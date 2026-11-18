import XCTest
@testable import CoreDomain

final class MealFeedbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let quantity = Quantity(amount: .one, unit: .cup, originalLiteral: "1")
    private func recipe(_ name: String) -> MealTemplate {
        MealTemplate(title: name, ingredients: [MealIngredient(name: "Rice", quantity: quantity)])
    }
    private func source(_ meal: MealTemplate) -> MealFeedbackSource { .recipe(id: meal.id, revision: meal.revision) }

    func testOptionalScopedFeedbackRoundTripEditRemovalAndSourceErasure() throws {
        let meal = recipe("Rice")
        var shop = ShoppingLedger(title: "Weekend")
        let id = try shop.chooseMeal(meal, at: now)
        var workspace = LedgerWorkspace(shops: [shop], mealTemplates: [meal])
        let occurrence = MealFeedbackSource.occurrence(shopID: shop.id, occurrenceID: id)
        let original = workspace
        try workspace.updateMealFeedback(for: occurrence, owner: "A", expectedRevision: nil, reactions: [], at: now)
        XCTAssertEqual(workspace, original)
        try workspace.updateMealFeedback(for: occurrence, owner: "A", expectedRevision: nil, reactions: [.tooManyLeftovers, .childrenLikedIt], at: now)
        try workspace.updateMealFeedback(for: source(meal), owner: "B", expectedRevision: nil, reactions: [.tooMuchEffort], at: now)
        XCTAssertEqual(workspace.mealFeedbackSignals(owner: "A", at: now)[source(meal)]?.reviewPortions, true)
        XCTAssertTrue(workspace.mealFeedbackSignals(owner: "other household", at: now).isEmpty)
        XCTAssertEqual(workspace.shops, original.shops)
        XCTAssertEqual(workspace.mealTemplates, original.mealTemplates)
        let saved = try JSONEncoder().encode(workspace)
        var decoded = try JSONDecoder().decode(LedgerWorkspace.self, from: saved)
        XCTAssertEqual(workspace, decoded)
        let revision = try XCTUnwrap(decoded.feedback(for: occurrence, owner: "A")?.revision)
        try decoded.updateMealFeedback(for: occurrence, owner: "A", expectedRevision: revision, reactions: [.makeAgain], at: now)
        XCTAssertThrowsError(try decoded.updateMealFeedback(for: occurrence, owner: "A", expectedRevision: revision, reactions: [], at: now))
        let latest = try XCTUnwrap(decoded.feedback(for: occurrence, owner: "A")?.revision)
        try decoded.updateMealFeedback(for: occurrence, owner: "A", expectedRevision: latest, reactions: [], at: now)
        XCTAssertNil(decoded.feedback(for: occurrence, owner: "A"))
        XCTAssertNotNil(decoded.feedback(for: source(meal), owner: "B"))
        try workspace.shops[0].removeMeal(occurrenceID: id, at: now)
        workspace.discardOrphanedMealFeedback()
        try workspace.validate()
        XCTAssertNil(workspace.feedback(for: occurrence, owner: "A"))
        workspace.mealTemplates = []
        workspace.discardOrphanedMealFeedback()
        XCTAssertEqual(workspace.privateMealFeedback, [])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self).contains("privateMealFeedback"))
    }

    func testLeftoverReactionSuggestsOnlyForADifferentFutureDinnerAndPreservesSourceAmounts() throws {
        var meal = recipe("Rice")
        meal.servings = try Rational(3, 2)
        var shop = ShoppingLedger(title: "Pickup")
        let past = try shop.chooseMeal(meal, on: now.addingTimeInterval(-86_400), at: now)
        let future = try shop.chooseMeal(meal, on: now.addingTimeInterval(86_400), at: now)
        var workspace = LedgerWorkspace(shops: [shop], mealTemplates: [meal])
        func suggestion(_ id: UUID) -> Rational? { workspace.suggestedFutureServings(shopID: shop.id, occurrenceID: id, owner: "adult", at: now) }
        try workspace.updateMealFeedback(for: .occurrence(shopID: shop.id, occurrenceID: future), owner: "adult",
                                         expectedRevision: nil, reactions: [.tooManyLeftovers], at: now)
        XCTAssertNil(suggestion(future))
        let source = MealFeedbackSource.occurrence(shopID: shop.id, occurrenceID: past)
        try workspace.updateMealFeedback(for: source, owner: "adult", expectedRevision: nil, reactions: [.tooManyLeftovers], at: now)
        XCTAssertEqual(suggestion(future), .one)
        XCTAssertNil(suggestion(past))
        XCTAssertEqual(workspace.shops, [shop])
        XCTAssertEqual(workspace.mealTemplates, [meal])
        try workspace.updateMealFeedback(for: source, owner: "adult", expectedRevision: workspace.feedback(for: source, owner: "adult")?.revision, reactions: [], at: now)
        XCTAssertNil(suggestion(future))
    }

    func testRankingExpiresAndChangesOnlyEligibleTiesWithSpaceForDiscovery() throws {
        let recipes = ["Untried", "Second favorite", "Favorite", "Blocked", "Reserved"].map(recipe)
        var workspace = LedgerWorkspace(mealTemplates: recipes)
        var reviews: [PantryMealMatcher.Review] = []
        for (index, meal) in recipes.enumerated() {
            let food = UUID()
            let lot = ConfirmedStockLot(id: UUID(), foodID: food, name: "Rice", usable: quantity, confirmedAt: now)
            var prefs = MealPreferenceSettings()
            if index == 3 { prefs.exclusions = ["rice"] }
            reviews.append(try PantryMealMatcher.review(recipe: meal, reviewedFoods: [meal.ingredients[0].id: food],
                globallyFreeLots: index == 4 ? [] : [lot], unresolvedFoods: [], profile: .init(settings: prefs)))
            if index > 0 {
                try workspace.updateMealFeedback(for: source(meal), owner: "A", expectedRevision: nil,
                    reactions: [.makeAgain], at: index == 1 ? now.addingTimeInterval(-86_400) : now)
            }
        }
        func ordered(_ date: Date) -> [String] {
            PantryMealMatcher.ranked(reviews, feedback: workspace.mealFeedbackSignals(owner: "A", at: date)).map(\.recipe.title)
        }
        XCTAssertEqual(ordered(now), ["Favorite", "Untried", "Second favorite"])
        XCTAssertEqual(ordered(now.addingTimeInterval(91 * 86_400)), ["Untried", "Second favorite", "Favorite"])
        let favorite = source(recipes[2])
        try workspace.updateMealFeedback(for: favorite, owner: "A", expectedRevision: workspace.feedback(for: favorite, owner: "A")?.revision,
                                         reactions: [.tooMuchEffort], at: now)
        XCTAssertEqual(ordered(now), ["Second favorite", "Untried", "Favorite"])
        try workspace.updateMealFeedback(for: favorite, owner: "A", expectedRevision: workspace.feedback(for: favorite, owner: "A")?.revision,
                                         reactions: [], at: now)
        XCTAssertEqual(ordered(now), ["Second favorite", "Untried", "Favorite"])
        XCTAssertEqual(workspace.mealTemplates, recipes)
    }
}
