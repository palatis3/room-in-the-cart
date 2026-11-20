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

    public struct BatchUse: Equatable, Sendable {
        public let lotID: UUID
        public let used: Quantity
        public let remaining: Quantity
    }

    public struct Review: Identifiable, Equatable, Sendable {
        public let recipe: MealTemplate
        public var id: UUID { recipe.id }
        public let preferenceRevision: UUID?
        public let eligibility: MealEligibilityPolicy.Result
        public let ingredients: [IngredientReview]
        public let useFirstLotIDs: Set<UUID>
        public let batchUse: BatchUse?
        /// Original unreserved lots after this recipe's reviewed allocations. Available
        /// only for a focused batch with a remainder and reliable ingredient amounts.
        public fileprivate(set) var stockAfterMeal: [ConfirmedStockLot]?
        public var canProjectRemainder: Bool {
            guard let use = batchUse, use.remaining.amount > .zero else { return false }
            return numericIngredients.allSatisfy { $0.ingredient.quantity != nil && !$0.hasUnresolvedStock && ($0.coverage?.issues.isEmpty ?? true) }
        }
        public var numericIngredients: [IngredientReview] { ingredients.filter { $0.ingredient.checkedWithoutAmount != true } }
        public var measuredIngredientsCovered: Bool {
            eligibility.eligible && !numericIngredients.isEmpty && numericIngredients.allSatisfy(\.covered)
        }
        public var hasHandCheckedIngredients: Bool { recipe.ingredients.contains { $0.checkedWithoutAmount == true } }
        public var canChooseUsingPantry: Bool {
            eligibility.eligible && hasConfirmedPantryFood && !recipe.ingredients.isEmpty &&
                recipe.ingredients.allSatisfy { ($0.quantity?.amount ?? .zero) > .zero || $0.checkedWithoutAmount == true } &&
                numericIngredients.allSatisfy { !$0.hasUnresolvedStock && ($0.coverage?.issues.isEmpty ?? true) }
        }
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
                              profile: MealPreferenceProfile?, foodEvidence: [UUID: MealEligibilityEvidence] = [:],
                              firstLotID: UUID? = nil, projectRemainder: Bool = false) throws -> Review {
        try recipe.validate()
        try profile?.settings.validate()
        var eligibility = MealEligibilityPolicy.evaluate(profile: profile, template: recipe)
        guard eligibility.eligible else {
            return Review(recipe: recipe, preferenceRevision: profile?.revision, eligibility: eligibility, ingredients: [], useFirstLotIDs: [], batchUse: nil, stockAfterMeal: nil)
        }
        let ingredientIDs = Set(recipe.ingredients.map(\.id))
        guard Set(reviewedFoods.keys).isSubset(of: ingredientIDs) else { throw DinnerPlanningError.stalePreview }
        let needs = recipe.ingredients.compactMap { ingredient -> StockNeed? in
            guard let foodID = reviewedFoods[ingredient.id], let amount = ingredient.quantity else { return nil }
            return StockNeed(id: ingredient.id, foodID: foodID, name: ingredient.name, amount: amount, priority: .required)
        }
        let matchedFoods = Set(recipe.ingredients.filter { $0.checkedWithoutAmount != true }.compactMap { reviewedFoods[$0.id] })
        let lots = globallyFreeLots.filter { matchedFoods.contains($0.foodID) }
        // A reviewed identity still has to respect exclusions on the recipe and
        // ingredient. Use the same product-label check as the shopping ledger.
        let labelsByFood = Dictionary(grouping: lots, by: \.foodID)
        for ingredient in recipe.ingredients where ingredient.checkedWithoutAmount != true {
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
            return Review(recipe: recipe, preferenceRevision: profile?.revision, eligibility: eligibility, ingredients: [], useFirstLotIDs: [], batchUse: nil, stockAfterMeal: nil)
        }
        let allocation = try ConfirmedStockAllocator.allocate(lots: lots, needs: needs, firstLotID: firstLotID)
        let demandByID = Dictionary(uniqueKeysWithValues: allocation.demands.map { ($0.id, $0) })
        let reviews = recipe.ingredients.map { ingredient in
            let food = ingredient.checkedWithoutAmount == true ? nil : reviewedFoods[ingredient.id]
            return IngredientReview(ingredient: ingredient, foodID: food, coverage: demandByID[ingredient.id],
                                    hasUnresolvedStock: food.map(unresolvedFoods.contains) ?? false)
        }
        let useFirst = Set(lots.filter { $0.useFirst == true }.map(\.id))
        let supported = Set(reviews.filter { !$0.hasUnresolvedStock && $0.coverage?.issues.isEmpty == true }.map(\.id))
        let used = Set(allocation.allocations.filter { $0.amount > .zero && supported.contains($0.needID) }.map(\.lotID))
        guard let firstLotID, used.contains(firstLotID), let lot = lots.first(where: { $0.id == firstLotID }) else {
            return Review(recipe: recipe, preferenceRevision: profile?.revision, eligibility: eligibility, ingredients: reviews,
                          useFirstLotIDs: useFirst.intersection(used), batchUse: nil, stockAfterMeal: nil)
        }
        let balances = Dictionary(uniqueKeysWithValues: allocation.remainingLots.map { ($0.lotID, $0) })
        func residual(_ lot: ConfirmedStockLot) throws -> Quantity? {
            guard let balance = balances[lot.id], balance.issues.isEmpty else { return nil }
            let normalized = Quantity(amount: balance.remainingUnallocated, unit: balance.unit,
                                      originalLiteral: balance.remainingUnallocated.description)
            guard let amount = try normalized.converted(to: lot.usable.unit, using: lot.usable.confirmedConversion) else { return nil }
            return Quantity(amount: amount, unit: lot.usable.unit, originalLiteral: amount.description,
                            confirmedConversion: lot.usable.confirmedConversion)
        }
        let batchUse = try residual(lot).map { remaining in
            let amount = try lot.usable.amount.subtracting(remaining.amount)
            return BatchUse(lotID: firstLotID,
                used: Quantity(amount: amount, unit: lot.usable.unit, originalLiteral: amount.description),
                remaining: remaining)
        }
        var result = Review(recipe: recipe, preferenceRevision: profile?.revision, eligibility: eligibility, ingredients: reviews,
                            useFirstLotIDs: useFirst.intersection(used), batchUse: batchUse, stockAfterMeal: nil)
        if projectRemainder && result.canProjectRemainder {
            result.stockAfterMeal = try globallyFreeLots.compactMap { original in
                guard used.contains(original.id) else { return original }
                guard let quantity = try residual(original) else { throw DinnerPlanningError.stalePreview }
                guard quantity.amount > .zero else { return nil }
                return ConfirmedStockLot(id: original.id, foodID: original.foodID, name: original.name,
                    usable: quantity, confirmedAt: original.confirmedAt, source: original.source, useFirst: original.useFirst == true)
            }
        }
        return result
    }

    /// Use the library order for ties. Unknown effort sorts after reviewed effort.
    public static func ranked(_ reviews: [Review], feedback: [MealFeedbackSource: MealFeedbackSignal] = [:]) -> [Review] {
        let eligible = reviews.filter { $0.eligibility.eligible && $0.hasConfirmedPantryFood }
        let scored = eligible.enumerated().map { entry in
            (review: entry.element, index: entry.offset,
             covered: entry.element.ingredients.filter(\.covered).count)
        }
        let ordered = scored.sorted { lhs, rhs in
            let left = lhs.review, right = rhs.review
            if left.useFirstLotIDs.isEmpty != right.useFirstLotIDs.isEmpty { return !left.useFirstLotIDs.isEmpty }
            if left.measuredIngredientsCovered != right.measuredIngredientsCovered { return left.measuredIngredientsCovered }
            // Compare proportions without rounding or favoring recipes with more rows.
            let leftCoverage = lhs.covered * max(1, right.numericIngredients.count)
            let rightCoverage = rhs.covered * max(1, left.numericIngredients.count)
            if leftCoverage != rightCoverage { return leftCoverage > rightCoverage }
            if left.eligibility.softDifferences.count != right.eligibility.softDifferences.count {
                return left.eligibility.softDifferences.count < right.eligibility.softDifferences.count
            }
            let leftEffort = left.recipe.eligibilityEvidence?.effort?.rank ?? Int.max
            let rightEffort = right.recipe.eligibilityEvidence?.effort?.rank ?? Int.max
            if leftEffort != rightEffort { return leftEffort < rightEffort }
            return lhs.index < rhs.index
        }
        guard !feedback.isEmpty else { return ordered.map(\.review) }

        // Only recipes with the same supply, preference and effort evidence can change order.
        func canTie(_ a: Review, _ b: Review) -> Bool {
            guard a.useFirstLotIDs.isEmpty == b.useFirstLotIDs.isEmpty,
                  a.measuredIngredientsCovered == b.measuredIngredientsCovered else { return false }
            let leftCoverage: Int = a.ingredients.filter(\.covered).count * max(1, b.numericIngredients.count)
            let rightCoverage: Int = b.ingredients.filter(\.covered).count * max(1, a.numericIngredients.count)
            guard leftCoverage == rightCoverage,
                  a.eligibility.softDifferences.count == b.eligibility.softDifferences.count else { return false }
            return a.recipe.eligibilityEvidence?.effort == b.recipe.eligibilityEvidence?.effort
        }
        func feasible(_ review: Review) -> Bool {
            review.numericIngredients.allSatisfy { !$0.hasUnresolvedStock && $0.ingredient.quantity != nil && ($0.coverage?.issues.isEmpty ?? true) }
        }
        var result: [Review] = []
        var start = 0
        while start < ordered.count {
            let first = ordered[start].review
            var end = start + 1
            if feasible(first) {
                while end < ordered.count && feasible(ordered[end].review) && canTie(first, ordered[end].review) { end += 1 }
            }
            var group = ordered[start..<end].map { row in
                (review: row.review, index: row.index,
                 signal: feedback[.recipe(id: row.review.id, revision: row.review.recipe.revision)])
            }.sorted { a, b in
                let left = a.signal?.score ?? 0, right = b.signal?.score ?? 0
                return left == right ? a.index < b.index : left > right
            }
            // Keep an untried meal in the first two of an otherwise equivalent group.
            if let unseen = group.firstIndex(where: { $0.signal == nil }), unseen > 1 {
                let discovery = group.remove(at: unseen)
                group.insert(discovery, at: 1)
            }
            result.append(contentsOf: group.map(\.review))
            start = end
        }
        return result
    }
}
