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

    private func fractionalDraft() -> SharedMealIdeaDraft {
        .init(title: "Half cup chickpeas", ingredients: [.init(name: "Chickpeas", required: .init(1, 2), unit: "cup",
            stock: .init(1, 4), reservations: [.init(name: "Protected lunch", amount: .init(1, 8))], pack: 1,
            usableNumerator: 1, usableDenominator: 2, evidence: "Household measured cup and drained yield")])
    }
    func testFractionalEvidenceSurvivesLostResponseRetryExactly() async throws {
        let scope = scope(), service = IdeaServiceFixture(page: try page(scope))
        let model = SharedMealIdeaModel(scope: scope, service: service, runtime: { scope })
        await model.load(); await service.setLost(true)
        let id = UUID(), original = fractionalDraft()
        await model.write(ideaID: id, draft: original, approve: false, reviewed: false)
        let pending = try XCTUnwrap(model.pending)
        var edited = original; edited.ingredients[0].required = .init(3, 4)
        await model.write(ideaID: id, draft: edited, approve: false, reviewed: false)
        await service.setLost(false); await model.retry()
        let requests = await service.sent()
        XCTAssertEqual(requests, [pending, pending])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(requests[0]), try encoder.encode(requests[1]))
        let roundTrip = try JSONDecoder().decode(SharedMealIdeaWrite.self, from: encoder.encode(requests[1]))
        XCTAssertEqual(roundTrip.draft, original)
        XCTAssertEqual(roundTrip.action, "save"); XCTAssertFalse(roundTrip.reviewedHouseholdEvidence)
        XCTAssertNil(model.pending); XCTAssertEqual(model.savedID, id)
    }
    func testApprovedFractionalPageRetainsExactSupplyAndProposedQuantity() throws {
        let scope = scope(), draft = fractionalDraft(), ideaID = UUID()
        let rawDraft = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft))
        let payload: [String: Any] = ["shopId": scope.shopID.uuidString, "shopRevision": 1, "authorityEpoch": 1,
            "grantRevision": 1, "shopper": false, "ideas": [["ideaId": ideaID.uuidString, "revision": 2,
            "actorId": scope.memberID, "state": "approved", "draft": rawDraft,
            "preview": ["canApprove": true, "ingredients": [["ingredientId": draft.ingredients[0].id.uuidString,
                "excluded": false, "reserved": ["numerator": 1, "denominator": 8],
                "remaining": ["numerator": 1, "denominator": 8], "shortage": ["numerator": 3, "denominator": 8],
                "wholePacks": 1, "unresolvedPrice": true]]]]]]
        let page = try JSONDecoder().decode(SharedMealIdeaPage.self, from: JSONSerialization.data(withJSONObject: payload))
        try page.validate()
        let idea = try XCTUnwrap(page.ideas.first), preview = try XCTUnwrap(idea.preview.ingredients.first)
        XCTAssertEqual(preview.reserved?.text, "1/8"); XCTAssertEqual(preview.remaining?.text, "1/8")
        XCTAssertEqual(preview.shortage?.text, "3/8"); XCTAssertEqual(preview.wholePacks, 1)
        let meal = try idea.draft.proposedMeal(day: "2026-11-09")
        let quantity = try XCTUnwrap(meal.planning?.ingredients.first?.quantity)
        XCTAssertEqual(quantity.amount, .init(numerator: 1, denominator: 2)); XCTAssertEqual(quantity.unit, "cup")
        XCTAssertEqual(quantity.originalLiteral, "1/2 cup")
        let encodedMeal = String(decoding: try JSONEncoder().encode(meal), as: UTF8.self)
        XCTAssertFalse(encodedMeal.contains("Protected lunch")); XCTAssertFalse(encodedMeal.contains("drained yield"))
        XCTAssertFalse(encodedMeal.contains("stock")); XCTAssertFalse(encodedMeal.contains("price"))
    }
    func testOunceAndFluidOunceStayDistinctAcrossHouseholdAndProposalRoundTrip() throws {
        let draft = SharedMealIdeaDraft(title: "Measured ingredients", ingredients: [
            .init(name: "Dry ingredient", required: .init(3, 2), unit: "ounce", evidence: "Household scale"),
            .init(name: "Liquid ingredient", required: .init(1, 2), unit: "fluidOunce", evidence: "Household jug")])
        let decoded = try JSONDecoder().decode(SharedMealIdeaDraft.self, from: JSONEncoder().encode(draft))
        let meal = try decoded.proposedMeal(day: "2026-11-09")
        let ingredients = try XCTUnwrap(meal.planning?.ingredients)
        XCTAssertEqual(ingredients.map { $0.quantity?.unit }, ["ounce", "fluidOunce"])
        XCTAssertEqual(ingredients.map { $0.quantity?.amount }, [.init(numerator: 3, denominator: 2), .init(numerator: 1, denominator: 2)])
        XCTAssertNotEqual(ingredients[0].quantity?.unit, ingredients[1].quantity?.unit)
    }
    func testFractionEntryRejectsInvalidOrOutOfRangeEvidenceWithoutRounding() throws {
        for input in ["1/0", "-1/2", "1/2/3", "0.5", "1/1000001", "1000001/2", "1/"] {
            XCTAssertNil(SharedMealIdeaAmount.parse(input), input)
        }
        XCTAssertEqual(SharedMealIdeaAmount.parse(" 1 / 2 ")?.text, "1/2")
        let legacy = try JSONDecoder().decode(SharedMealIdeaAmount.self, from: Data("300".utf8))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self), "300")
        var invalid = fractionalDraft(); invalid.ingredients[0].required = .init(1, 0)
        XCTAssertThrowsError(try invalid.validate())
        invalid = fractionalDraft(); invalid.ingredients[0].usableNumerator = 3
        XCTAssertThrowsError(try invalid.validate())
    }
}
