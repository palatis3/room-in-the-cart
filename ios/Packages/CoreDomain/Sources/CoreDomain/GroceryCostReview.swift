import Foundation

/// A grocery-only subtotal. An absent observation cannot be described as a free item.
public struct GroceryCostReview: Equatable, Sendable {
    public let known: Money?
    public let priced: Int
    public let unpriced: Set<UUID>
    public let inventoryComplete: Bool
    public init(lines: [(UUID, Money?)], currency: Currency, inventoryComplete: Bool) throws {
        guard Set(lines.map { $0.0 }).count == lines.count else { throw CheckoutError.invalidEvidence }
        var subtotal = Money(minorUnits: 0, currency: currency)
        var unknown = Set<UUID>()
        for (id, cost) in lines {
            if let cost {
                guard cost.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
                subtotal = try subtotal.adding(cost)
            } else { unknown.insert(id) }
        }
        priced = lines.count - unknown.count
        known = priced > 0 || (inventoryComplete && lines.isEmpty) ? subtotal : nil
        unpriced = unknown
        self.inventoryComplete = inventoryComplete
    }
    public func pricedChange(from prior: Self) throws -> Money? {
        guard inventoryComplete, prior.inventoryComplete, prior.unpriced == unpriced,
              let known, let previous = prior.known else { return nil }
        return try known.subtracting(previous)
    }

    /// Other active lines keep the same dated, quantity-matched pick on both sides of a preview.
    public static func unchangedLines(in shop: ShoppingLedger, excluding affected: Set<UUID>,
                                      at date: Date) throws -> [(UUID, Money?)] {
        try shop.lines.filter { !$0.isTrashed && !$0.isHandled && !affected.contains($0.id) }.map { line in
            guard shop.currentStop.name == shop.basis.branch,
                  let pick = shop.priceForCurrentPick(lineID: line.id), pick.checkedAt <= date,
                  let quantity = try shop.quantity(forLineID: line.id), quantity == pick.quantity
            else { return (line.id, nil) }
            return (line.id, pick.includedTotal)
        }
    }

}

public struct GroceryStoreSplit: Sendable {
    public struct Line: Sendable {
        public let id: UUID
        public let first, second: Money?
        public let secondStop: Bool
        public init(id: UUID, first: Money?, second: Money?, secondStop: Bool) {
            self.id = id; self.first = first; self.second = second; self.secondStop = secondStop
        }
    }
    public let single, firstStop, secondStop, split: GroceryCostReview
    /// Signed split-minus-single change for groceries plus the entered incremental trip cash.
    public let changeWithTravel: Money?
    public init(lines: [Line], currency: Currency, travel: Money?, conditionsConfirmed: Bool) throws {
        guard !lines.isEmpty, travel.map({ $0.currency == currency && $0.minorUnits >= 0 }) != false else { throw CheckoutError.invalidEvidence }
        single = try GroceryCostReview(lines: lines.map { ($0.id, $0.first) }, currency: currency, inventoryComplete: true)
        let firstRows = lines.filter { !$0.secondStop }.map { ($0.id, $0.first) }
        let secondRows = lines.filter(\.secondStop).map { ($0.id, $0.second) }
        firstStop = try GroceryCostReview(lines: firstRows, currency: currency, inventoryComplete: true)
        secondStop = try GroceryCostReview(lines: secondRows, currency: currency, inventoryComplete: true)
        split = try GroceryCostReview(lines: firstRows + secondRows, currency: currency, inventoryComplete: true)
        if conditionsConfirmed, !firstRows.isEmpty, !secondRows.isEmpty, single.unpriced.isEmpty, split.unpriced.isEmpty,
           let travel, let subtotal = split.known, let baseline = single.known {
            changeWithTravel = try subtotal.adding(travel).subtracting(baseline)
        } else { changeWithTravel = nil }
    }
}
