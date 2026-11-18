import Foundation

/// Reviews one possible dinner against the balances left after existing pantry reservations.
public enum PantryMealMatcher {
    public struct IngredientReview: Identifiable, Equatable, Sendable {
        public let ingredient: MealIngredient
        public let foodID: UUID?
        public let coverage: StockDemandCoverage?
        public let hasUnresolvedStock: Bool
        public var id: UUID { ingredient.id }
        public var hasConfirmedStock: Bool {
            guard !hasUnresolvedStock, let coverage, coverage.issues.isEmpty, let amount = coverage.allocated else { return false }
            return amount > .zero
        }
        public var covered: Bool {
            guard !hasUnresolvedStock, let coverage else { return false }
            return coverage.issues.isEmpty && coverage.allocated != nil && coverage.shortfall == .zero
        }
    }

    public struct Review: Identifiable, Equatable, Sendable {
        public let recipe: MealTemplate
        public var id: UUID { recipe.id }
        public let preferenceRevision: UUID?
        public let eligibility: MealEligibilityPolicy.Result
        public let ingredients: [IngredientReview]
        public let useFirstLotIDs: Set<UUID>
        public var hasConfirmedPantryFood: Bool { ingredients.contains(where: \.hasConfirmedStock) }
        public var allIngredientsCovered: Bool {
            eligibility.eligible && !ingredients.isEmpty && ingredients.allSatisfy(\.covered)
        }
    }

    /// A food is matched only after review. Similar words alone cannot claim a lot.
    /// Passing all matched needs to one allocation keeps repeated ingredients from
    /// each receiving the same remaining stock.
    public static func review(recipe: MealTemplate, reviewedFoods: [UUID: UUID],
                              globallyFreeLots: [ConfirmedStockLot], unresolvedFoods: Set<UUID>,
                              profile: MealPreferenceProfile?, foodEvidence: [UUID: MealEligibilityEvidence] = [:]) throws -> Review {
        try recipe.validate()
        try profile?.settings.validate()
        var eligibility = MealEligibilityPolicy.evaluate(profile: profile, template: recipe)
        guard eligibility.eligible else {
            return Review(recipe: recipe, preferenceRevision: profile?.revision, eligibility: eligibility, ingredients: [], useFirstLotIDs: [])
        }
        let ingredientIDs = Set(recipe.ingredients.map(\.id))
        guard Set(reviewedFoods.keys).isSubset(of: ingredientIDs) else { throw DinnerPlanningError.stalePreview }
        let needs = recipe.ingredients.compactMap { ingredient -> StockNeed? in
            guard let foodID = reviewedFoods[ingredient.id], let amount = ingredient.quantity else { return nil }
            return StockNeed(id: ingredient.id, foodID: foodID, name: ingredient.name, amount: amount, priority: .required)
        }
        let matchedFoods = Set(reviewedFoods.values)
        let lots = globallyFreeLots.filter { matchedFoods.contains($0.foodID) }
        // A reviewed identity still has to respect exclusions on the recipe and
        // ingredient. Use the same product-label check as the shopping ledger.
        let labelsByFood = Dictionary(grouping: lots, by: \.foodID)
        for ingredient in recipe.ingredients {
            guard let foodID = reviewedFoods[ingredient.id] else { continue }
            let lotsForFood = labelsByFood[foodID] ?? []
            for lot in lotsForFood {
                do {
                    try permittedProduct(lot.name, exclusions: recipe.exclusions + ingredient.exclusions)
                } catch LedgerError.excludedIngredient(let term) {
                    eligibility.blocked.append(.excluded(term))
                }
            }
        }
        for (foodID, foodLots) in labelsByFood {
            let evidence = foodEvidence[foodID]
            try evidence?.validate()
            let food = MealEligibilityPolicy.evaluateFood(profile: profile, labels: foodLots.map(\.name), evidence: evidence)
            for issue in food.blocked where !eligibility.blocked.contains(issue) { eligibility.blocked.append(issue) }
            for issue in food.unresolved where !eligibility.unresolved.contains(issue) { eligibility.unresolved.append(issue) }
            for issue in food.softDifferences where !eligibility.softDifferences.contains(issue) { eligibility.softDifferences.append(issue) }
        }
        guard eligibility.eligible else {
            return Review(recipe: recipe, preferenceRevision: profile?.revision, eligibility: eligibility, ingredients: [], useFirstLotIDs: [])
        }
        let allocation = try ConfirmedStockAllocator.allocate(lots: lots, needs: needs)
        let demandByID = Dictionary(uniqueKeysWithValues: allocation.demands.map { ($0.id, $0) })
        let reviews = recipe.ingredients.map { ingredient in
            let food = reviewedFoods[ingredient.id]
            return IngredientReview(ingredient: ingredient, foodID: food, coverage: demandByID[ingredient.id],
                                    hasUnresolvedStock: food.map(unresolvedFoods.contains) ?? false)
        }
        let useFirst = Set(lots.filter { $0.useFirst == true }.map(\.id))
        let supported = Set(reviews.filter { !$0.hasUnresolvedStock && $0.coverage?.issues.isEmpty == true }.map(\.id))
        let used = Set(allocation.allocations.filter { $0.amount > .zero && supported.contains($0.needID) }.map(\.lotID))
        return Review(recipe: recipe, preferenceRevision: profile?.revision, eligibility: eligibility, ingredients: reviews, useFirstLotIDs: useFirst.intersection(used))
    }

    /// Use the library order for ties. Unknown effort sorts after reviewed effort.
    public static func ranked(_ reviews: [Review]) -> [Review] {
        let eligible = reviews.filter { $0.eligibility.eligible && $0.hasConfirmedPantryFood }
        let scored = eligible.enumerated().map { entry in
            (review: entry.element, index: entry.offset,
             covered: entry.element.ingredients.filter(\.covered).count)
        }
        return scored.sorted { lhs, rhs in
            let left = lhs.review, right = rhs.review
            if left.useFirstLotIDs.isEmpty != right.useFirstLotIDs.isEmpty { return !left.useFirstLotIDs.isEmpty }
            if left.allIngredientsCovered != right.allIngredientsCovered { return left.allIngredientsCovered }
            // Compare proportions without rounding or favoring recipes with more rows.
            let leftCoverage = lhs.covered * max(1, right.ingredients.count)
            let rightCoverage = rhs.covered * max(1, left.ingredients.count)
            if leftCoverage != rightCoverage { return leftCoverage > rightCoverage }
            if left.eligibility.softDifferences.count != right.eligibility.softDifferences.count {
                return left.eligibility.softDifferences.count < right.eligibility.softDifferences.count
            }
            let leftEffort = left.recipe.eligibilityEvidence?.effort?.rank ?? Int.max
            let rightEffort = right.recipe.eligibilityEvidence?.effort?.rank ?? Int.max
            if leftEffort != rightEffort { return leftEffort < rightEffort }
            return lhs.index < rhs.index
        }.map(\.review)
    }
}
