#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import HouseholdClient
import CoreDomain

private final class S27Vault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
/// A guarded contract fixture for real native controls. PostgreSQL and signed-session wire behavior
/// are separately exercised by StoreQuoteNativeWireTests; no production path uses this server.
private final class S27Server: @unchecked Sendable {
    static let household = "11111111-1111-4111-8111-111111111111"
    static let shopper = "22222222-2222-4222-8222-222222222222"
    static let adult = "33333333-3333-4333-8333-333333333333"
    static let shop = "44444444-4444-4444-8444-444444444444"
    static let line = "55555555-5555-4555-8555-555555555555"
    private let lock = NSRecursiveLock()
    private let url: URL
    private var state: [String:Any]
    private var loseNext = false
    var changed: (@Sendable (Int,Int,Int,Int) -> Void)?
    private var revision: Int { state["revision"] as? Int ?? 3 }
    private var phase: String { state["phase"] as? String ?? "draft" }
    private var pairs: [[String:Any]] { get { state["pairs"] as? [[String:Any]] ?? [] } set { state["pairs"] = newValue } }
    private var receipts: [String:[String:Any]] { get { state["receipts"] as? [String:[String:Any]] ?? [:] } set { state["receipts"] = newValue } }
    private var commitments: [[String:Any]] { [["id":Self.line,"label":"Wraps for dinner and protected lunch","packs":2]] }
    init(url: URL, reset: Bool) throws {
        self.url = url
        if !reset, let data = try? Data(contentsOf:url), let saved = try? JSONSerialization.jsonObject(with:data) as? [String:Any] { state = saved }
        else { state = ["revision":3,"phase":"draft","pairs":[],"receipts":[:],"posts":0,"adoptions":0,"grant":true] }
        try persist()
    }
    func armLostReply() { lock.lock(); defer { lock.unlock() }; loseNext = true }
    func makeStale() throws { lock.lock(); defer { lock.unlock() }; state["revision"] = revision+1; try persist() }
    func freeze() throws { lock.lock(); defer { lock.unlock() }; state["phase"] = "frozen"; try persist() }
    func revoke() throws { lock.lock(); defer { lock.unlock() }; state["grant"] = false; try persist() }
    private func persist() throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]).write(to:url,options:.atomic)
        changed?(pairs.count,pairs.reduce(0) { $0 + (($1["proposals"] as? [Any])?.count ?? 0) },state["adoptions"] as? Int ?? 0,state["posts"] as? Int ?? 0)
    }
    func notify() { lock.lock(); defer { lock.unlock() }; try? persist() }
    func respond(_ request: URLRequest) throws -> (Int,Data) {
        lock.lock(); defer { lock.unlock() }
        guard ["s27-identity.invalid","s27-household.invalid"].contains(request.url?.host ?? "") else { throw URLError(.unsupportedURL) }
        let path = request.url!.path, shopper = request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-shopper"
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(buffer,count:n) }
        }
        let input = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
        func json(_ value: Any, status: Int = 200) throws -> (Int,Data) { (status,try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) }
        func denied(_ code: String = "unavailable", status: Int = 404) throws -> (Int,Data) { try json(["error":["code":code]],status:status) }
        if path == "/auth/v1/verify" {
            let role = (input["email"] as? String)?.contains("shopper") == true ? "shopper":"adult"
            return try json(["access_token":"fixture-"+role,"refresh_token":"refresh-"+role,"expires_in":3600,"user":["id":"native-"+role,"email_confirmed_at":"date"]])
        }
        if path == "/auth/v1/user" { return try json(["id":shopper ? "native-shopper":"native-adult","email_confirmed_at":"date"]) }
        if path == "/v1/me/workspaces" { return try json(["workspaces":[["householdId":Self.household,"label":"Isolated store quote household","role":"contributor"]]]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":shopper ? "shopper-device":"adult-device","deviceToken":shopper ? "shopper-token":"adult-token"],status:201) }
        if path.hasSuffix("/bootstrap") {
            return try json(["household":["id":Self.household,"label":"Isolated store quote household"],"memberId":shopper ? Self.shopper:Self.adult,"role":shopper ? "shopper":"contributor","shopId":Self.shop,"enrolled":true,"queueConsent":false,"capabilities":shopper ? ["shopper_commands","shopper_inbox","request_preview","store_quotes"]:(state["grant"] as? Bool == true ? ["store_quotes"]:[])])
        }
        if path.hasSuffix("/inbox") || path.hasSuffix("/requests/mine") { return try json(["requests":[],"nextCursor":NSNull()]) }
        if path.hasSuffix("/store-quotes"), request.httpMethod == "GET" {
            guard shopper || state["grant"] as? Bool == true else { return try denied() }
            var visible: [[String:Any]] = []
            for var pair in pairs {
                let own = (pair["owner"] as? String) == (shopper ? "shopper":"adult")
                let proposals = pair["proposals"] as? [Any] ?? []
                guard own || (shopper && !proposals.isEmpty) else { continue }
                pair.removeValue(forKey:"owner"); pair["own"] = own; pair["stale"] = pair["baseRevision"] as? Int != revision
                visible.append(pair)
            }
            let adults: [[String:Any]] = shopper ? [["id":Self.adult,"label":"Second adult","revision":1,"enabled":state["grant"] as? Bool ?? false]]:[]
            return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":2,"grantRevision":shopper ? 0:1,"shopper":shopper,"phase":phase,"adults":adults,"commitments":commitments,"currentBasis":state["basis"] ?? NSNull(),"pairs":visible.reversed().map { $0 },"nextCursor":NSNull()])
        }
        if path.contains("/store-quotes/"), request.httpMethod == "POST" {
            guard shopper || state["grant"] as? Bool == true, request.value(forHTTPHeaderField:"X-Shop-ID") == Self.shop,
                  let key = input["operationId"] as? String, input["authorityEpoch"] as? Int == 2,
                  input["grantRevision"] as? Int == (shopper ? 0:1) else { return try denied() }
            state["posts"] = (state["posts"] as? Int ?? 0)+1
            if let receipt = receipts[key] { try persist(); return try json(receipt) }
            guard input["shopRevision"] as? Int == revision else { return try denied("stale_base",status:409) }
            let action = path.split(separator:"/").last.map(String.init)!
            guard phase == "draft" || action == "grants" else { return try denied("checkout_locked",status:409) }
            if action == "pairs" {
                let options = try JSONDecoder().decode(EnteredStoreQuoteOptions.self,from:JSONSerialization.data(withJSONObject:input["options"]!)); try options.validate()
                let cs = try JSONDecoder().decode([StoreQuotePage.Commitment].self,from:JSONSerialization.data(withJSONObject:commitments))
                let result = try SharedStoreQuoteMath.compare(options,commitments:cs,shopID:UUID(uuidString:Self.shop)!)
                func minor(_ value: Money?) -> Any { value.map { Int($0.minorUnits) as Any } ?? NSNull() }
                let comparison: [String:Any] = ["comparable":result.comparable,"firstCheckout":minor(result.first.checkout.total.exact),"secondCheckout":minor(result.second.checkout.total.exact),"firstTrip":minor(result.first.tripInclusive.total.exact),"secondTrip":minor(result.second.tripInclusive.total.exact),"itemDelta":minor(result.itemSubtotalChange),"checkoutDelta":minor(result.checkoutChange),"cashDelta":minor(result.tripCashChange),"minutesDelta":result.extraMinutesChange.map { $0 as Any } ?? NSNull(),"preferred":result.preferredByTotalCash.map { ($0 == SharedStoreQuoteMath.firstID ? "first":"second") as Any } ?? NSNull(),"secondBreakEven":minor(result.secondTripCashBreakEven)]
                pairs.append(["pairId":key,"baseRevision":revision,"authorityEpoch":2,"grantRevision":shopper ? 0:1,"savedAt":ISO8601DateFormatter().string(from:Date()),"owner":shopper ? "shopper":"adult","commitments":commitments,"options":input["options"]!,"comparison":comparison,"proposals":[]])
            } else if action == "proposals" || action == "adoptions" {
                guard let id = input["pairId"] as? String, let index = pairs.firstIndex(where: { ($0["pairId"] as? String)?.lowercased() == id.lowercased() }),
                      pairs[index]["baseRevision"] as? Int == revision,
                      let choice = input["choice"] as? String, let options = pairs[index]["options"] as? [String:Any], let selected = options[choice] as? [String:Any],
                      selected["available"] as? Bool == true, selected["eligibilityConfirmed"] as? Bool == true else { return try denied("unreviewed_coverage",status:409) }
                if action == "proposals" {
                    guard !shopper, pairs[index]["owner"] as? String == "adult" else { return try denied() }
                    var p = pairs[index]["proposals"] as? [[String:Any]] ?? []; p.append(["proposalId":key,"choice":choice]); pairs[index]["proposals"] = p
                } else {
                    guard shopper else { return try denied() }
                    let proposals = pairs[index]["proposals"] as? [[String:Any]] ?? []
                    guard pairs[index]["owner"] as? String == "shopper" || proposals.contains(where: { ($0["proposalId"] as? String)?.lowercased() == (input["proposalId"] as? String)?.lowercased() && $0["choice"] as? String == choice }) else { return try denied() }
                    state["revision"] = revision+1; state["adoptions"] = (state["adoptions"] as? Int ?? 0)+1
                    state["basis"] = ["store":selected["store"]!,"branch":selected["branch"]!,"mode":selected["mode"]!,"slot":selected["slot"]!,"revision":revision]
                }
            } else if action == "grants" {
                guard shopper else { return try denied() }; state["grant"] = input["enabled"]
            } else { return try denied() }
            let receipt: [String:Any] = ["operationId":key,"shopRevision":revision]; receipts[key] = receipt; try persist()
            if loseNext && action == "pairs" { loseNext = false; throw URLError(.networkConnectionLost) }
            return try json(receipt)
        }
        if path.hasSuffix("/shops/"+Self.shop), shopper {
            let unknown = state["basis"] != nil
            let quote = try ShopperQuote(scope:"wholeCheckout",complete:!unknown,capMinor:4000,capScope:"wholeCheckout",fee:.fixed(unknown ? nil:0),taxesMinor:unknown ? nil:0,depositsMinor:unknown ? nil:0,discountsMinor:unknown ? nil:0,observedAt:Date().addingTimeInterval(-60),expiresAt:Date().addingTimeInterval(3600))
            var value: [String:Any] = ["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":2,"phase":phase,"quote":try JSONSerialization.jsonObject(with:JSONEncoder().encode(quote)),"lines":[["lineId":Self.line,"originalItem":"Wraps for dinner and protected lunch","packs":2,"unitPriceMinor":unknown ? NSNull() as Any:1900,"feeEligible":true]]]
            if unknown { value["storeBasisRevision"] = revision; value["storeReviewRequired"] = true }
            return try json(value)
        }
        return try denied()
    }
}
private final class S27Protocol: URLProtocol {
    static var server: S27Server?
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
@MainActor private final class S27FixtureState: ObservableObject {
    @Published var adult: HouseholdModel?
    @Published var shopper: HouseholdModel?
    @Published var saves = 0
    @Published var proposals = 0
    @Published var adoptions = 0
    @Published var posts = 0
    @Published var failure: String?
    private var server: S27Server?
    func start() async {
        guard adult == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--shared-store-quotes-fixture") else { return }
        do {
            let id = ProcessInfo.processInfo.environment["RITC_QUOTES_FIXTURE_WORKSPACE"] ?? "default"
            guard UUID(uuidString:id) != nil else { throw ClientError.configuration }
            let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("UITestWorkspace/S27-"+id)
            let server = try S27Server(url:directory.appendingPathComponent("server.json"),reset:ProcessInfo.processInfo.environment["RITC_QUOTES_FIXTURE_RESET"] == "1")
            self.server = server; S27Protocol.server = server
            server.changed = { [weak self] saved,proposed,adopted,posts in Task { @MainActor in self?.saves = saved; self?.proposals = proposed; self?.adoptions = adopted; self?.posts = posts } }
            server.notify()
            adult = try await make(role:"adult",directory:directory); shopper = try await make(role:"shopper",directory:directory)
        } catch { failure = "Fixture setup failed" }
    }
    func loseNext() { server?.armLostReply() }
    func stale() { try? server?.makeStale() }
    func freeze() { try? server?.freeze() }
    func revoke() { try? server?.revoke() }
    private func make(role: String, directory: URL) async throws -> HouseholdModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [S27Protocol.self]
        let transport = HTTPTransport(session:URLSession(configuration:config))
        let auth = AdultAuth(configuration:try .init(projectURL:URL(string:"https://s27-identity.invalid")!,publishableKey:"sb_publishable_fixture_only"),vault:S27Vault(),transport:transport)
        let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://s27-household.invalid")!),auth:auth,deviceVault:S27Vault(),transport:transport)
        let model = HouseholdModel(auth:auth,service:service,outboxURL:directory.appendingPathComponent(role+"-outbox.json"),deletionVault:S27Vault(),exitVault:S27Vault())
        model.email = role+"@example.invalid"; model.code = "123456"; await model.verifyCode()
        guard let workspace = model.workspaces.first else { throw ClientError.invalidResponse }
        model.keepLocalPrivate = true; await model.join(workspace)
        guard model.storeQuoteScope != nil else { throw ClientError.invalidResponse }; return model
    }
}
struct S27StoreQuotesFixtureRoot: View {
    @StateObject private var state = S27FixtureState()
    @State private var shopperMode = false
    @State private var showsControls = false
    var body: some View {
        VStack(spacing: 2) {
            HStack { Text("Saves: \(state.saves)").accessibilityIdentifier("fixture.s27.saves"); Text("Proposals: \(state.proposals)").accessibilityIdentifier("fixture.s27.proposals"); Text("Adoptions: \(state.adoptions)").accessibilityIdentifier("fixture.s27.adoptions"); Text("POSTs: \(state.posts)").accessibilityIdentifier("fixture.s27.posts") }.font(.caption).dynamicTypeSize(.large)
            HStack {
                Button(shopperMode ? "Use budget adult":"Use shopper") { shopperMode.toggle() }.accessibilityIdentifier("fixture.s27.switch")
                Button("Fixture controls") { showsControls.toggle() }
                    .accessibilityIdentifier("fixture.s27.showControls")
                    .accessibilityValue(showsControls ? "Expanded" : "Collapsed")
            }.dynamicTypeSize(.large)
            if showsControls {
                VStack {
                    fixtureAction("Lose next save reply", action: state.loseNext)
                    fixtureAction("Advance shared revision", action: state.stale)
                    fixtureAction("Freeze shared shop", action: state.freeze)
                    fixtureAction("Revoke adult budget access", action: state.revoke)
                }.buttonStyle(.bordered).dynamicTypeSize(.large)
            }
            if let adult = state.adult, let shopper = state.shopper {
                NavigationStack { HouseholdSettingsView(model:shopperMode ? shopper:adult) }.id(shopperMode)
            } else if let failure = state.failure { Text(failure).accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated store quote fixture") }
        }.tint(Theme.action).task { await state.start() }
    }

    private func fixtureAction(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title) {
            action()
            showsControls = false
        }
    }
}
#endif
