import Foundation

extension HouseholdService {
    private func trackingContext(_ expected: SharedDemandContext, shopID: UUID, generation start: UUID) throws {
        guard generation == start, try sharedDemandContext(shopID: shopID) == expected else { throw ClientError.cancelled }
    }
    public func sharedTracking(shopID: UUID) async throws -> SharedTrackingPage {
        let start = generation, context = try sharedDemandContext(shopID: shopID)
        try await authorizeShopper(shopID: shopID.uuidString.lowercased())
        try trackingContext(context, shopID: shopID, generation: start)
        let page: SharedTrackingPage = try await perform("shops/\(shopID.uuidString.lowercased())/demand/tracking", method: "GET", maximumResponseBytes: SharedTrackingWire.maximumResponseBytes)
        try trackingContext(context, shopID: shopID, generation: start)
        try page.validate(householdID: context.householdID, shopID: shopID, shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch)
        return page
    }
    public func sharedTrackingHistory(page: SharedTrackingPage) async throws -> SharedTrackingHistory {
        let shopID = page.shopId.uuid, start = generation, context = try sharedDemandContext(shopID: page.shopId.uuid)
        _ = try SharedTrackingReadBinding(page: page, context: context)
        try await authorizeShopper(shopID: page.shopId.string)
        try trackingContext(context, shopID: shopID, generation: start)
        let history: SharedTrackingHistory = try await perform("shops/\(page.shopId.string)/demand/tracking/operations", method: "GET", maximumResponseBytes: SharedTrackingWire.maximumResponseBytes)
        try trackingContext(context, shopID: shopID, generation: start)
        try history.validate(page: page); return history
    }
    public func sharedTrackingCandidate(page: SharedTrackingPage, kind: SharedTrackingIntentKind, requestPreview: ShopperPreview? = nil, actionSources: SharedTrackingActionSources? = nil,
                                        mealSources: SharedTrackingMealSources? = nil, transferredChanges: [SharedTrackingTransferredChange]? = nil) async throws -> SharedTrackingCandidateReview {
        let shopID = page.shopId.uuid, start = generation, context = try sharedDemandContext(shopID: page.shopId.uuid)
        let intent = try SharedTrackingIntent(page: page, context: context, kind: kind, requestPreview: requestPreview, actionSources: actionSources, mealSources: mealSources, transferredChanges: transferredChanges)
        try intent.requireFreshRequest()
        try await authorizeShopper(shopID: page.shopId.string)
        try trackingContext(context, shopID: shopID, generation: start)
        let bytes = try encoded(intent); try demandRequire(bytes.count <= SharedTrackingWire.maximumResponseBytes)
        let candidate: SharedTrackingCandidate = try await perform("shops/\(page.shopId.string)/demand/tracking/candidates", method: "POST", body: bytes, maximumResponseBytes: SharedTrackingWire.maximumResponseBytes)
        try trackingContext(context, shopID: shopID, generation: start)
        let result = try SharedTrackingCandidateReview(page: page, intent: intent, candidate: candidate)
        try result.requireFresh(); return result
    }
    /// Invoke only after displaying and explicitly acknowledging the complete
    /// changes AND pickup disclosure. Dropping the candidate sends no command.
    public func acceptSharedTrackingCandidate(_ review: SharedTrackingCandidateReview, acceptOverage: Bool = false, acceptUnknown: Bool = false) async throws -> SharedTrackingAcceptedReview {
        try review.validate(); try review.requireFresh()
        let acknowledgments = SharedTrackingMoneyAcknowledgments(acceptOverage: acceptOverage, acceptUnknown: acceptUnknown)
        try acknowledgments.validate(money: review.candidate.disclosure.money.after)
        let binding = review.intent.base, shopID = binding.shopId.uuid, start = generation
        guard try sharedDemandContext(shopID: shopID) == binding.context else { throw ClientError.accessEnded }
        try await authorizeShopper(shopID: binding.shopId.string)
        try trackingContext(binding.context, shopID: shopID, generation: start)
        struct Input: Encodable { let candidateId: SharedDemandID; let candidateDigest: String; let acknowledgedDisclosure: SharedTrackingDisclosure; let acceptOverage: Bool; let acceptUnknown: Bool }
        let bytes = try encoded(Input(candidateId: review.candidate.candidateId, candidateDigest: review.candidate.candidateDigest.value, acknowledgedDisclosure: review.candidate.disclosure, acceptOverage: acceptOverage, acceptUnknown: acceptUnknown))
        try demandRequire(bytes.count <= SharedTrackingWire.maximumResponseBytes)
        let preview: SharedTrackingPreview = try await perform("shops/\(binding.shopId.string)/demand/tracking/previews", method: "POST", body: bytes, maximumResponseBytes: SharedTrackingWire.maximumResponseBytes)
        try trackingContext(binding.context, shopID: shopID, generation: start)
        try demandRequire(preview.moneyAcknowledgments == acknowledgments)
        let accepted = try SharedTrackingAcceptedReview(candidateReview: review, preview: preview)
        try review.requireFresh(); return accepted
    }
    public func prepareSharedTrackingApply(_ review: SharedTrackingAcceptedReview) async throws -> PendingOperation {
        try review.validate(); try review.candidateReview.requireFresh()
        let candidate = review.candidateReview, read = candidate.intent.base, shopID = read.shopId.uuid, start = generation
        guard try sharedDemandContext(shopID: shopID) == read.context else { throw ClientError.accessEnded }
        let current = try await sharedTracking(shopID: shopID)
        try trackingContext(read.context, shopID: shopID, generation: start)
        try read.validate(page: current, context: read.context)
        let window = try await replayWindow()
        try trackingContext(read.context, shopID: shopID, generation: start)
        try candidate.requireFresh()
        try demandRequire(UUID(uuidString: window.id) != nil && demandTime(window.expiresAt).map { $0 > Date() } == true)
        let target: SharedDemandID?
        switch candidate.intent.kind {
        case .firstAdoptionUndo(let id, _), .mealOperationUndo(let id, _): target = id
        default: target = nil
        }
        let binding = SharedTrackingOperationBinding(kind: .apply, mode: candidate.intent.kind.mode, context: read.context, shopID: read.shopId,
            base: .init(shopRevision: read.shopRevision, authorityEpoch: read.authorityEpoch, requestRevision: candidate.intent.requestPreview?.requestRevision),
            graphRevision: candidate.candidate.after.graph.revision, privacyRevision: read.privacyRevision,
            stateDigest: review.preview.disclosure.pickup.stateDigest.value, previewID: review.preview.previewId, previewDigest: review.preview.previewDigest.value,
            action: review.preview.action, targetOperationID: target)
        return try trackingOperation(binding: binding, replayWindow: window.id)
    }
    /// The current read supplies the accepted freeze-review identity, which is
    /// distinct from the Apply preview. Partial and unknown coverage stay visible.
    public func prepareSharedTrackingFreeze(page: SharedTrackingPage) async throws -> PendingOperation {
        let start = generation, context = try sharedDemandContext(shopID: page.shopId.uuid), read = try SharedTrackingReadBinding(page: page, context: context)
        guard page.state != nil, page.projection == nil, let token = page.freezeReview else { throw ClientError.configuration }
        let current = try await sharedTracking(shopID: page.shopId.uuid)
        try trackingContext(context, shopID: page.shopId.uuid, generation: start)
        try read.validate(page: current, context: context)
        try demandRequire(current.freezeReview == token)
        let window = try await replayWindow()
        try trackingContext(context, shopID: page.shopId.uuid, generation: start)
        try demandRequire(UUID(uuidString: window.id) != nil && demandTime(window.expiresAt).map { $0 > Date() } == true)
        let binding = SharedTrackingOperationBinding(kind: .freeze, mode: "freeze", context: context, shopID: page.shopId,
            base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch), graphRevision: page.graph.revision,
            privacyRevision: page.privacyRevision, stateDigest: page.basisDigest.value, previewID: token.previewId, previewDigest: token.previewDigest.value, action: nil, targetOperationID: nil)
        return try trackingOperation(binding: binding, replayWindow: window.id)
    }
    private func trackingOperation(binding: SharedTrackingOperationBinding, replayWindow: String) throws -> PendingOperation {
        let envelope = CommandEnvelope(replayWindow: replayWindow, shopId: binding.shopID.string, kind: binding.commandKind, base: binding.base, body: try binding.body())
        let operation = try PendingOperation(envelope: envelope, householdID: binding.context.householdID, memberID: binding.context.memberID,
            deviceID: binding.context.deviceID, sharedTrackingBinding: binding)
        try binding.validate(operation); return operation
    }
    /// Exact saved bytes only. A fresh retry invocation may intentionally use a
    /// newly enrolled session with the same identity and original durable bytes.
    public func executeSharedTracking(_ operation: PendingOperation) async throws -> ShopperReceipt {
        let start = generation
        guard let binding = operation.sharedTrackingBinding else { throw ClientError.configuration }
        guard try sharedDemandContext(shopID: binding.shopID.uuid) == binding.context else { throw ClientError.accessEnded }
        do {
            let receipt = try await executeSharedTracking(operation, generation: start)
            try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            return receipt
        } catch let invalidation as SharedTrackingAccessInvalidated {
            guard generation == invalidation.clearedGeneration else { throw ClientError.cancelled }
            throw invalidation.underlying // Lower-level caller owns its outbox.
        }
    }
    private func executeSharedTracking(_ operation: PendingOperation, generation start: UUID) async throws -> ShopperReceipt {
        guard let binding = operation.sharedTrackingBinding else { throw ClientError.configuration }
        try binding.validate(operation)
        let shopID = binding.shopID.uuid, lease = SharedTrackingTransportLease(generation: start, context: binding.context, shopID: binding.shopID.uuid)
        try trackingContext(binding.context, shopID: shopID, generation: start)
        try await authorizeShopper(shopID: binding.shopID.string, trackingLease: lease)
        try trackingContext(binding.context, shopID: shopID, generation: start)
        let receipt: ShopperReceipt = try await perform("commands", method: "POST", body: operation.bytes, trackingLease: lease)
        try trackingContext(binding.context, shopID: shopID, generation: start)
        try binding.validateReceipt(receipt); return receipt
    }
    /// Generic 404 unavailable can mean a missing command resource. Only a fresh
    /// bootstrap/role check in this invocation's generation confirms scope loss.
    private func trackingShopAccessEnded(_ binding: SharedTrackingOperationBinding, generation start: UUID) async throws -> Bool {
        let lease = SharedTrackingTransportLease(generation: start, context: binding.context, shopID: binding.shopID.uuid)
        try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        do {
            try await authorizeShopper(shopID: binding.shopID.string, trackingLease: lease)
            try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            return false
        } catch let invalidation as SharedTrackingAccessInvalidated { throw invalidation }
        catch {
            try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            switch error {
            case ClientError.accessEnded, ClientError.sessionNeeded: return true
            case ClientError.service(let status, let code, _, _): return status == 404 && code == "unavailable"
            default: return false // Network or ordinary conflict does not prove loss.
            }
        }
    }
    /// Persist before sending. Snapshot exact original rows while the entry lease
    /// is current. Delayed cleanup can never delete new-session rows by scope alone.
    public func sendSharedTracking(_ operation: PendingOperation, outbox: any SharedTrackingOutbox) async throws -> ShopperReceipt {
        let start = generation
        guard let binding = operation.sharedTrackingBinding else { throw ClientError.configuration }
        try binding.validate(operation)
        guard try sharedDemandContext(shopID: binding.shopID.uuid) == binding.context else { throw ClientError.accessEnded }
        let observed: [PendingOperation]
        do { observed = try await outbox.operations() }
        catch { try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start); throw error }
        try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        do { try await outbox.append(operation) }
        catch { try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start); throw error }
        try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        let known = observed.filter { $0.id != operation.id } + [operation]
        do {
            let receipt = try await executeSharedTracking(operation, generation: start)
            try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            try await outbox.remove(operation.id)
            try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
            return receipt
        } catch {
            try await trackingFailure(error, operation: operation, binding: binding, known: known, generation: start, outbox: outbox)
        }
    }
    private func trackingFailure(_ error: Error, operation: PendingOperation, binding: SharedTrackingOperationBinding,
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
        try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        let originalShop = originalMember.filter { $0.sharedTrackingBinding?.shopID == binding.shopID || $0.sharedRequestUndoBinding?.shopID == binding.shopID }
        let targets: [PendingOperation]
        switch error {
        case ClientError.accessEnded: targets = originalShop
        case ClientError.sessionNeeded: targets = originalMember
        case ClientError.service(let status, let code, _, _):
            if status == 409 && ["tracking_preview_expired", "tracking_candidate_changed"].contains(code) {
                // The commands endpoint first resolves an existing exact operation
                // and returns its receipt. Only an uncommitted command reaches
                // preview expiry / candidate recomputation. Remove only this row;
                // generic refresh_required, stale conflicts and network ambiguity
                // never establish this noncommit boundary.
                targets = [operation]
            } else if ["tracking_replay_unavailable", "tracking_source_unavailable", "tracking_history_unavailable", "tracking_store_permission"].contains(code) {
                targets = originalMember
            } else if status == 404 && code == "unavailable" {
                let accessEnded: Bool
                do { accessEnded = try await trackingShopAccessEnded(binding, generation: start) }
                catch { try await trackingFailure(error, operation: operation, binding: binding, known: known, generation: start, outbox: outbox) }
                try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
                targets = accessEnded ? originalShop : []
            } else { targets = [] }
        default: targets = []
        }
        if !targets.isEmpty {
            do { try await outbox.removeIfUnchanged(targets) }
            catch { try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start); throw error }
            try trackingContext(binding.context, shopID: binding.shopID.uuid, generation: start)
        }
        throw error
    }
}
