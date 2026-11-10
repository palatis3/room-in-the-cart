import Foundation

// Read-only v2 DTOs. They do not authorize, calculate food, create Apply, or
// recover history. Server tracking digests use a DIFFERENT canonicalization
// from the legacy storage digest; no digest is recomputed by this slice.
public struct SharedTrackingDigest: Decodable, Equatable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
        try demandRequire(value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
    }
}
/// The quote field carries the server legacy storage digest, not a tracking hash.
public struct SharedTrackingQuoteDigest: Decodable, Equatable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
        try demandRequire(value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
    }
}
public struct SharedTrackingFact: Decodable, Equatable, Sendable {
    public let id: SharedDemandID
    public let revision: Int
    public let source: SharedDemandSource
    public let sourceLabel: String
    public let originalText: String
    public let originalQuantityText: String?
    public let quantity: SharedDemandQuantity?
    public let sourceExclusions: [SharedDemandSourceExclusion]
    public let requiredLineId: SharedDemandID?
    private enum K: String, CodingKey { case id, revision, source, sourceLabel, originalText, originalQuantityText, quantity, sourceExclusions, requiredLineId }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["id", "revision", "source", "sourceLabel", "originalText", "originalQuantityText", "quantity", "sourceExclusions", "requiredLineId"])
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(SharedDemandID.self, forKey: .id)
        revision = try c.decode(Int.self, forKey: .revision)
        source = try c.decode(SharedDemandSource.self, forKey: .source)
        sourceLabel = try c.decode(String.self, forKey: .sourceLabel)
        originalText = try c.decode(String.self, forKey: .originalText)
        originalQuantityText = try c.decode(String?.self, forKey: .originalQuantityText)
        quantity = try trackingDecode(SharedDemandQuantity?.self, from: c.superDecoder(forKey: .quantity), shape: .nullable(.quantity))
        sourceExclusions = try trackingDecode([SharedDemandSourceExclusion].self, from: c.superDecoder(forKey: .sourceExclusions), shape: .array(.restriction))
        requiredLineId = try c.decode(SharedDemandID?.self, forKey: .requiredLineId)
        try validate()
    }
}

public struct SharedTrackingBasketLine: Decodable, Equatable, Sendable {
    public let id: SharedDemandID
    public let name: String
    public let packs: Int
    public let priceMinor: Int?
    public let feeEligible: Bool
    private enum K: String, CodingKey { case id, name, packs, priceMinor, feeEligible }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["id", "name", "packs", "priceMinor", "feeEligible"])
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(SharedDemandID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        packs = try c.decode(Int.self, forKey: .packs)
        priceMinor = try c.decode(Int?.self, forKey: .priceMinor)
        feeEligible = try c.decode(Bool.self, forKey: .feeEligible)
        try demandRequire(demandText(name) && (1...10000).contains(packs) && (priceMinor.map { $0 >= 0 && $0 <= 9007199254740991 } ?? true))
    }
}

public struct SharedTrackingBinding: Decodable, Equatable, Sendable {
    public let factId: SharedDemandID
    public let contributionId: SharedDemandID
    private enum K: String, CodingKey { case factId, contributionId }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["factId", "contributionId"])
        let c = try decoder.container(keyedBy: K.self)
        factId = try c.decode(SharedDemandID.self, forKey: .factId)
        contributionId = try c.decode(SharedDemandID.self, forKey: .contributionId)

    }
}

public struct SharedTrackingUnboundFact: Decodable, Equatable, Sendable {
    public let factId: SharedDemandID
    public let transferred: SharedDemandContribution?
    private enum K: String, CodingKey { case factId, transferred }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["factId", "transferred"])
        let c = try decoder.container(keyedBy: K.self)
        factId = try c.decode(SharedDemandID.self, forKey: .factId)
        transferred = try trackingDecode(SharedDemandContribution?.self, from: c.superDecoder(forKey: .transferred), shape: .nullable(.contribution))

    }
}

public struct SharedTrackingState: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityEpoch: Int
    public let privacyRevision: Int
    public let quoteDigest: SharedTrackingQuoteDigest
    public let graph: SharedDemandGraph
    public let basket: [SharedTrackingBasketLine]
    public let catalog: [SharedTrackingFact]
    public let bindings: [SharedTrackingBinding]
    public let unbound: [SharedTrackingUnboundFact]
    public let legacyLineIds: [SharedDemandID]
    public let packReviews: [SharedDemandPackReview]
    private enum K: String, CodingKey { case schemaVersion, authorityEpoch, privacyRevision, quoteDigest, graph, basket, catalog, bindings, unbound, legacyLineIds, packReviews }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "authorityEpoch", "privacyRevision", "quoteDigest", "graph", "basket", "catalog", "bindings", "unbound", "legacyLineIds", "packReviews"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        privacyRevision = try c.decode(Int.self, forKey: .privacyRevision)
        quoteDigest = try c.decode(SharedTrackingQuoteDigest.self, forKey: .quoteDigest)
        graph = try trackingDecode(SharedDemandGraph.self, from: c.superDecoder(forKey: .graph), shape: .graph)
        basket = try c.decode([SharedTrackingBasketLine].self, forKey: .basket)
        catalog = try c.decode([SharedTrackingFact].self, forKey: .catalog)
        bindings = try c.decode([SharedTrackingBinding].self, forKey: .bindings)
        unbound = try c.decode([SharedTrackingUnboundFact].self, forKey: .unbound)
        legacyLineIds = try c.decode([SharedDemandID].self, forKey: .legacyLineIds)
        packReviews = try trackingDecode([SharedDemandPackReview].self, from: c.superDecoder(forKey: .packReviews), shape: .array(.pack))
        try validate()
    }
}

public struct SharedTrackingSurvivingState: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityEpoch: Int
    public let privacyRevision: Int
    public let quoteDigest: SharedTrackingQuoteDigest
    public let graph: SharedDemandGraph
    public let basket: [SharedTrackingBasketLine]
    public let catalog: [SharedTrackingFact]
    public let bindings: [SharedTrackingBinding]
    public let unbound: [SharedTrackingUnboundFact]
    public let legacyLineIds: [SharedDemandID]
    private enum K: String, CodingKey { case schemaVersion, authorityEpoch, privacyRevision, quoteDigest, graph, basket, catalog, bindings, unbound, legacyLineIds }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "authorityEpoch", "privacyRevision", "quoteDigest", "graph", "basket", "catalog", "bindings", "unbound", "legacyLineIds"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        privacyRevision = try c.decode(Int.self, forKey: .privacyRevision)
        quoteDigest = try c.decode(SharedTrackingQuoteDigest.self, forKey: .quoteDigest)
        graph = try trackingDecode(SharedDemandGraph.self, from: c.superDecoder(forKey: .graph), shape: .graph)
        basket = try c.decode([SharedTrackingBasketLine].self, forKey: .basket)
        catalog = try c.decode([SharedTrackingFact].self, forKey: .catalog)
        bindings = try c.decode([SharedTrackingBinding].self, forKey: .bindings)
        unbound = try c.decode([SharedTrackingUnboundFact].self, forKey: .unbound)
        legacyLineIds = try c.decode([SharedDemandID].self, forKey: .legacyLineIds)
        try trackingValidateCore(self)
    }
}

public struct SharedTrackingProjection: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case reviewRequired }
    public let schemaVersion: Int
    public let status: Status
    public let invalidatedStateDigest: SharedTrackingDigest
    public let previousPrivacyRevision: Int
    public let state: SharedTrackingSurvivingState
    private enum K: String, CodingKey { case schemaVersion, status, invalidatedStateDigest, previousPrivacyRevision, state }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "status", "invalidatedStateDigest", "previousPrivacyRevision", "state"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        status = try c.decode(Status.self, forKey: .status)
        invalidatedStateDigest = try c.decode(SharedTrackingDigest.self, forKey: .invalidatedStateDigest)
        previousPrivacyRevision = try c.decode(Int.self, forKey: .previousPrivacyRevision)
        state = try c.decode(SharedTrackingSurvivingState.self, forKey: .state)
        try demandRequire(schemaVersion == 1 && demandRevision(previousPrivacyRevision, zero: true) && state.privacyRevision > previousPrivacyRevision)
    }
}

public struct SharedTrackingCoverage: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case partial, unknown, tracked }
    public let status: Status
    public let trackedSubtotals: [SharedDemandLineTotal]
    public let completeFoodCoverage: Bool
    public let unboundFactIds: [SharedDemandID]
    public let untrackedBasketIds: [SharedDemandID]
    public let protectedUnboundFactIds: [SharedDemandID]
    public let allocatableUnboundFactIds: [SharedDemandID]
    private enum K: String, CodingKey { case status, trackedSubtotals, completeFoodCoverage, unboundFactIds, untrackedBasketIds, protectedUnboundFactIds, allocatableUnboundFactIds }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["status", "trackedSubtotals", "completeFoodCoverage", "unboundFactIds", "untrackedBasketIds", "protectedUnboundFactIds", "allocatableUnboundFactIds"])
        let c = try decoder.container(keyedBy: K.self)
        status = try c.decode(Status.self, forKey: .status)
        trackedSubtotals = try trackingDecode([SharedDemandLineTotal].self, from: c.superDecoder(forKey: .trackedSubtotals), shape: .array(.total))
        completeFoodCoverage = try c.decode(Bool.self, forKey: .completeFoodCoverage)
        unboundFactIds = try c.decode([SharedDemandID].self, forKey: .unboundFactIds)
        untrackedBasketIds = try c.decode([SharedDemandID].self, forKey: .untrackedBasketIds)
        protectedUnboundFactIds = try c.decode([SharedDemandID].self, forKey: .protectedUnboundFactIds)
        allocatableUnboundFactIds = try c.decode([SharedDemandID].self, forKey: .allocatableUnboundFactIds)
        try demandRequire(!completeFoodCoverage && allocatableUnboundFactIds.isEmpty && trackedSubtotals.count <= 200 && unboundFactIds.count <= 2000 && untrackedBasketIds.count <= 200 && protectedUnboundFactIds.count <= 2000)
        try demandRequire([unboundFactIds, untrackedBasketIds, protectedUnboundFactIds].allSatisfy { demandUnique($0) })
    }
}

public struct SharedTrackingFreezeReviewToken: Decodable, Equatable, Sendable {
    public let previewId: SharedDemandID
    public let previewDigest: SharedTrackingDigest
    public let trackingVersion: Int
    private enum K: String, CodingKey { case previewId, previewDigest, trackingVersion }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["previewId", "previewDigest", "trackingVersion"])
        let c = try decoder.container(keyedBy: K.self)
        previewId = try c.decode(SharedDemandID.self, forKey: .previewId)
        previewDigest = try c.decode(SharedTrackingDigest.self, forKey: .previewDigest)
        trackingVersion = try c.decode(Int.self, forKey: .trackingVersion)
        try demandRequire(trackingVersion == 2)
    }
}

public struct SharedTrackingPage: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case legacy, enabled, reviewRequired }
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let shopRevision: Int
    public let authorityEpoch: Int
    public let status: Status
    public let state: SharedTrackingState?
    public let projection: SharedTrackingProjection?
    public let basisDigest: SharedTrackingDigest
    public let coverage: SharedTrackingCoverage?
    public let freezeReview: SharedTrackingFreezeReviewToken?
    private enum K: String, CodingKey { case schemaVersion, shopId, shopRevision, authorityEpoch, status, state, projection, basisDigest, coverage, freezeReview }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "shopId", "shopRevision", "authorityEpoch", "status", "state", "projection", "basisDigest", "coverage", "freezeReview"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        status = try c.decode(Status.self, forKey: .status)
        state = try c.decode(SharedTrackingState?.self, forKey: .state)
        projection = try c.decode(SharedTrackingProjection?.self, forKey: .projection)
        basisDigest = try c.decode(SharedTrackingDigest.self, forKey: .basisDigest)
        coverage = try c.decode(SharedTrackingCoverage?.self, forKey: .coverage)
        freezeReview = try c.decode(SharedTrackingFreezeReviewToken?.self, forKey: .freezeReview)
        try validateStructure()
    }
}

public struct SharedTrackingHistoryItem: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case current_preview_required, unavailable }
    public let operationId: SharedDemandID
    public let shopRevision: Int
    public let committedAt: String
    public let status: Status
    private enum K: String, CodingKey { case operationId, shopRevision, committedAt, status }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["operationId", "shopRevision", "committedAt", "status"])
        let c = try decoder.container(keyedBy: K.self)
        operationId = try c.decode(SharedDemandID.self, forKey: .operationId)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        committedAt = try c.decode(String.self, forKey: .committedAt)
        status = try c.decode(Status.self, forKey: .status)
        try demandRequire(demandRevision(shopRevision) && demandTime(committedAt) != nil)
    }
}

public struct SharedTrackingHistory: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let shopRevision: Int
    public let items: [SharedTrackingHistoryItem]
    private enum K: String, CodingKey { case schemaVersion, shopId, shopRevision, items }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "shopId", "shopRevision", "items"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        items = try c.decode([SharedTrackingHistoryItem].self, forKey: .items)
        try demandRequire(schemaVersion == 2 && demandRevision(shopRevision) && items.count <= 100 && demandUnique(items.map(\.operationId)))
        var previous = Int.max
        for item in items {
            try demandRequire(item.shopRevision <= shopRevision && item.shopRevision < previous)
            previous = item.shopRevision
        }
    }
}
