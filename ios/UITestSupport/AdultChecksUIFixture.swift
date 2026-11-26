#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE && targetEnvironment(simulator)
import Foundation
import HouseholdClient
import SwiftUI

/// Real sign-in, device enrollment, bootstrap, privacy scope and question screens.
private enum CheckPersona: String, CaseIterable {
    case shopper, dani, contributor

    var member: String {
        switch self {
        case .shopper: "22222222-2222-4222-8222-222222222222"
        case .dani: "33333333-3333-4333-8333-333333333333"
        case .contributor: "88888888-8888-4888-8888-888888888888"
        }
    }
    var role: String { self == .shopper ? "shopper" : "contributor" }
}

private final class CheckFixtureServer: @unchecked Sendable {
    let household = "11111111-1111-4111-8111-111111111111"
    let shop = "44444444-4444-4444-8444-444444444444"
    let dinner = "55555555-5555-4555-8555-555555555555"
    let item = "66666666-6666-4666-8666-666666666666"
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    private let clock = ISO8601DateFormatter()
    var counters: (@Sendable (Int, Int, Int, Int) -> Void)?
    private var writes = 0
    private var deniedReads = 0

    func handle(_ request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            guard let url = request.url, url.host == "adult-checks.invalid" else { throw URLError(.unsupportedURL) }
            let path = url.path
            let body = try readBody(request)
            func json(_ value: [String: Any], _ status: Int = 200) throws -> (Int, Data) {
                (status, try JSONSerialization.data(withJSONObject: value))
            }
            if path == "/auth/v1/verify", let email = body["email"] as? String,
               let actor = CheckPersona.allCases.first(where: { email == $0.rawValue + "@example.invalid" }) {
                return try json(["access_token": "test-" + actor.rawValue, "refresh_token": "refresh-" + actor.rawValue,
                                 "expires_in": 3600, "user": ["id": actor.member, "email_confirmed_at": "2026-01-01T00:00:00Z"]])
            }
            guard let actor = CheckPersona.allCases.first(where: { request.value(forHTTPHeaderField: "Authorization") == "Bearer test-" + $0.rawValue })
            else { return try json(["error": ["code": "unauthorized"]], 401) }
            if path == "/auth/v1/user" { return try json(["id": actor.member, "email_confirmed_at": "2026-01-01T00:00:00Z"]) }
            if path == "/v1/me/workspaces" { return try json(["workspaces": [["householdId": household, "label": "Rivera", "role": actor.role]]]) }
            let householdPath = "/v1/households/" + household
            if path == householdPath + "/devices" { return try json(["deviceId": actor.member, "deviceToken": "device-" + actor.rawValue], 201) }
            guard request.value(forHTTPHeaderField: "X-Device-Token") == "device-" + actor.rawValue else {
                return try json(["error": ["code": "wrong_device"]], 403)
            }
            if path.hasSuffix("/bootstrap") {
                let capabilities = ["own_requests"] + (actor == .contributor ? [] : ["adult_checks"])
                    + (actor == .shopper ? ["shopper_inbox", "request_preview", "shopper_commands"] : [])
                return try json(["household": ["id": household, "label": "Rivera"], "memberId": actor.member,
                                 "role": actor.role, "shopId": shop, "enrolled": true, "queueConsent": false, "capabilities": capabilities])
            }
            if path == householdPath + "/shops/" + shop, request.httpMethod == "GET", actor == .shopper {
                let quote: [String: Any] = ["currency": "MXN", "scope": "wholeCheckout", "capScope": "wholeCheckout", "complete": false,
                    "fee": ["kind": "fixed"], "observedAt": "2026-01-01T00:00:00Z", "expiresAt": "2099-01-01T00:00:00Z"]
                let lines: [[String: Any]] = [
                    ["lineId": "77777777-7777-4777-8777-777777777777", "originalItem": "Arroz blanco", "packs": 5, "feeEligible": true],
                    ["lineId": item, "originalItem": "Arroz integral", "packs": 2, "feeEligible": true]
                ]
                return try json(["shopId": shop, "shopRevision": 3, "authorityEpoch": 2, "phase": "draft", "lines": lines, "quote": quote])
            }
            if path.hasSuffix("/requests/mine") || path.hasSuffix("/inbox") { return try json(["requests": [], "nextCursor": NSNull()]) }
            if path == householdPath + "/shops/" + shop + "/meal-plan/changes", actor == .shopper, request.httpMethod == "GET" {
                let meal: [String: Any] = ["title": "Tacos de frijoles", "day": "2026-12-02", "kind": "dinner", "portions": 4, "protected": false]
                return try json(["shopId": shop, "shopRevision": 3, "authorityEpoch": 2, "grantRevision": 1, "phase": "draft",
                                 "shopper": true, "meals": [["occurrenceId": dinner, "revision": 1, "meal": meal]], "proposals": []])
            }
            guard path == householdPath + "/shops/" + shop + "/adult-checks", request.value(forHTTPHeaderField: "X-Shop-ID") == shop else {
                return try json(["error": ["code": "unavailable"]], 404)
            }
            guard actor != .contributor else {
                deniedReads += 1
                publish()
                return try json(["error": ["code": "membership_inactive"]], 403)
            }
            if request.httpMethod == "POST" { try apply(body, actor: actor); writes += 1; publish() }
            return try json(page(actor))
        }
    }

    private func page(_ actor: CheckPersona) -> [String: Any] {
        let shopper = actor == .shopper
        let checks = rows.map { row in row.merging(["canAnswer": !shopper && row["answer"] == nil]) { _, new in new } }
        return ["shopId": shop, "shopRevision": 3, "authorityEpoch": 2, "pairRevision": 4,
                "shopper": shopper, "recipient": shopper ? ["id": CheckPersona.dani.member, "label": "Dani Rivera"] as Any : NSNull(),
                "dinners": shopper ? [["id": dinner, "label": "Tacos de frijoles", "day": "2026-12-02"]] : [],
                "items": shopper ? [["id": item, "label": "Arroz integral", "shoppingPacks": 2]] : [],
                "checks": checks, "validUntil": clock.string(from: Date().addingTimeInterval(60))]
    }

    private func apply(_ body: [String: Any], actor: CheckPersona) throws {
        guard let id = body["id"] as? String, UUID(uuidString: id) != nil else { throw ClientError.invalidResponse }
        switch body["action"] as? String {
        case "ask":
            guard actor == .shopper, body["recipientId"] as? String == CheckPersona.dani.member,
                  body["shopRevision"] as? Int == 3, body["pairRevision"] as? Int == 4, body["authorityEpoch"] as? Int == 2,
                  let kind = body["kind"] as? String, ["attendance", "cupboard"].contains(kind),
                  let source = body["sourceId"] as? String, source == (kind == "attendance" ? dinner : item),
                  let expires = body["expiresAt"] as? String, let end = clock.date(from: expires),
                  abs(end.timeIntervalSinceNow - (kind == "attendance" ? 86400 : 7200)) < 60,
                  !rows.contains(where: { $0["id"] as? String == id }) else { throw ClientError.invalidResponse }
            var row: [String: Any] = ["id": id, "kind": kind, "label": kind == "attendance" ? "Tacos de frijoles" : "Arroz integral",
                                      "sourceId": source, "expiresAt": expires, "reviewed": false]
            if kind == "attendance" { row["day"] = "2026-12-02" } else { row["shoppingPacks"] = 2 }
            rows.append(row)
        case "answer":
            guard actor == .dani, let index = rows.firstIndex(where: { $0["id"] as? String == id }), rows[index]["answer"] == nil,
                  let answer = body["answer"] as? String else { throw ClientError.invalidResponse }
            let answers = rows[index]["kind"] as? String == "attendance" ? ["home", "latePlate", "out"] : ["enough", "low", "cannotCheck"]
            guard answers.contains(answer) else { throw ClientError.invalidResponse }
            rows[index]["answer"] = answer
            rows[index]["answeredAt"] = clock.string(from: Date())
            rows[index]["quantity"] = body["quantity"]
        case "review":
            guard actor == .shopper, let index = rows.firstIndex(where: { $0["id"] as? String == id }),
                  let answer = body["answer"] as? String, rows[index]["answer"] as? String == answer,
                  let timestamp = body["answeredAt"] as? String, rows[index]["answeredAt"] as? String == timestamp
            else { throw ClientError.invalidResponse }
            rows[index]["reviewed"] = true
        default: throw ClientError.invalidResponse
        }
    }

    private func publish() {
        counters?(rows.count, rows.filter { $0["answer"] != nil }.count, writes, deniedReads)
    }
    private func readBody(_ request: URLRequest) throws -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, bytes.isEmpty {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                guard n >= 0 else { throw URLError(.cannotDecodeRawData) }
                if n == 0 { break }
                bytes.append(buffer, count: n)
            }
        }
        if bytes.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
    }
}

struct AdultChecksFixtureRoot: View {
    @State private var actors: [CheckPersona: HouseholdModel] = [:]
    @State private var current = CheckPersona.shopper
    @State private var counts = "0/0/0/0"
    @State private var failure = false
    @StateObject private var membership = MembershipCoordinator()
    @StateObject private var access = WorkspaceAccess()

    var body: some View {
        VStack {
            HStack {
                ForEach(CheckPersona.allCases, id: \.self) { actor in
                    Button(actor.rawValue.capitalized) { current = actor }.accessibilityIdentifier("fixture.checks." + actor.rawValue)
                }
            }
            Text(verbatim: counts).accessibilityIdentifier("fixture.checks.counts")
            if let household = actors[current] {
                NavigationStack { HouseholdSettingsView(model: household) }.id(current)
                    .environmentObject(access).environmentObject(membership)
            } else if failure { Text(verbatim: "Fixture setup failed") }
            else { ProgressView() }
        }.task { await start() }
    }

    private func start() async {
        guard actors.isEmpty else { return }
        let server = CheckFixtureServer()
        server.counters = { questions, replies, writes, denied in
            Task { @MainActor in counts = "\(questions)/\(replies)/\(writes)/\(denied)" }
        }
        ContributorRequestUIFixtureProtocol.handler = server.handle
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContributorRequestUIFixtureProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: configuration))
        let origin = URL(string: "https://adult-checks.invalid")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            var loaded: [CheckPersona: HouseholdModel] = [:]
            for actor in CheckPersona.allCases {
                let auth = AdultAuth(configuration: try .init(projectURL: origin, publishableKey: "sb_publishable_fixture_only"),
                                     vault: ContributorRequestUIFixtureVault(), transport: transport)
                let service = HouseholdService(configuration: try .init(baseURL: origin), auth: auth,
                                               deviceVault: ContributorRequestUIFixtureVault(), transport: transport)
                let model = HouseholdModel(auth: auth, service: service,
                                           outboxURL: directory.appendingPathComponent(actor.rawValue + ".json"),
                                           deletionVault: ContributorRequestUIFixtureVault(), exitVault: ContributorRequestUIFixtureVault())
                model.email = actor.rawValue + "@example.invalid"; model.code = "123456"
                await model.verifyCode()
                guard let workspace = model.workspaces.first else { throw ClientError.invalidResponse }
                model.keepLocalPrivate = true
                await model.join(workspace)
                guard model.projection?.memberId == actor.member else { throw ClientError.invalidResponse }
                loaded[actor] = model
            }
            actors = loaded
        } catch { failure = true }
    }
}
#endif
