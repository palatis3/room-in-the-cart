import Foundation
import SwiftUI

@MainActor final class MembershipModel: ObservableObject {
    @Published private(set) var state = MembershipState()
    @Published private(set) var offer: MembershipOffer?
    @Published private(set) var isLoadingOffer = false
    @Published private(set) var isBusy = false
    @Published private(set) var notice: Notice?
    // Apple does not identify a request/transaction in a pending purchase result.
    // Keep that report separate from the service outcome of each admitted update.
    @Published private(set) var purchaseReport: PurchaseReport?
    // Latest admitted attempt per verified identity, retained only in this model
    // session. Generic reconciliation cannot erase another transaction's failure.
    // A same-transaction retry updates its own outcome; stop clears all evidence.
    @Published private(set) var deliveryOutcomes: [String: DeliveryOutcome] = [:]
    // Distinct historical callback rejections in this session, coalesced by
    // reason. They neither describe a later purchase call nor prove delivery.
    @Published private(set) var callbackRejections: [MembershipFailure] = []
    let configuration: MembershipConfiguration
    let context: MembershipContext?
    @Published private(set) var eligibleAdults: [MembershipSeat]
    private let service: any MembershipEntitlementService
    private let storefront: any MembershipStorefront
    private let clock: () -> Date
    private var updatesTask: Task<Void, Never>?
    private var inFlightTransactions: Set<String> = []
    private var started = false
    private(set) var isStopped = false
    private var generation = 0
    private var purchaseRejection: MembershipFailure?

    enum Notice: Equatable { case pending, cancelled, restored, delivered, failed(MembershipFailure) }

    enum PurchaseReport: Equatable {
        case awaitingResult, pending, cancelled, unverified, verified(transactionID: String), failed(MembershipFailure)
    }
    enum DeliveryOutcome: Equatable {
        case inFlight // Current admitted attempt is awaiting service/finish.
        case delivered // Historical durable acknowledgement; never current access.
        case failed(MembershipFailure) // Unresolved latest observation for this transaction.
    }
    enum StatusMessage: Equatable, Identifiable {
        case pendingReport, cancelledReport, unverifiedReport, purchaseFailure(MembershipFailure)
        case deliveryInFlight, deliverySaved, deliveryFailure(MembershipFailure), callbackRejection(MembershipFailure), otherNotice(Notice)

        var id: String {
            switch self {
            case .pendingReport: return "membership.status.purchase.pending"
            case .cancelledReport: return "membership.status.purchase.cancelled"
            case .unverifiedReport: return "membership.status.purchase.unverified"
            case .purchaseFailure(let issue): return "membership.status.purchase.failure." + Self.failureID(issue)
            case .deliveryInFlight: return "membership.status.delivery.in-flight"
            case .deliverySaved: return "membership.status.delivery.saved"
            case .deliveryFailure(let issue): return "membership.status.delivery.failure." + Self.deliveryFailureID(issue)
            case .callbackRejection(let issue): return "membership.status.callback.rejection." + Self.failureID(issue)
            case .otherNotice(let notice):
                switch notice {
                case .pending: return "membership.status.notice.pending"
                case .cancelled: return "membership.status.notice.cancelled"
                case .restored: return "membership.status.notice.restored"
                case .delivered: return "membership.status.notice.delivered"
                case .failed(let issue): return "membership.status.notice.failure." + Self.failureID(issue)
                }
            }
        }
        // Delivery rows describe the action to take, not each transaction's
        // internal error. Keep their identity stable while equivalent failures
        // arrive or recover; the underlying deliveryOutcomes remain separate.
        private static func deliveryFailureID(_ issue: MembershipFailure) -> String {
            switch issue {
            case .unverified, .invalidReceipt, .invalidSnapshot, .serverRejected: return "verification"
            case .wrongHousehold, .accountMismatch: return "account-household"
            default: return failureID(issue)
            }
        }

        private static func failureID(_ issue: MembershipFailure) -> String {
            switch issue {
            case .notConfigured: return "not-configured"
            case .signInRequired: return "sign-in-required"
            case .unavailable: return "unavailable"
            case .unverified: return "unverified"
            case .wrongHousehold: return "wrong-household"
            case .invalidSnapshot: return "invalid-snapshot"
            case .invalidReceipt: return "invalid-receipt"
            case .deliveryPending: return "delivery-pending"
            case .serverRejected: return "server-rejected"
            case .accountMismatch: return "account-mismatch"
            case .refreshRequired: return "refresh-required"
            case .notPurchaser: return "not-purchaser"
            case .membershipInactive: return "membership-inactive"
            }
        }
    }

    /// User-facing projection of independent observations; never infer that a
    /// transaction update resolves the request that returned pending.
    var statusMessages: [StatusMessage] {
        var messages: [StatusMessage] = []
        switch purchaseReport {
        case .pending: messages.append(.pendingReport)
        case .cancelled: messages.append(.cancelledReport)
        case .unverified: messages.append(.unverifiedReport)
        case .failed(let issue): messages.append(.purchaseFailure(issue))
        case .awaitingResult, .verified, nil: break
        }
        if let purchaseRejection, purchaseReport != .unverified {
            messages.append(.purchaseFailure(purchaseRejection))
        }
        var deliveryIssues: [MembershipFailure] = []
        for outcome in deliveryOutcomes.values {
            if case .failed(let issue) = outcome, !deliveryIssues.contains(issue) { deliveryIssues.append(issue) }
        }
        var deliveryMessageIDs: Set<String> = []
        for issue in deliveryIssues.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            let message = StatusMessage.deliveryFailure(issue)
            if deliveryMessageIDs.insert(message.id).inserted { messages.append(message) }
        }
        if deliveryOutcomes.values.contains(.inFlight) { messages.append(.deliveryInFlight) }
        if deliveryOutcomes.values.contains(.delivered) { messages.append(.deliverySaved) }
        for issue in callbackRejections.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            messages.append(.callbackRejection(issue))
        }
        if let notice {
            switch notice {
            case .pending where purchaseReport == .pending: break
            case .cancelled where purchaseReport == .cancelled: break
            case .delivered where deliveryOutcomes.values.contains(.delivered): break
            case .failed(let issue) where deliveryIssues.contains(issue) || callbackRejections.contains(issue)
                || purchaseRejection == issue || purchaseReport == .failed(issue)
                || (issue == .unverified && purchaseReport == .unverified): break
            default: messages.append(.otherNotice(notice))
            }
        }
        return messages
    }

    init(configuration: MembershipConfiguration = .fromBundle(), context: MembershipContext? = nil, eligibleAdults: [MembershipSeat] = [],
         service: (any MembershipEntitlementService)? = nil,
         storefront: (any MembershipStorefront)? = nil, clock: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.context = context
        self.eligibleAdults = eligibleAdults.filter { $0.isAdult }
        self.service = service ?? UnavailableMembershipService()
        self.storefront = storefront ?? StoreKitMembershipStorefront()
        self.clock = clock
    }

    deinit { updatesTask?.cancel() }

    var hasPaidAccess: Bool { state.hasPaidAccess(context: context, now: clock()) }
    var canManageSeats: Bool {
        guard !isStopped, let context, let snapshot = state.snapshot, snapshot.purchaserID == context.purchaserID,
              snapshot.householdID == context.householdID, snapshot.verifiedAt <= clock(), clock() < snapshot.validUntil else { return false }
        switch snapshot.status {
        case .active: return snapshot.expiresAt.map { clock() < $0 } ?? false
        case .grace: return snapshot.graceExpiresAt.map { clock() < $0 } ?? false
        default: return false
        }
    }
    var canPurchase: Bool {
        !isStopped && configuration.isReady && context?.appAccountToken != nil && offer != nil && !isBusy && canStartNewPurchase
    }

    private var canStartNewPurchase: Bool {
        !canManageSeats && inFlightTransactions.isEmpty && notice != .failed(.deliveryPending)
            && !deliveryOutcomes.values.contains(.failed(.deliveryPending))
    }

    /// Retain at app scope; calling this from a settings screen as well is idempotent.
    func start() async {
        guard !started, !isStopped else { return }
        started = true
        let session = generation
        // An off-device purchase can arrive while StoreKit is still loading the offer.
        if context?.appAccountToken != nil, let productID = configuration.productID {
            let stream = storefront.updates(for: productID)
            updatesTask = Task { [weak self] in
                for await outcome in stream {
                    guard !Task.isCancelled, let self, session == self.generation else { break }
                    await self.receive(outcome)
                }
            }
        }
        await loadOffer()
        guard session == generation else { return }
        await refresh()
    }

    /// Call on sign out before discarding the model. No private/local work is removed.
    func stop() {
        generation += 1
        isStopped = true
        updatesTask?.cancel()
        updatesTask = nil
        started = false
        state.clear()
        eligibleAdults = []
        notice = nil
        purchaseRejection = nil
        purchaseReport = nil; deliveryOutcomes = [:]; callbackRejections = []
        offer = nil
        isLoadingOffer = false
        inFlightTransactions.removeAll()
    }

    func loadOffer() async {
        guard !isStopped, !isLoadingOffer, let id = configuration.productID else { return }
        let session = generation
        isLoadingOffer = true
        defer { isLoadingOffer = false }
        do {
            let loaded = try await storefront.load(productID: id)
            guard session == generation else { return }
            offer = loaded
        } catch {
            guard session == generation else { return }
            // The offer section shows its own retry. Preserve purchase and restore notices.
            offer = nil
        }
    }

    /// Foreground reconciliation: retry unfinished delivery and fetch authoritative expiry/refund state.
    func refresh() async {
        guard !isStopped, let context else { return }
        let session = generation
        var deliveryFailure: MembershipFailure?
        // A second adult reads their named seat with their own authenticated session.
        // They never submit the purchaser's App Store transactions under a different identity.
        if context.appAccountToken != nil {
            let unfinished = await storefront.unfinishedTransactions()
            for outcome in unfinished {
                guard session == generation else { return }
                if let failure = await receive(outcome) { deliveryFailure = failure }
            }
            let current = await storefront.currentTransactions()
            for outcome in current {
                guard session == generation else { return }
                if let failure = await receive(outcome) { deliveryFailure = failure }
            }
        }
        do {
            let snapshot = try await service.fetch(context: context)
            guard session == generation else { return }
            try state.accept(snapshot, context: context, now: clock())
            if canManageSeats {
                let adults = try await service.seatCandidates(context: context)
                guard session == generation else { return }
                eligibleAdults = adults.filter { $0.isAdult }
            } else { eligibleAdults = [] }
            // A successful Free projection does not erase a rejected restore or undelivered transaction.
            if let deliveryFailure { state.fail(deliveryFailure); notice = .failed(deliveryFailure) }
        } catch {
            guard session == generation else { return }
            let issue = failure(error)
            state.fail(issue)
            if issue == .signInRequired || issue == .membershipInactive { eligibleAdults = [] }
        }
    }

    func purchase() async {
        guard !isBusy, !isStopped else { return }
        guard configuration.isReady else { notice = .failed(.notConfigured); return }
        guard let context else { notice = .failed(.signInRequired); return }
        guard let appAccountToken = context.appAccountToken else { notice = .failed(.notPurchaser); return }
        guard offer != nil else { notice = .failed(.unavailable); return }
        isBusy = true
        let session = generation
        defer { isBusy = false }
        // A previous purchase can still be awaiting service delivery after a relaunch.
        let unfinished = await storefront.unfinishedTransactions()
        guard session == generation else { return }
        if !unfinished.isEmpty {
            for outcome in unfinished {
                guard session == generation else { return }
                await receive(outcome)
            }
            return
        }
        guard canStartNewPurchase else { return }
        // Only a new actual StoreKit purchase call resets its report. Observer
        // updates, restores and unrelated rejections cannot resolve this request.
        purchaseRejection = nil
        notice = nil
        purchaseReport = .awaitingResult
        do {
            let result = try await storefront.purchase(appAccountToken: appAccountToken)
            guard session == generation else { return }
            switch result {
            case .pending: purchaseReport = .pending
            case .cancelled: purchaseReport = .cancelled
            case .unverified: purchaseReport = .unverified
            case .verified(let transaction): purchaseReport = .verified(transactionID: transaction.transactionID)
            }
            await receive(result, origin: .purchase)
            if case .pending = result {
                // Approval can already be unfinished when the purchase reports pending.
                // Reconcile once through the normal delivery path; the pending report
                // does not identify this transaction or establish membership access.
                let unfinished = await storefront.unfinishedTransactions()
                guard session == generation else { return }
                for outcome in unfinished {
                    guard session == generation else { return }
                    await receive(outcome)
                }
            }
        } catch {
            guard session == generation else { return }
            let issue = error as? MembershipFailure ?? .unavailable
            purchaseReport = .failed(issue)
            notice = .failed(issue)
        }
    }

    func restore() async {
        guard !isBusy, !isStopped else { return }
        guard let context else { notice = .failed(.signInRequired); return }
        isBusy = true
        let session = generation
        defer { isBusy = false }
        do {
            // Only the purchasing account restores Apple transactions; a named seat is recovered from the service.
            if context.appAccountToken != nil { try await storefront.sync() }
            guard session == generation else { return }
            await refresh()
            guard session == generation else { return }
            if let issue = state.issue { notice = .failed(issue) }
            else if state.hasPaidAccess(context: context, now: clock()) { notice = .restored }
            else { notice = .failed(.unavailable) }
        } catch {
            guard session == generation else { return }
            notice = .failed(failure(error))
        }
    }

    /// Named seats are service mutations. They never grant the current-shop role or budget scope.
    func replaceSeat(userID: String?, replacingUserID: String?) async {
        guard !isBusy, canManageSeats, let context, let snapshot = state.snapshot else { return }
        isBusy = true
        let session = generation
        defer { isBusy = false }
        do {
            let updated = try await service.replaceSeat(userID: userID, replacingUserID: replacingUserID,
                context: context, revision: snapshot.revision)
            guard session == generation else { return }
            try state.accept(updated, context: context, now: clock())
        } catch {
            guard session == generation else { return }
            _ = reject(failure(error))
        }
    }

    // External observer/reconciliation/direct callbacks are not the return value
    // of the model-owned purchase call. Preserve rejection evidence separately.
    private enum OutcomeOrigin { case callback, purchase }
    @discardableResult func receive(_ outcome: MembershipPurchaseOutcome) async -> MembershipFailure? {
        await receive(outcome, origin: .callback)
    }
    @discardableResult private func receive(_ outcome: MembershipPurchaseOutcome, origin: OutcomeOrigin) async -> MembershipFailure? {
        guard !isStopped else { return nil }
        switch outcome {
        case .pending: notice = .pending; return nil
        case .cancelled: notice = .cancelled; return nil
        case .unverified: return rejectOutcome(.unverified, origin: origin)
        case .verified(let transaction): return await deliver(transaction, origin: origin)
        }
    }
    private func rejectOutcome(_ issue: MembershipFailure, origin: OutcomeOrigin) -> MembershipFailure {
        switch origin {
        case .callback:
            if !callbackRejections.contains(issue) { callbackRejections.append(issue) }
        case .purchase: purchaseRejection = issue
        }
        return reject(issue)
    }

    private func reject(_ issue: MembershipFailure) -> MembershipFailure {
        state.fail(issue)
        notice = .failed(issue)
        if issue == .signInRequired || issue == .membershipInactive { eligibleAdults = [] }
        return issue
    }

    private func deliver(_ transaction: SignedMembershipTransaction, origin: OutcomeOrigin) async -> MembershipFailure? {
        guard let context else { return rejectOutcome(.signInRequired, origin: origin) }
        guard context.appAccountToken != nil else { return rejectOutcome(.notPurchaser, origin: origin) }
        guard transaction.productID == configuration.productID else { return rejectOutcome(.unverified, origin: origin) }
        // Older purchases without a token are server-reconciled; mismatched tokens are never rebound.
        if let token = transaction.appAccountToken, token != context.appAccountToken {
            return rejectOutcome(.accountMismatch, origin: origin)
        }
        guard inFlightTransactions.insert(transaction.transactionID).inserted else { return nil }
        deliveryOutcomes[transaction.transactionID] = .inFlight
        let session = generation
        defer { inFlightTransactions.remove(transaction.transactionID) }
        do {
            let receipt = try await service.submit(transaction, context: context)
            guard session == generation else { return nil }
            guard receipt.durable, receipt.acceptedTransactionID == transaction.transactionID,
                  receipt.snapshot.purchaserID == context.purchaserID else { throw MembershipFailure.invalidReceipt }
            try state.accept(receipt.snapshot, context: context, now: clock())
            // Server commit is durable before finish; failed delivery remains in Transaction.unfinished.
            await storefront.finish(transactionID: transaction.transactionID)
            guard session == generation else { return nil }
            deliveryOutcomes[transaction.transactionID] = .delivered
            notice = .delivered
            if canManageSeats, let adults = try? await service.seatCandidates(context: context), session == generation {
                eligibleAdults = adults.filter { $0.isAdult }
            }
            return nil
        } catch {
            guard session == generation else { return nil }
            let issue = failure(error)
            deliveryOutcomes[transaction.transactionID] = .failed(issue)
            return reject(issue)
        }
    }

    private func failure(_ error: Error) -> MembershipFailure { error as? MembershipFailure ?? .deliveryPending }
}
