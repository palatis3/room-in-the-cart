import Foundation
import SwiftUI

@MainActor final class MembershipModel: ObservableObject {
    @Published private(set) var state = MembershipState()
    @Published private(set) var offer: MembershipOffer?
    @Published private(set) var isBusy = false
    @Published private(set) var notice: Notice?
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

    enum Notice: Equatable { case pending, cancelled, restored, delivered, failed(MembershipFailure) }

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
    var canPurchase: Bool { !isStopped && configuration.isReady && context?.appAccountToken != nil && offer != nil && !isBusy }

    /// Retain at app scope; calling this from a settings screen as well is idempotent.
    func start() async {
        guard !started, !isStopped else { return }
        started = true
        let session = generation
        await loadOffer()
        guard session == generation else { return }
        if context?.appAccountToken != nil {
            let stream = storefront.updates()
            updatesTask = Task { [weak self] in
                for await outcome in stream {
                    guard !Task.isCancelled, let self, session == self.generation else { break }
                    await self.receive(outcome)
                }
            }
        }
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
        offer = nil
        inFlightTransactions.removeAll()
    }

    func loadOffer() async {
        guard !isStopped else { return }
        guard let id = configuration.productID else { notice = .failed(.notConfigured); return }
        let session = generation
        do {
            let loaded = try await storefront.load(productID: id)
            guard session == generation else { return }
            offer = loaded
        } catch {
            guard session == generation else { return }
            offer = nil; notice = .failed(.unavailable)
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
        do {
            let result = try await storefront.purchase(appAccountToken: appAccountToken)
            guard session == generation else { return }
            await receive(result)
        } catch {
            guard session == generation else { return }
            notice = .failed(error as? MembershipFailure ?? .unavailable)
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

    // Internal for deterministic tests of callbacks without Apple account UI.
    @discardableResult func receive(_ outcome: MembershipPurchaseOutcome) async -> MembershipFailure? {
        guard !isStopped else { return nil }
        switch outcome {
        case .pending: notice = .pending; return nil
        case .cancelled: notice = .cancelled; return nil
        case .unverified: return reject(.unverified)
        case .verified(let transaction): return await deliver(transaction)
        }
    }

    private func reject(_ issue: MembershipFailure) -> MembershipFailure {
        state.fail(issue)
        notice = .failed(issue)
        if issue == .signInRequired || issue == .membershipInactive { eligibleAdults = [] }
        return issue
    }

    private func deliver(_ transaction: SignedMembershipTransaction) async -> MembershipFailure? {
        guard let context else { return reject(.signInRequired) }
        guard context.appAccountToken != nil else { return reject(.notPurchaser) }
        guard transaction.productID == configuration.productID else { return reject(.unverified) }
        // Older purchases without a token are server-reconciled; mismatched tokens are never rebound.
        if let token = transaction.appAccountToken, token != context.appAccountToken {
            return reject(.accountMismatch)
        }
        guard inFlightTransactions.insert(transaction.transactionID).inserted else { return nil }
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
            notice = .delivered
            if canManageSeats, let adults = try? await service.seatCandidates(context: context), session == generation {
                eligibleAdults = adults.filter { $0.isAdult }
            }
            return nil
        } catch {
            guard session == generation else { return nil }
            return reject(failure(error))
        }
    }

    private func failure(_ error: Error) -> MembershipFailure { error as? MembershipFailure ?? .deliveryPending }
}
