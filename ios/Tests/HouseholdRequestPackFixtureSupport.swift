@testable import RoomInTheCart
import Foundation
import HouseholdClient

final class S24FixtureVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
final class S24FixtureServer: @unchecked Sendable {
    static let household = "11111111-1111-4111-8111-111111111111"
    static let member = "22222222-2222-4222-8222-222222222222"
    static let shop = "33333333-3333-4333-8333-333333333333"
    static let requestID = "44444444-4444-4444-8444-444444444444"
    private let lock = NSRecursiveLock()
    let host = "s24-" + UUID().uuidString.lowercased() + ".invalid"
    var baseURL: URL { URL(string: "https://" + host)! }
    private var session: URLSession?
    private var closed = false
    private var interceptor: ((S24FixtureProtocol) -> Bool)?
    var intercept: ((S24FixtureProtocol) -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return interceptor }
        set { lock.lock(); defer { lock.unlock() }; interceptor = newValue }
    }
    func makeSession() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        precondition(!closed, "A closed fixture cannot be reused")
        if let session { return session }
        S24FixtureProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S24FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        return session
    }
    func close() {
        lock.lock()
        closed = true
        let session = self.session; self.session = nil
        interceptor = nil; changeHandler = nil
        lock.unlock()
        S24FixtureProtocol.remove(host: host)
        session?.invalidateAndCancel()
    }
    deinit { close() }

    private var recordedPreview: [String: Any]?
    private var recordedLines: [[String: Any]] = []
    private var receipts: [String: [String: Any]] = [:]
    private var count = 0
    private var previews = 0
    private var revision = 1
    func advanceSource() { lock.lock(); defer { lock.unlock() }; revision += 1 }
    private var accessRevoked = false
    func revokeAccess() { lock.lock(); defer { lock.unlock() }; accessRevoked = true }
    let includeExistingLine: Bool
    let cerealScenario: Bool
    let includeMealFacts: Bool
    init(includeExistingLine: Bool = false, cerealScenario: Bool = false, includeMealFacts: Bool = true) {
        self.includeExistingLine = includeExistingLine; self.cerealScenario = cerealScenario; self.includeMealFacts = includeMealFacts
    }
    static let protectedLunches: [[String: Any]] = [
        ["occurrenceId":"88888888-8888-4888-8888-888888888888", "revision":1,
         "meal":["title":"Sam’s wrap lunch", "day":"2026-11-04", "kind":"lunch", "portions":1, "protected":true]],
        ["occurrenceId":"99999999-9999-4999-8999-999999999999", "revision":1,
         "meal":["title":"Mia’s wrap lunch", "day":"2026-11-05", "kind":"lunch", "portions":1, "protected":true]]
    ]
    private var changeHandler: ((Int, Int) -> Void)?
    var changed: ((Int, Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changeHandler }
        set { lock.lock(); defer { lock.unlock() }; changeHandler = newValue }
    }
    var previewBody: [String: Any]? { lock.lock(); defer { lock.unlock() }; return recordedPreview }
    var commandCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var previewCount: Int { lock.lock(); defer { lock.unlock() }; return previews }
    var lineCount: Int { lock.lock(); defer { lock.unlock() }; return recordedLines.count }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock()
        var change: (((Int, Int) -> Void), Int, Int)?
        defer {
            lock.unlock()
            if let (callback, count, lines) = change { callback(count, lines) }
        }
        guard !closed, request.url?.host == host else { throw URLError(.unsupportedURL) }
        let path = request.url!.path
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; bytes.append(buffer, count: size) }
        }
        let input = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        func json(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        if path == "/auth/v1/verify" { return try json(["access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"user":["id":"fixture-adult","email_confirmed_at":"date"]]) }
        if path == "/auth/v1/user" { return try json(["id":"fixture-adult","email_confirmed_at":"date"]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":"fixture-device","deviceToken":"fixture-device-token"]) }
        if path.hasSuffix("/bootstrap") { return try json(["household":["id":Self.household,"label":"Fixture"],"memberId":Self.member,"role":"shopper","shopId":Self.shop,"enrolled":true,"queueConsent":false,"capabilities":["shopper_inbox","request_preview","shopper_commands"]]) }
        let requestRow: [String: Any] = ["requestId":Self.requestID,"shopId":Self.shop,"revision":recordedLines.isEmpty ? 1 : 2,"originalItem":cerealScenario ? "Brown rice cereal" : "Wraps for lunch","ownQuantity":cerealScenario ? "1 box" : "8 wraps","authoredAt":"2026-11-03T00:00:00Z","receivedAt":"2026-11-03T00:00:01Z","route":"current","status":recordedLines.isEmpty ? "pending" : "added","ownActionAllowed":recordedLines.isEmpty,"authorAlias":"Sam"]
        if path.hasSuffix("/inbox") { return try json(["requests":[requestRow],"nextCursor":NSNull()]) }
        if path.hasSuffix("/shops/" + Self.shop) {
            if accessRevoked { return (403, Data()) }
            let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: cerealScenario ? 3800 : 500, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(3600))
            let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote))
            var shop: [String: Any] = ["shopId":Self.shop,"shopRevision":revision + (recordedLines.isEmpty ? 0 : 1),"authorityEpoch":1,"phase":"draft","quote":data,"lines":recordedLines + (cerealScenario ? [["lineId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","originalItem":"Original pickup items","packs":1,"unitPriceMinor":3720,"feeEligible":true]] : []) + (includeExistingLine ? [["lineId":"77777777-7777-4777-8777-777777777777","originalItem":"Existing wraps","packs":1,"unitPriceMinor":0,"feeEligible":true]] : [])]
            if includeMealFacts { shop["meals"] = Self.protectedLunches }
            return try json(shop)
        }
        if path.hasSuffix("/previews") {
            previews += 1
            recordedPreview = input
            let decision = input["decision"] as? [String: Any] ?? [:]
            let line = decision["line"] as? [String: Any]
            let unit = line?["unitPriceMinor"] as? Int
            let before = cerealScenario ? 3720 : 0
            let cap = cerealScenario ? 3800 : 500
            let change: Int? = decision["choice"] as? String == "add" ? unit.map { $0 * (line?["packs"] as? Int ?? 1) } : 0
            let total = change.map { before + $0 }
            func budget(_ amount: Int?) -> [String: Any] { ["currency":"USD","totalMinor":amount as Any? ?? NSNull(),"overCapMinor":amount.map { max(0,$0-cap) } as Any? ?? NSNull(),"headroomMinor":amount.map { max(0,cap-$0) } as Any? ?? NSNull(),"status":amount.map { $0 > cap ? "overCap" : "withinCap" } ?? "unresolved","scope":"wholeCheckout","missing":amount == nil ? ["line_price"] : [],"lowerBoundMinor":amount ?? before,"upperBoundMinor":amount as Any? ?? NSNull(),"wholeCheckoutWithinCap":amount.map { $0 <= cap } ?? false] }
            return try json(["previewId":"55555555-5555-4555-8555-555555555555","expiresAt":"2099-01-01T00:00:00Z","shopRevision":revision,"authorityEpoch":1,"requestRevision":1,"choice":decision["choice"]!,"before":budget(before),"after":budget(total),"changeMinor":change as Any? ?? NSNull(),"requiresOverageAcceptance":total.map { $0 > cap } ?? false,"requiresUnknownAcceptance":total == nil])
        }
        if path.hasSuffix("/replay-windows") { return try json(["id":"66666666-6666-4666-8666-666666666666","expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands"), let key = input["clientKey"] as? String {
            count += 1
            if let receipt = receipts[key] { if let callback = changeHandler { change = (callback, count, recordedLines.count) }; return try json(receipt) }
            guard input["kind"] as? String == "request.apply", let decision = recordedPreview?["decision"] as? [String: Any] else { throw URLError(.badServerResponse) }
            if let line = decision["line"] as? [String: Any] { recordedLines.append(line) }
            let receipt: [String: Any] = ["operationId":UUID().uuidString,"kind":"request.apply","shopId":Self.shop,"shopRevision":2,"authorityEpoch":1,"disposition":"added","requestId":Self.requestID,"requestRevision":2]
            receipts[key] = receipt; if let callback = changeHandler { change = (callback, count, recordedLines.count) }; return try json(receipt)
        }
        throw URLError(.unsupportedURL)
    }
}
// Registry entries never own a fixture. Tests own it until teardown; a loading
// protocol retains its original server until completion/cancellation.
private final class S24WeakServer {
    weak var value: S24FixtureServer?
    init(_ value: S24FixtureServer) { self.value = value }
}
final class S24FixtureProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var servers: [String: S24WeakServer] = [:]
    fileprivate static func register(_ server: S24FixtureServer) {
        registryLock.lock(); defer { registryLock.unlock() }
        servers[server.host] = S24WeakServer(server)
    }
    fileprivate static func remove(host: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        servers.removeValue(forKey: host)
    }
    private static func server(for request: URLRequest) -> S24FixtureServer? {
        registryLock.lock(); defer { registryLock.unlock() }
        guard request.url?.scheme == "https", let host = request.url?.host else { return nil }
        return servers[host]?.value
    }
    private let responseLock = NSLock()
    private var boundServer: S24FixtureServer?
    private var finished = false
    // Claim all requests so an unknown destination fails here, never on a real network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        // Copy the interceptor before invoking it; no registry/server lock is held
        // during callbacks, which may change fixture state or hold this response.
        let intercept = server.intercept
        responseLock.lock()
        guard !finished else { responseLock.unlock(); return }
        boundServer = server
        responseLock.unlock()
        if intercept?(self) == true { return }
        finishResponse()
    }
    func finishResponse() {
        responseLock.lock()
        guard !finished, let server = boundServer else { responseLock.unlock(); return }
        finished = true; boundServer = nil
        responseLock.unlock()
        do {
            let (status, data) = try server.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        responseLock.lock()
        finished = true
        let server = boundServer; boundServer = nil
        responseLock.unlock()
        withExtendedLifetime(server) {}
    }
}
@MainActor func s24FixtureModel(server: S24FixtureServer, outboxURL: URL) async throws -> HouseholdInboxModel {
    let transport = HTTPTransport(session: server.makeSession())
    let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL,publishableKey:"sb_publishable_fixture_only"),vault:S24FixtureVault(),transport:transport)
    _ = try await auth.verifyEmailCode(email:"shopper@example.invalid",code:"123456")
    let service = HouseholdService(configuration: try .init(baseURL:server.baseURL),auth:auth,deviceVault:S24FixtureVault(),transport:transport)
    let bootstrap = try await service.enroll(householdID:S24FixtureServer.household)
    let model = HouseholdInboxModel(bootstrap:bootstrap,service:service,outbox:OperationOutbox(url:outboxURL),onAccessEnded:{})
    await model.load()
    return model
}
