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
    func testPlanTomorrowThenMoveToTonightForTwoKeepsTemplateAndGroceryFactsAcrossRestore() throws {
        var template = recipe
        template.servings = try Rational(4)
        var data = LedgerWorkspace(shops: [shop], mealTemplates: [template], selectedShopID: shop.id)
        let zone = shop.basis.timeZoneIdentifier
        let today = try MealDay(date: now, timeZoneIdentifier: zone)
        let tomorrow = try MealDay(date: now.addingTimeInterval(86400), timeZoneIdentifier: zone)
        let initial = try SavedDinnerReview(recipe: template, action: .plan(day: tomorrow, servings: template.servings),
            workspace: data, access: access, phase: .draft, at: now)
        try initial.apply(to: &data, access: access, phase: .draft, at: now)
        let original = try XCTUnwrap(data.shops[0].mealOccurrences.first)
        XCTAssertEqual(original.scheduledDay, tomorrow)
        let sources = data.shops[0].contributions
        let adjustment = DinnerAdjustment(occurrenceID: original.id, servings: try Rational(2),
            groups: original.servingGroups, quantities: [], scheduledDay: today)
        let preview = try DinnerPlanningEngine.preview(changes: [.adjust(adjustment)], tool: .manual,
            ledger: data.shops[0], state: data.dinnerPlanning, access: access, phase: .draft, at: now)
        XCTAssertEqual(preview.unchangedGroceriesForScheduleEdit(in: data, workspaceID: workspaceID)?.id, original.id)
        XCTAssertNil(preview.unchangedGroceriesForScheduleEdit(in: data, workspaceID: UUID()))
        var stale = data
        _ = try stale.shops[0].addManualLine(name: "Coffee", quantity: nil)
        XCTAssertNil(preview.unchangedGroceriesForScheduleEdit(in: stale, workspaceID: workspaceID))
        let changed = DinnerAdjustment(occurrenceID: original.id, servings: try Rational(2), groups: [],
            quantities: [.init(contributionID: original.ingredientContributionIDs[0],
                quantity: .init(amount: try Rational(3), unit: .count, originalLiteral: "3"))], scheduledDay: today)
        let foodPreview = try DinnerPlanningEngine.preview(changes: [.adjust(changed)], tool: .manual, ledger: data.shops[0],
            state: data.dinnerPlanning, access: access, phase: .draft, at: now)
        XCTAssertNil(foodPreview.unchangedGroceriesForScheduleEdit(in: data, workspaceID: workspaceID))
        XCTAssertTrue(foodPreview.reviewsGuestPurchases)
        _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &data.shops[0], state: &data.dinnerPlanning,
            access: access, phase: .draft, at: now)
        let restored = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(restored.mealTemplates, [template])
        XCTAssertEqual(restored.shops[0].mealOccurrences.count, 1)
        let planned = try XCTUnwrap(restored.shops[0].mealOccurrences.first)
        XCTAssertEqual(planned.id, original.id)
        XCTAssertEqual(planned.servings, try Rational(2))
        XCTAssertEqual(planned.scheduledDay, today)
        XCTAssertEqual(restored.shops[0].contributions, sources)
        XCTAssertEqual(restored.shops[0].contributions.last?.checkedWithoutAmount, true)
    }

    func testReviewedPlanYieldDoesNotChangeTheRecipeOrImplyScaledGroceries() throws {
        var data = workspace
        let tomorrow = try MealDay(date: now.addingTimeInterval(86400), timeZoneIdentifier: shop.basis.timeZoneIdentifier)
        let review = try SavedDinnerReview(recipe: recipe, action: .plan(day: tomorrow, servings: try Rational(4)),
            workspace: data, access: access, phase: .draft, at: now)
        try review.apply(to: &data, access: access, phase: .draft, at: now)
        XCTAssertEqual(data.shops[0].mealOccurrences.first?.servings, try Rational(4))
        XCTAssertEqual(data.mealTemplates, [recipe])
        XCTAssertEqual(data.shops[0].contributions.map(\.quantity), recipe.ingredients.map(\.quantity))
        XCTAssertEqual(data.shops[0].mealOccurrences.first?.scheduledDay, tomorrow)
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
    func testChangedActorOrWorkspaceCannotApplyReviewedGroceriesOrReplayAReceipt() throws {
        var data = workspace
        let review = try SavedDinnerReview(recipe: recipe, action: .groceries([recipe.ingredients[0].id]), workspace: data,
                                           access: access, phase: .draft, at: now)
        let changed = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "other", shopID: shop.id, assignedShopperID: "other",
            canPlan: true, canReadBudget: false, hasPaidTools: true, roleRevision: 1, verifiedAt: now, validUntil: now.addingTimeInterval(120))
        XCTAssertThrowsError(try review.apply(to: &data, access: changed, phase: .draft, at: now))
        XCTAssertTrue(data.shops[0].lines.isEmpty)
        try review.apply(to: &data, access: access, phase: .draft, at: now)
        let saved = data
        XCTAssertThrowsError(try review.apply(to: &data, access: changed, phase: .draft, at: now))
        XCTAssertEqual(data, saved)
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
