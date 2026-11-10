#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation
import SwiftUI
import HouseholdClient
import RecordArchive

/// Frozen synthetic v2 response; exact source and response hashes are retained in
/// the UI packet. This is transport-only fixture evidence, not live service proof.
private enum SharedRecordsFixturePayload {
    static let sourceSHA256 = "bcdd56df05221fd99952548a715799560bb7da0105a3f984048218fa4d81a0d1"
    static let responseSHA256 = "b286abb25c94609bbaed5a180ebf6a65e6a515fe4d7521adbd63ee254d692953"
    static let data = Data(#"""
{"asOf":"2026-11-10T12:00:00.000Z","record":{"food":{"basket":[{"feeEligible":true,"id":"00000000-0000-4000-8000-000000000010","name":"Apples","packs":1,"priceMinor":200},{"feeEligible":true,"id":"00000000-0000-4000-8000-000000000011","name":"Wraps","packs":2,"priceMinor":null}],"bindings":[],"catalog":[{"id":"00000000-0000-4000-8000-000000000021","originalQuantityText":null,"originalText":"Unknown lunch wraps","quantity":null,"requiredLineId":null,"revision":2,"source":{"bindingId":null,"groupId":null,"ingredientId":"00000000-0000-4000-8000-000000000031","kind":"reservation","originOccurrenceId":"00000000-0000-4000-8000-000000000030","purpose":"School lunch — original words","reservationId":"00000000-0000-4000-8000-000000000021"},"sourceExclusions":[{"ingredientId":"00000000-0000-4000-8000-000000000031","label":"Exact family restriction","occurrenceId":"00000000-0000-4000-8000-000000000030","resolution":{"kind":"unresolved"}}],"sourceLabel":"Protected lunch"}],"coverage":{"allocatableUnboundFactIds":[],"completeFoodCoverage":false,"protectedUnboundFactIds":["00000000-0000-4000-8000-000000000021"],"status":"partial","trackedSubtotals":[{"activeContributionIds":["00000000-0000-4000-8000-000000000020"],"lineId":"00000000-0000-4000-8000-000000000010","quantity":{"denominator":"1","numerator":"3"},"unit":"count"}],"unboundFactIds":["00000000-0000-4000-8000-000000000021"],"untrackedBasketIds":["00000000-0000-4000-8000-000000000011"]},"graph":{"contributions":[{"contains":[],"exclusions":[],"id":"00000000-0000-4000-8000-000000000020","lineId":"00000000-0000-4000-8000-000000000010","originalText":"Apples","productKey":"apples","productName":"Apples","quantity":{"amount":{"denominator":"1","numerator":"3"},"confirmedConversion":null,"originalLiteral":"three apples","unit":"count"},"removedAt":null,"source":{"kind":"manual"},"sourceExclusions":[]}],"conversionTableVersion":"us-customary-metric-v1","edges":[],"householdId":"00000000-0000-4000-8000-000000000001","lines":[{"id":"00000000-0000-4000-8000-000000000010","name":"Apples","originalOrder":0,"trashedAt":null,"unit":"count"},{"id":"00000000-0000-4000-8000-000000000011","name":"Wraps","originalOrder":1,"trashedAt":"2026-11-10T12:00:00.000Z","unit":"count"}],"revision":3,"schemaVersion":1,"shopId":"00000000-0000-4000-8000-000000000002","usedIds":["00000000-0000-4000-8000-000000000010","00000000-0000-4000-8000-000000000011","00000000-0000-4000-8000-000000000020","00000000-0000-4000-8000-000000000021"]},"legacyLineIds":["00000000-0000-4000-8000-000000000011"],"packReview":{"state":"recorded","values":[{"acceptUnresolved":false,"lineId":"00000000-0000-4000-8000-000000000010","usablePerPack":{"amount":{"denominator":"1","numerator":"3"},"confirmedConversion":null,"originalLiteral":"three apples","unit":"count"}}]},"status":"enabled","unbound":[{"factId":"00000000-0000-4000-8000-000000000021","transferred":{"contains":[],"exclusions":[],"id":"00000000-0000-4000-8000-000000000021","lineId":"00000000-0000-4000-8000-000000000011","originalText":"Unknown lunch wraps","productKey":"wraps","productName":"Wraps","quantity":null,"removedAt":null,"source":{"bindingId":null,"groupId":null,"ingredientId":"00000000-0000-4000-8000-000000000031","kind":"reservation","originOccurrenceId":"00000000-0000-4000-8000-000000000030","purpose":"School lunch — original words","reservationId":"00000000-0000-4000-8000-000000000021"},"sourceExclusions":[{"ingredientId":"00000000-0000-4000-8000-000000000031","label":"Exact family restriction","occurrenceId":"00000000-0000-4000-8000-000000000030","resolution":{"kind":"unresolved"}}]}}]},"mealOccurrences":[{"meal":{"day":null,"kind":"lunch","portions":2,"protected":true,"title":"Lunch"},"occurrenceId":"00000000-0000-4000-8000-000000000030","revision":2}],"origin":{"householdId":"00000000-0000-4000-8000-000000000001","shopId":"00000000-0000-4000-8000-000000000002"},"phase":"draft","privacyRevision":2,"projection":"assigned-shopper-independent-record-v2","quote":{"capMinor":2000,"capScope":"wholeCheckout","complete":false,"currency":"USD","depositsMinor":0,"discountsMinor":0,"expiresAt":"2026-11-11T12:00:00.000Z","fee":{"amountMinor":null,"kind":"fixed"},"observedAt":"2026-11-10T12:00:00.000Z","scope":"wholeCheckout","taxesMinor":0},"schemaVersion":2,"shopRevision":8,"storeBasisRevision":null,"storeReviewRequired":false},"recordDigest":"4319df1437fdd66d0bd73d63bb87efb10f0aa3b74f09442ccd6dd408011673ca","schemaVersion":2}
"""#.utf8)
}
private final class SharedRecordsFixtureServer: @unchecked Sendable {
    static let host = "shared-records-fixture.invalid"
    static let household = "00000000-0000-4000-8000-000000000001"
    static let member = "00000000-0000-4000-8000-000000000090"
    static let shop = "00000000-0000-4000-8000-000000000002"
    struct Evidence: Equatable, Sendable { var reads = 0; var mutations = 0; var failure: String? }
    private let lock = NSLock()
    private var current = Evidence()
    func evidence() -> Evidence { lock.lock(); defer { lock.unlock() }; return current }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        func json(_ value: Any, status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        func fail(_ message: String) throws -> (Int, Data) {
            current.failure = message
            return try json(["error": ["code": "fixture_unexpected_request"]], status: 409)
        }
        guard request.url?.host == Self.host else { return try fail("Wrong fixture host") }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        if path == "/auth/v1/verify", method == "POST" {
            return try json(["access_token": "shared-records-adult", "refresh_token": "shared-records-refresh", "expires_in": 3600,
                             "user": ["id": "shared-records-adult", "email_confirmed_at": "date"]])
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer shared-records-adult" else { return try fail("Wrong fixture actor") }
        if path == "/auth/v1/user", method == "GET" { return try json(["id": "shared-records-adult", "email_confirmed_at": "date"]) }
        if path == "/v1/me/workspaces", method == "GET" {
            return try json(["workspaces": [["householdId": Self.household, "label": "S20 shared Records fixture", "role": "shopper"]]])
        }
        let root = "/v1/households/" + Self.household
        if path == root + "/devices", method == "POST" { return try json(["deviceId": "shared-records-device", "deviceToken": "shared-records-device-token"], status: 201) }
        guard request.value(forHTTPHeaderField: "X-Device-Token") == "shared-records-device-token" else { return try fail("Wrong fixture device") }
        if method != "GET" { current.mutations += 1; return try fail("Records must not request a replay window or mutation") }
        if path == root + "/bootstrap" {
            return try json(["household": ["id": Self.household, "label": "S20 shared Records fixture"], "memberId": Self.member,
                             "role": "shopper", "shopId": Self.shop, "enrolled": true, "queueConsent": false,
                             "capabilities": ["shopper_commands", "shopper_inbox", "request_preview"]])
        }
        if path == root + "/shops/" + Self.shop + "/records/snapshot/v2" {
            let selected = request.value(forHTTPHeaderField: "X-Shop-ID")
            guard selected == nil || selected == Self.shop else { return try fail("Wrong selected shop") }
            current.reads += 1
            return (200, SharedRecordsFixturePayload.data)
        }
        return try fail("Unexpected fixture route: " + method + " " + path)
    }
}
private final class SharedRecordsFixtureProtocol: URLProtocol {
    static let server = SharedRecordsFixtureServer()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == SharedRecordsFixtureServer.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.server.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class SharedRecordsFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

@MainActor private final class SharedRecordsFixtureState: ObservableObject {
    let app: AppModel
    let ledger: LedgerModel
    let pickup: PickupModel
    let household: HouseholdModel
    let access: WorkspaceAccess
    @Published private(set) var ready = false
    @Published private(set) var failure = false
    @Published private(set) var count = 0
    @Published private(set) var copyID = "none"
    @Published private(set) var savedFiles = 0
    @Published private(set) var encrypted = false
    @Published private(set) var unchanged = true
    @Published private(set) var network = SharedRecordsFixtureServer.Evidence()
    private let registryURL: URL
    private let savedFile: URL
    private var registry: RecoveryRegistry?
    private var originalLocal: Data?
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestWorkspace", isDirectory: true)
        let directory = base.appendingPathComponent("SharedRecordsFixture", isDirectory: true), records = base.appendingPathComponent("Records", isDirectory: true)
        let defaults = UserDefaults(suiteName: "dev.roominthecart.shared-records-ui-fixture")!
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--shared-records-fixture"),
           ProcessInfo.processInfo.arguments.contains("--reset-shared-records-fixture") {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: records)
            defaults.removePersistentDomain(forName: "dev.roominthecart.shared-records-ui-fixture")
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        registryURL = records.appendingPathComponent("recovery-v1.json")
        savedFile = directory.appendingPathComponent("shared-record.roomrecovery")
        app = AppModel(databaseURL: directory.appendingPathComponent("comparisons.sqlite"))
        ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        access = WorkspaceAccess(defaults: defaults)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SharedRecordsFixtureProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config)), url = URL(string: "https://" + SharedRecordsFixtureServer.host)!
        // Fixed .invalid endpoints and in-memory vaults; no real account/provider.
        let auth = AdultAuth(configuration: try! .init(projectURL: url, publishableKey: "sb_publishable_fixture_only"), vault: SharedRecordsFixtureVault(), transport: transport)
        let service = HouseholdService(configuration: try! .init(baseURL: url), auth: auth, deviceVault: SharedRecordsFixtureVault(), transport: transport)
        household = HouseholdModel(auth: auth, service: service, outboxURL: directory.appendingPathComponent("outbox.json"),
            deletionVault: SharedRecordsFixtureVault(), exitVault: SharedRecordsFixtureVault(), guardianVault: SharedRecordsFixtureVault())
    }
    var files: RecordsMediaUITestFileAdapter {
        .init(save: { [weak self] document in
            guard let self, document.kind == .recovery,
                  let root = try JSONSerialization.jsonObject(with: document.data) as? [String: Any],
                  root["algorithm"] as? String == "AES-256-GCM" else { throw ArchiveError.integrity }
            try document.data.write(to: self.savedFile, options: [.atomic, .completeFileProtection])
            self.savedFiles += 1
            self.encrypted = !String(decoding: document.data, as: UTF8.self).contains("Unknown lunch wraps")
        }, selectedURL: { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: self.savedFile.path) else { return nil }
            return self.savedFile
        })
    }
    func start() async {
        guard !ready, !failure else { return }
        do {
            guard ArchiveCodec.digest(SharedRecordsFixturePayload.data) == SharedRecordsFixturePayload.responseSHA256 else { throw ArchiveError.integrity }
            _ = try SharedRecordWire.snapshot(from: SharedRecordsFixturePayload.data)
            await app.open(); await ledger.open(); await pickup.load()
            guard app.ready, ledger.ready, pickup.ready, access.unlocked else { throw ArchiveError.unavailable }
            originalLocal = try RecordsNativeCodec.canonical(RecordsNativeCodec.ledger(ledger.exportPayload()))
            registry = try RecoveryRegistry(url: registryURL)
            household.email = "shopper@example.invalid"; household.code = "123456"; await household.verifyCode()
            guard let workspace = household.workspaces.first else { throw ArchiveError.unavailable }
            household.keepLocalPrivate = true; await household.join(workspace)
            guard household.projection?.shopId == SharedRecordsFixtureServer.shop else { throw ArchiveError.unavailable }
            try await refresh(); ready = true
        } catch { failure = true }
    }
    func refresh() async throws {
        guard let registry else { throw ArchiveError.unavailable }
        let records = try await registry.refreshList(), shared = records.filter { $0.record.kind == .sharedShop }
        let nextCount = shared.count, nextID = shared.first?.id ?? "none"
        if count != nextCount { count = nextCount }; if copyID != nextID { copyID = nextID }
        let sourceUnchanged = try RecordsNativeCodec.canonical(RecordsNativeCodec.ledger(ledger.exportPayload())) == originalLocal &&
            ArchiveCodec.digest(SharedRecordsFixturePayload.data) == SharedRecordsFixturePayload.responseSHA256
        if unchanged != sourceUnchanged { unchanged = sourceUnchanged }
        let next = SharedRecordsFixtureProtocol.server.evidence(); if network != next { network = next }
        if next.failure != nil { failure = true }
    }
}
struct SharedRecordsUIFixtureRoot: View {
    @StateObject private var fixture = SharedRecordsFixtureState()
    var body: some View {
        VStack(spacing: 2) {
            Text("Copies: \(fixture.count); Saved files: \(fixture.savedFiles); Encrypted: \(fixture.encrypted ? "yes" : "no")")
                .accessibilityIdentifier("fixture.sharedRecords.storage").font(.caption2)
            Text("Reads: \(fixture.network.reads); Mutations: \(fixture.network.mutations); Unchanged: \(fixture.unchanged ? "yes" : "no")")
                .accessibilityIdentifier("fixture.sharedRecords.network").font(.caption2)
            Text(fixture.copyID).accessibilityIdentifier("fixture.sharedRecords.copyID").font(.caption2)
            if fixture.failure { Text("Shared Records fixture failed").accessibilityIdentifier("fixture.sharedRecords.failure") }
            else if fixture.ready {
                NavigationStack {
                    RecordsToolsEntryView(app: fixture.app, ledger: fixture.ledger, pickup: fixture.pickup,
                        erasureCleanup: RecordsErasureCleanup(eraseLedgerWorkspace: { try await CaptureMediaStore.shared.eraseWorkspace($0) },
                            erasePickupRecord: { try await CaptureMediaStore.shared.erasePickupRecord(workspaceID: $0, recordID: $1) }))
                }
                .environmentObject(fixture.app).environmentObject(fixture.ledger).environmentObject(fixture.pickup)
                .environmentObject(fixture.household).environmentObject(fixture.access)
                .environment(\.recordsMediaUITestFiles, fixture.files).tint(Theme.action)
            } else { ProgressView("Opening shared Records fixture") }
        }
        .task {
            await fixture.start()
            while !Task.isCancelled, fixture.ready {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                do { try await fixture.refresh() } catch { return }
            }
        }
    }
}
#endif
