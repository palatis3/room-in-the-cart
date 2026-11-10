import Foundation

extension SharedRequestUndoHistory {
    func validate(shop: ShopperShop, beforeRevision: Int?) throws {
        try demandRequire(shopId.string == shop.shopId && shopRevision == shop.shopRevision && authorityEpoch == shop.authorityEpoch && shop.phase == "draft")
        var previous = beforeRevision ?? Int(Int32.max)
        for item in items {
            try demandRequire(item.shopRevision < previous && item.shopRevision <= shopRevision); previous = item.shopRevision
        }
        if let nextBeforeRevision { try demandRequire(items.count == 20 && nextBeforeRevision == items.last.map { String($0.shopRevision) }) }
    }
}
extension SharedRequestUndoCandidate {
    func validateStructure() throws {
        try demandIDs([shopId, targetOperationId])
        try demandRequire(schemaVersion == 1 && kind == "requestAcceptanceUndo")
        try demandRequire(action.body.targetOperationId == targetOperationId && action.body.requestId == requestUndo.requestId && action.body.baseRequestRevision == base.requestRevision)
        try demandRequire(requestUndo.current.revision == base.requestRevision && requestUndo.beforeLink.operationId == targetOperationId && requestUndo.beforeLink.shopId == shopId)
        try demandRequire(packReviewLineIds.map(\.string) == action.body.lines.map(\.lineId) && demandUnique(packReviewLineIds))
        try requestUndoBudget(beforeCheckout); try requestUndoBudget(afterCheckout)
        func acceptedSources(_ food: SharedRequestUndoFood) -> [SharedDemandSource] {
            if let catalog = food.catalog { return catalog.map(\.source) }
            return food.graph?.contributions.filter { $0.removedAt == nil }.map(\.source) ?? []
        }
        let requestID = requestUndo.requestId
        func target(_ source: SharedDemandSource) -> Bool { if case .request(let id, _) = source { return id == requestID }; return false }
        let sources = acceptedSources(foodBefore).filter(target)
        try demandRequire(sources.count == 1 && acceptedSources(foodAfter).filter(target).isEmpty)
        if case .request(_, let revision) = sources[0] { try demandRequire(revision == requestUndo.beforeLink.reviewedRevision) }

        switch (base.food, foodBefore) {
        case (.legacy, .legacy): break
        case (.tracked(let revision, _), .tracked(let graph)): try demandRequire(graph.revision == revision && graph.shopId == shopId)
        case (.partition(let revision, _, _, let privacy), .partition(let state)):
            try demandRequire(state.graph.revision == revision && state.graph.shopId == shopId && state.privacyRevision == privacy && state.authorityEpoch == base.authorityEpoch)
        default: throw ClientError.invalidResponse
        }
        if let before = foodBefore.graph, let after = foodAfter.graph {
            try demandRequire(before.householdId == after.householdId && after.shopId == shopId && after.revision == before.revision + 1)
            try demandRequire(Set(before.usedIds).isSubset(of: Set(after.usedIds)))
        } else if foodBefore.graph != nil || foodAfter.graph != nil { throw ClientError.invalidResponse }
        if case .partition(let state) = foodAfter {
            let basket = try action.body.lines.map { line -> SharedTrackingBasketLine in
                guard let id = UUID(uuidString: line.lineId) else { throw ClientError.invalidResponse }
                return try .reviewed(id: .init(id), name: line.originalItem, packs: line.packs, priceMinor: line.unitPriceMinor, feeEligible: line.feeEligible)
            }
            try demandRequire(Set(basket.map(\.id)) == Set(state.basket.map(\.id)) && basket.allSatisfy(state.basket.contains))
            try demandRequire(state.authorityEpoch == base.authorityEpoch)
            if case .partition(let before) = foodBefore { try demandRequire(state.privacyRevision == before.privacyRevision) }
        }
        if scope.firstAdoptionReversed {
            guard case .partition = foodBefore, case .partition = foodAfter else { throw ClientError.invalidResponse }
        }
    }
    public func validate(shop: ShopperShop, householdID: String, targetOperationID: SharedDemandID) throws {
        try validateStructure()
        try demandRequire(targetOperationID == targetOperationId && shopId.string == shop.shopId && shop.phase == "draft" && shop.storeReviewRequired != true)
        try demandRequire(shop.shopRevision == base.shopRevision && shop.authorityEpoch == base.authorityEpoch && action.body.quote == shop.quote)
        if let graph = foodBefore.graph { try demandRequire(graph.householdId.string == householdID.lowercased()) }
        if let storeBasis { try demandRequire(shop.storeBasisRevision == storeBasis.revision) }
        else { try demandRequire(shop.storeBasisRevision == nil) }
        // Exact field differences only; no food or checkout reducer runs here.
        let before = shop.lines, after = action.body.lines
        let ids = Set(before.map(\.lineId)).union(after.map(\.lineId))
        var changed = Set<String>()
        for id in ids {
            let old = before.first { $0.lineId == id }, next = after.first { $0.lineId == id }
            guard old != next else { continue }; changed.insert(id)
            guard let touched = scope.touchedLines.first(where: { $0.lineId.string == id }) else { throw ClientError.invalidResponse }
            var fields: [SharedOperationUndoTouchedLine.Field] = []
            if let old, let next {
                if old.originalItem != next.originalItem { fields.append(.originalItem) }
                if old.packs != next.packs { fields.append(.packs) }
                if old.unitPriceMinor != next.unitPriceMinor { fields.append(.unitPriceMinor) }
                if old.feeEligible != next.feeEligible { fields.append(.feeEligible) }
            } else { fields = [.membership] }
            try demandRequire(touched.fields == fields)
        }
        try demandRequire(Set(scope.touchedLines.map { $0.lineId.string }) == changed)
        if case .partition(let state) = foodBefore {
            try demandRequire(state.basket.count == shop.lines.count)
            for row in state.basket {
                guard let line = shop.lines.first(where: { $0.lineId == row.id.string }) else { throw ClientError.invalidResponse }
                try demandRequire(row.name == line.originalItem && row.packs == line.packs && row.priceMinor == line.unitPriceMinor && row.feeEligible == line.feeEligible)
            }
        }
    }
}
extension SharedRequestUndoPreviewInput {
    func validate(candidate: SharedRequestUndoCandidate) throws {
        try demandRequire(targetOperationId == candidate.targetOperationId && base == candidate.base && effectDigest == candidate.effectDigest)
        try demandRequire(packs.map(\.lineId) == candidate.packReviewLineIds && demandUnique(packs.map(\.lineId)))
        for pack in packs { try pack.usablePerPack?.validate() }
        let legacy: Set<SharedDemandID>
        switch candidate.foodAfter {
        case .legacy: legacy = Set(candidate.packReviewLineIds)
        case .tracked: legacy = []
        case .partition(let state): legacy = Set(state.legacyLineIds)
        }
        try demandRequire(packs.filter { legacy.contains($0.lineId) }.allSatisfy(\.acceptUnresolved))
        try demandRequire(candidate.afterCheckout.status != "overCap" || acceptOverage)
        try demandRequire((!["unresolved", "scopeMismatch"].contains(candidate.afterCheckout.status) && candidate.afterCheckout.scope == "wholeCheckout") || acceptUnknown)
    }
}

/// Permits only the documented preview substitution: fresh tracked packs and
/// newly generated retirement timestamps, with every other wire field exact.
private func normalizedRequestUndoCandidate(_ preview: SharedRequestUndoCandidate, against candidate: SharedRequestUndoCandidate,
                                            packs: [SharedDemandPackReview]) throws -> JSONValue {
    var wire = preview.wire
    guard case .object(var object) = wire, let foodAfter = object["foodAfter"], case .object(var after) = foodAfter else { throw ClientError.invalidResponse }
    var graphPath: [String] = []
    switch preview.foodAfter {
    case .partition(let state):
        guard case .partition(let expected) = candidate.foodAfter, case .object(var raw) = after["state"] else { throw ClientError.invalidResponse }
        let expectedPacks = packs.filter { !state.legacyLineIds.contains($0.lineId) }
        try demandRequire(state.packReviews == expectedPacks)
        raw["packReviews"] = try JSONDecoder().decode(JSONValue.self, from: encoded(expected.packReviews))
        after["state"] = .object(raw); graphPath = ["state", "graph"]
    case .tracked: graphPath = ["graph"]
    case .legacy: break
    }
    if let before = candidate.foodBefore.graph, let expected = candidate.foodAfter.graph, let actual = preview.foodAfter.graph {
        var normalized = actual
        for i in normalized.contributions.indices {
            let row = normalized.contributions[i]
            if before.contributions.first(where: { $0.id == row.id })?.removedAt == nil,
               before.contributions.contains(where: { $0.id == row.id }),
               let target = expected.contributions.first(where: { $0.id == row.id }), target.removedAt != nil, row.removedAt != nil {
                normalized.contributions[i].removedAt = target.removedAt
            }
        }
        for i in normalized.lines.indices {
            let row = normalized.lines[i]
            if before.lines.first(where: { $0.id == row.id })?.trashedAt == nil,
               before.lines.contains(where: { $0.id == row.id }),
               let target = expected.lines.first(where: { $0.id == row.id }), target.trashedAt != nil, row.trashedAt != nil {
                normalized.lines[i].trashedAt = target.trashedAt
            }
        }
        try demandRequire(normalized == expected)
        let raw = try JSONDecoder().decode(JSONValue.self, from: encoded(normalized))
        if graphPath == ["graph"] { after["graph"] = raw }
        else if case .object(var state) = after["state"] { state["graph"] = raw; after["state"] = .object(state) }
    }
    object["foodAfter"] = .object(after); wire = .object(object); return wire
}
extension SharedRequestUndoReview {
    func validate() throws {
        try candidate.validate(shop: shop, householdID: context.householdID, targetOperationID: candidate.targetOperationId)
        try input.validate(candidate: candidate)
        try demandRequire(response.packs == input.packs)
        let actual = response.candidate
        let normalized = try normalizedRequestUndoCandidate(actual, against: candidate, packs: input.packs)
        try demandRequire(normalized == candidate.wire)
        switch (candidate.foodBefore.graph, actual.foodAfter.graph, response.foodReceipt) {
        case (nil, nil, .legacy): break
        case (.some(let before), .some(let after), .tracked(let receipt)):
            try demandRequire(receipt.schemaVersion == 1 && receipt.operationId == response.operationId && receipt.householdId == before.householdId && receipt.shopId == before.shopId)
            try demandRequire(receipt.baseRevision == before.revision && receipt.resultRevision == after.revision)
            try demandRequire(receipt.lines == demandDiff(before.lines, after.lines, { $0.id }) && receipt.contributions == demandDiff(before.contributions, after.contributions, { $0.id }) && receipt.edges == demandDiff(before.edges, after.edges, { $0.id }))
        default: throw ClientError.invalidResponse
        }
    }
    func requireFresh(now: Date = Date()) throws {
        guard let expiry = demandTime(response.expiresAt), expiry > now, expiry <= now.addingTimeInterval(600) else { throw ClientError.service(status: 409, code: "stale_preview", correlationID: nil, retryAfter: nil) }
    }
}
