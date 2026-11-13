import Foundation

extension HouseholdService {
    public func sharedDemand(shopID: UUID) async throws -> SharedDemandPage {
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shopID.uuidString.lowercased())
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        let page: SharedDemandPage = try await perform("shops/\(shopID.uuidString.lowercased())/demand", method: "GET")
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try page.validate(householdID: context.householdID, shopID: shopID)
        return page
    }
    public func sharedDemandActionSources(shopID: UUID, page: SharedDemandPage, request: SharedDemandActionSourceRequest) async throws -> SharedDemandActionSources {
        try request.validate()
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try page.validate(householdID: context.householdID, shopID: shopID)
        try await authorizeShopper(shopID: shopID.uuidString.lowercased())
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        let bytes = try encoded(request); guard bytes.count <= 65_536 else { throw ClientError.configuration }
        let result: SharedDemandActionSources = try await perform("shops/\(shopID.uuidString.lowercased())/demand/action-sources", method: "POST", body: bytes)
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        try result.validate(page: page, request: request); return result
    }
    public func previewSharedDemand(shopID: UUID, request: SharedDemandPreviewRequest) async throws -> SharedDemandReview {
        try request.validate()
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shopID.uuidString.lowercased())
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        let bytes = try encoded(request); guard bytes.count <= 1_800_000 else { throw ClientError.configuration }
        let preview: SharedDemandPreview = try await perform("shops/\(shopID.uuidString.lowercased())/demand/previews", method: "POST", body: bytes)
        guard generation == start, try sharedDemandContext(shopID: shopID) == context else { throw ClientError.cancelled }
        let review = SharedDemandReview(context: context, shopID: shopID, request: request, preview: preview)
        try review.validate(); return review
    }
    public func prepareSharedDemandApply(_ review: SharedDemandReview) async throws -> PendingOperation {
        try review.validate()
        let start = generation
        guard try sharedDemandContext(shopID: review.shopID) == review.context,
              let expiry = demandTime(review.preview.expiresAt), expiry > Date() else { throw ClientError.accessEnded }
        try await authorizeShopper(shopID: review.shopID.uuidString.lowercased())
        let window = try await replayWindow()
        guard generation == start, try sharedDemandContext(shopID: review.shopID) == review.context else { throw ClientError.cancelled }
        let binding = SharedDemandOperationBinding(context: review.context, shopID: .init(review.shopID), reservedOperationID: review.preview.receipt.operationId,
            previewID: review.preview.previewId, previewDigest: review.preview.previewDigest, action: review.request.action,
            base: review.commandBase, graphRevision: review.preview.after.revision)
        var body = try review.request.action.bodyValues()
        body["demandReview"] = .object(["previewId": .string(binding.previewID.string), "previewDigest": .string(binding.previewDigest)])
        let envelope = CommandEnvelope(replayWindow: window.id, shopId: review.shopID.uuidString.lowercased(), kind: binding.action.kind, base: binding.base, body: body)
        let operation = try PendingOperation(envelope: envelope, householdID: review.context.householdID, memberID: review.context.memberID,
                                             deviceID: review.context.deviceID, sharedDemandBinding: binding)
        _ = try binding.validate(operation); return operation
    }
    /// Never creates a replacement key, refreshes an expired preview or rewrites
    /// the saved action. The server distinguishes committed retry from new Apply.
    public func executeSharedDemand(_ operation: PendingOperation) async throws -> ShopperReceipt {
        guard let binding = operation.sharedDemandBinding else { throw ClientError.configuration }
        let envelope = try binding.validate(operation)
        guard let shopID = UUID(uuidString: envelope.shopId), try sharedDemandContext(shopID: shopID) == binding.context else { throw ClientError.accessEnded }
        let start = generation
        let receipt: ShopperReceipt
        switch binding.action {
        case .patch: receipt = try await executeSharedShop(operation)
        case .request: receipt = try await executeShopper(operation)
        }
        guard generation == start, try sharedDemandContext(shopID: shopID) == binding.context else { throw ClientError.cancelled }
        try binding.validateReceipt(receipt, envelope: envelope); return receipt
    }
}
