#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import SwiftUI
import HouseholdClient

/// Fixed synthetic scenario. It rejects unexpected writes and persists only this
/// test session's evidence so an actual app relaunch can retry the original bytes.
private final class OperationUndoFixtureServer: @unchecked Sendable {
    struct Snapshot: Codable {
        var previews = 0, posts = 0, writes = 0, exactRetries = 0
        var previewID: String?, operationID: String?, command: Data?, failure: String?
    }
    let host: String
    var changed: (@Sendable (Snapshot) -> Void)?
    private let lock = NSLock(), file: URL
    private var state: Snapshot
    private let f: [String: Any]
    init(directory: URL, workspace: UUID, reset: Bool) throws {
        host = "operation-undo-" + workspace.uuidString.lowercased() + ".test"
        if reset && FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("synthetic-state.json")
        state = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file)) : Snapshot()
        f = try OperationUndoUIFacts.object()
    }
    func notify() { lock.lock(); let value = state; lock.unlock(); changed?(value) }
    private func save() throws {
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtection])
        changed?(state)
    }
    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { state.failure = message; try save(); throw ClientError.invalidResponse }
    }
    private func json(_ object: Any, status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: object)) }
    private func body(_ request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&bytes, maxLength: bytes.count); guard n >= 0 else { throw ClientError.invalidResponse }
            if n == 0 { break }; result.append(contentsOf: bytes.prefix(n))
            guard result.count <= 1_800_000 else { throw ClientError.configuration }
        }
        return result
    }
    private var digest: String { String(repeating: String(state.previews % 16, radix: 16), count: 64) }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        let household = "00000000-0000-4000-8000-000000000001", shopID = "00000000-0000-4000-8000-000000000002"
        let householdPath = "/v1/households/" + household, shopPath = householdPath + "/shops/" + shopID
        try require(request.url?.host == host, "Wrong fixture host")
        if path == "/auth/v1/verify", method == "POST" {
            return try json(["access_token": "undo-fixture-shopper", "refresh_token": "fixture", "expires_in": 3600, "user": ["id": "undo-fixture-shopper", "email_confirmed_at": "date"]])
        }
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer undo-fixture-shopper", "Wrong fixture actor")
        if path == "/auth/v1/user", method == "GET" { return try json(["id": "undo-fixture-shopper", "email_confirmed_at": "date"]) }
        if path == "/v1/me/workspaces", method == "GET" { return try json(["workspaces": [["householdId": household, "label": "Isolated saved changes", "role": "shopper"]]]) }
        if path == householdPath + "/devices", method == "POST" { return try json(["deviceId": "undo-device", "deviceToken": "undo-token"], status: 201) }
        try require(request.value(forHTTPHeaderField: "X-Device-Token") == "undo-token", "Wrong fixture device")
        if path == householdPath + "/bootstrap", method == "GET" {
            return try json(["household": ["id": household, "label": "Isolated saved changes"], "memberId": "00000000-0000-4000-8000-000000000009", "role": "shopper", "shopId": shopID, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_commands", "shopper_inbox", "request_preview"]])
        }
        if path == householdPath + "/replay-windows", method == "POST" { return try json(["id": "00000000-0000-4000-8000-000000000040", "expiresAt": "2099-01-01T00:00:00Z"]) }
        let candidate = f["candidate"] as! [String: Any], action = candidate["action"] as! [String: Any], actionBody = action["body"] as! [String: Any]
        if path == shopPath, method == "GET" {
            var shop = f["shop"] as! [String: Any]
            if state.writes == 1 { shop["shopRevision"] = 8; shop["lines"] = actionBody["lines"]; shop["quote"] = actionBody["quote"] }
            return try json(shop)
        }
        if path == shopPath + "/demand", method == "GET" {
            var page = f["page"] as! [String: Any]
            if state.writes == 1 { page["shopRevision"] = 8; page["graph"] = candidate["after"]; page["totals"] = candidate["afterTotals"]; page["graphDigest"] = String(repeating: "d", count: 64) }
            return try json(page)
        }
        if path == shopPath + "/demand/operations", method == "GET" {
            var history = f["history"] as! [String: Any]
            if state.writes == 1 {
                history["shopRevision"] = 8
                var items = history["items"] as! [[String: Any]]
                items[1]["eligibility"] = ["status": "unavailable", "reason": "food_undo_already_reversed"]
                if let operationID = state.operationID {
                    items.insert(["operationId": operationID, "kind": "shop.patch", "shopRevision": 8, "committedAt": "2026-11-09T12:10:00Z", "eligibility": ["status": "unavailable", "reason": "food_undo_inverse_operation_unsupported"]], at: 0)
                }
                history["items"] = items
            }
            return try json(history)
        }
        if path == shopPath + "/demand/operation-undo-candidates" || path == shopPath + "/demand/operation-undo-previews" {
            try require(method == "POST" && state.writes == 0, "Unexpected review after Apply")
            let preview = path.hasSuffix("operation-undo-previews")
            var expected: [String: Any] = ["targetOperationId": candidate["targetOperationId"]!, "base": candidate["base"]!]
            if preview { expected["effectDigest"] = candidate["effectDigest"]; expected["packs"] = f["packs"] }
            let expectedBody: [String: JSONValue] = try OperationUndoUIFacts.decode(expected)
            let received = try JSONDecoder().decode([String: JSONValue].self, from: body(request))
            try require(received == expectedBody, "Changed source, base or explicit usable-pack review")
            if !preview { return try json(candidate) }
            state.previews += 1; state.previewID = UUID().uuidString.lowercased(); state.operationID = UUID().uuidString.lowercased()
            try save()
            var response = f["response"] as! [String: Any], receipt = response["receipt"] as! [String: Any]
            response["previewId"] = state.previewID; response["previewDigest"] = digest; receipt["operationId"] = state.operationID; response["receipt"] = receipt
            return try json(response)
        }
        if path == householdPath + "/commands", method == "POST" {
            let bytes = try body(request), envelope = try JSONDecoder().decode(CommandEnvelope.self, from: bytes)
            guard let previewID = state.previewID, let operationID = state.operationID else { try require(false, "Apply without preview"); throw ClientError.invalidResponse }
            var expected = actionBody; expected["demandReview"] = ["previewId": previewID, "previewDigest": digest]
            let expectedBody: [String: JSONValue] = try OperationUndoUIFacts.decode(expected)
            try require(envelope.kind == "shop.patch" && envelope.shopId == shopID && envelope.base == .init(shopRevision: 7, authorityEpoch: 2) && envelope.body == expectedBody, "Saved action changed food or money facts")
            state.posts += 1
            if let command = state.command {
                try require(bytes == command && state.writes == 1, "Retry changed original command bytes")
                state.exactRetries += 1; try save()
                return try json(["operationId": operationID, "kind": "shop.patch", "shopId": shopID, "shopRevision": 8, "authorityEpoch": 2, "disposition": "patched"])
            }
            state.command = bytes; state.writes = 1; try save()
            throw URLError(.networkConnectionLost)
        }
        try require(false, "Unexpected route: " + method + " " + path); throw ClientError.invalidResponse
    }
}

private final class OperationUndoFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: OperationUndoFixtureServer] = [:]
    func add(_ server: OperationUndoFixtureServer) { lock.lock(); defer { lock.unlock() }; values[server.host] = server }
    func server(_ host: String?) -> OperationUndoFixtureServer? { lock.lock(); defer { lock.unlock() }; return host.flatMap { values[$0] } }
}
private final class OperationUndoFixtureProtocol: URLProtocol {
    static let registry = OperationUndoFixtureRegistry()
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
private final class OperationUndoFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
@MainActor private final class OperationUndoFixtureState: ObservableObject {
    @Published var household: HouseholdModel?
    @Published var snapshot: OperationUndoFixtureServer.Snapshot?
    @Published var failure: String?
    private var started = false
    func start() async {
        guard !started else { return }; started = true
        do {
            guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--shared-operation-undo-fixture"),
                  let raw = ProcessInfo.processInfo.environment["RITC_OPERATION_UNDO_WORKSPACE"], let workspace = UUID(uuidString: raw) else { throw ClientError.configuration }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestWorkspace/OperationUndo-" + workspace.uuidString)
            let server = try OperationUndoFixtureServer(directory: directory, workspace: workspace, reset: ProcessInfo.processInfo.environment["RITC_OPERATION_UNDO_RESET"] == "1")
            server.changed = { [weak self] value in Task { @MainActor in self?.snapshot = value } }; OperationUndoFixtureProtocol.registry.add(server); server.notify()
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OperationUndoFixtureProtocol.self]
            let transport = HTTPTransport(session: URLSession(configuration: config)), base = URL(string: "https://" + server.host)!
            let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_fixture_only"), vault: OperationUndoFixtureVault(), transport: transport)
            let service = HouseholdService(configuration: try .init(baseURL: base), auth: auth, deviceVault: OperationUndoFixtureVault(), transport: transport)
            let model = HouseholdModel(auth: auth, service: service, outboxURL: directory.appendingPathComponent("shopper-outbox.json"), deletionVault: OperationUndoFixtureVault(), exitVault: OperationUndoFixtureVault())
            model.email = "shopper@example.invalid"; model.code = "123456"; await model.verifyCode()
            guard let workspace = model.workspaces.first else { throw ClientError.invalidResponse }
            model.keepLocalPrivate = true; await model.join(workspace)
            guard model.sharedShop != nil else { throw ClientError.invalidResponse }
            household = model
        } catch { failure = "Fixture setup failed: " + String(describing: error) }
    }
}
struct SharedOperationUndoFixtureRoot: View {
    @StateObject private var state = OperationUndoFixtureState()
    var body: some View {
        VStack(spacing: 2) {
            if let value = state.snapshot {
                Text("Previews: \(value.previews); POSTs: \(value.posts); Writes: \(value.writes); Exact retries: \(value.exactRetries)")
                    .accessibilityIdentifier("fixture.operationUndo.counts").font(.caption).dynamicTypeSize(.large)
                if let failure = value.failure { Text(failure).accessibilityIdentifier("fixture.operationUndo.rejected") }
            }
            if let household = state.household { NavigationStack { HouseholdShopView(model: household) } }
            else if let failure = state.failure { Text(failure).accessibilityIdentifier("fixture.failure") }
            else { ProgressView("Opening isolated saved-change fixture") }
        }.tint(Theme.action).task { await state.start() }
    }
}
#endif
