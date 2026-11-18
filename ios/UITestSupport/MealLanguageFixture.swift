#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import HouseholdClient
import CoreDomain

/// Isolated normal-Debug UI fixture. Every request is intercepted and all records and auth material are temporary.
private final class MealNoteProtocol: URLProtocol {
    static let household = "11111111-1111-4111-8111-111111111111"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            guard let url = request.url, url.host == "meal-note.invalid" else { throw URLError(.unsupportedURL) }
            let path = url.path
            let value: [String: Any]
            if path == "/auth/v1/verify" {
                value = ["access_token":"test-note-token", "refresh_token":"test-note-refresh", "expires_in":3600,
                         "user":["id":"adult-note", "email_confirmed_at":"date"]]
            } else if path == "/auth/v1/user" { value = ["id":"adult-note","email_confirmed_at":"date"] }
            else if path.hasSuffix("/me/workspaces") { value = ["workspaces":[["householdId":Self.household,"role":"organizer","label":"Fixture"]]] }
            else if path.hasSuffix("/devices") { value = ["deviceId":"note-device","deviceToken":"note-device-token"] }
            else if path.hasSuffix("/bootstrap") {
                value = ["household":["id":Self.household,"label":"Fixture"], "memberId":"22222222-2222-4222-8222-222222222222",
                    "role":"organizer", "enrolled":true, "queueConsent":false, "capabilities":[]]
            } else if ProcessInfo.processInfo.arguments.contains("--checkout-crop-fixture"),
                      path.hasSuffix("/receipt-assistance") || path.hasSuffix("/capture-assistance/checkout-line") {
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-note-token",
                      request.value(forHTTPHeaderField: "X-Device-Token") == "note-device-token" else { throw URLError(.userAuthenticationRequired) }
                if request.httpMethod == "GET", path.hasSuffix("/receipt-assistance") {
                    value = ["version":1, "available":true, "allowsCrop":true]
                } else {
                    guard request.httpMethod == "POST", path.hasSuffix("/capture-assistance/checkout-line") else { throw URLError(.unsupportedURL) }
                    var bytes = request.httpBody ?? Data()
                    if bytes.isEmpty, let stream = request.httpBodyStream {
                        stream.open(); defer { stream.close() }; bytes = try Data(reading: stream)
                    }
                    let input = try JSONDecoder().decode(ReceiptLineAssistanceRequest.self, from: bytes)
                    guard input.consent, input.page == 1, input.line == 1, input.text.isEmpty,
                          let crop = input.crop, crop.width * crop.height == crop.pixels.count,
                          crop.pixels.contains(where: { $0 < 100 }) else { throw URLError(.cannotParseResponse) }
                    value = ["version":1, "requestID":input.requestID.uuidString, "page":1, "line":1, "wording":"total $12.50"]
                }
            } else if path.contains("/language-assistance/") {
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-note-token",
                      request.value(forHTTPHeaderField: "X-Device-Token") == "note-device-token" else { throw URLError(.userAuthenticationRequired) }
                if request.httpMethod == "GET" { value = ["version":1,"available":true] }
                else {
                    var bytes = request.httpBody ?? Data()
                    if bytes.isEmpty, let stream = request.httpBodyStream {
                        stream.open(); defer { stream.close() }; bytes = try Data(reading: stream)
                    }
                    let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    guard payload?["consent"] as? Bool == true, let id = payload?["requestID"] as? String,
                          let line = (payload?["sourceLines"] as? [[String: String]])?.first,
                          let text = line["text"], let sourceID = line["id"] else { throw URLError(.cannotParseResponse) }
                    if path.hasSuffix("/meal-choice") {
                        guard let candidates = payload?["candidates"] as? [[String: String]],
                              let match = candidates.first(where: { $0["title"] == "Arroz con tomates" }),
                              let reference = match["id"] else { throw URLError(.cannotParseResponse) }
                        value = ["version":1,"requestID":id,"candidateID":reference]
                    } else {
                        let feedback = path.hasSuffix("/meal-feedback")
                        let quote = feedback ? text : (text.hasSuffix("guisantes") ? "guisantes" : "peas")
                        let kind = feedback ? "makeAgain" : "dislike"
                        value = ["version":1,"requestID":id,"suggestions":[["sourceLineID":sourceID,"kind":kind,"quote":quote]]]
                    }
                }
            } else { throw URLError(.unsupportedURL) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:value)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
}

private extension Data {
    init(reading stream: InputStream) throws {
        self.init()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            append(buffer, count: count)
        }
    }
}
private final class MealNoteVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return stored }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; stored = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; stored = nil }
}

struct MealLanguageFixture: View {
    @StateObject private var ledger: LedgerModel
    @StateObject private var access: WorkspaceAccess
    @State private var household: HouseholdModel?
    @State private var recipe = MealTemplate(title:"Test supper")
    @State private var swap: DinnerFeatureModel?
    @State private var pickup: PickupModel?

    @State private var failed = false
    private let directory: URL
    init() {
        let id = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MealNoteFixture-" + id)
        directory = folder
        _ledger = StateObject(wrappedValue: LedgerModel(databaseURL: folder.appendingPathComponent("ledger.sqlite")))
        _access = StateObject(wrappedValue: WorkspaceAccess(defaults: UserDefaults(suiteName: "mealNoteFixture." + id)!))
    }
    var body: some View {
        NavigationStack {
            if let household {
                List {
                    if ProcessInfo.processInfo.arguments.contains("--checkout-crop-fixture"), let shop = ledger.shop {
                        NavigationLink("Pickup details") { LedgerFactsView(model: ledger, shop: shop).environmentObject(household).environmentObject(access) }
                            .accessibilityIdentifier("fixture.checkout.details")
                    }
                    if let swap, let pickup, let original = ledger.shop?.mealOccurrences.first {
                        NavigationLink("Swap") {
                            DinnerSwapView(model: swap, meal: original)
                                .environmentObject(pickup).environmentObject(household).environmentObject(access)
                        }.accessibilityIdentifier("mealFixture.swap")
                    }
                    NavigationLink("Preferences") { PrivateMealPreferencesEntry(ledger: ledger).environmentObject(household).environmentObject(access) }.accessibilityIdentifier("mealFixture.preferences")
                    NavigationLink("Feedback") { MealFeedbackEntry(ledger: ledger, source: .recipe(id: recipe.id, revision: recipe.revision),
                        title: recipe.title).environmentObject(household).environmentObject(access) }.accessibilityIdentifier("mealFixture.feedback")
                }.environmentObject(household).environmentObject(access)
            } else if failed { Text("Fixture unavailable") }
            else { ProgressView() }
        }.task {
            guard household == nil, !failed else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                await ledger.open()
                guard await ledger.change(key:"fixture-recipe", { $0.mealTemplates = [recipe] }) else { throw ClientError.configuration }
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MealNoteProtocol.self]
                let transport = HTTPTransport(session: URLSession(configuration: config))
                let url = URL(string: "https://meal-note.invalid")!
                let auth = AdultAuth(configuration: try .init(projectURL:url,publishableKey:"sb_publishable_fixture_only"), vault:MealNoteVault(), transport:transport)
                let service = HouseholdService(configuration:try .init(baseURL:url),auth:auth,deviceVault:MealNoteVault(),transport:transport)
                let model = HouseholdModel(auth:auth,service:service,outboxURL:directory.appendingPathComponent("outbox.json"),
                    deletionVault:MealNoteVault(),exitVault:MealNoteVault(),guardianVault:MealNoteVault())
                model.email = "adult@example.invalid"; model.code = "123456"; await model.verifyCode()
                guard let first = model.workspaces.first else { throw ClientError.configuration }
                model.keepLocalPrivate = true; await model.join(first)
                guard model.projection?.enrolled == true else { throw ClientError.configuration }
                if ProcessInfo.processInfo.arguments.contains("--checkout-crop-fixture") {
                    guard await ledger.startShop(title: "Crop review") else { throw ClientError.configuration }
                }
                if ProcessInfo.processInfo.arguments.contains("--meal-choice-fixture") {
                    guard let origin = ledger.sourceWorkspaceID else { throw ClientError.configuration }
                    let instant = Date()
                    var shop = ShoppingLedger(title: "Fixture", basis: .init(branch: "Fixture"))
                    let ingredient = MealIngredient(name: "Rice", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"))
                    _ = try shop.chooseMeal(.init(title: "Original dinner", ingredients: [ingredient]), at: instant)
                    let accepted = AcceptedDinner(id: UUID(), template: .init(title: "Arroz con tomates", ingredients: [ingredient]),
                        acceptedAt: instant, acceptedFallback: false)
                    let context = DinnerAccessContext(scope: .local(workspaceID: origin), actorID: "adult-note", shopID: shop.id,
                        assignedShopperID: "adult-note", canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 0,
                        verifiedAt: instant, validUntil: instant.addingTimeInterval(3600))
                    guard await ledger.change(key: "fixture-swap", { workspace in
                        workspace.shops = [shop]; workspace.selectedShopID = shop.id
                        try workspace.dinnerPlanning.accept(accepted, access: context, at: instant)
                    }) else { throw ClientError.configuration }
                    let localPickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
                    await localPickup.load(); localPickup.bindCookLedger(ledger)
                    pickup = localPickup
                    swap = DinnerFeatureModel(store: ledger, access: { id in id == context.shopID ? context : nil }, phase: { _ in .draft })
                }
                household = model
            } catch { failed = true }
        }
    }
}
#endif
