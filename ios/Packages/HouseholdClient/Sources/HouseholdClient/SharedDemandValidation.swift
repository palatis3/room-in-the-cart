import Foundation

// Structural and binding validation only. The service's single exact reducer is
// authoritative for allocation arithmetic, conversions and current source facts.
private struct DemandKey: CodingKey {
    let stringValue: String; var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func demandExactKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let c = try decoder.container(keyedBy: DemandKey.self)
    try demandRequire(Set(c.allKeys.map(\.stringValue)) == expected)
}
func demandRequire(_ condition: @autoclosure () -> Bool) throws {
    guard condition() else { throw ClientError.invalidResponse }
}
func demandTime(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}
func demandText(_ text: String, limit: Int = 2048) -> Bool { !text.isEmpty && text.utf16.count <= limit }
func demandTag(_ text: String) -> Bool {
    text.utf16.count <= 128 && text.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil
}
func demandUnique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
func demandRevision(_ value: Int, zero: Bool = false) -> Bool { ((zero ? 0 : 1)...Int(Int32.max)).contains(value) }
func demandIDs(_ values: [SharedDemandID?]) throws { try demandRequire(values.compactMap { $0 }.allSatisfy(\.valid)) }

extension SharedDemandQuantity {
    public func validate() throws {
        try demandRequire(demandText(originalLiteral))
        if let c = confirmedConversion {
            try demandRequire(!DeliveryUnit.compatible(c.sourceUnit.rawValue, c.targetUnit.rawValue) && demandText(c.sourceNote) && demandTime(c.confirmedAt) != nil)
        }
    }
}
extension SharedDemandSource {
    var isReservation: Bool { if case .reservation = self { return true }; return false }
    var isSupply: Bool { switch self { case .manual, .imported: true; default: false } }
    var origin: (SharedDemandID?, SharedDemandID?) {
        switch self { case .meal(let occurrence, let ingredient, _, _): (occurrence, ingredient)
        case .reservation(_, _, let occurrence, let ingredient, _, _): (occurrence, ingredient)
        default: (nil, nil) }
    }
    var identityKey: String? {
        switch self {
        case .manual: nil
        case .imported(let batch, let entry): "import/\(batch.string)/\(entry.string)"
        case .request(let request, _): "request/\(request.string)"
        case .meal(let occurrence, let ingredient, let group, _): "meal/\(occurrence.string)/\(ingredient.string)/\(group?.string ?? "null")"
        case .reservation(let id, _, _, _, _, _): "reservation/\(id.string)"
        }
    }
    func validate() throws {
        switch self {
        case .request(let id, let revision): try demandIDs([id]); try demandRequire(demandRevision(revision, zero: true))
        case .meal(let occurrence, let ingredient, let group, let binding): try demandIDs([occurrence, ingredient, group, binding]); try demandRequire((group == nil) == (binding == nil))
        case .reservation(let id, let purpose, let occurrence, let ingredient, let group, let binding): try demandIDs([id, occurrence, ingredient, group, binding]); try demandRequire(demandText(purpose) && (binding == nil || group != nil))
        case .imported(let batch, let entry): try demandIDs([batch, entry])
        case .manual: break
        }
    }
    func isQuantification(of old: Self) -> Bool {
        guard case .reservation(let id, let purpose, let origin, let ingredient, let group, let binding) = self,
              case .reservation(let oldID, let oldPurpose, let oldOrigin, let oldIngredient, let oldGroup, let oldBinding) = old else { return false }
        return id == oldID && purpose == oldPurpose && origin == oldOrigin && ingredient == oldIngredient && group == oldGroup && oldBinding == nil && binding != nil
    }
}
extension SharedDemandContribution {
    public func validate() throws {
        try demandIDs([id, lineId]); try source.validate(); try quantity?.validate()
        try demandRequire(demandText(productName) && demandText(originalText) && (productKey.map(demandTag) ?? true))
        try demandRequire(exclusions.count <= 60 && contains.count <= 60 && demandUnique(exclusions) && demandUnique(contains))
        try demandRequire(exclusions.allSatisfy(demandTag) && contains.allSatisfy(demandTag) && Set(exclusions).isDisjoint(with: contains))
        try demandRequire(removedAt.map { demandTime($0) != nil } ?? true)
        let restrictions = sourceExclusions ?? []
        try demandRequire(restrictions.count <= 40 && demandUnique(restrictions.map { "\($0.occurrenceId.string)/\($0.ingredientId?.string ?? "null")/\($0.label)" }))
        for item in restrictions {
            try demandIDs([item.occurrenceId, item.ingredientId])
            try demandRequire(source.origin.0 == item.occurrenceId && (item.ingredientId == nil || source.origin.1 == item.ingredientId) && demandText(item.label, limit: 240))
            if case .mapped(let tags, let at) = item.resolution {
                try demandRequire(!tags.isEmpty && tags.count <= 60 && demandUnique(tags) && tags.allSatisfy(demandTag) && Set(tags).isSubset(of: Set(exclusions)) && demandTime(at) != nil)
            }
        }
    }
}
extension SharedDemandLine {
    func validate() throws { try demandIDs([id]); try demandRequire(demandText(name) && (0...10_000).contains(originalOrder) && (trashedAt.map { demandTime($0) != nil } ?? true)) }
}
extension SharedDemandEdge {
    func validate() throws {
        try demandIDs([id, demandId, supplyId]); try quantity.validate(); try demandRequire(demandId != supplyId && confirmation.productMatchConfirmed && demandTime(confirmation.confirmedAt) != nil && demandText(confirmation.evidence))
    }
}
extension SharedDemandGraph {
    public func validate() throws {
        try demandIDs(([householdId, shopId] + usedIds).map { Optional.some($0) })
        try demandRequire(schemaVersion == 1 && conversionTableVersion == "us-customary-metric-v1" && demandRevision(revision, zero: true))
        try demandRequire(lines.count <= 200 && contributions.count <= 2000 && edges.count <= 4000 && usedIds.count <= 10000)
        let ids = lines.map(\.id) + contributions.map(\.id) + edges.map(\.id)
        try demandRequire(demandUnique(ids) && demandUnique(usedIds) && Set(ids).isSubset(of: Set(usedIds)) && demandUnique(lines.map(\.originalOrder)))
        for line in lines { try line.validate() }
        for contribution in contributions {
            try contribution.validate()
            let line = lines.first { $0.id == contribution.lineId }
            try demandRequire(line != nil && (contribution.removedAt != nil || line?.trashedAt == nil))
        }
        // Retired request generations remain unique by reviewed revision; the
        // current catalog still permits only one active source per request.
        let provenance = contributions.compactMap { row -> String? in
            if case .request(let request, let revision) = row.source { return "request/\(request.string)/\(revision)" }
            return row.source.identityKey
        }
        let activeRequests = contributions.compactMap { row -> SharedDemandID? in
            guard row.removedAt == nil, case .request(let request, _) = row.source else { return nil }
            return request
        }
        try demandRequire(demandUnique(provenance) && demandUnique(activeRequests))
        for edge in edges {
            try edge.validate()
            guard let demand = contributions.first(where: { $0.id == edge.demandId }), let supply = contributions.first(where: { $0.id == edge.supplyId }) else { throw ClientError.invalidResponse }
            try demandRequire(demand.removedAt == nil && supply.removedAt == nil && demand.lineId == supply.lineId && demand.quantity != nil && supply.quantity != nil)
            try demandRequire(supply.source.isSupply && (edge.kind == .duplicate ? demand.source.isSupply : !demand.source.isSupply))
            try demandRequire([demand, supply].allSatisfy { !($0.sourceExclusions ?? []).contains { $0.resolution == .unresolved } })
        }
    }
}
extension SharedDemandChange {
    public var isEmpty: Bool { lines.isEmpty && contributions.isEmpty && edges.isEmpty && removeSourceIds.isEmpty && removeEdgeIds.isEmpty && (quantifyReservationIds ?? []).isEmpty && (clarifyReservationProductIds ?? []).isEmpty }
    public func validate() throws {
        try demandRequire(lines.count <= 200 && contributions.count <= 2000 && edges.count <= 4000 && removeSourceIds.count <= 2000 && removeEdgeIds.count <= 4000 && (quantifyReservationIds?.count ?? 0) <= 2000 && (clarifyReservationProductIds?.count ?? 0) <= 2000)
        try demandIDs((removeSourceIds + removeEdgeIds + (quantifyReservationIds ?? []) + (clarifyReservationProductIds ?? [])).map(Optional.some))
        let ids = lines.map(\.id) + contributions.map(\.id) + edges.map(\.id)
        try demandRequire(demandUnique(ids) && demandUnique(removeSourceIds) && demandUnique(removeEdgeIds) && demandUnique(quantifyReservationIds ?? []) && demandUnique(clarifyReservationProductIds ?? []))
        try demandRequire(Set(ids).isDisjoint(with: removeSourceIds + removeEdgeIds))
        try demandRequire(Set(clarifyReservationProductIds ?? []).isDisjoint(with: (quantifyReservationIds ?? []) + removeSourceIds))
        for id in clarifyReservationProductIds ?? [] {
            guard let row = contributions.first(where: { $0.id == id }) else { throw ClientError.invalidResponse }
            try demandRequire(row.source.isReservation && row.removedAt == nil && row.productKey != nil)
        }
        for line in lines { try line.validate() }; for c in contributions { try c.validate() }; for e in edges { try e.validate() }
    }
}
extension SharedDemandPreviewRequest {
    public func validate() throws {
        try demandIDs([undoOperationId] + packs.map { Optional.some($0.lineId) })
        try demandRequire(demandRevision(base.shopRevision) && demandRevision(base.authorityEpoch) && demandRevision(base.graphRevision, zero: true))
        try demandRequire((mode == .adopt) == (base.graphRevision == 0) && (mode == .undo) == (undoOperationId != nil))
        try demandRequire(!(mode == .undo || mode == .review) || change.isEmpty)
        try change.validate(); try demandRequire(packs.count <= 200 && demandUnique(packs.map(\.lineId)))
        for pack in packs { try pack.usablePerPack?.validate() }
        switch action {
        case .patch(let body):
            _ = try ShopperShopCandidate(quote: body.quote, lines: body.lines, reviewedStoreBasisRevision: body.reviewedStoreBasisRevision)
            if let edit = body.mealEdit { try demandIDs([edit.occurrenceId, edit.proposalId, edit.changeProposalId]); try edit.meal?.validatePlanning(); try demandRequire(edit.baseMealRevision.map { demandRevision($0) } ?? true) }
        case .request(let body): try demandIDs([body.requestId, body.previewId]) // Revision and allowed decision remain bound to its existing server preview.
        }
    }
}
extension SharedDemandPage {
    public func validate(householdID: String, shopID: UUID) throws {
        try demandRequire(schemaVersion == 1 && shopId.uuid == shopID && demandRevision(shopRevision) && demandRevision(authorityEpoch))
        try demandRequire((status == .legacy) == (graph == nil))
        try demandRequire(status == .legacy || legacySources == nil)
        try legacySources?.validate()
        try validateDemandTotals(totals, graph: graph)
        if let graph { try graph.validate(); try demandRequire(graph.householdId.string == householdID.lowercased() && graph.shopId == shopId && graph.revision > 0) }
    }
}

func validateDemandTotals(_ totals: [SharedDemandLineTotal], graph: SharedDemandGraph?) throws {
    guard let graph else { try demandRequire(totals.isEmpty); return }
    let lines = graph.lines.filter { line in line.trashedAt == nil && graph.contributions.contains { $0.lineId == line.id && $0.removedAt == nil } }
    try demandRequire(totals.map(\.lineId) == lines.map(\.id))
    for (line, total) in zip(lines, totals) {
        try demandRequire(total.unit == line.unit && total.activeContributionIds == graph.contributions.filter { $0.lineId == line.id && $0.removedAt == nil }.map(\.id))
    }
}
func demandDiff<Value: Equatable & Codable & Sendable>(_ before: [Value], _ after: [Value], _ id: (Value) -> SharedDemandID) -> [SharedDemandDelta<Value>] {
    let order = before.map(id) + after.map(id).filter { key in !before.contains { id($0) == key } }
    return order.compactMap { key in
        let b = before.first { id($0) == key }, a = after.first { id($0) == key }
        return b == a ? nil : SharedDemandDelta(id: key, before: b, after: a)
    }
}
extension SharedDemandReview {
    public func validate() throws {
        try request.validate(); try preview.before.validate(); try preview.after.validate()
        try demandIDs([preview.previewId, preview.receipt.operationId])
        let before = preview.before, after = preview.after, receipt = preview.receipt
        try demandRequire(before.householdId.string == context.householdID.lowercased() && before.shopId.uuid == shopID && after.householdId == before.householdId && after.shopId == before.shopId)
        try demandRequire(before.revision == request.base.graphRevision && after.revision == before.revision + 1 && preview.shopRevision == request.base.shopRevision && preview.authorityEpoch == request.base.authorityEpoch)
        try demandRequire(receipt.schemaVersion == 1 && receipt.householdId == before.householdId && receipt.shopId == before.shopId && receipt.baseRevision == before.revision && receipt.resultRevision == after.revision)
        try demandRequire(preview.packs == request.packs && demandTime(preview.expiresAt) != nil && preview.previewDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        try demandRequire(receipt.lines == demandDiff(before.lines, after.lines, { $0.id }) && receipt.contributions == demandDiff(before.contributions, after.contributions, { $0.id }) && receipt.edges == demandDiff(before.edges, after.edges, { $0.id }))
        try demandRequire(Set(before.usedIds).isSubset(of: Set(after.usedIds)))
        try validateDemandTotals(preview.beforeTotals, graph: before); try validateDemandTotals(preview.afterTotals, graph: after)
        if request.mode == .adopt { try demandRequire(before.lines.isEmpty && before.contributions.isEmpty && before.edges.isEmpty && before.usedIds.isEmpty) }
        if request.mode == .review { try demandRequire(receipt.lines.isEmpty && receipt.contributions.isEmpty && receipt.edges.isEmpty) }
        for id in request.change.clarifyReservationProductIds ?? [] {
            guard let old = before.contributions.first(where: { $0.id == id }),
                  let next = after.contributions.first(where: { $0.id == id }),
                  old.source.isReservation, old.removedAt == nil, old.productKey == nil, next.productKey != nil,
                  request.change.contributions.contains(next) else { throw ClientError.invalidResponse }
            var expected = old; expected.productKey = next.productKey
            try demandRequire(next == expected)
        }
        for old in before.contributions {
            guard let next = after.contributions.first(where: { $0.id == old.id }) else { throw ClientError.invalidResponse }
            let quantified = (request.change.quantifyReservationIds ?? []).contains(old.id) && old.quantity == nil && next.quantity != nil && next.source.isQuantification(of: old.source)
            try demandRequire((next.source == old.source || quantified) && next.originalText == old.originalText)
            if old.source.isReservation && old.removedAt == nil {
                try demandRequire(next.removedAt == nil)
                if old.productKey != next.productKey { try demandRequire((request.change.clarifyReservationProductIds ?? []).contains(old.id)) }
            }
        }
        if case .request(let action) = request.action {
            let sources = after.contributions.filter { row in if case .request(let id, _) = row.source { return row.removedAt == nil && id == action.requestId }; return false }
            try demandRequire(sources.count == 1)
        }
    }
    var commandBase: CommandBase {
        var requestRevision: Int?
        if case .request(let action) = request.action {
            requestRevision = preview.after.contributions.compactMap { row -> Int? in
                if case .request(let id, let revision) = row.source, id == action.requestId, row.removedAt == nil { return revision }; return nil
            }.first
        }
        return .init(shopRevision: request.base.shopRevision, authorityEpoch: request.base.authorityEpoch, requestRevision: requestRevision)
    }
}
extension SharedDemandOperationBinding {
    func validate(_ operation: PendingOperation) throws -> CommandEnvelope {
        try demandRequire(operation.sharedRequestUndoBinding == nil && operation.sharedTrackingBinding == nil)
        try demandIDs([shopID, reservedOperationID, previewID])
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        try demandRequire(operation.householdID == context.householdID && operation.memberID == context.memberID && operation.deviceID == context.deviceID && operation.clientKey == envelope.clientKey)
        try demandRequire(envelope.v == 1 && envelope.kind == action.kind && envelope.base == base && envelope.shopId == shopID.string && demandRevision(graphRevision) && demandRevision(base.shopRevision) && demandRevision(base.authorityEpoch))
        var body = try action.bodyValues(); body["demandReview"] = .object(["previewId": .string(previewID.string), "previewDigest": .string(previewDigest)])
        try demandRequire(envelope.body == body && previewDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && operation.bytes.count <= 65_536)
        return envelope
    }
    func validateReceipt(_ receipt: ShopperReceipt, envelope: CommandEnvelope) throws {
        try demandRequire(receipt.operationId == reservedOperationID.string && receipt.kind == action.kind && receipt.shopId == envelope.shopId && receipt.shopRevision == base.shopRevision + 1 && receipt.authorityEpoch == base.authorityEpoch)
        switch action {
        case .patch: try demandRequire(receipt.disposition == "patched")
        case .request(let body): try demandRequire(receipt.disposition == "added" && receipt.requestId == body.requestId.string && base.requestRevision != nil && receipt.requestRevision == base.requestRevision.map { $0 + 1 })
        }
    }
}
