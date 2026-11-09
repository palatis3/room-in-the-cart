#if DEBUG
import Foundation
import HouseholdClient

/// Fictional, isolated transport shared by S23 model tests and its opt-in UI fixture.
/// Never accepts a real host or sends network traffic.
final class S23DuplicateFixtureServer: @unchecked Sendable {
    static let householdID = "a1111111-1111-4111-8111-111111111111"
    static let memberID = "a2222222-2222-4222-8222-222222222222"
    static let shopID = "a3333333-3333-4333-8333-333333333333"
    static let samID = "a4444444-4444-4444-8444-444444444441"
    static let wrapsID = "a4444444-4444-4444-8444-444444444442"
    static let leeID = "a4444444-4444-4444-8444-444444444443"
    static let patID = "a4444444-4444-4444-8444-444444444444"
    static let lineID = "a7777777-7777-4777-8777-777777777777"
    private let lock = NSRecursiveLock()
    private var revision = 1
    private var decisions: [String: [String: Any]] = [:]
    private var receipts: [String: [String: Any]] = [:]
    private var statuses: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var clarifications: [String: String] = [:]
    private var applied: [String] = []
    private var previews = 0
    private let pageBoundary: Bool
    init(pageBoundary: Bool = false) { self.pageBoundary = pageBoundary }
    var changed: ((Int) -> Void)?
    var commandCount: Int { lock.lock(); defer { lock.unlock() }; return applied.count }
    var previewCount: Int { lock.lock(); defer { lock.unlock() }; return previews }
    var appliedRequestIDs: [String] { lock.lock(); defer { lock.unlock() }; return applied }

    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        guard ["s23-identity.invalid", "s23-household.invalid"].contains(request.url?.host ?? "") else { throw URLError(.unsupportedURL) }
        let path = request.url!.path
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(buffer, count: count)
            }
        }
        let input = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        func json(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        if path == "/auth/v1/verify" { return try json(["access_token":"fixture-access", "refresh_token":"fixture-refresh", "expires_in":3600, "user":["id":"s23-fictional-adult", "email_confirmed_at":"date"]]) }
        if path == "/auth/v1/user" { return try json(["id":"s23-fictional-adult", "email_confirmed_at":"date"]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":"fixture-device", "deviceToken":"fixture-device-token"]) }
        if path.hasSuffix("/bootstrap") {
            return try json(["household":["id":Self.householdID, "label":"S23 Fictional Household"], "memberId":Self.memberID, "role":"shopper", "shopId":Self.shopID, "enrolled":true, "queueConsent":false, "capabilities":["shopper_inbox", "request_preview", "shopper_commands"]])
        }
        if path.hasSuffix("/inbox") {
            let cursor = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "cursor" }?.value
            if pageBoundary {
                let rows = requestRows()
                return try json(["requests":cursor == nil ? Array(rows.prefix(2)) : Array(rows.suffix(2)), "nextCursor":cursor == nil ? Self.wrapsID as Any : NSNull()])
            }
            return try json(["requests":requestRows(), "nextCursor":NSNull()])
        }
        if path.hasSuffix("/shops/" + Self.shopID) {
            let quote = try ShopperQuote(scope:"wholeCheckout", complete:true, capMinor:3800, capScope:"wholeCheckout", fee:.fixed(0), taxesMinor:0, depositsMinor:0, discountsMinor:0,
                observedAt:Date(timeIntervalSince1970:1_793_718_000), expiresAt:Date(timeIntervalSince1970:4_070_908_800))
            return try json(["shopId":Self.shopID, "shopRevision":revision, "authorityEpoch":1, "phase":"draft", "quote":try JSONSerialization.jsonObject(with:JSONEncoder().encode(quote)),
                "lines":[["lineId":Self.lineID, "originalItem":"Cereal already in the basket", "packs":1, "unitPriceMinor":349, "feeEligible":true]]])
        }
        if path.hasSuffix("/previews"), let requestID = input["requestId"] as? String,
           let decision = input["decision"] as? [String: Any], let choice = decision["choice"] as? String {
            guard requestRows().contains(where: { $0["requestId"] as? String == requestID }) else { throw URLError(.badServerResponse) }
            previews += 1
            let previewID = UUID().uuidString.lowercased()
            decisions[previewID] = ["requestId":requestID, "decision":decision]
            let line = decision["line"] as? [String: Any]
            let delta: Int? = choice == "add" ? (line?["unitPriceMinor"] as? Int).map { $0 * (line?["packs"] as? Int ?? 1) } : 0
            let total = delta.map { 3720 + $0 }
            return try json(["previewId":previewID, "expiresAt":"2099-01-01T00:00:00Z", "shopRevision":revision, "authorityEpoch":1, "requestRevision":revisions[requestID] ?? 1, "choice":choice,
                "before":budget(3720), "after":budget(total), "changeMinor":delta as Any? ?? NSNull(), "requiresOverageAcceptance":total.map { $0 > 3800 } ?? false, "requiresUnknownAcceptance":total == nil])
        }
        if path.hasSuffix("/replay-windows") { return try json(["id":"a6666666-6666-4666-8666-666666666666", "expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands"), let key = input["clientKey"] as? String {
            if let receipt = receipts[key] { return try json(receipt) }
            guard let kind = input["kind"] as? String, let body = input["body"] as? [String: Any],
                  let requestID = body["requestId"] as? String else { throw URLError(.badServerResponse) }
            if kind == "request.clarify", let question = body["question"] as? String {
                guard requestRows().contains(where: { $0["requestId"] as? String == requestID && $0["ownActionAllowed"] as? Bool == true }) else { throw URLError(.badServerResponse) }
                clarifications[requestID] = question
                return try json(record(key:key,kind:kind,requestID:requestID,disposition:"clarified"))
            }
            guard kind == "request.apply", let previewID = body["previewId"] as? String,
                  let preview = decisions[previewID], preview["requestId"] as? String == requestID,
                  let decision = preview["decision"] as? [String: Any], let choice = decision["choice"] as? String else { throw URLError(.badServerResponse) }
            let disposition: String
            switch choice {
            case "link":
                guard decision["lineId"] as? String == Self.lineID else { throw URLError(.badServerResponse) }
                disposition = "added"; revision += 1
            case "defer": disposition = "deferred"
            case "dismiss": disposition = "dismissed"
            case "handled": disposition = "handled"
            default: throw URLError(.unsupportedURL)
            }
            return try json(record(key:key,kind:kind,requestID:requestID,disposition:disposition))
        }
        throw URLError(.unsupportedURL)
    }

    private func record(key:String,kind:String,requestID:String,disposition:String) -> [String: Any] {
        revisions[requestID] = (revisions[requestID] ?? 1) + 1; statuses[requestID] = disposition
        applied.append(requestID)
        let receipt: [String: Any] = ["operationId":UUID().uuidString.lowercased(), "kind":kind, "shopId":Self.shopID, "shopRevision":revision, "authorityEpoch":1, "disposition":disposition, "requestId":requestID, "requestRevision":revisions[requestID]!]
        receipts[key] = receipt; changed?(applied.count)
        return receipt
    }

    private func budget(_ total: Int?) -> [String: Any] {
        ["currency":"USD", "totalMinor":total as Any? ?? NSNull(), "overCapMinor":total.map { max(0,$0-3800) } as Any? ?? NSNull(), "headroomMinor":total.map { max(0,3800-$0) } as Any? ?? NSNull(), "status":total.map { $0 > 3800 ? "overCap" : "withinCap" } ?? "unresolved", "scope":"wholeCheckout", "missing":total == nil ? ["line_price"] : [], "lowerBoundMinor":total ?? 0, "upperBoundMinor":total as Any? ?? NSNull(), "wholeCheckoutWithinCap":total.map { $0 <= 3800 } ?? false]
    }
    private func requestRows() -> [[String: Any]] {
        [(Self.samID,"Cereal","1 box for breakfasts","Sam","pending"),
         (Self.wrapsID,"Wraps","8 wraps for lunch","Alex","pending"),
         (Self.leeID,"CEREAL","2 boxes for the school snack drive","Lee","pending"),
         (Self.patID,"Cereal","1 box for the weekend","Pat","handled")].enumerated().map { index, item in
            let status = statuses[item.0] ?? item.4
            return ["requestId":item.0, "shopId":Self.shopID, "revision":revisions[item.0] ?? 1, "originalItem":item.1, "ownQuantity":item.2, "authorAlias":item.3,
                "authoredAt":"2026-11-03T15:00:0\(index)Z", "receivedAt":"2026-11-03T15:01:0\(index)Z", "route":status == "deferred" ? "next" : "current", "status":status,
                "ownActionAllowed":status == "pending" || status == "clarified", "clarification":clarifications[item.0] as Any? ?? NSNull()]
        }
    }
}

final class S23DuplicateFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
final class S23DuplicateFixtureProtocol: URLProtocol {
    static var server: S23DuplicateFixtureServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status,data) = try server.respond(request)
            client?.urlProtocol(self, didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self, didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError:error) }
    }
    override func stopLoading() {}
}

@MainActor func s23DuplicateFixtureModel(server: S23DuplicateFixtureServer, outboxURL: URL) async throws -> HouseholdInboxModel {
    S23DuplicateFixtureProtocol.server = server
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [S23DuplicateFixtureProtocol.self]
    let transport = HTTPTransport(session:URLSession(configuration:configuration))
    let auth = AdultAuth(configuration:try .init(projectURL:URL(string:"https://s23-identity.invalid")!,publishableKey:"sb_publishable_fixture_only"),vault:S23DuplicateFixtureVault(),transport:transport)
    _ = try await auth.verifyEmailCode(email:"s23-shopper@example.invalid",code:"123456")
    let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://s23-household.invalid")!),auth:auth,deviceVault:S23DuplicateFixtureVault(),transport:transport)
    let bootstrap = try await service.enroll(householdID:S23DuplicateFixtureServer.householdID)
    let model = HouseholdInboxModel(bootstrap:bootstrap,service:service,outbox:OperationOutbox(url:outboxURL),onAccessEnded:{})
    await model.load()
    return model
}
#endif
