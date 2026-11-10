import Foundation

// Structural consistency only. The authenticated service validates current
// catalog provenance, allocation math, consent, authorization and erasure.
protocol TrackingStateFields {
    var schemaVersion: Int { get }
    var authorityEpoch: Int { get }
    var privacyRevision: Int { get }
    var graph: SharedDemandGraph { get }
    var basket: [SharedTrackingBasketLine] { get }
    var catalog: [SharedTrackingFact] { get }
    var bindings: [SharedTrackingBinding] { get }
    var unbound: [SharedTrackingUnboundFact] { get }
    var legacyLineIds: [SharedDemandID] { get }
}
extension SharedTrackingState: TrackingStateFields {}
extension SharedTrackingSurvivingState: TrackingStateFields {}

extension SharedTrackingFact {
    func validate() throws {
        try source.validate(); try quantity?.validate()
        try demandRequire(!source.isSupply && demandRevision(revision, zero: true))
        try demandRequire(demandText(sourceLabel) && demandText(originalText) && (originalQuantityText.map { demandText($0) } ?? true))
        try demandRequire(sourceExclusions.count <= 40)
        for item in sourceExclusions {
            try demandRequire(source.origin.0 == item.occurrenceId && (item.ingredientId == nil || source.origin.1 == item.ingredientId))
            try demandRequire(demandText(item.label, limit: 240))
            if case .mapped(let tags, let at) = item.resolution {
                try demandRequire(!tags.isEmpty && tags.count <= 60 && demandUnique(tags) && tags.allSatisfy(demandTag) && demandTime(at) != nil)
            }
        }
    }
}
private func trackingMatches(_ row: SharedDemandContribution, _ fact: SharedTrackingFact) throws {
    try demandRequire(row.source == fact.source && row.originalText == fact.originalText)
    if case .request = fact.source { /* Request quantity can be reviewed separately. */ }
    else {
        try demandRequire(row.quantity?.amount == fact.quantity?.amount && row.quantity?.unit == fact.quantity?.unit && row.quantity?.originalLiteral == fact.quantity?.originalLiteral)
        if let conversion = fact.quantity?.confirmedConversion { try demandRequire(row.quantity?.confirmedConversion == conversion) }
    }
    let restrictions = row.sourceExclusions ?? []
    try demandRequire(restrictions.count == fact.sourceExclusions.count)
    for (a, b) in zip(restrictions, fact.sourceExclusions) {
        try demandRequire(a.occurrenceId == b.occurrenceId && a.ingredientId == b.ingredientId && a.label == b.label)
    }
    try demandRequire(fact.requiredLineId == nil || fact.requiredLineId == row.lineId)
}
func trackingValidateCore<S: TrackingStateFields>(_ s: S) throws {
    try s.graph.validate()
    try demandRequire(s.schemaVersion == 2 && demandRevision(s.authorityEpoch, zero: true) && demandRevision(s.privacyRevision, zero: true))
    try demandRequire(s.basket.count <= 200 && s.catalog.count <= 2000 && s.bindings.count <= 2000 && s.unbound.count <= 2000 && s.legacyLineIds.count <= 200)
    try demandRequire(demandUnique(s.catalog.map(\.id)) && demandUnique(s.catalog.compactMap { $0.source.identityKey }) && demandUnique(s.basket.map(\.id)))
    let partition = s.bindings.map(\.factId) + s.unbound.map(\.factId)
    try demandRequire(demandUnique(partition) && Set(partition) == Set(s.catalog.map(\.id)) && demandUnique(s.bindings.map(\.contributionId)))
    let facts = Dictionary(uniqueKeysWithValues: s.catalog.map { ($0.id, $0) })
    for fact in s.catalog {
        try demandRequire(fact.requiredLineId == nil || s.basket.contains { $0.id == fact.requiredLineId })
    }
    let live = s.graph.contributions.filter { $0.removedAt == nil }
    for binding in s.bindings {
        guard let row = live.first(where: { $0.id == binding.contributionId }), let fact = facts[binding.factId] else { throw ClientError.invalidResponse }
        try trackingMatches(row, fact)
    }
    let boundIDs = Set(s.bindings.map(\.contributionId))
    try demandRequire(live.filter { !$0.source.isSupply }.allSatisfy { boundIDs.contains($0.id) })
    let detached = s.unbound.compactMap(\.transferred)
    try demandRequire(demandUnique(detached.map(\.id)))
    for unbound in s.unbound {
        guard let row = unbound.transferred else { continue }
        try row.validate()
        guard let fact = facts[unbound.factId] else { throw ClientError.invalidResponse }
        try demandRequire(row.removedAt == nil && !s.graph.contributions.contains { $0.id == row.id })
        try demandRequire(s.graph.usedIds.contains(row.id) && !s.graph.lines.contains { $0.id == row.id } && !s.graph.edges.contains { $0.id == row.id || $0.demandId == row.id || $0.supplyId == row.id })
        try trackingMatches(row, fact)
    }
    let tracked = s.graph.lines.filter { $0.trashedAt == nil }
    try demandRequire(tracked.allSatisfy { line in live.contains { $0.lineId == line.id } })
    let linePartition = tracked.map(\.id) + s.legacyLineIds
    try demandRequire(demandUnique(linePartition) && Set(linePartition) == Set(s.basket.map(\.id)))
    for line in tracked { try demandRequire(s.basket.contains { $0.id == line.id && $0.name == line.name }) }
}
extension SharedTrackingState {
    func validate() throws {
        try trackingValidateCore(self)
        let tracked = graph.lines.filter { $0.trashedAt == nil }
        try demandRequire(packReviews.count <= 200 && demandUnique(packReviews.map(\.lineId)) && Set(packReviews.map(\.lineId)) == Set(tracked.map(\.id)))
        for pack in packReviews { try pack.usablePerPack?.validate() }
    }
    /// A structural check for a normal same-privacy refresh. It does not infer
    /// operations/reducers or admit old history after privacy changes.
    public func validateRetainedIdentities(from previous: SharedTrackingState) throws {
        try demandRequire(graph.householdId == previous.graph.householdId && graph.shopId == previous.graph.shopId)
        try demandRequire(privacyRevision == previous.privacyRevision && authorityEpoch == previous.authorityEpoch && graph.revision >= previous.graph.revision)
        try demandRequire(Set(previous.graph.usedIds).isSubset(of: Set(graph.usedIds)))
    }
}
extension SharedTrackingCoverage {
    func validate(state: SharedTrackingState) throws {
        try validateDemandTotals(trackedSubtotals, graph: state.graph)
        try demandRequire(unboundFactIds == state.unbound.map(\.factId) && untrackedBasketIds == state.legacyLineIds)
        let protected = state.unbound.filter { u in state.catalog.first { $0.id == u.factId }?.source.isReservation == true }.map(\.factId)
        try demandRequire(protectedUnboundFactIds == protected)
        let expected: Status = !unboundFactIds.isEmpty || !untrackedBasketIds.isEmpty ? .partial : trackedSubtotals.contains { $0.quantity == nil } ? .unknown : .tracked
        try demandRequire(status == expected)
        // Numeric values remain server-authored. These implications are structural:
        // a missing quantity cannot become a known subtotal. Restrictions remain
        // independent of numeric totals; numeric does not mean safe or sufficient.
        for total in trackedSubtotals {
            let rows = state.graph.contributions.filter { $0.lineId == total.lineId && $0.removedAt == nil }
            if rows.contains(where: { $0.quantity == nil }) {
                try demandRequire(total.quantity == nil)
            }
        }
    }
}
extension SharedTrackingPage {
    var graph: SharedDemandGraph { state?.graph ?? projection!.state.graph }
    public var privacyRevision: Int { state?.privacyRevision ?? projection!.state.privacyRevision }
    func validateStructure() throws {
        try demandRequire(schemaVersion == 2 && demandRevision(shopRevision) && demandRevision(authorityEpoch))
        if status == .reviewRequired {
            try demandRequire(state == nil && projection != nil && coverage == nil && freezeReview == nil)
        } else {
            try demandRequire(state != nil && projection == nil && coverage != nil)
            if let state, let coverage { try coverage.validate(state: state) }
        }
        try demandRequire(graph.shopId == shopId && (state?.authorityEpoch ?? projection?.state.authorityEpoch) == authorityEpoch)
        if status == .legacy { try demandRequire(graph.revision == 0) }
        if status == .enabled { try demandRequire(graph.revision > 0) }
    }
    public func validate(householdID: String, shopID: UUID, shopRevision: Int, authorityEpoch: Int) throws {
        try demandRequire(graph.householdId.string == householdID.lowercased() && shopId.uuid == shopID && self.shopRevision == shopRevision && self.authorityEpoch == authorityEpoch)
    }
}
extension SharedTrackingHistory {
    public func validate(page: SharedTrackingPage) throws {
        try demandRequire(shopId == page.shopId && shopRevision == page.shopRevision)
    }
}

/// Pins an already-read response to the caller's exact session and revision.
/// This is a stale-response check, never permission or placement evidence.
/// Do not persist source content or reuse this binding across privacy recovery.
public struct SharedTrackingReadBinding: Equatable, Sendable {
    public let context: SharedDemandContext
    public let shopId: SharedDemandID
    public let shopRevision, graphRevision, authorityEpoch, privacyRevision: Int
    public let basisDigest: SharedTrackingDigest
    public init(page: SharedTrackingPage, context: SharedDemandContext) throws {
        try demandRequire(page.graph.householdId.string == context.householdID.lowercased())
        self.context = context; shopId = page.shopId; shopRevision = page.shopRevision
        graphRevision = page.graph.revision; authorityEpoch = page.authorityEpoch
        privacyRevision = page.privacyRevision; basisDigest = page.basisDigest
    }
    public func validate(page: SharedTrackingPage, context: SharedDemandContext) throws {
        let current = try SharedTrackingReadBinding(page: page, context: context)
        try demandRequire(current == self)
    }
}
