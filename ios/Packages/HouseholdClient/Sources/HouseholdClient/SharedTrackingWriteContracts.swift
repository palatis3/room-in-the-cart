import Foundation

/// Exact normalized action returned by the server. Raw equality prevents reused
/// v1 decoders from silently dropping fields before Apply or acknowledgement.
public struct SharedTrackingAction: Codable, Equatable, Sendable {
    public let command: SharedDemandAction
    public let wire: JSONValue
    public init(_ command: SharedDemandAction) throws {
        self = try JSONDecoder().decode(Self.self, from: encoded(trackingActionComparisonWire(JSONDecoder().decode(JSONValue.self, from: encoded(command)))))
    }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["kind", "body"])
        command = try SharedDemandAction(from: decoder)
        wire = try JSONValue(from: decoder)
        let normalized = try JSONDecoder().decode(JSONValue.self, from: encoded(command))
        let received = try trackingActionComparisonWire(wire), typed = try trackingActionComparisonWire(normalized)
        try demandRequire(received == typed)
        switch command {
        case .patch(let body):
            _ = try ShopperShopCandidate(quote: body.quote, lines: body.lines, reviewedStoreBasisRevision: body.reviewedStoreBasisRevision)
            guard let observed = demandTime(body.quote.observedAt), let expires = demandTime(body.quote.expiresAt) else { throw ClientError.invalidResponse }
            try demandRequire(body.quote.currency == "USD")
            _ = try ShopperQuote(scope: body.quote.scope, complete: body.quote.complete, capMinor: body.quote.capMinor, capScope: body.quote.capScope,
                fee: body.quote.fee, taxesMinor: body.quote.taxesMinor, depositsMinor: body.quote.depositsMinor, discountsMinor: body.quote.discountsMinor,
                observedAt: observed, expiresAt: expires)
            if let edit = body.mealEdit {
                try demandIDs([edit.occurrenceId, edit.proposalId, edit.changeProposalId])
                try demandRequire(edit.baseMealRevision.map { demandRevision($0) } ?? true)
                try edit.meal?.validatePlanning()
            }
        case .request(let body): try demandIDs([body.requestId, body.previewId])
        }
    }
    public func encode(to encoder: Encoder) throws { try wire.encode(to: encoder) }
}

// Compare only the existing UUID-typed meal identity fields canonically. Keep
// received action bytes verbatim for exact retry, including old pending actions.
// Every other value/key, required null, literal and restriction remains exact.
private func trackingActionComparisonWire(_ value: JSONValue) throws -> JSONValue {
    guard case .object(var root) = value, case .object(var body) = root["body"],
          case .object(var edit) = body["mealEdit"], let meal = edit["meal"], meal != .null else { return value }
    edit["meal"] = try undoMealIdentities(meal, wire: false)
    body["mealEdit"] = .object(edit); root["body"] = .object(body); return .object(root)
}

public struct SharedTrackingRebind: Encodable, Equatable, Sendable {
    public let factId: SharedDemandID
    public let line: SharedDemandLine
    public let basket: SharedTrackingBasketLine
    public let packReview: SharedDemandPackReview
    public init(factId: SharedDemandID, line: SharedDemandLine, basket: SharedTrackingBasketLine, packReview: SharedDemandPackReview) {
        self.factId = factId; self.line = line; self.basket = basket; self.packReview = packReview
    }
}
extension SharedTrackingBasketLine: Encodable {
    /// Explicitly authored/reviewed basket facts; this does not infer copied-label provenance.
    public static func reviewed(id: SharedDemandID, name: String, packs: Int, priceMinor: Int?, feeEligible: Bool) throws -> Self {
        struct Input: Encodable {
            let id: SharedDemandID; let name: String; let packs: Int
            @SharedDemandNullable var priceMinor: Int?
            let feeEligible: Bool
        }
        return try JSONDecoder().decode(Self.self, from: encoded(Input(id: id, name: name, packs: packs, priceMinor: priceMinor, feeEligible: feeEligible)))
    }
    private enum W: String, CodingKey { case id, name, packs, priceMinor, feeEligible }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: W.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(packs, forKey: .packs)
        try c.encode(priceMinor, forKey: .priceMinor); try c.encode(feeEligible, forKey: .feeEligible)
    }
}
public enum SharedTrackingIntentKind: Equatable, Sendable {
    case adopt(action: SharedDemandAction, change: SharedDemandChange, packs: [SharedDemandPackReview])
    case change(action: SharedDemandAction, change: SharedDemandChange, packs: [SharedDemandPackReview], unboundFactIds: [SharedDemandID])
    case review(action: SharedDemandAction, packs: [SharedDemandPackReview])
    case firstAdoptionUndo(targetOperationId: SharedDemandID, packs: [SharedDemandPackReview])
    case mealOperationUndo(targetOperationId: SharedDemandID, packs: [SharedDemandPackReview])
    case rebind(bindings: [SharedTrackingRebind])
    case recover(packs: [SharedDemandPackReview])
    public var mode: String {
        switch self { case .adopt: "adopt"; case .change: "change"; case .review: "review"
        case .firstAdoptionUndo: "firstAdoptionUndo"; case .mealOperationUndo: "mealOperationUndo"; case .rebind: "rebind"; case .recover: "recover" }
    }
    var action: SharedDemandAction? {
        switch self { case .adopt(let a, _, _), .change(let a, _, _, _), .review(let a, _): a; default: nil }
    }
    var packs: [SharedDemandPackReview]? {
        switch self { case .adopt(_, _, let p), .change(_, _, let p, _), .review(_, let p), .firstAdoptionUndo(_, let p), .mealOperationUndo(_, let p), .recover(let p): p; case .rebind: nil }
    }
}
/// The original request preview supplies the mutable request revision explicitly.
/// A historic catalog's accepted source revision is never used as a new base.
public struct SharedTrackingIntent: Encodable, Equatable, Sendable {
    public let kind: SharedTrackingIntentKind
    public let base: SharedTrackingReadBinding
    public let requestPreview: ShopperPreview?
    public let actionSources: SharedTrackingActionSources?
    public let mealSources: SharedTrackingMealSources?
    public let transferredChanges: [SharedTrackingTransferredChange]?
    public init(page: SharedTrackingPage, context: SharedDemandContext, kind: SharedTrackingIntentKind, requestPreview: ShopperPreview? = nil, actionSources: SharedTrackingActionSources? = nil,
                mealSources: SharedTrackingMealSources? = nil, transferredChanges: [SharedTrackingTransferredChange]? = nil) throws {
        self.kind = kind; base = try .init(page: page, context: context); self.requestPreview = requestPreview; self.actionSources = actionSources
        self.mealSources = mealSources; self.transferredChanges = transferredChanges
        try validate(page: page)
    }
    private enum K: String, CodingKey { case mode, base, action, change, packs, unboundFactIds, targetOperationId, bindings, transferredChanges }
    private struct Base: Encodable { let shopRevision, authorityEpoch, graphRevision: Int; let stateDigest: String }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(kind.mode, forKey: .mode)
        try c.encode(Base(shopRevision: base.shopRevision, authorityEpoch: base.authorityEpoch, graphRevision: base.graphRevision, stateDigest: base.basisDigest.value), forKey: .base)
        if let transferredChanges { try c.encode(transferredChanges, forKey: .transferredChanges) }
        switch kind {
        case .adopt(let action, let change, let packs): try c.encode(action, forKey: .action); try c.encode(change, forKey: .change); try c.encode(packs, forKey: .packs)
        case .change(let action, let change, let packs, let ids): try c.encode(action, forKey: .action); try c.encode(change, forKey: .change); try c.encode(packs, forKey: .packs); try c.encode(ids, forKey: .unboundFactIds)
        case .review(let action, let packs): try c.encode(action, forKey: .action); try c.encode(packs, forKey: .packs)
        case .firstAdoptionUndo(let target, let packs), .mealOperationUndo(let target, let packs): try c.encode(target, forKey: .targetOperationId); try c.encode(packs, forKey: .packs)
        case .rebind(let bindings): try c.encode(bindings, forKey: .bindings)
        case .recover(let packs): try c.encode(packs, forKey: .packs)
        }
    }
}

public struct SharedTrackingDisclosedUnbound: Decodable, Equatable, Sendable {
    public let fact: SharedTrackingFact
    public let transferred: SharedDemandContribution?
    private enum K: String, CodingKey { case fact, transferred }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["fact", "transferred"])
        let c = try decoder.container(keyedBy: K.self)
        fact = try c.decode(SharedTrackingFact.self, forKey: .fact)
        transferred = try trackingDecode(SharedDemandContribution?.self, from: c.superDecoder(forKey: .transferred), shape: .nullable(.contribution))

    }
}

public struct SharedTrackingPickupDisclosure: Decodable, Equatable, Sendable {
    public let stateDigest: SharedTrackingDigest
    public let catalogDigest: SharedTrackingDigest
    public let priceBasisDigest: SharedTrackingDigest
    public let coverageStatement: String
    public let coverage: SharedTrackingCoverage
    public let unbound: [SharedTrackingDisclosedUnbound]
    public let unpricedBasketIds: [SharedDemandID]
    public let unresolvedPackIds: [SharedDemandID]
    public let basket: [SharedTrackingBasketLine]
    public let packReviews: [SharedDemandPackReview]
    private enum K: String, CodingKey { case stateDigest, catalogDigest, priceBasisDigest, coverageStatement, coverage, unbound, unpricedBasketIds, unresolvedPackIds, basket, packReviews }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["stateDigest", "catalogDigest", "priceBasisDigest", "coverageStatement", "coverage", "unbound", "unpricedBasketIds", "unresolvedPackIds", "basket", "packReviews"])
        let c = try decoder.container(keyedBy: K.self)
        stateDigest = try c.decode(SharedTrackingDigest.self, forKey: .stateDigest)
        catalogDigest = try c.decode(SharedTrackingDigest.self, forKey: .catalogDigest)
        priceBasisDigest = try c.decode(SharedTrackingDigest.self, forKey: .priceBasisDigest)
        coverageStatement = try c.decode(String.self, forKey: .coverageStatement)
        coverage = try c.decode(SharedTrackingCoverage.self, forKey: .coverage)
        unbound = try c.decode([SharedTrackingDisclosedUnbound].self, forKey: .unbound)
        unpricedBasketIds = try c.decode([SharedDemandID].self, forKey: .unpricedBasketIds)
        unresolvedPackIds = try c.decode([SharedDemandID].self, forKey: .unresolvedPackIds)
        basket = try c.decode([SharedTrackingBasketLine].self, forKey: .basket)
        packReviews = try trackingDecode([SharedDemandPackReview].self, from: c.superDecoder(forKey: .packReviews), shape: .array(.pack))
        try demandRequire(coverageStatement == "tracked_subtotals_only_no_complete_coverage_or_free_unbound_supply")
    }
}

public struct SharedTrackingReversedAssertions: Decodable, Equatable, Sendable {
    public let lines: [SharedDemandLine]
    public let contributions: [SharedDemandContribution]
    public let edges: [SharedDemandEdge]
    public let packReviews: [SharedDemandPackReview]
    private enum K: String, CodingKey { case lines, contributions, edges, packReviews }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["lines", "contributions", "edges", "packReviews"])
        let c = try decoder.container(keyedBy: K.self)
        lines = try trackingDecode([SharedDemandLine].self, from: c.superDecoder(forKey: .lines), shape: .array(.trackingLine))
        contributions = try trackingDecode([SharedDemandContribution].self, from: c.superDecoder(forKey: .contributions), shape: .array(.contribution))
        edges = try trackingDecode([SharedDemandEdge].self, from: c.superDecoder(forKey: .edges), shape: .array(.trackingEdge))
        packReviews = try trackingDecode([SharedDemandPackReview].self, from: c.superDecoder(forKey: .packReviews), shape: .array(.pack))

    }
}

public struct SharedTrackingBasketDelta: Decodable, Equatable, Sendable {
    public let id: SharedDemandID
    public let before: SharedTrackingBasketLine?
    public let after: SharedTrackingBasketLine?
    private enum K: String, CodingKey { case id, before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["id", "before", "after"])
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(SharedDemandID.self, forKey: .id)
        before = try c.decode(SharedTrackingBasketLine?.self, forKey: .before)
        after = try c.decode(SharedTrackingBasketLine?.self, forKey: .after)

    }
}

public struct SharedTrackingUndoDisclosure: Decodable, Equatable, Sendable {
    public let targetOperationId: SharedDemandID
    public let reversedAssertions: SharedTrackingReversedAssertions
    public let basketChanges: [SharedTrackingBasketDelta]
    public let transferredFactIds: [SharedDemandID]
    public let retainedLaterContributionIds: [SharedDemandID]
    public let beforeCoverage: SharedTrackingCoverage
    public let afterCoverage: SharedTrackingCoverage
    private enum K: String, CodingKey { case targetOperationId, reversedAssertions, basketChanges, transferredFactIds, retainedLaterContributionIds, beforeCoverage, afterCoverage }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["targetOperationId", "reversedAssertions", "basketChanges", "transferredFactIds", "retainedLaterContributionIds", "beforeCoverage", "afterCoverage"])
        let c = try decoder.container(keyedBy: K.self)
        targetOperationId = try c.decode(SharedDemandID.self, forKey: .targetOperationId)
        reversedAssertions = try c.decode(SharedTrackingReversedAssertions.self, forKey: .reversedAssertions)
        basketChanges = try c.decode([SharedTrackingBasketDelta].self, forKey: .basketChanges)
        transferredFactIds = try c.decode([SharedDemandID].self, forKey: .transferredFactIds)
        retainedLaterContributionIds = try c.decode([SharedDemandID].self, forKey: .retainedLaterContributionIds)
        beforeCoverage = try c.decode(SharedTrackingCoverage.self, forKey: .beforeCoverage)
        afterCoverage = try c.decode(SharedTrackingCoverage.self, forKey: .afterCoverage)

    }
}

public struct SharedTrackingRestoredFact: Decodable, Equatable, Sendable {
    public let factId: SharedDemandID
    public let before: SharedTrackingUnboundFact
    public let after: SharedDemandContribution
    private enum K: String, CodingKey { case factId, before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["factId", "before", "after"])
        let c = try decoder.container(keyedBy: K.self)
        factId = try c.decode(SharedDemandID.self, forKey: .factId)
        before = try c.decode(SharedTrackingUnboundFact.self, forKey: .before)
        after = try trackingDecode(SharedDemandContribution.self, from: c.superDecoder(forKey: .after), shape: .contribution)

    }
}

public struct SharedTrackingRebindDisclosure: Decodable, Equatable, Sendable {
    public let restored: [SharedTrackingRestoredFact]
    public let allocationsRestored: [SharedDemandID]
    public let before: SharedTrackingCoverage
    public let after: SharedTrackingCoverage
    private enum K: String, CodingKey { case restored, allocationsRestored, before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["restored", "allocationsRestored", "before", "after"])
        let c = try decoder.container(keyedBy: K.self)
        restored = try c.decode([SharedTrackingRestoredFact].self, forKey: .restored)
        allocationsRestored = try c.decode([SharedDemandID].self, forKey: .allocationsRestored)
        before = try c.decode(SharedTrackingCoverage.self, forKey: .before)
        after = try c.decode(SharedTrackingCoverage.self, forKey: .after)
        try demandRequire(allocationsRestored.isEmpty && restored.count <= 2000 && demandUnique(restored.map(\.factId)))
    }
}

public struct SharedTrackingRecoveryDisclosure: Decodable, Equatable, Sendable {
    public let invalidatedStateDigest: SharedTrackingDigest
    public let survivingCatalog: [SharedTrackingFact]
    public let unbound: [SharedTrackingUnboundFact]
    public let freshPackReviews: [SharedDemandPackReview]
    public let coverage: SharedTrackingCoverage
    private enum K: String, CodingKey { case invalidatedStateDigest, survivingCatalog, unbound, freshPackReviews, coverage }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["invalidatedStateDigest", "survivingCatalog", "unbound", "freshPackReviews", "coverage"])
        let c = try decoder.container(keyedBy: K.self)
        invalidatedStateDigest = try c.decode(SharedTrackingDigest.self, forKey: .invalidatedStateDigest)
        survivingCatalog = try c.decode([SharedTrackingFact].self, forKey: .survivingCatalog)
        unbound = try c.decode([SharedTrackingUnboundFact].self, forKey: .unbound)
        freshPackReviews = try trackingDecode([SharedDemandPackReview].self, from: c.superDecoder(forKey: .freshPackReviews), shape: .array(.pack))
        coverage = try c.decode(SharedTrackingCoverage.self, forKey: .coverage)

    }
}

public enum SharedTrackingChanges: Decodable, Equatable, Sendable {
    case mealActionChange(SharedTrackingMealActionDisclosure), mealOperationUndo(SharedTrackingMealUndoDisclosure)
    case none, firstAdoptionUndo(SharedTrackingUndoDisclosure), compoundAdoptionUndo(SharedTrackingCompoundUndoDisclosure), rebind(SharedTrackingRebindDisclosure), recover(SharedTrackingRecoveryDisclosure)
    private enum K: String, CodingKey { case kind, targetOperationId, component, restored, invalidatedStateDigest }
    public init(from decoder: Decoder) throws {
        if try decoder.singleValueContainer().decodeNil() { self = .none; return }
        let c = try decoder.container(keyedBy: K.self)
        if c.contains(.kind) {
            switch try c.decode(String.self, forKey: .kind) {
            case "mealActionChange": self = .mealActionChange(try .init(from: decoder))
            case "mealOperationUndo": self = .mealOperationUndo(try .init(from: decoder))
            default: throw ClientError.invalidResponse
            }
        } else if c.contains(.targetOperationId) { self = .firstAdoptionUndo(try .init(from: decoder)) }
        else if c.contains(.component) { self = .compoundAdoptionUndo(try .init(from: decoder)) }
        else if c.contains(.restored) { self = .rebind(try .init(from: decoder)) }
        else if c.contains(.invalidatedStateDigest) { self = .recover(try .init(from: decoder)) }
        else { throw ClientError.invalidResponse }
    }
}
public struct SharedTrackingDisclosure: Codable, Equatable, Sendable {
    public let changes: SharedTrackingChanges
    public let pickup: SharedTrackingPickupDisclosure
    public let money: SharedTrackingMoneyDisclosure
    public let wire: JSONValue
    private enum K: String, CodingKey { case changes, pickup, money }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["changes", "pickup", "money"])
        let c = try decoder.container(keyedBy: K.self)
        changes = try c.decode(SharedTrackingChanges.self, forKey: .changes)
        pickup = try c.decode(SharedTrackingPickupDisclosure.self, forKey: .pickup)
        money = try c.decode(SharedTrackingMoneyDisclosure.self, forKey: .money)
        wire = try JSONValue(from: decoder)
    }
    public func encode(to encoder: Encoder) throws { try wire.encode(to: encoder) }
}

public struct SharedTrackingCandidate: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let candidateId: SharedDemandID
    public let candidateDigest: SharedTrackingDigest
    public let expiresAt: String
    public let action: SharedTrackingAction
    public let after: SharedTrackingState
    public let disclosure: SharedTrackingDisclosure
    private enum K: String, CodingKey { case schemaVersion, candidateId, candidateDigest, expiresAt, action, after, disclosure }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "candidateId", "candidateDigest", "expiresAt", "action", "after", "disclosure"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        candidateId = try c.decode(SharedDemandID.self, forKey: .candidateId)
        candidateDigest = try c.decode(SharedTrackingDigest.self, forKey: .candidateDigest)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        action = try c.decode(SharedTrackingAction.self, forKey: .action)
        after = try c.decode(SharedTrackingState.self, forKey: .after)
        disclosure = try c.decode(SharedTrackingDisclosure.self, forKey: .disclosure)
        try demandRequire(schemaVersion == 2 && demandTime(expiresAt) != nil)
        try disclosure.pickup.validate(state: after)
    }
}

public struct SharedTrackingPreview: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let previewId: SharedDemandID
    public let previewDigest: SharedTrackingDigest
    public let trackingVersion: Int
    public let expiresAt: String
    public let action: SharedTrackingAction
    public let disclosure: SharedTrackingDisclosure
    public let moneyAcknowledgments: SharedTrackingMoneyAcknowledgments
    private enum K: String, CodingKey { case schemaVersion, previewId, previewDigest, trackingVersion, expiresAt, action, disclosure, moneyAcknowledgments }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "previewId", "previewDigest", "trackingVersion", "expiresAt", "action", "disclosure", "moneyAcknowledgments"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        previewId = try c.decode(SharedDemandID.self, forKey: .previewId)
        previewDigest = try c.decode(SharedTrackingDigest.self, forKey: .previewDigest)
        trackingVersion = try c.decode(Int.self, forKey: .trackingVersion)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        action = try c.decode(SharedTrackingAction.self, forKey: .action)
        disclosure = try c.decode(SharedTrackingDisclosure.self, forKey: .disclosure)
        moneyAcknowledgments = try c.decode(SharedTrackingMoneyAcknowledgments.self, forKey: .moneyAcknowledgments)
        try moneyAcknowledgments.validate(money: disclosure.money.after)
        try demandRequire(schemaVersion == 2 && trackingVersion == 2 && demandTime(expiresAt) != nil)
    }
}

/// Ephemeral source-bearing reviews; never serialize these as a portable grant.
public struct SharedTrackingCandidateReview: Equatable, Sendable {
    public let page: SharedTrackingPage
    public let intent: SharedTrackingIntent
    public let candidate: SharedTrackingCandidate
    init(page: SharedTrackingPage, intent: SharedTrackingIntent, candidate: SharedTrackingCandidate) throws {
        self.page = page; self.intent = intent; self.candidate = candidate
        try validate()
    }
}
public struct SharedTrackingAcceptedReview: Equatable, Sendable {
    public let candidateReview: SharedTrackingCandidateReview
    public let preview: SharedTrackingPreview
    init(candidateReview: SharedTrackingCandidateReview, preview: SharedTrackingPreview) throws {
        self.candidateReview = candidateReview; self.preview = preview
        try validate()
    }
}

extension TrackingWireShape {
    static var trackingLine: Self { .object(["id": .scalar, "name": .scalar, "unit": .scalar, "originalOrder": .scalar, "trashedAt": .scalar]) }
    static var trackingEdge: Self { .object(["id": .scalar, "kind": .scalar, "demandId": .scalar, "supplyId": .scalar, "quantity": .quantity, "confirmation": .object(["productMatchConfirmed": .scalar, "confirmedAt": .scalar, "evidence": .scalar])]) }
}
