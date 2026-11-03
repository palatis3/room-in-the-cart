import Foundation

/// A service grant never follows from account login alone. Enrollment is an explicit UI action.
public actor HouseholdService {
    private let configuration: ServiceConfiguration
    private let transport: HTTPTransport
    private let auth: AdultAuth
    private let deviceVault: any RefreshTokenVault
    private var enrollment: DeviceEnrollment?
    private var householdID: String?
    private var subject: String?
    private var memberID: String?
    private var selectedGrantID: String?
    private var generation = UUID()
    public init(configuration: ServiceConfiguration, auth: AdultAuth, deviceVault: any RefreshTokenVault,
                transport: HTTPTransport = .init()) {
        self.configuration = configuration; self.auth = auth; self.deviceVault = deviceVault; self.transport = transport
    }
    public func enroll(householdID: String, grantID: String? = nil) async throws -> HouseholdBootstrap {
        guard UUID(uuidString: householdID) != nil else { throw ClientError.configuration }
        if let grantID, UUID(uuidString: grantID) == nil { throw ClientError.configuration }
        generation = UUID(); enrollment = nil; self.householdID = nil; subject = nil; memberID = nil
        selectedGrantID = grantID
        let start = generation
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        // Reuse the same enrolled device after a crash. The service validates current identity/session binding.
        if let saved = try deviceVault.read(), let bytes = saved.data(using: .utf8),
           let record = try? JSONDecoder().decode(StoredEnrollment.self, from: bytes),
           record.householdID == householdID, record.subject == access.identity.subject {
            enrollment = record.device; self.householdID = householdID; subject = access.identity.subject
            selectedGrantID = grantID ?? record.grantID
            return try await bootstrap()
        }
        let device: DeviceEnrollment = try await transport.json(request(base: configuration.baseURL,
            path: "v1/households/\(householdID)/devices", method: "POST", token: access.accessToken, body: Data("{}".utf8)))
        guard generation == start else { throw ClientError.cancelled }
        let stored = StoredEnrollment(householdID: householdID, subject: access.identity.subject, device: device, grantID: selectedGrantID)
        try deviceVault.write(String(decoding: encoded(stored), as: UTF8.self))
        enrollment = device; self.householdID = householdID; subject = access.identity.subject
        return try await bootstrap()
    }
    public func matches(_ operation: PendingOperation, memberID: String) -> Bool {
        operation.householdID == householdID && operation.memberID == memberID && operation.deviceID == enrollment?.deviceId
    }
    public func workspaces() async throws -> WorkspaceList {
        let start = generation
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        let result: WorkspaceList = try await transport.json(request(base: configuration.baseURL,
            path: "v1/me/workspaces", method: "GET", token: access.accessToken))
        guard generation == start else { throw ClientError.cancelled }
        return result
    }
    public func bootstrap() async throws -> HouseholdBootstrap {
        let start = generation
        var value: HouseholdBootstrap = try await perform("bootstrap", method: "GET")
        guard generation == start else { throw ClientError.cancelled }
        guard value.household.id == householdID, value.enrolled else { throw ClientError.accessEnded }
        if selectedGrantID == nil, ["helper", "editor"].contains(value.role) {
            guard let grant = value.grantId, UUID(uuidString: grant) != nil else { throw ClientError.accessEnded }
            selectedGrantID = grant
            value = try await perform("bootstrap", method: "GET")
            guard generation == start else { throw ClientError.cancelled }
        }
        if let selectedGrantID {
            guard value.grantId == selectedGrantID, ["helper", "editor"].contains(value.role),
                  value.capabilities.allSatisfy({ ["helper_view", "helper_propose"].contains($0) }),
                  value.capabilities.contains("helper_view") else { await clearScope(); throw ClientError.accessEnded }
        }
        memberID = value.memberId
        if let enrollment, let householdID, let subject {
            let stored = StoredEnrollment(householdID: householdID, subject: subject, device: enrollment, grantID: selectedGrantID)
            try deviceVault.write(String(decoding: encoded(stored), as: UTF8.self))
        }
        return value
    }
    public func replayWindow() async throws -> ReplayWindow { try await perform("replay-windows", method: "POST", body: Data("{}".utf8)) }
    public func ownRequests(cursor: String? = nil) async throws -> OwnRequestsPage {
        if let cursor, UUID(uuidString: cursor) == nil { throw ClientError.configuration }
        return try await perform("requests/mine", method: "GET", query: cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
    }
    private func authorizeShopper(shopID: String) async throws {
        guard UUID(uuidString: shopID) != nil else { throw ClientError.configuration }
        let projection = try await bootstrap()
        guard projection.role == "shopper", projection.shopId == shopID,
              ["shopper_inbox", "request_preview", "shopper_commands"].allSatisfy(projection.capabilities.contains) else {
            throw ClientError.accessEnded
        }
    }
    public func shopperShop(shopID: String) async throws -> ShopperShop {
        let start = generation
        try await authorizeShopper(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        return try await perform("shops/\(shopID)", method: "GET")
    }
    public func shopperInbox(shopID: String, cursor: String? = nil) async throws -> OwnRequestsPage {
        if let cursor, UUID(uuidString: cursor) == nil { throw ClientError.configuration }
        let start = generation
        try await authorizeShopper(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        return try await perform("shops/\(shopID)/inbox", method: "GET", query: cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
    }
    public func shopperPreview(shopID: String, requestID: String, base: CommandBase, decision: ShopperDecision) async throws -> ShopperPreview {
        guard UUID(uuidString: requestID) != nil, base.shopRevision > 0, base.authorityEpoch > 0,
              (base.requestRevision ?? 0) > 0 else { throw ClientError.configuration }
        struct Input: Encodable { let requestId: String; let base: CommandBase; let decision: ShopperDecision }
        let start = generation
        try await authorizeShopper(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        return try await perform("shops/\(shopID)/previews", method: "POST", body: encoded(Input(requestId: requestID, base: base, decision: decision)))
    }
    public func executeShopper(_ operation: PendingOperation) async throws -> ShopperReceipt {
        let start = generation
        guard let enrollment, operation.householdID == householdID, operation.deviceID == enrollment.deviceId else { throw ClientError.accessEnded }
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        guard envelope.clientKey == operation.clientKey, ["request.apply", "request.clarify"].contains(envelope.kind) else { throw ClientError.configuration }
        try await authorizeShopper(shopID: envelope.shopId)
        guard start == generation else { throw ClientError.cancelled }
        guard operation.memberID == memberID else { throw ClientError.accessEnded }
        return try await perform("commands", method: "POST", body: operation.bytes)
    }
    /// For other native service adapters; returning a token never grants a role.
    public func currentDeviceToken(householdID: String, memberID: String) async throws -> String {
        let start = generation
        guard selectedGrantID == nil, self.householdID == householdID, self.memberID == memberID, let enrollment else { throw ClientError.accessEnded }
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        guard access.identity.subject == subject else { throw ClientError.accessEnded }
        return enrollment.deviceToken
    }
    public func prepare(envelope: CommandEnvelope, bootstrap: HouseholdBootstrap) throws -> PendingOperation {
        guard let enrollment, let householdID, bootstrap.household.id == householdID,
              bootstrap.memberId == memberID else { throw ClientError.accessEnded }
        return try PendingOperation(envelope: envelope, householdID: householdID, memberID: bootstrap.memberId, deviceID: enrollment.deviceId)
    }
    public func execute(_ operation: PendingOperation) async throws -> OwnReceipt {
        let start = generation
        guard let enrollment, operation.householdID == householdID, operation.deviceID == enrollment.deviceId else { throw ClientError.accessEnded }
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        guard envelope.clientKey == operation.clientKey,
              ["request.send", "request.edit", "request.withdraw"].contains(envelope.kind) else { throw ClientError.configuration }
        // Bootstrap revalidates the present member; stored actor/device identity cannot be silently replaced on retry.
        let projection = try await bootstrap()
        guard start == generation else { throw ClientError.cancelled }
        guard projection.memberId == operation.memberID else { throw ClientError.accessEnded }
        return try await perform("commands", method: "POST", body: operation.bytes)
    }
    public func executeMembership(_ intent: MembershipIntent) async throws -> MembershipReceipt {
        let start = generation
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        guard access.identity.subject == intent.subject else { throw ClientError.accessEnded }
        if intent.kind == .create {
            struct Key: Decodable { let clientKey: String }
            guard try JSONDecoder().decode(Key.self, from: intent.bytes).clientKey == intent.id else { throw ClientError.configuration }
        }
        let value: MembershipReceipt = try await transport.json(request(base: configuration.baseURL,
            path: intent.kind == .create ? "v1/households" : "v1/invites/redeem", method: "POST", token: access.accessToken, body: intent.bytes))
        guard generation == start else { throw ClientError.cancelled }
        return value
    }
    private func authorizeAdmin() async throws {
        let value = try await bootstrap()
        guard value.capabilities.contains("household_admin"), selectedGrantID == nil else { throw ClientError.accessEnded }
    }
    public func members() async throws -> HouseholdMembers {
        let start = generation; try await authorizeAdmin(); guard start == generation else { throw ClientError.cancelled }
        return try await perform("members", method: "GET")
    }
    public func createAdultInvitation(expiresInHours: Int) async throws -> IssuedInvitation {
        guard (1...168).contains(expiresInHours) else { throw ClientError.configuration }
        let start = generation; try await authorizeAdmin(); guard start == generation else { throw ClientError.cancelled }
        struct Input: Encodable { let kind = "adult_contributor"; let expiresInHours: Int }
        return try await perform("invites", method: "POST", body: encoded(Input(expiresInHours: expiresInHours)))
    }
    public func managedInvitations() async throws -> ManagedInvitations {
        let start = generation; try await authorizeAdmin(); guard start == generation else { throw ClientError.cancelled }
        return try await perform("invites", method: "GET")
    }
    public func managedHelperViews() async throws -> ManagedHelperViews {
        let start = generation; let value = try await bootstrap(); guard start == generation else { throw ClientError.cancelled }
        guard selectedGrantID == nil, value.capabilities.contains("household_admin") || value.role == "shopper" else { throw ClientError.accessEnded }
        return try await perform("views", method: "GET")
    }
    public func revoke(_ kind: RevocationKind, targetID: String) async throws -> RevocationReceipt {
        guard UUID(uuidString: targetID) != nil else { throw ClientError.configuration }
        let start = generation; let value = try await bootstrap()
        guard start == generation else { throw ClientError.cancelled }
        guard selectedGrantID == nil, value.capabilities.contains("household_admin") || (kind == .view && value.role == "shopper") else { throw ClientError.accessEnded }
        struct Input: Encodable { let kind: RevocationKind; let targetId: String }
        return try await perform("revocations", method: "POST", body: encoded(Input(kind: kind, targetId: targetID)))
    }
    public func createHelperView(shopID: String, projection: HelperProjection, mode: String, expiresInHours: Int) async throws -> IssuedInvitation {
        guard ["read", "edit"].contains(mode), (1...168).contains(expiresInHours) else { throw ClientError.configuration }
        let start = generation; try await authorizeShopper(shopID: shopID); guard start == generation else { throw ClientError.cancelled }
        struct Input: Encodable { let shopId: String; let mode: String; let expiresInHours: Int; let shopLabel: String; let language: String; let items: [HelperInstruction] }
        return try await perform("views", method: "POST", body: encoded(Input(shopId: shopID, mode: mode, expiresInHours: expiresInHours,
            shopLabel: projection.shopLabel, language: projection.language, items: projection.items)))
    }
    public func currentHelperView(grantID: String) async throws -> HelperView {
        guard UUID(uuidString: grantID) != nil, selectedGrantID == grantID else { throw ClientError.accessEnded }
        let value: HelperView = try await perform("v1/views/\(grantID)/current", method: "GET", absolutePath: true)
        guard value.grantId == grantID else { throw ClientError.invalidResponse }
        return value
    }
    public func prepareHelperProposal(grantID: String, baseRevision: Int, correction: String) async throws -> HelperProposalIntent {
        let start = generation
        let view = try await currentHelperView(grantID: grantID)
        guard start == generation else { throw ClientError.cancelled }
        guard view.canPropose, let householdID, let memberID, let enrollment else { throw ClientError.accessEnded }
        guard view.revision == baseRevision else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
        return try .init(householdID: householdID, memberID: memberID, deviceID: enrollment.deviceId,
                         grantID: grantID, baseRevision: baseRevision, correction: correction)
    }
    public func executeHelperProposal(_ intent: HelperProposalIntent) async throws -> HelperProposalReceipt {
        let start = generation
        guard intent.householdID == householdID, intent.memberID == memberID, intent.deviceID == enrollment?.deviceId,
              intent.grantID == selectedGrantID else { throw ClientError.accessEnded }
        struct Key: Decodable { let clientKey: String }
        guard try JSONDecoder().decode(Key.self, from: intent.bytes).clientKey == intent.id else { throw ClientError.configuration }
        let view = try await currentHelperView(grantID: intent.grantID)
        guard start == generation else { throw ClientError.cancelled }
        guard view.canPropose else { throw ClientError.accessEnded }
        return try await perform("v1/views/\(intent.grantID)/proposals", method: "POST", body: intent.bytes, absolutePath: true)
    }
    public func helperProposals(grantID: String) async throws -> HelperProposals {
        guard UUID(uuidString: grantID) != nil, selectedGrantID == nil else { throw ClientError.configuration }
        return try await perform("views/\(grantID)/proposals", method: "GET")
    }
    public func guardianConsents() async throws -> GuardianConsents {
        guard selectedGrantID == nil else { throw ClientError.accessEnded }
        return try await perform("guardian/consents", method: "GET")
    }
    public func withdrawConsent(consentID: String) async throws -> ConsentWithdrawalReceipt {
        guard UUID(uuidString: consentID) != nil, selectedGrantID == nil else { throw ClientError.configuration }
        return try await perform("guardian/consents/\(consentID)/revoke", method: "POST", body: Data("{}".utf8))
    }
    public func revokeCurrentDevice() async throws {
        guard let householdID, let enrollment else { return }
        let start = generation
        do {
            let access = try await auth.access()
            guard start == generation else { throw ClientError.cancelled }
            var req = request(base: configuration.baseURL, path: "v1/households/\(householdID)/devices/current",
                              method: "DELETE", token: access.accessToken)
            req.setValue(enrollment.deviceToken, forHTTPHeaderField: "X-Device-Token")
            _ = try await transport.send(req)
            if start == generation { await clearScope() }
        } catch {
            if start == generation { await clearScope() }
            throw error
        }
    }
    public func clearScope() async {
        generation = UUID(); enrollment = nil; householdID = nil; subject = nil; memberID = nil; selectedGrantID = nil
        try? deviceVault.clear()
    }
    private func perform<T: Decodable & Sendable>(_ path: String, method: String, body: Data? = nil,
                                                 query: [URLQueryItem] = [], absolutePath: Bool = false) async throws -> T {
        let start = generation
        guard let householdID, let enrollment else { throw ClientError.sessionNeeded }
        if let selectedGrantID, path != "bootstrap",
           path != "v1/views/\(selectedGrantID)/current", path != "v1/views/\(selectedGrantID)/proposals" { throw ClientError.accessEnded }
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        guard access.identity.subject == subject else { await clearScope(); throw ClientError.accessEnded }
        var req = request(base: configuration.baseURL, path: "v1/households/\(householdID)/\(path)",
                          method: method, token: access.accessToken, body: body)
        if absolutePath { req.url = configuration.baseURL.appendingPathComponent(path) }
        req.setValue(enrollment.deviceToken, forHTTPHeaderField: "X-Device-Token")
        req.setValue(householdID, forHTTPHeaderField: "X-Household-ID")
        if let selectedGrantID { req.setValue(selectedGrantID, forHTTPHeaderField: "X-View-Grant-ID") }
        if !query.isEmpty {
            var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = query; req.url = components.url
        }
        do {
            let result: T = try await transport.json(req)
            guard generation == start else { throw ClientError.cancelled }
            return result
        } catch {
            guard generation == start else { throw ClientError.cancelled }
            if let error = error as? ClientError, error == .accessEnded || error == .sessionNeeded { await clearScope() }
            throw error
        }
    }
}

/// An atomic, device-private outbox. Saving here is not a shared commit, and callers must show waiting until a receipt arrives.
public actor OperationOutbox {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func operations() throws -> [PendingOperation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PendingOperation].self, from: Data(contentsOf: url))
    }
    public func append(_ operation: PendingOperation) throws {
        var all = try operations()
        if let old = all.first(where: { $0.id == operation.id }) {
            guard old == operation else { throw ClientError.service(status: 409, code: "key_reused", correlationID: nil, retryAfter: nil) }
            return
        }
        all.append(operation); try save(all)
    }
    public func remove(_ id: String) throws { try save(operations().filter { $0.id != id }) }
    public func purge() throws { try save([]) }
    private func save(_ all: [PendingOperation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try encoded(all).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encoded(all).write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var protectedURL = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }
}

private struct StoredEnrollment: Codable { let householdID: String; let subject: String; let device: DeviceEnrollment; let grantID: String? }
