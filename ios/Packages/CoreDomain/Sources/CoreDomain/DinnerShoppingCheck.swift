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
