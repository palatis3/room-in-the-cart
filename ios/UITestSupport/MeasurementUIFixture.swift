#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import SwiftUI
import HouseholdClient

private final class MeasurementFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}

/// Test-build transport only. It rejects every host except these reserved .invalid
/// endpoints and every non-allowlisted measurement field. Production auth, UI and
/// client validation are unchanged. Real PostgreSQL/HTTP tests prove server policy.
private final class MeasurementFixtureServer: @unchecked Sendable {
    static let household = "11111111-1111-4111-8111-111111111111"
    static let member = "22222222-2222-4222-8222-222222222222"
    static let shop = "33333333-3333-4333-8333-333333333333"
    private let lock = NSRecursiveLock()
    private let url: URL
    private var state: [String: Any]
    var changed: (@Sendable (Int, Int, Int, Int) -> Void)?
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        } else { state = [:] }
    }
    func notify() { changed?(count("grants"), count("sends"), count("deletes"), count("withdrawals")) }
    private func count(_ key: String) -> Int { state[key] as? Int ?? 0 }
    private func save(_ key: String) throws {
        state[key] = count(key) + 1
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: [.atomic])
        notify()
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        guard let host = request.url?.host, ["measurement-identity.invalid", "measurement-household.invalid"].contains(host) else { throw URLError(.unsupportedURL) }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(buffer, count: n) }
        }
        let input = bytes.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:])
        func json(_ value: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        func denied(_ code: String = "unavailable", _ status: Int = 404) throws -> (Int, Data) { try json(["error": ["code": code]], status) }
        if path == "/auth/v1/verify" {
            return try json(["access_token": "fixture-measurement", "refresh_token": "fixture-refresh", "expires_in": 3600, "user": ["id": "measurement-adult", "email_confirmed_at": "date"]])
        }
        if path == "/auth/v1/user" { return try json(["id": "measurement-adult", "email_confirmed_at": "date"]) }
        if path == "/v1/me/workspaces" { return try json(["workspaces": [["householdId": Self.household, "label": "Isolated measurement household", "role": "contributor"]]]) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-measurement" else { return try denied("session_needed", 401) }
        if path.hasSuffix("/devices") { return try json(["deviceId": "measurement-device", "deviceToken": "measurement-token"], 201) }
        guard request.value(forHTTPHeaderField: "X-Device-Token") == "measurement-token" else { return try denied() }
        if path.hasSuffix("/bootstrap") {
            return try json(["household": ["id": Self.household, "label": "Isolated measurement household"], "memberId": Self.member, "role": "shopper", "shopId": Self.shop, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_commands", "shopper_inbox", "request_preview"]])
        }
        if path.hasSuffix("/inbox") || path.hasSuffix("/requests/mine") { return try json(["requests": [], "nextCursor": NSNull()]) }
        if path.hasSuffix("/shops/" + Self.shop) {
            let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: nil, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date().addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(3600))
            return try json(["shopId": Self.shop, "shopRevision": 3, "authorityEpoch": 1, "phase": "closed", "frozenRevision": 1, "placedRevision": 2, "quote": try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote)), "lines": []])
        }
        let version = MeasurementNotice.currentVersion
        func status() -> [String: Any] { ["noticeVersion": version, "consent": state["consent"] ?? NSNull()] }
        if path.hasSuffix("/measurement/status"), method == "GET" { return try json(status()) }
        if path.hasSuffix("/measurement/consent"), method == "POST" {
            guard Set(input.keys) == ["noticeVersion"], input["noticeVersion"] as? String == version else { return try denied("invalid_command", 422) }
            if state["consent"] == nil {
                state["consent"] = ["consentId": UUID().uuidString.lowercased(), "noticeVersion": version, "grantedAt": "2026-11-03T16:00:00Z"]
                try save("grants")
            }
            return try json(status())
        }
        if path.hasSuffix("/measurement/withdraw"), method == "POST" {
            guard Set(input.keys) == ["consentId"], let current = state["consent"] as? [String: String],
                  (input["consentId"] as? String)?.lowercased() == current["consentId"] else { return try denied() }
            state["consent"] = nil; state["feedback"] = nil; try save("withdrawals")
            return try json(["withdrawn": true])
        }
        if path.hasSuffix("/shops/" + Self.shop + "/measurement-feedback") {
            if method == "GET" { return try json(["shopId": Self.shop, "eligibleWeek": "2026-W45", "feedback": state["feedback"] ?? NSNull()]) }
            if method == "POST" {
                guard Set(input.keys) == ["consentId", "noticeVersion", "outcome", "baseline", "comparison"], input["noticeVersion"] as? String == version,
                      let current = state["consent"] as? [String: String], (input["consentId"] as? String)?.lowercased() == current["consentId"],
                      let outcome = MeasurementAnswer.Outcome(rawValue: input["outcome"] as? String ?? ""),
                      let baseline = MeasurementAnswer.Baseline(rawValue: input["baseline"] as? String ?? ""),
                      let comparison = MeasurementAnswer.Comparison(rawValue: input["comparison"] as? String ?? "") else { return try denied("measurement_consent_required", 409) }
                let answer = MeasurementAnswer(outcome: outcome, baseline: baseline, comparison: comparison)
                state["feedback"] = ["feedbackId": UUID().uuidString.lowercased(), "shopId": Self.shop, "eligibleWeek": "2026-W45", "consentVersion": version, "outcome": outcome.rawValue, "baseline": baseline.rawValue, "comparison": comparison.rawValue, "incrementalBenefit": answer.incrementalBenefit.map { $0 as Any } ?? NSNull(), "recordedAt": "2026-11-03T16:01:00Z"]
                try save("sends"); return try json(state["feedback"]!)
            }
            if method == "DELETE" {
                guard Set(input.keys) == ["feedbackId"], let feedback = state["feedback"] as? [String: Any],
                      (input["feedbackId"] as? String)?.lowercased() == feedback["feedbackId"] as? String else { return try denied("invalid_command", 422) }
                state["feedback"] = nil; try save("deletes"); return try json(["removed": true])
            }
        }
        return try denied()
    }
}
private final class MeasurementFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var server: MeasurementFixtureServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status, data) = try server.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor private final class MeasurementFixtureState: ObservableObject {
    @Published var household: HouseholdModel?
    @Published var local: PickupModel?
    @Published var otherLocal: PickupModel?
    @Published var app: AppModel?
    @Published var ledger: LedgerModel?
    @Published var grants = 0
    @Published var sends = 0
    @Published var deletes = 0
    @Published var withdrawals = 0
    @Published var failed = false
    func start() async {
        guard household == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--measurement-fixture") else { return }
        do {
            let workspace = ProcessInfo.processInfo.environment["RITC_MEASUREMENT_FIXTURE_WORKSPACE"] ?? ""
            guard UUID(uuidString: workspace) != nil else { throw ClientError.configuration }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestWorkspace/Measurement-" + workspace)
            if ProcessInfo.processInfo.environment["RITC_MEASUREMENT_FIXTURE_RESET"] == "1", FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let server = try MeasurementFixtureServer(url: directory.appendingPathComponent("server.json"))
            MeasurementFixtureProtocol.server = server
            server.changed = { [weak self] grants, sends, deletes, withdrawals in Task { @MainActor in self?.grants = grants; self?.sends = sends; self?.deletes = deletes; self?.withdrawals = withdrawals } }
            server.notify()
            let first = PickupModel(databaseURL: directory.appendingPathComponent("local.sqlite"))
            let second = PickupModel(databaseURL: directory.appendingPathComponent("other-local.sqlite"))
            await first.load(); await second.load()
            guard first.ready, second.ready, first.sourceWorkspaceID != second.sourceWorkspaceID else { throw ClientError.invalidResponse }
            // Prove a legacy boolean alone does not turn on either scoped preference.
            UserDefaults.standard.set(true, forKey: PickupFeedbackSection.consentKey)
            local = first; otherLocal = second
            let app = AppModel(databaseURL: directory.appendingPathComponent("comparisons.sqlite"))
            let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
            await app.open(); await ledger.open()
            guard app.ready, ledger.ready else { throw ClientError.invalidResponse }
            self.app = app; self.ledger = ledger
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MeasurementFixtureProtocol.self]
            let transport = HTTPTransport(session: URLSession(configuration: config))
            let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://measurement-identity.invalid")!, publishableKey: "sb_publishable_fixture_only"), vault: MeasurementFixtureVault(), transport: transport)
            let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://measurement-household.invalid")!), auth: auth, deviceVault: MeasurementFixtureVault(), transport: transport)
            let model = HouseholdModel(auth: auth, service: service, outboxURL: directory.appendingPathComponent("outbox.json"), deletionVault: MeasurementFixtureVault(), exitVault: MeasurementFixtureVault())
            model.email = "adult@example.invalid"; model.code = "123456"; await model.verifyCode()
            guard let workspace = model.workspaces.first else { throw ClientError.invalidResponse }
            model.keepLocalPrivate = true; await model.join(workspace); await model.sharedShop?.load()
            guard model.projection?.role == "shopper", model.sharedShop?.shop?.phase == "closed" else { throw ClientError.invalidResponse }
            household = model
        } catch { failed = true }
    }
}
struct MeasurementUIFixtureRoot: View {
    @StateObject private var state = MeasurementFixtureState()
    @StateObject private var surfaces = DeviceSurfacesComposition()
    @StateObject private var membership = MembershipCoordinator()
    @StateObject private var access = WorkspaceAccess()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Consents: \(state.grants)").accessibilityIdentifier("fixture.measurement.grants")
                Text("Sends: \(state.sends)").accessibilityIdentifier("fixture.measurement.sends")
                Text("Deletes: \(state.deletes)").accessibilityIdentifier("fixture.measurement.deletes")
                Text("Withdrawals: \(state.withdrawals)").accessibilityIdentifier("fixture.measurement.withdrawals")
            }.font(.caption2)
            if let household = state.household, let local = state.local, let other = state.otherLocal,
               let app = state.app, let ledger = state.ledger {
                TabView {
                    NavigationStack { SettingsView() }.environmentObject(local).tabItem { Label("Settings", systemImage: "gearshape") }
                    NavigationStack { HouseholdShopView(model: household) }.environmentObject(local).tabItem { Label("Shared shop", systemImage: "cart") }
                    NavigationStack { SettingsView() }.environmentObject(other).tabItem { Label("Other workspace", systemImage: "square.stack") }
                }.environmentObject(household).environmentObject(surfaces).environmentObject(membership)
                    .environmentObject(app).environmentObject(ledger).environmentObject(access)
                    .environment(\.pickupLedger, ledger)
            } else if state.failed { Text("Fixture setup failed").accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated measurement fixture") }
        }.tint(Theme.action).task { await state.start() }
    }
}
#endif
