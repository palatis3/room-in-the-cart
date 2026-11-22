import Foundation

/// A read-only shopping estimate for one original dinner, based on its current
/// contributions. A pantry match here is never a purchase or a reservation.
public struct DinnerShoppingCheck {
    public let recipe: MealTemplate
    public let lineIDs: Set<UUID>
    private let shopID: UUID

    public init(shop: ShoppingLedger, occurrenceID: UUID, savedTemplates: [MealTemplate]) throws {
        guard let meal = shop.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }),
              !meal.isHidden, meal.carryover == nil else { throw DinnerPlanningError.stalePreview }
        let sources = Dictionary(grouping: shop.contributions, by: \.id)
        let rows = try meal.ingredientContributionIDs.map { id -> LedgerContribution in
            guard let candidates = sources[id], candidates.count == 1, let row = candidates.first, row.source == .meal(occurrenceID: meal.id),
                  row.removedAt == nil else { throw DinnerPlanningError.stalePreview }
            return row
        }
        let ingredients = rows.map { row in
            MealIngredient(id: row.id, name: row.productName, quantity: row.quantity, notes: row.notes,
                exclusions: row.exclusions, checkedWithoutAmount: row.checkedWithoutAmount == true)
        }
        var current = MealTemplate(id: meal.id, title: meal.title, servings: meal.servings,
            ingredients: ingredients, exclusions: meal.exclusions, leadTimeMinutes: meal.leadTimeMinutes)
        let originals = savedTemplates.filter { $0.id == meal.templateID && $0.revision == meal.templateRevision }
        if let original = originals.first, originals.allSatisfy({ $0 == original }),
           original.ingredients.map(\.name) == ingredients.map(\.name) {
            current.eligibilityEvidence = original.eligibilityEvidence
        }
        try current.validate()
        shopID = shop.id
        recipe = current
        lineIDs = Set(rows.map(\.lineID))
    }

    /// Ledger-only meal and lunch commitments may precede physical allocation.
    /// Until their checkout is current, that product's free balance is uncertain.
    public func foodsAwaitingAllocation(in shops: [ShoppingLedger], matched: Set<UUID>,
                                        currentCheckoutLines: [UUID: Set<UUID>]) -> Set<UUID> {
        guard !matched.isEmpty else { return [] }
        var uncertain = Set<UUID>()
        for shop in shops {
            let open = Set(shop.lines.lazy.filter { matched.contains($0.id) && !$0.isTrashed && !$0.isHandled }.map(\.id))
                .subtracting(currentCheckoutLines[shop.id] ?? [])
            guard !open.isEmpty else { continue }
            for source in shop.contributions where open.contains(source.lineID) && source.removedAt == nil {
                if source.source.isProtected || (source.source.isMeal && (shop.id != shopID || source.source != .meal(occurrenceID: recipe.id))) {
                    uncertain.insert(source.lineID)
                }
            }
        }
        return uncertain
    }

    public enum Remainder: Equatable {
        case covered, buy(Quantity), checkAmount
    }

    public static func remainder(_ row: PantryMealMatcher.IngredientReview) -> Remainder {
        guard let required = row.ingredient.quantity else { return .checkAmount }
        if required.amount == .zero { return .covered }
        guard !row.hasUnresolvedStock else { return .checkAmount }
        guard let coverage = row.coverage else { return .buy(required) }
        guard coverage.issues.isEmpty, coverage.allocated != nil, let shortfall = coverage.shortfall else { return .checkAmount }
        if shortfall == .zero { return .covered }
        let remaining = Quantity(amount: shortfall, unit: coverage.unit, originalLiteral: shortfall.description)
        if let originalAmount = try? remaining.converted(to: required.unit, using: required.confirmedConversion) {
            return .buy(Quantity(amount: originalAmount, unit: required.unit, originalLiteral: originalAmount.description))
        }
        return .buy(remaining)
    }
}

/// Allocate a fresh shopping identity only for an explicitly matched, fully
/// covered ingredient. The canonical checkout allocator identifies food by
/// shopping line ID. Reusing any existing line here could claim someone else's
/// purchase, import history or meal, so an ambiguous match rejects the review.
public struct DinnerPantryProducts: Codable, Equatable, Sendable {
    /// The existing pack format retains offer IDs on export and undo. This
    /// allows an orphaned choice to fail closed if its dinner receipt is absent.
    public static let atHomeOfferID = "dinner-at-home-v1"
    public static let alternateOfferID = "dinner-at-home-review-v1"
    public let originID: UUID
    public let matches: [UUID: UUID]

    public init(review: PantryMealMatcher.Review, workspace: LedgerWorkspace, originID: UUID) throws {
        guard review.eligibility.eligible,
              review.preferenceRevision == workspace.dinnerPlanning.privateMealPreferences?.revision
        else { throw DinnerPlanningError.stalePreview }
        var matches = [UUID: UUID]()
        for row in review.ingredients where row.foodID != nil {
            guard let food = row.foodID, row.covered, let required = row.ingredient.quantity,
                  required.amount > .zero else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
            matches[row.id] = food
        }
        guard !matches.isEmpty, Set(matches.values).count == matches.count
        else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
        self.originID = originID
        self.matches = matches
        try verifyNewLines(in: workspace)
    }

    private struct Binding: Codable {
        let ingredientID: UUID
        let foodID: UUID
    }
    private enum CodingKeys: String, CodingKey { case originID, matches }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        originID = try values.decode(UUID.self, forKey: .originID)
        let entries = try values.decode([Binding].self, forKey: .matches)
        guard !entries.isEmpty, Set(entries.map(\.ingredientID)).count == entries.count,
              Set(entries.map(\.foodID)).count == entries.count else { throw DinnerPlanningError.invalid("pantryProduct") }
        matches = Dictionary(uniqueKeysWithValues: entries.map { ($0.ingredientID, $0.foodID) })
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(originID, forKey: .originID)
        let ordered = matches.sorted { $0.key.uuidString < $1.key.uuidString }
        try values.encode(ordered.map { Binding(ingredientID: $0.key, foodID: $0.value) }, forKey: .matches)
    }

    public func verifyNewLines(in workspace: LedgerWorkspace) throws {
        let ids = Set(matches.values)
        guard workspace.shops.allSatisfy({ shop in
            shop.lines.allSatisfy { !ids.contains($0.id) }
        }) else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
    }

    func lineIDs(for recipe: MealTemplate) -> [UUID] {
        recipe.ingredients.map { matches[$0.id] ?? UUID() }
    }
}

extension LedgerWorkspace {
    /// Only the local planner can act on the exact, untouched contributions
    /// recorded by their reviewed dinner. Later merges and edits require review.
    public func dinnerPantryLines(shop: ShoppingLedger, workspaceID: UUID, originID: UUID, actorID: String,
                                 occurrenceID: UUID? = nil) -> Set<UUID> {
        let plans = dinnerPlanning.applyReceipts.compactMap { receipt -> PlannedDinner? in
            let proposal = receipt.proposal
            guard proposal.shopID == shop.id, proposal.namespace == "local:\(workspaceID.uuidString)",
                  proposal.authorID == actorID, proposal.preferenceRevision == dinnerPlanning.privateMealPreferences?.revision,
                  proposal.changes.count == 1, case .choose(let planned) = proposal.changes[0],
                  planned.pantryProducts?.originID == originID, occurrenceID == nil || planned.occurrenceID == occurrenceID
            else { return nil }
            return planned
        }
        guard !plans.isEmpty else { return [] }
        let otherLines = Set(shops.filter { $0.id != shop.id }.flatMap { $0.lines.filter { !$0.isHandled && !$0.isTrashed }.map(\.id) })
        let lines = Dictionary(uniqueKeysWithValues: shop.lines.map { ($0.id, $0) })
        let sources = Dictionary(grouping: shop.contributions.filter { $0.removedAt == nil }, by: \.lineID)
        let meals = Dictionary(uniqueKeysWithValues: shop.mealOccurrences.map { ($0.id, $0) })
        var result = Set<UUID>()
        for planned in plans {
            guard let products = planned.pantryProducts, let meal = meals[planned.occurrenceID],
                  !meal.isHidden, meal.removedAt == nil, meal.carryover == nil,
                  planned.template.ingredients.count == planned.contributionIDs.count,
                  planned.lineIDs.count == planned.contributionIDs.count,
                  meal.ingredientContributionIDs == planned.contributionIDs else { continue }
            for (index, ingredient) in planned.template.ingredients.enumerated() {
                guard let product = products.matches[ingredient.id], planned.lineIDs[index] == product,
                      !otherLines.contains(product), let line = lines[product], !line.isChecked, !line.isHandled, !line.isTrashed,
                      line.tripPick == nil, line.packagePick == nil, line.stopObservation == nil,
                      line.name == ingredient.name, line.notes == ingredient.notes,
                      let active = sources[product], active.count == 1, let source = active.first,
                      source.id == planned.contributionIDs[index], source.source == .meal(occurrenceID: meal.id),
                      source.quantity == ingredient.quantity, source.productName == ingredient.name,
                      source.exclusions == planned.template.exclusions + ingredient.exclusions, source.notes == ingredient.notes
                else { continue }
                result.insert(product)
            }
        }
        return result
    }
}

extension LedgerWorkspace {
    /// Ordinary pack choices keep their existing semantics. A dinner's linked
    /// products can credit pantry stock only in its original local adult scope.
    public func dinnerAuthorizedPacks(in selections: [LedgerPackSelection], shop: ShoppingLedger,
                                      workspaceID: UUID, originID: UUID?, actorID: String?) -> [LedgerPackSelection] {
        guard !selections.isEmpty else { return [] }
        var linked = Set<UUID>()
        for receipt in dinnerPlanning.applyReceipts where receipt.proposal.shopID == shop.id {
            for change in receipt.proposal.changes {
                if case .choose(let dinner) = change, let products = dinner.pantryProducts {
                    linked.formUnion(products.matches.values)
                }
            }
        }
        guard !linked.isEmpty else {
            return selections.filter { $0.shopID != shop.id || $0.request.offerA.id != DinnerPantryProducts.atHomeOfferID }
        }
        let allowed = originID.flatMap { origin in actorID.map {
            dinnerPantryLines(shop: shop, workspaceID: workspaceID, originID: origin, actorID: $0)
        }} ?? []
        return selections.filter {
            !$0.isNoPurchase || $0.shopID != shop.id ||
                (!linked.contains($0.lineID) && $0.request.offerA.id != DinnerPantryProducts.atHomeOfferID) ||
                (allowed.contains($0.lineID) && $0.canonicalStockEvidence?.basis.originID == originID)
        }
    }
}
