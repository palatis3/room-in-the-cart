import Foundation
import Combine
import HouseholdClient

struct SharedMealChangeScope: Hashable {
    let generation: UUID; let enrollmentRevision: UUID?
    let subject: String; let householdID: String; let memberID: String; let shopID: UUID; let authorityStamp: String
    init(subject: String, householdID: String, memberID: String, shopID: UUID, authorityStamp: String, generation: UUID = UUID(), enrollmentRevision: UUID? = nil) {
        self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.shopID = shopID
        self.authorityStamp = authorityStamp; self.generation = generation; self.enrollmentRevision = enrollmentRevision
    }
    func matches(_ value: SharedMealChangeIntent) -> Bool {
        value.subject == subject && value.householdID == householdID && value.memberID == memberID && value.shopID == shopID
    }
}
protocol SharedMealChangesServing: Sendable {
    func prepareNewSharedMealChange(shopID: UUID, idea: SharedMealIdeaPage.Idea, day: String) async throws -> SharedMealChangeIntent
    func sharedMealChanges(shopID: UUID) async throws -> SharedMealChangePage
    func prepareSharedMealChange(page: SharedMealChangePage, occurrenceID: UUID, meal: SharedMeal, reason: String) async throws -> SharedMealChangeIntent
    func authorizeSharedMealChange(_ intent: SharedMealChangeIntent) async throws
    func executeSharedMealChange(_ intent: SharedMealChangeIntent) async throws
    func dismissSharedMealChange(_ proposal: SharedMealChangePage.Proposal, page: SharedMealChangePage) async throws
}
extension SharedMealChangesServing {
    func prepareNewSharedMealChange(shopID: UUID, idea: SharedMealIdeaPage.Idea, day: String) async throws -> SharedMealChangeIntent { throw ClientError.configuration }
}
extension HouseholdService: SharedMealChangesServing {}

@MainActor final class SharedMealChangeModel: ObservableObject {
    let scope: SharedMealChangeScope
    private let service: any SharedMealChangesServing
    private let store: HistoryPendingStore
    private let runtime: () -> SharedMealChangeScope?
    private var generation = UUID()
    private var epoch: UUID?
    private var confirmed = Set<UUID>()
    private var savedCandidate: SharedMealChangeIntent?
    @Published private(set) var page: SharedMealChangePage?
    @Published private(set) var review: SharedMealChangeIntent?
    @Published private(set) var pending: SharedMealChangeIntent?
    @Published private(set) var hasPending = false
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    init(scope: SharedMealChangeScope, service: any SharedMealChangesServing, store: HistoryPendingStore, runtime: @escaping () -> SharedMealChangeScope?) {
        self.scope = scope; self.service = service; self.store = store; self.runtime = runtime
    }
    var live: Bool { runtime() == scope }
    var canPropose: Bool { live && !busy && !hasPending && epoch != nil && page?.shopper == false }
    func invalidate() { generation = UUID(); page = nil; review = nil; pending = nil; epoch = nil; hasPending = false; savedCandidate = nil; busy = false; notice = nil; confirmed = [] }
    func cancelReview() { review = nil }
    private func current(_ start: UUID) -> Bool { live && generation == start }
    func load() async {
        guard live, !busy else { return }
        let start = generation; busy = true; page = nil; review = nil; pending = nil; notice = nil
        defer { if current(start) { busy = false } }
        do {
            let epoch = await store.epoch(), state = try await store.read()
            guard current(start) else { return }
            self.epoch = epoch; savedCandidate = state.sharedMealChanges?.first(where: scope.matches); hasPending = savedCandidate != nil
            let value = try await service.sharedMealChanges(shopID: scope.shopID)
            guard current(start) else { return }; page = value
            if let saved = state.sharedMealChanges?.first(where: scope.matches) {
                try await service.authorizeSharedMealChange(saved)
                guard current(start) else { return }; pending = saved
            }
        } catch { fail(error, start: start) }
    }
    func prepare(occurrenceID: UUID, meal: SharedMeal, reason: String) async {
        guard canPropose, let page else { return }
        let start = generation; busy = true; review = nil; notice = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: occurrenceID, meal: meal, reason: reason)
            guard current(start), scope.matches(intent) else { return }; review = intent
        } catch { fail(error, start: start) }
    }
    func prepareNew(idea: SharedMealIdeaPage.Idea, day: String) async {
        guard live, !busy, !hasPending, epoch != nil else { return }
        let start = generation; busy = true; review = nil; notice = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await service.prepareNewSharedMealChange(shopID: scope.shopID, idea: idea, day: day)
            guard current(start), scope.matches(intent) else { return }; review = intent
        } catch { fail(error, start: start) }
    }
    func sendReviewed() async {
        guard live, !busy, !hasPending, let review, let epoch else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do {
            try await store.stageMealChange(review, expectedEpoch: epoch)
            guard current(start) else { return }; pending = review; savedCandidate = review; hasPending = true; self.review = nil
            try await deliver(review, epoch: epoch, start: start)
        } catch { fail(error, start: start) }
    }
    func retry() async {
        guard live, !busy, let pending, let epoch else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do { try await deliver(pending, epoch: epoch, start: start) } catch { fail(error, start: start) }
    }
    private func deliver(_ intent: SharedMealChangeIntent, epoch: UUID, start: UUID) async throws {
        if !confirmed.contains(intent.id) {
            try await service.executeSharedMealChange(intent)
            guard current(start) else { return }; confirmed.insert(intent.id)
        }
        try await store.finishMealChange(intent, expectedEpoch: epoch)
        guard current(start) else { return }
        pending = nil; savedCandidate = nil; review = nil; hasPending = false
        notice = ht("Proposal saved to the household. The meal and basket are unchanged until shopper review.")
        let updated = try await service.sharedMealChanges(shopID: scope.shopID)
        guard current(start) else { return }; page = updated
    }
    func clearPendingAfterStatusReview() async {
        guard live, !busy, let pending = pending ?? savedCandidate, scope.matches(pending), let epoch else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do {
            // Fresh current actor access is required for local cleanup. The old device/role is
            // required only for transmission, so reenrollment cannot permanently trap a retry.
            let latest = try await service.sharedMealChanges(shopID: scope.shopID)
            guard current(start) else { return }
            try await store.finishMealChange(pending, expectedEpoch: epoch)
            guard current(start) else { return }; self.pending = nil; savedCandidate = nil; hasPending = false; page = latest
            notice = ht("Local retry cleared after checking shared status. This does not withdraw or undo a shared proposal.")
        } catch { fail(error, start: start) }
    }
    func reviewedEdit(_ proposal: SharedMealChangePage.Proposal) async -> SharedMealEdit? {
        guard live, !busy, let page, page.shopper, proposal.isCurrent(in: page) else { return nil }
        let start = generation; busy = true; notice = nil
        defer { if current(start) { busy = false } }
        do {
            let latest = try await service.sharedMealChanges(shopID: scope.shopID)
            guard current(start), latest.shopper, latest.proposals.contains(proposal), proposal.isCurrent(in: latest) else { throw ClientError.configuration }
            self.page = latest
            var edit = SharedMealEdit(occurrenceID: proposal.request.occurrenceId, meal: proposal.request.meal, changeProposalID: proposal.id)
            edit.baseMealRevision = proposal.request.baseMealRevision
            return edit
        } catch { fail(error, start: start); return nil }
    }
    /// The assigned shopper reviews their own local evidence directly; no planner impersonation or proposal POST.
    func reviewedShopperSeed(occurrenceID: UUID, meal: SharedMeal) async -> SharedMealEdit? {
        guard live, !busy, !hasPending, let page, page.shopper, page.phase == "draft",
              let original = page.meals.first(where: { $0.id == occurrenceID }), meal.day == original.meal.day else { return nil }
        let start = generation; busy = true; notice = nil
        defer { if current(start) { busy = false } }
        do {
            try meal.validatePlanning()
            let latest = try await service.sharedMealChanges(shopID: scope.shopID)
            guard current(start), latest.shopper, latest.phase == "draft", latest.shopRevision == page.shopRevision,
                  latest.authorityEpoch == page.authorityEpoch, latest.meals.contains(original) else { throw ClientError.configuration }
            self.page = latest
            var edit = SharedMealEdit(occurrenceID: occurrenceID, meal: meal)
            edit.baseMealRevision = original.revision
            return edit
        } catch { fail(error, start: start); return nil }
    }
    func dismiss(_ proposal: SharedMealChangePage.Proposal) async {
        guard live, !busy, let page, page.shopper else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do {
            try await service.dismissSharedMealChange(proposal, page: page)
            let latest = try await service.sharedMealChanges(shopID: scope.shopID)
            guard current(start) else { return }; self.page = latest
        } catch { fail(error, start: start) }
    }
    private func fail(_ error: Error, start: UUID) {
        guard current(start) else { return }
        review = nil
        if let pending, confirmed.contains(pending.id) {
            notice = ht("The household confirmed this proposal. Saving the local receipt failed; retry cleanup with the same proposal.")
            return
        }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded, .service(status: 404, code: _, correlationID: _, retryAfter: _), .service(status: 403, code: _, correlationID: _, retryAfter: _):
            page = nil; pending = nil; notice = ht("Shared meal access changed. Refresh the household before continuing.")
        default:
            notice = ht("The proposal result is not confirmed. Refresh shared status or retry the exact saved proposal.")
        }
    }
}
