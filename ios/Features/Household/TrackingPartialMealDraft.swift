import Foundation
import HouseholdClient

/// Meal facts keep their catalog identity even when their graph contribution
/// has a different ID. Detached commitments are never graph supply.
struct TrackingPartialMealSourceEntry: Identifiable, Equatable {
    let source: SharedTrackingMealSource
    var id: SharedDemandID { source.factId }
    let quantifiesUnboundReservation: Bool
    init(source: SharedTrackingMealSource, quantifiesUnboundReservation: Bool = false) {
        self.source = source; self.quantifiesUnboundReservation = quantifiesUnboundReservation
    }
    var confirmed = false
    var quantificationConfirmed = false
    var lineID: SharedDemandID?
    var productConfirmed = false
    var conversion = TrackingFixedConversionEntry()
    var canBind: Bool { source.location == .new || source.location == .unbound }
    var needsConfirmation: Bool { source.before != nil && source.transition != .retain }
    var canReviewFreshConversion: Bool {
        needsConfirmation && source.proposed.quantity != nil && source.proposed.quantity?.confirmedConversion == nil
    }
    var needsQuantificationConfirmation: Bool { source.transition == .quantifyReservation || quantifiesUnboundReservation }
}
struct TrackingPartialMealRetirementEntry: Identifiable, Equatable {
    let factID: SharedDemandID?
    let source: SharedDemandContribution
    var id: SharedDemandID { source.id }
    var confirmed = false
}
struct TrackingPartialMealEdgeRemovalEntry: Identifiable, Equatable {
    let edge: SharedDemandEdge
    let required: Bool
    var id: SharedDemandID { edge.id }
    var remove: Bool
    var confirmed = false
}
struct TrackingPartialMealDelta {
    let change: SharedDemandChange
    let unboundFactIDs: [SharedDemandID]
}

struct TrackingPartialMealDraft: Equatable {
    let catalog: SharedTrackingMealSources
    var reviewed = false
    var rows: [TrackingPartialMealSourceEntry]
    var retirements: [TrackingPartialMealRetirementEntry]
    var edgeRemovals: [TrackingPartialMealEdgeRemovalEntry]

    init(page: SharedTrackingPage, catalog: SharedTrackingMealSources) throws {
        try catalog.validate(page: page, action: catalog.normalizedAction.command)
        guard let state = page.state else { throw ClientError.invalidResponse }
        self.catalog = catalog
        rows = catalog.sources.map { row in
            let old = state.catalog.first { $0.id == row.factId }
            let quantifies: Bool
            if let old, case .reservation = old.source { quantifies = old.quantity == nil && row.proposed.quantity != nil }
            else { quantifies = false }
            return .init(source: row, quantifiesUnboundReservation: row.before == nil && quantifies)
        }
        retirements = try catalog.retirementCandidates.map { id in
            guard let source = state.graph.contributions.first(where: { $0.id == id }) else { throw ClientError.invalidResponse }
            return .init(factID: nil, source: source)
        } + catalog.transferredRetirementCandidates.map { item in
            guard let source = state.unbound.first(where: { $0.factId == item.factId })?.transferred else { throw ClientError.invalidResponse }
            return .init(factID: item.factId, source: source)
        }
        let retired = Set(catalog.retirementCandidates)
        let changed = Set(catalog.sources.filter { $0.location == .tracked && $0.transition != .retain }.map { $0.proposed.id }).union(retired)
        edgeRemovals = state.graph.edges.filter { changed.contains($0.demandId) || changed.contains($0.supplyId) }.map { edge in
            let required = retired.contains(edge.demandId) || retired.contains(edge.supplyId)
            return .init(edge: edge, required: required, remove: required)
        }
    }

    private func validate(page: SharedTrackingPage) throws {
        let expected = try Self(page: page, catalog: catalog)
        guard reviewed, rows.map(\.source) == expected.rows.map(\.source),
              rows.map(\.quantifiesUnboundReservation) == expected.rows.map(\.quantifiesUnboundReservation),
              retirements.map(\.source) == expected.retirements.map(\.source),
              retirements.map(\.factID) == expected.retirements.map(\.factID),
              edgeRemovals.map(\.edge) == expected.edgeRemovals.map(\.edge),
              edgeRemovals.map(\.required) == expected.edgeRemovals.map(\.required),
              retirements.allSatisfy(\.confirmed),
              edgeRemovals.allSatisfy({ (!$0.required || $0.remove) && (!$0.remove || $0.confirmed) }) else { throw ClientError.configuration }
        for row in rows {
            guard !row.needsConfirmation || row.confirmed,
                  !row.needsQuantificationConfirmation || row.quantificationConfirmed else { throw ClientError.configuration }
            if !row.canBind {
                guard row.lineID == nil, !row.productConfirmed, !row.conversion.enabled || row.canReviewFreshConversion else { throw ClientError.configuration }
            } else if row.lineID == nil {
                guard !row.productConfirmed, !row.conversion.enabled else { throw ClientError.configuration }
            }
        }
    }

    /// Uses the server's reviewed quantity/conversion/restrictions and retains
    /// the user's existing product identity, contains tags and extra exclusions.
    private func updated(_ row: TrackingPartialMealSourceEntry, page: SharedTrackingPage) throws -> SharedDemandContribution {
        guard var value = row.source.before else { throw ClientError.configuration }
        let proposed = row.source.proposed
        value.source = proposed.source; value.productName = proposed.productName
        value.originalText = proposed.originalText
        if row.conversion.enabled {
            guard row.canReviewFreshConversion else { throw ClientError.configuration }
            // Evidence must bridge a relevant existing unit, never an unrelated
            // dimension. Protected detached rows also need to compare against
            // their previous quantity even though they have no allocation.
            var targetUnits = page.state?.graph.lines.first { $0.id == value.lineId }.map { [$0.unit] } ?? []
            if case .reservation = value.source, let oldQuantity = row.source.before?.quantity { targetUnits.append(oldQuantity.unit) }
            if !targetUnits.isEmpty {
                guard targetUnits.contains(where: { TrackingFixedConversionEntry.dimension($0) == TrackingFixedConversionEntry.dimension(row.conversion.target) }) else { throw ClientError.configuration }
            }
        }
        value.quantity = try row.conversion.apply(to: proposed.quantity)
        value.sourceExclusions = proposed.sourceExclusions.isEmpty && value.sourceExclusions == nil ? nil : proposed.sourceExclusions
        value.exclusions = Array(Set(value.exclusions + Self.mappedTags(proposed.sourceExclusions))).sorted()
        try value.validate()
        return value
    }

    func transferredChanges(page: SharedTrackingPage) throws -> [SharedTrackingTransferredChange]? {
        try validate(page: page)
        var result = try rows.filter { $0.source.location == .transferred && $0.needsConfirmation }.map {
            SharedTrackingTransferredChange(factId: $0.id, after: try updated($0, page: page))
        }
        result += retirements.compactMap { row in row.factID.map { .init(factId: $0, after: nil) } }
        return result.isEmpty ? nil : result
    }

    func delta(page: SharedTrackingPage, action: SharedDemandAction, packs: [TrackingPackEntry], basket: [ShopperBasketLine]) throws -> TrackingPartialMealDelta {
        try validate(page: page)
        try catalog.validate(page: page, action: action)
        guard let state = page.state else { throw ClientError.invalidResponse }
        var additions: [SharedDemandContribution] = []
        for row in rows {
            if row.source.location == .tracked && row.needsConfirmation { additions.append(try updated(row, page: page)) }
            guard row.canBind, let lineID = row.lineID else { continue }
            let proposed = row.source.proposed
            guard row.productConfirmed, basket.contains(where: { $0.lineId == lineID.string }),
                  proposed.requiredLineId == nil || proposed.requiredLineId == lineID else { throw ClientError.configuration }
            let active = state.graph.contributions.filter { $0.lineId == lineID && $0.removedAt == nil && !catalog.retirementCandidates.contains($0.id) }
            guard active.allSatisfy({ $0.productKey != nil }) || packs.first(where: { $0.id == lineID })?.confirmExistingSources == true else { throw ClientError.configuration }
            additions.append(.init(id: proposed.id, lineId: lineID, source: proposed.source,
                productKey: active.compactMap(\.productKey).first ?? "food.\(lineID.string)",
                productName: proposed.productName, originalText: proposed.originalText,
                quantity: try row.conversion.apply(to: proposed.quantity),
                sourceExclusions: proposed.sourceExclusions.isEmpty ? nil : proposed.sourceExclusions,
                exclusions: Self.mappedTags(proposed.sourceExclusions), contains: []))
        }
        let bound = Set(state.bindings.map(\.factId)).union(rows.filter { $0.canBind && $0.lineID != nil }.map(\.id))
        let quantify = rows.filter { $0.source.before != nil && $0.needsQuantificationConfirmation }.map { $0.source.proposed.id }
        let change = SharedDemandChange(contributions: additions,
            removeSourceIds: catalog.retirementCandidates,
            removeEdgeIds: edgeRemovals.filter(\.remove).map(\.id),
            quantifyReservationIds: quantify.isEmpty ? nil : quantify)
        return .init(change: change, unboundFactIDs: catalog.proposedCatalog.filter { !bound.contains($0.id) }.map(\.id))
    }
    private static func mappedTags(_ restrictions: [SharedDemandSourceExclusion]) -> [String] {
        Array(Set(restrictions.flatMap { item -> [String] in
            if case .mapped(let tags, _) = item.resolution { return tags }; return []
        })).sorted()
    }
}
