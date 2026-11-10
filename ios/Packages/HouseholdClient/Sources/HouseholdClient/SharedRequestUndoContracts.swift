import Foundation

public struct SharedRequestUndoState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, clarified, deferred, added }
    public enum Route: String, Codable, Sendable { case current, next }
    public let revision: Int
    public let status: Status
    public let route: Route
    private enum K: String, CodingKey { case revision, status, route }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["revision", "status", "route"])
        let c = try decoder.container(keyedBy: K.self)
        revision = try c.decode(Int.self, forKey: .revision)
        status = try c.decode(Status.self, forKey: .status)
        route = try c.decode(Route.self, forKey: .route)
        try demandRequire(demandRevision(revision))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(revision, forKey: .revision)
        try c.encode(status, forKey: .status)
        try c.encode(route, forKey: .route)
    }
}

public struct SharedRequestUndoLink: Codable, Equatable, Sendable {
    public let requestId: SharedDemandID
    public let shopId: SharedDemandID
    public let lineId: SharedDemandID
    public let reviewedRevision: Int
    public let operationId: SharedDemandID
    private enum K: String, CodingKey { case requestId, shopId, lineId, reviewedRevision, operationId }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["requestId", "shopId", "lineId", "reviewedRevision", "operationId"])
        let c = try decoder.container(keyedBy: K.self)
        requestId = try c.decode(SharedDemandID.self, forKey: .requestId)
        shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        lineId = try c.decode(SharedDemandID.self, forKey: .lineId)
        reviewedRevision = try c.decode(Int.self, forKey: .reviewedRevision)
        operationId = try c.decode(SharedDemandID.self, forKey: .operationId)
        try demandIDs([requestId, shopId, lineId, operationId]); try demandRequire(demandRevision(reviewedRevision))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(shopId, forKey: .shopId)
        try c.encode(lineId, forKey: .lineId)
        try c.encode(reviewedRevision, forKey: .reviewedRevision)
        try c.encode(operationId, forKey: .operationId)
    }
}

public struct SharedRequestUndoCarry: Codable, Equatable, Sendable {
    public let sourceRequestId: SharedDemandID
    public let targetRequestId: SharedDemandID
    public let sourceShopId: SharedDemandID
    public let targetShopId: SharedDemandID
    public let sourceAuthorityEpoch: Int
    public let targetAuthorityEpoch: Int
    public let operationId: SharedDemandID
    private enum K: String, CodingKey { case sourceRequestId, targetRequestId, sourceShopId, targetShopId, sourceAuthorityEpoch, targetAuthorityEpoch, operationId }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["sourceRequestId", "targetRequestId", "sourceShopId", "targetShopId", "sourceAuthorityEpoch", "targetAuthorityEpoch", "operationId"])
        let c = try decoder.container(keyedBy: K.self)
        sourceRequestId = try c.decode(SharedDemandID.self, forKey: .sourceRequestId)
        targetRequestId = try c.decode(SharedDemandID.self, forKey: .targetRequestId)
        sourceShopId = try c.decode(SharedDemandID.self, forKey: .sourceShopId)
        targetShopId = try c.decode(SharedDemandID.self, forKey: .targetShopId)
        sourceAuthorityEpoch = try c.decode(Int.self, forKey: .sourceAuthorityEpoch)
        targetAuthorityEpoch = try c.decode(Int.self, forKey: .targetAuthorityEpoch)
        operationId = try c.decode(SharedDemandID.self, forKey: .operationId)
        try demandIDs([sourceRequestId, targetRequestId, sourceShopId, targetShopId, operationId])
        try demandRequire(demandRevision(sourceAuthorityEpoch) && demandRevision(targetAuthorityEpoch))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(sourceRequestId, forKey: .sourceRequestId)
        try c.encode(targetRequestId, forKey: .targetRequestId)
        try c.encode(sourceShopId, forKey: .sourceShopId)
        try c.encode(targetShopId, forKey: .targetShopId)
        try c.encode(sourceAuthorityEpoch, forKey: .sourceAuthorityEpoch)
        try c.encode(targetAuthorityEpoch, forKey: .targetAuthorityEpoch)
        try c.encode(operationId, forKey: .operationId)
    }
}

public struct SharedRequestUndoBase: Codable, Equatable, Sendable {
    public let shopRevision: Int
    public let authorityEpoch: Int
    public let requestRevision: Int
    public let food: SharedRequestUndoFoodBase
    private enum K: String, CodingKey { case shopRevision, authorityEpoch, requestRevision, food }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["shopRevision", "authorityEpoch", "requestRevision", "food"])
        let c = try decoder.container(keyedBy: K.self)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        requestRevision = try c.decode(Int.self, forKey: .requestRevision)
        food = try c.decode(SharedRequestUndoFoodBase.self, forKey: .food)
        try demandRequire([shopRevision, authorityEpoch, requestRevision].allSatisfy { demandRevision($0) })
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(shopRevision, forKey: .shopRevision)
        try c.encode(authorityEpoch, forKey: .authorityEpoch)
        try c.encode(requestRevision, forKey: .requestRevision)
        try c.encode(food, forKey: .food)
    }
}

public struct SharedRequestUndoOutcome: Codable, Equatable, Sendable {
    public enum Choice: String, Codable, Sendable { case add, link }
    public let requestId: SharedDemandID
    public let choice: Choice
    public let originalItem: String
    public let originalQuantityText: String?
    public let targetBefore: SharedRequestUndoState
    public let targetAfter: SharedRequestUndoState
    public let current: SharedRequestUndoState
    public let restored: SharedRequestUndoState
    public let beforeLink: SharedRequestUndoLink
    public let afterLink: SharedRequestUndoLink?
    public let carry: [SharedRequestUndoCarry]
    private enum K: String, CodingKey { case requestId, choice, originalItem, originalQuantityText, targetBefore, targetAfter, current, restored, beforeLink, afterLink, carry }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["requestId", "choice", "originalItem", "originalQuantityText", "targetBefore", "targetAfter", "current", "restored", "beforeLink", "afterLink", "carry"])
        let c = try decoder.container(keyedBy: K.self)
        requestId = try c.decode(SharedDemandID.self, forKey: .requestId)
        choice = try c.decode(Choice.self, forKey: .choice)
        originalItem = try c.decode(String.self, forKey: .originalItem)
        originalQuantityText = try c.decode(String?.self, forKey: .originalQuantityText)
        targetBefore = try c.decode(SharedRequestUndoState.self, forKey: .targetBefore)
        targetAfter = try c.decode(SharedRequestUndoState.self, forKey: .targetAfter)
        current = try c.decode(SharedRequestUndoState.self, forKey: .current)
        restored = try c.decode(SharedRequestUndoState.self, forKey: .restored)
        beforeLink = try c.decode(SharedRequestUndoLink.self, forKey: .beforeLink)
        afterLink = try c.decode(SharedRequestUndoLink?.self, forKey: .afterLink)
        carry = try c.decode([SharedRequestUndoCarry].self, forKey: .carry)
        try demandRequire(originalQuantityText.map { demandText($0, limit: 80) } ?? true)
        try demandRequire(afterLink == nil && demandText(originalItem, limit: 240) && carry.count <= 50)
        try demandRequire(targetAfter.status == .added && current.status == .added && targetAfter.revision == targetBefore.revision + 1)
        try demandRequire(restored.revision == current.revision + 1 && restored.status == targetBefore.status && restored.route == targetBefore.route)
        try demandRequire(beforeLink.requestId == requestId && beforeLink.reviewedRevision == targetBefore.revision)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(choice, forKey: .choice)
        try c.encode(originalItem, forKey: .originalItem)
        try c.encode(originalQuantityText, forKey: .originalQuantityText)
        try c.encode(targetBefore, forKey: .targetBefore)
        try c.encode(targetAfter, forKey: .targetAfter)
        try c.encode(current, forKey: .current)
        try c.encode(restored, forKey: .restored)
        try c.encode(beforeLink, forKey: .beforeLink)
        try c.encode(afterLink, forKey: .afterLink)
        try c.encode(carry, forKey: .carry)
    }
}

public struct SharedRequestUndoEligibility: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case reviewable, unavailable }
    public let status: Status
    public let reason: String
    private enum K: String, CodingKey { case status, reason }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["status", "reason"])
        let c = try decoder.container(keyedBy: K.self)
        status = try c.decode(Status.self, forKey: .status)
        reason = try c.decode(String.self, forKey: .reason)
        try demandRequire(reason.range(of: "^[a-z0-9_]{1,160}$", options: .regularExpression) != nil)
        try demandRequire((status == .reviewable) == (reason == "explicit_current_preview_required"))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(status, forKey: .status)
        try c.encode(reason, forKey: .reason)
    }
}

public struct SharedRequestUndoHistoryItem: Codable, Equatable, Sendable {
    public let operationId: SharedDemandID
    public let kind: String
    public let shopRevision: Int
    public let committedAt: String
    public let eligibility: SharedRequestUndoEligibility
    private enum K: String, CodingKey { case operationId, kind, shopRevision, committedAt, eligibility }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["operationId", "kind", "shopRevision", "committedAt", "eligibility"])
        let c = try decoder.container(keyedBy: K.self)
        operationId = try c.decode(SharedDemandID.self, forKey: .operationId)
        kind = try c.decode(String.self, forKey: .kind)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        committedAt = try c.decode(String.self, forKey: .committedAt)
        eligibility = try c.decode(SharedRequestUndoEligibility.self, forKey: .eligibility)
        try demandIDs([operationId]); try demandRequire(kind == "request.apply" && demandRevision(shopRevision) && demandTime(committedAt) != nil)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(operationId, forKey: .operationId)
        try c.encode(kind, forKey: .kind)
        try c.encode(shopRevision, forKey: .shopRevision)
        try c.encode(committedAt, forKey: .committedAt)
        try c.encode(eligibility, forKey: .eligibility)
    }
}

public struct SharedRequestUndoHistory: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let shopRevision: Int
    public let authorityEpoch: Int
    public let items: [SharedRequestUndoHistoryItem]
    public let nextBeforeRevision: String?
    private enum K: String, CodingKey { case schemaVersion, shopId, shopRevision, authorityEpoch, items, nextBeforeRevision }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "shopId", "shopRevision", "authorityEpoch", "items", "nextBeforeRevision"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        items = try c.decode([SharedRequestUndoHistoryItem].self, forKey: .items)
        nextBeforeRevision = try c.decode(String?.self, forKey: .nextBeforeRevision)
        try demandRequire(schemaVersion == 1 && demandRevision(shopRevision) && demandRevision(authorityEpoch) && items.count <= 20 && demandUnique(items.map(\.operationId)))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(shopId, forKey: .shopId)
        try c.encode(shopRevision, forKey: .shopRevision)
        try c.encode(authorityEpoch, forKey: .authorityEpoch)
        try c.encode(items, forKey: .items)
        try c.encode(nextBeforeRevision, forKey: .nextBeforeRevision)
    }
}

/// Database evidence hashes are opaque. They are never recomputed with tracking
/// code-point ordering (or the native legacy JSON canonicalizer).
public struct SharedRequestUndoDigest: Codable, Equatable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
        try demandRequire(value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && value != String(repeating: "0", count: 64))
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
}
public enum SharedRequestUndoFoodBase: Codable, Equatable, Sendable {
    case legacy(catalogDigest: SharedRequestUndoDigest)
    case tracked(graphRevision: Int, graphDigest: SharedRequestUndoDigest)
    case partition(graphRevision: Int, graphDigest: SharedRequestUndoDigest, stateDigest: SharedTrackingDigest, privacyRevision: Int)
    private enum K: String, CodingKey { case kind, catalogDigest, graphRevision, graphDigest, stateDigest, privacyRevision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self), kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "legacy":
            try demandExactKeys(decoder, ["kind", "catalogDigest"])
            self = .legacy(catalogDigest: try c.decode(SharedRequestUndoDigest.self, forKey: .catalogDigest))
        case "tracked":
            try demandExactKeys(decoder, ["kind", "graphRevision", "graphDigest"])
            let revision = try c.decode(Int.self, forKey: .graphRevision); try demandRequire(demandRevision(revision))
            self = .tracked(graphRevision: revision, graphDigest: try c.decode(SharedRequestUndoDigest.self, forKey: .graphDigest))
        case "partition":
            try demandExactKeys(decoder, ["kind", "graphRevision", "graphDigest", "stateDigest", "privacyRevision"])
            let revision = try c.decode(Int.self, forKey: .graphRevision), privacy = try c.decode(Int.self, forKey: .privacyRevision)
            let state = try c.decode(SharedTrackingDigest.self, forKey: .stateDigest)
            try demandRequire(demandRevision(revision) && demandRevision(privacy, zero: true) && state.value != String(repeating: "0", count: 64))
            self = .partition(graphRevision: revision, graphDigest: try c.decode(SharedRequestUndoDigest.self, forKey: .graphDigest), stateDigest: state, privacyRevision: privacy)
        default: throw ClientError.invalidResponse
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .legacy(let digest): try c.encode("legacy", forKey: .kind); try c.encode(digest, forKey: .catalogDigest)
        case .tracked(let revision, let digest):
            try c.encode("tracked", forKey: .kind); try c.encode(revision, forKey: .graphRevision); try c.encode(digest, forKey: .graphDigest)
        case .partition(let revision, let graph, let state, let privacy):
            try c.encode("partition", forKey: .kind); try c.encode(revision, forKey: .graphRevision); try c.encode(graph, forKey: .graphDigest)
            try c.encode(state.value, forKey: .stateDigest); try c.encode(privacy, forKey: .privacyRevision)
        }
    }
}
public enum SharedRequestUndoFood: Decodable, Equatable, Sendable {
    case legacy(catalog: [SharedTrackingFact]), tracked(graph: SharedDemandGraph), partition(state: SharedTrackingState)
    private enum K: String, CodingKey { case kind, catalog, graph, state }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "legacy":
            try demandExactKeys(decoder, ["kind", "catalog"])
            let catalog = try c.decode([SharedTrackingFact].self, forKey: .catalog)
            try demandRequire(catalog.count <= 2000 && demandUnique(catalog.map(\.id))); self = .legacy(catalog: catalog)
        case "tracked":
            try demandExactKeys(decoder, ["kind", "graph"])
            let graph = try trackingDecode(SharedDemandGraph.self, from: c.superDecoder(forKey: .graph), shape: .graph)
            try graph.validate(); self = .tracked(graph: graph)
        case "partition":
            try demandExactKeys(decoder, ["kind", "state"]); self = .partition(state: try c.decode(SharedTrackingState.self, forKey: .state))
        default: throw ClientError.invalidResponse
        }
    }
    public var graph: SharedDemandGraph? {
        switch self { case .legacy: nil; case .tracked(let graph): graph; case .partition(let state): state.graph }
    }
    public var catalog: [SharedTrackingFact]? {
        switch self { case .legacy(let catalog): catalog; case .tracked: nil; case .partition(let state): state.catalog }
    }
}
public struct SharedRequestUndoAction: Codable, Equatable, Sendable {
    public let kind: String
    public let body: Body
    public struct Body: Codable, Equatable, Sendable {
        public let targetOperationId, requestId: SharedDemandID
        public let baseRequestRevision: Int
        public let lines: [ShopperBasketLine]
        public let quote: ShopperQuote
        private enum K: String, CodingKey { case targetOperationId, requestId, baseRequestRevision, lines, quote }
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["targetOperationId", "requestId", "baseRequestRevision", "lines", "quote"])
            let c = try decoder.container(keyedBy: K.self)
            targetOperationId = try c.decode(SharedDemandID.self, forKey: .targetOperationId); requestId = try c.decode(SharedDemandID.self, forKey: .requestId)
            baseRequestRevision = try c.decode(Int.self, forKey: .baseRequestRevision)
            lines = try trackingDecode([ShopperBasketLine].self, from: c.superDecoder(forKey: .lines), shape: requestUndoBasketShape)
            try requestUndoQuoteShape(c.superDecoder(forKey: .quote)); quote = try c.decode(ShopperQuote.self, forKey: .quote)
            try demandIDs([targetOperationId, requestId]); try demandRequire(demandRevision(baseRequestRevision))
            _ = try SharedTrackingAction(.patch(.init(quote: quote, lines: lines)))
        }
    }
    private enum K: String, CodingKey { case kind, body }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["kind", "body"]); let c = try decoder.container(keyedBy: K.self)
        kind = try c.decode(String.self, forKey: .kind); body = try c.decode(Body.self, forKey: .body)
        try demandRequire(kind == "request.undoAcceptance")
    }
}
public struct SharedRequestUndoScope: Decodable, Equatable, Sendable {
    public let requestsChanged, mealsChanged, quoteChanged: Bool
    public let firstAdoptionReversed: Bool
    public let touchedLines: [SharedOperationUndoTouchedLine]
    public let graphRows: Int
    private enum K: String, CodingKey { case requestsChanged, mealsChanged, quoteChanged, firstAdoptionReversed, touchedLines, graphRows }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let keys: Set<String> = ["requestsChanged", "mealsChanged", "quoteChanged", "touchedLines", "graphRows"]
        try demandExactKeys(decoder, c.contains(.firstAdoptionReversed) ? keys.union(["firstAdoptionReversed"]) : keys)
        requestsChanged = try c.decode(Bool.self, forKey: .requestsChanged); mealsChanged = try c.decode(Bool.self, forKey: .mealsChanged)
        quoteChanged = try c.decode(Bool.self, forKey: .quoteChanged)
        firstAdoptionReversed = c.contains(.firstAdoptionReversed) ? try c.decode(Bool.self, forKey: .firstAdoptionReversed) : false
        if c.contains(.firstAdoptionReversed) { try demandRequire(firstAdoptionReversed) }
        touchedLines = try c.decode([SharedOperationUndoTouchedLine].self, forKey: .touchedLines); graphRows = try c.decode(Int.self, forKey: .graphRows)
        try demandRequire(requestsChanged && !mealsChanged && !quoteChanged && touchedLines.count <= 200 && demandUnique(touchedLines.map(\.lineId)) && (0...6200).contains(graphRows))
    }
}
public struct SharedRequestUndoCandidate: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let shopId, targetOperationId: SharedDemandID
    public let effectDigest: SharedRequestUndoDigest
    public let base: SharedRequestUndoBase
    public let action: SharedRequestUndoAction
    public let requestUndo: SharedRequestUndoOutcome
    public let scope: SharedRequestUndoScope
    public let foodBefore, foodAfter: SharedRequestUndoFood
    public let beforeCheckout, afterCheckout: ShopperBudget
    public let packReviewLineIds: [SharedDemandID]
    public let storeBasis: SharedOperationUndoStoreBasis?
    let wire: JSONValue
    private enum K: String, CodingKey { case schemaVersion, kind, shopId, targetOperationId, effectDigest, base, action, requestUndo, scope, foodBefore, foodAfter, beforeCheckout, afterCheckout, packReviewLineIds, storeBasis }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "kind", "shopId", "targetOperationId", "effectDigest", "base", "action", "requestUndo", "scope", "foodBefore", "foodAfter", "beforeCheckout", "afterCheckout", "packReviewLineIds", "storeBasis"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); kind = try c.decode(String.self, forKey: .kind)
        shopId = try c.decode(SharedDemandID.self, forKey: .shopId); targetOperationId = try c.decode(SharedDemandID.self, forKey: .targetOperationId)
        effectDigest = try c.decode(SharedRequestUndoDigest.self, forKey: .effectDigest); base = try c.decode(SharedRequestUndoBase.self, forKey: .base)
        action = try c.decode(SharedRequestUndoAction.self, forKey: .action); requestUndo = try c.decode(SharedRequestUndoOutcome.self, forKey: .requestUndo)
        scope = try c.decode(SharedRequestUndoScope.self, forKey: .scope)
        foodBefore = try c.decode(SharedRequestUndoFood.self, forKey: .foodBefore); foodAfter = try c.decode(SharedRequestUndoFood.self, forKey: .foodAfter)
        beforeCheckout = try trackingDecode(ShopperBudget.self, from: c.superDecoder(forKey: .beforeCheckout), shape: requestUndoBudgetShape)
        afterCheckout = try trackingDecode(ShopperBudget.self, from: c.superDecoder(forKey: .afterCheckout), shape: requestUndoBudgetShape)
        packReviewLineIds = try c.decode([SharedDemandID].self, forKey: .packReviewLineIds)
        storeBasis = try c.decode(SharedOperationUndoStoreBasis?.self, forKey: .storeBasis)
        wire = try JSONValue(from: decoder)
        try validateStructure()
    }
}
public struct SharedRequestUndoPreviewInput: Encodable, Equatable, Sendable {
    public let targetOperationId: SharedDemandID
    public let base: SharedRequestUndoBase
    public let effectDigest: SharedRequestUndoDigest
    public let packs: [SharedDemandPackReview]
    public let acceptOverage, acceptUnknown: Bool
    public init(candidate: SharedRequestUndoCandidate, packs: [SharedDemandPackReview], acceptOverage: Bool, acceptUnknown: Bool) throws {
        targetOperationId = candidate.targetOperationId; base = candidate.base; effectDigest = candidate.effectDigest
        self.packs = packs; self.acceptOverage = acceptOverage; self.acceptUnknown = acceptUnknown
        try validate(candidate: candidate)
    }
}
public enum SharedRequestUndoFoodReceipt: Decodable, Equatable, Sendable {
    case legacy, tracked(SharedDemandReceipt)
    private enum K: String, CodingKey { case kind, receipt }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["kind", "receipt"]); let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "legacy": let isNull = try c.decodeNil(forKey: .receipt); try demandRequire(isNull); self = .legacy
        case "tracked": self = .tracked(try requestUndoReceipt(c.superDecoder(forKey: .receipt)))
        default: throw ClientError.invalidResponse
        }
    }
}
public struct SharedRequestUndoPreview: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let candidate: SharedRequestUndoCandidate
    public let previewId, operationId: SharedDemandID
    public let previewDigest: SharedRequestUndoDigest
    public let expiresAt: String
    public let packs: [SharedDemandPackReview]
    public let foodReceipt: SharedRequestUndoFoodReceipt
    private enum K: String, CodingKey { case schemaVersion, kind, candidate, previewId, previewDigest, expiresAt, operationId, packs, foodReceipt }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "kind", "candidate", "previewId", "previewDigest", "expiresAt", "operationId", "packs", "foodReceipt"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); kind = try c.decode(String.self, forKey: .kind)
        candidate = try c.decode(SharedRequestUndoCandidate.self, forKey: .candidate)
        previewId = try c.decode(SharedDemandID.self, forKey: .previewId); operationId = try c.decode(SharedDemandID.self, forKey: .operationId)
        previewDigest = try c.decode(SharedRequestUndoDigest.self, forKey: .previewDigest); expiresAt = try c.decode(String.self, forKey: .expiresAt)
        packs = try trackingDecode([SharedDemandPackReview].self, from: c.superDecoder(forKey: .packs), shape: .array(.pack))
        foodReceipt = try c.decode(SharedRequestUndoFoodReceipt.self, forKey: .foodReceipt)
        try demandIDs([previewId, operationId]); try demandRequire(schemaVersion == 1 && kind == "requestAcceptanceUndoPreview" && demandTime(expiresAt) != nil && operationId != candidate.targetOperationId)
    }
}
public struct SharedRequestUndoReview: Equatable, Sendable {
    public let context: SharedDemandContext
    public let shop: ShopperShop
    public let candidate: SharedRequestUndoCandidate
    public let input: SharedRequestUndoPreviewInput
    public let response: SharedRequestUndoPreview
    init(context: SharedDemandContext, shop: ShopperShop, candidate: SharedRequestUndoCandidate, input: SharedRequestUndoPreviewInput, response: SharedRequestUndoPreview) throws {
        self.context = context; self.shop = shop; self.candidate = candidate; self.input = input; self.response = response
        try validate()
    }
}
