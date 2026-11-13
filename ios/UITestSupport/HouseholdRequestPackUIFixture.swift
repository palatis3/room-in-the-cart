#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import HouseholdClient

// Temporary opt-in diagnostics; no product payload or extra observable state.
enum S24PackTrace {
    private static let scope: String? = {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--ui-testing"), process.arguments.contains("--request-pack-fixture"),
              let value = process.environment["S24_PACK_TRACE_SCOPE"], value.count <= 240,
              value.range(of: #"^[A-Za-z0-9_./ \[\]\-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }()
    static var enabled: Bool { scope != nil }
    static func emit(_ event: String, pack: String, oldID: String, newID: String, old: Bool, new: Bool) {
        guard let scope else { return }
        let process = ProcessInfo.processInfo
        print("S24_PACK_TRACE uptime=\(process.systemUptime) pid=\(process.processIdentifier) scope=\(scope) event=\(event) pack=\(pack) oldDraft=\(oldID) newDraft=\(newID) old=\(old) new=\(new)")
    }
}

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
    private var attemptedCommands = 0
    private var previews = 0
    private var revision = 1
    func advanceSource() { lock.lock(); defer { lock.unlock() }; revision += 1 }
    private var accessRevoked = false
    func revokeAccess() { lock.lock(); defer { lock.unlock() }; accessRevoked = true }
    private static let earlierShop = "77777777-5555-4555-8555-555555555555"
    private static let earlierRequest = "88888888-5555-4555-8555-555555555555"
    private let deferredScenario: Bool
    private var carryKey: String?
    private var carryBody: Data?
    let includeExistingLine: Bool
    // The cereal fixture's $37.20 checkout includes each reviewed charge exactly once.
    private enum CerealCheckout {
        static let items = 3485, fee = 199, tax = 75, deposits = 10, discounts = 49
        static let total = items + fee + tax + deposits - discounts
    }
    let cerealScenario: Bool
    let includeMealFacts: Bool
    let includeOtherMeal: Bool
    init(includeExistingLine: Bool = false, cerealScenario: Bool = false, includeMealFacts: Bool = true, deferredScenario: Bool = false, includeOtherMeal: Bool = false) {
        self.deferredScenario = deferredScenario
        self.includeOtherMeal = includeOtherMeal
        self.includeExistingLine = includeExistingLine; self.cerealScenario = cerealScenario; self.includeMealFacts = includeMealFacts
    }
    static let protectedLunches: [[String: Any]] = [
        ["occurrenceId":"88888888-8888-4888-8888-888888888888", "revision":1,
         "meal":["title":"Sam’s wrap lunch", "day":"2026-11-04", "kind":"lunch", "portions":1, "protected":true]],
        ["occurrenceId":"99999999-9999-4999-8999-999999999999", "revision":1,
         "meal":["title":"Mia’s wrap lunch", "day":"2026-11-05", "kind":"lunch", "portions":1, "protected":true]]
    ]
    // Opt-in only: existing protected-lunch scenarios keep their original meal facts.
    static let otherDinner: [String: Any] = [
        "occurrenceId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "revision":1,
        "meal":["title":"Family rice dinner", "day":"2026-11-06", "kind":"dinner", "portions":4, "protected":false]
    ]
    var changed: ((Int, Int) -> Void)?
    var commandAttempted: ((Int) -> Void)?
    var previewChanged: ((Int) -> Void)?
    var previewBody: [String: Any]? { lock.lock(); defer { lock.unlock() }; return recordedPreview }
    var commandCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var previewCount: Int { lock.lock(); defer { lock.unlock() }; return previews }
    var lineCount: Int { lock.lock(); defer { lock.unlock() }; return recordedLines.count }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        var attemptNotification: (callback: (Int) -> Void, count: Int)?
        lock.lock()
        defer {
            lock.unlock()
            // Observe even rejected commands, outside the server lock and before
            // URLProtocol delivers the response or error to the app.
            if let attemptNotification { attemptNotification.callback(attemptNotification.count) }
        }
        guard request.url?.host?.hasSuffix(".invalid") == true else { throw URLError(.unsupportedURL) }
        let path = request.url!.path
        if path.hasSuffix("/commands") {
            attemptedCommands += 1
            if let commandAttempted { attemptNotification = (commandAttempted, attemptedCommands) }
        }
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
        let capabilities = ["shopper_inbox", "request_preview", "shopper_commands"] + (deferredScenario ? ["deferred_requests"] : [])
        if deferredScenario && path.hasSuffix("/shops/" + Self.shop + "/deferred-requests") {
            let row: [String: Any] = ["sourceShopId": Self.earlierShop, "sourceAuthorityEpoch": 3,
                "requestId": Self.earlierRequest, "requestRevision": 2, "originalItem": "Wraps for lunch",
                "ownQuantity": "8 wraps", "authorAlias": "Sam", "authoredAt": "2026-11-03T00:00:00Z",
                "receivedAt": "2026-11-03T00:00:01Z"]
            return try json(["shopId": Self.shop, "shopRevision": revision + (recordedLines.isEmpty ? 0 : 1),
                             "authorityEpoch": 1, "requests": carryKey == nil ? [row] : [], "nextCursor": NSNull()])
        }
        if path.hasSuffix("/bootstrap") { return try json(["household":["id":Self.household,"label":"Fixture"],"memberId":Self.member,"role":"shopper","shopId":Self.shop,"enrolled":true,"queueConsent":false,"capabilities":capabilities]) }
        var requestRow: [String: Any] = ["requestId":Self.requestID,"shopId":Self.shop,"revision":recordedLines.isEmpty ? 1 : 2,"originalItem":cerealScenario ? "Brown rice cereal" : "Wraps for lunch","ownQuantity":cerealScenario ? "1 box" : "8 wraps","authoredAt":"2026-11-03T00:00:00Z","receivedAt":"2026-11-03T00:00:01Z","route":"current","status":recordedLines.isEmpty ? "pending" : "added","ownActionAllowed":recordedLines.isEmpty,"authorAlias":"Sam"]
        if path.hasSuffix("/inbox") {
            if deferredScenario { requestRow["fromPreviousShop"] = true }
            return try json(["requests": deferredScenario && carryKey == nil ? [] : [requestRow], "nextCursor": NSNull()])
        }
        if path.hasSuffix("/shops/" + Self.shop) {
            if accessRevoked { return (403, Data()) }
            let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: cerealScenario ? 3800 : 500, capScope: "wholeCheckout", fee: .fixed(cerealScenario ? CerealCheckout.fee : 0),
                taxesMinor: cerealScenario ? CerealCheckout.tax : 0, depositsMinor: cerealScenario ? CerealCheckout.deposits : 0,
                discountsMinor: cerealScenario ? CerealCheckout.discounts : 0, observedAt: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(3600))
            let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote))
            var shop: [String: Any] = ["shopId":Self.shop,"shopRevision":revision + (recordedLines.isEmpty ? 0 : 1),"authorityEpoch":1,"phase":"draft","quote":data,"lines":recordedLines + (cerealScenario ? [["lineId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","originalItem":"Original pickup items","packs":1,"unitPriceMinor":CerealCheckout.items,"feeEligible":true]] : []) + (includeExistingLine ? [["lineId":"77777777-7777-4777-8777-777777777777","originalItem":"Existing wraps","packs":1,"unitPriceMinor":0,"feeEligible":true]] : [])]
            if includeMealFacts { shop["meals"] = Self.protectedLunches + (includeOtherMeal ? [Self.otherDinner] : []) }
            return try json(shop)
        }
        if request.httpMethod == "GET", path.hasSuffix("/shops/" + Self.shop + "/demand/tracking") {
            if accessRevoked { return (403, Data()) }
            // Apply reads the current v2 tracking state before deciding whether
            // this ordinary, untracked pickup can use its reviewed pack decision.
            let basket = recordedLines + (cerealScenario ? [["lineId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","originalItem":"Original pickup items","packs":1,"unitPriceMinor":CerealCheckout.items,"feeEligible":true]] : []) + (includeExistingLine ? [["lineId":"77777777-7777-4777-8777-777777777777","originalItem":"Existing wraps","packs":1,"unitPriceMinor":0,"feeEligible":true]] : [])
            let charges = cerealScenario ? CerealCheckout.total - CerealCheckout.items : 0
            let total: Int? = basket.contains { !($0["unitPriceMinor"] is Int) } ? nil : basket.reduce(charges) {
                $0 + ($1["unitPriceMinor"] as! Int) * ($1["packs"] as! Int)
            }
            let catalog: [[String: Any]] = recordedLines.map { line in
                ["id": Self.requestID, "revision": 1, "source": ["kind": "request", "requestId": Self.requestID, "appliedRequestRevision": 1],
                 "sourceLabel": "Request", "originalText": requestRow["originalItem"]!, "originalQuantityText": requestRow["ownQuantity"]!,
                 "quantity": NSNull(), "sourceExclusions": [], "requiredLineId": line["lineId"]!]
            }
            return try json(ModelTrackingReadFixture.page(household: Self.household, shop: Self.shop,
                revision: revision + (recordedLines.isEmpty ? 0 : 1), basket: basket,
                checkout: ModelTrackingReadFixture.budget(total, cap: cerealScenario ? 3800 : 500), catalog: catalog))
        }
        if request.httpMethod == "GET", path.hasSuffix("/shops/" + Self.shop + "/demand") {
            if accessRevoked { return (403, Data()) }
            return try json(["schemaVersion":1,"shopId":Self.shop,"shopRevision":revision + (recordedLines.isEmpty ? 0 : 1),"authorityEpoch":1,"status":"legacy","graph":NSNull(),"totals":[]])
        }
        if path.hasSuffix("/previews") {
            previews += 1; previewChanged?(previews)
            recordedPreview = input
            let decision = input["decision"] as? [String: Any] ?? [:]
            let line = decision["line"] as? [String: Any]
            let unit = line?["unitPriceMinor"] as? Int
            let before = cerealScenario ? CerealCheckout.total : 0
            let cap = cerealScenario ? 3800 : 500
            let change: Int? = decision["choice"] as? String == "add" ? unit.map { $0 * (line?["packs"] as? Int ?? 1) } : 0
            let total = change.map { before + $0 }
            func budget(_ amount: Int?) -> [String: Any] { ["currency":"USD","totalMinor":amount as Any? ?? NSNull(),"overCapMinor":amount.map { max(0,$0-cap) } as Any? ?? NSNull(),"headroomMinor":amount.map { max(0,cap-$0) } as Any? ?? NSNull(),"status":amount.map { $0 > cap ? "overCap" : "withinCap" } ?? "unresolved","scope":"wholeCheckout","missing":amount == nil ? ["line_price"] : [],"lowerBoundMinor":amount ?? before,"upperBoundMinor":amount as Any? ?? NSNull(),"wholeCheckoutWithinCap":amount.map { $0 <= cap } ?? false] }
            return try json(["previewId":"55555555-5555-4555-8555-555555555555","expiresAt":"2099-01-01T00:00:00Z","shopRevision":revision,"authorityEpoch":1,"requestRevision":1,"choice":decision["choice"]!,"before":budget(before),"after":budget(total),"changeMinor":change as Any? ?? NSNull(),"requiresOverageAcceptance":total.map { $0 > cap } ?? false,"requiresUnknownAcceptance":total == nil])
        }
        if path.hasSuffix("/replay-windows") { return try json(["id":"66666666-6666-4666-8666-666666666666","expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands"), let key = input["clientKey"] as? String {
            count += 1
            if deferredScenario && input["kind"] as? String == "request.carry" {
                guard input["shopId"] as? String == Self.shop,
                      let body = input["body"] as? [String: Any], body.count == 3,
                      body["requestId"] as? String == Self.earlierRequest,
                      body["sourceShopId"] as? String == Self.earlierShop, body["sourceAuthorityEpoch"] as? Int == 3,
                      input["base"] as? [String: Int] == ["shopRevision": 1, "authorityEpoch": 1, "requestRevision": 2]
                else { throw URLError(.badServerResponse) }
                if let carryKey {
                    guard key == carryKey, bytes == carryBody, let receipt = receipts[key] else {
                        throw URLError(.badServerResponse)
                    }
                    changed?(count, recordedLines.count)
                    return try json(receipt)
                }
                carryKey = key
                carryBody = bytes
                receipts[key] = ["kind": "request.carry", "operationId": Self.requestID, "requestId": Self.requestID,
                    "sourceRequestId": Self.earlierRequest, "requestRevision": 1, "shopId": Self.shop,
                    "shopRevision": 1, "authorityEpoch": 1, "disposition": "recorded"]
                changed?(count, recordedLines.count)
                // The write committed, but the gateway cannot deliver its receipt.
                return (503, Data())
            }
            if let receipt = receipts[key] { changed?(count,recordedLines.count); return try json(receipt) }
            guard input["kind"] as? String == "request.apply", let decision = recordedPreview?["decision"] as? [String: Any] else { throw URLError(.badServerResponse) }
            if let line = decision["line"] as? [String: Any] { recordedLines.append(line) }
            let receipt: [String: Any] = ["operationId":UUID().uuidString,"kind":"request.apply","shopId":Self.shop,"shopRevision":2,"authorityEpoch":1,"disposition":"added","requestId":Self.requestID,"requestRevision":2]
            receipts[key] = receipt; changed?(count,recordedLines.count); return try json(receipt)
        }
        throw URLError(.unsupportedURL)
    }
}
final class S24FixtureProtocol: URLProtocol {
    static var server: S24FixtureServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status,data) = try server.respond(request)
            var headers = ["Content-Type": "application/json"]
            if status == 503 { headers["Retry-After"] = "8" }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
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

import SwiftUI

@MainActor final class S24RequestPackFixtureState: ObservableObject {
    @Published var model: HouseholdInboxModel?
    @Published var posts = 0
    @Published var commandAttempts = 0
    @Published var lines = 0
    @Published var failed = false
    @Published var previews = 0
    private let server = S24FixtureServer(cerealScenario: ProcessInfo.processInfo.arguments.contains("--request-meal-fixture"), includeMealFacts: !ProcessInfo.processInfo.arguments.contains("--request-meals-unknown"), deferredScenario: ProcessInfo.processInfo.arguments.contains("--deferred-request-fixture"), includeOtherMeal: ProcessInfo.processInfo.arguments.contains("--request-other-meal-fixture"))
    func endShopperAccess() async { server.revokeAccess(); await model?.load() }
    func start() async {
        guard model == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"),ProcessInfo.processInfo.arguments.contains("--request-pack-fixture") else { return }
        do {
            server.changed = { [weak self] posts,lines in Task { @MainActor in self?.posts=posts;self?.lines=lines } }
            server.commandAttempted = { [weak self] attempts in
                Task { @MainActor in
                    guard let self else { return }
                    self.commandAttempts = max(self.commandAttempts, attempts)
                }
            }
            server.previewChanged = { [weak self] previews in Task { @MainActor in self?.previews = previews } }
            let url=FileManager.default.temporaryDirectory.appendingPathComponent("UITestWorkspace/S24-"+UUID().uuidString).appendingPathComponent("outbox.json")
            model=try await s24FixtureModel(server:server,outboxURL:url)
        } catch { failed=true }
    }
}
struct S24RequestPackFixtureRoot: View {
    @StateObject private var state=S24RequestPackFixtureState()
    @AppStorage("appearance") private var appearance = "system"
    private var explicitColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let option = arguments.firstIndex(of: "-appearance"),
              arguments.indices.contains(option + 1),
              ["light", "dark"].contains(arguments[option + 1]) else { return nil }
        // Match the ordinary app's preference only for an explicit fixture opt-in.
        return appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
    var body: some View {
        VStack {
            Text("Fixture applied decisions: \(state.posts)").accessibilityIdentifier("fixture.s24.posts")
            Text("Fixture saved lines: \(state.lines)").accessibilityIdentifier("fixture.s24.lines")
            Button("Fixture end shopper access") { Task { await state.endShopperAccess() } }
                .accessibilityIdentifier("fixture.s24.end-access")
            if let model=state.model {
                S24FixtureDecisionDiagnostics(model: model, previews: state.previews, commandAttempts: state.commandAttempts)
                NavigationStack { ShopperInboxContent(model:model).navigationTitle("S24 request decision") }
            }
            else if state.failed { Text("Fixture setup failed").accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated S24 fixture") }
        }.tint(Theme.action)
            .preferredColorScheme(explicitColorScheme)
            .task { await state.start() }
    }
}

private struct S24FixtureDecisionDiagnostics: View {
    @ObservedObject var model: HouseholdInboxModel
    let previews: Int
    let commandAttempts: Int
    var body: some View {
        Text(verbatim: "Fixture previews: \(previews); busy: \(model.busy); selected: \(model.selected?.id ?? "none"); choice: \(model.choice.rawValue); price: \(model.price); preview: \(model.preview?.previewId ?? "none"); notice: \(model.notice ?? "none")")
            .font(.caption2).lineLimit(1)
            .accessibilityIdentifier("fixture.s24.preview-diagnostics")
            .accessibilityValue("Fixture command attempts: \(commandAttempts)")
    }
}

#endif
