@testable import RoomInTheCart
import Foundation
import HouseholdClient

final class S24FixtureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
final class S24FixtureServer: @unchecked Sendable {
    static let household = "11111111-1111-4111-8111-111111111111"
    static let member = "22222222-2222-4222-8222-222222222222"
    static let shop = "33333333-3333-4333-8333-333333333333"
    static let requestID = "44444444-4444-4444-8444-444444444444"
    private let lock = NSRecursiveLock()
    private var recordedPreview: [String: Any]?
    private var recordedLines: [[String: Any]] = []
    private var receipts: [String: [String: Any]] = [:]
    private var count = 0
    private var revision = 1
    func advanceSource() { lock.lock(); defer { lock.unlock() }; revision += 1 }
    let includeExistingLine: Bool
    init(includeExistingLine: Bool = false) { self.includeExistingLine = includeExistingLine }
    var changed: ((Int, Int) -> Void)?
    var previewBody: [String: Any]? { lock.lock(); defer { lock.unlock() }; return recordedPreview }
    var commandCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var lineCount: Int { lock.lock(); defer { lock.unlock() }; return recordedLines.count }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        guard request.url?.host?.hasSuffix(".invalid") == true else { throw URLError(.unsupportedURL) }
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
        let requestRow: [String: Any] = ["requestId":Self.requestID,"shopId":Self.shop,"revision":recordedLines.isEmpty ? 1 : 2,"originalItem":"Wraps for lunch","ownQuantity":"8 wraps","authoredAt":"2026-11-03T00:00:00Z","receivedAt":"2026-11-03T00:00:01Z","route":"current","status":recordedLines.isEmpty ? "pending" : "added","ownActionAllowed":recordedLines.isEmpty,"authorAlias":"Sam"]
        if path.hasSuffix("/inbox") { return try json(["requests":[requestRow],"nextCursor":NSNull()]) }
        if path.hasSuffix("/shops/" + Self.shop) {
            let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 500, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(3600))
            let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote))
            return try json(["shopId":Self.shop,"shopRevision":revision + (recordedLines.isEmpty ? 0 : 1),"authorityEpoch":1,"phase":"draft","quote":data,"lines":recordedLines + (includeExistingLine ? [["lineId":"77777777-7777-4777-8777-777777777777","originalItem":"Existing wraps","packs":1,"unitPriceMinor":0,"feeEligible":true]] : [])])
        }
        if path.hasSuffix("/previews") {
            recordedPreview = input
            let decision = input["decision"] as? [String: Any] ?? [:]
            let line = decision["line"] as? [String: Any]
            let unit = line?["unitPriceMinor"] as? Int
            let total: Int? = decision["choice"] as? String == "add" ? unit.map { $0 * (line?["packs"] as? Int ?? 1) } : 0
            func budget(_ amount: Int?) -> [String: Any] { ["currency":"USD","totalMinor":amount as Any? ?? NSNull(),"overCapMinor":amount.map { max(0,$0-500) } as Any? ?? NSNull(),"headroomMinor":amount.map { max(0,500-$0) } as Any? ?? NSNull(),"status":amount.map { $0 > 500 ? "overCap" : "withinCap" } ?? "unresolved","scope":"wholeCheckout","missing":amount == nil ? ["line_price"] : [],"lowerBoundMinor":amount ?? 0,"upperBoundMinor":amount as Any? ?? NSNull(),"wholeCheckoutWithinCap":amount.map { $0 <= 500 } ?? false] }
            return try json(["previewId":"55555555-5555-4555-8555-555555555555","expiresAt":"2099-01-01T00:00:00Z","shopRevision":revision,"authorityEpoch":1,"requestRevision":1,"choice":decision["choice"]!,"before":budget(0),"after":budget(total),"changeMinor":total as Any? ?? NSNull(),"requiresOverageAcceptance":total.map { $0 > 500 } ?? false,"requiresUnknownAcceptance":total == nil])
        }
        if path.hasSuffix("/replay-windows") { return try json(["id":"66666666-6666-4666-8666-666666666666","expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands"), let key = input["clientKey"] as? String {
            count += 1
            if let receipt = receipts[key] { changed?(count,recordedLines.count); return try json(receipt) }
            guard input["kind"] as? String == "request.apply", let decision = recordedPreview?["decision"] as? [String: Any] else { throw URLError(.badServerResponse) }
            if let line = decision["line"] as? [String: Any] { recordedLines.append(line) }
            let receipt: [String: Any] = ["operationId":UUID().uuidString,"kind":"request.apply","shopId":Self.shop,"shopRevision":2,"authorityEpoch":1,"disposition":"added","requestId":Self.requestID,"requestRevision":2]
            receipts[key] = receipt; changed?(count,recordedLines.count); return try json(receipt)
        }
        throw URLError(.unsupportedURL)
    }
}
final class S24FixtureProtocol: URLProtocol, @unchecked Sendable {
    static var server: S24FixtureServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status,data) = try server.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor func s24FixtureModel(server: S24FixtureServer, outboxURL: URL) async throws -> HouseholdInboxModel {
    S24FixtureProtocol.server = server
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [S24FixtureProtocol.self]
    let transport = HTTPTransport(session: URLSession(configuration: configuration))
    let auth = AdultAuth(configuration: try .init(projectURL: URL(string:"https://s24-identity.invalid")!,publishableKey:"sb_publishable_fixture_only"),vault:S24FixtureVault(),transport:transport)
    _ = try await auth.verifyEmailCode(email:"shopper@example.invalid",code:"123456")
    let service = HouseholdService(configuration: try .init(baseURL:URL(string:"https://s24-household.invalid")!),auth:auth,deviceVault:S24FixtureVault(),transport:transport)
    let bootstrap = try await service.enroll(householdID:S24FixtureServer.household)
    let model = HouseholdInboxModel(bootstrap:bootstrap,service:service,outbox:OperationOutbox(url:outboxURL),onAccessEnded:{})
    await model.load()
    return model
}
