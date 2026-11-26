import Foundation

/// The accepted shopping list, before any later shopping, meal or receipt edits.
/// References identify private ledger observations; no pantry receipts are copied.
public struct WeeklyCostBaseline: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Identifiable, Sendable {
        public enum PriceSource: Codable, Equatable, Sendable {
            case pick(Date)
            case reviewedPack(UUID)
        }
        public let id: UUID
        public let name: String
        public let quantity: Quantity?
        public let packages: [BasketPackage]
        public let containers: GroceryPackageCount?
        public let estimate: Money?
        public let source: PriceSource?
    }

    public let version: Int
    public let currency: Currency
    public let store: String
    public let lines: [Line]

    init(accepted: ShoppingLedger, previous: ShoppingLedger, selections: [LedgerPackSelection],
         workspaceID: UUID, bindings: [DinnerPortionBinding], at date: Date) throws {
        version = 1
        currency = accepted.basis.currency
        store = accepted.basis.branch
        let candidates = Dictionary(grouping: selections.filter {
            $0.shopID == accepted.id && $0.sourceWorkspaceID == workspaceID && $0.shopRevisionID == previous.revisionID &&
                $0.reviewedAt <= date
        }, by: \.lineID)
        let sources = Dictionary(grouping: accepted.contributions.filter { $0.removedAt == nil }, by: \.lineID)
        let packages = accepted.itemPackages
        let items = Dictionary(uniqueKeysWithValues: try accepted.shoppingKitRows().map { ($0.id, $0) })
        lines = try accepted.lines.filter { !$0.isTrashed && !$0.isHandled }.map { line in
            let quantity = items[line.id]?.quantity
            let members = sources[line.id] ?? []
            var reviewedPacks = packages[line.id] ?? []
            var estimate: Money?
            var source: Line.PriceSource?
            if let selection = candidates[line.id]?.last, selection.stockEvidence == nil, selection.canonicalStockEvidence == nil,
               selection.request.needed == quantity, selection.request.itemName == line.name,
               previous.basisRevision == accepted.basisRevision,
               try selection.isCurrent(in: previous, workspaceID: workspaceID, bindings: bindings),
               let requirement = try? LedgerPackRequirement.review(shop: accepted, lineID: line.id, bindings: bindings),
               selection.request.protectedAmount == requirement.protectedQuantity,
               let count = selection.selectedResult.packsToBuy {
                let offer = selection.selectedOfferID == selection.request.offerA.id ? selection.request.offerA : selection.request.offerB
                if let usable = offer.usableQuantity { reviewedPacks = [.init(count: count, amountPerPack: usable.amount, unit: usable.unit)] }
                estimate = selection.selectedResult.totalCost
                source = .reviewedPack(selection.id)
            } else if line.pickedPrice != nil, accepted.currentStop.name == accepted.basis.branch, let pick = accepted.priceForCurrentPick(lineID: line.id), pick.checkedAt <= date,
                      pick.quantity == quantity, let known = pick.includedTotal {
                estimate = known
                source = .pick(pick.checkedAt)
            }
            return Line(id: line.id, name: line.name, quantity: quantity, packages: reviewedPacks,
                        containers: GroceryPackageCount(reviewedSources: members), estimate: estimate, source: source)
        }
        try validate()
    }

    func validate() throws {
        guard version == 1, lines.count <= 10_000 else { throw DinnerPlanningError.invalid("costBaseline") }
        try dinnerUnique(lines.map(\.id))
        try ledgerText(store, maximum: 512)
        for line in lines {
            try ledgerText(line.name, nonempty: true, maximum: 512)
            try line.quantity?.validate()
            guard line.packages.allSatisfy({ $0.count > 0 && $0.amountPerPack > .zero }) else { throw DinnerPlanningError.invalid("costPackages") }
            guard (line.source == nil) == (line.estimate == nil),
                  line.estimate.map({ $0.currency == currency && $0.minorUnits >= 0 }) != false,
                  line.containers.map({ $0.count > 0 }) != false else { throw DinnerPlanningError.invalid("costLine") }
        }
    }
}

/// A read-only projection of accepted receipt revisions. A purchase joins a planned
/// line through the shopper’s reviewed order match or an explicitly linked delivery.
public struct WeeklyPurchaseReview: Equatable, Sendable {
    public struct Purchase: Equatable, Sendable {
        public let acquisition: ReceiptAcquisition
        public let earlierRevisions: [ReceiptAcquisition]
        public let net: Money?
        public let credit: Money?
        public let plannedLineID: UUID?
    }
    public let purchases: [Purchase]
    public let knownActual: Money?
    public let knownEstimate: Money?
    public let unpricedEstimates: Int
    public let unmatchedPlanLines: Int

    public init(baseline: WeeklyCostBaseline, pickup: ReceiptAcquisition.SavedPickup, fragments: Set<ReceiptKey>,
                receipts: [ReceiptAcquisition], adjustments: [PrivatePriceEvidence]) throws {
        let ids = Set(baseline.lines.map(\.id))
        var current: [UUID: ReceiptAcquisition] = [:]
        let history = Dictionary(grouping: receipts.filter { $0.savedPickup == pickup }, by: \.lineID)
        for receipt in receipts {
            try receipt.validate()
            if let old = current[receipt.lineID] {
                guard old.revision != receipt.revision || old == receipt else { throw DinnerPlanningError.invalid("receiptRevision") }
                if old.revision >= receipt.revision { continue }
            }
            current[receipt.lineID] = receipt
        }
        purchases = try current.values.filter { $0.savedPickup == pickup && $0.documentLine?.stage != .order }
            .sorted { ($0.purchaseDate, $0.id.uuidString) < ($1.purchaseDate, $1.id.uuidString) }.map { receipt in
                let paid = try PrivatePriceEvidence(receipt: receipt)
                let amount = try paid.netAmount(adjustments: adjustments)
                let net = amount.map { Money(minorUnits: $0, currency: receipt.currency) }
                let credit = try net.flatMap { try receipt.paidLineTotal?.subtracting($0) }
                var planned: UUID?
                if let match = receipt.orderMatch {
                    if match.portions.count == 1, let lineID = match.portions.first?.lineID, ids.contains(lineID) { planned = lineID }
                } else if case .linked(let fragment) = receipt.stock, fragments.contains(fragment), ids.contains(fragment.orderLineID) {
                    planned = fragment.orderLineID
                }
                let earlier = (history[receipt.lineID] ?? []).filter { $0.revision < receipt.revision && $0.documentLine?.stage != .order }
                    .sorted { $0.revision < $1.revision }
                return Purchase(acquisition: receipt, earlierRevisions: earlier, net: net, credit: credit, plannedLineID: planned)
            }
        let actual = purchases.compactMap(\.net).filter { $0.currency == baseline.currency }
        let estimates = baseline.lines.compactMap(\.estimate)
        knownActual = try Self.total(actual)
        knownEstimate = try Self.total(estimates)
        unpricedEstimates = baseline.lines.count - estimates.count
        let linked = purchases.flatMap { purchase -> [UUID] in
            if let match = purchase.acquisition.orderMatch { return match.portions.map(\.lineID) }
            return purchase.plannedLineID.map { [$0] } ?? []
        }
        unmatchedPlanLines = ids.subtracting(linked).count
    }

    public static func total(_ amounts: [Money]) throws -> Money? {
        guard let first = amounts.first else { return nil }
        return try amounts.dropFirst().reduce(first) { try $0.adding($1) }
    }
}

/// Only a quoted product explicitly tied to the same quantified requirement at
/// both stores can contribute to paired coverage. Inclusive quotes contain no
/// per-product evidence and offer no denominator.
extension TwoStoreQuotePair {
    public var pairedItemCoverage: (matched: Int, total: Int?)? {
        guard case .components(let a, let completeA, _, _, _, _) = first.quote.pricing,
              case .components(let b, let completeB, _, _, _, _) = second.quote.pricing else { return nil }
        let selected = Set(a.map(\.id)).union(b.map(\.id))
        let other = Dictionary(grouping: b, by: \.id)
        let suppliedA = Dictionary(grouping: first.supplies ?? [], by: \.id)
        let suppliedB = Dictionary(grouping: second.supplies ?? [], by: \.id)
        var matched = Set<UUID>()
        for line in a {
            guard let peer = other[line.id]?.onlyElement, line.name == peer.name,
                  case .exact(let priceA) = line.cost, case .exact(let priceB) = peer.cost,
                  priceA.currency == priceB.currency,
                  let packA = suppliedA[line.id]?.onlyElement, let packB = suppliedB[line.id]?.onlyElement,
                  let quantityA = try? Rational(packA.requiredUnits),
                  let quantityB = try? Rational(packB.requiredUnits),
                  let comparable = try? Quantity(amount: quantityB, unit: packB.unit, originalLiteral: "").converted(to: packA.unit),
                  quantityA == comparable, (try? packA.surplus()).map({ $0 >= 0 }) == true,
                  (try? packB.surplus()).map({ $0 >= 0 }) == true else { continue }
            matched.insert(line.id)
        }
        return (matched.count, completeA && completeB ? selected.count : nil)
    }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
