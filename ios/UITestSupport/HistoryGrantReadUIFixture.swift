#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import HouseholdClient

private final class H09Vault: RefreshTokenVault, @unchecked Sendable {
    private var token: String?
    func read() throws -> String? { token }
    func write(_ value: String) throws { token = value }
    func clear() throws { token = nil }
}
/// Real native client/entry/models; isolated transport mirrors the Free read boundary.
/// These fixtures are not evidence of service authorization, which has separate PostgreSQL tests.
private final class H09Server: @unchecked Sendable {
    static let household = "90000000-0000-4000-8000-000000000001"
    static let member = "90000000-0000-4000-8000-000000000002"
    static let shop = "90000000-0000-4000-8000-000000000003"
    static let foreignShop = "90000000-0000-4000-8000-000000000004"
    static let observation = "90000000-0000-4000-8000-000000000005"
    static let foreignObservation = "90000000-0000-4000-8000-000000000006"
    static let period = "90000000-0000-4000-8000-000000000007"
    private let lock = NSRecursiveLock()
    private var enabled = true
    private var reads = 0, paid = 0, denials = 0, mutations = 0
    var changed: (@Sendable (Int,Int,Int,Int) -> Void)?
    func revoke() { lock.lock(); defer { lock.unlock() }; enabled = false }
    private func notify() { changed?(reads,paid,denials,mutations) }
    func respond(_ request: URLRequest) throws -> (Int,Data) {
        lock.lock(); defer { lock.unlock() }
        guard ["h09-identity.invalid","h09-household.invalid"].contains(request.url?.host ?? "") else { throw URLError(.unsupportedURL) }
        let path = request.url!.path, selected = request.value(forHTTPHeaderField:"X-Shop-ID")
        func json(_ object: Any, status: Int = 200) throws -> (Int,Data) { (status,try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) }
        func unavailable() throws -> (Int,Data) { denials += 1; notify(); return try json(["error":["code":"unavailable"]],status:404) }
        func paywall() throws -> (Int,Data) { paid += 1; notify(); return try json(["error":["code":"membership_inactive"]],status:403) }
        if path == "/auth/v1/verify" { return try json(["access_token":"history-reader","refresh_token":"history-refresh","expires_in":3600,"user":["id":"history-reader","email_confirmed_at":"date"]]) }
        if path == "/auth/v1/user" { return try json(["id":"history-reader","email_confirmed_at":"date"]) }
        if path == "/v1/me/workspaces" { return try json(["workspaces":[["householdId":Self.household,"label":"Free budget read fixture","role":"contributor"]]]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":"history-device","deviceToken":"history-device-token"],status:201) }
        guard request.value(forHTTPHeaderField:"Authorization") == "Bearer history-reader",
              request.value(forHTTPHeaderField:"X-Device-Token") == "history-device-token" else { return try unavailable() }
        if selected != nil && (selected != Self.shop || !enabled) { return try unavailable() }
        if path.hasSuffix("/bootstrap") {
            var value: [String:Any] = ["household":["id":Self.household,"label":"Free budget read fixture"],"memberId":Self.member,"role":"contributor","enrolled":true,"queueConsent":false,"capabilities":enabled ? ["store_quotes"]:[],"canSelectShop":true,"selectionRequired":selected == nil]
            value["shopId"] = selected.map { $0 as Any } ?? NSNull(); return try json(value)
        }
        if path.hasSuffix("/shops") {
            let owned = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "scope" })?.value == "owned"
            let shops: [[String:Any]] = !owned && enabled ? [["shopId":Self.shop,"createdAt":"2026-11-01T12:00:00Z","phase":"draft","role":"contributor","revision":3,"authorityEpoch":2]]:[]
            return try json(["shops":shops,"nextCursor":NSNull()])
        }
        if path.hasSuffix("/history-readable-shops") {
            reads += 1; notify(); return try json(["shopIds":enabled ? [Self.shop]:[],"nextCursor":NSNull()])
        }
        if request.httpMethod != "GET" {
            if path.hasSuffix("/budget-history") { return try paywall() }
            mutations += 1; notify(); return try unavailable()
        }
        if path.hasSuffix("/price-observations") { return try paywall() }
        if path.hasSuffix("/price-observations/"+Self.observation), enabled {
            reads += 1; notify()
            let value = try HistoryPriceObservation(id:Self.observation,shopId:Self.shop,itemName:"Grant-only oats",packLabel:"12 oz dry pack",usablePack:nil,price:.exact(minor:349),store:"Entered market",branch:"Granted branch",channel:.storeShelf,mode:.inStore,eligibility:"Shelf label reviewed",observedAt:"2026-11-01T12:00:00Z",sourceText:"Allowed shelf evidence",sourceLocale:"en-US")
            return try json(["observation":JSONSerialization.jsonObject(with:JSONEncoder().encode(value))])
        }
        if path.contains("/price-observations/") { return try unavailable() }
        if path.hasSuffix("/budget-periods") { return try json(["periods":[["periodId":Self.period,"revision":1,"updatedAt":"2026-11-01T12:00:00Z"]],"nextCursor":NSNull()]) }
        if path.hasSuffix("/budget-periods/"+Self.period+"/record"), enabled {
            reads += 1; notify()
            // The adult owns this previously saved plan; all its sources are currently granted.
            let plan = try HistoryBudgetPeriod(id:Self.period,title:"Permitted saved November plan",startsAt:"2026-11-01T00:00:00Z",endsAt:"2026-11-15T00:00:00Z",timeZoneId:"America/New_York",shopBudgetMinor:10000,alreadyExcludedReserveMinor:1000,shopIds:[Self.shop],reservations:[],reviewedCompleteAt:nil)
            return try json(["periodId":Self.period,"revision":1,"period":JSONSerialization.jsonObject(with:JSONEncoder().encode(plan))])
        }
        if path.hasSuffix("/budget-periods/"+Self.period) { return try paywall() }
        return try unavailable()
    }
}
private final class H09Protocol: URLProtocol, @unchecked Sendable {
    static var server: H09Server?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status,data) = try server.respond(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@MainActor private final class H09FixtureState: ObservableObject {
    @Published var household: HouseholdModel?
    @Published var reads = 0
    @Published var paid = 0
    @Published var denials = 0
    @Published var mutations = 0
    @Published var failure: String?
    private let server = H09Server()
    func revoke() { server.revoke() }
    func start() async {
        guard household == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--history-grant-read-fixture") else { return }
        do {
            H09Protocol.server = server
            server.changed = { [weak self] read,paid,denied,writes in Task { @MainActor in self?.reads = read; self?.paid = paid; self?.denials = denied; self?.mutations = writes } }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [H09Protocol.self]
            let transport = HTTPTransport(session:URLSession(configuration:config))
            let auth = AdultAuth(configuration:try .init(projectURL:URL(string:"https://h09-identity.invalid")!,publishableKey:"sb_publishable_fixture_only"),vault:H09Vault(),transport:transport)
            let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://h09-household.invalid")!),auth:auth,deviceVault:H09Vault(),transport:transport)
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("UITestWorkspace/H09-"+UUID().uuidString)
            let value = HouseholdModel(auth:auth,service:service,outboxURL:base.appendingPathComponent("outbox.json"),deletionVault:H09Vault(),exitVault:H09Vault())
            value.email = "reader@example.invalid"; value.code = "123456"; await value.verifyCode()
            guard let workspace = value.workspaces.first else { throw ClientError.invalidResponse }
            value.keepLocalPrivate = true; await value.join(workspace)
            guard value.projection?.role == "contributor", value.projection?.shopId == nil else { throw ClientError.invalidResponse }
            let epoch = await value.decisionStore.epoch()
            for (shop,reference) in [(H09Server.shop,H09Server.observation),(H09Server.foreignShop,H09Server.foreignObservation)] {
                try await value.decisionStore.remember(.init(subject:"history-reader",householdID:H09Server.household,memberID:H09Server.member,shopID:shop,observationID:reference),expectedEpoch:epoch)
            }
            household = value
        } catch { failure = "History grant fixture setup failed" }
    }
}
struct H09HistoryGrantFixtureRoot: View {
    @StateObject private var state = H09FixtureState()
    var body: some View {
        VStack(spacing:2) {
            HStack {
                Text("Reads: \(state.reads)").accessibilityIdentifier("fixture.h09.reads")
                Text("Paid denied: \(state.paid)").accessibilityIdentifier("fixture.h09.paid")
                Text("Denied: \(state.denials)").accessibilityIdentifier("fixture.h09.denied")
                Text("Writes: \(state.mutations)").accessibilityIdentifier("fixture.h09.writes")
            }.font(.caption).dynamicTypeSize(.large)
            Button("Revoke budget read grant",action:state.revoke).accessibilityIdentifier("fixture.h09.revoke").dynamicTypeSize(.large)
            if let household = state.household {
                NavigationStack {
                    List {
                        NavigationLink(HistoryCopy.text("Prices and period budgets")) { HistoryRecordsEntryView(household:household) }
                            .accessibilityIdentifier("fixture.h09.openHistory")
                    }.navigationTitle("Free saved-record fixture")
                }
            } else if let failure = state.failure { Text(failure).accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening Free grant-only history fixture") }
        }.tint(Theme.action).task { await state.start() }
    }
}
#endif
