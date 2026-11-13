import Foundation

public struct SharedTrackingActionSourceBase: Codable, Equatable, Sendable {
    public let shopRevision, authorityEpoch, graphRevision: Int
    public let stateDigest: String
    public init(page: SharedTrackingPage) throws {
        guard page.status == .legacy, page.graph.revision == 0, page.state != nil, page.projection == nil else { throw ClientError.configuration }
        shopRevision = page.shopRevision; authorityEpoch = page.authorityEpoch; graphRevision = 0; stateDigest = page.basisDigest.value
    }
    private enum K: String, CodingKey { case shopRevision, authorityEpoch, graphRevision, stateDigest }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["shopRevision", "authorityEpoch", "graphRevision", "stateDigest"])
        let c = try decoder.container(keyedBy: K.self)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision); authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        graphRevision = try c.decode(Int.self, forKey: .graphRevision); stateDigest = try c.decode(SharedTrackingDigest.self, forKey: .stateDigest).value
        try demandRequire(demandRevision(shopRevision) && demandRevision(authorityEpoch) && graphRevision == 0)
    }
}
public struct SharedTrackingActionSourceRequest: Encodable, Equatable, Sendable {
    public let base: SharedTrackingActionSourceBase
    public let action: SharedTrackingAction
    public init(page: SharedTrackingPage, action: SharedDemandAction, requestPreview: ShopperPreview? = nil) throws {
        base = try .init(page: page)
        switch action {
        case .patch(var body):
            guard var edit = body.mealEdit, edit.proposalId == nil || edit.changeProposalId == nil, requestPreview == nil else { throw ClientError.configuration }
            edit.meal = edit.meal.map(normalizedDemandMeal); body.mealEdit = edit
            self.action = try .init(.patch(body))
        case .request(let body):
            guard let requestPreview else { throw ClientError.configuration }
            try demandRequire(requestPreview.previewId == body.previewId.string && requestPreview.shopRevision == page.shopRevision && requestPreview.authorityEpoch == page.authorityEpoch)
            try demandRequire(demandRevision(requestPreview.requestRevision) && requestPreview.requestRevision < Int(Int32.max) && ["add", "link"].contains(requestPreview.choice))
            try demandRequire(!requestPreview.requiresOverageAcceptance || body.acceptOverage)
            try demandRequire(!requestPreview.requiresUnknownAcceptance || body.acceptUnknown)
            self.action = try .init(action)
        }
    }
}
/// A descriptor for an exact proposed authoritative source, never an allocation
/// or an Apply grant. Product wording is separate from its immutable source fact.
public struct SharedTrackingActionSource: Decodable, Equatable, Sendable {
    public let productName: String
    public let fact: SharedTrackingFact
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["id", "revision", "source", "sourceLabel", "productName", "originalText", "originalQuantityText", "quantity", "sourceExclusions", "requiredLineId"])
        guard case .object(var wire) = try JSONValue(from: decoder), case .string(let name) = wire.removeValue(forKey: "productName") else { throw ClientError.invalidResponse }
        productName = name
        fact = try JSONDecoder().decode(SharedTrackingFact.self, from: encoded(JSONValue.object(wire)))
        try demandRequire(demandText(productName) && fact.source.identityKey != nil)
        if case .request(_, let revision) = fact.source { try demandRequire(fact.revision == revision) }
    }
}
public struct SharedTrackingActionSources: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let base: SharedTrackingActionSourceBase
    public let normalizedAction: SharedTrackingAction
    /// Database canonical digest, deliberately distinct from tracking digest.
    public let actionDigest: SharedTrackingQuoteDigest
    public let sources: [SharedTrackingActionSource]
    private enum K: String, CodingKey { case schemaVersion, shopId, base, normalizedAction, actionDigest, sources }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "shopId", "base", "normalizedAction", "actionDigest", "sources"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        base = try c.decode(SharedTrackingActionSourceBase.self, forKey: .base)
        normalizedAction = try c.decode(SharedTrackingAction.self, forKey: .normalizedAction)
        actionDigest = try c.decode(SharedTrackingQuoteDigest.self, forKey: .actionDigest)
        sources = try c.decode([SharedTrackingActionSource].self, forKey: .sources)
        let identities = sources.compactMap { $0.fact.source.identityKey }
        try demandRequire(schemaVersion == 2 && sources.count <= 2000 && demandUnique(sources.map { $0.fact.id }) && identities.count == sources.count && demandUnique(identities))
    }
    public func validate(page: SharedTrackingPage, action: SharedDemandAction, requestPreview: ShopperPreview? = nil) throws {
        let request = try SharedTrackingActionSourceRequest(page: page, action: action, requestPreview: requestPreview)
        try demandRequire(shopId == page.shopId && base == request.base && normalizedAction == request.action)
        if case .request(let body) = normalizedAction.command {
            let facts = sources.map(\.fact).filter { if case .request(let id, _) = $0.source { return id == body.requestId }; return false }
            guard facts.count == 1, let preview = requestPreview, case .request(_, let revision) = facts[0].source else { throw ClientError.invalidResponse }
            try demandRequire(revision == preview.requestRevision && facts[0].revision == preview.requestRevision && facts[0].requiredLineId != nil)
        }
    }
}

extension HouseholdService {
    public func sharedTrackingActionSources(page: SharedTrackingPage, action: SharedDemandAction, requestPreview: ShopperPreview? = nil) async throws -> SharedTrackingActionSources {
        let start = generation, context = try sharedDemandContext(shopID: page.shopId.uuid)
        _ = try SharedTrackingReadBinding(page: page, context: context)
        let request = try SharedTrackingActionSourceRequest(page: page, action: action, requestPreview: requestPreview)
        func current() throws {
            guard generation == start, try sharedDemandContext(shopID: page.shopId.uuid) == context else { throw ClientError.cancelled }
            if let requestPreview { try demandRequire(demandTime(requestPreview.expiresAt).map { $0 > Date() } == true) }
        }
        try current(); try await authorizeShopper(shopID: page.shopId.string); try current()
        let bytes = try encoded(request); try demandRequire(bytes.count <= SharedTrackingWire.maximumResponseBytes)
        let catalog: SharedTrackingActionSources = try await perform("shops/\(page.shopId.string)/demand/tracking/action-sources", method: "POST", body: bytes, maximumResponseBytes: SharedTrackingWire.maximumResponseBytes)
        try current(); try catalog.validate(page: page, action: action, requestPreview: requestPreview)
        return catalog
    }
}
