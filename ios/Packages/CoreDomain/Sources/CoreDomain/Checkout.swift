import Foundation

public enum CheckoutScope: String, Codable, Sendable { case item, dinner, wholeCheckout }
public enum ShoppingMode: String, Codable, Sendable { case pickup, delivery, inStore }

/// Evidence basis for a quote. Dates and source labels are evidence, never an implicit live feed.
public struct CheckoutContext: Codable, Equatable, Sendable {
    public let storeID: String
    public let branchID: String
    public let mode: ShoppingMode
    public let slot: String
    public let commitmentsID: UUID
    public let observedAt: Date
    public let source: String
    public init(storeID: String, branchID: String, mode: ShoppingMode, slot: String,
                commitmentsID: UUID, observedAt: Date, source: String) {
        self.storeID = storeID; self.branchID = branchID; self.mode = mode; self.slot = slot
        self.commitmentsID = commitmentsID; self.observedAt = observedAt; self.source = source
    }
}

/// All costs/discount magnitudes are nonnegative. Unknown is distinct from an observed zero.
public enum CostEvidence: Codable, Equatable, Sendable {
    case exact(Money)
    case bounded(lower: Money, upper: Money, reason: String)
    case unknown(reason: String)
}

public struct CheckoutLine: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// Complete line cost, including every purchased package, not a unit sticker price.
    public let cost: CostEvidence
    public let thresholdEligible: Bool
    public init(id: UUID, name: String, cost: CostEvidence, thresholdEligible: Bool = true) {
        self.id = id; self.name = name; self.cost = cost; self.thresholdEligible = thresholdEligible
    }
    public init(id: UUID, name: String, packages: Int64, packagePrice: Money, thresholdEligible: Bool = true) throws {
        guard packages >= 0, packagePrice.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
        self.init(id: id, name: name, cost: .exact(try packagePrice.multiplied(by: packages)), thresholdEligible: thresholdEligible)
    }
}

public enum FeeThresholdBasis: String, Codable, Sendable {
    case eligibleItemsBeforeDiscounts, eligibleItemsAfterEligibleDiscounts
}
public enum CheckoutFeeRule: Codable, Equatable, Sendable {
    case fixed(CostEvidence)
    /// Threshold is inclusive: eligible subtotal >= threshold waives the fee.
    case waivedAt(threshold: Money, belowThreshold: CostEvidence, basis: FeeThresholdBasis)
}
public struct CheckoutFee: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let rule: CheckoutFeeRule
    public init(id: String, rule: CheckoutFeeRule) { self.id = id; self.rule = rule }
}
public struct CheckoutDiscount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let amount: CostEvidence
    public let reducesEligibleSubtotal: Bool
    public init(id: String, amount: CostEvidence, reducesEligibleSubtotal: Bool) {
        self.id = id; self.amount = amount; self.reducesEligibleSubtotal = reducesEligibleSubtotal
    }
}

/// Inclusive totals cannot also carry component charges, preventing double-added fees/tax.
public enum CheckoutPricing: Codable, Equatable, Sendable {
    case inclusiveTotal(CostEvidence)
    case components(lines: [CheckoutLine], lineSetComplete: Bool, fees: [CheckoutFee],
                    discounts: [CheckoutDiscount], tax: CostEvidence, deposits: CostEvidence)
}
public struct CheckoutQuote: Codable, Equatable, Sendable {
    public let scope: CheckoutScope
    public let context: CheckoutContext
    public let pricing: CheckoutPricing
    public init(scope: CheckoutScope, context: CheckoutContext, pricing: CheckoutPricing) {
        self.scope = scope; self.context = context; self.pricing = pricing
    }
}
public struct CheckoutCap: Codable, Equatable, Sendable {
    public let scope: CheckoutScope
    public let commitmentsID: UUID
    public let amount: Money
    public init(scope: CheckoutScope, commitmentsID: UUID, amount: Money) {
        self.scope = scope; self.commitmentsID = commitmentsID; self.amount = amount
    }
}
public struct CheckoutUncertainty: Codable, Equatable, Sendable {
    public let component: String
    public let reason: String
}
public struct CheckoutAmount: Codable, Equatable, Sendable {
    public let lowerBound: Money
    public let upperBound: Money?
    public var exact: Money? { upperBound == lowerBound ? lowerBound : nil }
}
public enum CheckoutCapAssessment: Codable, Equatable, Sendable {
    case notProvided
    case scopeMismatch
    case unresolved
    case within(maximumCheckout: Money, minimumHeadroom: Money)
    case over(minimumCheckout: Money, minimumOverage: Money)
}
public struct CheckoutResult: Codable, Equatable, Sendable {
    public let scope: CheckoutScope
    public let total: CheckoutAmount
    public let uncertainties: [CheckoutUncertainty]
    public let cap: CheckoutCapAssessment
    public var isWholeCheckoutWithinCap: Bool {
        guard scope == .wholeCheckout else { return false }
        if case .within = cap { return true }
        return false
    }
}
public struct CheckoutComparison: Codable, Equatable, Sendable {
    public let before: CheckoutResult
    public let after: CheckoutResult
    /// Signed after minus before. Nil when exact matched-basis comparison is unavailable.
    public let change: Money?
}
public enum CheckoutError: Error, Equatable, Sendable {
    case invalidEvidence, duplicateIdentity, incomparableBasis
    case staleRevision, operationConflict, alreadyUndone, placedRequiresAmendment
    case missingSnapshot, invalidPlacement, invalidAmendment
}

public enum CheckoutEngine {
    public static let roundingPolicy = "USD-cents-exact; inclusive-fee-threshold"

    public static func evaluate(_ quote: CheckoutQuote, cap: CheckoutCap? = nil) throws -> CheckoutResult {
        try validate(quote.context)
        var issues: [CheckoutUncertainty] = []
        let total: Interval
        switch quote.pricing {
        case let .inclusiveTotal(evidence):
            total = try interval(evidence, component: "inclusiveTotal", issues: &issues)
        case let .components(lines, complete, fees, discounts, tax, deposits):
            guard Set(lines.map(\.id)).count == lines.count,
                  Set(fees.map(\.id)).count == fees.count,
                  Set(discounts.map(\.id)).count == discounts.count else { throw CheckoutError.duplicateIdentity }
            var goods = Interval.zero, eligible = Interval.zero
            for line in lines {
                guard !line.name.isEmpty, line.name.utf8.count <= 2_048 else { throw CheckoutError.invalidEvidence }
                let cost = try interval(line.cost, component: "line:\(line.id.uuidString)", issues: &issues)
                goods = try goods.adding(cost)
                if line.thresholdEligible { eligible = try eligible.adding(cost) }
            }
            if !complete {
                goods = Interval(lower: goods.lower, upper: nil)
                eligible = Interval(lower: eligible.lower, upper: nil)
                issues.append(.init(component: "lineSet", reason: "Remaining original items are not fully priced"))
            }
            var allDiscounts = Interval.zero, eligibleDiscounts = Interval.zero
            for discount in discounts {
                guard !discount.id.isEmpty else { throw CheckoutError.invalidEvidence }
                let amount = try interval(discount.amount, component: "discount:\(discount.id)", issues: &issues)
                allDiscounts = try allDiscounts.adding(amount)
                if discount.reducesEligibleSubtotal { eligibleDiscounts = try eligibleDiscounts.adding(amount) }
            }
            let netEligible = try eligible.subtractingDiscount(eligibleDiscounts)
            var charges = Interval.zero
            for fee in fees {
                guard !fee.id.isEmpty else { throw CheckoutError.invalidEvidence }
                let amount: Interval
                switch fee.rule {
                case let .fixed(evidence):
                    amount = try interval(evidence, component: "fee:\(fee.id)", issues: &issues)
                case let .waivedAt(threshold, evidence, basis):
                    guard threshold.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
                    let subtotal = basis == .eligibleItemsBeforeDiscounts ? eligible : netEligible
                    // Validate the evidence even if the fee is waived; do not invent a charge.
                    var feeIssues: [CheckoutUncertainty] = []
                    let below = try interval(evidence, component: "fee:\(fee.id)", issues: &feeIssues)
                    if subtotal.lower >= threshold.minorUnits { amount = .zero }
                    else if let upper = subtotal.upper, upper < threshold.minorUnits {
                        amount = below
                        issues += feeIssues
                    } else {
                        amount = Interval(lower: 0, upper: below.upper)
                        issues += feeIssues
                        issues.append(.init(component: "fee:\(fee.id)", reason: "Eligible subtotal may cross the fee-waiver threshold"))
                    }
                }
                charges = try charges.adding(amount)
            }
            let taxAmount = try interval(tax, component: "tax", issues: &issues)
            let depositAmount = try interval(deposits, component: "deposits", issues: &issues)
            total = try goods.subtractingDiscount(allDiscounts).adding(charges).adding(taxAmount).adding(depositAmount)
        }
        let assessment: CheckoutCapAssessment
        if let cap {
            guard cap.amount.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
            if cap.scope != quote.scope || cap.commitmentsID != quote.context.commitmentsID { assessment = .scopeMismatch }
            else if let upper = total.upper, upper <= cap.amount.minorUnits {
                assessment = .within(maximumCheckout: Money(minorUnits: upper), minimumHeadroom: Money(minorUnits: cap.amount.minorUnits - upper))
            } else if total.lower > cap.amount.minorUnits {
                assessment = .over(minimumCheckout: Money(minorUnits: total.lower), minimumOverage: Money(minorUnits: total.lower - cap.amount.minorUnits))
            } else { assessment = .unresolved }
        } else { assessment = .notProvided }
        return CheckoutResult(scope: quote.scope,
                              total: CheckoutAmount(lowerBound: Money(minorUnits: total.lower), upperBound: total.upper.map { Money(minorUnits: $0) }),
                              uncertainties: issues, cap: assessment)
    }

    public static func compare(before: CheckoutQuote, after: CheckoutQuote, cap: CheckoutCap? = nil) throws -> CheckoutComparison {
        let a = before.context, b = after.context
        guard before.scope == after.scope, a.storeID == b.storeID, a.branchID == b.branchID,
              a.mode == b.mode, a.slot == b.slot, a.commitmentsID == b.commitmentsID else { throw CheckoutError.incomparableBasis }
        let first = try evaluate(before, cap: cap), second = try evaluate(after, cap: cap)
        let change: Money?
        if let old = first.total.exact, let new = second.total.exact { change = try new.subtracting(old) }
        else { change = nil }
        return CheckoutComparison(before: first, after: second, change: change)
    }

    /// Remaining original charges consume the inherited line allowance. A nonpositive
    /// remainder means no additional replacement spend is authorized by this ceiling.
    /// The revised COMPLETE quote still must be evaluated jointly, including fee changes.
    public static func replacementCeiling(lineAllowance: Money, retainedOriginalCharge: Money,
                                          wholeCheckoutRemaining: Money?) throws -> Money? {
        guard lineAllowance.minorUnits >= 0, retainedOriginalCharge.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
        guard let wholeCheckoutRemaining else { return nil }
        let line = max(0, try lineAllowance.subtracting(retainedOriginalCharge).minorUnits)
        return Money(minorUnits: min(line, max(0, wholeCheckoutRemaining.minorUnits)))
    }

    private static func validate(_ context: CheckoutContext) throws {
        guard !context.storeID.isEmpty, !context.branchID.isEmpty, !context.slot.isEmpty,
              !context.source.isEmpty, context.observedAt.timeIntervalSinceReferenceDate.isFinite else { throw CheckoutError.invalidEvidence }
    }
    private static func interval(_ evidence: CostEvidence, component: String, issues: inout [CheckoutUncertainty]) throws -> Interval {
        switch evidence {
        case let .exact(amount):
            guard amount.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
            return Interval(lower: amount.minorUnits, upper: amount.minorUnits)
        case let .bounded(lower, upper, reason):
            guard lower.minorUnits >= 0, upper >= lower, !reason.isEmpty else { throw CheckoutError.invalidEvidence }
            if lower != upper { issues.append(.init(component: component, reason: reason)) }
            return Interval(lower: lower.minorUnits, upper: upper.minorUnits)
        case let .unknown(reason):
            guard !reason.isEmpty else { throw CheckoutError.invalidEvidence }
            issues.append(.init(component: component, reason: reason))
            return Interval(lower: 0, upper: nil)
        }
    }
    private struct Interval {
        let lower: Int64
        let upper: Int64?
        static let zero = Interval(lower: 0, upper: 0)
        func adding(_ other: Self) throws -> Self {
            let upper = try self.upper.flatMap { a in try other.upper.map { try checkedAdd(a, $0) } }
            return Self(lower: try checkedAdd(lower, other.lower), upper: upper)
        }
        func subtractingDiscount(_ discount: Self) throws -> Self {
            let lower = discount.upper.map { max(0, self.lower - $0) } ?? 0
            let upper = self.upper.map { max(0, $0 - discount.lower) }
            return Self(lower: lower, upper: upper)
        }
    }
}

public struct BasketLine: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let quantity: Quantity
    public let expectedCost: CostEvidence
    public init(id: UUID, name: String, quantity: Quantity, expectedCost: CostEvidence) {
        self.id = id; self.name = name; self.quantity = quantity; self.expectedCost = expectedCost
    }
}
public enum BasketChange: Codable, Equatable, Sendable {
    case upsert(BasketLine)
    case remove(UUID)
    var lineID: UUID { switch self { case let .upsert(line): return line.id; case let .remove(id): return id } }
}
public struct BasketProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let baseRevisionID: UUID
    public let revisionID: UUID
    public let changes: [BasketChange]
    public init(id: UUID, baseRevisionID: UUID, revisionID: UUID, changes: [BasketChange]) {
        self.id = id; self.baseRevisionID = baseRevisionID; self.revisionID = revisionID; self.changes = changes
    }
}
public enum BasketRevisionReason: Codable, Equatable, Sendable { case initial, applied(UUID), undone(UUID) }
public struct BasketRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let number: Int64
    public let parentID: UUID?
    public let lines: [BasketLine]
    public let createdAt: Date
    public let reason: BasketRevisionReason
}
public struct HandoffSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let basketID: UUID
    public let revision: BasketRevision
    public let createdAt: Date
}
public enum HandoffActionKind: String, Codable, Sendable {
    case prepared, copyAttempted, copied, shareOpened, shareCancelled, retailerOpened, intentionallySent, acknowledged
}
public struct HandoffAction: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let snapshotID: UUID
    public let kind: HandoffActionKind
    public let occurredAt: Date
    /// Actual destination if known. Nil never implies a particular recipient.
    public let destination: String?
    public init(id: UUID, snapshotID: UUID, kind: HandoffActionKind, occurredAt: Date, destination: String? = nil) {
        self.id = id; self.snapshotID = snapshotID; self.kind = kind; self.occurredAt = occurredAt; self.destination = destination
    }
}
public struct ReportedPlacement: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let intentID: UUID
    public let snapshotID: UUID
    public let reportedAt: Date
    public init(id: UUID, intentID: UUID, snapshotID: UUID, reportedAt: Date) {
        self.id = id; self.intentID = intentID; self.snapshotID = snapshotID; self.reportedAt = reportedAt
    }
}
public struct ConfirmedAmendment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let placementID: UUID
    public let previousAmendmentID: UUID?
    public let lines: [BasketLine]
    public let confirmedAt: Date
    public let retailerReference: String
    public init(id: UUID, placementID: UUID, previousAmendmentID: UUID?, lines: [BasketLine], confirmedAt: Date, retailerReference: String) {
        self.id = id; self.placementID = placementID; self.previousAmendmentID = previousAmendmentID
        self.lines = lines; self.confirmedAt = confirmedAt; self.retailerReference = retailerReference
    }
}
public enum BasketPhase: String, Codable, Sendable { case draft, frozen, reportedPlaced }

/// Local private lifecycle. Shared shopper authority belongs to the service and is never
/// conferred by decoding this value. Caller persists each returned state atomically.
public struct BasketPlan: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public private(set) var revisions: [BasketRevision]
    public private(set) var snapshots: [HandoffSnapshot] = []
    public private(set) var handoffActions: [HandoffAction] = []
    public private(set) var placements: [ReportedPlacement] = []
    public private(set) var amendments: [ConfirmedAmendment] = []
    private var applied: [Application] = []
    private var undos: [Undo] = []
    public var current: BasketRevision { revisions[revisions.count - 1] }
    public var phase: BasketPhase {
        if !placements.isEmpty { return .reportedPlaced }
        return snapshots.contains(where: { $0.revision.id == current.id }) ? .frozen : .draft
    }
    public var reportedOrderLines: [BasketLine]? {
        guard let placed = placements.first, let frozen = snapshots.first(where: { $0.id == placed.snapshotID }) else { return nil }
        return frozen.revision.lines
    }
    public var effectiveOrderLines: [BasketLine]? { amendments.last?.lines ?? reportedOrderLines }
    public init(id: UUID, revisionID: UUID, lines: [BasketLine], createdAt: Date) throws {
        try Self.validate(lines, at: createdAt)
        self.id = id
        revisions = [BasketRevision(id: revisionID, number: 1, parentID: nil, lines: lines, createdAt: createdAt, reason: .initial)]
    }

    private enum CodingKeys: String, CodingKey {
        case id, revisions, snapshots, handoffActions, placements, amendments, applied, undos
    }
    /// Archives are untrusted input. Rebuild every revision through its normal command
    /// and reject fabricated/empty histories before any consumer can access `current`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let revisions = try container.decode([BasketRevision].self, forKey: .revisions)
        let applications = try container.decode([Application].self, forKey: .applied)
        let undos = try container.decode([Undo].self, forKey: .undos)
        guard let first = revisions.first, first.number == 1, first.parentID == nil, first.reason == .initial,
              revisions.count <= 100_000, Set(revisions.map(\.id)).count == revisions.count,
              Set(applications.map { $0.proposal.id }).count == applications.count,
              Set(undos.map(\.operationID)).count == undos.count else { throw CheckoutError.invalidEvidence }
        try self.init(id: id, revisionID: first.id, lines: first.lines, createdAt: first.createdAt)
        for revision in revisions.dropFirst() {
            let result: BasketRevision
            switch revision.reason {
            case let .applied(operation):
                guard let receipt = applications.first(where: { $0.proposal.id == operation }),
                      receipt.before == current.lines, receipt.revision == revision else { throw CheckoutError.invalidEvidence }
                result = try apply(receipt.proposal, at: revision.createdAt)
            case let .undone(proposal):
                guard let receipt = undos.first(where: { $0.revision.id == revision.id }),
                      receipt.proposalID == proposal else { throw CheckoutError.invalidEvidence }
                result = try undo(operationID: receipt.operationID, proposalID: proposal,
                                  expectedRevision: receipt.expectedRevision, revisionID: revision.id, at: revision.createdAt)
            case .initial: throw CheckoutError.invalidEvidence
            }
            guard result == revision else { throw CheckoutError.invalidEvidence }
        }
        guard applied == applications, self.undos == undos else { throw CheckoutError.invalidEvidence }
        let snapshots = try container.decode([HandoffSnapshot].self, forKey: .snapshots)
        guard Set(snapshots.map(\.id)).count == snapshots.count else { throw CheckoutError.duplicateIdentity }
        for snapshot in snapshots {
            guard snapshot.basketID == id, revisions.contains(snapshot.revision),
                  snapshot.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw CheckoutError.invalidEvidence }
        }
        self.snapshots = snapshots
        for action in try container.decode([HandoffAction].self, forKey: .handoffActions) {
            guard try recordHandoff(action) else { throw CheckoutError.duplicateIdentity }
        }
        for placement in try container.decode([ReportedPlacement].self, forKey: .placements) {
            guard try reportPlaced(placement) else { throw CheckoutError.duplicateIdentity }
        }
        for amendment in try container.decode([ConfirmedAmendment].self, forKey: .amendments) {
            guard try confirmAmendment(amendment) else { throw CheckoutError.duplicateIdentity }
        }
    }

    @discardableResult
    public mutating func apply(_ proposal: BasketProposal, at: Date) throws -> BasketRevision {
        if let receipt = applied.first(where: { $0.proposal.id == proposal.id }) {
            guard receipt.proposal == proposal else { throw CheckoutError.operationConflict }
            return receipt.revision
        }
        guard placements.isEmpty else { throw CheckoutError.placedRequiresAmendment }
        guard current.id == proposal.baseRevisionID else { throw CheckoutError.staleRevision }
        guard !proposal.changes.isEmpty, Set(proposal.changes.map(\.lineID)).count == proposal.changes.count,
              !revisions.contains(where: { $0.id == proposal.revisionID }) else { throw CheckoutError.duplicateIdentity }
        var lines = current.lines
        for change in proposal.changes {
            switch change {
            case let .upsert(line):
                if let index = lines.firstIndex(where: { $0.id == line.id }) { lines[index] = line }
                else { lines.append(line) }
            case let .remove(id):
                guard lines.contains(where: { $0.id == id }) else { throw CheckoutError.invalidEvidence }
                lines.removeAll { $0.id == id }
            }
        }
        try Self.validate(lines, at: at)
        let revision = BasketRevision(id: proposal.revisionID, number: try checkedAdd(current.number, 1),
                                      parentID: current.id, lines: lines, createdAt: at, reason: .applied(proposal.id))
        applied.append(Application(proposal: proposal, before: current.lines, revision: revision))
        revisions.append(revision)
        return revision
    }

    /// Undo is a new revision. It restores only this proposal's affected lines and
    /// preserves unrelated later edits; changed affected lines require another review.
    @discardableResult
    public mutating func undo(operationID: UUID, proposalID: UUID, expectedRevision: UUID, revisionID: UUID, at: Date) throws -> BasketRevision {
        if let old = undos.first(where: { $0.operationID == operationID }) {
            guard old.proposalID == proposalID, old.expectedRevision == expectedRevision, old.revision.id == revisionID else { throw CheckoutError.operationConflict }
            return old.revision
        }
        guard placements.isEmpty else { throw CheckoutError.placedRequiresAmendment }
        guard current.id == expectedRevision else { throw CheckoutError.staleRevision }
        guard !undos.contains(where: { $0.proposalID == proposalID }) else { throw CheckoutError.alreadyUndone }
        guard let receipt = applied.first(where: { $0.proposal.id == proposalID }) else { throw CheckoutError.invalidEvidence }
        guard !revisions.contains(where: { $0.id == revisionID }) else { throw CheckoutError.duplicateIdentity }
        var lines = current.lines
        for id in receipt.proposal.changes.map(\.lineID) {
            guard lines.first(where: { $0.id == id }) == receipt.revision.lines.first(where: { $0.id == id }) else { throw CheckoutError.staleRevision }
            let original = receipt.before.first(where: { $0.id == id })
            if let index = lines.firstIndex(where: { $0.id == id }) {
                if let original { lines[index] = original } else { lines.remove(at: index) }
            } else if let original {
                let formerIndex = receipt.before.firstIndex(where: { $0.id == id }) ?? lines.endIndex
                lines.insert(original, at: min(formerIndex, lines.endIndex))
            }
        }
        try Self.validate(lines, at: at)
        let revision = BasketRevision(id: revisionID, number: try checkedAdd(current.number, 1), parentID: current.id,
                                      lines: lines, createdAt: at, reason: .undone(proposalID))
        undos.append(Undo(operationID: operationID, proposalID: proposalID, expectedRevision: expectedRevision, revision: revision))
        revisions.append(revision)
        return revision
    }

    @discardableResult
    public mutating func freeze(snapshotID: UUID, expectedRevision: UUID, at: Date) throws -> HandoffSnapshot {
        if let snapshot = snapshots.first(where: { $0.id == snapshotID }) {
            guard snapshot.revision.id == expectedRevision else { throw CheckoutError.operationConflict }
            return snapshot
        }
        guard placements.isEmpty else { throw CheckoutError.placedRequiresAmendment }
        guard current.id == expectedRevision else { throw CheckoutError.staleRevision }
        guard at.timeIntervalSinceReferenceDate.isFinite else { throw CheckoutError.invalidEvidence }
        let snapshot = HandoffSnapshot(id: snapshotID, basketID: id, revision: current, createdAt: at)
        snapshots.append(snapshot)
        return snapshot
    }

    @discardableResult
    public mutating func recordHandoff(_ action: HandoffAction) throws -> Bool {
        if let old = handoffActions.first(where: { $0.id == action.id }) {
            guard old == action else { throw CheckoutError.operationConflict }; return false
        }
        guard snapshots.contains(where: { $0.id == action.snapshotID }), action.occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw CheckoutError.missingSnapshot }
        handoffActions.append(action)
        return true
    }

    @discardableResult
    public mutating func reportPlaced(_ placement: ReportedPlacement) throws -> Bool {
        if let old = placements.first(where: { $0.id == placement.id }) {
            guard old == placement else { throw CheckoutError.operationConflict }; return false
        }
        guard placements.isEmpty, placement.reportedAt.timeIntervalSinceReferenceDate.isFinite else { throw CheckoutError.invalidPlacement }
        guard let snapshot = snapshots.first(where: { $0.id == placement.snapshotID }) else { throw CheckoutError.missingSnapshot }
        guard snapshot.revision.id == current.id else { throw CheckoutError.staleRevision }
        placements.append(placement)
        return true
    }

    @discardableResult
    public mutating func confirmAmendment(_ amendment: ConfirmedAmendment) throws -> Bool {
        if let old = amendments.first(where: { $0.id == amendment.id }) {
            guard old == amendment else { throw CheckoutError.operationConflict }; return false
        }
        guard placements.first?.id == amendment.placementID, !amendment.retailerReference.isEmpty,
              amendment.previousAmendmentID == amendments.last?.id else { throw CheckoutError.invalidAmendment }
        try Self.validate(amendment.lines, at: amendment.confirmedAt)
        amendments.append(amendment)
        return true
    }

    private struct Application: Codable, Equatable, Sendable { let proposal: BasketProposal; let before: [BasketLine]; let revision: BasketRevision }
    private struct Undo: Codable, Equatable, Sendable { let operationID: UUID; let proposalID: UUID; let expectedRevision: UUID; let revision: BasketRevision }
    private static func validate(_ lines: [BasketLine], at: Date) throws {
        guard at.timeIntervalSinceReferenceDate.isFinite, Set(lines.map(\.id)).count == lines.count else { throw CheckoutError.duplicateIdentity }
        for line in lines {
            guard !line.name.isEmpty, line.name.utf8.count <= 2_048 else { throw CheckoutError.invalidEvidence }
            try line.quantity.validate()
            switch line.expectedCost {
            case let .exact(amount): guard amount.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
            case let .bounded(lower, upper, reason): guard lower.minorUnits >= 0, upper >= lower, !reason.isEmpty else { throw CheckoutError.invalidEvidence }
            case let .unknown(reason): guard !reason.isEmpty else { throw CheckoutError.invalidEvidence }
            }
        }
    }
}
