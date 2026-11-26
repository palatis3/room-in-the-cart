import CoreDomain
import XCTest
@testable import RoomInTheCart

@MainActor final class InStoreSavedPlaceTests: XCTestCase {
    private let actorID = UUID()
    private let workspaceID = UUID()

    private func scope(_ shop: ShoppingLedger, household: String = "home", role: String = "shopper", device: String = "existing-device") -> InStorePlaceScope {
        .init(identity: .init(actorID: actorID, subject: "account", householdID: household, memberID: "member", role: role),
              workspace: workspaceID, shop: shop, enrollment: device)
    }

    func testExactLineSurvivesAisleAndAvailabilityChangeButNotSubstitutionOrPick() throws {
        var shop = ShoppingLedger(basis: ShopBasis(branch: "Centro"))
        let blue = try shop.addManualLine(name: "Yogur", quantity: nil, notes: "Azul, 750 g")
        let green = try shop.addManualLine(name: "Yogur", quantity: nil, notes: "Verde, 750 g")
        let initial = scope(shop)
        func current(_ id: UUID) -> InStoreSavedPlace? {
            .make(scope: initial, lineID: id, workspace: LedgerWorkspace(shops: [shop], selectedShopID: shop.id), photo: nil)
        }
        let saved = try XCTUnwrap(current(blue))
        XCTAssertFalse(saved.matches(current(green)))
        try shop.updateLine(lineID: blue, name: "Yogur", notes: "Azul, 750 g", aisle: "Refrigerados")
        XCTAssertTrue(saved.matches(current(blue)))
        try shop.markUnavailable(lineID: blue, expectedRevision: shop.revisionID)
        XCTAssertTrue(saved.matches(current(blue)))
        XCTAssertFalse(try XCTUnwrap(shop.lines.first(where: { $0.id == blue })).isChecked)
        try shop.undoTripChange(lineID: blue, expectedRevision: shop.revisionID)
        try shop.updateLine(lineID: blue, name: "Yogur", notes: "Azul, 1 kg", aisle: "Refrigerados")
        XCTAssertFalse(saved.matches(current(blue)))
        try shop.setChecked(lineID: blue, checked: true)
        XCTAssertNil(current(blue))
    }

    func testProtectedSlotReopensRemainsPrivateAndRefusesStaleReplacementAfterClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root)
        let reopened = CaptureMediaStore(directory: root)
        var shop = ShoppingLedger(basis: ShopBasis(branch: "Centro"))
        let id = try shop.addManualLine(name: "PRIVATE YOGURT", quantity: nil, notes: "SECRET BLUE")
        let owner = scope(shop), now = Date()
        let place = try XCTUnwrap(InStoreSavedPlace.make(scope: owner, lineID: id,
            workspace: LedgerWorkspace(shops: [shop], selectedShopID: shop.id), photo: nil, at: now))
        try await store.updateSavedPlace(in: owner, expected: nil, place: place, at: now) { true }
        let loaded = try await reopened.savedPlace(in: owner, at: now) { true }
        let marked = try XCTUnwrap(loaded)
        XCTAssertEqual(marked.place, place)
        let other = try await reopened.savedPlace(in: scope(shop, household: "other"), at: now) { true }
        let changedRole = try await reopened.savedPlace(in: scope(shop, role: "organizer"), at: now) { true }
        XCTAssertNil(other)
        XCTAssertNil(changedRole)
        let replacedEnrollment = try await reopened.savedPlace(in: scope(shop, device: "replacement-device"), at: now) { true }
        XCTAssertNil(replacedEnrollment)
        // Read the actual protected sidecar, not a re-encoding of the in-memory model.
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("shopping-places-") })
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertTrue(text.contains(place.product))
        XCTAssertEqual(place.product.count, 64)
        for secret in ["PRIVATE YOGURT", "SECRET BLUE", "existing-device", "account", "member", "home"] {
            XCTAssertFalse(text.contains(secret))
        }
        try await store.updateSavedPlace(in: owner, expected: marked.revision, place: nil, at: now) { true }
        do {
            try await reopened.updateSavedPlace(in: owner, expected: marked.revision, place: place, at: now) { true }
            XCTFail("A stale detail replaced a deliberate clear")
        } catch { XCTAssertEqual(error as? ScanFailure, .stale) }
        let cleared = try await reopened.savedPlace(in: owner, at: now) { true }
        XCTAssertNil(cleared?.place)
        let afterExpiry = try await reopened.savedPlace(in: owner, at: now.addingTimeInterval(InStoreSavedPlace.lifetime)) { true }
        XCTAssertNil(afterExpiry)
        let rewound = try await reopened.savedPlace(in: owner, at: now) { true }
        XCTAssertNil(rewound)
        try await store.eraseWorkspace(workspaceID)
        do {
            try await reopened.updateSavedPlace(in: owner, expected: nil, place: place, at: now) { true }
            XCTFail("Retired workspace accepted a late place")
        } catch { XCTAssertEqual(error as? ScanFailure, .retired) }
    }

    func testAWithdrawnPhotoCannotReopenEvenWhenTheDisplayStillCachesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root)
        var shop = ShoppingLedger(basis: ShopBasis(branch: "Centro"))
        let id = try shop.addManualLine(name: "Coffee", quantity: nil)
        let owner = scope(shop)
        let photoOwner = PackageRowPhoto.Owner(.init(actorID: actorID, subject: "account",
                                                     householdID: "home", memberID: "member", role: "shopper"))
        let place = InStoreSavedPlace(line: id, product: String(repeating: "a", count: 64), photo: UUID(),
                                      association: nil, saved: .now)
        try await store.updateSavedPlace(in: owner, expected: nil, place: place) { true }
        let cached = try await store.savedPlace(in: owner) { true }
        XCTAssertEqual(cached?.place, place)
        let reviewed = try await store.savedPlace(in: owner, photoOwner: photoOwner) { true }
        XCTAssertNil(reviewed)
    }

    func testRevocationBetweenChecksRollsBackOnlyTheNewWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureMediaStore(directory: root)
        var shop = ShoppingLedger(basis: ShopBasis(branch: "Centro"))
        let id = try shop.addManualLine(name: "Oats", quantity: nil)
        let owner = scope(shop)
        let place = try XCTUnwrap(InStoreSavedPlace.make(scope: owner, lineID: id,
            workspace: LedgerWorkspace(shops: [shop], selectedShopID: shop.id), photo: nil))
        var checks = 0
        do {
            try await store.updateSavedPlace(in: owner, expected: nil, place: place) {
                checks += 1
                return checks == 1
            }
            XCTFail("Revoked place survived the write")
        } catch { XCTAssertEqual(error as? ScanFailure, .stale) }
        let after = try await store.savedPlace(in: owner) { true }
        XCTAssertNil(after)
    }
}
