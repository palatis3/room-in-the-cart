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
    private var generation = UUID()
    public init(configuration: ServiceConfiguration, auth: AdultAuth, deviceVault: any RefreshTokenVault,
                transport: HTTPTransport = .init()) {
        self.configuration = configuration; self.auth = auth; self.deviceVault = deviceVault; self.transport = transport
    }
    public func enroll(householdID: String) async throws -> HouseholdBootstrap {
        guard UUID(uuidString: householdID) != nil else { throw ClientError.configuration }
        generation = UUID(); enrollment = nil; self.householdID = nil; subject = nil; memberID = nil
        let start = generation
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        // Reuse the same enrolled device after a crash. The service validates current identity/session binding.
        if let saved = try deviceVault.read(), let bytes = saved.data(using: .utf8),
           let record = try? JSONDecoder().decode(StoredEnrollment.self, from: bytes),
           record.householdID == householdID, record.subject == access.identity.subject {
            enrollment = record.device; self.householdID = householdID; subject = access.identity.subject
            return try await bootstrap()
        }
        let device: DeviceEnrollment = try await transport.json(request(base: configuration.baseURL,
            path: "v1/households/\(householdID)/devices", method: "POST", token: access.accessToken, body: Data("{}".utf8)))
        guard generation == start else { throw ClientError.cancelled }
        let stored = StoredEnrollment(householdID: householdID, subject: access.identity.subject, device: device)
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
        let value: HouseholdBootstrap = try await perform("bootstrap", method: "GET")
        guard generation == start else { throw ClientError.cancelled }
        guard value.household.id == householdID, value.enrolled else { throw ClientError.accessEnded }
        memberID = value.memberId
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
        guard self.householdID == householdID, self.memberID == memberID, let enrollment else { throw ClientError.accessEnded }
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
        generation = UUID(); enrollment = nil; householdID = nil; subject = nil; memberID = nil
        try? deviceVault.clear()
    }
    private func perform<T: Decodable & Sendable>(_ path: String, method: String, body: Data? = nil,
                                                 query: [URLQueryItem] = []) async throws -> T {
        let start = generation
        guard let householdID, let enrollment else { throw ClientError.sessionNeeded }
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        guard access.identity.subject == subject else { await clearScope(); throw ClientError.accessEnded }
        var req = request(base: configuration.baseURL, path: "v1/households/\(householdID)/\(path)",
                          method: method, token: access.accessToken, body: body)
        req.setValue(enrollment.deviceToken, forHTTPHeaderField: "X-Device-Token")
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

private struct StoredEnrollment: Codable { let householdID: String; let subject: String; let device: DeviceEnrollment }
