import Foundation

/// A count here means physical packs explicitly counted for this shelf price.
public struct PickedShelfPrice: Codable, Equatable, Sendable {
    public let rate: Money
    public let unit: UnitOfMeasure
    public let measured: Quantity?

    public init(rate: Money, unit: UnitOfMeasure, measured: Quantity?) {
        self.rate = rate
        self.unit = unit
        self.measured = measured
    }

    public func lineTotal() throws -> Money? {
        guard (0...1_000_000_000).contains(rate.minorUnits), unit == .count || unit.dimension == .mass else {
            throw LedgerError.invalid("shelfPrice")
        }
        guard let measured else { return nil }
        try measured.validate()
        guard measured.unit.dimension == unit.dimension, measured.amount > .zero,
              unit != .count || measured.amount.denominator == 1,
              let amount = try measured.converted(to: unit) else { throw LedgerError.invalid("shelfAmount") }
        let cents = try amount.multiplied(by: Rational(rate.minorUnits)).roundedNearest()
        guard cents <= 1_000_000_000 else { throw LedgerError.invalid("shelfTotal") }
        return Money(minorUnits: cents, currency: rate.currency)
    }
}

public struct BudgetDeferralPreview: Equatable, Sendable {
    public let before: PickedCartSubtotal
    public let after: PickedCartSubtotal
    public let affectedDinners: [String]
}

extension ShoppingLedger {
    public func budgetDinnerImpact(for lineID: UUID) -> (dinners: [String], protected: Bool) {
        var mealIDs = Set<UUID>()
        var protected = false
        for contribution in contributions(forLineID: lineID) {
            switch contribution.source {
            case .meal(let id): mealIDs.insert(id)
            case .protectedNeed: protected = true
            default: break
            }
        }
        let dinners = mealOccurrences.filter { $0.removedAt == nil && mealIDs.contains($0.id) }
        return (dinners.map(\.title), protected || dinners.contains { $0.servingGroups.contains(where: \.isProtected) })
    }

    public mutating func setBudgetFlexible(lineID: UUID, expectedRevision: UUID, flexible: Bool) throws {
        let protected = budgetDinnerImpact(for: lineID).protected
        try updateBudgetLine(lineID, revision: expectedRevision, operation: "budgetFlexibility") { line in
            guard line.inStorePickedAt != nil, !flexible || !protected else { throw LedgerError.stalePreview }
            line.flexiblePick = flexible ? true : nil
        }
    }

    public func previewBudgetDeferral(lineID: UUID) throws -> BudgetDeferralPreview {
        guard let line = lines.first(where: { $0.id == lineID }),
              line.flexiblePick == true, line.inStorePickedAt != nil, !line.isHandled, !line.isTrashed else {
            throw LedgerError.stalePreview
        }
        let impact = budgetDinnerImpact(for: lineID)
        guard !impact.protected else { throw LedgerError.invalid("protectedPick") }
        let before = pickedCartSubtotal
        let removed = priceForCurrentPick(lineID: lineID)?.includedTotal
        let after = try PickedCartSubtotal(total: removed.map(before.total.subtracting) ?? before.total,
            priced: before.priced - (removed == nil ? 0 : 1), picked: before.picked - 1)
        return BudgetDeferralPreview(before: before, after: after, affectedDinners: impact.dinners)
    }
}
