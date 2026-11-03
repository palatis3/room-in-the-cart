import XCTest
import CoreDomain
import HouseholdClient
@testable import RoomInTheCart

final class FamilyDecisionTests: XCTestCase {
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
