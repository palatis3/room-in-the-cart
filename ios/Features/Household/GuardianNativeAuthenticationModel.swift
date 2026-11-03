import Foundation
import Combine
import HouseholdClient

protocol GuardianNativeAuthenticating: Sendable {
    func childEnrollmentAvailability(language: GuardianLanguage) async throws -> GuardianAvailabilityResponse
    func prepareNativeAuthentication(token: String, email: String) async throws -> ChildNativeAuthStartIntent
    func startNativeAuthentication(_ intent: ChildNativeAuthStartIntent) async throws -> ChildNativeAuthChallenge
    func prepareNativeAdmission(challenge: ChildNativeAuthChallenge, startIntent: ChildNativeAuthStartIntent) async throws -> ChildNativeAuthAdmitIntent
    func authorizeNativeAdmission(_ intent: ChildNativeAuthAdmitIntent) async throws
    func admitNativeAuthentication(_ intent: ChildNativeAuthAdmitIntent) async throws -> ChildNativeAuthAdmission
    func close() async
}
extension ChildInvitationClient: GuardianNativeAuthenticating {}
protocol GuardianChildIdentityVerifying: Sendable {
    func verifyGuardianChildCode(email: String, code: String) async throws
    func childInvitationAccess() async throws -> ChildInvitationAccess
    func clearLocalSession() async throws
}
extension AdultAuth: GuardianChildIdentityVerifying {
    func verifyGuardianChildCode(email: String, code: String) async throws { _ = try await verifyEmailCode(email: email, code: code) }
}

/// Only the consent-bound service may send an OTP. This model has no direct provider send/sign-up method.
@MainActor final class GuardianNativeAuthenticationModel: ObservableObject {
    private let service: any GuardianNativeAuthenticating
    private let identity: any GuardianChildIdentityVerifying
    private let store: GuardianChildPendingStore
    private let live: () -> Bool
    private let onAdmitted: @MainActor (ChildInvitationAccess, ChildNativeAuthStartIntent, ChildNativeAuthAdmitIntent) async throws -> Void
    private var generation = UUID()
    private var epoch: UUID?
    private var saved = GuardianChildStoredState()
    private var closingTask: Task<Void,Never>?
    @Published var token = ""
    @Published var email = ""
    @Published var code = ""
    @Published private(set) var availability: GuardianAvailabilityResponse?
    @Published private(set) var hasSavedAction = false
    @Published private(set) var challengeReady = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    init(service: any GuardianNativeAuthenticating, identity: any GuardianChildIdentityVerifying,
         store: GuardianChildPendingStore, live: @escaping () -> Bool,
         onAdmitted: @escaping @MainActor (ChildInvitationAccess, ChildNativeAuthStartIntent, ChildNativeAuthAdmitIntent) async throws -> Void) {
        self.service = service; self.identity = identity; self.store = store; self.live = live; self.onAdmitted = onAdmitted
    }
    var canStart: Bool { live() && availability?.available == true && !busy && !hasSavedAction && epoch != nil && !token.isEmpty && GuardianChildSignInEmail.isValid(email) }
    var canVerify: Bool { live() && availability?.available == true && !busy && challengeReady && saved.admission == nil && !code.isEmpty }
    private func current(_ start: UUID) -> Bool { live() && generation == start }
    func invalidate() {
        generation = UUID(); token = ""; email = ""; code = ""; saved = .init(); epoch = nil
        availability = nil; hasSavedAction = false; challengeReady = false; busy = false; message = nil
    }
    func suspend() {
        invalidate(); let predecessor = closingTask
        closingTask = Task { if let predecessor { await predecessor.value }; await service.close() }
    }
    func load() async {
        guard live(), !busy else { return }
        let start = generation; busy = true
        defer { if current(start) { busy = false } }
        do {
            await closingTask?.value; guard current(start) else { return }; closingTask = nil
            let language: GuardianLanguage = Locale.current.language.languageCode?.identifier == "es" ? .es : .en
            let availability = try await service.childEnrollmentAvailability(language: language)
            guard current(start) else { return }; self.availability = availability
            let epoch = await store.epoch(), state = try await store.read()
            guard current(start) else { return }; self.epoch = epoch; saved = state; hasSavedAction = state.authentication != nil
            if !availability.available {
                message = GuardianCopy.text("Child sign-in is unavailable until the covered email service and current notices are approved.")
            } else if hasSavedAction { message = GuardianCopy.text("Resume the same saved sign-in. An uncertain request must not send a new email.") }
        } catch { await fail(error, start: start) }
    }
    func startSignIn() async {
        guard canStart, let epoch else { return }
        let start = generation, token = self.token, email = self.email
        busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await service.prepareNativeAuthentication(token: token, email: email)
            guard current(start) else { return }
            try await store.saveAuthentication(intent, expectedEpoch: epoch)
            guard current(start) else { return }; saved.authentication = intent; hasSavedAction = true; self.token = ""; self.email = ""
            try await restoreChallenge(intent, epoch: epoch, start: start)
        } catch { await fail(error, start: start) }
    }
    func resumeSavedSignIn() async {
        guard live(), availability?.available == true, !busy, let intent = saved.authentication, let epoch else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            try await restoreChallenge(intent, epoch: epoch, start: start)
            guard current(start) else { return }
            if let admission = saved.admission { try await admit(admission, startIntent: intent, start: start) }
        } catch { await fail(error, start: start) }
    }
    private func restoreChallenge(_ intent: ChildNativeAuthStartIntent, epoch: UUID, start: UUID) async throws {
        let challenge = try await service.startNativeAuthentication(intent)
        guard current(start) else { return }
        try await store.rememberChallenge(challenge, expectedEpoch: epoch)
        guard current(start) else { return }; saved.challenge = challenge; challengeReady = true
        message = GuardianCopy.text("Check the email approved by your guardian for the sign-in code. No adult account is used here.")
    }
    func verifyCode() async {
        guard canVerify, let challenge = saved.challenge, let intent = saved.authentication, let epoch else { return }
        let start = generation, code = self.code; busy = true; message = nil; self.code = ""
        defer { if current(start) { busy = false } }
        do {
            try await identity.verifyGuardianChildCode(email: intent.email, code: code)
            guard current(start) else { return }
            let admission = try await service.prepareNativeAdmission(challenge: challenge, startIntent: intent)
            guard current(start) else { return }
            try await store.saveAdmission(admission, expectedEpoch: epoch)
            guard current(start) else { return }; saved.admission = admission
            try await admit(admission, startIntent: intent, start: start)
        } catch { await fail(error, start: start) }
    }
    private func admit(_ intent: ChildNativeAuthAdmitIntent, startIntent: ChildNativeAuthStartIntent, start: UUID) async throws {
        try await service.authorizeNativeAdmission(intent)
        guard current(start) else { return }
        let receipt = try await service.admitNativeAuthentication(intent)
        guard current(start), receipt.admitted else { return }
        let access = try await identity.childInvitationAccess()
        guard current(start), access.issuer == intent.issuer, access.subject == intent.subject, access.sessionID == intent.sessionID else { throw ClientError.accessEnded }
        try await onAdmitted(access, startIntent, intent)
    }
    private func fail(_ error: Error, start: UUID) async {
        guard current(start) else { return }
        code = ""
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded:
            challengeReady = false
            message = GuardianCopy.text("This child sign-in must be checked again. Resume its saved action, or ask your guardian for a new setup.")
        case .cancelled: break
        case .service(_, let code, _, _) where code.contains("unavailable") || code.contains("configuration"):
            challengeReady = false
            message = GuardianCopy.text("Child sign-in is unavailable until the covered email service is configured. Your saved action has not been replaced.")
        default:
            message = GuardianCopy.text("The child sign-in result is not confirmed. Resume this exact saved action. Do not request another email.")
        }
    }
}

actor GuardianCoveredChildService: GuardianChildServing {
    private let client: ChildInvitationClient
    private let start: ChildNativeAuthStartIntent
    private let admission: ChildNativeAuthAdmitIntent
    init(client: ChildInvitationClient, start: ChildNativeAuthStartIntent, admission: ChildNativeAuthAdmitIntent) {
        self.client = client; self.start = start; self.admission = admission
    }
    func prepareCoveredClaim() async throws -> ChildInvitationIntent {
        _ = try await client.admitNativeAuthentication(admission)
        return try await client.prepareClaim(startIntent: start, admissionIntent: admission)
    }
    func prepareClaim(token: String) async throws -> ChildInvitationIntent { throw ClientError.configuration }
    func authorize(_ intent: ChildInvitationIntent) async throws { try await client.authorize(intent) }
    func claim(_ intent: ChildInvitationIntent) async throws -> ChildInvitationClaimReceipt { try await client.claim(intent) }
    func status(_ receipt: ChildInvitationClaimReceipt) async throws -> ChildInvitationClaimStatus { try await client.status(receipt) }
    func prepareFinish(receipt: ChildInvitationClaimReceipt, pairingCode: String) async throws -> ChildInvitationIntent { try await client.prepareFinish(receipt: receipt,pairingCode:pairingCode) }
    func finish(_ intent: ChildInvitationIntent) async throws -> ChildEnrollmentReceipt { try await client.finish(intent) }
    func close() async { await client.close() }
}
