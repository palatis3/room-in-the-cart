import Foundation
import SwiftUI
import HouseholdClient

@MainActor final class HouseholdLifecycleModel: ObservableObject {
    @Published private(set) var scope: HouseholdBootstrap?
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var pendingMembership: MembershipIntent?
    @Published private(set) var activation: MembershipReceipt?
    @Published private(set) var members: [HouseholdMember] = []
    @Published private(set) var invitations: [ManagedInvitation] = []
    @Published private(set) var managedViews: [ManagedHelperView] = []
    @Published private(set) var managementReviewed = false
    @Published private(set) var proposalsGrantID: String?
    @Published private(set) var issued: IssuedInvitation?
    @Published private(set) var issuanceUncertain = false
    @Published private(set) var consents: [GuardianConsent] = []
    @Published private(set) var helperView: HelperView?
    @Published private(set) var pendingProposal: HelperProposalIntent?
    @Published private(set) var proposalReceipt: HelperProposalReceipt?
    @Published private(set) var proposalCursor: String?
    @Published private(set) var proposals: [HelperProposal] = []
    @Published var householdLabel = ""
    @Published var alias = ""
    @Published var invitationCode = ""
    @Published var adultAttestation = false
    @Published var keepLocalPrivate = false
    @Published var expiryHours = 24
    @Published var correction = ""
    let subject: String
    private let service: HouseholdService
    private let store: LifecycleIntentStore
    private let onEnrolled: @MainActor (MembershipReceipt) async throws -> Void
    private let onAccessEnded: @MainActor () async -> Void
    private var generation = UUID()
    private var scopeGeneration = UUID()
    private var retryAfter = Date.distantPast
    private var attempts = 0

    init(subject: String, service: HouseholdService, store: LifecycleIntentStore,
         onEnrolled: @escaping @MainActor (MembershipReceipt) async throws -> Void,
         onAccessEnded: @escaping @MainActor () async -> Void) {
        self.subject = subject; self.service = service; self.store = store
        self.onEnrolled = onEnrolled; self.onAccessEnded = onAccessEnded
    }
    var isHelper: Bool { scope?.grantId != nil && ["helper", "editor"].contains(scope?.role ?? "") }
    var canAdminister: Bool { !isHelper && scope?.capabilities.contains("household_admin") == true }
    var canShare: Bool { !isHelper && scope?.role == "shopper" && scope?.shopId != nil }
    func setScope(_ value: HouseholdBootstrap) { clearScope(); scope = value }
    func clearScope() {
        scopeGeneration = UUID(); scope = nil; members = []; invitations = []; managedViews = []; managementReviewed = false
        proposalsGrantID = nil; proposalCursor = nil; consents = []; issued = nil; helperView = nil
        pendingProposal = nil; proposalReceipt = nil; proposals = []; correction = ""; notice = nil; issuanceUncertain = false
    }
    func clear() {
        generation = UUID(); clearScope(); pendingMembership = nil; activation = nil
        invitationCode = ""; alias = ""; householdLabel = ""; adultAttestation = false; keepLocalPrivate = false
    }
    func restorePending() async {
        guard !busy else { return }
        let start = generation
        do {
            let saved = try await store.read()
            guard start == generation else { return }
            pendingMembership = saved.membership?.subject == subject ? saved.membership : nil
            activation = saved.activation?.subject == subject ? saved.activation?.receipt : nil
        } catch { notice = ht("Saved household actions could not be read. Nothing was sent.") }
    }
    func createHousehold() async {
        guard scope == nil, !busy, pendingMembership == nil, activation == nil, adultAttestation, keepLocalPrivate else { return }
        do {
            let intent = try MembershipIntent.create(subject: subject, label: householdLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                alias: alias.trimmingCharacters(in: .whitespacesAndNewlines), adultAttestation: adultAttestation)
            await saveAndSend(intent)
        } catch { notice = ht("Enter a household name and your alias, each up to 80 characters, and confirm the adult declaration.") }
    }
    func redeemInvitation() async {
        guard scope == nil, !busy, pendingMembership == nil, activation == nil, adultAttestation, keepLocalPrivate else { return }
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let intent = try MembershipIntent.redeem(subject: subject, token: invitationCode.trimmingCharacters(in: .whitespacesAndNewlines),
                alias: name.isEmpty ? nil : name, adultAttestation: adultAttestation)
            await saveAndSend(intent)
        } catch { notice = ht("Paste the complete invitation code and confirm the adult declaration. An alias can have up to 80 characters.") }
    }
    private func saveAndSend(_ intent: MembershipIntent) async {
        busy = true; notice = nil; defer { busy = false }; let start = generation
        do {
            var saved = try await store.read(); saved.membership = intent
            guard start == generation else { return }
            try await store.save(saved)
            guard start == generation else { return }
            pendingMembership = intent; attempts = 0
            await sendMembership(intent, start: start)
        } catch { if start == generation { notice = ht("The action was not saved on this phone. Nothing was sent.") } }
    }
    func retryMembership() async {
        guard !busy, scope == nil, let pendingMembership else { return }
        guard Date() >= retryAfter, attempts < 5 else { notice = ht("Wait before retrying, or review this action after several failed attempts."); return }
        busy = true; defer { busy = false }; await sendMembership(pendingMembership, start: generation)
    }
    private func sendMembership(_ intent: MembershipIntent, start: UUID) async {
        attempts += 1
        do {
            let receipt = try await service.executeMembership(intent)
            guard start == generation else { return }
            activation = receipt; invitationCode = ""
            var saved = try await store.read(); saved.membership = nil; saved.activation = .init(subject: subject, receipt: receipt)
            try await store.save(saved)
            guard start == generation else { return }
            pendingMembership = nil
            await connect(receipt, start: start)
        } catch {
            guard start == generation else { return }
            if activation != nil { notice = ht("Membership was confirmed, but its local recovery record could not be saved. Connect again to continue."); return }
            if let failure = error as? ClientError, let delay = RetryPolicy().delay(attempt: attempts, error: failure) { retryAfter = Date().addingTimeInterval(delay) }
            await handle(error, scoped: false)
        }
    }
    func connectConfirmedMembership() async {
        guard !busy, let activation else { return }
        busy = true; defer { busy = false }; await connect(activation, start: generation)
    }
    private func connect(_ receipt: MembershipReceipt, start: UUID) async {
        do {
            try await onEnrolled(receipt)
            guard start == generation else { return }
            var saved = try await store.read(); saved.activation = nil; try await store.save(saved)
            guard start == generation else { return }
            activation = nil; notice = ht("Household access is connected. Your existing private work was not uploaded.")
        } catch {
            if start == generation { notice = ht("Membership was confirmed. Connect again to finish opening this household.") }
        }
    }
    func clearPendingMembership() async {
        guard !busy else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            var saved = try await store.read(); saved.membership = nil; try await store.save(saved)
            guard start == generation else { return }
            pendingMembership = nil; attempts = 0; notice = ht("The local retry was cleared. Check your household list before creating another household.")
        } catch { notice = ht("The local retry could not be cleared.") }
    }
    func loadMembers() async {
        guard canAdminister, !busy else { return }
        busy = true; defer { busy = false }; let start = scopeGeneration
        do {
            let value = try await service.members(); let links = try await service.managedInvitations()
            guard start == scopeGeneration else { return }; members = value.members; invitations = links.invites; managementReviewed = true
        }
        catch { if start == scopeGeneration { await handle(error) } }
    }
    func createAdultInvitation() async {
        guard canAdminister, !busy, !issuanceUncertain else { return }
        busy = true; notice = nil; issued = nil; managementReviewed = false; defer { busy = false }; let start = scopeGeneration
        do { let result = try await service.createAdultInvitation(expiresInHours: expiryHours)
            guard start == scopeGeneration else { return }; issued = result }
        catch { if start == scopeGeneration { issuanceUncertain = isUncertain(error); await handle(error) } }
    }
    func acknowledgeUncertainCreation() { guard !busy, managementReviewed else { return }; issuanceUncertain = false; notice = nil }
    func loadManagedViews() async {
        guard canShare || canAdminister, !busy else { return }
        busy = true; defer { busy = false }; let start = scopeGeneration
        do { let result = try await service.managedHelperViews(); guard start == scopeGeneration else { return }; managedViews = result.views; managementReviewed = true }
        catch { if start == scopeGeneration { await handle(error) } }
    }
    func revoke(_ kind: RevocationKind, targetID: String) async {
        guard !busy, canAdminister || (kind == .view && canShare) else { return }
        busy = true; notice = nil; defer { busy = false }; let start = scopeGeneration
        do {
            let receipt = try await service.revoke(kind, targetID: targetID)
            guard start == scopeGeneration else { return }
            guard receipt.revoked, receipt.targetId == targetID else { throw ClientError.invalidResponse }
            if kind == .member { members.removeAll { $0.id == targetID } }
            if issued?.inviteId == targetID || issued?.grantId == targetID { issued = nil }
            guard start == scopeGeneration else { return }
            notice = ht("Access was revoked. Previously exported copies cannot be recalled.")
            if kind == .invite { invitations.removeAll { $0.id == targetID } }
            if kind == .view { managedViews.removeAll { $0.id == targetID } }
        } catch { if start == scopeGeneration { await handle(error) } }
    }
    func createHelperView(projection: HelperProjection, mode: String) async {
        guard canShare, let shopID = scope?.shopId, !busy, !issuanceUncertain else { return }
        busy = true; notice = nil; issued = nil; managementReviewed = false; defer { busy = false }; let start = scopeGeneration
        do { let result = try await service.createHelperView(shopID: shopID, projection: projection, mode: mode, expiresInHours: expiryHours)
            guard start == scopeGeneration else { return }; issued = result }
        catch { if start == scopeGeneration { issuanceUncertain = isUncertain(error); await handle(error) } }
    }
    func loadHelper() async {
        guard isHelper, let grantID = scope?.grantId, !busy else { return }
        busy = true; defer { busy = false }; let start = scopeGeneration
        do {
            let value = try await service.currentHelperView(grantID: grantID)
            guard start == scopeGeneration else { return }
            helperView = value
            let saved = try await store.read(); guard start == scopeGeneration else { return }
            pendingProposal = saved.proposals.first { $0.householdID == scope?.household.id && $0.memberID == scope?.memberId && $0.grantID == grantID }
        } catch { if start == scopeGeneration { await handle(error) } }
    }
    func sendProposal() async {
        guard isHelper, let helperView, helperView.canPropose, pendingProposal == nil, !busy else { return }
        let text = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1000 else { notice = ht("Enter a suggestion up to 1,000 characters."); return }
        busy = true; notice = nil; proposalReceipt = nil; defer { busy = false }; let start = scopeGeneration
        do {
            let intent = try await service.prepareHelperProposal(grantID: helperView.grantId, baseRevision: helperView.revision, correction: text)
            guard start == scopeGeneration else { return }
            var saved = try await store.read(); saved.proposals.append(intent); try await store.save(saved)
            guard start == scopeGeneration else { return }; pendingProposal = intent; attempts = 0
            await deliverProposal(intent, start: start)
        } catch { if start == scopeGeneration { await handle(error) } }
    }
    func retryProposal() async {
        guard isHelper, !busy, let pendingProposal else { return }
        guard Date() >= retryAfter, attempts < 5 else { notice = ht("Wait before retrying, or review this action after several failed attempts."); return }
        busy = true; defer { busy = false }; await deliverProposal(pendingProposal, start: scopeGeneration)
    }
    private func deliverProposal(_ intent: HelperProposalIntent, start: UUID) async {
        attempts += 1
        do {
            let receipt = try await service.executeHelperProposal(intent)
            guard start == scopeGeneration else { return }
            proposalReceipt = receipt; correction = ""
            var saved = try await store.read(); saved.proposals.removeAll { $0.id == intent.id }; try await store.save(saved)
            guard start == scopeGeneration else { return }; pendingProposal = nil
            notice = ht("Your suggestion was received for review. The shared instructions and shopping basket have not changed.")
        } catch {
            guard start == scopeGeneration else { return }
            if proposalReceipt?.grantId == intent.grantID { notice = ht("Your suggestion was received. Local retry cleanup needs another attempt."); return }
            if let failure = error as? ClientError, let delay = RetryPolicy().delay(attempt: attempts, error: failure) { retryAfter = Date().addingTimeInterval(delay) }
            await handle(error)
        }
    }
    func clearPendingProposalAfterReview() async {
        guard isHelper, !busy, let pendingProposal else { return }
        busy = true; defer { busy = false }; let start = scopeGeneration
        do {
            let fresh = try await service.currentHelperView(grantID: pendingProposal.grantID)
            guard start == scopeGeneration else { return }
            var saved = try await store.read(); saved.proposals.removeAll { $0.id == pendingProposal.id }; try await store.save(saved)
            guard start == scopeGeneration else { return }; self.pendingProposal = nil; helperView = fresh; correction = ""
        } catch { if start == scopeGeneration { await handle(error) } }
    }
    func loadProposals(grantID: String, more: Bool = false) async {
        guard canShare, !busy else { return }
        if more && (proposalsGrantID != grantID || proposalCursor == nil) { return }
        busy = true; defer { busy = false }; let start = scopeGeneration
        if !more { proposals = []; proposalsGrantID = nil; proposalCursor = nil }
        do {
            let page = try await service.helperProposals(grantID: grantID, cursor: proposalCursor)
            guard start == scopeGeneration else { return }
            let received = Set(page.proposals.map(\.id))
            proposals.removeAll { received.contains($0.id) }
            proposals += page.proposals
            proposalsGrantID = grantID
            proposalCursor = page.nextCursor
        } catch { if start == scopeGeneration { await handle(error) } }
    }
    func expireHelperIfNeeded() async {
        guard let helperView, let expiry = serviceDate(helperView.expiresAt), Date() >= expiry else { return }
        clearScope(); await onAccessEnded()
    }
    func loadConsents() async {
        guard scope != nil, !isHelper, !busy else { return }
        busy = true; defer { busy = false }; let start = scopeGeneration
        do { let result = try await service.guardianConsents(); guard start == scopeGeneration else { return }; consents = result.consents }
        catch { if start == scopeGeneration { await handle(error) } }
    }
    func withdrawConsent(_ consent: GuardianConsent) async {
        guard !isHelper, scope != nil, !busy else { return }
        busy = true; notice = nil; defer { busy = false }; let start = scopeGeneration
        do {
            let result = try await service.withdrawConsent(consentID: consent.id)
            guard start == scopeGeneration else { return }
            guard result.revoked, result.consentId == consent.id else { throw ClientError.invalidResponse }
            consents.removeAll { $0.id == consent.id }
            notice = ht("Consent was withdrawn. The child's current online access has ended.")
        } catch { if start == scopeGeneration { await handle(error) } }
    }
    private func isUncertain(_ error: Error) -> Bool {
        switch error as? ClientError { case .transport, .invalidResponse: return true
        case .service(let status, _, _, _): return status >= 500; default: return false }
    }
    private func handle(_ error: Error, scoped: Bool = true) async {
        switch error as? ClientError {
        case .sessionNeeded, .accessEnded:
            clearScope(); await onAccessEnded()
        case .service(let status, let code, _, _):
            if status == 404, isHelper { clearScope(); await onAccessEnded(); return }
            if code == "consent_unavailable" { notice = ht("Child enrollment is unavailable until verified guardian consent is connected.") }
            else if code == "shopper_transfer_required" { notice = ht("Transfer this person's active pickups before removing household access.") }
            else if status == 404 { notice = ht("This invitation or record is unavailable, expired, or outside your access.") }
            else if status == 409 { notice = ht("Current information has changed. Refresh and review before starting a new action.") }
            else { notice = ht("The service could not confirm this action. Keep the existing retry until you review its status.") }
        case .cancelled: break
        default: notice = ht("The service could not confirm this action. Keep the existing retry until you review its status.")
        }
    }
}
