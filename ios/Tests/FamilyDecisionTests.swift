import XCTest
import CoreDomain
import HouseholdClient
@testable import RoomInTheCart

final class FamilyDecisionTests: XCTestCase {
    @MainActor
    func testRefreshingAccessHidesDecisionsFromATransferredPickup() async throws {
        let server = S24FixtureServer()
        defer { server.close() }
        let transport = HTTPTransport(session: server.makeSession())
        let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL, publishableKey: "sb_publishable_fixture_only"),
                             vault: S24FixtureVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "shopper@example.invalid", code: "123456")
        let service = HouseholdService(configuration: try .init(baseURL: server.baseURL), auth: auth,
                                       deviceVault: S24FixtureVault(), transport: transport)
        _ = try await service.enroll(householdID: S24FixtureServer.household)
        let shop = try XCTUnwrap(UUID(uuidString: S24FixtureServer.shop)), decision = UUID()
        let record: [String: Any] = ["id": decision.uuidString, "shopId": shop.uuidString, "version": 1,
            "kind": "preference", "dish": "Wednesday wraps", "decision": "Keep the filling separate",
            "scope": "one_shop", "recordedAt": "2026-11-16T12:00:00Z"]
        let recordBytes = try JSONSerialization.data(withJSONObject: record)
        let searchBytes = try JSONSerialization.data(withJSONObject: ["decisions": [record], "nextCursor": NSNull()])
        let ownedBytes = try JSONEncoder().encode(HistoryOwnedShopPage(shops: [
            .init(shopId: shop.uuidString, createdAt: "2026-11-16T12:00:00Z", phase: "closed", revision: 1, authorityEpoch: 1)
        ], nextCursor: nil))
        server.intercept = { task in
            let path = task.request.url!.path
            if path.hasSuffix("/shops") { Self.respond(task, bytes: ownedBytes); return true }
            if path.hasSuffix("/decisions/" + decision.uuidString.lowercased()) { Self.respond(task, bytes: recordBytes); return true }
            if path.hasSuffix("/decisions") { Self.respond(task, bytes: searchBytes); return true }
            return false
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FamilyDecisionAccess(generation: UUID(), subject: "fixture-adult", householdID: S24FixtureServer.household,
                                          memberID: S24FixtureServer.member, shopID: nil)
        let model = FamilyDecisionModel(access: access, service: service,
                                        store: HistoryPendingStore(url: directory.appendingPathComponent("history.json")),
                                        currentAccess: { access })
        await model.load()
        XCTAssertEqual(model.shops.count, 1)
        await model.search(dish: "Wednesday wraps", product: nil, occasion: nil)
        XCTAssertEqual(model.results.map(\.id), [decision])
        await model.open(shopID: shop, id: decision)
        XCTAssertEqual(model.record?.decision, "Keep the filling separate")

        // The adult session remains valid, but the server no longer assigns this pickup to them.
        let empty = try JSONEncoder().encode(HistoryOwnedShopPage(shops: [], nextCursor: nil))
        server.intercept = { task in
            guard task.request.url!.path.hasSuffix("/shops") else { return false }
            Self.respond(task, bytes: empty); return true
        }
        await model.load()
        XCTAssertTrue(model.shops.isEmpty)
        XCTAssertNil(model.notice, "A valid refresh with no assigned pickups is not a network error")
        XCTAssertNil(model.record, "Refreshing access must conceal the previously opened decision")
        XCTAssertTrue(model.results.isEmpty, "Prior search snippets must not survive an access refresh")
        XCTAssertFalse(model.searched)
        XCTAssertNil(model.cursor)
    }

    private static func respond(_ task: S24FixtureProtocol, bytes: Data) {
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        task.client?.urlProtocol(task, didReceive: response, cacheStoragePolicy: .notAllowed)
        task.client?.urlProtocol(task, didLoad: bytes)
        task.client?.urlProtocolDidFinishLoading(task)
    }

    func testRetriedDecisionKeepsIdentityAndErasurePreventsLateCompletion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryPendingStore(url: url)
        let household = UUID().uuidString, member = UUID().uuidString, shop = UUID(), key = UUID()
        let data: [String: Any] = ["id": key.uuidString, "subject": "adult", "householdID": household, "memberID": member,
            "deviceID": "device", "shopID": shop.uuidString, "recordID": key.uuidString,
            "action": ["create": ["_0": ["kind":"preference","dish":"Wednesday wraps","decision":"Use corn tortillas today"]]]]
        let intent = try JSONDecoder().decode(FamilyDecisionIntent.self, from: JSONSerialization.data(withJSONObject: data))
        let epoch = await store.epoch()
        try await store.stageDecision(intent, expectedEpoch: epoch)
        try await store.stageDecision(intent, expectedEpoch: epoch)
        let reopened = HistoryPendingStore(url: url)
        let initial = try await reopened.read()
        XCTAssertEqual(initial.familyDecisions?.pending, [intent])
        try await store.finishDecision(intent, confirmed: true, expectedEpoch: epoch)
        let saved = try await store.read()
        XCTAssertEqual(saved.familyDecisions?.records.map(\.id), [key])
        XCTAssertEqual(saved.familyDecisions?.pending, [])
        try await store.purge(householdID: household, subject: "adult")
        do {
            try await store.stageDecision(intent, expectedEpoch: epoch)
            XCTFail("A pre-erasure intent was restored.")
        } catch ClientError.cancelled { }
        let erased = try await store.read()
        XCTAssertEqual(erased.familyDecisions?.records, [])
    }

    func testPrivateRepairInstructionNeverImpliesThatMealWasCookedOrCreatesSharedRecord() throws {
        let need = UUID(), shop = UUID()
        var journey = PickupJourney(id: shop, savedAt: Date())
        journey.urgent = [UrgentMealNeed(id: need, food: "Wraps", meal: "Lunch", required: .init(amount: .one, unit: .count, originalLiteral: "1"),
            available: .init(amount: .zero, unit: .count, originalLiteral: "0"), due: nil, confirmedAt: Date())]
        journey.repairs = [.init(id: UUID(), needID: need, instruction: "Keep the bean filling separate", createdAt: Date(),
            extraTripAgreed: false, repeatMealAgreed: false, elapsedMinutes: nil, due: nil)]
        let original = journey
        let evidence = try XCTUnwrap(PickupDecisionEvidence.records(in: journey).first)
        XCTAssertEqual(evidence.draft.dish, "Lunch")
        XCTAssertEqual(evidence.draft.product, "Wraps")
        XCTAssertEqual(evidence.draft.kind, .approval)
        XCTAssertNil(evidence.draft.outcome)
        XCTAssertTrue(evidence.arrivals.isEmpty)
        XCTAssertEqual(journey, original)
    }
}
