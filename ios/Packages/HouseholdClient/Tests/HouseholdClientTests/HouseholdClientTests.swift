import XCTest
@testable import HouseholdClient

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    typealias Interceptor = (MockURLProtocol) -> Bool
    private static let callbackLock = NSLock()
    private static var callbacks: (handler: Handler?, intercept: Interceptor?) = (nil, nil)

    static var handler: Handler? {
        get { callbackLock.withLock { callbacks.handler } }
        set { callbackLock.withLock { callbacks.handler = newValue } }
    }

    static var intercept: Interceptor? {
        get { callbackLock.withLock { callbacks.intercept } }
        set { callbackLock.withLock { callbacks.intercept = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let callbacks = Self.callbackLock.withLock { Self.callbacks }
        if callbacks.intercept?(self) == true { return }
        do {
            guard let handler = callbacks.handler else { throw URLError(.notConnectedToInternet) }
            let (status, data) = try handler(request)
            finish(status: status, data: data)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    func finish(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class HeldResponse: @unchecked Sendable {
    private let lock = NSLock(); private var value: MockURLProtocol?
    func set(_ value: MockURLProtocol) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func finish(status: Int, data: Data = Data()) { lock.lock(); let saved = value; value = nil; lock.unlock(); saved?.finish(status: status, data: data) }
}
final class MemoryVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var token: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; token = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; token = nil }
}
final class HouseholdClientTests: XCTestCase {
    let household = "00000000-0000-4000-8000-000000000001"
    let member = "00000000-0000-4000-8000-000000000002"
    override func tearDown() { MockURLProtocol.handler = nil; MockURLProtocol.intercept = nil; super.tearDown() }
    func transport() -> HTTPTransport {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return HTTPTransport(session: URLSession(configuration: config))
    }
    func auth(_ vault: MemoryVault = .init()) throws -> AdultAuth {
        AdultAuth(configuration: try .init(projectURL: URL(string: "https://identity.test")!, publishableKey: "sb_publishable_unit_test"), vault: vault, transport: transport())
    }
    func authResponse(_ request: URLRequest) -> (Int, Data)? {
        if request.url!.path == "/auth/v1/verify" || request.url!.path == "/auth/v1/token" {
            return (200, Data(#"{"access_token":"access","refresh_token":"rotated","expires_in":3600,"user":{"id":"account","email":"adult@example.test","email_confirmed_at":"2026-01-01T00:00:00Z"}}"#.utf8))
        }
        if request.url!.path == "/auth/v1/user" { return (200, Data(#"{"id":"account","email":"adult@example.test","email_confirmed_at":"2026-01-01T00:00:00Z"}"#.utf8)) }
        return nil
    }
    func testOTPVerifiesIdentityAndRotatesRefreshOnlyInVault() async throws {
        let vault = MemoryVault(); let auth = try auth(vault); var paths: [String] = []
        MockURLProtocol.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_unit_test")
            return self.authResponse(request)!
        }
        let result = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        XCTAssertEqual(result.identity.subject, "account")
        XCTAssertEqual(try vault.read(), "rotated")
        XCTAssertEqual(paths, ["/auth/v1/verify", "/auth/v1/user"])
    }
    func testIdentityMismatchNeverStoresSession() async throws {
        let vault = MemoryVault(); let auth = try auth(vault)
        MockURLProtocol.handler = { request in
            if request.url!.path == "/auth/v1/user" { return (200, Data(#"{"id":"other","email_confirmed_at":"date"}"#.utf8)) }
            return self.authResponse(request)!
        }
        do { _ = try await auth.verifyEmailCode(email: "x", code: "123456"); XCTFail("Accepted wrong identity") }
        catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
        XCTAssertNil(try vault.read())
    }
    func testSignOutClearsLocalCredentialsWhenNetworkFails() async throws {
        let vault = MemoryVault(); let auth = try auth(vault)
        MockURLProtocol.handler = { self.authResponse($0)! }
        _ = try await auth.verifyEmailCode(email: "x", code: "123456")
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await auth.signOut(); XCTFail("Expected network failure") } catch {}
        XCTAssertNil(try vault.read())
        do { _ = try await auth.access(); XCTFail("Signed out token reused") } catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
    }
    func testDurableRetryPreservesExactEnvelopeAndRejectsChangedKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("outbox.json"); let store = OperationOutbox(url: url)
        let key = UUID(); let envelope = CommandEnvelope(replayWindow: "original-window", clientKey: key, shopId: "shop", kind: "request.send", base: .init(shopRevision: 3, authorityEpoch: 2), body: ["originalItem": .string("Rice")])
        let operation = try PendingOperation(envelope: envelope, householdID: household, memberID: member, deviceID: "device")
        try await store.append(operation); try await store.append(operation)
        let restored = try await OperationOutbox(url: url).operations()
        XCTAssertEqual(restored, [operation]); XCTAssertEqual(try JSONDecoder().decode(CommandEnvelope.self, from: restored[0].bytes), envelope)
        let changed = CommandEnvelope(replayWindow: "new-window", clientKey: key, shopId: "shop", kind: "request.send", base: .init(shopRevision: 4, authorityEpoch: 2), body: ["originalItem": .string("Beans")])
        do { try await store.append(PendingOperation(envelope: changed, householdID: household, memberID: member, deviceID: "device")); XCTFail("Changed key accepted") } catch {}
        let retained = try await store.operations(); XCTAssertEqual(retained, [operation])
    }
    func testServiceRetriesIdenticalBodyAndClearsRevokedScope() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var bodies: [Data] = []; var revoked = false
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-secret"}"#.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "device-secret")
            if revoked { return (403, Data()) }
            if request.url!.path.hasSuffix("/bootstrap") {
                return (200, Data("{\"household\":{\"id\":\"\(self.household)\",\"label\":\"Home\"},\"memberId\":\"\(self.member)\",\"role\":\"contributor\",\"shopId\":\"shop\",\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[]}".utf8))
            }
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
            }
            bodies.append(bytes); throw URLError(.networkConnectionLost)
        }
        _ = try await auth.verifyEmailCode(email: "x", code: "123456")
        let bootstrap = try await service.enroll(householdID: household)
        let operation = try await service.prepare(envelope: .init(replayWindow: "window", shopId: "shop", kind: "request.send", base: .init(shopRevision: 0, authorityEpoch: 0), body: ["originalItem": .string("Rice")]), bootstrap: bootstrap)
        for _ in 0..<2 { do { _ = try await service.execute(operation); XCTFail("Expected transport failure") } catch { XCTAssertEqual(error as? ClientError, .transport) } }
        XCTAssertEqual(bodies, [operation.bytes, operation.bytes])
        revoked = true
        do { _ = try await service.bootstrap(); XCTFail("Revoked access") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.bootstrap(); XCTFail("Scope retained") } catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
    }
    func testRequestingEmailCodeDoesNotSignIn() async throws {
        let vault = MemoryVault(); let auth = try auth(vault)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/auth/v1/otp")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data("{}".utf8))
        }
        try await auth.requestEmailCode(email: "adult@example.test")
        XCTAssertNil(try vault.read())
        do { _ = try await auth.access(); XCTFail("OTP delivery granted access") }
        catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
    }
    func testInvalidRefreshClearsStoredCredential() async throws {
        let vault = MemoryVault(); try vault.write("expired")
        let auth = try auth(vault)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/auth/v1/token")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "refresh_token")
            return (400, Data(#"{"error_code":"refresh_token_not_found"}"#.utf8))
        }
        do { _ = try await auth.access(); XCTFail("Invalid refresh accepted") } catch {}
        XCTAssertNil(try vault.read())
    }
    func testRetryIsBoundedHonorsServerDelayAndStopsConflicts() {
        let policy = RetryPolicy(maximumAttempts: 5)
        XCTAssertEqual(policy.delay(attempt: 1, error: .transport, jitter: 0), 2)
        XCTAssertEqual(policy.delay(attempt: 1, error: .service(status: 429, code: "limited", correlationID: nil, retryAfter: 120), jitter: 0), 120)
        XCTAssertNil(policy.delay(attempt: 5, error: .transport))
        XCTAssertNil(policy.delay(attempt: 1, error: .service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil)))
        XCTAssertNil(policy.delay(attempt: 1, error: .accessEnded))
    }
    func testEnrollmentResumesSameDeviceAfterClientRecreation() async throws {
        let auth = try auth(); let vault = MemoryVault(); var registrations = 0
        let config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            if request.url!.path.hasSuffix("/devices") {
                registrations += 1
                return (200, Data(#"{"deviceId":"original-device","deviceToken":"original-token"}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "original-token")
            return (200, Data("{\"household\":{\"id\":\"\(self.household)\",\"label\":\"Home\"},\"memberId\":\"\(self.member)\",\"role\":\"contributor\",\"shopId\":null,\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[]}".utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let first = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        _ = try await first.enroll(householdID: household)
        let recreated = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        _ = try await recreated.enroll(householdID: household)
        XCTAssertEqual(registrations, 1)
    }
    private final class EnrollmentServer {
        let household: String, member: String
        var subject = "first-adult", session = UUID().uuidString
        struct Binding: Equatable { let subject: String; let session: String }
        var deviceSessions: [String: Binding] = [:]
        var binding: Binding { .init(subject: subject, session: session) }
        var revoked = false
        init(household: String, member: String) { self.household = household; self.member = member }

        func response(_ request: URLRequest) -> (Int, Data) {
            let path = request.url!.path
            let user = ["id": subject, "email": "adult@example.test", "email_confirmed_at": "2026-01-01T00:00:00Z"]
            func ok(_ body: [String: Any]) -> (Int, Data) { (200, try! JSONSerialization.data(withJSONObject: body)) }
            if path == "/auth/v1/user" { return ok(user) }
            if path == "/auth/v1/verify" || path == "/auth/v1/token" {
                let claims = ["iss": "https://identity.test/auth/v1", "sub": subject, "session_id": session]
                let payload = GuardianSecret.canonical(try! JSONEncoder().encode(claims))
                return ok(["access_token": "header." + payload + ".signature", "refresh_token": "rotated", "expires_in": 3600, "user": user])
            }
            if path.hasSuffix("/devices") {
                let token = "device-token-" + String(deviceSessions.count + 1)
                deviceSessions[token] = binding
                return ok(["deviceId": UUID().uuidString, "deviceToken": token])
            }
            if path.hasSuffix("/bootstrap") {
                let token = request.value(forHTTPHeaderField: "X-Device-Token") ?? ""
                guard !revoked, deviceSessions[token] == binding else { return (401, Data()) }
                return ok(["household": ["id": household, "label": "Home"], "memberId": member,
                           "role": "contributor", "enrolled": true, "queueConsent": false, "capabilities": ["own_requests"]])
            }
            XCTFail("Unexpected request at " + path); return (400, Data())
        }
    }

    func testFreshLoginReenrollsWithoutReplayingAnotherSessionOrAdultsQueue() async throws {
        let server = EnrollmentServer(household: household, member: member)
        MockURLProtocol.handler = server.response
        let auth = try auth(), vault = MemoryVault()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: vault, transport: transport())
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let original = try await service.enroll(householdID: household)
        let envelope = CommandEnvelope(replayWindow: "original", shopId: "shop", kind: "request.send",
                                       base: .init(shopRevision: 1, authorityEpoch: 1), body: ["originalItem": .string("Rice")])
        var pending = try await service.prepare(envelope: envelope, bootstrap: original)
        let newSession = UUID().uuidString
        for subject in [server.subject, "other-adult"] {
            // Change the session first, then the subject alone to exercise both boundaries.
            server.subject = subject; server.session = newSession
            _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "654321")
            let next = try await service.enroll(householdID: household)
            do { _ = try await service.execute(pending); XCTFail("A different enrollment replayed the old queue") }
            catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
            pending = try await service.prepare(envelope: envelope, bootstrap: next)
        }
        XCTAssertEqual(server.deviceSessions.count, 3)
    }

    func testLegacyEnrollmentResumesOnRefreshAndRevocationCannotRegisterAnotherDevice() async throws {
        let server = EnrollmentServer(household: household, member: member)
        MockURLProtocol.handler = server.response
        let refresh = MemoryVault(), devices = MemoryVault()
        let config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        let firstAuth = try auth(refresh)
        _ = try await firstAuth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let first = HouseholdService(configuration: config, auth: firstAuth, deviceVault: devices, transport: transport())
        _ = try await first.enroll(householdID: household)
        let raw = Data(try XCTUnwrap(devices.read()).utf8)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        legacy.removeValue(forKey: "sessionID")
        let legacyRecord = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
        try devices.write(legacyRecord)
        let restored = HouseholdService(configuration: config, auth: try auth(refresh), deviceVault: devices, transport: transport())
        _ = try await restored.enroll(householdID: household)
        XCTAssertEqual(server.deviceSessions.count, 1)
        let migrated = try XCTUnwrap(devices.read())
        XCTAssertEqual(try (JSONSerialization.jsonObject(with: Data(migrated.utf8)) as? [String: Any])?["sessionID"] as? String, server.session)
        server.revoked = true
        for record in [migrated, legacyRecord] {
            try devices.write(record)
            do { _ = try await restored.enroll(householdID: household); XCTFail("Revoked enrollment was accepted") }
            catch { XCTAssertEqual(error as? ClientError, .sessionNeeded) }
            XCTAssertEqual(server.deviceSessions.count, 1)
        }
    }
    func testRejectsInsecureOrPrivilegedAuthConfiguration() throws {
        XCTAssertThrowsError(try ServiceConfiguration(baseURL: URL(string: "http://example.test")!))
        XCTAssertThrowsError(try AdultAuthConfiguration(projectURL: URL(string: "https://example.test")!, publishableKey: "sb_secret_forbidden"))
    }

    func testAllDeviceSignOutRequestsGlobalScope() async throws {
        let auth = try auth(); var scope: String?
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            scope = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            return (204, Data())
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        try await auth.signOut(allDevices: true)
        XCTAssertEqual(scope, "global")
    }

    func testSignOutInvalidatesInflightVerification() async throws {
        let vault = MemoryVault(), held = HeldResponse(), arrived = expectation(description: "User verification in flight")
        let auth = try auth(vault)
        MockURLProtocol.handler = { self.authResponse($0)! }
        MockURLProtocol.intercept = { task in
            guard task.request.url!.path == "/auth/v1/user" else { return false }
            held.set(task); arrived.fulfill(); return true
        }
        let verification = Task { try await auth.verifyEmailCode(email: "adult@example.test", code: "123456") }
        await fulfillment(of: [arrived], timeout: 2)
        try await auth.signOut()
        held.finish(status: 200, data: Data(#"{"id":"account","email_confirmed_at":"date"}"#.utf8))
        do { _ = try await verification.value; XCTFail("Old verification revived sign-in") }
        catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        XCTAssertNil(try vault.read())
    }

    func testOldHouseholdFailureCannotClearNewEnrollment() async throws {
        let auth = try auth(), vault = MemoryVault(), held = HeldResponse(), arrived = expectation(description: "Old bootstrap pending")
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: vault, transport: transport())
        let second = "00000000-0000-4000-8000-000000000003"
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-secret"}"#.utf8)) }
            let selected = request.url!.path.contains(second) ? second : self.household
            return (200, Data("{\"household\":{\"id\":\"\(selected)\",\"label\":\"Home\"},\"memberId\":\"\(self.member)\",\"role\":\"contributor\",\"shopId\":null,\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[]}".utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        MockURLProtocol.intercept = { task in
            guard task.request.url!.path.contains(self.household), task.request.url!.path.hasSuffix("/bootstrap") else { return false }
            held.set(task); arrived.fulfill(); return true
        }
        let old = Task { try await service.bootstrap() }
        await fulfillment(of: [arrived], timeout: 2)
        _ = try await service.enroll(householdID: second)
        held.finish(status: 403)
        do { _ = try await old.value; XCTFail("Old response accepted") } catch { XCTAssertEqual(error as? ClientError, .cancelled) }
        let current = try await service.bootstrap()
        XCTAssertEqual(current.household.id, second)
        let token = try await service.currentDeviceToken(householdID: second, memberID: member)
        XCTAssertEqual(token, "device-secret")
        do { _ = try await service.currentDeviceToken(householdID: household, memberID: member); XCTFail("Wrong household token") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.currentDeviceToken(householdID: second, memberID: "someone-else"); XCTFail("Wrong actor token") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
    }

    func testOwnRequestCursorUsesQueryAndRequiresUUID() async throws {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var cursors: [String?] = []
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-secret"}"#.utf8)) }
            if request.url!.path.hasSuffix("/bootstrap") { return (200, Data("{\"household\":{\"id\":\"\(self.household)\",\"label\":\"Home\"},\"memberId\":\"\(self.member)\",\"role\":\"contributor\",\"shopId\":null,\"enrolled\":true,\"queueConsent\":false,\"capabilities\":[]}".utf8)) }
            XCTAssertEqual(request.url!.path, "/v1/households/\(self.household)/requests/mine")
            cursors.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
            return (200, Data(#"{"requests":[],"nextCursor":null}"#.utf8))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        _ = try await service.ownRequests(cursor: member)
        do { _ = try await service.ownRequests(cursor: "../other"); XCTFail("Invalid cursor accepted") }
        catch { XCTAssertEqual(error as? ClientError, .configuration) }
        XCTAssertEqual(cursors, [member])
    }
}
