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

extension SavedDinnerReviewTests {
    func testTwoNightsPlusManualItemRestoreReplayAndRemoveOneNight() throws {
        let cilantro = MealIngredient(name: "Cilantro", quantity: .init(amount: .one, unit: .count, originalLiteral: "1 bunch"))
        let wine = MealIngredient(name: "Wine", quantity: .init(amount: .one, unit: .count, originalLiteral: "1 bottle"), notes: "Wine pairing")
        let tacos = MealTemplate(title: "Tacos", ingredients: [cilantro, wine])
        var data = LedgerWorkspace(shops: [shop], mealTemplates: [tacos], selectedShopID: shop.id)
        let manual = try data.shops[0].addManualLine(name: cilantro.name, quantity: cilantro.quantity)
        let restricted = try data.shops[0].addManualLine(name: cilantro.name, quantity: cilantro.quantity, exclusions: ["different requirement"])
        let mass = try data.shops[0].addManualLine(name: cilantro.name,
            quantity: .init(amount: .one, unit: .gram, originalLiteral: "1 g"))
        let box = try data.shops[0].addManualLine(name: cilantro.name,
            quantity: .init(amount: .one, unit: .count, originalLiteral: "1 box"))
        func review(_ date: Date) throws -> SavedDinnerReview {
            try SavedDinnerReview(recipe: tacos,
                action: .plan(day: MealDay(date: date, timeZoneIdentifier: shop.basis.timeZoneIdentifier), servings: .one),
                workspace: data, access: access, phase: .draft, at: now)
        }
        let first = try review(now)
        XCTAssertEqual(first.receipt.changes.map(\.name), [cilantro.name])
        XCTAssertEqual(first.receipt.changes.first?.before?.amount, .one)
        try first.apply(to: &data, access: access, phase: .draft, at: now)
        let second = try review(now.addingTimeInterval(86400))
        XCTAssertEqual(second.receipt.changes.first?.before?.amount, try Rational(2))
        XCTAssertEqual(second.receipt.changes.first?.after?.amount, try Rational(3))
        try second.apply(to: &data, access: access, phase: .draft, at: now)
        data = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(data.shops[0].revisions.last?.savedDinnerReceipt, second.receipt)
        try second.apply(to: &data, access: access, phase: .draft, at: now)
        XCTAssertEqual(try data.shops[0].quantity(forLineID: manual)?.amount, try Rational(3))
        try data.shops[0].removeMeal(occurrenceID: XCTUnwrap(first.occurrenceID), at: now)
        XCTAssertEqual(try data.shops[0].quantity(forLineID: manual)?.amount, try Rational(2))
        XCTAssertEqual(try data.shops[0].quantity(forLineID: restricted)?.amount, .one)
        XCTAssertEqual(try data.shops[0].quantity(forLineID: mass)?.unit, .gram)
        XCTAssertEqual(try data.shops[0].quantity(forLineID: box)?.amount, .one)
        XCTAssertFalse(data.shops[0].lines.contains { $0.name == wine.name })
        XCTAssertEqual(data.mealTemplates, [tacos])
        try data.validate()
    }

    func testReviewedOptionalChoiceAppliesToOneOccurrenceAndCanBeRememberedWithoutEditingSource() throws {
        let oil = MealIngredient(name: "Aceite", quantity: .init(amount: .one, unit: .cup, originalLiteral: "1"))
        let wine = MealIngredient(name: "Vino (opcional)", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"))
        let bread = MealIngredient(name: "Pan", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"))
        var dinner = MealTemplate(title: "Cena", ingredients: [oil, wine, bread])
        dinner.recipeSteps = [.init("Agregar pan", ingredientIndices: [2])]
        var data = LedgerWorkspace(shops: [shop], mealTemplates: [dinner], selectedShopID: shop.id)
        XCTAssertTrue(wine.suggestedShoppingExtra)
        let review = try SavedDinnerReview(recipe: dinner, action: .planTonight, workspace: data,
            access: access, phase: .draft, at: now, omittedIngredientIDs: [bread.id], rememberChoices: true)
        try review.apply(to: &data, access: access, phase: .draft, at: now)
        let latest = try XCTUnwrap(data.shops[0].revisions.last?.savedDinnerReceipt)
        XCTAssertEqual(latest.rememberedOmissions, [bread.id])
        XCTAssertEqual(latest.changes.map(\.name), [oil.name, wine.name])
        XCTAssertEqual(data.shops[0].mealOccurrences.first?.recipeSteps?.first?.ingredientIndices, [])
        XCTAssertEqual(data.mealTemplates, [dinner])
        let planOnly = try SavedDinnerReview(recipe: dinner, action: .planTonight, workspace: data, access: access,
            phase: .draft, at: now, omittedIngredientIDs: Set(dinner.ingredients.map(\.id)))
        try planOnly.apply(to: &data, access: access, phase: .draft, at: now)
        XCTAssertTrue(planOnly.receipt.changes.isEmpty)
        XCTAssertEqual(data.shops[0].mealOccurrences.last?.ingredientContributionIDs, [])
        try data.validate()
    }

    func testReviewedStepPortionsPreserveExactTotalsAcrossResizingAndCommaInput() throws {
        let total = try ListQuantityParser.numericAmount("4,0")
        let byStep = [0: try ListQuantityParser.numericAmount("3"), 1: try ListQuantityParser.numericAmount("1")]
        var amounts = CookingStepAmounts(recipeServings: total, cookingServings: try Rational(2), allocations: [
            .init(ingredient: 0, originalAmount: total, unit: .tablespoons, byStep: byStep)
        ])
        try amounts.validate(stepCount: 2, ingredientCount: 1)
        XCTAssertEqual(try amounts.scaled(byStep[0]!), try ListQuantityParser.numericAmount("1,5"))
        XCTAssertEqual(try amounts.scaled(byStep[1]!), try ListQuantityParser.numericAmount("1/2"))
        for servings in [total, try Rational(1), try Rational(6), try Rational(2)] {
            amounts.cookingServings = servings
            let sum = try byStep.values.reduce(Rational.zero) { try $0.adding(amounts.scaled($1)) }
            XCTAssertEqual(sum, try amounts.scaled(total))
        }
        let invalid = CookingStepAmounts(recipeServings: total, cookingServings: .one, allocations: [
            .init(ingredient: 0, originalAmount: total, unit: .tablespoons, byStep: [0: .one])
        ])
        XCTAssertThrowsError(try invalid.validate(stepCount: 2, ingredientCount: 1))
        XCTAssertThrowsError(try amounts.validate(stepCount: 1, ingredientCount: 1))
    }
}
