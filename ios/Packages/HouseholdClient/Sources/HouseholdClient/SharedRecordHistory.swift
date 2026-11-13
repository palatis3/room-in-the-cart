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
    /// Missing sections identify older archives, not an empty history.
    public enum CaptureCoverage: String, Equatable, Sendable { case notCaptured, captured }
    public struct FoodHistory: Decodable, Equatable, Sendable {
        public struct DemandRevision: Decodable, Equatable, Sendable {
            public let shopRevision: Int
            public let predecessorRevision: Int?
            public let recordedAt: String
            public let graph: SharedDemandGraph
            public let packReviews: [SharedDemandPackReview]
            private enum K: String, CodingKey { case shopRevision, predecessorRevision, recordedAt, graph, packReviews }
            public init(from decoder: Decoder) throws {
                try demandExactKeys(decoder, ["shopRevision", "predecessorRevision", "recordedAt", "graph", "packReviews"])
                let c = try decoder.container(keyedBy: K.self)
                shopRevision = try c.decode(Int.self, forKey: .shopRevision)
                predecessorRevision = try c.decode(Int?.self, forKey: .predecessorRevision)
                recordedAt = try c.decode(String.self, forKey: .recordedAt)
                graph = try trackingDecode(SharedDemandGraph.self, from: c.superDecoder(forKey: .graph), shape: .graph)
                packReviews = try trackingDecode([SharedDemandPackReview].self, from: c.superDecoder(forKey: .packReviews), shape: .array(.pack))
                try graph.validate(); try historyPacks(packReviews, graph: graph)
                try demandRequire(demandRevision(shopRevision) && demandTime(recordedAt) != nil && graph.revision > 0)
                try demandRequire(predecessorRevision == (graph.revision == 1 ? nil : graph.revision - 1))
            }
        }
        public struct FoodPartition: Decodable, Equatable, Sendable {
            public let graph: SharedDemandGraph
            public let basket: [SharedTrackingBasketLine]
            public let catalog: [SharedTrackingFact]
            public let bindings: [SharedTrackingBinding]
            public let unbound: [SharedTrackingUnboundFact]
            public let legacyLineIds: [SharedDemandID]
            public let packReviews: [SharedDemandPackReview]
            private enum K: String, CodingKey { case graph, basket, catalog, bindings, unbound, legacyLineIds, packReviews }
            public init(from decoder: Decoder) throws {
                try demandExactKeys(decoder, ["graph", "basket", "catalog", "bindings", "unbound", "legacyLineIds", "packReviews"])
                let c = try decoder.container(keyedBy: K.self)
                graph = try trackingDecode(SharedDemandGraph.self, from: c.superDecoder(forKey: .graph), shape: .graph)
                basket = try c.decode([SharedTrackingBasketLine].self, forKey: .basket)
                catalog = try c.decode([SharedTrackingFact].self, forKey: .catalog)
                bindings = try c.decode([SharedTrackingBinding].self, forKey: .bindings)
                unbound = try c.decode([SharedTrackingUnboundFact].self, forKey: .unbound)
                legacyLineIds = try c.decode([SharedDemandID].self, forKey: .legacyLineIds)
                packReviews = try trackingDecode([SharedDemandPackReview].self, from: c.superDecoder(forKey: .packReviews), shape: .array(.pack))
                try trackingValidateCore(HistoryFoodPartition(food: self)); try historyPacks(packReviews, graph: graph)
            }
        }
        public struct TrackingRevision: Decodable, Equatable, Sendable {
            public let shopRevision: Int
            public let recordedAt: String
            public let food: FoodPartition
            private enum K: String, CodingKey { case shopRevision, recordedAt, food }
            public init(from decoder: Decoder) throws {
                try demandExactKeys(decoder, ["shopRevision", "recordedAt", "food"])
                let c = try decoder.container(keyedBy: K.self)
                shopRevision = try c.decode(Int.self, forKey: .shopRevision)
                recordedAt = try c.decode(String.self, forKey: .recordedAt)
                food = try c.decode(FoodPartition.self, forKey: .food)
                try demandRequire(demandRevision(shopRevision) && demandTime(recordedAt) != nil)
            }
        }
        public let demandRevisions: [DemandRevision]
        public let trackingRevisions: [TrackingRevision]
        private enum K: String, CodingKey { case demandRevisions, trackingRevisions }
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["demandRevisions", "trackingRevisions"])
            let c = try decoder.container(keyedBy: K.self)
            demandRevisions = try c.decode([DemandRevision].self, forKey: .demandRevisions)
            trackingRevisions = try c.decode([TrackingRevision].self, forKey: .trackingRevisions)
            try demandRequire(demandRevisions.count <= 2000 && trackingRevisions.count <= 2000)
            try demandRequire(demandUnique(demandRevisions.map(\.shopRevision)) && demandUnique(demandRevisions.map { $0.graph.revision }))
            try demandRequire(demandUnique(trackingRevisions.map(\.shopRevision)))
        }
    }
    public struct StockHistory: Decodable, Equatable, Sendable {
        /// Source evidence for a carried lot; no other shop's basket or meals.
        public struct CarriedDelivery: Decodable, Equatable, Sendable {
            public let originShopId: UUID
            public let source: Deliveries.Source
            public let observations: [Deliveries.Observation]
            private enum K: String, CodingKey { case originShopId, source, observations }
            public init(from decoder: Decoder) throws {
                try demandExactKeys(decoder, ["originShopId", "source", "observations"])
                let c = try decoder.container(keyedBy: K.self)
                originShopId = try c.decode(UUID.self, forKey: .originShopId)
                source = try trackingDecode(Deliveries.Source.self, from: c.superDecoder(forKey: .source),
                    shape: historyObject(["sourceId", "placedRevision", "lineId", "segmentKey", "foodName", "exclusionTags"]))
                observations = try c.decode([Deliveries.Observation].self, forKey: .observations)
                try demandRequire(demandRevision(source.placedRevision) && historyText(source.foodName, 240) && source.exclusionTags.count <= 20)
                try demandRequire(observations.count <= 2000 && demandUnique(observations.map { $0.body.observationId }))
                var arrivalHead: UUID?, usableHead: UUID?, previousRevision = -1
                for observation in observations {
                    try demandRequire(observation.body.sourceId == source.sourceId)
                    let revision: Int
                    switch observation.body {
                    case .arrival(let body):
                        revision = body.supplyRevision
                        try demandRequire(body.predecessorId == arrivalHead)
                        arrivalHead = body.observationId
                    case .usable(let body):
                        revision = body.supplyRevision
                        try demandRequire(body.predecessorId == usableHead && arrivalHead == body.arrivalObservationId)
                        usableHead = body.observationId
                    }
                    try demandRequire(revision > previousRevision)
                    previousRevision = revision
                }
            }
        }
        public struct Lot: Decodable, Equatable, Sendable {
            public let lotId: UUID
            public let deliverySourceId: UUID?
            public let location: String
            public let storedAt, useFirstAt: String?
            public let foodName: String
            public let exclusionTags: [String]
        }
        public struct Event: Decodable, Equatable, Sendable {
            public enum Details: Equatable, Sendable {
                case observe(confirmedAt: String, quantity: SharedMealQuantity?)
                case select(selected: Bool)
                case match(occurrenceId: UUID, mealRevision: Int, ingredientId: UUID, matched: Bool)
                case reserve(occurrenceId: UUID, mealRevision: Int, ingredientId: UUID, groupId: UUID, quantity: SharedMealQuantity?)
            }
            public let lotId: UUID
            public let pantryRevision: Int
            public let recordedAt: String
            public let details: Details
            public var kind: String {
                switch details { case .observe: "observe"; case .select: "select"; case .match: "match"; case .reserve: "reserve" }
            }
            private enum K: String, CodingKey { case kind, lotId, pantryRevision, recordedAt, confirmedAt, quantity, selected, occurrenceId, mealRevision, ingredientId, matched, groupId }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                let kind = try c.decode(String.self, forKey: .kind)
                let common: Set<String> = ["kind", "lotId", "pantryRevision", "recordedAt"]
                switch kind {
                case "observe":
                    try demandExactKeys(decoder, common.union(["confirmedAt", "quantity"]))
                    let confirmedAt = try c.decode(String.self, forKey: .confirmedAt)
                    let quantity = try trackingDecode(SharedMealQuantity?.self, from: c.superDecoder(forKey: .quantity), shape: .nullable(historyQuantity))
                    try demandRequire(demandTime(confirmedAt) != nil); try historyQuantityValue(quantity, zero: true)
                    details = .observe(confirmedAt: confirmedAt, quantity: quantity)
                case "select":
                    try demandExactKeys(decoder, common.union(["selected"]))
                    details = .select(selected: try c.decode(Bool.self, forKey: .selected))
                case "match", "reserve":
                    let target: Set<String> = ["occurrenceId", "mealRevision", "ingredientId"]
                    try demandExactKeys(decoder, common.union(target).union(kind == "match" ? ["matched"] : ["groupId", "quantity"]))
                    let occurrence = try c.decode(UUID.self, forKey: .occurrenceId), revision = try c.decode(Int.self, forKey: .mealRevision)
                    let ingredient = try c.decode(UUID.self, forKey: .ingredientId)
                    try demandRequire(demandRevision(revision))
                    if kind == "match" {
                        details = .match(occurrenceId: occurrence, mealRevision: revision, ingredientId: ingredient, matched: try c.decode(Bool.self, forKey: .matched))
                    } else {
                        let quantity = try trackingDecode(SharedMealQuantity?.self, from: c.superDecoder(forKey: .quantity), shape: .nullable(historyQuantity))
                        try historyQuantityValue(quantity)
                        details = .reserve(occurrenceId: occurrence, mealRevision: revision, ingredientId: ingredient,
                            groupId: try c.decode(UUID.self, forKey: .groupId), quantity: quantity)
                    }
                default: throw ClientError.invalidResponse
                }
                lotId = try c.decode(UUID.self, forKey: .lotId); pantryRevision = try c.decode(Int.self, forKey: .pantryRevision)
                recordedAt = try c.decode(String.self, forKey: .recordedAt)
                try demandRequire(demandRevision(pantryRevision) && demandTime(recordedAt) != nil)
            }
        }
        public let lots: [Lot]
        public let events: [Event]
        public let carriedDeliveries: [CarriedDelivery]?
        public var carriedDeliveriesCoverage: CaptureCoverage { carriedDeliveries == nil ? .notCaptured : .captured }
        private enum K: String, CodingKey { case lots, events, carriedDeliveries }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            try demandExactKeys(decoder, c.contains(.carriedDeliveries) ? ["lots", "events", "carriedDeliveries"] : ["lots", "events"])
            carriedDeliveries = c.contains(.carriedDeliveries) ? try c.decode([CarriedDelivery].self, forKey: .carriedDeliveries) : nil
            let carried = carriedDeliveries ?? []
            try demandRequire(carried.count <= 2000 && carried.reduce(0) { $0 + $1.observations.count } <= 2000)
            try demandRequire(demandUnique(carried.map { $0.source.sourceId }))
            lots = try trackingDecode([Lot].self, from: c.superDecoder(forKey: .lots), shape: .array(historyObject(["lotId", "deliverySourceId", "location", "storedAt", "useFirstAt", "foodName", "exclusionTags"])))
            events = try c.decode([Event].self, forKey: .events)
            try demandRequire(lots.count <= 2000 && events.count <= 2000 && demandUnique(lots.map(\.lotId)) && demandUnique(events.map(\.pantryRevision)))
            let identifiers = Set(lots.map(\.lotId))
            for lot in lots {
                try demandRequire(["pantry", "freezer"].contains(lot.location) && historyText(lot.foodName, 240))
                try demandRequire((lot.storedAt.map { demandTime($0) != nil } ?? true) && (lot.useFirstAt.map { demandTime($0) != nil } ?? true))
                try demandRequire(lot.exclusionTags.count <= 20 && lot.exclusionTags.allSatisfy { historyText($0, 240) })
            }
            try demandRequire(events.allSatisfy { identifiers.contains($0.lotId) })
        }
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
    public let foodHistory: FoodHistory?
    public let stockHistory: StockHistory?
    public var foodHistoryCoverage: CaptureCoverage { foodHistory == nil ? .notCaptured : .captured }
    public var stockHistoryCoverage: CaptureCoverage { stockHistory == nil ? .notCaptured : .captured }
    private let wire: JSONValue
    private enum K: String, CodingKey {
        case schemaVersion, projection, origin, shopRevision, phase, basketRevisions, mealRevisions, cookCopies, cookSends, deliveries, decisions, financialEntries, priceObservations, foodHistory, stockHistory
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        var keys: Set<String> = ["schemaVersion", "projection", "origin", "shopRevision", "phase", "basketRevisions", "mealRevisions", "cookCopies", "cookSends", "deliveries", "decisions", "financialEntries", "priceObservations"]
        if c.contains(.foodHistory) { keys.insert("foodHistory") }
        if c.contains(.stockHistory) { keys.insert("stockHistory") }
        try demandExactKeys(decoder, keys)
        // Only absence identifies a legacy archive. Present null fails closed.
        foodHistory = c.contains(.foodHistory) ? try c.decode(FoodHistory.self, forKey: .foodHistory) : nil
        stockHistory = c.contains(.stockHistory) ? try c.decode(StockHistory.self, forKey: .stockHistory) : nil
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
        let historicalOccurrences = Set(mealRevisions.filter { $0.meal != nil }.map(\.occurrenceId))
        func sourceExists(_ source: SharedDemandSource) -> Bool {
            source.origin.0.map { historicalOccurrences.contains($0) } ?? true
        }
        if let history = foodHistory {
            let graphs = Dictionary(uniqueKeysWithValues: history.demandRevisions.map { ($0.graph.revision, $0) })
            for revision in history.demandRevisions {
                try demandRequire(revision.shopRevision <= shopRevision && baskets[revision.shopRevision] != nil)
                try demandRequire(revision.graph.householdId == origin.householdId && revision.graph.shopId == origin.shopId)
                try demandRequire(revision.predecessorRevision.map { graphs[$0] != nil } ?? true)
                try demandRequire(revision.graph.contributions.allSatisfy { sourceExists($0.source) })
            }
            for revision in history.trackingRevisions {
                let food = revision.food
                try demandRequire(revision.shopRevision <= shopRevision && baskets[revision.shopRevision] != nil)
                guard let demand = graphs[food.graph.revision], let basket = baskets[revision.shopRevision] else { throw ClientError.invalidResponse }
                try demandRequire(demand.graph == food.graph && demand.shopRevision <= revision.shopRevision)
                try demandRequire(food.basket.count == basket.basketLines.count)
                for line in food.basket {
                    guard let original = basket.basketLines.first(where: { UUID(uuidString: $0.lineId) == line.id.uuid }) else { throw ClientError.invalidResponse }
                    try demandRequire(line.name == original.originalItem && line.packs == original.packs && line.priceMinor == original.unitPriceMinor && line.feeEligible == original.feeEligible)
                }
                try demandRequire(food.unbound.compactMap(\.transferred).allSatisfy { sourceExists($0.source) })
                for fact in food.catalog {
                    if let occurrence = fact.source.origin.0 {
                        try demandRequire(meals.contains(mealKey(occurrence.uuid, fact.revision)))
                    }
                }
            }
        }
        if let history = stockHistory {
            let carried = history.carriedDeliveries ?? []
            let carriedSources = Set(carried.map { $0.source.sourceId })
            try demandRequire(sources.isDisjoint(with: carriedSources))
            try unique(deliveries.observations.map { $0.body.observationId } + carried.flatMap { $0.observations.map { $0.body.observationId } })
            for delivery in carried {
                try demandRequire(delivery.originShopId != origin.shopId.uuid)
                guard let lot = history.lots.first(where: { $0.lotId == delivery.source.sourceId }) else { throw ClientError.invalidResponse }
                try demandRequire(lot.deliverySourceId == delivery.source.sourceId && lot.foodName == delivery.source.foodName && lot.exclusionTags == delivery.source.exclusionTags)
            }
            for lot in history.lots {
                if let delivery = lot.deliverySourceId { try demandRequire(delivery == lot.lotId && sources.union(carriedSources).contains(delivery)) }
            }
            for event in history.events {
                switch event.details {
                case .observe:
                    try demandRequire(history.lots.first { $0.lotId == event.lotId }?.deliverySourceId == nil)
                case .select: break
                case .match(let occurrence, let revision, let ingredient, _):
                    let meal = mealRevisions.first { $0.occurrenceId.uuid == occurrence && $0.revision == revision }?.meal
                    try demandRequire(meal?.planning?.ingredients.contains { $0.id == ingredient } == true)
                case .reserve(let occurrence, let revision, let ingredient, let group, _):
                    let meal = mealRevisions.first { $0.occurrenceId.uuid == occurrence && $0.revision == revision }?.meal
                    let item = meal?.planning?.ingredients.first { $0.id == ingredient }
                    try demandRequire(item?.groupIds.contains(group) == true && meal?.planning?.groups.contains { $0.id == group } == true)
                }
            }
        }
    }
    /// Preserve required nulls and original literals after every nested allowlist passed.
    public func independentData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(wire)
        try demandRequire(bytes.count <= SharedRecordHistoryWire.maximumResponseBytes)
        return bytes
    }
}

// Structural adapter only; these constants are never exported or usable as a live read binding.
private struct HistoryFoodPartition: TrackingStateFields {
    let food: SharedRecordHistory.FoodHistory.FoodPartition
    var schemaVersion: Int { 2 }; var authorityEpoch: Int { 0 }; var privacyRevision: Int { 0 }
    var graph: SharedDemandGraph { food.graph }; var basket: [SharedTrackingBasketLine] { food.basket }
    var catalog: [SharedTrackingFact] { food.catalog }; var bindings: [SharedTrackingBinding] { food.bindings }
    var unbound: [SharedTrackingUnboundFact] { food.unbound }; var legacyLineIds: [SharedDemandID] { food.legacyLineIds }
}
private func historyPacks(_ packs: [SharedDemandPackReview], graph: SharedDemandGraph) throws {
    try demandRequire(packs.count <= 200 && demandUnique(packs.map(\.lineId)))
    try demandRequire(Set(packs.map(\.lineId)) == Set(graph.lines.filter { $0.trashedAt == nil }.map(\.id)))
    for pack in packs { try pack.usablePerPack?.validate() }
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
        let result: SharedRecordHistorySnapshot = try await perform("shops/\(shopID.uuidString.lowercased())/records/history/v1", method: "GET",
            query: [URLQueryItem(name: "includeRetirementStatus", value: "true")], maximumResponseBytes: SharedRecordHistoryWire.maximumResponseBytes)
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try demandRequire(result.record.origin.householdId.string == context.householdID.lowercased() && result.record.origin.shopId.uuid == shopID)
        return result
    }
}
