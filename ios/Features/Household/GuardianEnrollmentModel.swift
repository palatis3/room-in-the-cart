import Foundation
import Combine
import HouseholdClient

struct GuardianRuntimeScope: Equatable {
    let subject: String
    let householdID: String
    let memberID: String
    let generation: UUID
    let enrollmentRevision: UUID
    func matches(_ intent: GuardianEnrollmentIntent) -> Bool {
        intent.subject == subject && intent.householdID == householdID && intent.memberID == memberID
    }
}

protocol GuardianEnrollmentServing: Sendable {
    func guardianNotice(language: GuardianLanguage) async throws -> GuardianNoticeResponse
    func guardianEnrollments() async throws -> [GuardianEnrollment]
    func guardianEnrollment(enrollmentID: String) async throws -> GuardianEnrollment
    func prepareGuardianEnrollment(notice: GuardianNotice, childLocation: String, childID: String?, guardianDeclaration: Bool) async throws -> GuardianEnrollmentIntent
    func prepareGuardianVerification(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent
    func prepareGuardianConsent(enrollment: GuardianEnrollment, notice: GuardianNotice, childAlias: String, childSignInEmail: String) async throws -> GuardianEnrollmentIntent
    func prepareGuardianChildInvitation(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent
    func prepareGuardianChildConfirmation(enrollment: GuardianEnrollment, claimID: String, pairingCode: String) async throws -> GuardianEnrollmentIntent
    func prepareGuardianCancellation(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent
    func authorizeGuardianEnrollment(_ intent: GuardianEnrollmentIntent) async throws
    func executeGuardianEnrollment(_ intent: GuardianEnrollmentIntent) async throws -> GuardianEnrollment
    func executeGuardianChildInvitation(_ intent: GuardianEnrollmentIntent) async throws -> GuardianChildInvitation
}
extension HouseholdService: GuardianEnrollmentServing {}

/// Keeps reviewed, exact retry bytes apart from basket commands. A local result never grants access.
@MainActor final class GuardianEnrollmentModel: ObservableObject {
    let scope: GuardianRuntimeScope
    private let service: any GuardianEnrollmentServing
    private let store: GuardianIntentStore
    private let runtime: () -> GuardianRuntimeScope?
    private var generation = UUID()
    private var epoch: UUID?
    private var savedCandidate: GuardianEnrollmentIntent?
    private var retryNotBefore = Date.distantPast
    private var attempts = 0
    @Published private(set) var availability: GuardianNoticeResponse?
    @Published private(set) var enrollments: [GuardianEnrollment] = []
    @Published private(set) var selected: GuardianEnrollment?
    @Published private(set) var pending: GuardianEnrollmentIntent?
    @Published private(set) var hasPending = false
    @Published private(set) var invitation: GuardianChildInvitation?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var language: GuardianLanguage = Locale.current.language.languageCode?.identifier == "es" ? .es : .en
    @Published var noticeReviewed = false
    @Published var guardianDeclaration = false
    @Published var grantReviewed = false
    @Published var childLocation = ""
    @Published var childAlias = ""
    @Published var pairingCode = ""
    @Published var childSignInEmail = ""

    init(scope: GuardianRuntimeScope, service: any GuardianEnrollmentServing, store: GuardianIntentStore,
         runtime: @escaping () -> GuardianRuntimeScope?) {
        self.scope = scope; self.service = service; self.store = store; self.runtime = runtime
    }
    var live: Bool { runtime() == scope }
    var available: Bool { live && availability?.available == true && availability?.notice != nil }
    var canStart: Bool { available && !busy && !hasPending && epoch != nil && noticeReviewed && guardianDeclaration && !childLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canGrant: Bool {
        guard available, !busy, !hasPending, let selected, let notice = availability?.notice,
              selected.state.rawValue == "verified", selected.noticeDigest == notice.digest, selected.noticeVersion == notice.version else { return false }
        return noticeReviewed && grantReviewed && GuardianChildSignInEmail.isValid(childSignInEmail) && !childAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func invalidate() {
        generation = UUID(); epoch = nil; availability = nil; enrollments = []; selected = nil
        pending = nil; savedCandidate = nil; hasPending = false; invitation = nil; message = nil; busy = false
        noticeReviewed = false; guardianDeclaration = false; grantReviewed = false
        childLocation = ""; childAlias = ""; childSignInEmail = ""; pairingCode = ""
    }
    private func current(_ start: UUID) -> Bool { live && generation == start }
    func load() async {
        guard live, !busy else { return }
        let start = generation, selectedID = selected?.enrollmentId
        busy = true; availability = nil; enrollments = []; selected = nil; pending = nil; invitation = nil; message = nil
        noticeReviewed = false; grantReviewed = false
        defer { if current(start) { busy = false } }
        do {
            let notice = try await service.guardianNotice(language: language)
            guard current(start) else { return }; availability = notice
            let rows = try await service.guardianEnrollments()
            guard current(start) else { return }; enrollments = rows
            selected = rows.first { $0.enrollmentId == selectedID }
            let epoch = await store.epoch(), saved = try await store.read()
            guard current(start) else { return }; self.epoch = epoch
            savedCandidate = saved.first(where: scope.matches); hasPending = savedCandidate != nil
            if let intent = savedCandidate {
                try await service.authorizeGuardianEnrollment(intent)
                guard current(start) else { return }; pending = intent
                if selected == nil { selected = rows.first { $0.enrollmentId == intent.enrollmentID } }
            }
        } catch { await fail(error, start: start) }
    }
    func select(_ value: GuardianEnrollment) {
        guard live, !busy, enrollments.contains(value) else { return }
        selected = value; childAlias = value.childAlias ?? ""; childSignInEmail = ""; pairingCode = ""; grantReviewed = false; invitation = nil
    }
    func start() async {
        guard canStart, let notice = availability?.notice else { return }
        await perform { try await self.service.prepareGuardianEnrollment(notice: notice,
            childLocation: self.childLocation.trimmingCharacters(in: .whitespacesAndNewlines), childID: nil, guardianDeclaration: true) }
    }
    func requestVerification() async {
        guard available, let selected, selected.state.rawValue == "awaiting_verification" else { return }
        await perform { try await self.service.prepareGuardianVerification(enrollment: selected) }
    }
    func grantPermission() async {
        guard canGrant, let selected, let notice = availability?.notice else { return }
        let alias = childAlias.trimmingCharacters(in: .whitespacesAndNewlines), email = childSignInEmail
        await perform { try await self.service.prepareGuardianConsent(enrollment: selected, notice: notice, childAlias: alias, childSignInEmail: email) }
    }
    func createInvitation() async {
        guard available, let selected, selected.state.rawValue == "consented" else { return }
        await perform { try await self.service.prepareGuardianChildInvitation(enrollment: selected) }
    }
    func confirmChild() async {
        guard available, let selected, selected.state.rawValue == "child_claimed", let claimID = selected.claimId,
              !pairingCode.isEmpty else { return }
        let code = pairingCode
        await perform { try await self.service.prepareGuardianChildConfirmation(enrollment: selected, claimID: claimID, pairingCode: code) }
    }
    func cancelEnrollment() async {
        guard let selected, !["active", "cancelled", "expired", "withdrawn"].contains(selected.state.rawValue) else { return }
        await perform { try await self.service.prepareGuardianCancellation(enrollment: selected) }
    }
    private func perform(_ prepare: () async throws -> GuardianEnrollmentIntent) async {
        guard live, !busy, !hasPending, let epoch else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await prepare()
            guard current(start), scope.matches(intent) else { return }
            try await store.save(intent, expectedEpoch: epoch)
            guard current(start) else { return }
            pending = intent; savedCandidate = intent; hasPending = true; attempts = 0
            try await deliver(intent, epoch: epoch, start: start)
        } catch { await fail(error, start: start) }
    }
    func retry() async {
        guard live, !busy, let pending, let epoch else { return }
        guard Date() >= retryNotBefore, attempts < 5 else { message = GuardianCopy.text("Wait before retrying. Check current setup status after several attempts."); return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do { try await deliver(pending, epoch: epoch, start: start) } catch { await fail(error, start: start) }
    }
    private func deliver(_ intent: GuardianEnrollmentIntent, epoch: UUID, start: UUID) async throws {
        try await service.authorizeGuardianEnrollment(intent)
        guard current(start) else { return }; attempts += 1
        if intent.kind == .childInvitation {
            let issued = try await service.executeGuardianChildInvitation(intent)
            guard current(start) else { return }; invitation = issued
            // Retain the exact random secret until the guardian explicitly finishes sharing.
            // A restart can recover this same invitation by an authorized exact retry.
            message = GuardianCopy.text("Share this invitation with the intended child's device. Keep it private.")
        } else {
            let value = try await service.executeGuardianEnrollment(intent)
            guard current(start) else { return }
            try await store.complete(id: intent.id, expectedEpoch: epoch)
            guard current(start) else { return }
            pending = nil; savedCandidate = nil; hasPending = false; selected = value
            enrollments.removeAll { $0.enrollmentId == value.enrollmentId }; enrollments.append(value)
            pairingCode = ""; childSignInEmail = ""; grantReviewed = false; guardianDeclaration = false
            message = GuardianCopy.text("Setup status confirmed by the household service.")
        }
    }
    /// A fresh status read precedes any deliberate local retry retirement. This never cancels a server action.
    func clearRetryAfterStatusReview() async {
        guard live, !busy, let intent = pending ?? savedCandidate, let epoch else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            let rows = try await service.guardianEnrollments()
            guard current(start) else { return }
            try await store.complete(id: intent.id, expectedEpoch: epoch)
            guard current(start) else { return }
            enrollments = rows
            if let selected { self.selected = rows.first { $0.enrollmentId == selected.enrollmentId } }
            pending = nil; savedCandidate = nil; hasPending = false; invitation = nil
            message = GuardianCopy.text("Local retry cleared after checking status. A setup or permission already saved by the service is unchanged.")
        } catch { await fail(error, start: start) }
    }
    private func fail(_ error: Error, start: UUID) async {
        guard current(start) else { return }
        if let value = error as? ClientError, let delay = RetryPolicy().delay(attempt: attempts, error: value) {
            retryNotBefore = Date().addingTimeInterval(delay)
        }
        switch error as? ClientError {
        case .sessionNeeded, .accessEnded:
            try? await store.purge(householdID: scope.householdID, subject: scope.subject)
            guard current(start) else { return }; epoch = nil; savedCandidate = nil; hasPending = false
            availability = nil; enrollments = []; selected = nil; pending = nil; invitation = nil
            childAlias = ""; childSignInEmail = ""; pairingCode = ""; noticeReviewed = false; grantReviewed = false
            message = GuardianCopy.text("Guardian access must be checked again. Unlock your household account.")
        case .service(let status, let code, _, _):
            if status == 403 || status == 404 {
                try? await store.purge(householdID: scope.householdID, subject: scope.subject)
                guard current(start) else { return }; epoch = nil; savedCandidate = nil; hasPending = false
                availability = nil; enrollments = []; selected = nil; pending = nil; invitation = nil; childAlias = ""; childSignInEmail = ""; pairingCode = "" }
            if code.contains("unavailable") || code.contains("configuration") || code.contains("notice_approval") {
                availability = nil; message = GuardianCopy.text("Child setup is unavailable until the verification service and current notices are approved.")
            } else if status == 409 {
                message = GuardianCopy.text("Setup changed. Refresh and review the current notice and status before a new action.")
            } else { message = GuardianCopy.text("The service could not confirm this setup action. Keep the exact retry and check status.") }
        case .cancelled: break
        default: message = GuardianCopy.text("The service could not confirm this setup action. Keep the exact retry and check status.")
        }
    }
}
