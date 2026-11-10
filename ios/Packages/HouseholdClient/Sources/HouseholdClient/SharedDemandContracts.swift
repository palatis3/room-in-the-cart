import Foundation

/// Required JSON null is different from an omitted key. Synthesis decodes this
/// wrapper with decode(_:forKey:), so an absent required field fails decoding.
@propertyWrapper public struct SharedDemandNullable<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Value?
    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer(); wrappedValue = c.decodeNil() ? nil : try c.decode(Value.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}

public struct SharedDemandID: Codable, Equatable, Hashable, Sendable {
    public let uuid: UUID
    public var string: String { uuid.uuidString.lowercased() }
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
    var valid: Bool { string.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer(), value = try c.decode(String.self)
        guard value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil,
              let uuid = UUID(uuidString: value) else { throw ClientError.invalidResponse }
        self.uuid = uuid
    }
    public func encode(to encoder: Encoder) throws { try demandRequire(valid); var c = encoder.singleValueContainer(); try c.encode(string) }
}

public struct SharedDemandAmount: Codable, Equatable, Sendable {
    public let numerator, denominator: Int64
    public init(numerator: Int64, denominator: Int64 = 1) throws {
        var a = numerator, b = denominator
        guard a > 0, b > 0 else { throw ClientError.configuration }
        while b != 0 { (a, b) = (b, a % b) }
        guard a == 1 else { throw ClientError.configuration }
        self.numerator = numerator; self.denominator = denominator
    }
    private enum K: String, CodingKey { case numerator, denominator }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let n = try c.decode(String.self, forKey: .numerator), d = try c.decode(String.self, forKey: .denominator)
        guard let nn = Int64(n), let dd = Int64(d), String(nn) == n, String(dd) == d else { throw ClientError.invalidResponse }
        try self.init(numerator: nn, denominator: dd)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self); try c.encode(String(numerator), forKey: .numerator); try c.encode(String(denominator), forKey: .denominator)
    }
}
public typealias SharedDemandUnit = HistoryUnit

public struct SharedDemandConversion: Codable, Equatable, Sendable {
    public var sourceUnit, targetUnit: SharedDemandUnit
    public var targetAmountPerSourceUnit: SharedDemandAmount
    public var sourceNote, confirmedAt: String
    public init(sourceUnit: SharedDemandUnit, targetUnit: SharedDemandUnit, targetAmountPerSourceUnit: SharedDemandAmount, sourceNote: String, confirmedAt: String) {
        self.sourceUnit = sourceUnit; self.targetUnit = targetUnit; self.targetAmountPerSourceUnit = targetAmountPerSourceUnit; self.sourceNote = sourceNote; self.confirmedAt = confirmedAt
    }
}
public struct SharedDemandQuantity: Codable, Equatable, Sendable {
    public var amount: SharedDemandAmount; public var unit: SharedDemandUnit; public var originalLiteral: String
    @SharedDemandNullable public var confirmedConversion: SharedDemandConversion?
    public init(amount: SharedDemandAmount, unit: SharedDemandUnit, originalLiteral: String, confirmedConversion: SharedDemandConversion? = nil) {
        self.amount = amount; self.unit = unit; self.originalLiteral = originalLiteral; self.confirmedConversion = confirmedConversion
    }
}

public enum SharedDemandSource: Codable, Equatable, Sendable {
    case manual
    case imported(batchId: SharedDemandID, entryId: SharedDemandID)
    case request(requestId: SharedDemandID, appliedRequestRevision: Int)
    case meal(occurrenceId: SharedDemandID, ingredientId: SharedDemandID, groupId: SharedDemandID?, bindingId: SharedDemandID?)
    case reservation(reservationId: SharedDemandID, purpose: String, originOccurrenceId: SharedDemandID?, ingredientId: SharedDemandID, groupId: SharedDemandID?, bindingId: SharedDemandID?)
    private enum K: String, CodingKey { case kind, batchId, entryId, requestId, appliedRequestRevision, occurrenceId, ingredientId, groupId, bindingId, reservationId, purpose, originOccurrenceId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let allowed: [String: Set<String>] = ["manual": ["kind"], "import": ["kind", "batchId", "entryId"], "request": ["kind", "requestId", "appliedRequestRevision"], "meal": ["kind", "occurrenceId", "ingredientId", "groupId", "bindingId"], "reservation": ["kind", "reservationId", "purpose", "originOccurrenceId", "ingredientId", "groupId", "bindingId"]]
        guard let keys = allowed[kind] else { throw ClientError.invalidResponse }
        try demandExactKeys(decoder, keys)
        switch kind {
        case "manual": self = .manual
        case "import": self = .imported(batchId: try c.decode(SharedDemandID.self, forKey: .batchId), entryId: try c.decode(SharedDemandID.self, forKey: .entryId))
        case "request": self = .request(requestId: try c.decode(SharedDemandID.self, forKey: .requestId), appliedRequestRevision: try c.decode(Int.self, forKey: .appliedRequestRevision))
        case "meal": self = .meal(occurrenceId: try c.decode(SharedDemandID.self, forKey: .occurrenceId), ingredientId: try c.decode(SharedDemandID.self, forKey: .ingredientId), groupId: try c.decode(SharedDemandID?.self, forKey: .groupId), bindingId: try c.decode(SharedDemandID?.self, forKey: .bindingId))
        case "reservation": self = .reservation(reservationId: try c.decode(SharedDemandID.self, forKey: .reservationId), purpose: try c.decode(String.self, forKey: .purpose), originOccurrenceId: try c.decode(SharedDemandID?.self, forKey: .originOccurrenceId), ingredientId: try c.decode(SharedDemandID.self, forKey: .ingredientId), groupId: try c.decode(SharedDemandID?.self, forKey: .groupId), bindingId: try c.decode(SharedDemandID?.self, forKey: .bindingId))
        default: throw ClientError.invalidResponse
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .manual: try c.encode("manual", forKey: .kind)
        case .imported(let batch, let entry): try c.encode("import", forKey: .kind); try c.encode(batch, forKey: .batchId); try c.encode(entry, forKey: .entryId)
        case .request(let id, let revision): try c.encode("request", forKey: .kind); try c.encode(id, forKey: .requestId); try c.encode(revision, forKey: .appliedRequestRevision)
        case .meal(let occurrence, let ingredient, let group, let binding):
            try c.encode("meal", forKey: .kind); try c.encode(occurrence, forKey: .occurrenceId); try c.encode(ingredient, forKey: .ingredientId); try c.encode(group, forKey: .groupId); try c.encode(binding, forKey: .bindingId)
        case .reservation(let id, let purpose, let occurrence, let ingredient, let group, let binding):
            try c.encode("reservation", forKey: .kind); try c.encode(id, forKey: .reservationId); try c.encode(purpose, forKey: .purpose); try c.encode(occurrence, forKey: .originOccurrenceId); try c.encode(ingredient, forKey: .ingredientId); try c.encode(group, forKey: .groupId); try c.encode(binding, forKey: .bindingId)
        }
    }
}
public enum SharedDemandExclusionResolution: Codable, Equatable, Sendable {
    case unresolved
    case mapped(tags: [String], confirmedAt: String)
    private enum K: String, CodingKey { case kind, tags, confirmedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "unresolved": try demandExactKeys(decoder, ["kind"]); self = .unresolved
        case "mapped": try demandExactKeys(decoder, ["kind", "tags", "confirmedAt"]); self = .mapped(tags: try c.decode([String].self, forKey: .tags), confirmedAt: try c.decode(String.self, forKey: .confirmedAt))
        default: throw ClientError.invalidResponse
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self { case .unresolved: try c.encode("unresolved", forKey: .kind)
        case .mapped(let tags, let at): try c.encode("mapped", forKey: .kind); try c.encode(tags, forKey: .tags); try c.encode(at, forKey: .confirmedAt) }
    }
}

public struct SharedDemandSourceExclusion: Codable, Equatable, Sendable {
    public var occurrenceId: SharedDemandID
    @SharedDemandNullable public var ingredientId: SharedDemandID?
    public var label: String
    public var resolution: SharedDemandExclusionResolution
    public init(occurrenceId: SharedDemandID, ingredientId: SharedDemandID?, label: String, resolution: SharedDemandExclusionResolution) {
        self.occurrenceId = occurrenceId; self.ingredientId = ingredientId; self.label = label; self.resolution = resolution
    }
}

public struct SharedDemandLine: Codable, Equatable, Sendable {
    public var id: SharedDemandID
    public var name: String
    public var unit: SharedDemandUnit
    public var originalOrder: Int
    @SharedDemandNullable public var trashedAt: String?
    public init(id: SharedDemandID = SharedDemandID(), name: String, unit: SharedDemandUnit, originalOrder: Int, trashedAt: String? = nil) {
        self.id = id; self.name = name; self.unit = unit; self.originalOrder = originalOrder; self.trashedAt = trashedAt
    }
}

public struct SharedDemandContribution: Codable, Equatable, Sendable {
    public var id: SharedDemandID
    public var lineId: SharedDemandID
    public var source: SharedDemandSource
    @SharedDemandNullable public var productKey: String?
    public var productName: String
    public var originalText: String
    @SharedDemandNullable public var quantity: SharedDemandQuantity?
    public var sourceExclusions: [SharedDemandSourceExclusion]?
    public var exclusions: [String]
    public var contains: [String]
    @SharedDemandNullable public var removedAt: String?
    public init(id: SharedDemandID = SharedDemandID(), lineId: SharedDemandID, source: SharedDemandSource, productKey: String?, productName: String, originalText: String, quantity: SharedDemandQuantity?, sourceExclusions: [SharedDemandSourceExclusion]? = nil, exclusions: [String] = [], contains: [String] = [], removedAt: String? = nil) {
        self.id = id; self.lineId = lineId; self.source = source; self.productKey = productKey; self.productName = productName; self.originalText = originalText; self.quantity = quantity; self.sourceExclusions = sourceExclusions; self.exclusions = exclusions; self.contains = contains; self.removedAt = removedAt
    }
}

public struct SharedDemandConfirmation: Codable, Equatable, Sendable {
    public var productMatchConfirmed: Bool
    public var confirmedAt: String
    public var evidence: String
    public init(productMatchConfirmed: Bool = true, confirmedAt: String, evidence: String) {
        self.productMatchConfirmed = productMatchConfirmed; self.confirmedAt = confirmedAt; self.evidence = evidence
    }
}

public struct SharedDemandEdge: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case duplicate, withinExisting }
    public var id: SharedDemandID
    public var kind: Kind
    public var demandId: SharedDemandID
    public var supplyId: SharedDemandID
    public var quantity: SharedDemandQuantity
    public var confirmation: SharedDemandConfirmation
    public init(id: SharedDemandID = SharedDemandID(), kind: Kind, demandId: SharedDemandID, supplyId: SharedDemandID, quantity: SharedDemandQuantity, confirmation: SharedDemandConfirmation) {
        self.id = id; self.kind = kind; self.demandId = demandId; self.supplyId = supplyId; self.quantity = quantity; self.confirmation = confirmation
    }
}

public struct SharedDemandGraph: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var conversionTableVersion: String
    public var householdId: SharedDemandID
    public var shopId: SharedDemandID
    public var revision: Int
    public var lines: [SharedDemandLine]
    public var contributions: [SharedDemandContribution]
    public var edges: [SharedDemandEdge]
    public var usedIds: [SharedDemandID]
    public init(schemaVersion: Int = 1, conversionTableVersion: String = "us-customary-metric-v1", householdId: SharedDemandID, shopId: SharedDemandID, revision: Int, lines: [SharedDemandLine], contributions: [SharedDemandContribution], edges: [SharedDemandEdge], usedIds: [SharedDemandID]) {
        self.schemaVersion = schemaVersion; self.conversionTableVersion = conversionTableVersion; self.householdId = householdId; self.shopId = shopId; self.revision = revision; self.lines = lines; self.contributions = contributions; self.edges = edges; self.usedIds = usedIds
    }
}

public struct SharedDemandChange: Codable, Equatable, Sendable {
    public var lines: [SharedDemandLine]
    public var contributions: [SharedDemandContribution]
    public var edges: [SharedDemandEdge]
    public var removeSourceIds: [SharedDemandID]
    public var removeEdgeIds: [SharedDemandID]
    public var quantifyReservationIds: [SharedDemandID]?
    public var clarifyReservationProductIds: [SharedDemandID]?
    public init(lines: [SharedDemandLine] = [], contributions: [SharedDemandContribution] = [], edges: [SharedDemandEdge] = [], removeSourceIds: [SharedDemandID] = [], removeEdgeIds: [SharedDemandID] = [], quantifyReservationIds: [SharedDemandID]? = nil, clarifyReservationProductIds: [SharedDemandID]? = nil) {
        self.lines = lines; self.contributions = contributions; self.edges = edges; self.removeSourceIds = removeSourceIds; self.removeEdgeIds = removeEdgeIds; self.quantifyReservationIds = quantifyReservationIds; self.clarifyReservationProductIds = clarifyReservationProductIds
    }
}

public struct SharedDemandBase: Codable, Equatable, Sendable {
    public var shopRevision: Int
    public var authorityEpoch: Int
    public var graphRevision: Int
    public init(shopRevision: Int, authorityEpoch: Int, graphRevision: Int) {
        self.shopRevision = shopRevision; self.authorityEpoch = authorityEpoch; self.graphRevision = graphRevision
    }
}

public struct SharedDemandPackReview: Codable, Equatable, Sendable {
    public var lineId: SharedDemandID
    @SharedDemandNullable public var usablePerPack: SharedDemandQuantity?
    public var acceptUnresolved: Bool
    public init(lineId: SharedDemandID, usablePerPack: SharedDemandQuantity?, acceptUnresolved: Bool) {
        self.lineId = lineId; self.usablePerPack = usablePerPack; self.acceptUnresolved = acceptUnresolved
    }
}

public struct SharedDemandRequestApply: Codable, Equatable, Sendable {
    public var requestId: SharedDemandID
    public var previewId: SharedDemandID
    public var acceptOverage: Bool
    public var acceptUnknown: Bool
    public init(requestId: SharedDemandID, previewId: SharedDemandID, acceptOverage: Bool, acceptUnknown: Bool) {
        self.requestId = requestId; self.previewId = previewId; self.acceptOverage = acceptOverage; self.acceptUnknown = acceptUnknown
    }
}

public struct SharedDemandMealEdit: Codable, Equatable, Sendable {
    public var occurrenceId: SharedDemandID
    @SharedDemandNullable public var baseMealRevision: Int?
    @SharedDemandNullable public var meal: SharedMeal?
    public var proposalId: SharedDemandID?
    public var changeProposalId: SharedDemandID?
    public init(occurrenceId: SharedDemandID, baseMealRevision: Int?, meal: SharedMeal?, proposalId: SharedDemandID? = nil, changeProposalId: SharedDemandID? = nil) {
        self.occurrenceId = occurrenceId; self.baseMealRevision = baseMealRevision; self.meal = meal; self.proposalId = proposalId; self.changeProposalId = changeProposalId
    }
}

public struct SharedDemandShopPatch: Codable, Equatable, Sendable {
    public var quote: ShopperQuote
    public var lines: [ShopperBasketLine]
    public var mealEdit: SharedDemandMealEdit?
    public var reviewedStoreBasisRevision: Int?
    public init(quote: ShopperQuote, lines: [ShopperBasketLine], mealEdit: SharedDemandMealEdit? = nil, reviewedStoreBasisRevision: Int? = nil) {
        self.quote = quote; self.lines = lines; self.mealEdit = mealEdit; self.reviewedStoreBasisRevision = reviewedStoreBasisRevision
    }
}

public struct SharedDemandPreviewRequest: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case adopt, change, undo, review }
    public var mode: Mode
    public var base: SharedDemandBase
    public var change: SharedDemandChange
    public var action: SharedDemandAction
    public var packs: [SharedDemandPackReview]
    public var undoOperationId: SharedDemandID?
    public init(mode: Mode, base: SharedDemandBase, change: SharedDemandChange, action: SharedDemandAction, packs: [SharedDemandPackReview], undoOperationId: SharedDemandID? = nil) {
        self.mode = mode; self.base = base; self.change = change; self.action = action; self.packs = packs; self.undoOperationId = undoOperationId
    }
}

public enum SharedDemandAction: Codable, Equatable, Sendable {
    case patch(SharedDemandShopPatch)
    case request(SharedDemandRequestApply)
    public var kind: String { switch self { case .patch: "shop.patch"; case .request: "request.apply" } }
    private enum K: String, CodingKey { case kind, body }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "shop.patch": self = .patch(try c.decode(SharedDemandShopPatch.self, forKey: .body))
        case "request.apply": self = .request(try c.decode(SharedDemandRequestApply.self, forKey: .body))
        default: throw ClientError.invalidResponse
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self); try c.encode(kind, forKey: .kind)
        switch self { case .patch(let body): try c.encode(body, forKey: .body); case .request(let body): try c.encode(body, forKey: .body) }
    }
    func bodyValues() throws -> [String: JSONValue] {
        let bytes: Data
        switch self { case .patch(let body): bytes = try encoded(body); case .request(let body): bytes = try encoded(body) }
        return try JSONDecoder().decode([String: JSONValue].self, from: bytes)
    }
}
public struct SharedDemandDelta<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let id: SharedDemandID
    @SharedDemandNullable public var before: Value?
    @SharedDemandNullable public var after: Value?
    public init(id: SharedDemandID, before: Value?, after: Value?) { self.id = id; self.before = before; self.after = after }
}
public struct SharedDemandReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operationId, householdId, shopId: SharedDemandID
    public let baseRevision, resultRevision: Int
    public let lines: [SharedDemandDelta<SharedDemandLine>]
    public let contributions: [SharedDemandDelta<SharedDemandContribution>]
    public let edges: [SharedDemandDelta<SharedDemandEdge>]
}
public struct SharedDemandPage: Codable, Equatable, Sendable {
    /// Absent on older servers. Meal-action review requires this exact server digest.
    public var graphDigest: String? = nil
    /// Absent on an older server. Missing is not an empty adoption catalog.
    public var legacySources: SharedDemandLegacySources? = nil
    public enum Status: String, Codable, Sendable { case legacy, enabled, reviewRequired }
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let shopRevision, authorityEpoch: Int
    public let status: Status
    @SharedDemandNullable public var graph: SharedDemandGraph?
    public let totals: [SharedDemandLineTotal]
}
public struct SharedDemandPreview: Codable, Equatable, Sendable {
    public let previewId: SharedDemandID
    public let previewDigest, expiresAt: String
    public let before, after: SharedDemandGraph
    public let receipt: SharedDemandReceipt
    public let packs: [SharedDemandPackReview]
    public let beforeTotals, afterTotals: [SharedDemandLineTotal]
    public let shopRevision, authorityEpoch: Int
}
public struct SharedDemandContext: Codable, Equatable, Sendable {
    public let subject, householdID, memberID, deviceID: String
}
/// A preview is not a shared commit and does not enqueue Apply automatically.
public struct SharedDemandReview: Codable, Equatable, Sendable {
    public let context: SharedDemandContext
    public let shopID: UUID
    public let request: SharedDemandPreviewRequest
    public let preview: SharedDemandPreview
}
/// Persisted alongside exact PendingOperation.bytes in the existing private outbox.
public struct SharedDemandOperationBinding: Codable, Equatable, Sendable {
    public let context: SharedDemandContext
    public let shopID: SharedDemandID
    public let reservedOperationID, previewID: SharedDemandID
    public let previewDigest: String
    public let action: SharedDemandAction
    public let base: CommandBase
    public let graphRevision: Int
}

/// Authoritative server totals; never calculated from pack count on the client.
public struct SharedDemandLineTotal: Codable, Equatable, Sendable {
    public let lineId: SharedDemandID
    public let unit: SharedDemandUnit
    @SharedDemandNullable public var quantity: SharedDemandAmount?
    public let activeContributionIds: [SharedDemandID]
}
