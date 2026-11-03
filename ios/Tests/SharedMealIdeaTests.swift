import XCTest
import HouseholdClient
@testable import RoomInTheCart

private actor IdeaServiceFixture: SharedMealIdeasServing {
    var page: SharedMealIdeaPage
    var lost = false
    var requests: [SharedMealIdeaWrite] = []
    var onRead: (@Sendable () async -> Void)?
    init(page: SharedMealIdeaPage) { self.page = page }
    func setLost(_ value: Bool) { lost = value }
    func readHook(_ hook: @escaping @Sendable () async -> Void) { onRead = hook }
    func sent() -> [SharedMealIdeaWrite] { requests }
    func sharedMealIdeas(shopID: UUID) async throws -> SharedMealIdeaPage { await onRead?(); return page }
    func writeSharedMealIdea(shopID: UUID, request: SharedMealIdeaWrite) async throws -> SharedMealIdeaReceipt {
        requests.append(request)
        if lost { throw URLError(.networkConnectionLost) }
        return try JSONDecoder().decode(SharedMealIdeaReceipt.self, from: JSONSerialization.data(withJSONObject: ["saved":true,"ideaId":request.ideaId.uuidString,"revision":(request.baseRevision ?? 0)+1,"state":request.action == "approve" ? "approved":"draft"]))
    }
}
@MainActor final class SharedMealIdeaTests: XCTestCase {
    private func scope() -> SharedMealChangeScope { .init(subject: "adult", householdID: UUID().uuidString, memberID: UUID().uuidString, shopID: UUID(), authorityStamp: "contributor/meal_proposals") }
    private func draft() -> SharedMealIdeaDraft { .init(title: "Beans", ingredients: [.init(name: "Beans", required: 300, stock: 50, reservations: [.init(name: "Lunch", amount: 20)], pack: 400, usableNumerator: 1, usableDenominator: 1, evidence: "Shared stock checked")]) }
    private func page(_ scope: SharedMealChangeScope) throws -> SharedMealIdeaPage {
        try JSONDecoder().decode(SharedMealIdeaPage.self, from: JSONSerialization.data(withJSONObject: ["shopId":scope.shopID.uuidString,"shopRevision":1,"authorityEpoch":1,"grantRevision":1,"shopper":false,"ideas":[]]))
    }
    func testUnknownHouseholdEvidenceEncodesAsExplicitNullNotPrivateDefaults() throws {
        let value = SharedMealIdeaDraft(title: "Manual", ingredients: [.init(name: "Rice", evidence: "Not checked")])
        try value.validate()
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String:Any])
        let ingredient = try XCTUnwrap((encoded["ingredients"] as? [[String:Any]])?.first)
        for key in ["required","stock","pack","usableNumerator","usableDenominator"] { XCTAssertTrue(ingredient[key] is NSNull, key) }
        XCTAssertNil(ingredient["price"]); XCTAssertNil(encoded["workspaceID"])
    }
    func testLostResponseBlocksEditedWriteAndRetriesExactOriginalKeyAndEvidence() async throws {
        let scope = scope(), service = IdeaServiceFixture(page: try page(scope))
        let model = SharedMealIdeaModel(scope: scope, service: service, runtime: { scope })
        await model.load(); await service.setLost(true)
        let id = UUID(), original = draft()
        await model.write(ideaID: id, draft: original, approve: false, reviewed: false)
        let pending = try XCTUnwrap(model.pending)
        var changed = original; changed.title = "Different"
        await model.write(ideaID: id, draft: changed, approve: false, reviewed: false)
        await service.setLost(false); await model.retry()
        let requests = await service.sent()
        XCTAssertEqual(requests, [pending,pending]); XCTAssertNil(model.pending); XCTAssertEqual(model.savedID,id)
    }
    func testApprovalCannotBeSentForUnsavedOrUnreviewedIdea() async throws {
        let scope = scope(), service = IdeaServiceFixture(page: try page(scope))
        let model = SharedMealIdeaModel(scope: scope, service: service, runtime: { scope })
        await model.load(); await model.write(ideaID: UUID(), draft: draft(), approve: true, reviewed: true)
        let requests = await service.sent(); XCTAssertTrue(requests.isEmpty)
    }
    func testChangingAccountOrEnrollmentScopeDiscardsLateReadAndBlocksWrite() async throws {
        let scope = scope(), service = IdeaServiceFixture(page: try page(scope))
        var current: SharedMealChangeScope? = scope
        let model = SharedMealIdeaModel(scope: scope, service: service, runtime: { current })
        await service.readHook { await MainActor.run { current = nil } }
        await model.load(); XCTAssertNil(model.page)
        await model.write(ideaID: UUID(), draft: draft(), approve: false, reviewed: false)
        let requests = await service.sent(); XCTAssertTrue(requests.isEmpty)
    }
    func testNewProposalRequiresExplicitApprovedIdeaAndEncodesNullOriginalRevision() throws {
        let value = try draft().proposedMeal(day: "2026-11-09")
        let id = UUID(), request = SharedMealChangeRequest(occurrenceId: UUID(), baseMealRevision: nil, shopRevision: 1, authorityEpoch: 1, grantRevision: 0, meal: value, reason: "Approved", approvedIdeaId: id, approvedIdeaRevision: 2)
        try request.validate()
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String:Any])
        XCTAssertTrue(raw["baseMealRevision"] is NSNull); XCTAssertEqual(raw["approvedIdeaId"] as? String,id.uuidString)
        XCTAssertThrowsError(try SharedMealChangeRequest(occurrenceId: UUID(), baseMealRevision: nil, shopRevision: 1, authorityEpoch: 1, grantRevision: 0, meal: value, reason: "Unapproved").validate())
        XCTAssertTrue(value.planning?.groups.isEmpty == true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("Shared stock checked"))
    }
}
