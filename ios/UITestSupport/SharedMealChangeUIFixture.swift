#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import SwiftUI
import HouseholdClient

private final class S17FixtureVault: RefreshTokenVault, @unchecked Sendable {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
private final class S17FixtureServer: @unchecked Sendable {
    static let household = "11111111-1111-4111-8111-111111111111"
    static let shopper = "22222222-2222-4222-8222-222222222222"
    static let planner = "33333333-3333-4333-8333-333333333333"
    static let shop = "44444444-4444-4444-8444-444444444444"
    static let occurrence = "55555555-5555-4555-8555-555555555555"
    private let lock = NSRecursiveLock()
    private let deliveries = ProcessInfo.processInfo.arguments.contains("--shared-delivery-fixture") ? SharedDeliveryFixtureRecords() : nil
    private let purchases = ProcessInfo.processInfo.arguments.contains("--request-purchase-fixture") ? RequestPurchaseFixture() : nil
    private let fallbacks = SharedFallbackUIFixture()
    private let financial = ProcessInfo.processInfo.arguments.contains("--financial-closeout-fixture") ? SharedFinancialFixture() : nil
    private let confirmedOrder = ProcessInfo.processInfo.arguments.contains("--confirmed-order-fixture") ? SharedConfirmedOrderUIFixture() : nil
    private var revision = 2
    private let quoteObservedAt = Date().addingTimeInterval(-60)
    private let quoteExpiresAt = Date().addingTimeInterval(3600)
    private var meal: [String:Any] = ["title":"Fixture shared soup","day":"2026-11-05","kind":"dinner","portions":4,"protected":false]
    private var proposals: [[String:Any]] = []
    private var receipts: [String:[String:Any]] = [:]
    private var posts = 0
    var changed: (@Sendable (Int,Int) -> Void)?
    init() {
        if ProcessInfo.processInfo.arguments.contains("--shared-meal-undated-fixture") {
            meal["day"] = NSNull()
            let ingredient: [String: Any] = [
                "id": "77777777-7777-4777-8777-777777777777", "name": "Beans", "quantity": NSNull(),
                "groupIds": [], "exclusions": []]
            meal["planning"] = ["groups": [], "ingredients": [ingredient]] as [String: Any]
        }
        if ProcessInfo.processInfo.arguments.contains("--shared-meal-deadline-fixture") {
            meal["day"] = "2026-11-01"
            meal["planning"] = ["groups": [], "ingredients": [],
                                "deadline": ["at": "2026-11-01T05:30:00Z", "zone": "America/New_York"]] as [String:Any]
        }
    }

    func respond(_ request: URLRequest) throws -> (Int,Data) {
        lock.lock(); defer { lock.unlock() }
        deliveries?.shopRevision = revision
        guard request.url?.host?.hasSuffix(".invalid") == true else { throw URLError(.unsupportedURL) }
        if let confirmedOrder { revision = confirmedOrder.revision }
        let path = request.url!.path
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(buffer,count:n) }
        }
        let input = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
        let shopper = request.value(forHTTPHeaderField:"Authorization")?.contains("shopper") == true
        func json(_ value: Any, status: Int = 200) throws -> (Int,Data) { (status,try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) }
        func denied() throws -> (Int,Data) { try json(["error":["code":"unavailable"]],status:404) }
        if path == "/auth/v1/verify" {
            let role = (input["email"] as? String)?.contains("shopper") == true ? "shopper" : "planner"
            return try json(["access_token":"fixture-"+role,"refresh_token":"refresh-"+role,"expires_in":3600,"user":["id":"native-"+role,"email_confirmed_at":"date"]])
        }
        if path == "/auth/v1/user" { return try json(["id":shopper ? "native-shopper":"native-planner","email_confirmed_at":"date"]) }
        if path == "/v1/me/workspaces" { return try json(["workspaces":[["householdId":Self.household,"label":"Isolated shared meals","role":"contributor"]]]) }
        if path.hasSuffix("/devices") { return try json(["deviceId":shopper ? (fallbacks != nil ? "dddddddd-dddd-4ddd-8ddd-dddddddddddd" : "shopper-device") : "planner-device","deviceToken":shopper ? "shopper-token":"planner-token"],status:201) }
        if path.hasSuffix("/bootstrap") {
            var capabilities = shopper ? ["shopper_commands","shopper_inbox","request_preview"] : ["meal_proposals"]
            if shopper, confirmedOrder != nil { capabilities.append("confirmed_order") }
            if shopper, let deliveries {
                capabilities.append("delivery_evidence")
                if purchases != nil { capabilities.append("request_purchase_confirmation") }
                if fallbacks != nil { capabilities.append("accepted_fallbacks") }
                if deliveries.recovery != nil { capabilities.append("meal_recovery") }
                if deliveries.pantry != nil { capabilities.append("pantry_lots") }
                if deliveries.supportsCookCopies { capabilities += ["cook_copies", "cook_corrections"] }
            }
            return try json(["household":["id":Self.household,"label":"Isolated shared meals"],"memberId":shopper ? Self.shopper:Self.planner,
                             "role":shopper ? "shopper":"contributor","shopId":Self.shop,"enrolled":true,"queueConsent":false,"capabilities":capabilities])
        }
        if path == "/v1/households/\(Self.household)/entitlements", request.httpMethod == "GET" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-shopper",
                  request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            let now = Date(), format = ISO8601DateFormatter()
            let end = format.string(from: now.addingTimeInterval(3600))
            let expired = ProcessInfo.processInfo.arguments.contains("--expired-recovery-seat")
            return try json(["householdID": Self.household, "purchaserID": Self.planner, "revision": expired ? 2 : 1,
                "status": expired ? "expired" : "active", "expiresAt": expired ? format.string(from: now) : end,
                "verifiedAt": format.string(from: now), "validUntil": end,
                "seats": [["userID": Self.shopper, "displayName": "Fixture shopper", "isAdult": true]]])
        }
        let scoped = "/v1/households/" + Self.household
        let deliveryPath = scoped + "/shops/" + Self.shop
        if let financial, path == deliveryPath + "/financial-evidence" || path == deliveryPath + "/financial-reviews" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-shopper",
                  request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            return try financial.respond(shop: Self.shop, method: request.httpMethod, path: path, body: input, revision: &revision)
        }
        let pantryPath = deliveryPath + "/pantry-lots"
        let cookPath = deliveryPath + "/cook-copies"
        let recoveryPath = deliveryPath + "/meal-recovery"
        if let fallbacks, path == deliveryPath || path.hasPrefix(deliveryPath + "/") || path == scoped + "/commands" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-shopper",
                  request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            let route = path == scoped + "/commands" ? "/commands" : String(path.dropFirst(deliveryPath.count))
            if let result = try fallbacks.respond(route, method: request.httpMethod ?? "GET", input: input, bytes: bytes) { return result }
        }
        if let confirmedOrder, path == deliveryPath + "/confirmed-order" || (path == scoped + "/commands" && input["kind"] as? String == "amendment.recordResponse") {
            guard shopper, request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            if path.hasSuffix("/confirmed-order") { return try json(confirmedOrder.page(shop: Self.shop)) }
            return try json(confirmedOrder.record(shop: Self.shop, actor: Self.shopper, input: input, bytes: bytes))
        }
        if let deliveries, [deliveryPath + "/delivery-evidence", deliveryPath + "/delivery-evidence/coverage",
                            pantryPath, pantryPath + "/coverage", pantryPath + "/observation-preview",
                            recoveryPath, recoveryPath + "/coverage", recoveryPath + "/preview",
                            cookPath, cookPath + "/baseline", cookPath + "/correction", scoped + "/commands"].contains(path) {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-shopper",
                  request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            if path.hasSuffix("/delivery-evidence/coverage") {
                var coverage = try deliveries.coverage(shop: Self.shop)
                if financial != nil { coverage["shopRevision"] = revision }
                return try json(coverage)
            }
            if path.hasSuffix("/delivery-evidence") {
                var page = deliveries.page(shop: Self.shop)
                if financial != nil { page["shopRevision"] = revision }
                return try json(page)
            }
            do {
                if path == recoveryPath || path.hasPrefix(recoveryPath + "/") {
                    guard let recovery = deliveries.recovery else { return try denied() }
                    switch (request.httpMethod, path) {
                    case ("GET", recoveryPath): return try json(recovery.desk(shop: Self.shop))
                    case ("GET", recoveryPath + "/coverage"): return try json(recovery.coverage(shop: Self.shop))
                    case ("POST", recoveryPath + "/preview"): return try json(recovery.preview(shop: Self.shop, input: input))
                    default: return try denied()
                    }
                }
                if path == pantryPath || path.hasPrefix(pantryPath + "/") {
                    guard let pantry = deliveries.pantry else { return try denied() }
                    switch (request.httpMethod, path) {
                    case ("GET", pantryPath): return try json(pantry.page(shop: Self.shop, supply: deliveries.revision))
                    case ("GET", pantryPath + "/coverage"): return try json(pantry.coverage(shop: Self.shop, supply: deliveries.revision))
                    case ("POST", pantryPath + "/observation-preview"):
                        return try json(pantry.preview(shop: Self.shop, supply: deliveries.revision, body: input))
                    default: return try denied()
                    }
                }
                if path == cookPath {
                    guard deliveries.supportsCookCopies, request.httpMethod == "GET",
                          let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems else { return try denied() }
                    return try json(deliveries.cookCopies(occurrenceID: query.first { $0.name == "occurrenceId" }?.value, cursor: query.first { $0.name == "cursor" }?.value))
                }
                guard request.httpMethod == "POST" else { return try denied() }
                if path == cookPath + "/correction" {
                    guard deliveries.supportsCookCopies else { return try denied() }
                    return try json(deliveries.correction(input))
                }
                if path == cookPath + "/baseline" {
                    guard deliveries.supportsCookCopies else { return try denied() }
                    return try json(deliveries.cookBaseline(input))
                }
                if (input["kind"] as? String)?.hasPrefix("pantry.") == true, deliveries.pantry == nil { return try denied() }
                if (input["kind"] as? String)?.hasPrefix("cookCopy.") == true, !deliveries.supportsCookCopies { return try denied() }
                if input["kind"] as? String == "request.confirmPurchase", let purchases {
                    return try json(purchases.record(shop: Self.shop, command: input, bytes: bytes))
                }
                return try json(deliveries.record(shop: Self.shop, command: input))
            } catch let failure as SharedDeliveryFixtureRecords.CookFailure {
                let code: String
                switch failure {
                case .invalid: return try json(["error":["code":"invalid_request"]], status:400)
                case .staleSupply: code = "stale_supply"
                case .staleBase: code = "stale_base"
                case .replayConflict: code = "key_reused"
                }
                return try json(["error":["code":code]], status:409)
            }
        }
        if path == deliveryPath + "/inbox", let purchases {
            guard shopper, request.value(forHTTPHeaderField: "X-Device-Token") == "shopper-token" else { return try denied() }
            return try json(purchases.page(shop: Self.shop))
        }
        if path.hasSuffix("/inbox") { return try json(["requests":[],"nextCursor":NSNull()]) }
        if path.hasSuffix("/requests/mine") { return try json(["requests":[],"nextCursor":NSNull()]) }
        let occurrence: [String:Any] = ["occurrenceId":Self.occurrence,"revision":revision,"meal":meal]
        if path.hasSuffix("/meal-plan/changes"), request.httpMethod == "POST" {
            guard !shopper, let id = input["proposalId"] as? String, input["shopRevision"] as? Int == revision else { return try denied() }
            if !proposals.contains(where: { ($0["proposalId"] as? String) == id }) { proposals.append(["proposalId":id,"request":input,"original":meal,"state":"pending"]) }
            changed?(proposals.count,posts)
            return try json(["saved":true,"proposalId":id])
        }
        if path.hasSuffix("/meal-plan/changes") { return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"grantRevision":1,"phase":"draft","shopper":shopper,"meals":[occurrence],"proposals":proposals]) }
        if path.hasSuffix("/meal-plan") { return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"grantRevision":1,"shopper":shopper,"plannerId":Self.planner,"adults":[["id":Self.planner,"label":"Fixture planner"]],"meals":[occurrence],"proposals":[]]) }
        if path.hasSuffix("/shops/"+Self.shop) {
            guard shopper else { return try denied() }
            let quote = try ShopperQuote(scope:"wholeCheckout",complete:true,capMinor:1000,capScope:"wholeCheckout",fee:.fixed(0),taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:quoteObservedAt,expiresAt:quoteExpiresAt)
            let placedMeals = deliveries?.page(shop: Self.shop)["meals"] as? [[String:Any]]
            return try json(["shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"phase":deliveries == nil ? "draft" : (financial?.closed == true ? "closed" : "placed"),"placedRevision":deliveries == nil ? NSNull() as Any : 1 as Any,"meals":placedMeals ?? [occurrence],"quote":try JSONSerialization.jsonObject(with:JSONEncoder().encode(quote)),"lines":[["lineId":"66666666-6666-4666-8666-666666666666","originalItem":"Entered soup packs","packs":1,"unitPriceMinor":500,"feeEligible":true]]])
        }
        if path.hasSuffix("/replay-windows") { return try json(["id":"77777777-7777-4777-8777-777777777777","expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/commands"), let key = input["clientKey"] as? String {
            guard shopper else { return try denied() }
            if let receipt = receipts[key] { return try json(receipt) }
            guard input["kind"] as? String == "shop.patch", let body = input["body"] as? [String:Any], let edit = body["mealEdit"] as? [String:Any],
                  let next = edit["meal"] as? [String:Any], (input["base"] as? [String:Any])?["shopRevision"] as? Int == revision else { return try denied() }
            if let id = edit["changeProposalId"] as? String {
                guard let index = proposals.firstIndex(where: { ($0["proposalId"] as? String)?.lowercased() == id.lowercased() }) else { return try denied() }
                proposals[index]["state"] = "applied"
            }
            meal = next; revision += 1; posts += 1
            let receipt: [String:Any] = ["operationId":UUID().uuidString,"kind":"shop.patch","shopId":Self.shop,"shopRevision":revision,"authorityEpoch":1,"disposition":"patched"]
            receipts[key] = receipt; changed?(proposals.count,posts); return try json(receipt)
        }
        return try denied()
    }
}
private final class S17FixtureProtocol: URLProtocol {
    static var server: S17FixtureServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { guard let server = Self.server else { throw URLError(.unsupportedURL) }
            let (status,data) = try server.respond(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@MainActor final class S17FixtureState: ObservableObject {
    @Published var planner: HouseholdModel?
    @Published var shopper: HouseholdModel?
    @Published var proposals = 0
    @Published var applications = 0
    @Published var failure: String?
    private let server = S17FixtureServer()
    func start() async {
        guard planner == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--shared-meal-fixture") else { return }
        do {
            S17FixtureProtocol.server = server
            server.changed = { [weak self] proposed,applied in Task { @MainActor in self?.proposals = proposed; self?.applications = applied } }
            planner = try await make(role:"planner"); shopper = try await make(role:"shopper")
        } catch { failure = "Fixture setup failed" }
    }
    static func recoveryShopper() async throws -> HouseholdModel {
        let state = S17FixtureState()
        S17FixtureProtocol.server = state.server
        return try await state.make(role: "shopper")
    }

    static func recoveryMembership() -> MembershipCoordinator {
        MembershipCoordinator { session, credentials in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [S17FixtureProtocol.self]
            let service = try HTTPMembershipEntitlementService(baseURL: session.serviceURL, session: URLSession(configuration: config),
                deviceToken: credentials.deviceToken, token: credentials.accessToken)
            let context = MembershipContext(purchaserID: session.memberID, purchaserName: session.accountName,
                householdID: session.householdID, householdName: session.householdName, appAccountToken: nil)
            return MembershipModel(configuration: .init(productID: nil, privacyURL: nil, termsURL: nil), context: context, service: service)
        }
    }

    private func make(role: String) async throws -> HouseholdModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [S17FixtureProtocol.self]
        let transport = HTTPTransport(session:URLSession(configuration:config))
        let auth = AdultAuth(configuration:try .init(projectURL:URL(string:"https://s17-identity.invalid")!,publishableKey:"sb_publishable_fixture_only"),vault:S17FixtureVault(),transport:transport)
        let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://s17-household.invalid")!),auth:auth,deviceVault:S17FixtureVault(),transport:transport)
        let url = ProcessInfo.processInfo.arguments.contains("--confirmed-order-fixture") ? SharedConfirmedOrderUIFixture.folder.appendingPathComponent("outbox.json") : FileManager.default.temporaryDirectory.appendingPathComponent("UITestWorkspace/S17-"+UUID().uuidString).appendingPathComponent("outbox.json")
        let model = HouseholdModel(auth:auth,service:service,outboxURL:url,deletionVault:S17FixtureVault(),exitVault:S17FixtureVault())
        model.email = role+"@example.invalid"; model.code = "123456"; await model.verifyCode()
        guard let workspace = model.workspaces.first else { throw ClientError.invalidResponse }
        model.keepLocalPrivate = true; await model.join(workspace)
        guard model.projection != nil else { throw ClientError.invalidResponse }
        if role == "shopper" { await model.sharedShop?.load() }
        return model
    }
}
struct S17SharedMealFixtureRoot: View {
    @StateObject private var state = S17FixtureState()
    @State private var shopperMode = ProcessInfo.processInfo.arguments.contains("--shopper-meal-seed") || ProcessInfo.processInfo.arguments.contains("--shared-meal-deadline-fixture")
    @State private var directSeed = ProcessInfo.processInfo.arguments.contains("--shopper-meal-seed")
    @State private var directShopReview = ProcessInfo.processInfo.arguments.contains("--shared-meal-deadline-fixture")
    private var focusedDaySheet: Bool { ProcessInfo.processInfo.arguments.contains("--shared-meal-day-sheet-fixture") }
    private var seed: SharedMealChangeSeed { .init(localOccurrenceID: UUID(uuidString:"88888888-8888-4888-8888-888888888888")!, title:"Fixture guest soup",portions:6,planning:.init(groups:[],ingredients:[])) }
    @ViewBuilder var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--shared-meal-civil-date-fixture") {
            SharedMealCivilDateFixtureRoot()
        } else { sharedMealContent }
    }
    private var sharedMealContent: some View {
        VStack {
            if !focusedDaySheet {
                Text("Fixture shared proposals: \(state.proposals)").accessibilityIdentifier("fixture.s17.proposals")
                Text("Fixture shared applications: \(state.applications)").accessibilityIdentifier("fixture.s17.applications")
            }
            if let planner = state.planner, let shopper = state.shopper {
                if !focusedDaySheet {
                    Button("Switch to assigned shopper") { shopperMode = true; directSeed = false; directShopReview = false }.accessibilityIdentifier("fixture.s17.switch")
                    Button("Open shopper local evidence") { shopperMode = true; directSeed = true; directShopReview = false }.accessibilityIdentifier("fixture.s17.seed")
                }
                NavigationStack {
                    if ProcessInfo.processInfo.arguments.contains("--shared-meal-undated-fixture"), let model = shopper.sharedShop {
                        SharedUndatedMealFixtureEditor(model: model, compactReadbacks: focusedDaySheet)
                    } else if shopperMode && !directSeed {
                        if directShopReview { HouseholdShopView(model:shopper) } else { DinnerSharedPlanningEntry(household:shopper) }
                    }
                    else { SharedMealChangesView(household:shopperMode ? shopper:planner,seed:seed,onReviewOpened:{ directSeed = false; shopperMode = true; directShopReview = true }) }
                }.id(shopperMode ? (directSeed ? "shopper-seed":"shopper") : "planner")
            } else if let failure = state.failure { Text(failure).accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated shared meal fixture") }
        }.task { await state.start() }
    }
}

/// Uses the loaded HTTP fixture shop and production editor, including the actual review model.
private struct SharedUndatedMealFixtureEditor: View {
    @ObservedObject var model: HouseholdShopModel
    let compactReadbacks: Bool
    @State private var mealDaySelection: SharedMealDaySelection?
    @ViewBuilder private var readbacks: some View {
        Text(model.draft.mealEdit?.occurrenceID.uuidString ?? "none")
            .accessibilityIdentifier("fixture.undated.occurrence")
        Text(model.draft.mealEdit?.meal?.planning?.ingredients.first?.id.uuidString ?? "none")
            .accessibilityIdentifier("fixture.undated.ingredient")
    }
    var body: some View {
        VStack {
            if compactReadbacks {
                // Test-only identity readbacks must not consume the product's AX5
                // viewport. The editor and presented calendar retain full Dynamic Type.
                readbacks.font(.caption2).dynamicTypeSize(.medium).lineLimit(1)
            } else { readbacks }
            Form {
                SharedMealEditor(model: model, meals: model.shop?.meals ?? []) { mealDaySelection = $0 }
                Button("Review fixture meal") { model.reviewDraft() }
                    .accessibilityIdentifier("fixture.undated.review")
                Text(model.review?.mealEdit?.occurrenceID.uuidString ?? "none")
                    .accessibilityIdentifier("fixture.undated.reviewedOccurrence")
            }
        }.sheet(item: $mealDaySelection) { selected in
            SharedMealDaySheet(model: model, selection: selected)
        }.task { model.beginEditing() }
    }
}

/// Exercises the production facts view under the same environment override as a real screen.
/// Entered civil days remain unchanged; no service, account, or persisted fixture is needed.
private struct SharedMealCivilDateFixtureRoot: View {
    private let days = ["2026-03-07", "2026-03-08", "2026-03-09", "2026-10-31",
        "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-05"]
    @State private var index = 0
    private var zone: TimeZone {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--shared-meal-civil-date-zone"), flag + 1 < args.count,
              let zone = TimeZone(identifier: args[flag + 1]) else { return .gmt }
        return zone
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: zone.identifier).accessibilityIdentifier("fixture.civil-date.zone")
            Text(verbatim: days[index]).accessibilityIdentifier("fixture.civil-date.wire-day")
            SharedMealFacts(meal: SharedMeal(title: "Civil date fixture", day: days[index],
                kind: "dinner", portions: 4, protected: false))
            Button("Next civil day") { index = (index + 1) % days.count }
                .accessibilityIdentifier("fixture.civil-date.next")
        }.padding().environment(\.timeZone, zone)
    }
}
#endif
