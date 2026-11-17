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
