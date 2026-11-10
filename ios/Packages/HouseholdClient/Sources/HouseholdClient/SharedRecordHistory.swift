import Foundation

/// Inert historical evidence, never a live command base or authorization grant.
public struct SharedRecordHistory: Decodable, Equatable, Sendable {
    public struct BasketRevision: Decodable, Equatable, Sendable {
        public let revision: Int
        public let purpose, recordedAt, phase: String
        public let quote: ShopperQuote
        public let basketLines: [ShopperBasketLine]
        private enum K: String, CodingKey { case revision, purpose, recordedAt, phase, quote, basketLines }
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["revision", "purpose", "recordedAt", "phase", "quote", "basketLines"])
            let c = try decoder.container(keyedBy: K.self)
            revision = try c.decode(Int.self, forKey: .revision)
            purpose = try c.decode(String.self, forKey: .purpose)
            recordedAt = try c.decode(String.self, forKey: .recordedAt)
            phase = try c.decode(String.self, forKey: .phase)
            let q = try c.superDecoder(forKey: .quote)
            try requestUndoQuoteShape(q); quote = try ShopperQuote(from: q)
            basketLines = try trackingDecode([ShopperBasketLine].self, from: c.superDecoder(forKey: .basketLines), shape: requestUndoBasketShape)
            try demandRequire(demandRevision(revision) && demandTime(recordedAt) != nil && historyPhase(phase))
            try demandRequire(["create", "patch", "decision", "freeze", "reopen", "placed"].contains(purpose))
            _ = try ShopperShopCandidate(quote: quote, lines: basketLines)
            guard let observed = demandTime(quote.observedAt), let expires = demandTime(quote.expiresAt) else { throw ClientError.invalidResponse }
            try demandRequire(quote.currency == "USD" && (quote.fee.kind != "threshold" || quote.fee.thresholdMinor != nil))
            _ = try ShopperQuote(scope: quote.scope, complete: quote.complete, capMinor: quote.capMinor, capScope: quote.capScope,
                fee: quote.fee, taxesMinor: quote.taxesMinor, depositsMinor: quote.depositsMinor, discountsMinor: quote.discountsMinor,
                observedAt: observed, expiresAt: expires)
        }
    }
    public struct MealRevision: Decodable, Equatable, Sendable {
        public let occurrenceId: SharedDemandID
        public let revision: Int
        /// Null records an explicit removal at this revision.
        public let meal: SharedMeal?
        private enum K: String, CodingKey { case occurrenceId, revision, meal }
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["occurrenceId", "revision", "meal"])
            try undoMealShapeInEdit(decoder)
            let c = try decoder.container(keyedBy: K.self)
            occurrenceId = try c.decode(SharedDemandID.self, forKey: .occurrenceId)
            revision = try c.decode(Int.self, forKey: .revision)
            meal = try c.decode(SharedMeal?.self, forKey: .meal)
            try demandRequire(demandRevision(revision))
        }
    }
    public struct CookCopy: Decodable, Equatable, Sendable {
        public let copyId, occurrenceId: UUID
        public let mealRevision, shopRevision, placedRevision, version: Int
        public let language, text, createdAt: String
    }
    public struct CookSend: Decodable, Equatable, Sendable {
        public let copyId: UUID
        public let recipient, sentAt: String
    }
    public struct Deliveries: Decodable, Equatable, Sendable {
        public struct Source: Decodable, Equatable, Sendable {
            public let sourceId, lineId, segmentKey: UUID
            public let placedRevision: Int
            public let foodName: String
            public let exclusionTags: [String]
        }
        public struct ArrivalBody: Decodable, Equatable, Sendable {
            public let supplyRevision: Int
            public let sourceId, observationId: UUID
            public let predecessorId: UUID?
            public let arrivedAt: String?
            public let received: SharedMealQuantity?
        }
        public struct UsableBody: Decodable, Equatable, Sendable {
            public let supplyRevision: Int
            public let sourceId, observationId, arrivalObservationId: UUID
            public let predecessorId: UUID?
            public let confirmedAt: String
            public let usable: SharedMealQuantity?
        }
        public struct Observation: Decodable, Equatable, Sendable {
            public enum Body: Equatable, Sendable {
                case arrival(ArrivalBody), usable(UsableBody)
                public var sourceId: UUID { switch self { case .arrival(let b): b.sourceId; case .usable(let b): b.sourceId } }
                public var observationId: UUID { switch self { case .arrival(let b): b.observationId; case .usable(let b): b.observationId } }
            }
            public let kind, recordedAt: String
            public let body: Body
            private enum K: String, CodingKey { case kind, recordedAt, body }
            public init(from decoder: Decoder) throws {
                try demandExactKeys(decoder, ["kind", "recordedAt", "body"])
                let c = try decoder.container(keyedBy: K.self)
                kind = try c.decode(String.self, forKey: .kind); recordedAt = try c.decode(String.self, forKey: .recordedAt)
                try demandRequire(demandTime(recordedAt) != nil)
                let d = try c.superDecoder(forKey: .body)
                switch kind {
                case "arrival":
                    let value = try trackingDecode(ArrivalBody.self, from: d, shape: historyObject(["supplyRevision", "sourceId", "observationId", "predecessorId", "arrivedAt"], ["received": .nullable(historyQuantity)]))
                    try demandRequire(demandRevision(value.supplyRevision, zero: true) && (value.arrivedAt.map { demandTime($0) != nil } ?? true))
                    try historyQuantityValue(value.received, zero: true); body = .arrival(value)
                case "usable":
                    let value = try trackingDecode(UsableBody.self, from: d, shape: historyObject(["supplyRevision", "sourceId", "observationId", "predecessorId", "arrivalObservationId", "confirmedAt"], ["usable": .nullable(historyQuantity)]))
                    try demandRequire(demandRevision(value.supplyRevision, zero: true) && demandTime(value.confirmedAt) != nil)
                    try historyQuantityValue(value.usable, zero: true); body = .usable(value)
                default: throw ClientError.invalidResponse
                }
            }
        }
        public struct Match: Decodable, Equatable, Sendable {
            public let supplyRevision, mealRevision: Int
            public let sourceId, occurrenceId, ingredientId: UUID
            public let matched: Bool
        }
        public struct Reservation: Decodable, Equatable, Sendable {
            public let supplyRevision, mealRevision: Int
            public let sourceId, occurrenceId, ingredientId, groupId: UUID
            public let quantity: SharedMealQuantity?
        }
        public let sources: [Source]
        public let observations: [Observation]
        public let matches: [Match]
        public let reservations: [Reservation]
    }
    public let schemaVersion: Int
    public let projection: String
    public let origin: SharedIndependentRecord.Origin
    public let shopRevision: Int
    public let phase: String
    public let basketRevisions: [BasketRevision]
    public let mealRevisions: [MealRevision]
    public let cookCopies: [CookCopy]
    public let cookSends: [CookSend]
    public let deliveries: Deliveries
    public let decisions: [FamilyDecisionRecord]
    public let financialEntries: [ShopperFinancialEntry]
    public let priceObservations: [HistoryPriceObservation]
    private let wire: JSONValue
    private enum K: String, CodingKey {
        case schemaVersion, projection, origin, shopRevision, phase, basketRevisions, mealRevisions, cookCopies, cookSends, deliveries, decisions, financialEntries, priceObservations
    }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "projection", "origin", "shopRevision", "phase", "basketRevisions", "mealRevisions", "cookCopies", "cookSends", "deliveries", "decisions", "financialEntries", "priceObservations"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); projection = try c.decode(String.self, forKey: .projection)
        origin = try c.decode(SharedIndependentRecord.Origin.self, forKey: .origin)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision); phase = try c.decode(String.self, forKey: .phase)
        basketRevisions = try c.decode([BasketRevision].self, forKey: .basketRevisions)
        mealRevisions = try c.decode([MealRevision].self, forKey: .mealRevisions)
        cookCopies = try trackingDecode([CookCopy].self, from: c.superDecoder(forKey: .cookCopies), shape: .array(historyObject(["copyId", "occurrenceId", "mealRevision", "shopRevision", "placedRevision", "version", "language", "text", "createdAt"])))
        cookSends = try trackingDecode([CookSend].self, from: c.superDecoder(forKey: .cookSends), shape: .array(historyObject(["copyId", "recipient", "sentAt"])))
        let target = ["supplyRevision", "sourceId", "occurrenceId", "mealRevision", "ingredientId"]
        deliveries = try trackingDecode(Deliveries.self, from: c.superDecoder(forKey: .deliveries), shape: .object([
            "sources": .array(historyObject(["sourceId", "placedRevision", "lineId", "segmentKey", "foodName", "exclusionTags"])),
            "observations": .scalar,
            "matches": .array(historyObject(target + ["matched"])),
            "reservations": .array(historyObject(target + ["groupId"], ["quantity": .nullable(historyQuantity)]))
        ]))
        decisions = try trackingDecode([FamilyDecisionRecord].self, from: c.superDecoder(forKey: .decisions), shape: .array(historyObject(["id", "shopId", "version", "kind", "product", "dish", "occasion", "decision", "outcome", "scope", "recordedAt", "observedAt", "promotedAt"])))
        financialEntries = try trackingDecode([ShopperFinancialEntry].self, from: c.superDecoder(forKey: .financialEntries), shape: .array(historyObject(["id", "evidenceKey", "kind", "amountMinor", "currency", "occurredAt", "creditId", "chargeEvidenceKey", "holdEvidenceKey", "sourceText"])))
        var prices = try c.nestedUnkeyedContainer(forKey: .priceObservations), observations = [HistoryPriceObservation]()
        while !prices.isAtEnd {
            let d = try prices.superDecoder()
            try historyObject(["id", "shopId", "itemName", "packLabel", "currency", "store", "branch", "channel", "mode", "eligibility", "observedAt", "sourceText", "sourceLocale"], ["usablePack": .nullable(historyQuantity), "price": .scalar]).validate(d)
            enum P: String, CodingKey { case price, kind }
            let price = try d.container(keyedBy: P.self).superDecoder(forKey: .price)
            switch try price.container(keyedBy: P.self).decode(String.self, forKey: .kind) {
            case "exact": try demandExactKeys(price, ["kind", "minor"])
            case "bounded": try demandExactKeys(price, ["kind", "lowerMinor", "upperMinor", "reason"])
            case "unknown": try demandExactKeys(price, ["kind", "reason"])
            default: throw ClientError.invalidResponse
            }
            let observation = try HistoryPriceObservation(from: d); try observation.validate()
            observations.append(observation); try demandRequire(observations.count <= 2000)
        }
        priceObservations = observations
        wire = try JSONValue(from: decoder)
        try validate()
    }
    private func validate() throws {
        try demandRequire(schemaVersion == 1 && projection == "assigned-shopper-history-v1" && demandRevision(shopRevision) && historyPhase(phase))
        try demandRequire([basketRevisions.count, mealRevisions.count, cookCopies.count, cookSends.count, deliveries.sources.count,
            deliveries.observations.count, deliveries.matches.count, deliveries.reservations.count, decisions.count, financialEntries.count, priceObservations.count].allSatisfy { $0 <= 2000 })
        func unique<T: Hashable>(_ values: [T]) throws { try demandRequire(Set(values).count == values.count) }
        func mealKey(_ id: UUID, _ revision: Int) -> String { id.uuidString + "/" + String(revision) }
        try unique(basketRevisions.map(\.revision)); try unique(mealRevisions.map { mealKey($0.occurrenceId.uuid, $0.revision) })
        try unique(cookCopies.map(\.copyId)); try unique(deliveries.sources.map(\.sourceId)); try unique(deliveries.observations.map { $0.body.observationId })
        try unique(decisions.map(\.id)); try unique(financialEntries.map(\.id)); try unique(priceObservations.map { $0.id.lowercased() })
        let baskets = Dictionary(uniqueKeysWithValues: basketRevisions.map { ($0.revision, $0) })
        let meals = Set(mealRevisions.filter { $0.meal != nil }.map { mealKey($0.occurrenceId.uuid, $0.revision) })
        let sources = Set(deliveries.sources.map(\.sourceId)), copies = Set(cookCopies.map(\.copyId))
        try demandRequire(basketRevisions.allSatisfy { $0.revision <= shopRevision } && mealRevisions.allSatisfy { $0.revision <= shopRevision })
        for copy in cookCopies {
            try demandRequire([copy.mealRevision, copy.shopRevision, copy.placedRevision, copy.version].allSatisfy { demandRevision($0) })
            try demandRequire(copy.shopRevision <= shopRevision && baskets[copy.placedRevision] != nil && meals.contains(mealKey(copy.occurrenceId, copy.mealRevision)))
            try demandRequire(["en", "es"].contains(copy.language) && historyText(copy.text, 16000) && demandTime(copy.createdAt) != nil)
        }
        for send in cookSends { try demandRequire(copies.contains(send.copyId) && historyText(send.recipient, 80) && demandTime(send.sentAt) != nil) }
        for source in deliveries.sources {
            try demandRequire(demandRevision(source.placedRevision) && baskets[source.placedRevision]?.basketLines.contains { UUID(uuidString: $0.lineId) == source.lineId } == true)
            try demandRequire(historyText(source.foodName, 240) && source.exclusionTags.count <= 20)
        }
        for observation in deliveries.observations { try demandRequire(sources.contains(observation.body.sourceId)) }
        for match in deliveries.matches {
            try demandRequire(demandRevision(match.supplyRevision) && demandRevision(match.mealRevision) && sources.contains(match.sourceId) && meals.contains(mealKey(match.occurrenceId, match.mealRevision)))
        }
        for reservation in deliveries.reservations {
            try demandRequire(demandRevision(reservation.supplyRevision) && demandRevision(reservation.mealRevision) && sources.contains(reservation.sourceId) && meals.contains(mealKey(reservation.occurrenceId, reservation.mealRevision)))
            try historyQuantityValue(reservation.quantity)
        }
        for decision in decisions { try decision.validate(); try demandRequire(decision.shopId == origin.shopId.uuid && demandRevision(decision.version)) }
        for entry in financialEntries {
            try demandRequire(HistoryValidation.cents(entry.amountMinor) && entry.currency == "USD" && demandTime(entry.occurredAt) != nil && HistoryValidation.text(entry.sourceText, 8192))
        }
        try demandRequire(priceObservations.allSatisfy { UUID(uuidString: $0.shopId) == origin.shopId.uuid })
    }
    /// Preserve required nulls and original literals after every nested allowlist passed.
    public func independentData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(wire)
        try demandRequire(bytes.count <= SharedRecordHistoryWire.maximumResponseBytes)
        return bytes
    }
}

private func historyObject(_ scalarKeys: [String], _ nested: [String: TrackingWireShape] = [:]) -> TrackingWireShape {
    .object(Dictionary(uniqueKeysWithValues: scalarKeys.map { ($0, TrackingWireShape.scalar) }).merging(nested) { _, shape in shape })
}
private let historyQuantity = historyObject(["unit", "originalLiteral"], ["amount": historyObject(["numerator", "denominator"])])
private func historyPhase(_ value: String) -> Bool { ["draft", "frozen", "placed", "closed"].contains(value) }
private func historyText(_ value: String, _ maximum: Int) -> Bool { !value.isEmpty && value.utf16.count <= maximum }
private func historyQuantityValue(_ value: SharedMealQuantity?, zero: Bool = false) throws {
    guard let value else { return }
    try demandRequire(((zero ? 0 : 1)...1_000_000_000).contains(value.amount.numerator) && (1...1_000_000_000).contains(value.amount.denominator))
    try demandRequire(HistoryUnit(rawValue: value.unit) != nil && historyText(value.originalLiteral, 240))
}

public struct SharedRecordHistorySnapshot: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let asOf: String
    public let recordDigest: SharedTrackingDigest
    public let record: SharedRecordHistory
    private enum K: String, CodingKey { case schemaVersion, asOf, recordDigest, record }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "asOf", "recordDigest", "record"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); asOf = try c.decode(String.self, forKey: .asOf)
        recordDigest = try c.decode(SharedTrackingDigest.self, forKey: .recordDigest)
        record = try c.decode(SharedRecordHistory.self, forKey: .record)
        try demandRequire(schemaVersion == 1 && demandTime(asOf) != nil)
    }
}
public enum SharedRecordHistoryWire {
    public static let maximumResponseBytes = 1_800_000
    public static func snapshot(from bytes: Data) throws -> SharedRecordHistorySnapshot {
        try preflight(bytes); return try JSONDecoder().decode(SharedRecordHistorySnapshot.self, from: bytes)
    }
    public static func independentRecord(from bytes: Data) throws -> SharedRecordHistory {
        try preflight(bytes); return try JSONDecoder().decode(SharedRecordHistory.self, from: bytes)
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
extension HouseholdService {
    public func sharedRecordHistory(shopID: UUID) async throws -> SharedRecordHistorySnapshot {
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shopID.uuidString.lowercased())
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        let result: SharedRecordHistorySnapshot = try await perform("shops/\(shopID.uuidString.lowercased())/records/history/v1", method: "GET", maximumResponseBytes: SharedRecordHistoryWire.maximumResponseBytes)
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try demandRequire(result.record.origin.householdId.string == context.householdID.lowercased() && result.record.origin.shopId.uuid == shopID)
        return result
    }
}
