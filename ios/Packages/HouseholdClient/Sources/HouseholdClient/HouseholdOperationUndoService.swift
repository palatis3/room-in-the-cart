import Foundation

extension HouseholdService {
    private func operationUndoContext(shopID: UUID) async throws -> (UUID, SharedDemandContext) {
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shopID.uuidString.lowercased())
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        return (start, context)
    }
    public func sharedOperationHistory(shopID: UUID, page: SharedDemandPage, beforeRevision: Int? = nil) async throws -> SharedOperationUndoHistory {
        if let beforeRevision { try demandRequire(demandRevision(beforeRevision)) }
        let (start, context) = try await operationUndoContext(shopID: shopID)
        try page.validate(householdID: context.householdID, shopID: shopID)
        let query = beforeRevision.map { [URLQueryItem(name: "beforeRevision", value: String($0))] } ?? []
        let result: SharedOperationUndoHistory = try await perform("shops/\(shopID.uuidString.lowercased())/demand/operations", method: "GET", query: query)
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try result.validate(page: page, beforeRevision: beforeRevision); return result
    }
    public func sharedOperationUndoCandidate(page: SharedDemandPage, shop: ShopperShop, target: SharedOperationUndoHistoryItem) async throws -> SharedOperationUndoCandidate {
        guard target.kind == .patch, target.eligibility.status == .reviewable, target.eligibility.reason == .explicit_current_preview_required else { throw ClientError.configuration }
        let shopID = page.shopId.uuid, request = try SharedOperationUndoCandidateRequest(targetOperationID: target.operationId, page: page)
        let (start, context) = try await operationUndoContext(shopID: shopID)
        try page.validate(householdID: context.householdID, shopID: shopID)
        let result: SharedOperationUndoCandidate = try await perform("shops/\(shopID.uuidString.lowercased())/demand/operation-undo-candidates", method: "POST", body: try encoded(request))
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try result.validate(page: page, shop: shop, target: target); return result
    }
    public func previewSharedOperationUndo(page: SharedDemandPage, shop: ShopperShop, target: SharedOperationUndoHistoryItem, candidate: SharedOperationUndoCandidate, packs: [SharedDemandPackReview]) async throws -> SharedOperationUndoReview {
        try candidate.validate(page: page, shop: shop, target: target)
        let request = try SharedOperationUndoPreviewRequest(candidate: candidate, packs: packs), shopID = page.shopId.uuid
        let (start, context) = try await operationUndoContext(shopID: shopID)
        try page.validate(householdID: context.householdID, shopID: shopID)
        let bytes = try encoded(request); try demandRequire(bytes.count <= 1_800_000)
        let result: SharedOperationUndoPreview = try await perform("shops/\(shopID.uuidString.lowercased())/demand/operation-undo-previews", method: "POST", body: bytes)
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        return try .init(context: context, page: page, shop: shop, target: target, candidate: candidate, request: request, response: result)
    }
    public func prepareSharedOperationUndoApply(_ review: SharedOperationUndoReview) async throws -> PendingOperation {
        try review.validate()
        func checkExpiry() throws {
            let preview = review.response.preview
            guard let expiry = demandTime(preview.expiresAt), expiry > Date() else { throw ClientError.service(status: 409, code: "stale_preview", correlationID: nil, retryAfter: nil) }
            let scope = review.candidate.scope
            if scope.quoteChanged || scope.touchedLines.contains(where: { touched in
                touched.fields.contains(.unitPriceMinor) || (touched.fields.contains(.membership) &&
                    review.response.action.body.lines.contains(where: { $0.lineId == touched.lineId.string }))
            }) {
                guard let expiry = demandTime(review.response.action.body.quote.expiresAt), expiry > Date() else { throw ClientError.service(status: 409, code: "food_undo_expired_quote", correlationID: nil, retryAfter: nil) }
            }
        }
        try checkExpiry()
        let shopID = review.page.shopId.uuid
        let (start, context) = try await operationUndoContext(shopID: shopID)
        guard context == review.context else { throw ClientError.accessEnded }
        let window = try await replayWindow()
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try checkExpiry()
        let preview = review.response.preview
        let action = review.response.action.commandAction
        let binding = SharedDemandOperationBinding(context: context, shopID: review.page.shopId, reservedOperationID: preview.receipt.operationId,
            previewID: preview.previewId, previewDigest: preview.previewDigest, action: action,
            base: .init(shopRevision: preview.shopRevision, authorityEpoch: preview.authorityEpoch), graphRevision: preview.after.revision)
        var body = try action.bodyValues()
        body["demandReview"] = .object(["previewId": .string(binding.previewID.string), "previewDigest": .string(binding.previewDigest)])
        let envelope = CommandEnvelope(replayWindow: window.id, shopId: review.page.shopId.string, kind: "shop.patch", base: binding.base, body: body)
        let operation = try PendingOperation(envelope: envelope, householdID: context.householdID, memberID: context.memberID, deviceID: context.deviceID, sharedDemandBinding: binding)
        _ = try binding.validate(operation); return operation
    }
}
