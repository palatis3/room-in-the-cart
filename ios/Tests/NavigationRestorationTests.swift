import XCTest
import CoreDomain
import LocalStore
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class NavigationRestorationTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let defaults: UserDefaults
        let access: WorkspaceAccess
        let app: AppModel
        let ledger: LedgerModel
        let household: HouseholdModel
        let routes: NavigationSnapshotStore
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NavigationRestorationTests." + UUID().uuidString))
        let app = AppModel(databaseURL: directory.appendingPathComponent("comparisons.sqlite"))
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        cleanup.track(app, ledger)
        await app.open(); await ledger.open()
        return Fixture(directory: directory, cleanup: cleanup, defaults: defaults, access: WorkspaceAccess(defaults: defaults), app: app,
            ledger: ledger, household: HouseholdModel(outboxURL: directory.appendingPathComponent("outbox.json")),
            routes: NavigationSnapshotStore(url: directory.appendingPathComponent("navigation.json")))
    }
    private func router(_ fixture: Fixture, household: HouseholdModel? = nil, access: WorkspaceAccess? = nil) -> NavigationRestorationModel {
        let model = NavigationRestorationModel(store: fixture.routes)
        model.bind(app: fixture.app, ledger: fixture.ledger, household: household ?? fixture.household, access: access ?? fixture.access)
        return model
    }
    private func saveComparison(_ fixture: Fixture) async throws -> SavedComparison {
        var draft = ComparisonDraft()
        draft.item = "Restored wraps"; draft.needed = "12"
        draft.aQuantity = "8"; draft.aPrice = "3.00"; draft.bQuantity = "6"; draft.bPrice = "2.00"
        let store = try XCTUnwrap(fixture.app.store)
        let record = try await store.save(id: draft.id, title: draft.item, payload: JSONEncoder().encode(SavedPayload(draft: draft)), savedAt: Date())
        await fixture.app.refresh(); return record
    }
    private func comparisonRoute(_ fixture: Fixture, _ record: SavedComparison) throws -> RestorableDestination {
        .comparison(actorID: fixture.access.localActorID, workspaceID: try XCTUnwrap(fixture.app.store?.workspaceID), recordID: record.id)
    }
    func testRelaunchRestoresSelectedTabIndependentPathsAndStableSavedSources() async throws {
        let f = try await fixture()
        let created = await f.ledger.startShop(title: "Saturday pickup"); XCTAssertTrue(created)
        let shop = try XCTUnwrap(f.ledger.shop?.id), workspace = try XCTUnwrap(f.ledger.sourceWorkspaceID)
        let record = try await saveComparison(f)
        let shopRoute = RestorableDestination.shoppingList(actorID: f.access.localActorID, workspaceID: workspace, shopID: shop)
        let recordRoute = try comparisonRoute(f, record)
        let first = router(f)
        first.setPath([shopRoute], for: .shop); first.setPath([recordRoute], for: .records); first.select(.records)
        try await f.app.store?.close()
        let reopenedApp = AppModel(databaseURL: f.directory.appendingPathComponent("comparisons.sqlite"))
        let reopenedLedger = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"))
        f.cleanup.track(reopenedApp, reopenedLedger)
        let reopenedAccess = WorkspaceAccess(defaults: f.defaults)
        let second = NavigationRestorationModel(store: f.routes)
        second.bind(app: reopenedApp, ledger: reopenedLedger, household: f.household, access: reopenedAccess)
        XCTAssertEqual(second.selection, .records)
        XCTAssertTrue(second.recordsPath.isEmpty, "Source identity must be checked after opening, not recovered from the navigation file")
        await reopenedApp.open(); await reopenedLedger.open(); second.reconcile()
        XCTAssertEqual(second.recordsPath, [recordRoute]); XCTAssertEqual(second.shopPath, [shopRoute])
        XCTAssertEqual(reopenedLedger.shop?.id, shop)
        XCTAssertEqual(try reopenedApp.decode(try XCTUnwrap(reopenedApp.records.first)).id, record.id)
        second.select(.dinners)
        XCTAssertEqual(NavigationRestorationModel(store: f.routes).selection, .dinners)
    }
    func testDeletedRecordAndRetiredLedgerCannotBeRestoredOrFollowNewWorkspace() async throws {
        let f = try await fixture()
        let record = try await saveComparison(f)
        let created = await f.ledger.startShop(title: "Delete this source"); XCTAssertTrue(created)
        let oldWorkspace = try XCTUnwrap(f.ledger.sourceWorkspaceID)
        let shopRoute = RestorableDestination.shoppingList(actorID: f.access.localActorID, workspaceID: oldWorkspace, shopID: f.ledger.shop?.id)
        let first = router(f)
        first.setPath([shopRoute], for: .shop); first.setPath([try comparisonRoute(f, record)], for: .records)
        _ = try await f.app.store?.erase(id: record.id, expectedRevision: record.revision, operationID: UUID(), at: Date())
        await f.app.refresh()
        _ = try await f.ledger.eraseWholeLedger(f.ledger.reviewWholeLedgerDeletion())
        first.reconcile()
        XCTAssertTrue(first.shopPath.isEmpty); XCTAssertTrue(first.recordsPath.isEmpty)
        XCTAssertNotEqual(f.ledger.sourceWorkspaceID, oldWorkspace)
        XCTAssertTrue(f.routes.load().shop.isEmpty); XCTAssertTrue(f.routes.load().records.isEmpty)
        // The shipping deletion keeps the replacement unavailable until Records
        // has finished its erasure cleanup. This fixture has no recovered copies.
        try await f.ledger.finishWholeLedgerDeletion()
        let started = await f.ledger.startShop(title: "Different source"); XCTAssertTrue(started)
        first.reconcile(); XCTAssertTrue(first.shopPath.isEmpty)
        XCTAssertTrue(router(f).recordsPath.isEmpty)
    }
    func testLocalPathsDoNotCrossInstallationActorOrSelectedShop() async throws {
        let f = try await fixture()
        let record = try await saveComparison(f)
        let first = router(f); first.setPath([try comparisonRoute(f, record)], for: .records)
        let anotherDefaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let changedActor = router(f, access: WorkspaceAccess(defaults: anotherDefaults))
        XCTAssertTrue(changedActor.recordsPath.isEmpty); XCTAssertTrue(f.routes.load().records.isEmpty)
        let created = await f.ledger.startShop(title: "Original"); XCTAssertTrue(created)
        first.setPath([.shoppingList(actorID: f.access.localActorID, workspaceID: try XCTUnwrap(f.ledger.sourceWorkspaceID), shopID: f.ledger.shop?.id)], for: .shop)
        let other = await f.ledger.startShop(title: "Other pickup"); XCTAssertTrue(other)
        first.reconcile(); XCTAssertTrue(first.shopPath.isEmpty)
    }
    func testEmptyStartPickupRouteAcquiresCommittedShopIdentityWithoutSavingSheetDraft() async throws {
        let f = try await fixture()
        let model = router(f), workspace = try XCTUnwrap(f.ledger.sourceWorkspaceID)
        model.setPath([.shoppingList(actorID: f.access.localActorID, workspaceID: workspace, shopID: nil)], for: .shop)
        let created = await f.ledger.startShop(title: "Created through Start pickup"); XCTAssertTrue(created)
        model.reconcile()
        XCTAssertEqual(f.routes.load().shop, [.shoppingList(actorID: f.access.localActorID, workspaceID: workspace, shopID: f.ledger.shop?.id)])
    }
    func testFirstPickupRecoversTheCommittedDraftIfAnotherWriterStartsItFirst() async throws {
        let f = try await fixture()
        let navigation = router(f)
        let workspace = try XCTUnwrap(f.ledger.sourceWorkspaceID)
        let actor = f.access.localActorID
        let openList = RestorableDestination.shoppingList(actorID: actor, workspaceID: workspace, shopID: nil)
        navigation.setPath([openList], for: .shop)

        let writer = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"))
        f.cleanup.track(writer)
        await writer.open()
        let created = await writer.startShop(title: "Tuesday pickup")
        XCTAssertTrue(created)
        let durableID = try XCTUnwrap(writer.shop?.id)

        let conflictingSave = await f.ledger.startShop(title: "Pickup")
        XCTAssertFalse(conflictingSave)
        XCTAssertTrue(f.ledger.hasPendingSave)
        navigation.reconcile()
        XCTAssertEqual(navigation.shopPath, [openList])
        XCTAssertNil(f.ledger.shop)
        let staleRetry = await f.ledger.retrySave()
        XCTAssertFalse(staleRetry)

        await f.ledger.discardPendingSave()
        navigation.reconcile()
        XCTAssertFalse(f.ledger.hasPendingSave)
        XCTAssertEqual(f.ledger.workspace.shops.map(\.id), [durableID])
        let savedList = RestorableDestination.shoppingList(actorID: actor, workspaceID: workspace, shopID: durableID)
        XCTAssertEqual(navigation.shopPath, [savedList])
        XCTAssertEqual(f.routes.load().shop, [savedList])
    }

    func testIncomingLinkBeforeOpenAlwaysTakesPrecedenceOverSavedTabAndPath() async throws {
        let f = try await fixture()
        let record = try await saveComparison(f), first = router(f)
        first.setPath([try comparisonRoute(f, record)], for: .records); first.select(.records)
        let incoming = NavigationRestorationModel(store: f.routes)
        incoming.preferIncomingLink()
        incoming.bind(app: f.app, ledger: f.ledger, household: f.household, access: f.access)
        XCTAssertEqual(incoming.selection, .shop); XCTAssertTrue(incoming.recordsPath.isEmpty)
        XCTAssertEqual(f.routes.load(), .empty)
    }
    func testMissingMalformedAndFutureNavigationFilesUseOrdinaryShopRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("navigation.json"), store = NavigationSnapshotStore(url: url)
        XCTAssertEqual(store.load(), .empty)
        for text in ["not-json", "{}", "{\"version\":2,\"selection\":\"records\",\"shop\":[],\"dinners\":[],\"records\":[]}"] {
            try Data(text.utf8).write(to: url); XCTAssertEqual(store.load(), .empty)
        }
    }

    func testRefreshingEarlierHouseholdDoesNotUseAnotherModelsRevokedServer() async throws {
        let f = try await fixture()
        let firstServer = RestorationServer()
        let first = try householdModel(firstServer, directory: f.directory.appendingPathComponent("first"))
        try await enroll(first)
        let firstScope = try XCTUnwrap(first.projection)
        let firstReads = firstServer.bootstrapReads
        let secondServer = RestorationServer(); secondServer.revoked = true
        let second = try householdModel(secondServer, directory: f.directory.appendingPathComponent("second"))
        await first.refresh()
        XCTAssertNotNil(first.projection, "Another model's revoked fixture must not revoke this household")
        XCTAssertEqual(first.projection?.household.id, firstScope.household.id)
        XCTAssertEqual(first.projection?.shopId, firstScope.shopId)
        XCTAssertEqual(firstServer.bootstrapReads, firstReads + 1)
        XCTAssertEqual(secondServer.bootstrapReads, 0)
        XCTAssertNil(second.projection)
    }

    func testHouseholdLocatorWaitsForFreshEnrollmentAndRevocationRemovesItDurably() async throws {
        let f = try await fixture()
        let server = RestorationServer(), household = try householdModel(server, directory: f.directory)
        try await enroll(household)
        let scope = try XCTUnwrap(contextualScope(household))
        let route = RestorableDestination.household(.inbox, HouseholdNavigationIdentity(scope))
        let first = router(f, household: household); first.setPath([route], for: .shop)
        XCTAssertEqual(first.shopPath, [route])
        let freshHousehold = try householdModel(server, directory: f.directory.appendingPathComponent("relaunched"))
        let relaunched = router(f, household: freshHousehold)
        XCTAssertTrue(relaunched.shopPath.isEmpty)
        XCTAssertNil(freshHousehold.projection); XCTAssertFalse(freshHousehold.keepLocalPrivate)
        XCTAssertEqual(f.routes.load().shop, [route], "A locator can wait for explicit fresh enrollment, but cannot provide it")
        try await enroll(freshHousehold); relaunched.reconcile()
        XCTAssertEqual(relaunched.shopPath, [route]); XCTAssertGreaterThanOrEqual(server.bootstrapReads, 2)
        server.revoked = true; await freshHousehold.refresh(); relaunched.reconcile()
        XCTAssertNil(freshHousehold.projection); XCTAssertTrue(relaunched.shopPath.isEmpty); XCTAssertTrue(f.routes.load().shop.isEmpty)
        server.revoked = false; try await enroll(freshHousehold); relaunched.reconcile()
        XCTAssertTrue(relaunched.shopPath.isEmpty, "A revoked route must not resurrect on later authorized enrollment")
    }
    func testBackgroundHidesHouseholdPathUntilExplicitFreshScopeAndNeverRestoresComposerConsent() async throws {
        let f = try await fixture()
        let server = RestorationServer(), household = try householdModel(server, directory: f.directory)
        try await enroll(household)
        let identity = HouseholdNavigationIdentity(try XCTUnwrap(contextualScope(household)))
        let route = RestorableDestination.household(.inbox, identity)
        let first = router(f, household: household); first.setPath([route], for: .shop)
        first.suspend(); household.lock(); first.resume()
        XCTAssertTrue(first.shopPath.isEmpty); XCTAssertEqual(f.routes.load().shop, [route])
        try await enroll(household); first.reconcile(); XCTAssertEqual(first.shopPath, [route])
        let encoded = String(decoding: try JSONEncoder().encode(f.routes.load()), as: UTF8.self)
        for field in ["consent", "capabilities", "role", "enrolled", "budget"] { XCTAssertFalse(encoded.contains(field)) }
        first.setPath([.household(.composer, identity)], for: .shop)
        XCTAssertTrue(first.shopPath.isEmpty); XCTAssertTrue(f.routes.load().shop.isEmpty)
    }
    func testHouseholdScopeChangeAndContributorEntryDiscardAdultPaths() async throws {
        let f = try await fixture()
        let server = RestorationServer(), household = try householdModel(server, directory: f.directory)
        try await enroll(household)
        let route = RestorableDestination.household(.inbox, HouseholdNavigationIdentity(try XCTUnwrap(contextualScope(household))))
        let first = router(f, household: household); first.setPath([route], for: .shop)
        server.shop = UUID().uuidString; await household.refresh(); first.reconcile()
        XCTAssertTrue(first.shopPath.isEmpty); XCTAssertTrue(f.routes.load().shop.isEmpty)
        let record = try await saveComparison(f)
        first.setPath([try comparisonRoute(f, record)], for: .records); first.select(.records)
        server.role = "contributor"; server.capabilities = []; await household.refresh(); first.reconcile()
        XCTAssertEqual(first.selection, .shop); XCTAssertTrue(first.recordsPath.isEmpty); XCTAssertEqual(f.routes.load(), .empty)
    }
    func testRestoredHouseholdLocatorRejectsDifferentFreshIdentityScopeOrPermissions() async throws {
        let f = try await fixture()
        let baseline = try householdModel(RestorationServer(), directory: f.directory)
        try await enroll(baseline)
        let route = RestorableDestination.household(.inbox, HouseholdNavigationIdentity(try XCTUnwrap(contextualScope(baseline))))
        let changes: [(RestorationServer) -> Void] = [
            { $0.subject = "different-adult" }, { $0.householdID = UUID().uuidString },
            { $0.member = UUID().uuidString }, { $0.shop = UUID().uuidString },
            { $0.role = "organizer" }, { $0.capabilities = ["shopper_inbox"] }
        ]
        for change in changes {
            let server = RestorationServer(); change(server)
            f.routes.save(NavigationSnapshot(version: 1, selection: .shop, shop: [route], dinners: [], records: []))
            let fresh = try householdModel(server, directory: f.directory.appendingPathComponent(UUID().uuidString))
            let restored = router(f, household: fresh)
            XCTAssertTrue(restored.shopPath.isEmpty)
            try await enroll(fresh); restored.reconcile()
            XCTAssertTrue(restored.shopPath.isEmpty); XCTAssertTrue(f.routes.load().shop.isEmpty)
        }
    }
    func testVerifiedChooserIsScopedToTheExplicitEntryAndInitialAccount() async throws {
        let f = try await fixture()
        let server = RestorationServer()
        let household = try householdModel(server, directory: f.directory)
        household.email = "shopper@example.invalid"; household.code = "123456"
        await household.verifyCode { true }
        XCTAssertTrue(household.showingVerifiedHousehold)
        XCTAssertEqual(household.workspaces.count, 1)
        XCTAssertNil(household.projection)
        XCTAssertFalse(household.keepLocalPrivate)

        // Even a successful verification for a different adult cannot reuse that presentation.
        server.subject = "second-adult"
        household.code = "654321"
        await household.verifyCode { true }
        XCTAssertEqual(household.identity?.subject, "second-adult")
        XCTAssertFalse(household.showingVerifiedHousehold)

        let dismissed = try householdModel(server, directory: f.directory)
        dismissed.email = "shopper@example.invalid"; dismissed.code = "123456"
        await dismissed.verifyCode { false } // The entry disappeared before verification completed.
        XCTAssertNotNil(dismissed.identity)
        XCTAssertFalse(dismissed.showingVerifiedHousehold)
    }
    private func householdModel(_ server: RestorationServer, directory: URL) throws -> HouseholdModel {
        addTeardownBlock { server.close() }
        let transport = HTTPTransport(session: server.makeSession())
        let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL, publishableKey: "sb_publishable_fixture_only"), vault: RestorationVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: server.baseURL), auth: auth, deviceVault: RestorationVault(), transport: transport)
        return HouseholdModel(auth: auth, service: service, outboxURL: directory.appendingPathComponent("household.json"), deletionVault: RestorationVault(), exitVault: RestorationVault())
    }
    private func enroll(_ household: HouseholdModel) async throws {
        household.email = "adult@example.invalid"; household.code = "123456"; await household.verifyCode()
        household.keepLocalPrivate = true; await household.join(try XCTUnwrap(household.workspaces.first))
        XCTAssertNotNil(household.projection)
    }
}

private final class RestorationServer: @unchecked Sendable {
    private let lock = NSLock()
    let host = "restoration-" + UUID().uuidString.lowercased() + ".invalid"
    var baseURL: URL { URL(string: "https://" + host)! }
    private var sessions: [URLSession] = []
    private var closed = false
    private struct State {
        var revoked = false
        var subject = "restoration-adult"
        var householdID = "11111111-1111-4111-8111-111111111111"
        var member = "22222222-2222-4222-8222-222222222222"
        var role = "shopper"
        var shop = "33333333-3333-4333-8333-333333333333"
        var capabilities = ["shopper_inbox", "request_preview", "shopper_commands"]
        var bootstrapReads = 0
    }
    private var state = State()
    var revoked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return state.revoked }
        set { lock.lock(); defer { lock.unlock() }; state.revoked = newValue }
    }
    var subject: String {
        get { lock.lock(); defer { lock.unlock() }; return state.subject }
        set { lock.lock(); defer { lock.unlock() }; state.subject = newValue }
    }
    var householdID: String {
        get { lock.lock(); defer { lock.unlock() }; return state.householdID }
        set { lock.lock(); defer { lock.unlock() }; state.householdID = newValue }
    }
    var member: String {
        get { lock.lock(); defer { lock.unlock() }; return state.member }
        set { lock.lock(); defer { lock.unlock() }; state.member = newValue }
    }
    var role: String {
        get { lock.lock(); defer { lock.unlock() }; return state.role }
        set { lock.lock(); defer { lock.unlock() }; state.role = newValue }
    }
    var shop: String {
        get { lock.lock(); defer { lock.unlock() }; return state.shop }
        set { lock.lock(); defer { lock.unlock() }; state.shop = newValue }
    }
    var capabilities: [String] {
        get { lock.lock(); defer { lock.unlock() }; return state.capabilities }
        set { lock.lock(); defer { lock.unlock() }; state.capabilities = newValue }
    }
    var bootstrapReads: Int { lock.lock(); defer { lock.unlock() }; return state.bootstrapReads }
    func makeSession() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        precondition(!closed, "A closed fixture cannot be reused")
        RestorationProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestorationProtocol.self]
        let session = URLSession(configuration: configuration)
        // Existing restoration tests intentionally create multiple models for one server.
        sessions.append(session)
        return session
    }
    func close() {
        lock.lock()
        closed = true
        let sessions = self.sessions; self.sessions = []
        lock.unlock()
        RestorationProtocol.remove(host: host)
        for session in sessions { session.invalidateAndCancel() }
    }
    deinit { close() }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, request.url?.host == host else { throw URLError(.unsupportedURL) }
        let path = request.url!.path
        let value: Any
        if path == "/auth/v1/verify" {
            value = ["access_token":"fixture-access", "refresh_token":"fixture-refresh", "expires_in":3600, "user":["id":state.subject, "email_confirmed_at":"date"]]
        } else if path == "/auth/v1/user" { value = ["id":state.subject, "email_confirmed_at":"date"]
        } else if path.hasSuffix("/workspaces") {
            value = ["workspaces":[["householdId":state.householdID, "label":"Fixture", "role":state.role]]]
        } else if path.hasSuffix("/devices") { value = ["deviceId":"fixture-device", "deviceToken":"fixture-device-token"]
        } else if path.hasSuffix("/bootstrap") {
            state.bootstrapReads += 1
            if state.revoked { return (403, Data("{\"error\":\"access_ended\"}".utf8)) }
            value = ["household":["id":state.householdID, "label":"Fixture"], "memberId":state.member, "role":state.role, "shopId":state.shop, "enrolled":true, "queueConsent":false, "capabilities":state.capabilities]
        } else { throw URLError(.unsupportedURL) }
        return (200, try JSONSerialization.data(withJSONObject: value))
    }
}
private final class WeakRestorationServer {
    weak var value: RestorationServer?
    init(_ value: RestorationServer) { self.value = value }
}

private final class RestorationProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var servers: [String: WeakRestorationServer] = [:]
    static func register(_ server: RestorationServer) {
        registryLock.lock(); defer { registryLock.unlock() }
        servers[server.host] = WeakRestorationServer(server)
    }
    static func remove(host: String) {
        registryLock.lock(); defer { registryLock.unlock() }; servers.removeValue(forKey: host)
    }
    private static func server(for request: URLRequest) -> RestorationServer? {
        registryLock.lock(); defer { registryLock.unlock() }
        guard request.url?.scheme == "https", let host = request.url?.host else { return nil }
        return servers[host]?.value
    }
    // Claim unknown destinations too, so a missing fixture never reaches the network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server(for: request) else { throw URLError(.unsupportedURL) }
            let (status, bytes) = try server.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class RestorationVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
