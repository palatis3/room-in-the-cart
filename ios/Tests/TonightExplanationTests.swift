import XCTest
import CoreDomain
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class TonightExplanationTests: XCTestCase {
    private func ready() async throws -> TonightMealModel {
        let food = UUID(), ingredient = MealIngredient(name: "Wraps", quantity: .init(amount: try Rational(4), unit: .count, originalLiteral: "4"))
        let recipe = MealTemplate(title: "Reviewed tacos", ingredients: [ingredient])
        let workspace = LedgerWorkspace(mealTemplates: [recipe])
        let model = TonightMealModel()
        let input = TonightMealModel.Input(workspace: workspace, ledgerRevision: 1,
            basis: .init(originID: UUID(), inventoryRevision: 1, sourceHeads: []),
            foods: [.init(id: food, name: "Wraps", detail: "3 confirmed")],
            freeLots: [.init(id: food, foodID: food, name: "Wraps", usable: .init(amount: try Rational(3), unit: .count, originalLiteral: "3"), confirmedAt: Date(), source: .pantry)],
            unresolvedFoods: [], sources: [])
        await model.refresh(authorize: { true }, load: { input })
        try model.match(recipeID: recipe.id, ingredientID: ingredient.id, foodID: food)
        return model
    }
    private func reply(_ request: MealExplanationRequest) throws -> MealExplanationReply {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "requestID": request.requestID.uuidString,
            "suggestions": [["sourceLineID": request.candidates[0].id.uuidString, "reasons": ["pantry_match", "needs_more_food"]]]])
        return try JSONDecoder().decode(MealExplanationReply.self, from: data)
    }
    func testOfflineRetryUsesExactConsentAndProposalDoesNotSaveOrChangeStock() async throws {
        let meals = try await ready(), original = try XCTUnwrap(meals.input)
        let snapshot = try TonightExplanationModel.Snapshot(model: meals, ledgerID: UUID()), model = TonightExplanationModel()
        let selected = Set(snapshot.candidates.map(\.id))
        var first: UUID?
        await model.send(snapshot: snapshot, selected: selected, locale: "en", isCurrent: { snapshot.isCurrent(in: meals) }, refresh: { true }) { request in
            first = request.requestID; throw URLError(.notConnectedToInternet)
        }
        XCTAssertTrue(model.failed); XCTAssertNil(model.reply); XCTAssertFalse(meals.suggestions.isEmpty)
        await model.send(snapshot: snapshot, selected: selected, locale: "en", isCurrent: { snapshot.isCurrent(in: meals) }, refresh: { true }) { request in
            XCTAssertEqual(first, request.requestID); return try self.reply(request)
        }
        XCTAssertNotNil(model.reply); XCTAssertEqual(meals.input?.workspace, original.workspace)
        XCTAssertEqual(meals.input?.freeLots, original.freeLots); XCTAssertTrue(original.workspace.shops.isEmpty)
        XCTAssertEqual(snapshot.candidates.first?.reasons, [.pantryMatch, .needsMoreFood])
    }
    func testRemovedMatchDuringResponseCannotPublishOrBecomeAnEligibleID() async throws {
        let meals = try await ready(), snapshot = try TonightExplanationModel.Snapshot(model: meals, ledgerID: UUID())
        let model = TonightExplanationModel()
        await model.send(snapshot: snapshot, selected: Set(snapshot.candidates.map(\.id)), locale: "es",
            isCurrent: { snapshot.isCurrent(in: meals) }, refresh: { true }) { request in
                let candidate = try XCTUnwrap(snapshot.candidates.first)
                try meals.match(recipeID: candidate.id, ingredientID: candidate.review.recipe.ingredients[0].id, foodID: nil)
                return try self.reply(request)
            }
        XCTAssertNil(model.reply); XCTAssertFalse(model.busy)
        XCTAssertTrue(try TonightExplanationModel.Snapshot(model: meals, ledgerID: UUID()).candidates.isEmpty)
        XCTAssertThrowsError(try snapshot.request(selected: [UUID()], locale: "en"))
    }
    func testRevokedReadAfterProviderAndChangedPantryBeforeSendFailClosed() async throws {
        let meals = try await ready(), snapshot = try TonightExplanationModel.Snapshot(model: meals, ledgerID: UUID())
        let model = TonightExplanationModel(); var access = true; var calls = 0
        await model.send(snapshot: snapshot, selected: Set(snapshot.candidates.map(\.id)), locale: "en",
            isCurrent: { access && snapshot.isCurrent(in: meals) }, refresh: { true }) { request in
                calls += 1; access = false; return try self.reply(request)
            }
        XCTAssertNil(model.reply)
        access = true
        let original = try XCTUnwrap(meals.input)
        let changed = TonightMealModel.Input(workspace: original.workspace, ledgerRevision: original.ledgerRevision,
            basis: .init(originID: original.basis.originID, inventoryRevision: original.basis.inventoryRevision + 1,
                         sourceHeads: original.basis.sourceHeads), foods: original.foods, freeLots: [],
            unresolvedFoods: Set(original.foods.map(\.id)), sources: original.sources)
        await model.send(snapshot: snapshot, selected: Set(snapshot.candidates.map(\.id)), locale: "en",
            isCurrent: { access && snapshot.isCurrent(in: meals) }, refresh: {
                await meals.refresh(authorize: { access }, load: { changed })
                return snapshot.isCurrent(in: meals)
            }) { request in calls += 1; return try self.reply(request) }
        XCTAssertEqual(calls, 1); XCTAssertNil(model.reply)
    }
}
