#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import HouseholdClient

@main struct RoomInTheCartContributorFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                fixtureContent
            } else { Color.clear }
        }
    }
    @ViewBuilder private var fixtureContent: some View {
        #if AWAY_CARRYOVER_UI_FIXTURE
        if ProcessInfo.processInfo.arguments.contains("--away-carryover-fixture") { AwayCarryoverUIFixtureRoot() }
        else { otherFixtureContent }
        #else
        otherFixtureContent
        #endif
    }
    @ViewBuilder private var otherFixtureContent: some View {
        if ProcessInfo.processInfo.arguments.contains("--shared-meal-fixture") { S17SharedMealFixtureRoot() }
        else if ProcessInfo.processInfo.arguments.contains("--request-pack-fixture") { S24RequestPackFixtureRoot() }
        else { ContributorRequestUIFixtureRoot() }
    }
}

/// Included only in an explicitly flagged test build. No live credential/provider path.
@MainActor final class ContributorRequestUIFixtureState: ObservableObject {
    @Published var household: HouseholdModel?
    @Published var requestPosts = 0
    @Published var persistedRequests = 0
    @Published var setupFailure = false
    private let server = ContributorRequestUIFixtureServer()
    func start() async {
        guard household == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        do {
            server.changed = { [weak self] posts, records in Task { @MainActor in self?.requestPosts = posts; self?.persistedRequests = records } }
            ContributorRequestUIFixtureProtocol.handler = server.respond
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ContributorRequestUIFixtureProtocol.self]
            let transport = HTTPTransport(session: URLSession(configuration: config))
            let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://contributor-identity.invalid")!, publishableKey: "sb_publishable_fixture_only"), vault: ContributorRequestUIFixtureVault(), transport: transport)
            let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://contributor-household.invalid")!), auth: auth, deviceVault: ContributorRequestUIFixtureVault(), transport: transport)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UITestWorkspace/ContributorRequest-" + UUID().uuidString, isDirectory: true)
            let model = HouseholdModel(auth: auth, service: service, outboxURL: directory.appendingPathComponent("outbox.json"), deletionVault: ContributorRequestUIFixtureVault(), exitVault: ContributorRequestUIFixtureVault())
            model.email = "sam@example.invalid"; model.code = "123456"; await model.verifyCode()
            guard let workspace = model.workspaces.first else { setupFailure = true; return }
            model.keepLocalPrivate = true; await model.join(workspace)
            guard model.contributorRequestScope != nil else { setupFailure = true; return }
            household = model
        } catch { setupFailure = true }
    }
}
struct ContributorRequestUIFixtureRoot: View {
    @StateObject private var fixture = ContributorRequestUIFixtureState()
    var body: some View {
        VStack(spacing: 0) {
            Text("Fixture request POSTs: \(fixture.requestPosts)").accessibilityIdentifier("fixture.requestPosts")
            Text("Fixture saved requests: \(fixture.persistedRequests)").accessibilityIdentifier("fixture.requestRows")
            if let household = fixture.household {
                NavigationStack { HouseholdSettingsView(model: household) }
            } else if fixture.setupFailure { Text("Fixture setup failed").accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated contributor fixture") }
        }.task { await fixture.start() }
    }
}
private final class ContributorRequestUIFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }; func write(_ value: String) throws { self.value = value }; func clear() throws { value = nil }
}
private final class ContributorRequestUIFixtureServer: @unchecked Sendable {
    let household = UUID().uuidString.lowercased(), member = UUID().uuidString.lowercased(), shop = UUID().uuidString.lowercased()
    private var rows: [[String: Any]] = [], receipts: [String: [String: Any]] = [:], posts = 0
    var changed: ((Int, Int) -> Void)?
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        guard request.url?.host?.hasSuffix(".invalid") == true else { throw URLError(.unsupportedURL) }
        let path = request.url!.path
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        func response(_ value: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        if path == "/auth/v1/verify" { return try response(["access_token":"fixture-sam","refresh_token":"fixture-refresh","expires_in":3600,"user":["id":"fixture-sam","email_confirmed_at":"date"]]) }
        if path == "/auth/v1/user" { return try response(["id":"fixture-sam","email_confirmed_at":"date"]) }
        if path == "/v1/me/workspaces" { return try response(["workspaces":[["householdId":household,"label":"Fixture home","role":"contributor"]]]) }
        if path.hasSuffix("/devices") { return try response(["deviceId":"fixture-device","deviceToken":"fixture-token"],201) }
        if path.hasSuffix("/bootstrap") { return try response(["household":["id":household,"label":"Fixture home"],"memberId":member,"role":"contributor","shopId":shop,"enrolled":true,"queueConsent":false,"capabilities":["own_requests"]]) }
        if path.hasSuffix("/requests/mine") { return try response(["requests":rows,"nextCursor":NSNull()]) }
        if path.hasSuffix("/replay-windows") { return try response(["id":UUID().uuidString.lowercased(),"expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands") {
            guard json["kind"] as? String == "request.send", let key = json["clientKey"] as? String,
                  let body = json["body"] as? [String: Any] else { throw URLError(.unsupportedURL) }
            posts += 1
            if let receipt = receipts[key] { changed?(posts, rows.count); return try response(receipt) }
            let row: [String: Any] = ["requestId":UUID().uuidString.lowercased(),"shopId":shop,"revision":1,"originalItem":body["originalItem"]!,"ownQuantity":body["ownQuantity"]!,"authoredAt":body["authoredAt"]!,"receivedAt":"2026-11-03T00:00:00Z","route":body["route"]!,"status":"pending","ownActionAllowed":true,"clarification":NSNull(),"followupTo":NSNull()]
            rows.append(row); let receipt: [String: Any] = ["operationId":UUID().uuidString,"kind":"request.send","request":row]; receipts[key] = receipt
            changed?(posts, rows.count); return try response(receipt)
        }
        throw URLError(.unsupportedURL)
    }
}
private final class ContributorRequestUIFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (status,data) = try Self.handler(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
