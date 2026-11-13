import Foundation

extension HouseholdService {
    private func requestUndoContext(_ expected: SharedDemandContext, shopID: UUID, generation start: UUID) throws {
        guard generation == start, try sharedDemandContext(shopID: shopID) == expected else { throw ClientError.cancelled }
    }
    public func requestAcceptanceHistory(shop: ShopperShop, beforeRevision: Int? = nil) async throws -> SharedRequestUndoHistory {
        guard let shopID = UUID(uuidString: shop.shopId) else { throw ClientError.configuration }
        if let beforeRevision { try demandRequire(demandRevision(beforeRevision)) }
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shop.shopId)
        try requestUndoContext(context, shopID: shopID, generation: start)
        let result: SharedRequestUndoHistory = try await perform("shops/\(shop.shopId)/requests/operations", method: "GET",
            query: beforeRevision.map { [URLQueryItem(name: "beforeRevision", value: String($0))] } ?? [], maximumResponseBytes: SharedRequestUndoWire.maximumResponseBytes)
        try requestUndoContext(context, shopID: shopID, generation: start)
        try result.validate(shop: shop, beforeRevision: beforeRevision); return result
    }
    /// The target can come from request history or explicit tracking reviewRoute.
    /// Only this fresh server candidate establishes reviewable current facts.
    public func requestAcceptanceUndoCandidate(shop: ShopperShop, targetOperationID: SharedDemandID) async throws -> SharedRequestUndoCandidate {
        guard let shopID = UUID(uuidString: shop.shopId) else { throw ClientError.configuration }
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shop.shopId)
        try requestUndoContext(context, shopID: shopID, generation: start)
        struct Base: Encodable { let shopRevision, authorityEpoch: Int }
        struct Input: Encodable { let targetOperationId: SharedDemandID; let base: Base }
        let input = Input(targetOperationId: targetOperationID, base: .init(shopRevision: shop.shopRevision, authorityEpoch: shop.authorityEpoch))
        let result: SharedRequestUndoCandidate = try await perform("shops/\(shop.shopId)/requests/operation-undo-candidates", method: "POST", body: encoded(input), maximumResponseBytes: SharedRequestUndoWire.maximumResponseBytes)
        try requestUndoContext(context, shopID: shopID, generation: start)
        try result.validate(shop: shop, householdID: context.householdID, targetOperationID: targetOperationID); return result
    }
    public func previewRequestAcceptanceUndo(shop: ShopperShop, candidate: SharedRequestUndoCandidate,
                                             packs: [SharedDemandPackReview], acceptOverage: Bool, acceptUnknown: Bool) async throws -> SharedRequestUndoReview {
        let shopID = candidate.shopId.uuid, start = generation, context = try sharedDemandContext(shopID: candidate.shopId.uuid)
        try candidate.validate(shop: shop, householdID: context.householdID, targetOperationID: candidate.targetOperationId)
        let input = try SharedRequestUndoPreviewInput(candidate: candidate, packs: packs, acceptOverage: acceptOverage, acceptUnknown: acceptUnknown)
        try await authorizeShopper(shopID: candidate.shopId.string)
        try requestUndoContext(context, shopID: shopID, generation: start)
        let bytes = try encoded(input); try demandRequire(bytes.count <= SharedRequestUndoWire.maximumResponseBytes)
        let result: SharedRequestUndoPreview = try await perform("shops/\(candidate.shopId.string)/requests/operation-undo-previews", method: "POST", body: bytes, maximumResponseBytes: SharedRequestUndoWire.maximumResponseBytes)
        try requestUndoContext(context, shopID: shopID, generation: start)
        let review = try SharedRequestUndoReview(context: context, shop: shop, candidate: candidate, input: input, response: result)
        try review.requireFresh(); return review
    }
    public func prepareRequestAcceptanceUndo(_ review: SharedRequestUndoReview) async throws -> PendingOperation {
        try review.validate(); try review.requireFresh()
        let start = generation, shopID = review.candidate.shopId.uuid, context = review.context
        try requestUndoContext(context, shopID: shopID, generation: start)
        try await authorizeShopper(shopID: review.candidate.shopId.string)
        try requestUndoContext(context, shopID: shopID, generation: start)
        let current = try await shopperShop(shopID: review.candidate.shopId.string)
        try requestUndoContext(context, shopID: shopID, generation: start)
        try demandRequire(current == review.shop)
        let window = try await replayWindow()
        try requestUndoContext(context, shopID: shopID, generation: start); try review.requireFresh()
        try demandRequire(UUID(uuidString: window.id) != nil && demandTime(window.expiresAt).map { $0 > Date() } == true)
        let candidate = review.response.candidate
        let binding = SharedRequestUndoOperationBinding(context: context, shopID: candidate.shopId, targetOperationID: candidate.targetOperationId,
            reservedOperationID: review.response.operationId, previewID: review.response.previewId, previewDigest: review.response.previewDigest,
            base: .init(shopRevision: candidate.base.shopRevision, authorityEpoch: candidate.base.authorityEpoch, requestRevision: candidate.base.requestRevision), action: candidate.action)
        let operation = try PendingOperation(envelope: .init(replayWindow: window.id, shopId: candidate.shopId.string, kind: "request.undoAcceptance", base: binding.base, body: binding.body()),
            householdID: context.householdID, memberID: context.memberID, deviceID: context.deviceID, sharedRequestUndoBinding: binding)
        try binding.validate(operation); return operation
    }
    public func executeRequestAcceptanceUndo(_ operation: PendingOperation) async throws -> ShopperReceipt {
        do { return try await executeRequestAcceptanceUndo(operation, generation: generation) }
        catch let invalidation as SharedTrackingAccessInvalidated {
            guard generation == invalidation.clearedGeneration else { throw ClientError.cancelled }; throw invalidation.underlying
        }
    }
    private func executeRequestAcceptanceUndo(_ operation: PendingOperation, generation start: UUID) async throws -> ShopperReceipt {
        guard let binding = operation.sharedRequestUndoBinding else { throw ClientError.configuration }
        try binding.validate(operation)
        let lease = SharedTrackingTransportLease(generation: start, context: binding.context, shopID: binding.shopID.uuid)
        try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        try await authorizeShopper(shopID: binding.shopID.string, trackingLease: lease)
        try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        let receipt: ShopperReceipt = try await perform("commands", method: "POST", body: operation.bytes, trackingLease: lease)
        try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        try binding.validateReceipt(receipt); return receipt
    }
    private func requestUndoShopAccessEnded(_ binding: SharedRequestUndoOperationBinding, generation start: UUID) async throws -> Bool {
        let lease = SharedTrackingTransportLease(generation: start, context: binding.context, shopID: binding.shopID.uuid)
        try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        do {
            try await authorizeShopper(shopID: binding.shopID.string, trackingLease: lease)
            try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            return false
        } catch let invalidation as SharedTrackingAccessInvalidated { throw invalidation }
        catch {
            try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            switch error {
            case ClientError.accessEnded, ClientError.sessionNeeded: return true
            case ClientError.service(let status, let code, _, _): return status == 404 && code == "unavailable"
            default: return false // Network or ordinary conflict does not prove loss.
            }
        }
    }
    /// Persist before sending. Snapshot exact original rows while the entry lease
    /// is current. Delayed cleanup can never delete new-session rows by scope alone.
    public func sendRequestAcceptanceUndo(_ operation: PendingOperation, outbox: any SharedTrackingOutbox) async throws -> ShopperReceipt {
        let start = generation
        guard let binding = operation.sharedRequestUndoBinding else { throw ClientError.configuration }
        try binding.validate(operation)
        guard try sharedDemandContext(shopID: binding.shopID.uuid) == binding.context else { throw ClientError.accessEnded }
        let observed: [PendingOperation]
        do { observed = try await outbox.operations() }
        catch { try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start); throw error }
        try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        do { try await outbox.append(operation) }
        catch { try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start); throw error }
        try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        let known = observed.filter { $0.id != operation.id } + [operation]
        do {
            let receipt = try await executeRequestAcceptanceUndo(operation, generation: start)
            try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            try await outbox.remove(operation.id)
            try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            return receipt
        } catch {
            try await requestUndoFailure(error, operation: operation, binding: binding, known: known, generation: start, outbox: outbox)
        }
    }
    private func requestUndoFailure(_ error: Error, operation: PendingOperation, binding: SharedRequestUndoOperationBinding,
                                 known: [PendingOperation], generation start: UUID, outbox: any SharedTrackingOutbox) async throws -> Never {
        let originalMember = known.filter { $0.householdID == operation.householdID && $0.memberID == operation.memberID }
        if let invalidation = error as? SharedTrackingAccessInvalidated {
            // This event is proven by perform's response handling, not inferred
            // from a changed generation. Exact-row cleanup is safe even if a new
            // session has since enrolled and appended new same-shop commands.
            guard invalidation.lease.generation == start, invalidation.lease.context == binding.context,
                  invalidation.lease.shopID == binding.shopID.uuid else { throw ClientError.invalidResponse }
            do { try await outbox.removeIfUnchanged(originalMember) }
            catch {
                guard generation == invalidation.clearedGeneration else { throw ClientError.cancelled }
                throw error
            }
            guard generation == invalidation.clearedGeneration else { throw ClientError.cancelled }
            throw invalidation.underlying
        }
        // An unrelated clear/re-enroll has no invalidation proof and cannot
        // initiate cleanup. Explicit sign-out still owns its full lifecycle purge.
        try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        let originalShop = originalMember.filter { $0.sharedRequestUndoBinding?.shopID == binding.shopID || $0.sharedTrackingBinding?.shopID == binding.shopID }
        let targets: [PendingOperation]
        switch error {
        case ClientError.accessEnded: targets = originalShop
        case ClientError.sessionNeeded: targets = originalMember
        case ClientError.service(let status, let code, _, _):
            if status == 409 && code == "request_undo_history_unavailable" {
                // Missing immutable target evidence is terminal for this exact
                // command. Ambiguous refresh_required expiry remains retained.
                targets = [operation]
            } else if ["request_undo_history_erased", "request_undo_author_access_ended", "tracking_replay_unavailable", "tracking_source_unavailable", "tracking_history_unavailable", "tracking_store_permission"].contains(code) {
                targets = originalMember
            } else if status == 409 && code == "request_undo_access_ended" {
                targets = originalShop
            } else if status == 404 && code == "unavailable" {
                let accessEnded: Bool
                do { accessEnded = try await requestUndoShopAccessEnded(binding, generation: start) }
                catch { try await requestUndoFailure(error, operation: operation, binding: binding, known: known, generation: start, outbox: outbox) }
                try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
                targets = accessEnded ? originalShop : []
            } else { targets = [] }
        default: targets = []
        }
        if !targets.isEmpty {
            do { try await outbox.removeIfUnchanged(targets) }
            catch { try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start); throw error }
            try requestUndoContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        }
        throw error
    }
}
