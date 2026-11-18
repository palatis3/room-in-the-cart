import XCTest
@testable import CoreDomain

final class PantryMealMatcherTests: XCTestCase {
    private func quantity(_ count: Int64) throws -> Quantity {
        Quantity(amount: try Rational(count), unit: .count, originalLiteral: String(count))
    }
    private func lot(_ name: String, _ count: Int64, foodID: UUID, useFirst: Bool = false) throws -> ConfirmedStockLot {
        ConfirmedStockLot(id: UUID(), foodID: foodID, name: name, usable: try quantity(count),
                          confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), useFirst: useFirst)
    }

    func testUsesOnlyReviewedFoodAndNeverCountsTheSameLotTwice() throws {
        let beans = UUID()
        let early = try lot("Beans", 2, foodID: beans, useFirst: true)
        let other = try lot("Beans", 12, foodID: UUID(), useFirst: true)
        let first = MealIngredient(name: "Beans", quantity: try quantity(2))
        let second = MealIngredient(name: "Beans", quantity: try quantity(1))
        let sauce = MealIngredient(name: "Sauce", quantity: nil)
        let recipe = MealTemplate(title: "Beans on toast", ingredients: [first, second, sauce])
        let result = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [first.id: beans, second.id: beans],
            globallyFreeLots: [other, early], unresolvedFoods: [], profile: nil)
        XCTAssertTrue(result.ingredients[0].covered)
        XCTAssertEqual(result.ingredients[1].coverage?.shortfall, .one)
        XCTAssertNil(result.ingredients[2].coverage)
        XCTAssertEqual(result.useFirstLotIDs, [early.id])
        XCTAssertFalse(result.allIngredientsCovered)
    }

    func testPairingConsumesOnlyTheSelectedPhysicalBatchAndEveryOtherUsedLot() throws {
        let cabbage = UUID(), tortillas = UUID(), sauce = UUID()
        let old = try lot("Other cabbage", 1, foodID: cabbage, useFirst: true)
        let selected = ConfirmedStockLot(id: UUID(), foodID: cabbage, name: "Opened cabbage",
            usable: Quantity(amount: .one, unit: .kilogram, originalLiteral: "1 kg"), confirmedAt: old.confirmedAt, source: .pantry)
        let wraps = try lot("Unreserved tortillas", 2, foodID: tortillas)
        let half = Quantity(amount: try Rational(500), unit: .gram, originalLiteral: "500 g")
        let greens = MealIngredient(name: "Cabbage", quantity: half)
        let wrap = MealIngredient(name: "Tortilla", quantity: try quantity(1))
        let dressing = MealIngredient(name: "Sauce", quantity: try quantity(1))
        let first = MealTemplate(title: "Slaw wrap", ingredients: [greens, wrap])
        let second = MealTemplate(title: "Cabbage tacos", ingredients: [greens, wrap, dressing])
        // The same food in a different batch is eligible, and flagged for first use.
        let older = ConfirmedStockLot(id: old.id, foodID: cabbage, name: old.name, usable: selected.usable,
                                     confirmedAt: old.confirmedAt, useFirst: true)
        let stock = [older, selected, wraps]
        let bindings = [greens.id: cabbage, wrap.id: tortillas]
        let normal = try PantryMealMatcher.review(recipe: first, reviewedFoods: bindings, globallyFreeLots: stock,
                                                  unresolvedFoods: [], profile: nil)
        XCTAssertEqual(normal.useFirstLotIDs, [older.id])
        let plan = try PantryMealMatcher.review(recipe: first, reviewedFoods: bindings, globallyFreeLots: stock,
            unresolvedFoods: [], profile: nil, firstLotID: selected.id, projectRemainder: true)
        let remaining = try XCTUnwrap(plan.stockAfterMeal)
        XCTAssertTrue(plan.useFirstLotIDs.isEmpty)
        XCTAssertEqual(plan.batchUse?.used.amount, try Rational(1, 2))
        XCTAssertEqual(plan.batchUse?.remaining.unit, .kilogram)
        XCTAssertEqual(remaining.first { $0.id == wraps.id }?.usable.amount, .one)
        XCTAssertEqual(remaining.first { $0.id == older.id }, older)
        let follow = try PantryMealMatcher.review(recipe: second, reviewedFoods: bindings.merging([dressing.id: sauce]) { _, new in new },
            globallyFreeLots: remaining, unresolvedFoods: [], profile: nil, firstLotID: selected.id, projectRemainder: true)
        XCTAssertEqual(follow.batchUse?.remaining.amount, .zero)
        XCTAssertNil(follow.stockAfterMeal)
        XCTAssertEqual(follow.ingredients.filter { !$0.covered }.map(\.id), [dressing.id])
        XCTAssertEqual(follow.ingredients.last?.coverage?.shortfall, .one)
        let price = try TonightPurchaseEstimate.estimate(follow, workspace: LedgerWorkspace(), workspaceID: UUID(), shopID: nil, at: old.confirmedAt)
        XCTAssertFalse(price.complete)
        XCTAssertNil(price.subtotal)
        let origin = UUID(), shop = ShoppingLedger(title: "Corner store"), now = old.confirmedAt
        let access = DinnerAccessContext(scope: .local(workspaceID: origin), actorID: "shopper", shopID: shop.id,
            assignedShopperID: "shopper", canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 0,
            verifiedAt: now, validUntil: now.addingTimeInterval(60))
        let pack = PackOffer(id: "sauce-packets", label: "Eight sauce packets", usableQuantity: try quantity(8), price: Money(minorUnits: 249))
        var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "reviewed", template: second, createdAt: now)
        idea.supplyEvidence = [DinnerIdeaFoodEvidence(ingredient: dressing, workspaceID: origin, shopID: shop.id,
            basisRevision: shop.basisRevision, foodID: sauce, pack: pack, source: "Shelf label", observedAt: now)]
        var workspace = LedgerWorkspace(shops: [shop])
        try workspace.dinnerPlanning.saveIdea(idea, access: access, at: now)
        try workspace.dinnerPlanning.accept(.init(id: UUID(), template: second, acceptedAt: now, sourceIdeaID: idea.id),
                                           access: access, at: now)
        let groceries = try TonightPurchaseEstimate.estimate(follow, workspace: workspace, workspaceID: origin, shopID: shop.id, at: now)
        XCTAssertEqual(groceries.packages.map(\.count), [1])
        XCTAssertEqual(groceries.subtotal?.minorUnits, 249)
        XCTAssertTrue(groceries.complete)
        XCTAssertFalse(remaining.contains { $0.foodID == sauce })
        XCTAssertEqual(stock[1].usable.amount, .one)
        XCTAssertEqual(stock[2].usable.amount, try Rational(2))
        let uncertain = try PantryMealMatcher.review(recipe: first, reviewedFoods: bindings, globallyFreeLots: stock,
            unresolvedFoods: [tortillas], profile: nil, firstLotID: selected.id, projectRemainder: true)
        XCTAssertNil(uncertain.stockAfterMeal)
    }

    func testExclusionsApplyToActualFoodAndUnknownPreferencesBeforeCoverage() throws {
        let foodID = UUID()
        let ingredient = MealIngredient(name: "Sauce", quantity: try quantity(1), exclusions: ["peanut"])
        let recipe = MealTemplate(title: "Noodles", ingredients: [ingredient])
        let stock = try lot("Peanut sauce", 2, foodID: foodID, useFirst: true)
        let result = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [ingredient.id: foodID],
            globallyFreeLots: [stock], unresolvedFoods: [], profile: nil)
        XCTAssertEqual(result.eligibility.blocked, [.excluded("peanut")])
        XCTAssertTrue(result.useFirstLotIDs.isEmpty)
        var settings = MealPreferenceSettings()
        settings.availableAppliances = ["Stove"]
        let missingApplianceEvidence = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [:],
            globallyFreeLots: [], unresolvedFoods: [], profile: .init(settings: settings))
        XCTAssertEqual(missingApplianceEvidence.eligibility.unresolved, [.appliancesUnknown])
        XCTAssertFalse(missingApplianceEvidence.allIngredientsCovered)
    }

    func testUnresolvedStockAndUnmatchedIngredientsCannotEstablishFeasibility() throws {
        let foodID = UUID()
        let ingredient = MealIngredient(name: "Lime", quantity: try quantity(2))
        let recipe = MealTemplate(title: "Limes", ingredients: [ingredient])
        let stock = try lot("Lime", 2, foodID: foodID)
        for bindings in [[:], [ingredient.id: foodID]] {
            let review = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: bindings, globallyFreeLots: [stock],
                unresolvedFoods: [foodID], profile: nil)
            XCTAssertFalse(review.allIngredientsCovered)
            XCTAssertTrue(PantryMealMatcher.ranked([review]).isEmpty)
        }
        XCTAssertThrowsError(try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [UUID(): foodID],
            globallyFreeLots: [], unresolvedFoods: [], profile: nil))
    }
    func testRanksUseFirstThenCoverageAndReviewedEffortAndRemovesBlockedDinners() throws {
        let foodID = UUID()
        let ingredient = MealIngredient(name: "Beans", quantity: try quantity(1))
        let lot = try lot("Beans", 1, foodID: foodID)
        func review(_ title: String, effort: MealEffort?, useFirst: Bool = false, blocked: Bool = false) throws -> PantryMealMatcher.Review {
            var recipe = MealTemplate(title: title, ingredients: [ingredient])
            var evidence = MealEligibilityEvidence()
            evidence.effort = effort
            recipe.eligibilityEvidence = evidence
            var settings = MealPreferenceSettings()
            if blocked { settings.exclusions = ["Beans"] }
            let source = ConfirmedStockLot(id: lot.id, foodID: foodID, name: lot.name, usable: lot.usable,
                                          confirmedAt: lot.confirmedAt, useFirst: useFirst)
            return try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [ingredient.id: foodID],
                globallyFreeLots: [source], unresolvedFoods: [], profile: .init(settings: settings))
        }
        let candidates = try [
            review("Unknown time", effort: nil), review("More work", effort: .high),
            review("Use first", effort: .high, useFirst: true), review("Quick", effort: .low),
            review("Favorite with excluded ingredient", effort: .low, useFirst: true, blocked: true)
        ]
        XCTAssertEqual(PantryMealMatcher.ranked(candidates).map(\.recipe.title),
                       ["Use first", "Quick", "More work", "Unknown time"])
    }

}
