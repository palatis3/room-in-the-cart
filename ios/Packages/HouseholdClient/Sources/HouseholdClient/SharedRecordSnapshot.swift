import Foundation

/// Inert food and money evidence. Deliberately neither a TrackingState nor a
/// command base: an imported record cannot become a live operation or a grant.
public struct SharedIndependentRecord: Decodable, Equatable, Sendable {
    public struct Origin: Decodable, Equatable, Sendable {
        public let householdId: SharedDemandID
        public let shopId: SharedDemandID
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["householdId", "shopId"])
            let c = try decoder.container(keyedBy: K.self)
            householdId = try c.decode(SharedDemandID.self, forKey: .householdId)
            shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        }
        private enum K: String, CodingKey { case householdId, shopId }
    }
    public struct MealOccurrence: Decodable, Equatable, Sendable {
        public let occurrenceId: SharedDemandID
        public let revision: Int
        public let meal: SharedMeal
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["occurrenceId", "revision", "meal"])
            try undoMealShapeInEdit(decoder)
            let c = try decoder.container(keyedBy: K.self)
            occurrenceId = try c.decode(SharedDemandID.self, forKey: .occurrenceId)
            revision = try c.decode(Int.self, forKey: .revision)
            meal = try c.decode(SharedMeal.self, forKey: .meal)
            try demandRequire(demandRevision(revision))
        }
        private enum K: String, CodingKey { case occurrenceId, revision, meal }
    }
    public let schemaVersion: Int
    public let projection: String
    public let origin: Origin
    public let shopRevision: Int
    public let privacyRevision: Int
    public let phase: String
    public let storeBasisRevision: Int?
    public let storeReviewRequired: Bool
    public let quote: ShopperQuote
    public let mealOccurrences: [MealOccurrence]
    public let food: SharedRecordFood
    private let wire: JSONValue
    private enum K: String, CodingKey { case schemaVersion, projection, origin, shopRevision, privacyRevision, phase, storeBasisRevision, storeReviewRequired, quote, mealOccurrences, food }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "projection", "origin", "shopRevision", "privacyRevision", "phase", "storeBasisRevision", "storeReviewRequired", "quote", "mealOccurrences", "food"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        projection = try c.decode(String.self, forKey: .projection)
        origin = try c.decode(Origin.self, forKey: .origin)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        privacyRevision = try c.decode(Int.self, forKey: .privacyRevision)
        phase = try c.decode(String.self, forKey: .phase)
        storeBasisRevision = try c.decode(Int?.self, forKey: .storeBasisRevision)
        storeReviewRequired = try c.decode(Bool.self, forKey: .storeReviewRequired)
        let quoteDecoder = try c.superDecoder(forKey: .quote)
        try requestUndoQuoteShape(quoteDecoder)
        quote = try ShopperQuote(from: quoteDecoder)
        mealOccurrences = try c.decode([MealOccurrence].self, forKey: .mealOccurrences)
        food = try c.decode(SharedRecordFood.self, forKey: .food)
        wire = try JSONValue(from: decoder)
        try demandRequire(schemaVersion == 2 && projection == "assigned-shopper-independent-record-v2")
        try demandRequire(demandRevision(shopRevision) && demandRevision(privacyRevision, zero: true))
        try demandRequire(["draft", "frozen", "placed", "closed"].contains(phase) && (storeBasisRevision.map { demandRevision($0) } ?? true))
        try demandRequire(food.graph.householdId == origin.householdId && food.graph.shopId == origin.shopId)
        try demandRequire(mealOccurrences.count <= 100 && demandUnique(mealOccurrences.map(\.occurrenceId)) && mealOccurrences.allSatisfy { $0.revision <= shopRevision })
        let occurrences = Set(mealOccurrences.map(\.occurrenceId))
        try demandRequire(food.catalog.allSatisfy { $0.source.origin.0.map { occurrences.contains($0) } ?? true })
        let money = [quote.capMinor, quote.fee.amountMinor, quote.fee.thresholdMinor, quote.fee.belowMinor, quote.fee.aboveMinor, quote.taxesMinor, quote.depositsMinor, quote.discountsMinor].compactMap { $0 }
        try demandRequire(quote.fee.kind != "threshold" || quote.fee.thresholdMinor != nil)
        try demandRequire(quote.currency == "USD" && money.allSatisfy { (0...1_000_000_000).contains($0) })
        try demandRequire(["wholeCheckout", "item", "dinner"].contains(quote.scope) && ["wholeCheckout", "item", "dinner", "unknown"].contains(quote.capScope))
        guard let observed = demandTime(quote.observedAt), let expires = demandTime(quote.expiresAt) else { throw ClientError.invalidResponse }
        try demandRequire(expires > observed)
        // Every nested field has already passed its exact allowlist. Preserve
        // required nulls and original literals in an independent canonical copy.
    }
    public func independentData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(wire)
        try demandRequire(bytes.count <= SharedRecordWire.maximumResponseBytes)
        return bytes
    }
}

public struct SharedRecordFood: Decodable, Equatable, Sendable {
    public struct PackReview: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case recorded, notRecorded, erased }
        public let state: State
        public let values: [SharedDemandPackReview]?
        private enum K: String, CodingKey { case state, values }
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["state", "values"])
            let c = try decoder.container(keyedBy: K.self)
            state = try c.decode(State.self, forKey: .state)
            values = try trackingDecode([SharedDemandPackReview]?.self, from: c.superDecoder(forKey: .values), shape: .nullable(.array(.pack)))
            try demandRequire((state == .erased) == (values == nil))
        }
    }
    public let status: SharedTrackingPage.Status
    public let graph: SharedDemandGraph
    public let basket: [SharedTrackingBasketLine]
    public let catalog: [SharedTrackingFact]
    public let bindings: [SharedTrackingBinding]
    public let unbound: [SharedTrackingUnboundFact]
    public let legacyLineIds: [SharedDemandID]
    public let packReview: PackReview
    public let coverage: SharedTrackingCoverage?
    private enum K: String, CodingKey { case status, graph, basket, catalog, bindings, unbound, legacyLineIds, packReview, coverage }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["status", "graph", "basket", "catalog", "bindings", "unbound", "legacyLineIds", "packReview", "coverage"])
        let c = try decoder.container(keyedBy: K.self)
        status = try c.decode(SharedTrackingPage.Status.self, forKey: .status)
        graph = try trackingDecode(SharedDemandGraph.self, from: c.superDecoder(forKey: .graph), shape: .graph)
        basket = try c.decode([SharedTrackingBasketLine].self, forKey: .basket)
        catalog = try c.decode([SharedTrackingFact].self, forKey: .catalog)
        bindings = try c.decode([SharedTrackingBinding].self, forKey: .bindings)
        unbound = try c.decode([SharedTrackingUnboundFact].self, forKey: .unbound)
        legacyLineIds = try c.decode([SharedDemandID].self, forKey: .legacyLineIds)
        packReview = try c.decode(PackReview.self, forKey: .packReview)
        coverage = try c.decode(SharedTrackingCoverage?.self, forKey: .coverage)
        try trackingValidateCore(RecordPartition(food: self))
        if status == .reviewRequired {
            try demandRequire(packReview.state == .erased && coverage == nil)
        } else {
            try demandRequire((status == .legacy) == (graph.revision == 0))
            try demandRequire(packReview.state == (status == .legacy ? .notRecorded : .recorded))
            guard let values = packReview.values, let coverage else { throw ClientError.invalidResponse }
            try demandRequire(values.count <= 200 && demandUnique(values.map(\.lineId)) && Set(values.map(\.lineId)) == Set(graph.lines.filter { $0.trashedAt == nil }.map(\.id)))
            for pack in values { try pack.usablePerPack?.validate() }
            try validateDemandTotals(coverage.trackedSubtotals, graph: graph)
            try demandRequire(coverage.unboundFactIds == unbound.map(\.factId) && coverage.untrackedBasketIds == legacyLineIds)
            try demandRequire(coverage.protectedUnboundFactIds == unbound.filter { u in catalog.first { $0.id == u.factId }?.source.isReservation == true }.map(\.factId))
            let expected: SharedTrackingCoverage.Status = !unbound.isEmpty || !legacyLineIds.isEmpty ? .partial : coverage.trackedSubtotals.contains { $0.quantity == nil } ? .unknown : .tracked
            try demandRequire(coverage.status == expected)
            for total in coverage.trackedSubtotals where graph.contributions.contains(where: { $0.removedAt == nil && $0.lineId == total.lineId && $0.quantity == nil }) { try demandRequire(total.quantity == nil) }
        }
    }
}
/// Structural validator adapter only. These constants are never encoded, exposed
/// as authorization, or used to create a live read binding.
private struct RecordPartition: TrackingStateFields {
    let food: SharedRecordFood
    var schemaVersion: Int { 2 }; var authorityEpoch: Int { 0 }; var privacyRevision: Int { 0 }
    var graph: SharedDemandGraph { food.graph }; var basket: [SharedTrackingBasketLine] { food.basket }
    var catalog: [SharedTrackingFact] { food.catalog }; var bindings: [SharedTrackingBinding] { food.bindings }
    var unbound: [SharedTrackingUnboundFact] { food.unbound }; var legacyLineIds: [SharedDemandID] { food.legacyLineIds }
}

public struct SharedRecordSnapshot: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    /// Observation time, NOT a local save or export timestamp.
    public let asOf: String
    public let recordDigest: SharedTrackingDigest
    public let record: SharedIndependentRecord
    private enum K: String, CodingKey { case schemaVersion, asOf, recordDigest, record }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "asOf", "recordDigest", "record"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        asOf = try c.decode(String.self, forKey: .asOf)
        recordDigest = try c.decode(SharedTrackingDigest.self, forKey: .recordDigest)
        record = try c.decode(SharedIndependentRecord.self, forKey: .record)
        try demandRequire(schemaVersion == 2 && demandTime(asOf) != nil)
    }
}
public enum SharedRecordWire {
    public static let maximumResponseBytes = 1_800_000
    public static func snapshot(from bytes: Data) throws -> SharedRecordSnapshot {
        try preflight(bytes); return try JSONDecoder().decode(SharedRecordSnapshot.self, from: bytes)
    }
    public static func independentRecord(from bytes: Data) throws -> SharedIndependentRecord {
        try preflight(bytes); return try JSONDecoder().decode(SharedIndependentRecord.self, from: bytes)
    }
    private static func preflight(_ bytes: Data) throws {
        try demandRequire(!bytes.isEmpty && bytes.count <= maximumResponseBytes)
        var depth = 0, quoted = false, escaped = false
        for byte in bytes {
            if quoted { if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false } }
            else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; try demandRequire(depth <= 48) }
            else if byte == 125 || byte == 93 { depth -= 1; try demandRequire(depth >= 0) }
        }
        try demandRequire(depth == 0 && !quoted)
    }
}
