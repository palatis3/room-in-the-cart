#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import SwiftUI
import HouseholdClient

/// One fixed, synthetic graph review. This transport does not implement allocation
/// arithmetic or stand in for PostgreSQL acceptance. Unexpected mutations fail.
private final class FoodEditorFixtureServer: @unchecked Sendable {
    static let household = "11111111-1111-4111-8111-111111111111"
    static let member = "22222222-2222-4222-8222-222222222222"
    static let shop = "44444444-4444-4444-8444-444444444444"
    static let line = "66666666-6666-4666-8666-666666666666"
    static let known = "77777777-7777-4777-8777-777777777777"
    static let unknown = "88888888-8888-4888-8888-888888888888"
    static let window = "99999999-9999-4999-8999-999999999999"
    struct Snapshot: Codable, Sendable {
        var observedAt: String
        var expiredAt: String
        var targetExpiry: String
        var previews = 0
        var posts = 0
        var writes = 0
        var exactRetries = 0
        var failure: String?
        var previewID: String?
        var operationID: String?
        var previewRequest: Data?
        var firstCommand: Data?
    }
    private let lock = NSLock()
    let host: String
    private let url: URL
    private var state: Snapshot
    var changed: (@Sendable (Snapshot) -> Void)?
    init(directory: URL, workspace: UUID, reset: Bool) throws {
        host = "food-editor-" + workspace.uuidString.lowercased() + ".invalid"
        url = directory.appendingPathComponent("synthetic-server.json")
        if reset, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        } else {
            let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  let futureDay = calendar.date(byAdding: .day, value: 2, to: today) else { throw ClientError.configuration }
            let format = ISO8601DateFormatter()
            state = Snapshot(observedAt: format.string(from: yesterday), expiredAt: format.string(from: today), targetExpiry: format.string(from: futureDay))
            try save()
        }
    }
    func notify() { lock.lock(); let value = state; lock.unlock(); changed?(value) }
    private func save() throws { try JSONEncoder().encode(state).write(to: url, options: .atomic) }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func json(_ value: Any, status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
    private func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { state.failure = reason; try save(); changed?(state); throw ClientError.invalidResponse }
    }
    private func id(_ value: String) -> SharedDemandID { SharedDemandID(UUID(uuidString: value)!) }
    private func quote(updated: Bool) throws -> ShopperQuote {
        try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: updated ? 3500 : 2000, capScope: "wholeCheckout",
            fee: .fixed(495), taxesMinor: nil, depositsMinor: 0, discountsMinor: 50,
            observedAt: ISO8601DateFormatter().date(from: state.observedAt)!,
            expiresAt: ISO8601DateFormatter().date(from: updated ? state.targetExpiry : state.expiredAt)!)
    }
    private func basket(updated: Bool) -> [ShopperBasketLine] {
        [.init(lineId: UUID(uuidString: Self.line)!, originalItem: "Wraps — no salt", packs: 2, unitPriceMinor: updated ? 425 : 100, feeEligible: true)]
    }
    private func graph(revision: Int) throws -> SharedDemandGraph {
        let line = id(Self.line), known = id(Self.known), unknown = id(Self.unknown)
        let knownSource = SharedDemandContribution(id: known, lineId: line, source: .manual, productKey: "wraps", productName: "Wraps — no salt",
            originalText: "Twelve wraps — no salt", quantity: .init(amount: try .init(numerator: 12), unit: .count, originalLiteral: "12"))
        let unknownSource = SharedDemandContribution(id: unknown, lineId: line, source: .manual, productKey: "wraps", productName: "Wraps — no salt",
            originalText: "Extra wraps — amount unknown", quantity: nil)
        return .init(householdId: id(Self.household), shopId: id(Self.shop), revision: revision,
            lines: [.init(id: line, name: "Wraps — no salt", unit: .count, originalOrder: 0)],
            contributions: [knownSource, unknownSource], edges: [], usedIds: [line, known, unknown])
    }
    private var totals: [[String: Any]] {
        [["lineId": Self.line, "unit": "count", "quantity": NSNull(), "activeContributionIds": [Self.known, Self.unknown]]]
    }
    private func check(_ input: SharedDemandPreviewRequest) throws {
        try input.validate()
        try require(input.mode == .review && input.change.isEmpty && input.undoOperationId == nil, "Food graph must remain unchanged")
        try require(input.base == .init(shopRevision: 1, authorityEpoch: 1, graphRevision: 1), "Wrong reviewed base")
        guard case .patch(let patch) = input.action else { try require(false, "Expected shop patch"); return }
        try require(patch.quote == quote(updated: true) && patch.lines == basket(updated: true) && patch.mealEdit == nil && patch.reviewedStoreBasisRevision == 3,
            "Entered quote, line identity, packs, price, scope, unknown tax or store basis changed")
        let expectedPack = SharedDemandPackReview(lineId: id(Self.line),
            usablePerPack: .init(amount: try .init(numerator: 8), unit: .count, originalLiteral: "8"), acceptUnresolved: true)
        try require(input.packs == [expectedPack], "Expected explicit eight-per-pack review and unknown-need acknowledgment")
    }
    private func body(_ request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw ClientError.invalidResponse }; if count == 0 { break }
            result.append(buffer, count: count); guard result.count <= 1_800_000 else { throw ClientError.invalidResponse }
        }
        return result
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        try require(request.url?.host == host, "Wrong fixture host")
        let path = request.url!.path, method = request.httpMethod ?? "GET", bytes = try body(request)
        if path == "/auth/v1/verify", method == "POST" {
            return try json(["access_token": "fixture-food-shopper", "refresh_token": "fixture-refresh", "expires_in": 3600,
                "user": ["id": "fixture-food-shopper", "email_confirmed_at": "date"]])
        }
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-food-shopper", "Wrong fixture actor")
        if path == "/auth/v1/user", method == "GET" { return try json(["id": "fixture-food-shopper", "email_confirmed_at": "date"]) }
        if path == "/v1/me/workspaces", method == "GET" { return try json(["workspaces": [["householdId": Self.household, "label": "Isolated food editor", "role": "shopper"]]]) }
        let householdPath = "/v1/households/" + Self.household, shopPath = householdPath + "/shops/" + Self.shop
        if path == householdPath + "/devices", method == "POST" { return try json(["deviceId": "food-editor-device", "deviceToken": "food-editor-token"], status: 201) }
        try require(request.value(forHTTPHeaderField: "X-Device-Token") == "food-editor-token", "Wrong fixture device")
        if path == householdPath + "/bootstrap", method == "GET" {
            return try json(["household": ["id": Self.household, "label": "Isolated food editor"], "memberId": Self.member,
                "role": "shopper", "shopId": Self.shop, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_commands", "shopper_inbox", "request_preview"]])
        }
        if path == householdPath + "/replay-windows", method == "POST" { return try json(["id": Self.window, "expiresAt": "2099-01-01T00:00:00Z"]) }
        if path == shopPath, method == "GET" {
            return try json(["shopId": Self.shop, "shopRevision": state.writes + 1, "authorityEpoch": 1, "phase": "draft", "meals": [],
                "quote": try object(quote(updated: state.writes == 1)), "lines": try object(basket(updated: state.writes == 1)), "storeBasisRevision": 3])
        }
        if path == shopPath + "/demand", method == "GET" {
            return try json(["schemaVersion": 1, "shopId": Self.shop, "shopRevision": state.writes + 1, "authorityEpoch": 1,
                "status": "enabled", "graph": try object(graph(revision: state.writes + 1)), "totals": totals])
        }
        if path == shopPath + "/demand/previews", method == "POST" {
            try require(state.writes == 0, "No new preview after committed retry")
            let input = try JSONDecoder().decode(SharedDemandPreviewRequest.self, from: bytes); try check(input)
            state.previews += 1; state.previewID = UUID().uuidString.lowercased(); state.operationID = UUID().uuidString.lowercased(); state.previewRequest = bytes
            try save(); changed?(state)
            return try json(["previewId": state.previewID!, "previewDigest": String(repeating: "a", count: 64), "expiresAt": "2099-01-01T00:00:00Z",
                "before": try object(graph(revision: 1)), "after": try object(graph(revision: 2)), "beforeTotals": totals, "afterTotals": totals,
                "packs": try object(input.packs), "shopRevision": 1, "authorityEpoch": 1,
                "receipt": ["schemaVersion": 1, "operationId": state.operationID!, "householdId": Self.household, "shopId": Self.shop,
                    "baseRevision": 1, "resultRevision": 2, "lines": [], "contributions": [], "edges": []]])
        }
        if path == householdPath + "/commands", method == "POST" {
            guard let reviewed = state.previewRequest, let previewID = state.previewID, let operationID = state.operationID else {
                try require(false, "Apply without preview"); throw ClientError.invalidResponse
            }
            let input = try JSONDecoder().decode(SharedDemandPreviewRequest.self, from: reviewed); try check(input)
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: bytes)
            try require(envelope.v == 1 && envelope.replayWindow == Self.window && UUID(uuidString: envelope.clientKey) != nil && envelope.kind == "shop.patch" && envelope.shopId == Self.shop && envelope.base == .init(shopRevision: 1, authorityEpoch: 1), "Wrong command scope or base")
            guard case .patch(let expectedPatch) = input.action else { throw ClientError.invalidResponse }
            var expectedBody = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(expectedPatch))
            expectedBody["demandReview"] = .object(["previewId": .string(previewID), "previewDigest": .string(String(repeating: "a", count: 64))])
            try require(envelope.body == expectedBody, "Command must preserve the exact reviewed monetary and food action")
            state.posts += 1
            if let first = state.firstCommand {
                try require(first == bytes && state.writes == 1, "Relaunch retry changed bytes or duplicated mutation")
                state.exactRetries += 1; try save(); changed?(state)
                return try json(["operationId": operationID, "kind": "shop.patch", "shopId": Self.shop, "shopRevision": 2, "authorityEpoch": 1, "disposition": "patched"])
            }
            try require(state.writes == 0, "Duplicate synthetic commit")
            state.firstCommand = bytes; state.writes = 1; try save(); changed?(state)
            // Commit first, then lose only its response. Relaunch uses the real
            // parent outbox and must resend this very command, not a new preview.
            throw URLError(.networkConnectionLost)
        }
        try require(false, "Unexpected fixture route: " + method + " " + path)
        throw ClientError.invalidResponse
    }
}
private final class FoodEditorFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: FoodEditorFixtureServer] = [:]
    func add(_ server: FoodEditorFixtureServer) { lock.lock(); defer { lock.unlock() }; values[server.host] = server }
    func server(_ host: String?) -> FoodEditorFixtureServer? { lock.lock(); defer { lock.unlock() }; return host.flatMap { values[$0] } }
}
private final class FoodEditorFixtureProtocol: URLProtocol {
    static let registry = FoodEditorFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.server(request.url?.host) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.registry.server(request.url?.host) else { throw ClientError.configuration }
            let (status, bytes) = try server.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class FoodEditorFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
@MainActor private final class FoodEditorFixtureState: ObservableObject {
    @Published var household: HouseholdModel?
    @Published var snapshot: FoodEditorFixtureServer.Snapshot?
    @Published var failure: String?
    private var started = false
    func start() async {
        guard !started else { return }; started = true
        do {
            guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--shared-food-editor-fixture"),
                  let raw = ProcessInfo.processInfo.environment["RITC_FOOD_EDITOR_WORKSPACE"], let workspace = UUID(uuidString: raw) else { throw ClientError.configuration }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestWorkspace/FoodEditor-" + workspace.uuidString)
            let server = try FoodEditorFixtureServer(directory: directory, workspace: workspace, reset: ProcessInfo.processInfo.environment["RITC_FOOD_EDITOR_RESET"] == "1")
            server.changed = { [weak self] value in Task { @MainActor in self?.snapshot = value } }; FoodEditorFixtureProtocol.registry.add(server); server.notify()
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FoodEditorFixtureProtocol.self]
            let transport = HTTPTransport(session: URLSession(configuration: config)), base = URL(string: "https://" + server.host)!
            let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_fixture_only"), vault: FoodEditorFixtureVault(), transport: transport)
            let service = HouseholdService(configuration: try .init(baseURL: base), auth: auth, deviceVault: FoodEditorFixtureVault(), transport: transport)
            let model = HouseholdModel(auth: auth, service: service, outboxURL: directory.appendingPathComponent("shopper-outbox.json"), deletionVault: FoodEditorFixtureVault(), exitVault: FoodEditorFixtureVault())
            model.email = "shopper@example.invalid"; model.code = "123456"; await model.verifyCode()
            guard let workspace = model.workspaces.first else { throw ClientError.invalidResponse }
            model.keepLocalPrivate = true; await model.join(workspace)
            guard model.sharedShop != nil else { throw ClientError.invalidResponse }
            household = model
        } catch { failure = "Fixture setup failed: " + String(describing: error) }
    }
}
struct SharedFoodEditorFixtureRoot: View {
    @StateObject private var state = FoodEditorFixtureState()
    var body: some View {
        VStack(spacing: 2) {
            if let value = state.snapshot {
                Text("Previews: \(value.previews); POSTs: \(value.posts); Writes: \(value.writes); Exact retries: \(value.exactRetries)")
                    .accessibilityIdentifier("fixture.foodEditor.counts").font(.caption).dynamicTypeSize(.large)
                Text(value.expiredAt).accessibilityIdentifier("fixture.foodEditor.originalExpiry").font(.caption).dynamicTypeSize(.large)
                Text(value.targetExpiry).accessibilityIdentifier("fixture.foodEditor.targetExpiry").font(.caption).dynamicTypeSize(.large)
                if let failure = value.failure { Text(failure).accessibilityIdentifier("fixture.foodEditor.rejected") }
            }
            if let household = state.household { NavigationStack { HouseholdShopView(model: household) } }
            else if let failure = state.failure { Text(failure).accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated food editor fixture") }
        }.tint(Theme.action).task { await state.start() }
    }
}
#endif
