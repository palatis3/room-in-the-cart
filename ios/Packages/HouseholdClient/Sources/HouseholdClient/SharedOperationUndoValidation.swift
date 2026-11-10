import Foundation

private func undoDigest(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
extension SharedOperationUndoHistory {
    public func validate(page: SharedDemandPage, beforeRevision: Int?) throws {
        try demandRequire(schemaVersion == 1 && shopId == page.shopId && shopRevision == page.shopRevision && authorityEpoch == page.authorityEpoch)
        try demandRequire(items.count <= 20 && demandUnique(items.map(\.operationId)))
        var previous = beforeRevision ?? Int(Int32.max)
        for item in items {
            try demandIDs([item.operationId])
            try demandRequire(demandRevision(item.shopRevision) && item.shopRevision <= shopRevision && item.shopRevision < previous && demandTime(item.committedAt) != nil)
            try demandRequire((item.eligibility.status == .reviewable) == (item.eligibility.reason == .explicit_current_preview_required))
            if item.eligibility.status == .reviewable { try demandRequire(item.kind == .patch) }
            previous = item.shopRevision
        }
        if let nextBeforeRevision {
            try demandRequire(items.count == 20 && nextBeforeRevision == items.last.map { String($0.shopRevision) })
        }
    }
}
private func undoBudget(_ value: ShopperBudget) throws {
    try demandRequire(value.currency == "USD" && ["withinCap", "overCap", "unresolved", "scopeMismatch"].contains(value.status))
    try demandRequire(["wholeCheckout", "item", "dinner"].contains(value.scope) && value.lowerBoundMinor >= 0)
    try demandRequire([value.totalMinor, value.overCapMinor, value.upperBoundMinor].compactMap { $0 }.allSatisfy { $0 >= 0 })
    try demandRequire(value.upperBoundMinor.map { $0 >= value.lowerBoundMinor } ?? true)
    try demandRequire(value.missing.count <= 1000 && value.missing.allSatisfy { demandText($0) })
    if value.wholeCheckoutWithinCap { try demandRequire(value.scope == "wholeCheckout" && value.status == "withinCap" && value.totalMinor != nil) }
}
private func undoGraphProtection(_ before: SharedDemandGraph, _ after: SharedDemandGraph) throws {
    try before.validate(); try after.validate()
    try demandRequire(before.householdId == after.householdId && before.shopId == after.shopId && after.revision == before.revision + 1 && before.usedIds == after.usedIds)
    try demandRequire(Set(before.lines.map(\.id)) == Set(after.lines.map(\.id)) && Set(before.contributions.map(\.id)) == Set(after.contributions.map(\.id)))
    for old in before.contributions {
        guard let next = after.contributions.first(where: { $0.id == old.id }) else { throw ClientError.invalidResponse }
        try demandRequire(old.source == next.source && old.originalText == next.originalText)
        if old.source.isReservation && old.removedAt == nil {
            // Never reverse quantification/product clarification or relax a protected amount.
            // Cross-unit quantity mutations require a future explicitly reviewed contract.
            try demandRequire(next.removedAt == nil && next.quantity == old.quantity && next.productKey == old.productKey)
        }
    }
}
extension SharedOperationUndoCandidate {
    public func validate(page: SharedDemandPage, shop: ShopperShop, target: SharedOperationUndoHistoryItem) throws {
        let expected = try SharedDemandActionSourceBase(page: page)
        try demandRequire(schemaVersion == 1 && shopId == page.shopId && base == expected && before == page.graph && beforeTotals == page.totals)
        try demandRequire(shop.storeBasisRevision == nil && shop.storeReviewRequired != true && shop.shopId == shopId.string && shop.phase == "draft" && shop.shopRevision == base.shopRevision && shop.authorityEpoch == base.authorityEpoch)
        try demandRequire(target.operationId == targetOperationId && target.kind == .patch && target.eligibility.status == .reviewable && target.eligibility.reason == .explicit_current_preview_required && undoDigest(effectDigest))
        try demandRequire(scope.targetOperationId == targetOperationId && demandRevision(scope.baseShopRevision) && scope.resultShopRevision == scope.baseShopRevision + 1 && scope.resultShopRevision == target.shopRevision && scope.resultShopRevision <= base.shopRevision)
        try demandRequire(!scope.requestsChanged && (0...6200).contains(scope.graphRows) && scope.touchedLines.count <= 200)
        try demandRequire(scope.mealsChanged || scope.quoteChanged || scope.graphRows > 0 || !scope.touchedLines.isEmpty)
        if scope.mealsChanged {
            guard let mealUndo, let edit = action.body.mealEdit else { throw ClientError.invalidResponse }
            try mealUndo.validate(scope: scope, base: base, shop: shop, edit: edit)
        } else { try demandRequire(mealUndo == nil && action.body.mealEdit == nil) }
        try undoGraphProtection(before, after)
        try validateDemandTotals(beforeTotals, graph: before); try validateDemandTotals(afterTotals, graph: after)
        _ = try ShopperShopCandidate(quote: action.body.quote, lines: action.body.lines)
        let quote = action.body.quote
        guard let observed = demandTime(quote.observedAt), let expires = demandTime(quote.expiresAt) else { throw ClientError.invalidResponse }
        try demandRequire(quote.currency == "USD")
        _ = try ShopperQuote(scope: quote.scope, complete: quote.complete, capMinor: quote.capMinor, capScope: quote.capScope,
            fee: quote.fee, taxesMinor: quote.taxesMinor, depositsMinor: quote.depositsMinor, discountsMinor: quote.discountsMinor, observedAt: observed, expiresAt: expires)
        try demandRequire(demandUnique(scope.touchedLines.map(\.lineId)) && demandUnique(packReviewLineIds))
        try demandRequire(packReviewLineIds.map(\.string) == action.body.lines.map(\.lineId))
        try demandRequire(Set(packReviewLineIds) == Set(after.lines.filter { $0.trashedAt == nil }.map(\.id)))
        let oldLines = shop.lines, newLines = action.body.lines
        let order = oldLines.map(\.lineId) + newLines.map(\.lineId).filter { id in !oldLines.contains { $0.lineId == id } }
        var changed = Set<String>()
        for id in order {
            let old = oldLines.first { $0.lineId == id }, next = newLines.first { $0.lineId == id }
            if old == next { continue }; changed.insert(id)
            guard let touched = scope.touchedLines.first(where: { $0.lineId.string == id }) else { throw ClientError.invalidResponse }
            let fields: [SharedOperationUndoTouchedLine.Field]
            if let old, let next {
                var differences: [SharedOperationUndoTouchedLine.Field] = []
                if old.originalItem != next.originalItem { differences.append(.originalItem) }
                if old.packs != next.packs { differences.append(.packs) }
                if old.unitPriceMinor != next.unitPriceMinor { differences.append(.unitPriceMinor) }
                if old.feeEligible != next.feeEligible { differences.append(.feeEligible) }
                fields = differences
            } else { fields = [.membership] }
            try demandRequire(touched.fields == fields)
        }
        try demandRequire(Set(scope.touchedLines.map { $0.lineId.string }) == changed && scope.quoteChanged == (shop.quote != quote))
        try undoBudget(beforeCheckout); try undoBudget(afterCheckout)
    }
}
extension SharedOperationUndoReview {
    public func validate() throws {
        try page.validate(householdID: context.householdID, shopID: candidate.shopId.uuid)
        try candidate.validate(page: page, shop: shop, target: target); try request.validate(candidate: candidate)
        let p = response.preview, r = p.receipt
        try demandRequire(response.operationUndo.targetOperationId == candidate.targetOperationId && response.operationUndo.effectDigest == candidate.effectDigest && response.operationUndo.scope == candidate.scope && response.action == candidate.action)
        try demandRequire(response.mealUndo == candidate.mealUndo)
        try demandRequire(response.beforeCheckout == candidate.beforeCheckout && response.afterCheckout == candidate.afterCheckout)
        try demandRequire(p.before == candidate.before && p.beforeTotals == candidate.beforeTotals && p.afterTotals == candidate.afterTotals && p.packs == request.packs)
        try demandRequire(p.shopRevision == candidate.base.shopRevision && p.authorityEpoch == candidate.base.authorityEpoch && undoDigest(p.previewDigest) && demandTime(p.expiresAt) != nil)
        try demandIDs([p.previewId, r.operationId]); try demandRequire(r.operationId != target.operationId)
        try undoGraphProtection(p.before, p.after)
        var comparable = p.after
        for i in comparable.contributions.indices {
            let row = comparable.contributions[i]
            if let original = p.before.contributions.first(where: { $0.id == row.id }), original.removedAt == nil,
               let expected = candidate.after.contributions.first(where: { $0.id == row.id }), expected.removedAt != nil, row.removedAt != nil {
                comparable.contributions[i].removedAt = expected.removedAt
            }
        }
        for i in comparable.lines.indices {
            let row = comparable.lines[i]
            if let original = p.before.lines.first(where: { $0.id == row.id }), original.trashedAt == nil,
               let expected = candidate.after.lines.first(where: { $0.id == row.id }), expected.trashedAt != nil, row.trashedAt != nil {
                comparable.lines[i].trashedAt = expected.trashedAt
            }
        }
        try demandRequire(comparable == candidate.after)
        try demandRequire(r.schemaVersion == 1 && r.householdId == p.before.householdId && r.shopId == p.before.shopId && r.baseRevision == p.before.revision && r.resultRevision == p.after.revision)
        try demandRequire(r.lines == demandDiff(p.before.lines, p.after.lines, { $0.id }) && r.contributions == demandDiff(p.before.contributions, p.after.contributions, { $0.id }) && r.edges == demandDiff(p.before.edges, p.after.edges, { $0.id }))
        try validateDemandTotals(p.afterTotals, graph: p.after)
    }
}
