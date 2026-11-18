import XCTest
@testable import CoreDomain

final class DinnerSwapTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let workspace = UUID()

    private func access(_ shop: ShoppingLedger) -> DinnerAccessContext {
        .init(scope: .local(workspaceID: workspace), actorID: "shopper", shopID: shop.id,
              assignedShopperID: "shopper", canPlan: true, canReadBudget: true, hasPaidTools: false,
              roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(30))
    }
    private func recipe(_ title: String, ingredient: String) -> MealTemplate {
        .init(title: title, ingredients: [.init(name: ingredient, quantity: .init(amount: .one, unit: .count, originalLiteral: "1"))])
    }
    private func swap() throws -> (ShoppingLedger, DinnerPlanningState, DinnerApplyReceipt) {
        var shop = ShoppingLedger(title: "Week")
        var state = DinnerPlanningState()
        let old = try shop.chooseMeal(recipe("Tacos", ingredient: "Tortillas"), at: now)
        let proposal = try DinnerSwapEngine.preview(occurrenceID: old, replacement: .init(template: recipe("Soup", ingredient: "Beans")),
            ledger: shop, state: state, access: access(shop), phase: .draft, at: now).proposal
        let actor = access(shop)
        let receipt = try DinnerPlanningEngine.apply(proposal, ledger: &shop, state: &state, access: actor, phase: .draft, at: now)
        return (shop, state, receipt)
    }
    func testUndoAfterSeparateGroceryAndDinnerEditsPreservesThemAndReplaysOnce() throws {
        var (shop, state, receipt) = try swap()
        let effect = try XCTUnwrap(receipt.swapEffect)
        let coffee = try shop.addManualLine(name: "Coffee", quantity: nil, at: now)
        let dinner = try shop.chooseMeal(recipe("Thursday noodles", ingredient: "Noodles"), at: now)
        let actor = access(shop)
        let revision = try DinnerSwapEngine.undo(receipt, ledger: &shop, state: &state, access: actor, phase: .draft, at: now)
        XCTAssertTrue(shop.lines.contains { $0.id == coffee && !$0.isTrashed })
        XCTAssertTrue(shop.mealOccurrences.contains { $0.id == dinner && $0.removedAt == nil })
        XCTAssertEqual(shop.mealOccurrences.first { $0.id == effect.original.id }, effect.original)
        XCTAssertNotNil(shop.mealOccurrences.first { $0.id == effect.replacementID }?.removedAt)
        let workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(
            LedgerWorkspace(shops: [shop], selectedShopID: shop.id, dinnerPlanning: state)))
        shop = workspace.shops[0]
        state = workspace.dinnerPlanning
        let head = shop.revision
        XCTAssertEqual(try DinnerSwapEngine.undo(receipt, ledger: &shop, state: &state, access: actor, phase: .reportedPlaced, at: now), revision)
        XCTAssertEqual(shop.revision, head)
        try workspace.validate()
    }
    func testSwapSpecificGroupAndUndoLeaveTheProtectedLunchBoundToItsOriginalQuantity() throws {
        var shop = ShoppingLedger(), state = DinnerPlanningState()
        let supper = ServingGroup(name: "Dinner", servings: .one)
        let lunch = ServingGroup(name: "Lunch", servings: .one, isProtected: true)
        var tortillas = recipe("Tacos", ingredient: "Tortillas")
        tortillas.servings = try Rational(2)
        tortillas.servingGroups = [supper, lunch]
        tortillas.ingredients[0].quantity = Quantity(amount: try Rational(4), unit: .count, originalLiteral: "4")
        let old = try shop.chooseMeal(tortillas, at: now)
        let ingredient = try XCTUnwrap(shop.mealOccurrences.first?.ingredientContributionIDs.first)
        let amount = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let bindings = [supper, lunch].map {
            DinnerPortionBinding(occurrenceID: old, contributionID: ingredient, groupID: $0.id, quantity: amount, servings: .one)
        }
        let actor = access(shop)
        try state.setPortionBindings(bindings, for: old, ledger: shop, access: actor, at: now)
        let new = PlannedDinner(template: recipe("Soup", ingredient: "Beans"))
        XCTAssertThrowsError(try DinnerSwapEngine.preview(occurrenceID: old, groupID: lunch.id, replacement: new,
            ledger: shop, state: state, access: actor, phase: .draft, at: now))
        let review = try DinnerSwapEngine.preview(occurrenceID: old, groupID: supper.id, replacement: new,
            ledger: shop, state: state, access: actor, phase: .draft, at: now)
        let receipt = try DinnerPlanningEngine.apply(review.proposal, ledger: &shop, state: &state, access: actor, phase: .draft, at: now)
        XCTAssertEqual(state.portionBindings, [bindings[1]])
        XCTAssertEqual(shop.mealOccurrences.first?.servingGroups, [lunch])
        _ = try DinnerSwapEngine.undo(receipt, ledger: &shop, state: &state, access: actor, phase: .draft, at: now)
        XCTAssertEqual(state.portionBindings, bindings)
        XCTAssertEqual(shop.mealOccurrences.first?.servingGroups, [supper, lunch])
    }

    func testIndependentEditToReplacementOrPlacedCheckoutRefusesUndoAndKeepsCurrentFacts() throws {
        var (shop, state, receipt) = try swap()
        let actor = access(shop), effect = try XCTUnwrap(receipt.swapEffect)
        XCTAssertThrowsError(try DinnerSwapEngine.undo(receipt, ledger: &shop, state: &state, access: actor, phase: .reportedPlaced, at: now))
        try shop.scheduleMeal(occurrenceID: effect.replacementID, day: MealDay(year: 2026, month: 11, day: 18, timeZoneIdentifier: "UTC"), at: now)
        let before = shop
        XCTAssertThrowsError(try DinnerSwapEngine.undo(receipt, ledger: &shop, state: &state, access: actor, phase: .draft, at: now))
        XCTAssertEqual(shop, before)
    }
}
