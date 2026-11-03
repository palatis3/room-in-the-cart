import Foundation

/// Amounts in the checkout line's unit. Explicit reviewed bindings take precedence over the
/// proportional serving split used by older meal records.
public struct LedgerMealPortions: Equatable, Sendable {
    public let groups: [UUID: Rational]
    public let unassigned: Rational

    public static func review(meal: MealOccurrence, contribution: LedgerContribution, in shop: ShoppingLedger,
                              unit: UnitOfMeasure, bindings: [DinnerPortionBinding]) throws -> Self {
        guard let source = contribution.quantity, let total = try source.converted(to: unit) else { throw LedgerPackError.missingQuantity }
        let reviewed = bindings.filter { $0.occurrenceID == meal.id }
        if !reviewed.isEmpty { try DinnerPlanningEngine.validateBindings(reviewed, occurrenceID: meal.id, ledger: shop) }
        var groups: [UUID: Rational] = [:], assigned = Rational.zero, servings = Rational.zero
        for group in meal.servingGroups {
            servings = try servings.adding(group.servings)
            guard servings <= meal.servings else { throw LedgerPackError.invalidEvidence }
            let amount: Rational
            if reviewed.isEmpty {
                amount = try total.multiplied(by: group.servings.divided(by: meal.servings))
            } else {
                guard let bound = reviewed.first(where: { $0.contributionID == contribution.id && $0.groupID == group.id }),
                      let inSource = try bound.quantity.converted(to: source.unit),
                      let converted = try Quantity(amount: inSource, unit: source.unit, originalLiteral: bound.quantity.originalLiteral,
                          confirmedConversion: source.confirmedConversion).converted(to: unit) else {
                    throw DinnerPlanningError.reviewRequired("portionBinding")
                }
                amount = converted
            }
            groups[group.id] = amount
            assigned = try assigned.adding(amount)
        }
        guard assigned <= total else { throw LedgerPackError.invalidEvidence }
        return try Self(groups: groups, unassigned: total.subtracting(assigned))
    }
}
