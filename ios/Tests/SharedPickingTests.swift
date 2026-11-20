import HouseholdClient
import XCTest
@testable import RoomInTheCart

@MainActor final class SharedPickingTests: XCTestCase {
    func testOfflinePendingRestoresAndReconcilesLastPackClaimedOnOtherDevice() async throws {
        let fixture = SharedPickingTestFixture()
        let server = S24FixtureServer()
        defer { server.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let household = try await account(server, fixture, url)
        let scope = try XCTUnwrap(household.adultRequestScope(shop: fixture.shop, capability: "shared_picking"))
        let first = SharedPickingModel(household: household, scope: scope)
        await first.refresh()
        let row = try XCTUnwrap(first.page?.rows.first)
        fixture.set(.offline)
        await first.pick(.pick, row: row, packs: 1)
        let pending = try XCTUnwrap(first.pending.first)
        XCTAssertEqual(first.page?.rows.first?.picked, 0)
        let persisted = try await household.pickingPendingStore.read()
        XCTAssertEqual(persisted, [pending])
        // Another still-authorized trip has its own independent pending row on this device.
        var otherObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
        var otherIntent = try XCTUnwrap(otherObject["intent"] as? [String: Any])
        otherIntent["shopID"] = UUID().uuidString
        otherObject["intent"] = otherIntent
        let otherTrip = try JSONDecoder().decode(ScopedSharedPick.self, from: JSONSerialization.data(withJSONObject: otherObject))
        let epoch = await household.pickingPendingStore.epoch()
        try await household.pickingPendingStore.save(otherTrip, expectedEpoch: epoch)
        first.close()
        XCTAssertNil(first.page)
        fixture.set(.otherPicked)
        let reopened = SharedPickingModel(household: household, scope: scope)
        await reopened.refresh()
        XCTAssertEqual(reopened.page?.rows.first?.lastActorLabel, "Jo")
        XCTAssertEqual(reopened.page?.rows.first?.picked, 1)
        XCTAssertTrue(reopened.pending.isEmpty)
        XCTAssertTrue(reopened.notice == householdTripText("The row changed. The picked count already includes the other shopper’s work. Your pending change was not added."))
        let retired = try await household.pickingPendingStore.read()
        XCTAssertEqual(retired, [otherTrip])
    }

    func testRevokedDeviceHidesRowsAndRetiresItsRetryBeforeAnotherWrite() async throws {
        let fixture = SharedPickingTestFixture(), server = S24FixtureServer()
        defer { server.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let household = try await account(server, fixture, url)
        let scope = try XCTUnwrap(household.adultRequestScope(shop: fixture.shop, capability: "shared_picking"))
        let picker = SharedPickingModel(household: household, scope: scope)
        await picker.refresh()
        fixture.set(.offline)
        await picker.pick(.claim, row: try XCTUnwrap(picker.page?.rows.first))
        XCTAssertEqual(picker.pending.count, 1)
        fixture.set(.revoked)
        await picker.refresh()
        XCTAssertNil(picker.page)
        XCTAssertTrue(picker.pending.isEmpty)
        let durable = try await household.pickingPendingStore.read()
        XCTAssertTrue(durable.isEmpty)
        XCTAssertEqual(fixture.operationRequests, 1)
    }

    private func account(_ server: S24FixtureServer, _ fixture: SharedPickingTestFixture, _ queue: URL) async throws -> HouseholdModel {
        server.intercept = fixture.intercept
        let transport = HTTPTransport(session: server.makeSession())
        let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL, publishableKey: "sb_publishable_fixture"),
                             vault: S24FixtureVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: server.baseURL), auth: auth,
                                       deviceVault: S24FixtureVault(), transport: transport)
        let model = HouseholdModel(auth: auth, service: service, outboxURL: queue, deletionVault: S24FixtureVault(),
                                   exitVault: S24FixtureVault(), guardianVault: S24FixtureVault())
        model.email = "picking@example.invalid"; model.code = "123456"
        await model.verifyCode()
        model.keepLocalPrivate = true
        await model.join(try XCTUnwrap(model.workspaces.first))
        return model
    }
}

private final class SharedPickingTestFixture: @unchecked Sendable {
    enum State { case online, offline, revoked, otherPicked }
    let shop = UUID(), device = UUID(), row = UUID(), grant = UUID(), safety = UUID()
    private let lock = NSLock()
    private var state: State = .online
    private var writes = 0
    var operationRequests: Int { lock.withLock { writes } }
    func set(_ next: State) { lock.withLock { state = next } }

    /// Auth and account identity use the established S24 session fixture. Intercept only this shop's new routes.
    func intercept(_ connection: S24FixtureProtocol) -> Bool {
        let req = connection.request, path = req.url!.path
        let member = S24FixtureServer.member, household = S24FixtureServer.household
        let status: Int, payload: [String: Any]
        let mode = lock.withLock { state }
        if path.hasSuffix("/workspaces") {
            status = 200; payload = ["workspaces": [["householdId": household, "label": "Cart", "role": "contributor"]]]
        } else if path.hasSuffix("/devices") {
            status = 201; payload = ["deviceId": device.uuidString, "deviceToken": "fixture-device"]
        } else if path.hasSuffix("/bootstrap") {
            status = 200; payload = ["memberId": member, "household": ["id": household, "label": "Cart"], "role": "contributor",
                "shopId": shop.uuidString, "enrolled": true, "queueConsent": false, "capabilities": ["shared_picking", "shared_content_safety"]]
        } else if path.contains("/shared-picking") {
            let write = path.hasSuffix("/operations")
            if write { lock.withLock { writes += 1 } }
            if mode == .offline {
                connection.client?.urlProtocol(connection, didFailWithError: URLError(.notConnectedToInternet))
                return true
            } else if mode == .revoked || write {
                status = mode == .revoked ? 403 : 409; payload = ["error": ["code": mode == .revoked ? "unavailable" : "stale_base"]]
            } else {
                status = 200
                var line: [String: Any] = ["id": row.uuidString, "safetyId": safety.uuidString, "label": "Tea",
                                          "packs": 1, "picked": 0, "revision": 1]
                if mode == .otherPicked { line["revision"] = 2; line["picked"] = 1; line["lastActorLabel"] = "Jo" }
                payload = ["managed": false, "authorityEpoch": 1, "shopRevision": 1, "recipientId": member,
                           "permissionId": grant.uuidString, "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
                           "members": [], "availableRows": [], "rows": [line]]
            }
        } else { return false }
        connection.client?.urlProtocol(connection, didReceive: HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        connection.client?.urlProtocol(connection, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        connection.client?.urlProtocolDidFinishLoading(connection)
        return true
    }
}
