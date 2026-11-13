import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedOperationUndoParentTests: XCTestCase {
    func testOriginalShopOutboxCancelApplyLostReplyRelaunchAndExactRetry() async throws {
        let fixture = try UndoParentFixture(); UndoParentProtocol.registry.add(fixture)
        defer { UndoParentProtocol.registry.remove(fixture.host) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UndoParentProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: configuration)), url = URL(string: "https://\(fixture.host)")!
        let auth = AdultAuth(configuration: try .init(projectURL: url, publishableKey: "sb_publishable_fixture"), vault: UndoParentVault(), transport: transport)
        let vault = UndoParentVault(), config = try ServiceConfiguration(baseURL: url)
        var service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport)
        _ = try await auth.verifyEmailCode(email: "fixture@example.test", code: "123456")
        let household = "00000000-0000-4000-8000-000000000001"
        let scope = try await service.enroll(householdID: household)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxURL = directory.appendingPathComponent("shared-shop.json"), outbox = OperationOutbox(url: directory.appendingPathComponent("shared-shop.json"))
        let parent = HouseholdShopModel(scope: scope, service: service, outbox: outbox, onConfirmed: {}, onAccessEnded: {})
        let model = SharedOperationUndoModel(access: parent), known = try OperationUndoFixture.review()
        await model.load(); XCTAssertEqual(model.history, [known.target])
        await model.select(known.target); XCTAssertNotNil(model.candidate); model.cancel()
        let cancelled = try await outbox.operations(); XCTAssertTrue(cancelled.isEmpty); XCTAssertTrue(fixture.commands.isEmpty)
        await model.load(); await model.select(known.target)
        try model.acknowledgePack(known.request.packs[0]); await model.preview(); XCTAssertNotNil(model.review)
        model.monetaryAcknowledged = true; await model.apply()
        let saved = try await outbox.operations(), operation = try XCTUnwrap(saved.first)
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(parent.pending, operation); XCTAssertEqual(fixture.commands, [operation.bytes]); XCTAssertEqual(fixture.commits, 1)
        service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport)
        let reopenedScope = try await service.enroll(householdID: household)
        let reopened = HouseholdShopModel(scope: reopenedScope, service: service, outbox: OperationOutbox(url: outboxURL), onConfirmed: {}, onAccessEnded: {})
        let relaunched = SharedOperationUndoModel(access: reopened)
        await relaunched.load(); XCTAssertTrue(relaunched.pending); XCTAssertNil(relaunched.candidate); XCTAssertNil(relaunched.review)
        await relaunched.retry()
        XCTAssertEqual(fixture.commands, [operation.bytes, operation.bytes]); XCTAssertEqual(fixture.commits, 1)
        XCTAssertNil(reopened.pending); let remaining = try await outbox.operations(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(reopened.shop?.shopRevision, 8); XCTAssertEqual(reopened.shop?.lines.first?.packs, 2)
        guard case .confirmed(let receipt) = reopened.delivery else { return XCTFail("Reserved Undo receipt was not confirmed") }
        XCTAssertEqual(receipt.operationId, known.response.preview.receipt.operationId.string)
    }
}

private final class UndoParentFixture: @unchecked Sendable {
    let host = "undo-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private let f: [String: Any]
    private var sent: [Data] = [], committed = 0
    var commands: [Data] { lock.lock(); defer { lock.unlock() }; return sent }
    var commits: Int { lock.lock(); defer { lock.unlock() }; return committed }
    init() throws { f = try OperationUndoFixture.object() }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        return data
    }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path, shop = f["shop"] as! [String: Any], id = shop["shopId"] as! String
        if path.hasSuffix("/auth/v1/verify") { return try data(["access_token": "adult", "refresh_token": "refresh", "expires_in": 3600, "user": ["id": "adult", "email_confirmed_at": "date"]]) }
        if path.hasSuffix("/auth/v1/user") { return try data(["id": "adult", "email_confirmed_at": "date"]) }
        if path.hasSuffix("/devices") { return try data(["deviceId": "device", "deviceToken": "token"]) }
        if path.hasSuffix("/bootstrap") { return try data(["household": ["id": "00000000-0000-4000-8000-000000000001", "label": "Home"], "memberId": "00000000-0000-4000-8000-000000000009", "role": "shopper", "shopId": id, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_commands", "shopper_inbox", "request_preview"]]) }
        if path.hasSuffix("/replay-windows") { return try data(["id": UUID().uuidString.lowercased(), "expiresAt": "2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/demand/operations") { guard committed == 0 else { throw ClientError.configuration }; return try data(f["history"]!) }
        if path.hasSuffix("/operation-undo-candidates") || path.hasSuffix("/operation-undo-previews") {
            guard committed == 0, request.httpMethod == "POST" else { throw ClientError.configuration }
            let candidate = f["candidate"] as! [String: Any]
            var expected: [String: Any] = ["targetOperationId": candidate["targetOperationId"]!, "base": candidate["base"]!]
            let preview = path.hasSuffix("/operation-undo-previews")
            if preview { expected["effectDigest"] = candidate["effectDigest"]; expected["packs"] = f["packs"] }
            let received = try JSONDecoder().decode([String: JSONValue].self, from: body(request))
            let expectedBody: [String: JSONValue] = try OperationUndoFixture.decode(expected)
            guard received == expectedBody else { throw ClientError.invalidResponse }
            return try data(f[preview ? "response" : "candidate"]!)
        }
        if path.hasSuffix("/demand") { guard committed == 0 else { throw ClientError.configuration }; return try data(f["page"]!) }
        if path.hasSuffix("/shops/" + id) {
            var value = shop
            if committed != 0 {
                value["shopRevision"] = 8
                let action = (f["candidate"] as! [String: Any])["action"] as! [String: Any], body = action["body"] as! [String: Any]
                value["lines"] = body["lines"]
            }
            return try data(value)
        }
        guard path.hasSuffix("/commands") else { throw ClientError.configuration }
        let bytes = body(request), envelope = try JSONDecoder().decode(CommandEnvelope.self, from: bytes)
        let action = (f["candidate"] as! [String: Any])["action"] as! [String: Any]
        var expected = action["body"] as! [String: Any]
        let response = f["response"] as! [String: Any], receipt = response["receipt"] as! [String: Any]
        expected["demandReview"] = ["previewId": response["previewId"]!, "previewDigest": response["previewDigest"]!]
        let expectedBody: [String: JSONValue] = try OperationUndoFixture.decode(expected)
        guard envelope.kind == "shop.patch", envelope.shopId == id, envelope.base == .init(shopRevision: 7, authorityEpoch: 2), envelope.body == expectedBody else { throw ClientError.invalidResponse }
        sent.append(bytes)
        if committed == 0 { committed = 1; throw URLError(.networkConnectionLost) }
        guard sent.first == bytes else { throw ClientError.invalidResponse }
        return try data(["operationId": receipt["operationId"]!, "kind": "shop.patch", "shopId": id, "shopRevision": 8, "authorityEpoch": 2, "disposition": "patched"])
    }
}
private final class UndoParentVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var token: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; token = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; token = nil }
}
private final class UndoParentRegistry: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: UndoParentFixture] = [:]
    func add(_ value: UndoParentFixture) { lock.lock(); defer { lock.unlock() }; values[value.host] = value }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
    func fixture(_ key: String?) -> UndoParentFixture? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
}
private final class UndoParentProtocol: URLProtocol {
    static let registry = UndoParentRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.fixture(request.url?.host) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let fixture = Self.registry.fixture(request.url?.host) else { throw ClientError.configuration }
            let bytes = try fixture.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
