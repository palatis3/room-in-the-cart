import XCTest
@testable import HouseholdClient
@testable import RoomInTheCart

final class ShopPackChangesTests: XCTestCase {
    private let household = UUID(), member = UUID(), device = UUID(), shop = UUID()
    private let brown = UUID(), white = UUID()
    private func read<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
    }
    private func key(member other: UUID? = nil, epoch: Int = 4, capabilities: [String] = ["shopper_commands"]) throws -> ShopPackScope {
        let session = try read(HouseholdDeviceSession.self, ["householdID": household.uuidString,
            "deviceID": device.uuidString, "memberID": (other ?? member).uuidString])
        return .init(subject: "shopper", device: session, shop: shop, authorityEpoch: epoch, capabilities: capabilities)
    }
    private func snapshot(_ revision: Int, _ lines: [(UUID, Int)], shop other: UUID? = nil,
                          epoch: Int = 4, partial: Bool = false) throws -> ShopperShop {
        var source: [String: Any] = ["shopId": (other ?? shop).uuidString, "shopRevision": revision,
            "authorityEpoch": epoch, "phase": "draft", "lines": lines.map {
                ["lineId": $0.0.uuidString, "packs": $0.1, "originalItem": "Rice", "feeEligible": true] as [String: Any]
            }, "quote": ["currency": "MXN", "scope": "wholeCheckout", "capScope": "wholeCheckout",
                        "complete": false, "fee": ["kind": "fixed"], "observedAt": "2025-01-01T00:00:00Z", "expiresAt": "2099-01-01T00:00:00Z"] as [String: Any]]
        if partial { source["nextCursor"] = UUID().uuidString }
        return try read(ShopperShop.self, source)
    }

    func testCompleteReadsPersistOnlyStablePackChangesAndDismissOnDevice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let store = HistoryPendingStore(url: url)
        let epoch = await store.epoch(), scope = try key()
        let initial = try await store.observePacks(scope: scope, shop: snapshot(1, [(brown,2),(white,4)]), expectedEpoch: epoch)
        XCTAssertFalse(initial.hasEarlierVisit)
        XCTAssertTrue(initial.previous.isEmpty)
        for bad in [try snapshot(2, [(brown,1)], partial: true), try snapshot(2, [(brown,2),(brown,4)]),
                    try snapshot(2, [(brown,1)], shop: UUID()), try snapshot(1, [(brown,5)])] {
            do { _ = try await store.observePacks(scope: scope, shop: bad, expectedEpoch: epoch); XCTFail("Unexpected complete observation") }
            catch { }
        }
        let next = try await store.observePacks(scope: scope, shop: snapshot(3, [(white,4),(brown,1)]), expectedEpoch: epoch)
        XCTAssertEqual(next.previous, [brown:2])
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Rice"))
        let reopened = HistoryPendingStore(url: url), reopenedEpoch = await reopened.epoch()
        let changedAgain = try await reopened.observePacks(scope: scope, shop: snapshot(4, [(brown,3),(white,3)]), expectedEpoch: reopenedEpoch)
        XCTAssertEqual(changedAgain.previous, [brown:2, white:4])
        do { _ = try await reopened.dismissPackChange(brown, observed: next, expectedEpoch: reopenedEpoch); XCTFail("Stale dismissal") } catch { }
        let acknowledged = try await reopened.dismissPackChange(brown, observed: changedAgain, expectedEpoch: reopenedEpoch)
        XCTAssertEqual(acknowledged.previous, [white:4])
        let withdrawn = try await reopened.observePacks(scope: scope, shop: snapshot(5, [(brown,3)]), expectedEpoch: reopenedEpoch)
        XCTAssertTrue(withdrawn.previous.isEmpty)
        let returned = try await reopened.observePacks(scope: scope, shop: snapshot(6, [(white,1),(brown,3)]), expectedEpoch: reopenedEpoch)
        XCTAssertTrue(returned.previous.isEmpty)
        try await reopened.purge(householdID: household.uuidString, subject: scope.subject)
        let erased = try await reopened.read()
        XCTAssertEqual(erased.observedShopPacks, [])
        do { _ = try await reopened.observePacks(scope: scope, shop: snapshot(7, []), expectedEpoch: reopenedEpoch); XCTFail("Recreated erased observation") } catch { }
    }

    func testMemberAuthorityAndCapabilitiesNeverInheritAnEarlierInterval() throws {
        let lines = [ShopperBasketLine(lineId: brown, originalItem: "Rice", packs: 2, unitPriceMinor: nil, feeEligible: true)]
        let changed = [ShopperBasketLine(lineId: brown, originalItem: "Rice", packs: 4, unitPriceMinor: nil, feeEligible: true)]
        let first = try ShopPackObservation(scope: key(), revision: 1, lines: lines, after: nil)
        for scope in [try key(member: UUID()), try key(epoch: 5), try key(capabilities: ["shopper_commands", "adult_checks"])] {
            let next = try ShopPackObservation(scope: scope, revision: 2, lines: changed, after: first)
            XCTAssertFalse(next.hasEarlierVisit)
            XCTAssertTrue(next.previous.isEmpty)
        }
    }

    func testCupboardReviewRequiresExactCurrentRowSeatReplyAndPacks() throws {
        let id = UUID(), stamp = "2026-01-01T00:00:00Z", expiry = "2099-01-01T00:00:00Z"
        let target = SharedGroceryTarget(shopID: shop, rowID: brown, revision: 3, authorityEpoch: 4,
                                          reply: .init(id: id, pairRevision: 1, answeredAt: stamp))
        let row = ShopperBasketLine(lineId: brown, originalItem: "Rice", packs: 2, unitPriceMinor: nil, feeEligible: true)
        let check: [String: Any] = ["id": id.uuidString, "sourceId": brown.uuidString, "kind": "cupboard", "label": "Rice",
            "shoppingPacks": 2, "expiresAt": expiry, "answer": "low", "answeredAt": stamp, "reviewed": false, "canAnswer": false]
        let page: [String: Any] = ["shopId": shop.uuidString, "shopRevision": 3, "authorityEpoch": 4, "pairRevision": 1,
            "shopper": true, "dinners": [], "items": [], "checks": [check], "validUntil": expiry]
        XCTAssertEqual(try target.confirmedReply(in: read(AdultCheckPage.self, page), row: row).answer, .low)
        for delta: [String: Any] in [["shopId": UUID().uuidString], ["shopper": false], ["pairRevision": 2], ["shopRevision": 4],
                                      ["authorityEpoch": 5], ["checks": []], ["validUntil": stamp]] {
            let altered = try read(AdultCheckPage.self, page.merging(delta) { _, new in new })
            XCTAssertThrowsError(try target.confirmedReply(in: altered, row: row))
        }
        for delta: [String: Any] in [["sourceId": white.uuidString], ["shoppingPacks": 3], ["answeredAt": expiry], ["expiresAt": stamp]] {
            let altered = check.merging(delta) { _, new in new }
            let updated = try read(AdultCheckPage.self, page.merging(["checks": [altered]]) { _, new in new })
            XCTAssertThrowsError(try target.confirmedReply(in: updated, row: row))
        }
    }
}
