import Foundation

public enum PickupError: Error, Equatable, Sendable {
    case duplicateIdentity, invalidEvidence, unknownOrderLine, wrongBranch
    case replayConflict, staleObservation, impossibleUsableAmount, missingConversion
    case invalidCreditLink, creditAlreadySettled
}

public struct PickupOrderLine: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let branchID: String
    public let name: String
    public let ordered: Quantity
    public init(id: UUID, branchID: String, name: String, ordered: Quantity) {
        self.id = id; self.branchID = branchID; self.name = name; self.ordered = ordered
    }
}
/// A second genuine delivery has a distinct source event/segment. Retry identity is
/// never inferred from equal item names, equal amounts, or nearby timestamps.
public struct ReceiptKey: Codable, Hashable, Sendable {
    public let sourceEventID: String
    public let orderLineID: UUID
    public let branchID: String
    public let segmentID: String
    public init(sourceEventID: String, orderLineID: UUID, branchID: String, segmentID: String) {
        self.sourceEventID = sourceEventID; self.orderLineID = orderLineID
        self.branchID = branchID; self.segmentID = segmentID
    }
}
public enum ReceiptDisposition: String, Codable, Sendable { case received, noFill, partial, wrongItem, late }
public struct ReceiptFragment: Codable, Equatable, Sendable {
    public let key: ReceiptKey
    public let itemName: String
    /// Physical food quantity received, in its observed units. A pack label is not
    /// itself a confirmed usable quantity and must not be substituted for this value.
    public let received: Quantity
    public let disposition: ReceiptDisposition
    public let receivedAt: Date
    public init(key: ReceiptKey, itemName: String, received: Quantity, disposition: ReceiptDisposition, receivedAt: Date) {
        self.key = key; self.itemName = itemName; self.received = received
        self.disposition = disposition; self.receivedAt = receivedAt
    }
}
public struct UsableObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let receipt: ReceiptKey
    public let usable: Quantity
    public let confirmedAt: Date
    public let supersedesID: UUID?
    /// Explicit reviewed identity/unit/constraint match. A wrong product never feeds
    /// the meal allocation merely because its amount is numerically compatible.
    public let confirmedMatchToOrderLine: Bool
    public init(id: UUID, receipt: ReceiptKey, usable: Quantity, confirmedAt: Date,
                supersedesID: UUID? = nil, confirmedMatchToOrderLine: Bool) {
        self.id = id; self.receipt = receipt; self.usable = usable; self.confirmedAt = confirmedAt
        self.supersedesID = supersedesID; self.confirmedMatchToOrderLine = confirmedMatchToOrderLine
    }
}
public enum AllocationPriority: Int, Codable, Comparable, Sendable {
    case protected = 0, required = 1, flexible = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public struct AllocationNeed: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let orderLineID: UUID
    public let name: String
    public let amount: Quantity
    public let priority: AllocationPriority
    public init(id: UUID, orderLineID: UUID, name: String, amount: Quantity, priority: AllocationPriority) {
        self.id = id; self.orderLineID = orderLineID; self.name = name; self.amount = amount; self.priority = priority
    }
}
public enum PickupIssue: String, Codable, Sendable {
    case receiptUnverified, usableUnverified, identityMatchUnconfirmed, conversionUnknown
}
public struct DemandCoverage: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let orderLineID: UUID
    /// All amounts use this normalized order-line unit. Unknown conversion yields nil.
    public let unit: UnitOfMeasure
    public let needed: Rational?
    public let allocated: Rational?
    public let shortfall: Rational?
    public let issues: [PickupIssue]
}
public struct ReceiptAllocation: Codable, Equatable, Sendable {
    public let receipt: ReceiptKey
    public let needID: UUID
    public let unit: UnitOfMeasure
    public let amount: Rational
}
public struct LineAvailability: Codable, Equatable, Sendable {
    public let orderLineID: UUID
    public let unit: UnitOfMeasure
    public let confirmedUsable: Rational
    public let remainingUnallocated: Rational
    public let issues: [PickupIssue]
}
public struct PickupAllocation: Codable, Equatable, Sendable {
    public let demands: [DemandCoverage]
    public let allocations: [ReceiptAllocation]
    public let lines: [LineAvailability]
    public var confirmedCoverageComplete: Bool {
        !demands.isEmpty && demands.allSatisfy { $0.shortfall == .zero }
    }
}

/// Receipt facts and usable corrections are separate immutable histories. Allocation
/// is recomputed from latest confirmed observations, so correcting yield revisits every
/// dependent meal without ever changing received quantity or the posted cash ledger.
public struct PickupLedger: Codable, Equatable, Sendable {
    public let orderID: UUID
    public let orderLines: [PickupOrderLine]
    public private(set) var receipts: [ReceiptFragment] = []
    public private(set) var usableObservations: [UsableObservation] = []

    public init(orderID: UUID, orderLines: [PickupOrderLine]) throws {
        guard Set(orderLines.map(\.id)).count == orderLines.count else { throw PickupError.duplicateIdentity }
        for line in orderLines {
            guard !line.branchID.isEmpty, !line.name.isEmpty else { throw PickupError.invalidEvidence }
            try line.ordered.validate()
        }
        self.orderID = orderID; self.orderLines = orderLines
    }

    private enum CodingKeys: String, CodingKey { case orderID, orderLines, receipts, usableObservations }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(orderID: container.decode(UUID.self, forKey: .orderID),
                      orderLines: container.decode([PickupOrderLine].self, forKey: .orderLines))
        for receipt in try container.decode([ReceiptFragment].self, forKey: .receipts) {
            guard try receive(receipt) else { throw PickupError.duplicateIdentity }
        }
        for observation in try container.decode([UsableObservation].self, forKey: .usableObservations) {
            guard try confirmUsable(observation) else { throw PickupError.duplicateIdentity }
        }
    }

    @discardableResult
    public mutating func receive(_ fragment: ReceiptFragment) throws -> Bool {
        if let old = receipts.first(where: { $0.key == fragment.key }) {
            guard old == fragment else { throw PickupError.replayConflict }; return false
        }
        guard let line = orderLines.first(where: { $0.id == fragment.key.orderLineID }) else { throw PickupError.unknownOrderLine }
        guard line.branchID == fragment.key.branchID else { throw PickupError.wrongBranch }
        guard !fragment.key.sourceEventID.isEmpty, !fragment.key.segmentID.isEmpty,
              !fragment.itemName.isEmpty, fragment.receivedAt.timeIntervalSinceReferenceDate.isFinite,
              fragment.disposition != .noFill || fragment.received.amount == .zero else { throw PickupError.invalidEvidence }
        try fragment.received.validate()
        receipts.append(fragment)
        return true
    }

    @discardableResult
    public mutating func confirmUsable(_ observation: UsableObservation) throws -> Bool {
        if let old = usableObservations.first(where: { $0.id == observation.id }) {
            guard old == observation else { throw PickupError.replayConflict }; return false
        }
        guard let receipt = receipts.first(where: { $0.key == observation.receipt }),
              observation.confirmedAt.timeIntervalSinceReferenceDate.isFinite else { throw PickupError.invalidEvidence }
        guard usableObservations.last(where: { $0.receipt == observation.receipt })?.id == observation.supersedesID else { throw PickupError.staleObservation }
        try observation.usable.validate()
        guard let inReceivedUnits = try observation.usable.converted(to: receipt.received.unit) else { throw PickupError.missingConversion }
        guard inReceivedUnits <= receipt.received.amount else { throw PickupError.impossibleUsableAmount }
        usableObservations.append(observation)
        return true
    }

    public func allocate(_ needs: [AllocationNeed]) throws -> PickupAllocation {
        guard Set(needs.map(\.id)).count == needs.count else { throw PickupError.duplicateIdentity }
        for need in needs {
            guard orderLines.contains(where: { $0.id == need.orderLineID }), !need.name.isEmpty else { throw PickupError.unknownOrderLine }
            try need.amount.validate()
        }
        var coverages: [DemandCoverage] = [], allocations: [ReceiptAllocation] = [], availability: [LineAvailability] = []
        for line in orderLines {
            let lineReceipts = receipts.filter { $0.key.orderLineID == line.id }
            var issues: [PickupIssue] = lineReceipts.isEmpty ? [.receiptUnverified] : []
            var lots: [(key: ReceiptKey, amount: Rational)] = []
            for receipt in lineReceipts {
                guard let observed = usableObservations.last(where: { $0.receipt == receipt.key }) else {
                    if receipt.disposition != .noFill { issues.append(.usableUnverified) }
                    continue
                }
                guard observed.confirmedMatchToOrderLine else { issues.append(.identityMatchUnconfirmed); continue }
                guard let amount = try observed.usable.converted(to: line.ordered.unit) else { issues.append(.conversionUnknown); continue }
                lots.append((receipt.key, amount))
            }
            let confirmed = try lots.reduce(Rational.zero) { try $0.adding($1.amount) }
            let lineNeeds = needs.enumerated().filter { $0.element.orderLineID == line.id }.sorted {
                $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority
            }.map(\.element)
            let converted = try lineNeeds.map { try $0.amount.converted(to: line.ordered.unit) }
            // An unconvertible demand might consume this same food. Reserve the line
            // for review rather than reallocating its unknown claim to another dinner.
            let incompatible = converted.contains { $0 == nil }
            if incompatible { issues.append(.conversionUnknown) }
            issues = unique(issues)
            let allocation = try incompatible ? nil : PriorityAllocationCore.allocate(supply: lots.map(\.amount), needs: converted.compactMap { $0 })
            for (index, need) in lineNeeds.enumerated() {
                let requested = converted[index]
                guard let allocation else {
                    coverages.append(DemandCoverage(id: need.id, orderLineID: line.id, unit: line.ordered.unit,
                                                     needed: requested, allocated: nil, shortfall: nil, issues: issues))
                    continue
                }
                coverages.append(DemandCoverage(id: need.id, orderLineID: line.id, unit: line.ordered.unit,
                                                 needed: requested, allocated: allocation.allocated[index], shortfall: allocation.shortfalls[index], issues: issues))
            }
            if let allocation {
                for edge in allocation.edges {
                    allocations.append(ReceiptAllocation(receipt: lots[edge.lot].key, needID: lineNeeds[edge.need].id,
                                                         unit: line.ordered.unit, amount: edge.amount))
                }
                for index in lots.indices { lots[index].amount = allocation.remaining[index] }
            }
            availability.append(LineAvailability(orderLineID: line.id, unit: line.ordered.unit, confirmedUsable: confirmed,
                                                 remainingUnallocated: try lots.reduce(.zero) { try $0.adding($1.amount) }, issues: issues))
        }
        // Preserve original presentation order; priority only affects consumption order.
        let index = Dictionary(uniqueKeysWithValues: needs.enumerated().map { ($0.element.id, $0.offset) })
        coverages.sort { index[$0.id, default: 0] < index[$1.id, default: 0] }
        return PickupAllocation(demands: coverages, allocations: allocations, lines: availability)
    }

    private func unique(_ issues: [PickupIssue]) -> [PickupIssue] {
        issues.reduce(into: []) { result, issue in if !result.contains(issue) { result.append(issue) } }
    }
}

public enum ConfirmedStockSource: String, Codable, Sendable { case pantry, freezer, manual }
/// A dated, explicitly confirmed usable lot. foodID is a reviewed identity match;
/// matching two names alone must never create this relationship.
public struct ConfirmedStockLot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let foodID: UUID
    public let name: String
    public let usable: Quantity
    public let confirmedAt: Date
    public let source: ConfirmedStockSource
    public let useFirst: Bool?
    public init(id: UUID, foodID: UUID, name: String, usable: Quantity, confirmedAt: Date, source: ConfirmedStockSource = .manual, useFirst: Bool = false) {
        self.id = id; self.foodID = foodID; self.name = name; self.usable = usable
        self.confirmedAt = confirmedAt; self.source = source
        self.useFirst = useFirst ? true : nil
    }
}
public struct StockNeed: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let foodID: UUID
    public let name: String
    public let amount: Quantity
    public let priority: AllocationPriority
    public init(id: UUID, foodID: UUID, name: String, amount: Quantity, priority: AllocationPriority) {
        self.id = id; self.foodID = foodID; self.name = name; self.amount = amount; self.priority = priority
    }
}
public struct StockDemandCoverage: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let foodID: UUID
    public let unit: UnitOfMeasure
    public let needed: Rational?
    public let allocated: Rational?
    public let shortfall: Rational?
    public let issues: [PickupIssue]
}
public struct StockAllocationEdge: Codable, Equatable, Sendable {
    public let lotID: UUID
    public let needID: UUID
    public let foodID: UUID
    public let unit: UnitOfMeasure
    public let amount: Rational
}
public struct StockLotBalance: Codable, Equatable, Sendable {
    public let lotID: UUID
    public let foodID: UUID
    public let unit: UnitOfMeasure
    public let remainingUnallocated: Rational
    public let issues: [PickupIssue]
}
public struct StockAllocationResult: Codable, Equatable, Sendable {
    public let demands: [StockDemandCoverage]
    public let allocations: [StockAllocationEdge]
    public let remainingLots: [StockLotBalance]
    public var confirmedCoverageComplete: Bool { !demands.isEmpty && demands.allSatisfy { $0.shortfall == .zero } }
}

/// Works on a fresh installation with no shop, order, receipt, or invented meal date.
/// The result allocates only explicitly confirmed matching lots. All quantities are
/// normalized to the first need's unit for that food; unknown conversions stay visible.
public enum ConfirmedStockAllocator {
    public static func allocate(lots: [ConfirmedStockLot], needs: [StockNeed]) throws -> StockAllocationResult {
        guard Set(lots.map(\.id)).count == lots.count, Set(needs.map(\.id)).count == needs.count else { throw PickupError.duplicateIdentity }
        for lot in lots {
            guard !lot.name.isEmpty, lot.confirmedAt.timeIntervalSinceReferenceDate.isFinite else { throw PickupError.invalidEvidence }
            try lot.usable.validate()
        }
        for need in needs {
            guard !need.name.isEmpty else { throw PickupError.invalidEvidence }
            try need.amount.validate()
        }
        var foods: [UUID] = []
        for id in needs.map(\.foodID) + lots.map(\.foodID) where !foods.contains(id) { foods.append(id) }
        var demands: [StockDemandCoverage] = [], edges: [StockAllocationEdge] = [], balances: [StockLotBalance] = []
        for food in foods {
            let foodNeeds = needs.enumerated().filter { $0.element.foodID == food }.sorted {
                $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority
            }.map(\.element)
            let matched = lots.filter { $0.foodID == food }
            let foodLots = matched.filter { $0.useFirst == true } + matched.filter { $0.useFirst != true }
            guard let unit = needs.first(where: { $0.foodID == food })?.amount.unit ?? foodLots.first?.usable.unit else { continue }
            let requests = try foodNeeds.map { try $0.amount.converted(to: unit) }
            let supplies = try foodLots.map { try $0.usable.converted(to: unit) }
            let issues: [PickupIssue] = requests.contains(where: { $0 == nil }) || supplies.contains(where: { $0 == nil }) ? [.conversionUnknown] : []
            let matchedLots = foodLots.indices.filter { supplies[$0] != nil }
            let allocation = try requests.contains(where: { $0 == nil }) ? nil : PriorityAllocationCore.allocate(
                supply: matchedLots.compactMap { supplies[$0] }, needs: requests.compactMap { $0 })
            for (index, need) in foodNeeds.enumerated() {
                demands.append(StockDemandCoverage(id: need.id, foodID: food, unit: unit, needed: requests[index],
                                                   allocated: allocation?.allocated[index], shortfall: allocation?.shortfalls[index], issues: issues))
            }
            if let allocation {
                for edge in allocation.edges {
                    edges.append(StockAllocationEdge(lotID: foodLots[matchedLots[edge.lot]].id, needID: foodNeeds[edge.need].id,
                                                    foodID: food, unit: unit, amount: edge.amount))
                }
            }
            for index in foodLots.indices {
                let lot = foodLots[index]
                if let matched = matchedLots.firstIndex(of: index), let allocation {
                    balances.append(StockLotBalance(lotID: lot.id, foodID: food, unit: unit,
                                                    remainingUnallocated: allocation.remaining[matched], issues: []))
                } else {
                    balances.append(StockLotBalance(lotID: lot.id, foodID: food, unit: lot.usable.unit,
                                                    remainingUnallocated: lot.usable.amount, issues: issues))
                }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: needs.enumerated().map { ($0.element.id, $0.offset) })
        demands.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        return StockAllocationResult(demands: demands, allocations: edges, remainingLots: balances)
    }
}

/// One conservation algorithm shared by receipt allocation and independent confirmed stock.
/// Callers supply needs in protected/required/flexible order after unit normalization.
private enum PriorityAllocationCore {
    struct Edge { let lot: Int; let need: Int; let amount: Rational }
    struct Result { let allocated: [Rational]; let shortfalls: [Rational]; let remaining: [Rational]; let edges: [Edge] }
    static func allocate(supply: [Rational], needs: [Rational]) throws -> Result {
        var stock = supply, allocated: [Rational] = [], shortfalls: [Rational] = [], edges: [Edge] = []
        for (needIndex, requested) in needs.enumerated() {
            var remaining = requested
            for lotIndex in stock.indices where remaining > .zero {
                let used = min(remaining, stock[lotIndex])
                if used > .zero {
                    edges.append(Edge(lot: lotIndex, need: needIndex, amount: used))
                    stock[lotIndex] = try stock[lotIndex].subtracting(used)
                    remaining = try remaining.subtracting(used)
                }
            }
            allocated.append(try requested.subtracting(remaining))
            shortfalls.append(remaining)
        }
        return Result(allocated: allocated, shortfalls: shortfalls, remaining: stock, edges: edges)
    }
}

public enum SettlementKind: String, Codable, Sendable {
    case postedCharge, postedTopUp, pendingCredit, postedCredit, includedCredit, paymentHold, holdRelease
}
public struct SettlementEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let evidenceKey: String
    public let kind: SettlementKind
    /// Positive magnitude. Kind determines cash direction; no floating-point money.
    public let amount: Money
    public let occurredAt: Date
    /// Credit identity connects pending, posted, and already-included evidence.
    public let creditID: String?
    /// Original charge evidence key, required for all credit records.
    public let chargeEvidenceKey: String?
    public let holdEvidenceKey: String?
    public init(id: UUID, evidenceKey: String, kind: SettlementKind, amount: Money, occurredAt: Date,
                creditID: String? = nil, chargeEvidenceKey: String? = nil, holdEvidenceKey: String? = nil) {
        self.id = id; self.evidenceKey = evidenceKey; self.kind = kind; self.amount = amount
        self.occurredAt = occurredAt; self.creditID = creditID; self.chargeEvidenceKey = chargeEvidenceKey
        self.holdEvidenceKey = holdEvidenceKey
    }
}
public struct SettlementSummary: Codable, Equatable, Sendable {
    public let paidSoFar: Money
    public let pendingCredits: Money
    public let includedCredits: Money
    public let paymentHolds: Money
}
public struct SettlementLedger: Codable, Equatable, Sendable {
    public private(set) var entries: [SettlementEntry] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        for entry in try container.decode([SettlementEntry].self, forKey: .entries) {
            guard try append(entry) else { throw PickupError.duplicateIdentity }
        }
    }

    @discardableResult
    public mutating func append(_ entry: SettlementEntry) throws -> Bool {
        if let old = entries.first(where: { $0.id == entry.id }) {
            guard old == entry else { throw PickupError.replayConflict }; return false
        }
        if let old = entries.first(where: { $0.evidenceKey == entry.evidenceKey }) {
            guard old.kind == entry.kind, old.amount == entry.amount, old.occurredAt == entry.occurredAt,
                  old.creditID == entry.creditID, old.chargeEvidenceKey == entry.chargeEvidenceKey,
                  old.holdEvidenceKey == entry.holdEvidenceKey else { throw PickupError.replayConflict }
            return false
        }
        guard !entry.evidenceKey.isEmpty, entry.amount.minorUnits >= 0,
              entry.occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw PickupError.invalidEvidence }
        switch entry.kind {
        case .pendingCredit, .postedCredit, .includedCredit:
            guard entry.holdEvidenceKey == nil, let credit = entry.creditID, !credit.isEmpty,
                  let charge = entry.chargeEvidenceKey,
                  entries.contains(where: { $0.evidenceKey == charge && [.postedCharge, .postedTopUp].contains($0.kind) }) else { throw PickupError.invalidCreditLink }
            let siblings = entries.filter { $0.creditID == credit }
            guard siblings.allSatisfy({ $0.chargeEvidenceKey == charge }) else { throw PickupError.invalidCreditLink }
            if entry.kind == .pendingCredit {
                // Late pending evidence after settlement is redundant and cannot reopen it.
                guard !siblings.contains(where: { [.postedCredit, .includedCredit].contains($0.kind) }) else { throw PickupError.creditAlreadySettled }
                guard !siblings.contains(where: { $0.kind == .pendingCredit }) else { throw PickupError.duplicateIdentity }
            } else {
                guard !siblings.contains(where: { [.postedCredit, .includedCredit].contains($0.kind) }) else { throw PickupError.creditAlreadySettled }
            }
        case .postedCharge, .postedTopUp, .paymentHold:
            guard entry.creditID == nil, entry.chargeEvidenceKey == nil, entry.holdEvidenceKey == nil else { throw PickupError.invalidCreditLink }
        case .holdRelease:
            guard entry.creditID == nil, entry.chargeEvidenceKey == nil,
                  let holdKey = entry.holdEvidenceKey,
                  let hold = entries.first(where: { $0.evidenceKey == holdKey && $0.kind == .paymentHold }),
                  hold.amount == entry.amount,
                  !entries.contains(where: { $0.kind == .holdRelease && $0.holdEvidenceKey == holdKey }) else { throw PickupError.invalidEvidence }
        }
        // Check all arithmetic on a candidate before committing; overflow leaves history intact.
        var candidate = self
        candidate.entries.append(entry)
        _ = try candidate.summary()
        self = candidate
        return true
    }

    public func summary() throws -> SettlementSummary { try Self.summary(of: entries) }

    public static func summary(of entries: [SettlementEntry]) throws -> SettlementSummary {
        var paid: Int64 = 0, pending: Int64 = 0, included: Int64 = 0, holds: Int64 = 0
        let settledCredits = Set(entries.filter { [.postedCredit, .includedCredit].contains($0.kind) }.compactMap(\.creditID))
        for entry in entries {
            switch entry.kind {
            case .postedCharge, .postedTopUp: paid = try checkedAdd(paid, entry.amount.minorUnits)
            case .postedCredit: paid = try checkedAdd(paid, -entry.amount.minorUnits)
            case .pendingCredit:
                if let credit = entry.creditID, !settledCredits.contains(credit) { pending = try checkedAdd(pending, entry.amount.minorUnits) }
            case .includedCredit: included = try checkedAdd(included, entry.amount.minorUnits)
            case .paymentHold: holds = try checkedAdd(holds, entry.amount.minorUnits)
            case .holdRelease: holds = try checkedAdd(holds, -entry.amount.minorUnits)
            }
        }
        return SettlementSummary(paidSoFar: Money(minorUnits: paid), pendingCredits: Money(minorUnits: pending),
                                 includedCredits: Money(minorUnits: included), paymentHolds: Money(minorUnits: holds))
    }
}

public enum RetailerCutoffStatus: String, Codable, Sendable { case open, awaitPickup }
public struct RetailerDeadline: Codable, Equatable, Sendable {
    public let cutoff: Date
    public let timeZoneID: String
    public init(cutoff: Date, timeZoneID: String) throws {
        guard cutoff.timeIntervalSinceReferenceDate.isFinite, TimeZone(identifier: timeZoneID) != nil else { throw PickupError.invalidEvidence }
        self.cutoff = cutoff; self.timeZoneID = timeZoneID
    }
    private enum CodingKeys: String, CodingKey { case cutoff, timeZoneID }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(cutoff: container.decode(Date.self, forKey: .cutoff), timeZoneID: container.decode(String.self, forKey: .timeZoneID))
    }
    /// Cutoff is a hard deadline, not the pickup slot. Expiry asserts neither fill nor refund.
    public func status(at now: Date) throws -> RetailerCutoffStatus {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw PickupError.invalidEvidence }
        return now < cutoff ? .open : .awaitPickup
    }
}
