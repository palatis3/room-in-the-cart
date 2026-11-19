import CoreDomain
import Foundation
import LocalStore
import HouseholdClient

/// A receipt can be carried by several pickup histories. The option identifies
/// one existing physical pantry lot and the inventory revision shown to its owner.
struct PantryRecentPurchase: Identifiable, Equatable {
    let id: UUID
    let receiptKey: ReceiptKey
    let reviewedFood: PantryReviewedFood
    let receivedAt: Date
    let usableObservationID: UUID
    let confirmedAt: Date
    let received: Quantity
}

/// The exact private delivery and optional pickup details displayed when a shopper links a package.
struct PantryReceiptDelivery: Identifiable, Equatable {
    let lot: InventoryLot
    let state: InventoryState
    let purchase: PantryRecentPurchase?
    var id: UUID { lot.id }

    static func fragment(of lot: InventoryLot) -> ReceiptKey? {
        guard case .receipt(_, let key) = lot.source, !key.sourceEventID.hasPrefix("receipt-acquisition/") else { return nil }
        return key
    }

    static func label(for lot: InventoryLot, purchase: PantryRecentPurchase?) -> String {
        let title = pantryFormat("Link delivery: %@ · %@", lot.name, String(lot.id.uuidString.suffix(8)))
        guard let purchase else { return title }
        return title + " · " + pantryQuantity(purchase.received) + " · " + purchase.receivedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Only the effective, reported order is a basis for comparison. Quotes for a
/// different basket revision and current pantry balances cannot fill missing evidence.
struct ReceiptTripPlan: Identifiable, Equatable {
    let id: UUID
    let branch: String
    let date: Date
    let lines: [BasketLine]
    let deliveryKeys: Set<ReceiptKey>
    var countsPacks = false

    init?(journey: PickupJourney) {
        guard let basket = journey.basket, let placement = basket.placements.first,
              let physical = journey.pickup, let branch = journey.context?.branchID,
              let lines = basket.effectiveOrderLines, !lines.isEmpty,
              physical.orderLines.allSatisfy({ $0.branchID == branch }),
              Set(physical.orderLines.map(\.id)) == Set(lines.map(\.id)) else { return nil }
        id = journey.id; self.branch = branch; date = placement.reportedAt; self.lines = lines
        deliveryKeys = Set(physical.receipts.map(\.key))
    }

    init(shared order: SharedConfirmedOrder, household: String) throws {
        try order.validate(shopID: order.shopId)
        id = order.shopId; branch = household; countsPacks = true; deliveryKeys = []
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let placed = format.date(from: order.original.snapshotCreatedAt) ?? ISO8601DateFormatter().date(from: order.original.snapshotCreatedAt)
        else { throw ClientError.invalidResponse }
        date = placed
        lines = try order.current.lines.map { line in
            guard let id = UUID(uuidString: line.lineId) else { throw ClientError.invalidResponse }
            let count = Int64(line.packs)
            let total: CostEvidence
            if let price = line.unitPriceMinor { total = .exact(try Money(minorUnits: Int64(price)).multiplied(by: count)) }
            else { total = .unknown(reason: "unknown") }
            return BasketLine(id: id, name: line.originalItem, quantity: Quantity(amount: try Rational(count), unit: .count, originalLiteral: String(count)), expectedCost: total)
        }
    }

    func suggestedLine(for row: ReceiptImportDraft.Line, purchases: [PantryRecentPurchase], knownFood: UUID? = nil) -> UUID? {
        let candidates: [PantryRecentPurchase]
        switch row.treatment {
        case .link(let lot): candidates = purchases.filter { $0.id == lot }
        default:
            guard let food = row.appliedAlias?.foodID ?? knownFood else { return nil }
            candidates = purchases.filter { $0.reviewedFood.id == food }
        }
        let ids = Set(candidates.filter { deliveryKeys.contains($0.receiptKey) }.map(\.receiptKey.orderLineID))
        guard ids.count == 1, let id = ids.first, lines.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

struct ReceiptTripLink: Equatable {
    let receiptLineID: UUID
    let portions: [UUID: Quantity]
    let printedTotal: Money?

    init?(receiptLineID: UUID, printed: Quantity, portions: [UUID: Quantity], printedTotal: Money?) {
        guard !portions.isEmpty, printed.amount > .zero, printedTotal.map({ $0 >= .zero }) != false else { return nil }
        var sum = Rational.zero
        for part in portions.values {
            guard part.unit == printed.unit, part.amount > .zero, let next = try? sum.adding(part.amount) else { return nil }
            sum = next
        }
        guard sum == printed.amount else { return nil }
        self.receiptLineID = receiptLineID; self.portions = portions; self.printedTotal = printedTotal
    }

    enum Status: Equatable { case noEvidence, incompatible, quantity, price, priceUnknown, matched }
    static func compare(_ planned: BasketLine, with links: [UUID: Self]) -> Status {
        let contributing = links.values.filter { $0.portions[planned.id] != nil }
        guard !contributing.isEmpty else { return .noEvidence }
        var sum = Rational.zero, cents: Int64 = 0, completePrice = true
        for link in contributing {
            guard let quantity = link.portions[planned.id], let amount = try? quantity.converted(to: planned.quantity.unit),
                  let total = try? sum.adding(amount) else { return .incompatible }
            sum = total
            if let price = link.printedTotal, link.portions.count == 1 {
                let result = cents.addingReportingOverflow(price.minorUnits)
                if result.overflow { completePrice = false } else { cents = result.partialValue }
            } else { completePrice = false }
        }
        guard sum == planned.quantity.amount else { return .quantity }
        guard completePrice, case .exact(let expected) = planned.expectedCost else { return .priceUnknown }
        return expected.minorUnits == cents ? .matched : .price
    }
}
