import XCTest
@testable import CoreDomain

final class SavedDinnerReviewTests: XCTestCase {
    private let workspaceID = UUID()
    private let shop = ShoppingLedger(title: "Dinner groceries")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let recipe = MealTemplate(title: "Lemon chickpeas", servings: try! Rational(2), ingredients: [
        MealIngredient(name: "Lemon", quantity: Quantity(amount: .one, unit: .count, originalLiteral: "1 lemon")),
        MealIngredient(name: "Chickpeas", quantity: nil, checkedWithoutAmount: true)
    ])
    private var workspace: LedgerWorkspace { LedgerWorkspace(shops: [shop], mealTemplates: [recipe], selectedShopID: shop.id) }
    private var access: DinnerAccessContext {
        DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "adult", shopID: shop.id, assignedShopperID: "adult",
            canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(120))
    }
    func testOneLemonOnlyIsAnIdempotentShoppingEditAndDoesNotChangeChosenDemand() throws {
        var data = workspace
        _ = try data.shops[0].chooseMeal(recipe, at: now)
        let supply = try data.shops[0].addManualLine(name: "Lemon", quantity: recipe.ingredients[0].quantity)
        let contribution = try XCTUnwrap(data.shops[0].contributions(forLineID: supply).first)
        _ = try data.shops[0].addProtectedNeed(name: "Lemon", quantity: recipe.ingredients[0].quantity, purpose: "Lunch", within: contribution.id)
        let original = data.shops[0]
        XCTAssertEqual(original.allocations.count, 1)
        let review = try SavedDinnerReview(recipe: recipe, action: .groceries([recipe.ingredients[0].id]), workspace: data,
                                           access: access, phase: .draft, at: now)
        XCTAssertEqual(review.destinationTitle, "Dinner groceries")
        XCTAssertEqual(review.ingredients.map(\.name), ["Lemon"])
        try review.apply(to: &data, access: access, phase: .draft, at: now)
        XCTAssertEqual(data.shops[0].mealOccurrences, original.mealOccurrences)
        XCTAssertEqual(data.shops[0].allocations, original.allocations)
        XCTAssertEqual(Array(data.shops[0].contributions.dropLast()), original.contributions)
        XCTAssertEqual(data.shops[0].contributions.last?.source, .manual)
        XCTAssertEqual(data.shops[0].contributions.last?.quantity, recipe.ingredients[0].quantity)
        let saved = data
        try review.apply(to: &data, access: access, phase: .draft, at: now)
        XCTAssertEqual(data, saved)
        try data.validate()
    }
    func testWholeDinnerKeepsBothIngredientsServingsAndDay() throws {
        var data = workspace
        let review = try SavedDinnerReview(recipe: recipe, action: .planTonight, workspace: data, access: access, phase: .draft, at: now)
        try review.apply(to: &data, access: access, phase: .draft, at: now)
        let meal = try XCTUnwrap(data.shops[0].mealOccurrences.first)
        XCTAssertEqual(meal.title, recipe.title)
        XCTAssertEqual(meal.servings, recipe.servings)
        XCTAssertEqual(meal.templateID, recipe.id)
        XCTAssertEqual(meal.scheduledDay, try MealDay(date: now, timeZoneIdentifier: shop.basis.timeZoneIdentifier))
        XCTAssertEqual(meal.ingredientContributionIDs.count, 2)
        XCTAssertTrue(review.isApplied(in: data))
        let saved = data
        try review.apply(to: &data, access: access, phase: .draft, at: now)
        XCTAssertEqual(data, saved)
    }
    func testStaleMealPickupAndClosedBasketCannotAddGroceries() throws {
        let review = try SavedDinnerReview(recipe: recipe, action: .groceries([recipe.ingredients[0].id]), workspace: workspace,
                                           access: access, phase: .draft, at: now)
        var data = workspace
        data.mealTemplates[0].revision += 1
        XCTAssertThrowsError(try review.apply(to: &data, access: access, phase: .draft, at: now))
        data = workspace
        _ = try data.shops[0].addManualLine(name: "Tea", quantity: nil)
        XCTAssertThrowsError(try review.apply(to: &data, access: access, phase: .draft, at: now))
        data = workspace
        XCTAssertThrowsError(try review.apply(to: &data, access: access, phase: .reportedPlaced, at: now))
        data.selectedShopID = nil
        XCTAssertThrowsError(try review.apply(to: &data, access: access, phase: .draft, at: now))
        XCTAssertTrue(data.shops[0].lines.isEmpty)
    }
    func testNoSelectionUnknownIDAndNonFreeRecipeRequireReview() throws {
        for ids in [Set<UUID>(), [UUID()]] {
            XCTAssertThrowsError(try SavedDinnerReview(recipe: recipe, action: .groceries(ids), workspace: workspace,
                                                       access: access, phase: .draft, at: now))
        }
        var data = workspace
        data.mealTemplates.insert(MealTemplate(title: "Another dinner"), at: 0)
        XCTAssertThrowsError(try SavedDinnerReview(recipe: recipe, action: .planTonight, workspace: data,
                                                   access: access, phase: .draft, at: now))
    }
}
