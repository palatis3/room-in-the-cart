import Foundation
import SwiftUI
import LocalAuthentication
import HouseholdClient

@MainActor final class HouseholdModel: ObservableObject {
    @Published private(set) var identity: VerifiedAdultIdentity?
    @Published private(set) var workspaces: [WorkspaceList.Workspace] = []
    @Published private(set) var projection: HouseholdBootstrap?
    @Published private(set) var shopperInbox: HouseholdInboxModel?
    @Published private(set) var sharedShop: HouseholdShopModel?
    @Published private(set) var lifecycle: HouseholdLifecycleModel?
    @Published private(set) var requests: [OwnRequest] = []
    @Published private(set) var nextRequestCursor: String?
    @Published private(set) var delivery: DeliveryState = .localDraft
    @Published private(set) var busy = false
    @Published private(set) var locked = false
    @Published private(set) var codeSent = false
    @Published private(set) var notice: String?
    @Published var email = ""
    @Published var code = ""
    @Published var item = ""
    @Published var quantity = ""
    @Published private(set) var editing: OwnRequest?
    @Published private(set) var followingUp: OwnRequest?
    @Published var forNextShop = false
    @Published var keepLocalPrivate = false
    let configured: Bool
    let emailOTPEnabled: Bool
    private(set) var serviceURL: URL?
    var onScopeChange: (() -> Void)?
    private(set) var accountDeletion: AccountDeletionModel?
    private(set) var householdExit: HouseholdExitModel?
    private let auth: AdultAuth?
    let service: HouseholdService?
    private let outbox: OperationOutbox
    private let shopperOutbox: OperationOutbox
    private let sharedShopOutbox: OperationOutbox
    private let lifecycleStore: LifecycleIntentStore
    private let historyStore: HistoryPendingStore
    private var pending: PendingOperation?
    private var attempts = 0
    private var retryAfter = Date.distantPast
    private var generation = UUID()

    init(bundle: Bundle = .main, auth: AdultAuth? = nil, service: HouseholdService? = nil, outboxURL: URL? = nil, deletionVault: (any RefreshTokenVault)? = nil, exitVault: (any RefreshTokenVault)? = nil) {
        let otpSetting = bundle.object(forInfoDictionaryKey: "RITCEmailOTPEnabled")
        emailOTPEnabled = (auth != nil && service != nil) || (otpSetting as? String == "YES") || (otpSetting as? Bool == true)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let queueURL = outboxURL ?? base.appendingPathComponent("RoomInTheCart/household-outbox.json")
        outbox = OperationOutbox(url: queueURL)
        shopperOutbox = OperationOutbox(url: queueURL.deletingPathExtension().appendingPathExtension("shopper.json"))
        sharedShopOutbox = OperationOutbox(url: queueURL.deletingPathExtension().appendingPathExtension("shared-shop.json"))
        lifecycleStore = LifecycleIntentStore(url: queueURL.deletingPathExtension().appendingPathExtension("lifecycle.json"))
        historyStore = HistoryPendingStore(url: queueURL.deletingPathExtension().appendingPathExtension("history.json"))
        if let auth, let service {
            self.auth = auth; self.service = service; configured = true
            householdExit = HouseholdExitModel(service: service, vault: exitVault ?? KeychainRefreshTokenVault(service: "RoomInTheCart.injected", account: "household-exits"))
            accountDeletion = AccountDeletionModel(service: service, vault: deletionVault ?? KeychainRefreshTokenVault(service: "RoomInTheCart.injected", account: "deletion-receipts"))
            return
        }
        guard let serviceString = bundle.object(forInfoDictionaryKey: "HouseholdServiceURL") as? String,
              let authString = bundle.object(forInfoDictionaryKey: "SupabaseProjectURL") as? String,
              let key = bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
              let serviceURL = URL(string: serviceString), let projectURL = URL(string: authString),
              let serviceConfig = try? ServiceConfiguration(baseURL: serviceURL),
              let authConfig = try? AdultAuthConfiguration(projectURL: projectURL, publishableKey: key) else {
            self.auth = nil; self.service = nil; configured = false; return
        }
        let namespace = (bundle.bundleIdentifier ?? "RoomInTheCart") + "." + (projectURL.host ?? "auth")
        let managedAuth = AdultAuth(configuration: authConfig, vault: KeychainRefreshTokenVault(service: namespace))
        self.serviceURL = serviceURL
        self.auth = managedAuth
        let householdService = HouseholdService(configuration: serviceConfig, auth: managedAuth,
            deviceVault: KeychainRefreshTokenVault(service: namespace, account: "household-device"))
        self.service = householdService
        householdExit = HouseholdExitModel(service: householdService, vault: KeychainRefreshTokenVault(
            service: namespace + "." + serviceURL.absoluteString, account: "household-exits"))
        accountDeletion = AccountDeletionModel(service: householdService, vault: KeychainRefreshTokenVault(
            service: namespace + "." + serviceURL.absoluteString, account: "deletion-receipts"))
        configured = true
    }
    func sendCode() async {
        guard emailOTPEnabled else { notice = ht("Email sign-in is not ready yet. Your private shopping tools work without an account."); return }
        guard let auth, !busy else { return }
        busy = true; notice = nil; defer { busy = false }
        let start = generation
        do { try await auth.requestEmailCode(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
            guard start == generation else { return }; codeSent = true
            notice = ht("Check your email for a sign-in code.") }
        catch { await show(error, start: start) }
    }
    func verifyCode() async {
        guard emailOTPEnabled else { notice = ht("Email sign-in is not ready yet. Your private shopping tools work without an account."); return }
        guard let auth, let service, !busy else { return }
        busy = true; notice = nil; defer { busy = false }
        let start = generation
        do {
            let access = try await auth.verifyEmailCode(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: code)
            guard start == generation else { return }
            identity = access.identity; code = ""; locked = false
            configureLifecycle(access.identity)
            let result = try await service.workspaces()
            guard start == generation else { return }
            workspaces = result.workspaces
            if workspaces.isEmpty { notice = ht("This account has no active household access. Your private work stays on this phone.") }
        } catch { await show(error, start: start) }
    }
    /// Explicit consent keeps local data private. There is deliberately no automatic local import.
    func join(_ workspace: WorkspaceList.Workspace) async {
        guard keepLocalPrivate, let service, !busy, !locked else { return }
        onScopeChange?()
        clearProjection()
        busy = true; notice = nil; defer { busy = false }
        let start = generation
        do {
            let value = try await service.enroll(householdID: workspace.householdId)
            guard start == generation else { return }
            try await finishEnrollment(value, start: start)
        } catch { await show(error, start: start) }
    }
    private func finishEnrollment(_ value: HouseholdBootstrap, start: UUID) async throws {
        guard let service else { throw ClientError.configuration }
            projection = value
            if value.capabilities.contains("own_requests") {
                let page = try await service.ownRequests()
                guard start == generation else { return }
                requests = page.requests; nextRequestCursor = page.nextCursor
            }
            // Old device-bound operations require review; never attach them to this new enrollment.
            let old = try await outbox.operations()
            guard start == generation else { return }
            if let operation = old.first(where: { $0.householdID == value.household.id && $0.memberID == value.memberId && $0.targetsShop(value.shopId) }) {
                pending = operation
                let matches = await service.matches(operation, memberID: value.memberId)
                guard start == generation else { return }
                if matches {
                    delivery = .waiting(operationID: operation.id)
                } else {
                    delivery = .needsReview(operationID: operation.id, code: "device_changed")
                }
                notice = ht("An earlier request needs review. Check received requests before sending it again.")
            }
            configureShopperInbox(value); configureSharedShop(value)
            lifecycle?.setScope(value)
    }
    private func configureLifecycle(_ identity: VerifiedAdultIdentity) {
        guard let service else { return }
        lifecycle?.clear()
        let start = generation
        lifecycle = HouseholdLifecycleModel(subject: identity.subject, service: service, store: lifecycleStore) { [weak self] receipt in
            guard let self, self.identity?.subject == identity.subject, !self.locked, !self.busy else { throw ClientError.sessionNeeded }
            self.busy = true; defer { self.busy = false }
            self.onScopeChange?(); self.clearProjection()
            let current = self.generation
            let value = try await service.enroll(householdID: receipt.householdId, grantID: receipt.grantId)
            guard current == self.generation else { throw ClientError.cancelled }
            try await self.finishEnrollment(value, start: current)
        } onAccessEnded: { [weak self] in
            await self?.show(ClientError.accessEnded, start: start)
        }
    }
    func selectShop(_ id: UUID?) async {
        guard let service, let scope = projection, scope.canSelectShop == true || scope.selectionRequired == true,
              scope.grantId == nil, !busy, !locked else { return }
        onScopeChange?()
        clearProjection()
        busy = true; defer { busy = false }
        let start = generation
        do {
            let value = try await service.selectShop(id)
            guard start == generation else { return }
            try await finishEnrollment(value, start: start)
        } catch {
            guard start == generation else { return }
            await show(error, start: start)
        }
    }
    func refresh() async {
        guard let service, projection != nil, !busy, !locked else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            let fresh = try await service.bootstrap()
            guard start == generation, let prior = projection else { return }
            let scopeChanged = prior.household.id != fresh.household.id || prior.memberId != fresh.memberId ||
                prior.role != fresh.role || prior.shopId != fresh.shopId || prior.grantId != fresh.grantId ||
                Set(prior.capabilities) != Set(fresh.capabilities)
            if scopeChanged {
                onScopeChange?()
                cancelEdit()
                requests = []
                nextRequestCursor = nil
            }
            // Revoke the old view as soon as authority is known, even if the request list cannot load.
            projection = fresh
            configureShopperInbox(fresh); configureSharedShop(fresh); lifecycle?.setScope(fresh)
            notice = nil
            if fresh.capabilities.contains("own_requests") {
                let page = try await service.ownRequests()
                guard start == generation else { return }
                requests = page.requests; nextRequestCursor = page.nextCursor
            } else { requests = []; nextRequestCursor = nil }
        } catch { await show(error, start: start) }
    }
    func loadMoreRequests() async {
        guard let service, let cursor = nextRequestCursor, projection != nil, !busy, !locked else { return }
        busy = true; defer { busy = false }; let start = generation
        do {
            let page = try await service.ownRequests(cursor: cursor)
            guard start == generation else { return }
            for request in page.requests { requests.removeAll { $0.id == request.id }; requests.append(request) }
            nextRequestCursor = page.nextCursor
        } catch { await show(error, start: start) }
    }
    func sendRequest() async {
        guard let service, let projection, projection.capabilities.contains("own_requests"), let shop = editing?.shopId ?? followingUp?.shopId ?? projection.shopId,
              !busy, !locked, pending == nil else { return }
        let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 240, amount.count <= 80 else { notice = ht("Enter an item up to 240 characters and a quantity up to 80 characters."); return }
        busy = true; notice = nil; defer { busy = false }; let start = generation
        do {
            let window = try await service.replayWindow()
            guard start == generation else { return }
            var body: [String: JSONValue] = ["originalItem": .string(text), "ownQuantity": amount.isEmpty ? .null : .string(amount)]
            let kind: String
            if let editing {
                kind = "request.edit"; body["requestId"] = .string(editing.requestId)
            } else {
                kind = "request.send"; body["clientRequestId"] = .string(UUID().uuidString.lowercased())
                body["authoredAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                body["route"] = .string(forNextShop ? "next" : "current")
                if let followingUp { body["followupTo"] = .string(followingUp.requestId) }
            }
            let envelope = CommandEnvelope(replayWindow: window.id, shopId: editing?.shopId ?? followingUp?.shopId ?? shop, kind: kind,
                base: .init(shopRevision: 0, authorityEpoch: 0, requestRevision: editing?.revision), body: body)
            let operation = try await service.prepare(envelope: envelope, bootstrap: projection)
            guard start == generation else { return }
            try await outbox.append(operation)
            guard start == generation else { return }
            pending = operation; attempts = 0; delivery = .waiting(operationID: operation.id)
            await deliver(operation, start: start)
        } catch { await show(error, start: start) }
    }
    func edit(_ request: OwnRequest) {
        guard request.ownActionAllowed, pending == nil, !busy, !locked else { return }
        followingUp = nil; editing = request; item = request.originalItem; quantity = request.ownQuantity ?? ""; delivery = .localDraft
    }
    func followUp(_ request: OwnRequest) {
        guard !request.ownActionAllowed, pending == nil, !busy, !locked else { return }
        editing = nil; followingUp = request; item = request.originalItem; quantity = request.ownQuantity ?? ""; delivery = .localDraft
    }
    func cancelEdit() { editing = nil; followingUp = nil; item = ""; quantity = ""; forNextShop = false }
    func withdraw(_ request: OwnRequest) async {
        guard request.ownActionAllowed, let service, let projection,
              pending == nil, !busy, !locked else { return }
        busy = true; notice = nil; defer { busy = false }; let start = generation
        do {
            let window = try await service.replayWindow()
            guard start == generation else { return }
            let envelope = CommandEnvelope(replayWindow: window.id, shopId: request.shopId, kind: "request.withdraw",
                base: .init(shopRevision: 0, authorityEpoch: 0, requestRevision: request.revision), body: ["requestId": .string(request.requestId)])
            let operation = try await service.prepare(envelope: envelope, bootstrap: projection)
            guard start == generation else { return }
            try await outbox.append(operation)
            guard start == generation else { return }
            pending = operation; attempts = 0; delivery = .waiting(operationID: operation.id)
            await deliver(operation, start: start)
        } catch { await show(error, start: start) }
    }
    func retry() async {
        guard let pending, !busy, !locked, case .waiting = delivery else { return }
        guard Date() >= retryAfter, attempts < 5 else { notice = ht("Wait before retrying, or review this request after several failed attempts."); return }
        busy = true; defer { busy = false }; await deliver(pending, start: generation)
    }
    private func deliver(_ operation: PendingOperation, start: UUID) async {
        guard let service else { return }
        attempts += 1
        do {
            let receipt = try await service.execute(operation)
            guard start == generation else { return }
            delivery = .received(receipt); pending = nil; cancelEdit()
            requests.removeAll { $0.id == receipt.request.id }; requests.insert(receipt.request, at: 0)
            do { try await outbox.remove(operation.id) }
            catch { if start == generation { notice = ht("Received by the household. Local retry cleanup needs another attempt.") } }
        } catch {
            guard start == generation else { return }
            if let failure = error as? ClientError {
                if let delay = RetryPolicy().delay(attempt: attempts, error: failure) { retryAfter = Date().addingTimeInterval(delay) }
                else if failure != .accessEnded && failure != .sessionNeeded && failure != .cancelled {
                    let reason: String
                    if case .service(_, let code, _, _) = failure { reason = code } else { reason = "retry_limit" }
                    delivery = .needsReview(operationID: operation.id, code: reason)
                }
            }
            await show(error, start: start)
        }
    }
    func discardPendingAfterReview() async {
        guard !busy, !locked, let pending else { return }
        busy = true; defer { busy = false }; let start = generation
        do { try await outbox.remove(pending.id)
            guard start == generation else { return }
            self.pending = nil; delivery = .localDraft; attempts = 0; notice = nil }
        catch { if start == generation { notice = ht("Could not clear the local retry. Try again.") } }
    }
    /// Scene transitions hide protected projections; returning requires OS owner authentication and fresh authorization.
    func lock() {
        accountDeletion?.clearReview(); householdExit?.clear()
        onScopeChange?(); generation = UUID(); locked = identity != nil
        clearProjection(); lifecycle?.clear(); lifecycle = nil; workspaces = []; code = ""; notice = nil
    }
    func unlock() async {
        guard let auth, let service, !busy else { return }
        busy = true; defer { busy = false }; let start = generation
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            notice = ht("Sign in again to reopen household access on this device."); return
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: ht("Reopen your protected household account")) else { return }
            guard start == generation else { return }
            let access = try await auth.access(); let list = try await service.workspaces()
            guard start == generation else { return }
            identity = access.identity; workspaces = list.workspaces; locked = false; keepLocalPrivate = false
            configureLifecycle(access.identity)
        } catch { await show(error, start: start) }
    }
    func hideExitingScope(_ intent: HouseholdExitIntent) async {
        guard let identity, identity.subject == intent.subject else { return }
        workspaces.removeAll { $0.householdId == intent.householdID }
        if projection?.household.id == intent.householdID, projection?.memberId == intent.memberID {
            generation = UUID(); onScopeChange?(); clearProjection()
            await service?.clearScope()
            if self.identity == identity, !locked { configureLifecycle(identity) }
        }
    }
    func householdExited(_ intent: HouseholdExitIntent) async {
        let subject = intent.subject, householdID = intent.householdID
        guard identity?.subject == subject, let service else { return }
        await hideExitingScope(intent)
        let start = generation
        var cleanupFailed = false
        for queue in [outbox, shopperOutbox, sharedShopOutbox] {
            do { try await queue.purge(householdID: householdID, memberID: intent.memberID) } catch { cleanupFailed = true }
        }
        do { try await lifecycleStore.purge(householdID: householdID, memberID: intent.memberID, subject: subject) } catch { cleanupFailed = true }
        do { try await historyStore.purge(householdID: householdID, subject: subject) } catch { cleanupFailed = true }
        guard start == generation, self.identity?.subject == subject, !locked else { return }
        do {
            let list = try await service.workspaces()
            guard start == generation, self.identity?.subject == subject, !locked else { return }
            workspaces = list.workspaces
        } catch { notice = ht("You left the household. Its access is closed. The remaining memberships could not be refreshed.") }
        if cleanupFailed { notice = ht("You left the household. Some local household retries could not be cleared.") }
    }
    func submitAccountDeletion(subject: String) async {
        guard identity?.subject == subject, !locked, let accountDeletion else { return }
        switch await accountDeletion.submit(subject: subject) {
        case .accepted: await deletionAccepted(subject: subject)
        case .uncertain:
            // Acceptance may already have revoked the account. Keep only receipt-based status access.
            if identity?.subject == subject { await finishSignOut(allDevices: false, alreadyRevoked: true) }
        case .rejected: break
        }
    }
    func deletionAccepted(subject: String) async {
        guard identity?.subject == subject else { return }
        let removed: Bool
        do { try householdExit?.forget(subject: subject); removed = true } catch { removed = false }
        await finishSignOut(allDevices: false, alreadyRevoked: true)
        if !removed { notice = ht("Unlock this phone to update the saved household exit request.") }
    }
    func signOut(allDevices: Bool = false) async {
        await finishSignOut(allDevices: allDevices, alreadyRevoked: false)
    }
    private func finishSignOut(allDevices: Bool, alreadyRevoked: Bool) async {
        guard alreadyRevoked || !busy else { return }
        busy = true; defer { busy = false }
        onScopeChange?()
        accountDeletion?.clearReview(); householdExit?.clear()
        generation = UUID(); identity = nil; workspaces = []; clearProjection(); lifecycle?.clear(); lifecycle = nil
        delivery = .localDraft; code = ""; email = ""; item = ""; quantity = ""; codeSent = false; locked = false
        keepLocalPrivate = false; editing = nil
        var failed = false
        if !alreadyRevoked { do { try await service?.revokeCurrentDevice() } catch { failed = true } }
        await service?.clearScope()
        do { try await outbox.purge() } catch { failed = true }
        do { try await shopperOutbox.purge() } catch { failed = true }
        do { try await sharedShopOutbox.purge() } catch { failed = true }
        do { try await lifecycleStore.purge() } catch { failed = true }
        do { try await historyStore.purge() } catch { failed = true }
        do {
            if alreadyRevoked { try await auth?.clearLocalSession() }
            else { try await auth?.signOut(allDevices: allDevices) }
        } catch { failed = true }
        notice = failed ? ht("Signed out on this phone. Remote sign-out or local cleanup could not be confirmed.") : nil
    }
    func adultAccessToken() async throws -> String {
        guard let auth, identity != nil, let projection, !["helper", "editor"].contains(projection.role), !locked else { throw ClientError.sessionNeeded }
        let start = generation
        let access = try await auth.access()
        guard start == generation, !locked else { throw ClientError.cancelled }
        guard access.identity == identity else { throw ClientError.accessEnded }
        return access.accessToken
    }
    func deviceAccessToken() async throws -> String {
        guard let service, let projection, identity != nil, !locked else { throw ClientError.sessionNeeded }
        let start = generation
        let token = try await service.currentDeviceToken(householdID: projection.household.id, memberID: projection.memberId)
        guard start == generation, !locked else { throw ClientError.cancelled }
        return token
    }
    private func clearProjection() {
        lifecycle?.clearScope()
        shopperInbox?.clear(); shopperInbox = nil; sharedShop?.clear(); sharedShop = nil
        projection = nil; requests = []; nextRequestCursor = nil; pending = nil
        delivery = .localDraft; attempts = 0; retryAfter = .distantPast; cancelEdit()
    }
    var canReviewHouseholdRequests: Bool {
        guard let projection, !locked, projection.role == "shopper", projection.shopId != nil else { return false }
        return ["shopper_inbox", "request_preview", "shopper_commands"].allSatisfy(projection.capabilities.contains)
    }
    private func configureShopperInbox(_ projection: HouseholdBootstrap) {
        guard canReviewHouseholdRequests, let service else { shopperInbox?.clear(); shopperInbox = nil; return }
        if let shopperInbox, shopperInbox.authorized, shopperInbox.householdID == projection.household.id,
           shopperInbox.memberID == projection.memberId, shopperInbox.shopID == projection.shopId { return }
        shopperInbox?.clear()
        let start = generation
        shopperInbox = HouseholdInboxModel(bootstrap: projection, service: service, outbox: shopperOutbox) { [weak self] in
            await self?.show(ClientError.accessEnded, start: start)
        }
    }
    private func configureSharedShop(_ projection: HouseholdBootstrap) {
        guard !locked, projection.grantId == nil,
              projection.capabilities.contains("household_admin") || projection.role == "shopper", let service else {
            sharedShop?.clear(); sharedShop = nil; return
        }
        if let sharedShop, sharedShop.authorized, sharedShop.householdID == projection.household.id, sharedShop.memberID == projection.memberId {
            sharedShop.updateScope(projection); return
        }
        sharedShop?.clear()
        let start = generation
        sharedShop = HouseholdShopModel(scope: projection, service: service, outbox: sharedShopOutbox) { [weak self] in
            guard let self, self.generation == start else { return }; await self.refresh()
        } onAccessEnded: { [weak self] in await self?.show(ClientError.accessEnded, start: start) }
    }
    private func show(_ error: Error, start: UUID) async {
        guard start == generation else { return }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded:
            onScopeChange?()
            generation = UUID(); clearProjection(); workspaces = []; delivery = .accessEnded; locked = identity != nil
            notice = ht("Access needs to be checked again. Your private work stays on this phone.")
            await service?.clearScope()
            do { try await outbox.purge() }
            catch { notice = ht("Access has ended. Local retry cleanup could not be confirmed.") }
            do { try await shopperOutbox.purge() }
            catch { notice = ht("Access has ended. Local retry cleanup could not be confirmed.") }
            do { try await sharedShopOutbox.purge() }
            catch { notice = ht("Access has ended. Local retry cleanup could not be confirmed.") }
            do { try await lifecycleStore.purge() }
            catch { notice = ht("Access has ended. Local retry cleanup could not be confirmed.") }
            do { try await historyStore.purge() }
            catch { notice = ht("Access has ended. Local retry cleanup could not be confirmed.") }
        case .service(let status, _, _, _) where status == 409:
            notice = ht("This request needs review against the current household state. It has not been applied again.")
        case .service(let status, _, _, _) where status == 429:
            notice = ht("Too many attempts. Wait before trying again.")
        case .cancelled: break
        default: notice = ht("The service could not confirm this action. Keep your draft and try again.")
        }
    }
}
func ht(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Household") }

// E09 uses the active native session; recovered files never supply this authority.
extension HouseholdModel {
    func makeHistoryModel() -> HistoryFeatureModel? {
        guard let service else { return nil }
        return HistoryFeatureModel(service: service, store: historyStore, runtime: { [weak self] in
            guard let self, !self.locked, let identity = self.identity, let scope = self.projection,
                  scope.enrolled, scope.grantId == nil,
                  ["organizer", "shopper", "contributor"].contains(scope.role) else { return nil }
            return HistoryRuntimeScope(generation: self.generation, subject: identity.subject,
                householdID: scope.household.id, memberID: scope.memberId, currentShopID: scope.shopId,
                authorityStamp: scope.role + "|" + scope.capabilities.sorted().joined(separator: ","))
        }, onAccessEnded: { [weak self] in
            guard let self else { return }
            await self.show(ClientError.accessEnded, start: self.generation)
        })
    }
    /// Also used by the account deletion coordinator before dismissing native access.
    func purgeHistoryLocalState() async throws { try await historyStore.purge() }
}
