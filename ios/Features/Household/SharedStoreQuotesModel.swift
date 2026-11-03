import Foundation
import Combine
import CoreDomain
import HouseholdClient

struct StoreQuoteScope: Hashable {
    let generation: UUID; let enrollmentRevision: UUID
    let subject: String; let householdID: String; let memberID: String; let shopID: UUID; let authorityStamp: String
    func matches(_ value: StoreQuoteIntent) -> Bool {
        value.context.subject == subject && value.context.householdID == householdID && value.context.memberID == memberID && value.shopID == shopID
    }
}
protocol SharedStoreQuotesServing: Sendable {
    func storeQuotes(shopID: UUID, cursor: UUID?) async throws -> StoreQuotePage
    func prepareStoreQuote(shopID: UUID, action: StoreQuoteAction, request: StoreQuoteWrite) async throws -> StoreQuoteIntent
    func authorizeStoreQuote(_ intent: StoreQuoteIntent) async throws
    func executeStoreQuote(_ intent: StoreQuoteIntent) async throws -> StoreQuoteReceipt
}
extension HouseholdService: SharedStoreQuotesServing {}

/// This model never receives the device-private ledger, paid access, or a meal-planning grant.
@MainActor final class SharedStoreQuotesModel: ObservableObject {
    let scope: StoreQuoteScope
    private let service: any SharedStoreQuotesServing
    private let store: StoreQuotesPendingStore
    private let runtime: () -> StoreQuoteScope?
    private var generation = UUID()
    private var epoch: UUID?
    private var confirmed = Set<UUID>()
    @Published private(set) var page: StoreQuotePage?
    @Published private(set) var pairs: [StoreQuotePage.Pair] = []
    @Published private(set) var review: StoreQuoteIntent?
    @Published private(set) var pending: StoreQuoteIntent?
    @Published private(set) var hasPending = false
    @Published private(set) var busy = false
    @Published private(set) var authorized = true
    @Published private(set) var notice: String?
    init(scope: StoreQuoteScope, service: any SharedStoreQuotesServing, store: StoreQuotesPendingStore, runtime: @escaping () -> StoreQuoteScope?) {
        self.scope = scope; self.service = service; self.store = store; self.runtime = runtime
    }
    var live: Bool { authorized && runtime() == scope }
    var canPrepare: Bool { live && !busy && !hasPending && epoch != nil && page?.phase == "draft" }
    var canManageGrants: Bool { live && !busy && !hasPending && epoch != nil && page?.shopper == true }
    func invalidate() {
        generation = UUID(); page = nil; pairs = []; review = nil; pending = nil; hasPending = false; epoch = nil; busy = false; notice = nil; confirmed = []
    }
    func cancelReview() { review = nil }
    private func current(_ start: UUID) -> Bool { live && generation == start }
    func load(more: Bool = false) async {
        guard live, !busy else { return }
        let start = generation, prior = page; busy = true; review = nil; notice = nil
        if !more { page = nil; pairs = []; pending = nil }
        defer { if current(start) { busy = false } }
        do {
            let epoch = await store.epoch(), saved = try await store.read()
            guard current(start) else { return }; self.epoch = epoch
            let local = saved.first(where: scope.matches); hasPending = local != nil
            let value = try await service.storeQuotes(shopID: scope.shopID, cursor: more ? prior?.nextCursor : nil)
            guard current(start) else { return }
            try value.validate()
            guard value.shopId == scope.shopID else { throw ClientError.invalidResponse }
            let unchanged = more && prior?.shopRevision == value.shopRevision && prior?.authorityEpoch == value.authorityEpoch && prior?.grantRevision == value.grantRevision
            page = value
            if unchanged { let existing = Set(pairs.map(\.id)); pairs += value.pairs.filter { !existing.contains($0.id) } }
            else { pairs = value.pairs }
            if let local {
                try await service.authorizeStoreQuote(local)
                guard current(start) else { return }; pending = local
            }
        } catch { fail(error, start: start) }
    }
    func prepareSave(_ options: EnteredStoreQuoteOptions) async {
        guard canPrepare, let page, !page.commitments.isEmpty else { return }
        await prepare(.pairs, request: .init(page: page, options: options))
    }
    func prepareSelection(pair: StoreQuotePage.Pair, choice: StoreQuoteChoice, proposalID: UUID? = nil) async {
        guard canPrepare, let page, pairs.contains(pair), pair.current(in: page), pair.comparison.comparable,
              pair.options[choice].available == true, pair.options[choice].eligibilityConfirmed else { return }
        if page.shopper {
            guard pair.own || pair.proposals.contains(where: { $0.id == proposalID && $0.choice == choice }) else { return }
        } else { guard pair.own, proposalID == nil else { return } }
        await prepare(page.shopper ? .adoptions : .proposals, request: .init(page: page, pairId: pair.id, choice: choice, proposalId: proposalID))
    }
    func prepareGrant(_ adult: StoreQuotePage.Adult, enabled: Bool) async {
        guard canManageGrants, let page, page.shopper, page.adults.contains(adult) else { return }
        await prepare(.grants, request: .init(page: page, adultId: adult.id, enabled: enabled, targetRevision: adult.revision))
    }
    private func prepare(_ action: StoreQuoteAction, request: StoreQuoteWrite) async {
        let start = generation; busy = true; review = nil; notice = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await service.prepareStoreQuote(shopID: scope.shopID, action: action, request: request)
            guard current(start), scope.matches(intent) else { return }; review = intent
        } catch { fail(error, start: start) }
    }
    func sendReviewed() async {
        guard live, !busy, !hasPending, let review, let epoch else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do {
            try await store.save(review, expectedEpoch: epoch)
            guard current(start) else { return }; pending = review; hasPending = true; self.review = nil
            try await deliver(review, epoch: epoch, start: start)
        } catch { fail(error, start: start) }
    }
    func retry() async {
        guard live, !busy, let pending, let epoch else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do { try await deliver(pending, epoch: epoch, start: start) } catch { fail(error, start: start) }
    }
    private func deliver(_ intent: StoreQuoteIntent, epoch: UUID, start: UUID) async throws {
        if !confirmed.contains(intent.id) {
            _ = try await service.executeStoreQuote(intent)
            guard current(start) else { return }; confirmed.insert(intent.id)
        }
        try await store.complete(intent, expectedEpoch: epoch)
        guard current(start) else { return }; pending = nil; hasPending = false; review = nil
        let value = try await service.storeQuotes(shopID: scope.shopID, cursor: nil)
        guard current(start) else { return }; page = value; pairs = value.pairs
        switch intent.action {
        case .pairs: notice = StoreQuoteCopy.text("Comparison saved privately for you. Proposing is a separate action.")
        case .proposals: notice = StoreQuoteCopy.text("Proposal sent to the assigned shopper. The shared basket is unchanged.")
        case .adoptions: notice = StoreQuoteCopy.text("Store choice adopted once. Review every item price and checkout charge before freezing the shared shop.")
        case .grants: notice = StoreQuoteCopy.text("This adult's budget access was updated for this shop and shopper assignment.")
        }
    }
    /// Clearing is explicit after a successful current read; it cannot undo an accepted action.
    func clearPendingAfterRefresh() async {
        guard live, !busy, let epoch else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do {
            let value = try await service.storeQuotes(shopID: scope.shopID, cursor: nil)
            guard current(start) else { return }; page = value; pairs = value.pairs
            if let saved = try await store.read().first(where: scope.matches) { try await store.complete(saved, expectedEpoch: epoch) }
            guard current(start) else { return }; pending = nil; hasPending = false
            notice = StoreQuoteCopy.text("Local retry cleared after refreshing. A change already received by the household is preserved.")
        } catch { fail(error, start: start) }
    }
    private func fail(_ error: Error, start: UUID) {
        guard current(start) else { return }
        review = nil
        if let error = error as? ClientError {
            switch error {
            case .accessEnded, .sessionNeeded:
                page = nil; pairs = []; pending = nil; authorized = false; busy = false
            case .service(let status, _, _, _) where [401,403,404].contains(status):
                page = nil; pairs = []; pending = nil; authorized = false; busy = false
            case .service(let status, _, _, _) where status == 409:
                page = nil; pairs = []
            default: break
            }
        }
        notice = StoreQuoteCopy.text("The household result is not confirmed. Refresh access or retry the exact saved action. Changed revisions need a new review.")
    }
}

/// CoreDomain remains the comparison engine for the connected and local screens.
enum SharedStoreQuoteMath {
    static let firstID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let secondID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static func compare(_ options: EnteredStoreQuoteOptions, commitments: [StoreQuotePage.Commitment], shopID: UUID) throws -> TwoStoreQuoteResult {
        try options.validate()
        let same = DinnerCommitmentSet(id: shopID, commitments: try commitments.map {
            DinnerCommitment(id: $0.id, name: $0.label, kind: .staple, portions: try Rational(Int64($0.packs)), protected: false)
        })
        func option(_ source: EnteredStoreQuote, id: UUID) throws -> StoreQuoteOption {
            let context = CheckoutContext(storeID: source.store, branchID: source.branch, mode: ShoppingMode(rawValue: source.mode)!, slot: source.slot,
                commitmentsID: same.id, observedAt: serviceDate(source.observedAt)!, source: source.source)
            let evidence = source.allChargesIncluded ? source.checkoutMinor.map { CostEvidence.exact(Money(minorUnits: Int64($0))) } ?? .unknown(reason: "Checkout total is unknown") : .unknown(reason: "Checkout charges are unreviewed")
            return StoreQuoteOption(id: id, label: source.label, commitments: same,
                quote: CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(evidence)),
                available: source.eligibilityConfirmed ? source.available : nil, quantitiesMatched: source.quantitiesMatched, singleStore: source.singleStore,
                trip: StoreTripEvidence(incrementalCash: source.tripMinor.map { .exact(Money(minorUnits: Int64($0))) } ?? .unknown(reason: "Trip cash is unknown"), extraMinutes: source.extraMinutes, tripAlreadyPlanned: source.tripAlreadyPlanned),
                observedItemSubtotal: source.itemsMinor.map { Money(minorUnits: Int64($0)) }, eligibilityTerms: source.terms.isEmpty ? nil : source.terms)
        }
        let pair = TwoStoreQuotePair(shopID: shopID, baseRevisionID: shopID, basisRevision: 0, first: try option(options.first,id: firstID), second: try option(options.second,id: secondID))
        return try TwoStoreQuoteEngine.evaluateEnteredQuotes(pair)
    }
}

extension SharedStoreQuoteMath {
    static func capAssessment(_ source: EnteredStoreQuote, commitmentsID: UUID) throws -> CheckoutCapAssessment {
        try source.validate()
        let scope: CheckoutScope = source.capScope == "itemsOnly" ? .item : .wholeCheckout
        let context = CheckoutContext(storeID: source.store, branchID: source.branch, mode: ShoppingMode(rawValue: source.mode)!, slot: source.slot,
            commitmentsID: commitmentsID, observedAt: serviceDate(source.observedAt)!, source: source.source)
        let amount = source.capScope == "itemsOnly" ? source.itemsMinor : (source.allChargesIncluded ? source.checkoutMinor : nil)
        let quote = CheckoutQuote(scope: scope, context: context, pricing: .inclusiveTotal(amount.map { .exact(Money(minorUnits: Int64($0))) } ?? .unknown(reason: "Cap basis is unknown")))
        let cap = source.capMinor.map { CheckoutCap(scope: scope, commitmentsID: commitmentsID, amount: Money(minorUnits: Int64($0))) }
        return try CheckoutEngine.evaluate(quote, cap: cap).cap
    }
}
