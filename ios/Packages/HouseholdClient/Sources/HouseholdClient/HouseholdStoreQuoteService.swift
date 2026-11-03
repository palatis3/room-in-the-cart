import Foundation

extension HouseholdService {
    public func storeQuotes(shopID: UUID, cursor: UUID? = nil) async throws -> StoreQuotePage {
        let page: StoreQuotePage = try await storeQuoteRequest(shopID: shopID, cursor: cursor)
        try page.validate()
        guard page.shopId == shopID else { throw ClientError.invalidResponse }
        return page
    }
    public func prepareStoreQuote(shopID: UUID, action: StoreQuoteAction, request: StoreQuoteWrite) async throws -> StoreQuoteIntent {
        let context = try storeQuoteContext(shopID: shopID)
        let page = try await storeQuotes(shopID: shopID)
        guard try storeQuoteContext(shopID: shopID) == context,
              page.authorityEpoch == request.authorityEpoch, page.grantRevision == request.grantRevision,
              page.shopRevision == request.shopRevision, action == .grants || page.phase == "draft" else { throw ClientError.accessEnded }
        if action == .adoptions || action == .grants { guard page.shopper else { throw ClientError.accessEnded } }
        return try .init(context: context, shopID: shopID, action: action, request: request, reviewedCommitments: page.commitments)
    }
    public func authorizeStoreQuote(_ intent: StoreQuoteIntent) async throws {
        try intent.validate()
        let current = try storeQuoteContext(shopID: intent.shopID)
        guard current.subject == intent.context.subject, current.householdID == intent.context.householdID,
              current.memberID == intent.context.memberID else { throw ClientError.accessEnded }
        guard current.deviceID == intent.context.deviceID else {
            throw ClientError.service(status: 409, code: "quote_device_changed", correlationID: nil, retryAfter: nil)
        }
        let page = try await storeQuotes(shopID: intent.shopID)
        guard try storeQuoteContext(shopID: intent.shopID) == intent.context,
              page.authorityEpoch == intent.request.authorityEpoch, page.grantRevision == intent.request.grantRevision else {
            throw ClientError.service(status: 409, code: "quote_authority_changed", correlationID: nil, retryAfter: nil)
        }
        if intent.action == .adoptions || intent.action == .grants { guard page.shopper else { throw ClientError.accessEnded } }
    }
    public func executeStoreQuote(_ intent: StoreQuoteIntent) async throws -> StoreQuoteReceipt {
        try await authorizeStoreQuote(intent)
        let receipt: StoreQuoteReceipt = try await storeQuoteRequest(shopID: intent.shopID, suffix: "/" + intent.action.rawValue, method: "POST", body: intent.bytes)
        guard receipt.operationId == intent.id,
              receipt.shopRevision == intent.request.shopRevision + (intent.action == .adoptions ? 1 : 0) else { throw ClientError.invalidResponse }
        return receipt
    }
}
