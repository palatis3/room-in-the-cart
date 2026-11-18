import Foundation
import HouseholdClient

protocol GuardianChildDeletionServing: Sendable {
    func guardianDeletionChildren(subject: String, householdID: String, memberID: String) async throws -> [GuardianDeletionChild]
    func guardianDeletionReview(subject: String, householdID: String, memberID: String, child: GuardianDeletionChild, childSignInEmail: String) async throws -> GuardianDeletionReview
    func deleteGuardianChildAccount(_ request: GuardianDeletionRequest) async throws -> DeletionStatus
    func deletionStatus(_ receipt: DeletionReceipt) async throws -> DeletionStatus
}
extension HouseholdService: GuardianChildDeletionServing {}

@MainActor final class GuardianChildDeletionModel: ObservableObject {
    private let scope: GuardianRuntimeScope
    private let service: any GuardianChildDeletionServing
    private let store: GuardianDeletionReceipts
    private let runtime: () -> GuardianRuntimeScope?
    private var generation = UUID()
    @Published private(set) var children: [GuardianDeletionChild]?
    @Published private(set) var review: GuardianDeletionReview?
    @Published private(set) var receipts: [GuardianDeletionRequest] = []
    @Published private(set) var statuses: [UUID: DeletionStatus] = [:]
    @Published private(set) var missing: Set<UUID> = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var needsSignIn = false

    init(scope: GuardianRuntimeScope, service: any GuardianChildDeletionServing, vault: any RefreshTokenVault,
         runtime: @escaping () -> GuardianRuntimeScope?) {
        self.scope = scope
        self.service = service
        self.store = GuardianDeletionReceipts(vault: vault)
        self.runtime = runtime
    }

    var live: Bool { runtime() == scope }
    private func current(_ start: UUID) -> Bool { live && generation == start }

    func clear() {
        generation = UUID()
        children = nil
        review = nil
        receipts = []
        statuses = [:]
        missing = []
        busy = false
        message = nil
        needsSignIn = false
    }

    func load() async {
        guard live, !busy else { return }
        let start = generation
        busy = true
        review = nil
        children = nil
        message = nil
        needsSignIn = false
        defer { if current(start) { busy = false } }
        do {
            receipts = try store.saved(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID)
            let result = try await service.guardianDeletionChildren(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID)
            guard current(start) else { return }
            children = result
        } catch { if current(start) { describe(error) } }
    }

    func canReview(_ child: GuardianDeletionChild) -> Bool {
        live && !busy && children?.contains(child) == true &&
            !receipts.contains { $0.review.enrollmentId == child.id && !missing.contains($0.id) }
    }

    func select(_ child: GuardianDeletionChild, email: String) async {
        guard canReview(child), GuardianChildSignInEmail.isValid(email) else { return }
        let start = generation
        busy = true
        review = nil
        message = nil
        defer { if current(start) { busy = false } }
        do {
            let result = try await service.guardianDeletionReview(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, child: child, childSignInEmail: email)
            guard current(start) else { return }
            guard let expiry = result.expiry, expiry > Date() else { throw ClientError.service(status: 409, code: "review_expired", correlationID: nil, retryAfter: nil) }
            review = result
        } catch { if current(start) { describe(error) } }
    }

    func cancelReview() { review = nil }

    func submit(_ confirmed: GuardianDeletionReview) async {
        guard live, !busy, review == confirmed else { return }
        let start = generation
        busy = true
        review = nil
        message = nil
        defer { if current(start) { busy = false } }
        guard let expiry = confirmed.expiry, expiry > Date() else {
            message = GuardianCopy.text("The review expired. Select the child again before confirming.")
            return
        }
        let saved: GuardianDeletionRequest
        do {
            saved = try store.prepare(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, review: confirmed)
            receipts.removeAll { $0.id == saved.id }
            receipts.append(saved)
            missing.remove(saved.id)
        } catch {
            message = GuardianCopy.text("The request was not sent. Unlock this phone so it can save the child’s deletion receipt.")
            return
        }
        do {
            let status = try await service.deleteGuardianChildAccount(saved)
            guard current(start) else { return }
            statuses[saved.id] = status
            children?.removeAll { $0.id == confirmed.enrollmentId }
        } catch { if current(start) { describe(error) } }
    }

    func check(_ request: GuardianDeletionRequest) async {
        guard live, !busy, receipts.contains(where: { $0.id == request.id }) else { return }
        let start = generation
        busy = true
        review = nil
        message = nil
        defer { if current(start) { busy = false } }
        do {
            let status = try await service.deletionStatus(request.receipt)
            guard current(start) else { return }
            statuses[request.id] = status
            missing.remove(request.id)
            children?.removeAll { $0.id == request.review.enrollmentId }
        } catch ClientError.service(404, _, _, _) {
            guard current(start) else { return }
            missing.insert(request.id)
            message = GuardianCopy.text("No status is available for this receipt. It may have expired or the request may not have arrived. Check again, or refresh and review the child’s account again.")
        } catch {
            if current(start) { message = GuardianCopy.text("The receipt is saved on this phone. Check deletion status again when you can connect.") }
        }
    }

    func forget(_ request: GuardianDeletionRequest) {
        guard live, !busy, receipts.contains(where: { $0.id == request.id }),
              statuses[request.id]?.status == .complete || missing.contains(request.id) else { return }
        do {
            try store.remove(request)
            receipts.removeAll { $0.id == request.id }
            statuses.removeValue(forKey: request.id)
            missing.remove(request.id)
        } catch { message = ht("Unlock this phone and try reading the deletion receipt again.") }
    }

    private func describe(_ error: Error) {
        switch error as? ClientError {
        case .sessionNeeded:
            needsSignIn = true
            children = nil
            message = GuardianCopy.text("Sign in to your guardian account with a new email code, open this household, and review the child’s account within five minutes.")
        case .accessEnded, .service(404, _, _, _), .service(409, _, _, _):
            children = nil
            message = GuardianCopy.text("The service could not verify this child account and your authority to delete it. Check any saved receipt, then refresh the list.")
        case .service(_, "deletion_unavailable", _, _):
            message = ht("Account deletion is currently unavailable. Check again later.")
        default:
            message = ht("The service could not confirm this action. Check any saved receipt before trying again.")
        }
    }
}

protocol GuardianManualReviewServing: Sendable {
    func guardianManualReviews(subject: String, householdID: String, memberID: String) async throws -> GuardianManualReviewPage
    func requestGuardianManualReview(_ key: GuardianManualReviewKey, childSignInEmail: String) async throws -> GuardianManualReviewCase
}
extension HouseholdService: GuardianManualReviewServing {}

@MainActor final class GuardianManualReviewModel: ObservableObject {
    let scope: GuardianRuntimeScope
    private let service: any GuardianManualReviewServing
    private let keys: GuardianManualReviewKeys
    private let runtime: () -> GuardianRuntimeScope?
    private var generation = UUID()
    @Published private(set) var children: [GuardianManualReviewChild] = []
    @Published private(set) var cases: [GuardianManualReviewCase] = []
    @Published private(set) var available: Bool?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published private(set) var needsSignIn = false

    init(scope: GuardianRuntimeScope, service: any GuardianManualReviewServing, vault: any RefreshTokenVault,
         runtime: @escaping () -> GuardianRuntimeScope?) {
        self.scope = scope
        self.service = service
        keys = GuardianManualReviewKeys(vault: vault)
        self.runtime = runtime
    }

    var live: Bool { runtime() == scope }
    private func current(_ start: UUID) -> Bool { live && generation == start }

    func clear() {
        generation = UUID()
        children = []
        cases = []
        available = nil
        message = nil
        needsSignIn = false
        busy = false
    }

    func refresh() async {
        guard live, !busy else { return }
        clear()
        let start = generation
        busy = true
        defer { if current(start) { busy = false } }
        do {
            let page = try await service.guardianManualReviews(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID)
            guard current(start) else { return }
            cases = page.requests
            try keys.received(Set(cases.map(\.id)), subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID)
            children = page.children
            available = page.available
        } catch { if current(start) { describe(error) } }
    }

    func submit(child: GuardianManualReviewChild, email: String) async {
        guard live, !busy, available == true, children.contains(child), GuardianChildSignInEmail.isValid(email) else { return }
        let start = generation
        busy = true
        message = nil
        defer { if current(start) { busy = false } }
        let key: GuardianManualReviewKey
        do {
            key = try keys.prepare(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, enrollmentID: child.id)
        } catch {
            message = GuardianCopy.text("The review request was not sent. Unlock this phone and try again.")
            return
        }
        do {
            let result = try await service.requestGuardianManualReview(key, childSignInEmail: email)
            guard current(start) else { return }
            cases.removeAll { $0.id == result.id }
            cases.insert(result, at: 0)
            children.removeAll { $0.id == child.id }
            try keys.received([result.id], subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID)
        } catch ClientError.service(409, "key_reused", _, _) {
            guard current(start) else { return }
            // A definitively rejected key cannot recover a current case. Refresh before a new explicit submission.
            do {
                try keys.received([key.id], subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID)
                available = nil
                children = []
                message = GuardianCopy.text("This review request has expired or changed. Refresh your cases before opening a new one.")
            } catch { describe(error) }
        } catch { if current(start) { describe(error) } }
    }

    private func describe(_ error: Error) {
        available = nil
        children = []
        switch error as? ClientError {
        case .sessionNeeded:
            needsSignIn = true
            message = GuardianCopy.text("Sign in to your guardian account with a new email code, then open this household to request a private review.")
        case .accessEnded, .service(404, _, _, _):
            message = GuardianCopy.text("The service could not verify this guardian and child account together. Refresh the list after checking the child’s approved sign-in.")
        case .service(409, "review_already_requested", _, _):
            message = GuardianCopy.text("A private review has already been requested. Refresh to see your cases.")
        default:
            message = GuardianCopy.text("The service could not confirm the review request. Refresh your cases before trying again.")
        }
    }
}
