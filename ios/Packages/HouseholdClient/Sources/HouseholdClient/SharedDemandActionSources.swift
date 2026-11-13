import Foundation

/// Informational facts for one exact meal action. This is never an Apply token.
public struct SharedDemandActionSourceBase: Codable, Equatable, Sendable {
    public let shopRevision, authorityEpoch, graphRevision: Int
    public let graphDigest: String
    public init(page: SharedDemandPage) throws {
        guard page.status == .enabled, let graph = page.graph, let digest = page.graphDigest else { throw ClientError.configuration }
        shopRevision = page.shopRevision; authorityEpoch = page.authorityEpoch; graphRevision = graph.revision; graphDigest = digest
        try validate()
    }
    func validate() throws {
        try demandRequire(demandRevision(shopRevision) && demandRevision(authorityEpoch) && demandRevision(graphRevision))
        try demandRequire(graphDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }
}
public struct SharedDemandActionSourceRequest: Codable, Equatable, Sendable {
    public let base: SharedDemandActionSourceBase
    public let action: SharedDemandAction
    public init(page: SharedDemandPage, patch: SharedDemandShopPatch) throws {
        var canonical = patch
        if var edit = canonical.mealEdit {
            edit.meal = edit.meal.map(normalizedDemandMeal)
            canonical.mealEdit = edit
        }
        base = try .init(page: page); action = .patch(canonical); try validate()
    }
    public func validate() throws {
        try base.validate()
        guard case .patch(let patch) = action, let edit = patch.mealEdit, edit.proposalId == nil || edit.changeProposalId == nil else { throw ClientError.configuration }
        // Reuse the ordinary action/body validator; no allocation reducer here.
        try SharedDemandPreviewRequest(mode: .review, base: .init(shopRevision: base.shopRevision, authorityEpoch: base.authorityEpoch, graphRevision: base.graphRevision), change: .init(), action: action, packs: []).validate()
    }
}
public struct SharedDemandActionSource: Codable, Equatable, Sendable {
    public enum Transition: String, Codable, Sendable { case retain, update, new, quantifyReservation }
    @SharedDemandNullable public var before: SharedDemandContribution?
    public let proposed: SharedDemandLegacySource
    public let transition: Transition
}
public struct SharedDemandActionSources: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let base: SharedDemandActionSourceBase
    public let graphDigest, actionDigest: String
    public let normalizedAction: SharedDemandAction
    public let sources: [SharedDemandActionSource]
    public let retirementCandidates, retainedContributionIds: [SharedDemandID]
    public func validate(page: SharedDemandPage, request: SharedDemandActionSourceRequest) throws {
        try request.validate()
        let expectedBase = try SharedDemandActionSourceBase(page: page)
        try demandRequire(schemaVersion == 1 && page.status == .enabled && shopId == page.shopId && base == request.base && base == expectedBase)
        try demandRequire(graphDigest == base.graphDigest && actionDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && normalizedAction == request.action)
        guard let graph = page.graph else { throw ClientError.invalidResponse }
        try demandRequire(sources.count <= 2000 && retirementCandidates.count <= 2000 && retainedContributionIds.count <= 2000)
        try demandRequire(demandUnique(sources.map { $0.proposed.id }) && demandUnique(retirementCandidates) && demandUnique(retainedContributionIds))
        try demandIDs(retirementCandidates.map(Optional.some) + retainedContributionIds.map(Optional.some))
        let identities = sources.compactMap { $0.proposed.source.identityKey }
        try demandRequire(identities.count == sources.count && demandUnique(identities))
        var matched = Set<SharedDemandID>()
        for row in sources {
            let fact = row.proposed
            switch fact.source { case .meal, .reservation: break; default: throw ClientError.invalidResponse }
            try demandRequire(demandText(fact.sourceLabel) && demandText(fact.productName) && demandText(fact.originalText) && (fact.originalQuantityText.map { demandText($0) } ?? true))
            let mapped = fact.sourceExclusions.flatMap { item -> [String] in if case .mapped(let tags, _) = item.resolution { return tags }; return [] }
            try SharedDemandContribution(id: fact.id, lineId: fact.requiredLineId ?? fact.id, source: fact.source, productKey: nil, productName: fact.productName, originalText: fact.originalText, quantity: fact.quantity, sourceExclusions: fact.sourceExclusions, exclusions: Array(Set(mapped)).sorted()).validate()
            if let old = row.before {
                try demandRequire(graph.contributions.contains(old) && old.removedAt == nil && old.id == fact.id && fact.requiredLineId == old.lineId && fact.originalText == old.originalText)
                let quantified = row.transition == .quantifyReservation && old.source.isReservation && old.quantity == nil && fact.quantity != nil && (fact.source == old.source || fact.source.isQuantification(of: old.source))
                try demandRequire(fact.source == old.source || quantified)
                switch row.transition {
                case .new: throw ClientError.invalidResponse
                case .retain: try demandRequire(fact.source == old.source && fact.quantity == old.quantity && fact.productName == old.productName && fact.sourceExclusions == (old.sourceExclusions ?? []))
                case .quantifyReservation: try demandRequire(quantified)
                case .update: try demandRequire(fact.source == old.source)
                }
                matched.insert(old.id)
            } else {
                try demandRequire(row.transition == .new && fact.requiredLineId == nil && !graph.usedIds.contains(fact.id))
            }
        }
        let retiring = Set(retirementCandidates), retained = Set(retainedContributionIds)
        try demandRequire(matched.isDisjoint(with: retiring) && matched.isDisjoint(with: retained) && retiring.isDisjoint(with: retained))
        try demandRequire(matched.union(retiring).union(retained) == Set(graph.contributions.map(\.id)))
        for id in retirementCandidates {
            guard let old = graph.contributions.first(where: { $0.id == id && $0.removedAt == nil }), case .meal = old.source else { throw ClientError.invalidResponse }
        }
        // Every active meal/protected source must be accounted for by the action,
        // never hidden in the unrelated-retained partition.
        for old in graph.contributions where retained.contains(old.id) && old.removedAt == nil {
            switch old.source { case .meal, .reservation: throw ClientError.invalidResponse; default: break }
        }
    }
}

/// Matches only sharedMealSchema's string.trim() fields. Do not reduce rationals,
/// rewrite quantity wording internally, or alter identity, schedule or authority.
func normalizedDemandMeal(_ original: SharedMeal) -> SharedMeal {
    // ECMAScript WhiteSpace + LineTerminator, including BOM but excluding NEL.
    let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    func trim(_ value: String) -> String { value.trimmingCharacters(in: whitespace) }
    func quantity(_ value: SharedMealQuantity) -> SharedMealQuantity {
        var result = value; result.originalLiteral = trim(value.originalLiteral); return result
    }
    var result = original; result.title = trim(original.title)
    if var planning = result.planning {
        planning.groups = planning.groups.map { var group = $0; group.name = trim(group.name); return group }
        planning.ingredients = planning.ingredients.map {
            var ingredient = $0; ingredient.name = trim(ingredient.name)
            ingredient.quantity = ingredient.quantity.map(quantity)
            ingredient.exclusions = ingredient.exclusions.map(trim); return ingredient
        }
        planning.bindings = planning.bindings.map { $0.map { var binding = $0; binding.quantity = quantity(binding.quantity); return binding } }
        planning.exclusions = planning.exclusions.map { $0.map(trim) }
        planning.completedSteps = planning.completedSteps.map { $0.map(trim) }
        result.planning = planning
    }
    return result
}
