import Foundation

/// Only an already authenticated, approved child identity provider integration may supply this access.
/// Local values detect session changes; the server authenticates issuer, subject and live session independently.
public struct ChildInvitationAccess: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let issuer: String; public let subject: String; public let sessionID: String; public let accessToken: String
    public init(issuer: String, subject: String, sessionID: String, accessToken: String) {
        self.issuer = issuer; self.subject = subject; self.sessionID = sessionID; self.accessToken = accessToken
    }
    public var description: String { "ChildInvitationAccess(<redacted>)" }
    public var debugDescription: String { description }
    var binding: ChildInvitationBinding { .init(issuer: issuer, subject: subject, sessionID: sessionID) }
    func validate() throws {
        guard GuardianValidation.text(issuer, 2000), GuardianValidation.text(subject, 200),
              GuardianValidation.text(sessionID, 200), GuardianValidation.token(accessToken) else { throw ClientError.sessionNeeded }
    }
}
struct ChildInvitationBinding: Codable, Equatable, Sendable { let issuer: String; let subject: String; let sessionID: String }
private struct ChildInvitationBody: Codable, Equatable, Sendable {
    let clientKey: String; let pairingCode: String
    var token: String?; var householdId: String?; var claimId: String?; var deviceSecret: String?
}
/// Claim and finish are distinct from adult invitation redemption. Retain these exact bytes in a dedicated protected store.
public struct ChildInvitationIntent: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Codable, Sendable { case claim, finish }
    public let id: String; public let kind: Kind; public let issuer: String; public let subject: String; public let sessionID: String
    public let pairingCode: String; public let householdID: String?; public let claimID: String?; public let bytes: Data
    private let body: ChildInvitationBody
    public var description: String { "ChildInvitationIntent(\(kind.rawValue), <redacted>)" }
    public var debugDescription: String { description }
    var binding: ChildInvitationBinding { .init(issuer: issuer, subject: subject, sessionID: sessionID) }
    init(binding: ChildInvitationBinding, token: String) throws {
        id = UUID().uuidString.lowercased(); kind = .claim; issuer = binding.issuer; subject = binding.subject; sessionID = binding.sessionID
        pairingCode = try GuardianPairingCode.generate(); householdID = nil; claimID = nil
        body = .init(clientKey: id, pairingCode: pairingCode, token: token)
        bytes = try encoded(body); try validate()
    }
    init(binding: ChildInvitationBinding, receipt: ChildInvitationClaimReceipt, pairingCode: String) throws {
        id = UUID().uuidString.lowercased(); kind = .finish; issuer = binding.issuer; subject = binding.subject; sessionID = binding.sessionID
        self.pairingCode = pairingCode; householdID = receipt.householdId; claimID = receipt.claimId
        body = .init(clientKey: id, pairingCode: pairingCode, householdId: householdID, claimId: claimID, deviceSecret: try GuardianSecret.generate())
        bytes = try encoded(body); try validate()
    }
    public func validate() throws {
        guard GuardianValidation.ids([id]), GuardianValidation.text(issuer, 2000), GuardianValidation.text(subject, 200),
              GuardianValidation.text(sessionID, 200), GuardianPairingCode.isValid(pairingCode),
              body.clientKey == id, body.pairingCode == pairingCode else { throw ClientError.configuration }
        switch kind {
        case .claim:
            guard let token = body.token, GuardianValidation.token(token), householdID == nil, claimID == nil,
                  body.householdId == nil, body.claimId == nil, body.deviceSecret == nil else { throw ClientError.configuration }
        case .finish:
            guard let householdID, let claimID, GuardianValidation.ids([householdID, claimID]),
                  body.householdId == householdID, body.claimId == claimID, body.token == nil,
                  body.deviceSecret.map(GuardianSecret.isCanonical) == true else { throw ClientError.configuration }
        }
        guard bytes == (try encoded(body)) else { throw ClientError.configuration }
    }
    func validate(_ receipt: ChildEnrollmentReceipt) throws {
        guard let householdID, kind == .finish, receipt.deviceToken == body.deviceSecret else { throw ClientError.invalidResponse }
        try receipt.validate(householdID: householdID)
    }
}

/// This client provides no sign-in, account creation, adult attestation, device registration or local activation path.
/// A production caller must inject an approved child authentication integration; no default exists.
public actor ChildInvitationClient {
    private struct Claimed: Sendable { let receipt: ChildInvitationClaimReceipt; let intent: ChildInvitationIntent }
    private struct Challenged: Sendable { let receipt: ChildNativeAuthChallenge; let intent: ChildNativeAuthStartIntent }
    private let configuration: ServiceConfiguration; private let transport: HTTPTransport
    private let access: @Sendable () async throws -> ChildInvitationAccess
    private var generation = UUID(); private var claims: [String: Claimed] = [:]
    private var challenges: [String: Challenged] = [:]
    private var admissions: [String: ChildNativeAuthAdmitIntent] = [:]
    public init(configuration: ServiceConfiguration, transport: HTTPTransport = .init(),
                access: @escaping @Sendable () async throws -> ChildInvitationAccess) {
        self.configuration = configuration; self.transport = transport; self.access = access
    }
    public func childEnrollmentAvailability(language: GuardianLanguage) async throws -> GuardianAvailabilityResponse {
        let start = generation
        var req = request(base: configuration.baseURL, path: "v1/guardian/availability", method: "GET")
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "language", value: language.rawValue)]; req.url = components.url
        let value: GuardianAvailabilityResponse = try await transport.json(req)
        guard start == generation else { throw ClientError.cancelled }
        try value.validate(); return value
    }
    public func prepareNativeAuthentication(token: String, email: String) throws -> ChildNativeAuthStartIntent {
        try .init(token: token, email: email)
    }
    public func startNativeAuthentication(_ intent: ChildNativeAuthStartIntent) async throws -> ChildNativeAuthChallenge {
        try intent.validate(); let start = generation
        let receipt: ChildNativeAuthChallenge = try await transport.json(request(base: configuration.baseURL,
            path: "v1/child-invitations/native-auth/start", method: "POST", body: intent.bytes))
        try receipt.validate(); guard start == generation else { throw ClientError.cancelled }
        if let existing = challenges[intent.id], existing.receipt != receipt { throw ClientError.invalidResponse }
        challenges[intent.id] = .init(receipt: receipt, intent: intent); return receipt
    }
    /// After restart, recover the original challenge by retrying the retained start intent; this never requests a new key or secret.
    public func prepareNativeAdmission(challenge: ChildNativeAuthChallenge, startIntent: ChildNativeAuthStartIntent) async throws -> ChildNativeAuthAdmitIntent {
        try startIntent.validate(); try challenge.validate(); let start = generation
        guard let retained = challenges[startIntent.id], retained.intent == startIntent, retained.receipt == challenge else { throw ClientError.accessEnded }
        let current = try await access(); try current.validate()
        guard start == generation else { throw ClientError.cancelled }
        return try .init(binding: current.binding, challenge: challenge, start: startIntent)
    }
    public func authorizeNativeAdmission(_ intent: ChildNativeAuthAdmitIntent) async throws {
        try intent.validate(); _ = try await authenticated(binding: intent.binding, generation: generation)
    }
    public func admitNativeAuthentication(_ intent: ChildNativeAuthAdmitIntent) async throws -> ChildNativeAuthAdmission {
        try intent.validate(); let start = generation
        let receipt: ChildNativeAuthAdmission = try await perform(binding: intent.binding, path: "v1/child-invitations/native-auth/admit", method: "POST", body: intent.bytes)
        try receipt.validate(); guard start == generation else { throw ClientError.cancelled }
        admissions[intent.startID] = intent; return receipt
    }
    public func prepareClaim(startIntent: ChildNativeAuthStartIntent, admissionIntent: ChildNativeAuthAdmitIntent) async throws -> ChildInvitationIntent {
        try startIntent.validate(); try admissionIntent.validate(); let start = generation
        guard admissionIntent.matches(startIntent), admissions[startIntent.id] == admissionIntent else { throw ClientError.accessEnded }
        let current = try await authenticated(binding: admissionIntent.binding, generation: start)
        return try .init(binding: current.binding, token: startIntent.invitationToken)
    }
    public func prepareClaim(token: String) async throws -> ChildInvitationIntent {
        let start = generation; let current = try await access(); try current.validate()
        guard start == generation else { throw ClientError.cancelled }
        return try .init(binding: current.binding, token: token)
    }
    public func authorize(_ intent: ChildInvitationIntent) async throws {
        try intent.validate(); _ = try await authenticated(binding: intent.binding, generation: generation)
    }
    public func claim(_ intent: ChildInvitationIntent) async throws -> ChildInvitationClaimReceipt {
        try intent.validate(); guard intent.kind == .claim else { throw ClientError.configuration }
        let start = generation
        let receipt: ChildInvitationClaimReceipt = try await perform(binding: intent.binding, path: "v1/child-invitations/claim", method: "POST", body: intent.bytes)
        try receipt.validate(); guard start == generation else { throw ClientError.cancelled }
        claims[receipt.claimId] = .init(receipt: receipt, intent: intent); return receipt
    }
    /// After restart, replay the retained claim intent first to restore this local binding from the server receipt.
    public func status(_ receipt: ChildInvitationClaimReceipt) async throws -> ChildInvitationClaimStatus {
        let claimed = try claimed(receipt)
        let result: ChildInvitationClaimStatus = try await perform(binding: claimed.intent.binding,
            path: "v1/child-invitations/claims/\(receipt.claimId)", method: "GET", query: [.init(name: "householdId", value: receipt.householdId)])
        try result.validate(claimID: receipt.claimId); return result
    }
    public func prepareFinish(receipt: ChildInvitationClaimReceipt, pairingCode: String) async throws -> ChildInvitationIntent {
        let start = generation; let claimed = try claimed(receipt)
        guard pairingCode == claimed.intent.pairingCode else { throw ClientError.configuration }
        let current = try await status(receipt)
        guard start == generation else { throw ClientError.cancelled }
        guard current.status == .approved else { throw ClientError.accessEnded }
        return try .init(binding: claimed.intent.binding, receipt: receipt, pairingCode: pairingCode)
    }
    /// The returned service credential is not installed or activated locally by this client.
    public func finish(_ intent: ChildInvitationIntent) async throws -> ChildEnrollmentReceipt {
        try intent.validate(); guard intent.kind == .finish, let householdID = intent.householdID else { throw ClientError.configuration }
        let receipt: ChildEnrollmentReceipt = try await perform(binding: intent.binding, path: "v1/child-invitations/finish", method: "POST", body: intent.bytes)
        try receipt.validate(householdID: householdID); try intent.validate(receipt); return receipt
    }
    public func close() { generation = UUID(); claims.removeAll(); challenges.removeAll(); admissions.removeAll() }
    private func claimed(_ receipt: ChildInvitationClaimReceipt) throws -> Claimed {
        try receipt.validate()
        guard let value = claims[receipt.claimId], value.receipt == receipt else { throw ClientError.accessEnded }
        return value
    }
    private func authenticated(binding: ChildInvitationBinding, generation start: UUID) async throws -> ChildInvitationAccess {
        let current = try await access(); try current.validate()
        guard start == generation else { throw ClientError.cancelled }
        guard current.binding == binding else { throw ClientError.accessEnded }; return current
    }
    private func perform<T: Decodable & Sendable>(binding: ChildInvitationBinding, path: String, method: String,
                                                 body: Data? = nil, query: [URLQueryItem] = []) async throws -> T {
        let start = generation; let current = try await authenticated(binding: binding, generation: start)
        var req = request(base: configuration.baseURL, path: path, method: method, token: current.accessToken, body: body)
        if !query.isEmpty {
            var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = query; req.url = components.url
        }
        let result: T = try await transport.json(req)
        _ = try await authenticated(binding: binding, generation: start)
        return result
    }
}
