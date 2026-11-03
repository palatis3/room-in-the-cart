import Foundation

public struct AdultAuthConfiguration: Sendable {
    public let projectURL: URL
    public let publishableKey: String
    public init(projectURL: URL, publishableKey: String) throws {
        _ = try ServiceConfiguration(baseURL: projectURL)
        guard publishableKey.hasPrefix("sb_publishable_"), publishableKey.count > 15 else { throw ClientError.configuration }
        self.projectURL = projectURL; self.publishableKey = publishableKey
    }
}
public struct VerifiedAdultIdentity: Equatable, Sendable {
    public let subject: String
    public let email: String?
}
public struct AdultAccess: Sendable {
    public let identity: VerifiedAdultIdentity
    public let accessToken: String
    public let expiresAt: Date
}
/// Managed login proves an account identity only. All household roles and object grants come from the service.
public actor AdultAuth {
    private let config: AdultAuthConfiguration
    private let transport: HTTPTransport
    private let vault: any RefreshTokenVault
    private let now: @Sendable () -> Date
    private var current: AdultAccess?
    private var generation = UUID()
    private var refreshTask: Task<AdultAccess, Error>?
    public init(configuration: AdultAuthConfiguration, vault: any RefreshTokenVault,
                transport: HTTPTransport = .init(), now: @escaping @Sendable () -> Date = { Date() }) {
        config = configuration; self.vault = vault; self.transport = transport; self.now = now
    }
    public func requestEmailCode(email: String) async throws {
        struct Body: Encodable { let email: String; let create_user: Bool }
        _ = try await transport.send(authRequest("otp", body: try encoded(Body(email: email, create_user: true))))
    }
    public func verifyEmailCode(email: String, code: String) async throws -> AdultAccess {
        struct Body: Encodable { let email: String; let token: String; let type = "email" }
        // A newly verified account must not race a refresh of the previous account.
        generation = UUID(); current = nil; refreshTask?.cancel(); refreshTask = nil
        try vault.clear()
        let start = generation
        let session: TokenResponse = try await transport.json(authRequest("verify", body: try encoded(Body(email: email, token: code))))
        return try await accept(session, generation: start)
    }
    /// Coalesces rotating-token refreshes; a sign-out invalidates all in-flight completions.
    public func access() async throws -> AdultAccess {
        if let current, current.expiresAt > now().addingTimeInterval(60) { return current }
        if let refreshTask { return try await refreshTask.value }
        let start = generation
        let task = Task { try await self.refresh(generation: start) }
        refreshTask = task
        defer { if generation == start { refreshTask = nil } }
        return try await task.value
    }
    private func refresh(generation start: UUID) async throws -> AdultAccess {
        guard let refresh = try vault.read() else { throw ClientError.sessionNeeded }
        struct Body: Encodable { let refresh_token: String }
        var request = authRequest("token", body: try encoded(Body(refresh_token: refresh)))
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "grant_type", value: "refresh_token")]; request.url = components.url
        do {
            let session: TokenResponse = try await transport.json(request)
            return try await accept(session, generation: start)
        } catch {
            if generation == start, let failure = error as? ClientError {
                let invalid: Bool
                switch failure {
                case .sessionNeeded, .accessEnded: invalid = true
                case .service(let status, _, _, _): invalid = status == 400 || status == 422
                default: invalid = false
                }
                if invalid { current = nil; try vault.clear() }
            }
            throw error
        }
    }
    private func accept(_ session: TokenResponse, generation start: UUID) async throws -> AdultAccess {
        guard generation == start else { throw ClientError.cancelled }
        guard !session.access_token.isEmpty, !session.refresh_token.isEmpty, session.expires_in > 0,
              !session.user.id.isEmpty else { throw ClientError.sessionNeeded }
        // Preserve a rotated refresh token if the subsequent user verification loses the network.
        // This does not grant UI access; /user must still succeed before returning an identity.
        try vault.write(session.refresh_token)
        do {
            let user: UserResponse = try await transport.json(authRequest("user", method: "GET", token: session.access_token))
            guard generation == start else { throw ClientError.cancelled }
            guard user.id == session.user.id, user.email_confirmed_at != nil else { throw ClientError.sessionNeeded }
            let value = AdultAccess(identity: .init(subject: user.id, email: user.email), accessToken: session.access_token,
                                    expiresAt: now().addingTimeInterval(session.expires_in))
            current = value
            return value
        } catch {
            if generation == start, let failure = error as? ClientError,
               failure == .sessionNeeded || failure == .accessEnded { current = nil; try vault.clear() }
            throw error
        }
    }
    public func clearLocalSession() throws {
        generation = UUID(); current = nil; refreshTask?.cancel(); refreshTask = nil
        try vault.clear()
    }
    /// Clears local credentials first, even if remote revocation cannot be reached. Caller must also tear down household projections.
    public func signOut(allDevices: Bool = false) async throws {
        let token = current?.accessToken
        try clearLocalSession()
        guard let token else { return }
        var request = authRequest("logout", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "scope", value: allDevices ? "global" : "local")]; request.url = components.url
        _ = try await transport.send(request)
    }
    private func authRequest(_ path: String, method: String = "POST", token: String? = nil, body: Data? = nil) -> URLRequest {
        var result = request(base: config.projectURL.appendingPathComponent("auth/v1"), path: path, method: method, token: token, body: body)
        result.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        return result
    }
}
private struct TokenResponse: Decodable, Sendable { let access_token: String; let refresh_token: String; let expires_in: TimeInterval; let user: UserResponse }
private struct UserResponse: Decodable, Sendable { let id: String; let email: String?; let email_confirmed_at: String? }
