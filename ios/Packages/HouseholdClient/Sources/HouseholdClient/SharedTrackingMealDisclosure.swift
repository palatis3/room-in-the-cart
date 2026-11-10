import Foundation

/// Explicit detached-row intent. The server validates source authority and
/// conservation; this type does not place the row in the allocation graph.
public struct SharedTrackingTransferredChange: Encodable, Equatable, Sendable {
    public let factId: SharedDemandID
    public let after: SharedDemandContribution?
    public init(factId: SharedDemandID, after: SharedDemandContribution?) { self.factId = factId; self.after = after }
    private enum K: String, CodingKey { case factId, after }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self); try c.encode(factId, forKey: .factId); try c.encode(after, forKey: .after)
    }
}
public struct SharedTrackingTransferredDelta: Decodable, Equatable, Sendable {
    public let factId: SharedDemandID
    public let before: SharedDemandContribution
    public let after: SharedDemandContribution?
    private enum K: String, CodingKey { case factId, before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["factId", "before", "after"]); let c = try decoder.container(keyedBy: K.self)
        factId = try c.decode(SharedDemandID.self, forKey: .factId)
        before = try trackingDecode(SharedDemandContribution.self, from: c.superDecoder(forKey: .before), shape: .contribution)
        after = try trackingDecode(SharedDemandContribution?.self, from: c.superDecoder(forKey: .after), shape: .nullable(.contribution))
        try before.validate(); try after?.validate()
        try demandRequire(before.removedAt == nil && before != after)
        if let after { try demandRequire(after.id == before.id && after.lineId == before.lineId && after.removedAt == nil) }
    }
}
public struct SharedTrackingMealActionDisclosure: Decodable, Equatable, Sendable {
    public let mealChange: SharedTrackingMealChange
    public let transferredChanges: [SharedTrackingTransferredDelta]
    private enum K: String, CodingKey { case kind, mealChange, transferredChanges }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["kind", "mealChange", "transferredChanges"]); let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind); try demandRequire(kind == "mealActionChange")
        mealChange = try c.decode(SharedTrackingMealChange.self, forKey: .mealChange)
        transferredChanges = try c.decode([SharedTrackingTransferredDelta].self, forKey: .transferredChanges)
        try demandRequire(transferredChanges.count <= 2000 && demandUnique(transferredChanges.map(\.factId)))
    }
    func validate(intent: SharedTrackingIntent, page: SharedTrackingPage, candidate: SharedTrackingCandidate) throws {
        try mealChange.validate(action: candidate.action, shopRevision: page.shopRevision)
        if let catalog = intent.mealSources { try demandRequire(mealChange == catalog.mealChange) }
        let changes = intent.transferredChanges ?? []
        try demandRequire(transferredChanges.map(\.factId) == changes.map(\.factId))
        for (delta, input) in zip(transferredChanges, changes) {
            try demandRequire(page.state?.unbound.first { $0.factId == delta.factId }?.transferred == delta.before && input.after == delta.after)
            let result = candidate.after.unbound.first { $0.factId == delta.factId }
            if let after = delta.after { try demandRequire(result?.transferred == after) }
            else { try demandRequire(result == nil && !candidate.after.catalog.contains { $0.id == delta.factId }) }
            try demandRequire(candidate.after.graph.usedIds.contains(delta.before.id) && !candidate.after.graph.contributions.contains { $0.id == delta.before.id })
        }
    }
}
public struct SharedTrackingUnboundDelta: Decodable, Equatable, Sendable {
    public let factId: SharedDemandID
    public let before, after: SharedTrackingUnboundFact?
    private enum K: String, CodingKey { case factId, before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["factId", "before", "after"]); let c = try decoder.container(keyedBy: K.self)
        factId = try c.decode(SharedDemandID.self, forKey: .factId)
        before = try c.decode(SharedTrackingUnboundFact?.self, forKey: .before); after = try c.decode(SharedTrackingUnboundFact?.self, forKey: .after)
        try demandRequire(before != after && (before.map { $0.factId == factId } ?? true) && (after.map { $0.factId == factId } ?? true))
    }
}
public struct SharedTrackingMealUndoDisclosure: Decodable, Equatable, Sendable {
    public let targetOperationId: SharedDemandID
    public let mealUndo: SharedOperationUndoMeal
    public let transferredChanges: [SharedTrackingUnboundDelta]
    public let touchedBasket: [SharedOperationUndoTouchedLine]
    public let quote: SharedTrackingUndoQuotes
    public let graphRows: Int
    public let beforeCoverage, afterCoverage: SharedTrackingCoverage
    private enum K: String, CodingKey { case kind, targetOperationId, mealUndo, transferredChanges, touchedBasket, quote, graphRows, beforeCoverage, afterCoverage }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["kind", "targetOperationId", "mealUndo", "transferredChanges", "touchedBasket", "quote", "graphRows", "beforeCoverage", "afterCoverage"])
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind); try demandRequire(kind == "mealOperationUndo")
        targetOperationId = try c.decode(SharedDemandID.self, forKey: .targetOperationId); mealUndo = try c.decode(SharedOperationUndoMeal.self, forKey: .mealUndo)
        transferredChanges = try c.decode([SharedTrackingUnboundDelta].self, forKey: .transferredChanges)
        touchedBasket = try c.decode([SharedOperationUndoTouchedLine].self, forKey: .touchedBasket)
        quote = try c.decode(SharedTrackingUndoQuotes.self, forKey: .quote); graphRows = try c.decode(Int.self, forKey: .graphRows)
        beforeCoverage = try c.decode(SharedTrackingCoverage.self, forKey: .beforeCoverage); afterCoverage = try c.decode(SharedTrackingCoverage.self, forKey: .afterCoverage)
        try demandRequire(graphRows >= 0 && graphRows <= 6200 && transferredChanges.count <= 4000 && demandUnique(transferredChanges.map(\.factId)) && touchedBasket.count <= 200 && demandUnique(touchedBasket.map(\.lineId)))
    }
    func validate(target: SharedDemandID, page: SharedTrackingPage, candidate: SharedTrackingCandidate) throws {
        guard let before = page.state, case .patch(let body) = candidate.action.command, let edit = body.mealEdit else { throw ClientError.invalidResponse }
        let after = candidate.after
        try demandRequire(targetOperationId == target && beforeCoverage == page.coverage && afterCoverage == candidate.disclosure.pickup.coverage && quote.after == body.quote)
        try mealUndo.validateCompound(edit: edit, shopRevision: page.shopRevision)
        func affected(_ source: SharedDemandSource) -> Bool {
            switch source {
            case .meal(let id, _, _, _): id == mealUndo.occurrenceId
            case .reservation(_, _, let id, _, _, _): id == mealUndo.occurrenceId
            default: false
            }
        }
        try demandRequire(before.catalog.filter { !affected($0.source) } == after.catalog.filter { !affected($0.source) })
        let changed = Set(before.unbound.map(\.factId) + after.unbound.map(\.factId)).filter { id in
            before.unbound.first { $0.factId == id } != after.unbound.first { $0.factId == id }
        }
        try demandRequire(Set(transferredChanges.map(\.factId)) == Set(changed))
        for delta in transferredChanges {
            guard let fact = before.catalog.first(where: { $0.id == delta.factId }) ?? after.catalog.first(where: { $0.id == delta.factId }) else { throw ClientError.invalidResponse }
            try demandRequire(affected(fact.source))
            try demandRequire(delta.before == before.unbound.first { $0.factId == delta.factId } && delta.after == after.unbound.first { $0.factId == delta.factId })
            if let row = delta.after?.transferred { try demandRequire(after.graph.usedIds.contains(row.id) && !after.graph.contributions.contains { $0.id == row.id }) }
        }
        try trackingValidateTouchedBasket(touchedBasket, before: before.basket, after: after.basket)
        let rows = demandDiff(before.graph.lines, after.graph.lines, { $0.id }).count + demandDiff(before.graph.contributions, after.graph.contributions, { $0.id }).count + demandDiff(before.graph.edges, after.graph.edges, { $0.id }).count
        try demandRequire(rows == graphRows)
    }
}
func trackingValidateTouchedBasket(_ touched: [SharedOperationUndoTouchedLine], before: [SharedTrackingBasketLine], after: [SharedTrackingBasketLine]) throws {
    var changed = Set<SharedDemandID>()
    for id in Set(before.map(\.id)).union(after.map(\.id)) {
        let old = before.first { $0.id == id }, next = after.first { $0.id == id }
        guard old != next else { continue }; changed.insert(id)
        guard let delta = touched.first(where: { $0.lineId == id }) else { throw ClientError.invalidResponse }
        var fields: [SharedOperationUndoTouchedLine.Field] = []
        if let old, let next {
            if old.name != next.name { fields.append(.originalItem) }; if old.packs != next.packs { fields.append(.packs) }
            if old.priceMinor != next.priceMinor { fields.append(.unitPriceMinor) }; if old.feeEligible != next.feeEligible { fields.append(.feeEligible) }
        } else { fields = [.membership] }
        try demandRequire(delta.fields == fields)
    }
    try demandRequire(Set(touched.map(\.lineId)) == changed)
}

extension SharedTrackingIntent {
    func validateMealChange(page: SharedTrackingPage, action: SharedDemandAction, change: SharedDemandChange) throws {
        guard case .patch(let body) = action, let edit = body.mealEdit else {
            try demandRequire(mealSources == nil && transferredChanges == nil); try change.validate(); return
        }
        guard let catalog = mealSources, let state = page.state else { throw ClientError.configuration }
        try catalog.validate(page: page, action: action)
        let detachedIDs = Set(state.unbound.compactMap { $0.transferred?.id })
        let quantify = change.quantifyReservationIds ?? [], clarify = change.clarifyReservationProductIds ?? []
        try demandRequire(quantify.count <= 2000 && clarify.count <= 2000 && demandUnique(quantify) && demandUnique(clarify) && Set(clarify).isDisjoint(with: quantify + change.removeSourceIds))
        try demandIDs((quantify + clarify).map(Optional.some))
        // Detached confirmations use the same explicit lists on the wire, but
        // cannot be passed to the graph-only validator as graph contributions.
        var graphChange = change
        graphChange.quantifyReservationIds = change.quantifyReservationIds.map { $0.filter { !detachedIDs.contains($0) } }
        graphChange.clarifyReservationProductIds = change.clarifyReservationProductIds.map { $0.filter { !detachedIDs.contains($0) } }
        try graphChange.validate()
        let changes = transferredChanges ?? []
        try demandRequire(changes.count <= 2000 && demandUnique(changes.map(\.factId)))
        var changedIDs = Set<SharedDemandID>()
        for input in changes {
            guard let old = state.unbound.first(where: { $0.factId == input.factId })?.transferred else { throw ClientError.configuration }
            let occurrence: SharedDemandID
            switch old.source {
            case .meal(let id, _, _, _): occurrence = id
            case .reservation(_, _, let id, _, _, _):
                guard let id else { throw ClientError.configuration }; occurrence = id
            default: throw ClientError.configuration
            }
            try demandRequire(occurrence == edit.occurrenceId && changedIDs.insert(old.id).inserted)
            try demandRequire(!change.contributions.contains { $0.id == old.id } && !change.removeSourceIds.contains(old.id) && !change.edges.contains { $0.demandId == old.id || $0.supplyId == old.id })
            if let after = input.after {
                try after.validate()
                guard let source = catalog.sources.first(where: { $0.factId == input.factId && $0.location == .transferred }), source.before == old else { throw ClientError.configuration }
                let proposed = source.proposed
                try demandRequire(after.id == old.id && after.lineId == old.lineId && after.removedAt == nil && after != old && after.originalText == old.originalText)
                try demandRequire(after.source == proposed.source && after.quantity?.amount == proposed.quantity?.amount && after.quantity?.unit == proposed.quantity?.unit && after.quantity?.originalLiteral == proposed.quantity?.originalLiteral)
                try trackingRestrictionOrigins(after.sourceExclusions ?? [], proposed.sourceExclusions)
                if let conversion = proposed.quantity?.confirmedConversion { try demandRequire(after.quantity?.confirmedConversion == conversion) }
                if old.source.isReservation {
                    try demandRequire(old.quantity == nil || after.quantity != nil)
                    if old.quantity == nil && after.quantity != nil { try demandRequire(quantify.contains(old.id)) }
                    if old.productKey != after.productKey { try demandRequire(old.productKey == nil && after.productKey != nil && clarify.contains(old.id)) }
                }
                if quantify.contains(old.id) { try demandRequire(old.source.isReservation && old.quantity == nil && after.quantity != nil) }
                if clarify.contains(old.id) { try demandRequire(old.source.isReservation && old.productKey == nil && after.productKey != nil && old.quantity == after.quantity && old.source == after.source) }
            } else {
                guard case .meal = old.source else { throw ClientError.configuration }
                try demandRequire(catalog.transferredRetirementCandidates.contains { $0.factId == input.factId && $0.contributionId == old.id })
                try demandRequire(!quantify.contains(old.id) && !clarify.contains(old.id))
            }
        }
        try demandRequire(Set(quantify.filter { detachedIDs.contains($0) }).isSubset(of: changedIDs) && Set(clarify.filter { detachedIDs.contains($0) }).isSubset(of: changedIDs))
    }
}
