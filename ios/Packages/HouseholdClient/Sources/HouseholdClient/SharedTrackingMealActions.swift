import Foundation

/// Exact informational meal facts. Neither this catalog nor its opaque digest
/// grants Apply authority or turns a detached commitment into usable supply.
public struct SharedTrackingMealSourceBase: Codable, Equatable, Sendable {
    public let shopRevision, authorityEpoch, graphRevision: Int
    public let stateDigest: SharedTrackingDigest
    public init(page: SharedTrackingPage) throws {
        guard page.status == .enabled, let state = page.state, page.projection == nil, state.graph.revision > 0 else { throw ClientError.configuration }
        shopRevision = page.shopRevision; authorityEpoch = page.authorityEpoch; graphRevision = state.graph.revision; stateDigest = page.basisDigest
    }
    private enum K: String, CodingKey { case shopRevision, authorityEpoch, graphRevision, stateDigest }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["shopRevision", "authorityEpoch", "graphRevision", "stateDigest"])
        let c = try decoder.container(keyedBy: K.self)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision); authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        graphRevision = try c.decode(Int.self, forKey: .graphRevision); stateDigest = try c.decode(SharedTrackingDigest.self, forKey: .stateDigest)
        try demandRequire(demandRevision(shopRevision) && demandRevision(authorityEpoch) && demandRevision(graphRevision))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(shopRevision, forKey: .shopRevision); try c.encode(authorityEpoch, forKey: .authorityEpoch)
        try c.encode(graphRevision, forKey: .graphRevision); try c.encode(stateDigest.value, forKey: .stateDigest)
    }
}
public struct SharedTrackingMealSourceRequest: Encodable, Equatable, Sendable {
    public let base: SharedTrackingMealSourceBase
    public let action: SharedTrackingAction
    public init(page: SharedTrackingPage, action: SharedDemandAction) throws {
        base = try .init(page: page)
        guard case .patch(var patch) = action, var edit = patch.mealEdit,
              edit.proposalId == nil || edit.changeProposalId == nil else { throw ClientError.configuration }
        edit.meal = edit.meal.map(normalizedDemandMeal); patch.mealEdit = edit
        self.action = try .init(.patch(patch))
    }
}
public struct SharedTrackingMealChange: Decodable, Equatable, Sendable {
    public let occurrenceId: SharedDemandID
    public let before: SharedOperationUndoMeal.Fact?
    public let after: SharedOperationUndoMeal.Fact
    private enum K: String, CodingKey { case occurrenceId, before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["occurrenceId", "before", "after"])
        let c = try decoder.container(keyedBy: K.self)
        occurrenceId = try c.decode(SharedDemandID.self, forKey: .occurrenceId)
        before = try c.decode(SharedOperationUndoMeal.Fact?.self, forKey: .before)
        after = try c.decode(SharedOperationUndoMeal.Fact.self, forKey: .after)
        try demandRequire(after.revision.map { demandRevision($0) } == true)
        if let before { try demandRequire(before.revision.map { demandRevision($0) } == true && before.meal != nil) }
        else { try demandRequire(after.meal != nil) }
    }
    func validate(action: SharedTrackingAction, shopRevision: Int) throws {
        guard case .patch(let patch) = action.command, let edit = patch.mealEdit else { throw ClientError.invalidResponse }
        try demandRequire(occurrenceId == edit.occurrenceId && before?.revision == edit.baseMealRevision && after.revision == shopRevision + 1 && after.meal == edit.meal)
        if let revision = before?.revision { try demandRequire(revision <= shopRevision) }
    }
}
public struct SharedTrackingMealSource: Decodable, Equatable, Sendable {
    public enum Location: String, Decodable, Sendable { case tracked, transferred, unbound, new }
    public let before: SharedDemandContribution?
    public let proposed: SharedDemandLegacySource
    public let transition: SharedDemandActionSource.Transition
    public let factId: SharedDemandID
    public let revision: Int
    public let location: Location
    private enum K: String, CodingKey { case before, proposed, transition, factId, revision, location }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["before", "proposed", "transition", "factId", "revision", "location"])
        let c = try decoder.container(keyedBy: K.self)
        before = try trackingDecode(SharedDemandContribution?.self, from: c.superDecoder(forKey: .before), shape: .nullable(.contribution))
        let source = try c.superDecoder(forKey: .proposed)
        try TrackingWireShape.object(["id": .scalar, "source": .scalar, "sourceLabel": .scalar, "productName": .scalar,
            "originalText": .scalar, "originalQuantityText": .scalar, "quantity": .nullable(.quantity),
            "sourceExclusions": .array(.restriction), "requiredLineId": .scalar]).validate(source)
        proposed = try SharedDemandLegacySource(from: source)
        transition = try c.decode(SharedDemandActionSource.Transition.self, forKey: .transition)
        factId = try c.decode(SharedDemandID.self, forKey: .factId); revision = try c.decode(Int.self, forKey: .revision)
        location = try c.decode(Location.self, forKey: .location)
        try demandRequire(demandRevision(revision, zero: true))
        switch proposed.source { case .meal, .reservation: break; default: throw ClientError.invalidResponse }
        try proposed.quantity?.validate()
        let tags = proposed.sourceExclusions.flatMap { item -> [String] in if case .mapped(let values, _) = item.resolution { return values }; return [] }
        try SharedDemandContribution(id: proposed.id, lineId: proposed.requiredLineId ?? proposed.id, source: proposed.source, productKey: nil,
            productName: proposed.productName, originalText: proposed.originalText, quantity: proposed.quantity, sourceExclusions: proposed.sourceExclusions,
            exclusions: Array(Set(tags)).sorted(), contains: []).validate()
        try demandRequire(demandText(proposed.sourceLabel) && demandText(proposed.productName) && demandText(proposed.originalText) && (proposed.originalQuantityText.map { demandText($0) } ?? true))
        try demandRequire((location == .tracked || location == .transferred) == (before != nil))
        if before == nil { try demandRequire(transition == .new) }
    }
}
public struct SharedTrackingTransferredRetirement: Decodable, Equatable, Sendable {
    public let factId, contributionId: SharedDemandID
    private enum K: String, CodingKey { case factId, contributionId }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["factId", "contributionId"]); let c = try decoder.container(keyedBy: K.self)
        factId = try c.decode(SharedDemandID.self, forKey: .factId); contributionId = try c.decode(SharedDemandID.self, forKey: .contributionId)
    }
}
public struct SharedTrackingMealSources: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let base: SharedTrackingMealSourceBase
    public let normalizedAction: SharedTrackingAction
    public let actionDigest: SharedTrackingQuoteDigest
    public let mealChange: SharedTrackingMealChange
    public let sources: [SharedTrackingMealSource]
    public let retirementCandidates: [SharedDemandID]
    public let transferredRetirementCandidates: [SharedTrackingTransferredRetirement]
    public let retiredUnboundFactIds, retainedContributionIds: [SharedDemandID]
    public let proposedCatalog: [SharedTrackingFact]
    public let beforeCoverage: SharedTrackingCoverage
    private enum K: String, CodingKey { case schemaVersion, shopId, base, normalizedAction, actionDigest, mealChange, sources, retirementCandidates, transferredRetirementCandidates, retiredUnboundFactIds, retainedContributionIds, proposedCatalog, beforeCoverage }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "shopId", "base", "normalizedAction", "actionDigest", "mealChange", "sources", "retirementCandidates", "transferredRetirementCandidates", "retiredUnboundFactIds", "retainedContributionIds", "proposedCatalog", "beforeCoverage"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        base = try c.decode(SharedTrackingMealSourceBase.self, forKey: .base); normalizedAction = try c.decode(SharedTrackingAction.self, forKey: .normalizedAction)
        actionDigest = try c.decode(SharedTrackingQuoteDigest.self, forKey: .actionDigest); mealChange = try c.decode(SharedTrackingMealChange.self, forKey: .mealChange)
        sources = try c.decode([SharedTrackingMealSource].self, forKey: .sources); retirementCandidates = try c.decode([SharedDemandID].self, forKey: .retirementCandidates)
        transferredRetirementCandidates = try c.decode([SharedTrackingTransferredRetirement].self, forKey: .transferredRetirementCandidates)
        retiredUnboundFactIds = try c.decode([SharedDemandID].self, forKey: .retiredUnboundFactIds); retainedContributionIds = try c.decode([SharedDemandID].self, forKey: .retainedContributionIds)
        proposedCatalog = try c.decode([SharedTrackingFact].self, forKey: .proposedCatalog); beforeCoverage = try c.decode(SharedTrackingCoverage.self, forKey: .beforeCoverage)
        try demandRequire(schemaVersion == 2 && sources.count <= 2000 && retirementCandidates.count <= 2000 && transferredRetirementCandidates.count <= 2000 && retiredUnboundFactIds.count <= 2000 && retainedContributionIds.count <= 2000 && proposedCatalog.count <= 2000)
        try demandRequire(demandUnique(sources.map(\.factId)) && demandUnique(sources.map { $0.proposed.id }) && demandUnique(retirementCandidates) && demandUnique(retainedContributionIds) && demandUnique(retiredUnboundFactIds) && demandUnique(proposedCatalog.map(\.id)))
        try demandRequire(demandUnique(transferredRetirementCandidates.map(\.factId)) && demandUnique(transferredRetirementCandidates.map(\.contributionId)))
        try mealChange.validate(action: normalizedAction, shopRevision: base.shopRevision)
    }
    public func validate(page: SharedTrackingPage, action: SharedDemandAction) throws {
        let request = try SharedTrackingMealSourceRequest(page: page, action: action)
        guard let state = page.state else { throw ClientError.invalidResponse }
        try demandRequire(shopId == page.shopId && base == request.base && normalizedAction == request.action && beforeCoverage == page.coverage)
        let facts = Dictionary(uniqueKeysWithValues: proposedCatalog.map { ($0.id, $0) })
        var matched = Set<SharedDemandID>(), detached = Set<SharedDemandID>()
        for row in sources {
            guard let fact = facts[row.factId] else { throw ClientError.invalidResponse }
            let proposed = row.proposed
            try demandRequire(row.revision == fact.revision && proposed.source == fact.source && proposed.originalText == fact.originalText && proposed.originalQuantityText == fact.originalQuantityText)
            try demandRequire(proposed.quantity?.amount == fact.quantity?.amount && proposed.quantity?.unit == fact.quantity?.unit && proposed.quantity?.originalLiteral == fact.quantity?.originalLiteral)
            try trackingRestrictionOrigins(proposed.sourceExclusions, fact.sourceExclusions)
            if let conversion = fact.quantity?.confirmedConversion { try demandRequire(proposed.quantity?.confirmedConversion == conversion) }
            if let old = row.before {
                try demandRequire(old.id == proposed.id && old.removedAt == nil && proposed.requiredLineId == old.lineId && proposed.originalText == old.originalText)
                let quantified = row.transition == .quantifyReservation && old.source.isReservation && old.quantity == nil && proposed.quantity != nil && (proposed.source == old.source || proposed.source.isQuantification(of: old.source))
                try demandRequire(proposed.source == old.source || quantified)
                switch row.transition {
                case .new: throw ClientError.invalidResponse
                case .retain: try demandRequire(proposed.source == old.source && proposed.quantity == old.quantity && proposed.productName == old.productName && proposed.sourceExclusions == (old.sourceExclusions ?? []))
                case .update: try demandRequire(proposed.source == old.source)
                case .quantifyReservation: try demandRequire(quantified)
                }
                if row.location == .tracked {
                    try demandRequire(state.graph.contributions.contains(old) && state.bindings.contains { $0.factId == row.factId && $0.contributionId == old.id })
                    matched.insert(old.id)
                } else {
                    try demandRequire(row.location == .transferred && state.unbound.contains { $0.factId == row.factId && $0.transferred == old })
                    detached.insert(row.factId)
                }
            } else {
                try demandRequire(!state.graph.usedIds.contains(proposed.id))
                if row.location == .unbound {
                    guard let old = state.catalog.first(where: { $0.id == row.factId }) else { throw ClientError.invalidResponse }
                    try demandRequire(state.unbound.contains { $0.factId == row.factId && $0.transferred == nil } && proposed.originalText == old.originalText)
                    try demandRequire(proposed.source == old.source || (old.quantity == nil && proposed.quantity != nil && proposed.source.isQuantification(of: old.source)))
                } else { try demandRequire(row.location == .new && !state.catalog.contains { $0.id == row.factId }) }
            }
        }
        let retiring = Set(retirementCandidates), retained = Set(retainedContributionIds)
        try demandRequire(matched.isDisjoint(with: retiring) && matched.isDisjoint(with: retained) && retiring.isDisjoint(with: retained))
        try demandRequire(matched.union(retiring).union(retained) == Set(state.graph.contributions.map(\.id)))
        for id in retirementCandidates {
            guard let row = state.graph.contributions.first(where: { $0.id == id && $0.removedAt == nil }), case .meal = row.source else { throw ClientError.invalidResponse }
        }
        for row in state.graph.contributions where retained.contains(row.id) && row.removedAt == nil {
            switch row.source { case .meal, .reservation: throw ClientError.invalidResponse; default: break }
        }
        for retirement in transferredRetirementCandidates {
            guard let row = state.unbound.first(where: { $0.factId == retirement.factId })?.transferred,
                  case .meal = row.source else { throw ClientError.invalidResponse }
            try demandRequire(row.id == retirement.contributionId && !detached.contains(retirement.factId) && facts[retirement.factId] == nil)
        }
        for id in retiredUnboundFactIds {
            guard let fact = state.catalog.first(where: { $0.id == id }), case .meal = fact.source else { throw ClientError.invalidResponse }
            try demandRequire(state.unbound.contains { $0.factId == id && $0.transferred == nil } && facts[id] == nil)
        }
        let allMealFacts = Set(proposedCatalog.filter { trackingMealSource($0.source) }.map(\.id))
        try demandRequire(allMealFacts == Set(sources.map(\.factId)))
        let transferredMealFacts = Set(state.unbound.filter { $0.transferred.map { trackingMealSource($0.source) } == true }.map(\.factId))
        try demandRequire(detached.union(transferredRetirementCandidates.map(\.factId)) == transferredMealFacts)
        let survivingPlainMealFacts = Set(state.unbound.filter { entry in
            entry.transferred == nil && state.catalog.contains { $0.id == entry.factId && trackingMealSource($0.source) }
        }.map(\.factId))
        try demandRequire(Set(sources.filter { $0.location == .unbound }.map(\.factId)).union(retiredUnboundFactIds) == survivingPlainMealFacts)
        func affected(_ source: SharedDemandSource) -> Bool {
            switch source {
            case .meal(let id, _, _, _): id == mealChange.occurrenceId
            case .reservation(_, _, let id, _, _, _): id == mealChange.occurrenceId
            default: false
            }
        }
        let untouched = state.catalog.filter { !affected($0.source) }
        try demandRequire(untouched == proposedCatalog.filter { !affected($0.source) })
    }
}
func trackingMealSource(_ source: SharedDemandSource) -> Bool {
    switch source { case .meal, .reservation: true; default: false }
}

extension HouseholdService {
    public func sharedTrackingMealActionSources(page: SharedTrackingPage, action: SharedDemandAction) async throws -> SharedTrackingMealSources {
        let start = generation, context = try sharedDemandContext(shopID: page.shopId.uuid)
        _ = try SharedTrackingReadBinding(page: page, context: context)
        let request = try SharedTrackingMealSourceRequest(page: page, action: action)
        func current() throws { guard generation == start, try sharedDemandContext(shopID: page.shopId.uuid) == context else { throw ClientError.cancelled } }
        try current(); try await authorizeShopper(shopID: page.shopId.string); try current()
        let bytes = try encoded(request); try demandRequire(bytes.count <= SharedTrackingWire.maximumResponseBytes)
        let result: SharedTrackingMealSources = try await perform("shops/\(page.shopId.string)/demand/tracking/meal-action-sources", method: "POST", body: bytes, maximumResponseBytes: SharedTrackingWire.maximumResponseBytes)
        try current(); try result.validate(page: page, action: action); return result
    }
}

func trackingRestrictionOrigins(_ reviewed: [SharedDemandSourceExclusion], _ authoritative: [SharedDemandSourceExclusion]) throws {
    try demandRequire(reviewed.count == authoritative.count)
    for (a, b) in zip(reviewed, authoritative) {
        try demandRequire(a.occurrenceId == b.occurrenceId && a.ingredientId == b.ingredientId && a.label == b.label)
    }
}
