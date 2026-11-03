import Foundation
import Combine
import HouseholdClient

struct GuardianChildScope: Equatable, Codable, Sendable {
    let issuer: String; let subject: String; let sessionID: String
    let generation: UUID
    func matches(_ intent: ChildInvitationIntent) -> Bool {
        intent.issuer == issuer && intent.subject == subject && intent.sessionID == sessionID
    }
}
protocol GuardianChildServing: Sendable {
    func prepareClaim(token: String) async throws -> ChildInvitationIntent
    func prepareCoveredClaim() async throws -> ChildInvitationIntent
    func authorize(_ intent: ChildInvitationIntent) async throws
    func claim(_ intent: ChildInvitationIntent) async throws -> ChildInvitationClaimReceipt
    func status(_ receipt: ChildInvitationClaimReceipt) async throws -> ChildInvitationClaimStatus
    func prepareFinish(receipt: ChildInvitationClaimReceipt, pairingCode: String) async throws -> ChildInvitationIntent
    func finish(_ intent: ChildInvitationIntent) async throws -> ChildEnrollmentReceipt
    func close() async
}
extension GuardianChildServing {
    func prepareCoveredClaim() async throws -> ChildInvitationIntent { throw ClientError.configuration }
}
extension ChildInvitationClient: GuardianChildServing {}

struct GuardianChildStoredState: Codable, Equatable, Sendable {
    var authentication: ChildNativeAuthStartIntent?
    var challenge: ChildNativeAuthChallenge?
    var admission: ChildNativeAuthAdmitIntent?
    var claim: ChildInvitationIntent?
    var receipt: ChildInvitationClaimReceipt?
    var finish: ChildInvitationIntent?
}
/// A separate device-only Keychain entry holds invitation, pairing and device secrets. No provider token is persisted here.
actor GuardianChildPendingStore {
    private let vault: any RefreshTokenVault
    private var generation = UUID()
    init(vault: any RefreshTokenVault) { self.vault = vault }
    func epoch() -> UUID { generation }
    func read() throws -> GuardianChildStoredState {
        guard let value = try vault.read() else { return .init() }
        guard value.utf8.count <= 100_000 else { throw ClientError.invalidResponse }
        let state = try JSONDecoder().decode(GuardianChildStoredState.self, from: Data(value.utf8))
        try validate(state); return state
    }
    func saveAuthentication(_ intent: ChildNativeAuthStartIntent, expectedEpoch: UUID) throws {
        try check(expectedEpoch); try intent.validate(); var state = try read()
        if let old = state.authentication { guard old == intent else { throw ClientError.configuration }; return }
        guard state.claim == nil else { throw ClientError.configuration }
        state.authentication = intent; try write(state)
    }
    func rememberChallenge(_ challenge: ChildNativeAuthChallenge, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        guard state.authentication != nil else { throw ClientError.configuration }
        if let old = state.challenge { guard old == challenge else { throw ClientError.invalidResponse }; return }
        state.challenge = challenge; try write(state)
    }
    func saveAdmission(_ intent: ChildNativeAuthAdmitIntent, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        if let old = state.admission { guard old == intent else { throw ClientError.configuration }; return }
        state.admission = intent; try write(state)
    }
    func saveClaim(_ intent: ChildInvitationIntent, expectedEpoch: UUID) throws {
        try check(expectedEpoch); try intent.validate(); guard intent.kind == .claim else { throw ClientError.configuration }
        var state = try read()
        if let old = state.claim { guard old == intent else { throw ClientError.configuration }; return }
        state.claim = intent; try write(state)
    }
    func remember(_ receipt: ChildInvitationClaimReceipt, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        guard state.claim != nil else { throw ClientError.configuration }
        if let old = state.receipt { guard old == receipt else { throw ClientError.invalidResponse }; return }
        state.receipt = receipt; try write(state)
    }
    func saveFinish(_ intent: ChildInvitationIntent, expectedEpoch: UUID) throws {
        try check(expectedEpoch); var state = try read()
        if let old = state.finish { guard old == intent else { throw ClientError.configuration }; return }
        state.finish = intent; try write(state)
    }
    func purge() throws { generation = UUID(); try vault.clear() }
    private func check(_ epoch: UUID) throws { guard generation == epoch else { throw ClientError.cancelled } }
    private func validate(_ state: GuardianChildStoredState) throws {
        if let start = state.authentication { try start.validate() }
        if let challenge = state.challenge {
            guard state.authentication != nil, challenge.status == "check_email", UUID(uuidString: challenge.householdId) != nil,
                  UUID(uuidString: challenge.challengeId) != nil else { throw ClientError.configuration }
        }
        if let admission = state.admission {
            try admission.validate()
            guard let start = state.authentication, let challenge = state.challenge, admission.startID == start.id,
                  admission.householdID == challenge.householdId, admission.challengeID == challenge.challengeId else { throw ClientError.configuration }
        }
        if let claim = state.claim { try claim.validate(); guard claim.kind == .claim else { throw ClientError.configuration } }
        if let receipt = state.receipt {
            guard state.claim != nil, UUID(uuidString: receipt.householdId) != nil, UUID(uuidString: receipt.claimId) != nil,
                  receipt.status == "awaiting_guardian" else { throw ClientError.configuration }
        }
        if let finish = state.finish {
            try finish.validate()
            guard let claim = state.claim, let receipt = state.receipt, finish.kind == .finish,
                  finish.issuer == claim.issuer, finish.subject == claim.subject, finish.sessionID == claim.sessionID,
                  finish.pairingCode == claim.pairingCode, finish.householdID == receipt.householdId,
                  finish.claimID == receipt.claimId else { throw ClientError.configuration }
        }
    }
    private func write(_ state: GuardianChildStoredState) throws {
        try validate(state)
        try vault.write(String(decoding: JSONEncoder().encode(state), as: UTF8.self))
    }
}

/// Construct only with an approved child authentication source. The production entry supplies none.
@MainActor final class GuardianChildModel: ObservableObject {
    let scope: GuardianChildScope
    let coveredAuthentication: Bool
    private let service: any GuardianChildServing
    private let store: GuardianChildPendingStore
    private let runtime: () -> GuardianChildScope?
    /// The integration must bind installation to this exact still-live child scope and open only S22.
    private let onEnrolled: @MainActor (GuardianChildScope, ChildEnrollmentReceipt) async throws -> Void
    private var generation = UUID()
    private var epoch: UUID?
    private var closingTask: Task<Void, Never>?
    private var state = GuardianChildStoredState()
    @Published var invitationToken = ""
    @Published private(set) var pairingCode: String?
    @Published private(set) var status: ChildInvitationClaimStatus.Status?
    @Published private(set) var hasPending = false
    @Published private(set) var busy = false
    @Published private(set) var completed = false
    @Published private(set) var message: String?
    init(scope: GuardianChildScope, service: any GuardianChildServing, store: GuardianChildPendingStore, coveredAuthentication: Bool = false,
         runtime: @escaping () -> GuardianChildScope?, onEnrolled: @escaping @MainActor (GuardianChildScope, ChildEnrollmentReceipt) async throws -> Void) {
        self.scope = scope; self.service = service; self.store = store; self.coveredAuthentication = coveredAuthentication; self.runtime = runtime; self.onEnrolled = onEnrolled
    }
    var live: Bool { runtime() == scope }
    var canClaim: Bool { live && !busy && !hasPending && !completed && epoch != nil && (coveredAuthentication || !invitationToken.isEmpty) }
    var canFinish: Bool { live && !busy && status == .approved && state.receipt != nil && state.finish == nil }
    private func current(_ start: UUID) -> Bool { live && generation == start }
    func invalidate() {
        generation = UUID(); invitationToken = ""; pairingCode = nil; status = nil
        state = .init(); epoch = nil; hasPending = false; busy = false; completed = false; message = nil
    }
    func suspend() {
        invalidate()
        let predecessor = closingTask
        closingTask = Task { if let predecessor { await predecessor.value }; await service.close() }
    }
    func load() async {
        guard live, !busy else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            await closingTask?.value
            guard current(start) else { return }; closingTask = nil
            let epoch = await store.epoch(), saved = try await store.read()
            guard current(start) else { return }
            if let claim = saved.claim {
                guard scope.matches(claim) else { throw ClientError.accessEnded }
                try await service.authorize(claim)
                guard current(start) else { return }; pairingCode = claim.pairingCode
            }
            self.epoch = epoch; state = saved; hasPending = saved.claim != nil
            if hasPending { message = GuardianCopy.text("Resume this same saved invitation to check its current status.") }
        } catch { await fail(error, start: start) }
    }
    func claimInvitation() async {
        guard canClaim, let epoch else { return }
        let token = invitationToken.trimmingCharacters(in: .whitespacesAndNewlines), start = generation
        busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await (coveredAuthentication ? service.prepareCoveredClaim() : service.prepareClaim(token: token))
            guard current(start), scope.matches(intent) else { return }
            try await store.saveClaim(intent, expectedEpoch: epoch)
            guard current(start) else { return }
            state.claim = intent; hasPending = true; invitationToken = ""; pairingCode = intent.pairingCode
            try await sendClaim(intent, epoch: epoch, start: start)
        } catch { await fail(error, start: start) }
    }
    func retry() async {
        guard live, !busy, let claim = state.claim, let epoch else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            if let finish = state.finish { try await sendFinish(finish, start: start) }
            else { try await sendClaim(claim, epoch: epoch, start: start) }
        } catch { await fail(error, start: start) }
    }
    private func sendClaim(_ intent: ChildInvitationIntent, epoch: UUID, start: UUID) async throws {
        try await service.authorize(intent)
        guard current(start) else { return }
        let receipt = try await service.claim(intent)
        guard current(start) else { return }
        try await store.remember(receipt, expectedEpoch: epoch)
        guard current(start) else { return }; state.receipt = receipt
        let latest = try await service.status(receipt)
        guard current(start) else { return }; status = latest.status
        if latest.status == .ended { try await endAccess(start: start) }
    }
    func refreshStatus() async {
        guard live, !busy, let receipt = state.receipt else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            let value = try await service.status(receipt)
            guard current(start) else { return }; status = value.status
            if value.status == .ended { try await endAccess(start: start) }
        } catch { await fail(error, start: start) }
    }
    func finishSetup() async {
        guard canFinish, let receipt = state.receipt, let code = pairingCode, let epoch else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await service.prepareFinish(receipt: receipt, pairingCode: code)
            guard current(start), scope.matches(intent) else { return }
            try await store.saveFinish(intent, expectedEpoch: epoch)
            guard current(start) else { return }; state.finish = intent
            try await sendFinish(intent, start: start)
        } catch { await fail(error, start: start) }
    }
    private func sendFinish(_ intent: ChildInvitationIntent, start: UUID) async throws {
        try await service.authorize(intent)
        guard current(start) else { return }
        let receipt = try await service.finish(intent)
        guard current(start) else { return }
        try await onEnrolled(scope, receipt)
        guard current(start) else { return }
        try await store.purge()
        guard current(start) else { return }
        state = .init(); hasPending = false; pairingCode = nil; completed = true; status = .active
        message = GuardianCopy.text("Your own-request access was confirmed by the household service.")
    }
    func forgetThisDevice() async {
        guard !busy else { return }
        invalidate()
        do { try await store.purge(); await service.close()
            message = GuardianCopy.text("Setup secrets were removed from this device. Your guardian must cancel pending setup or withdraw any active permission.") }
        catch { message = GuardianCopy.text("Unlock this device to remove its saved setup secrets.") }
    }
    private func endAccess(start: UUID) async throws {
        try await store.purge(); await service.close()
        guard current(start) else { return }; state = .init(); pairingCode = nil; hasPending = false; status = .ended
        message = GuardianCopy.text("This child setup has ended. Ask your guardian for a new setup.")
    }
    private func fail(_ error: Error, start: UUID) async {
        guard current(start) else { return }
        switch error as? ClientError {
        case .sessionNeeded, .accessEnded:
            try? await endAccess(start: start)
            guard current(start) else { return }
            pairingCode = nil; status = .ended; invitationToken = ""
            message = GuardianCopy.text("Your child session or invitation has ended. Ask your guardian for a new setup.")
        case .service(let status, _, _, _) where status == 403 || status == 404 || status == 410:
            try? await endAccess(start: start)
        case .cancelled: break
        default:
            message = GuardianCopy.text("The result is not confirmed. Retry this same saved invitation or finish action.")
        }
    }
}
