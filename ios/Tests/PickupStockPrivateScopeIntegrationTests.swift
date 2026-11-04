import XCTest
import CoreDomain
import DeviceSurfaces
import HouseholdClient
@testable import RoomInTheCart

private final class StockScopeVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private final class StockScopeServer: @unchecked Sendable {
    let role: String
    let household = UUID().uuidString, member = UUID().uuidString, grant = UUID().uuidString
    private let lock = NSLock()
    private var count = 0
    init(role: String) { self.role = role }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }; count += 1
        let path = try XCTUnwrap(request.url?.path)
        let value: [String: Any]
        if path == "/auth/v1/verify" {
            value = ["access_token":"fixture-access", "refresh_token":"fixture-refresh", "expires_in":3600,
                     "user":["id":"signed-in-stock-owner", "email_confirmed_at":"date"]]
        } else if path == "/auth/v1/user" {
            value = ["id":"signed-in-stock-owner", "email_confirmed_at":"date"]
        } else if path.hasSuffix("/workspaces") {
            value = ["workspaces":[["householdId":household, "label":"Fixture home", "role":role]]]
        } else if path.hasSuffix("/devices") {
            value = ["deviceId":UUID().uuidString, "deviceToken":"fixture-device-token"]
        } else if path.hasSuffix("/bootstrap") {
            var projection: [String: Any] = ["household":["id":household, "label":"Fixture home"], "memberId":member,
                "role":role, "enrolled":true, "queueConsent":false, "capabilities":[]]
            if ["helper", "editor"].contains(role) { projection["grantId"] = grant; projection["capabilities"] = ["helper_view"] }
            value = projection
        } else { throw URLError(.unsupportedURL) }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
private final class StockScopeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [String: StockScopeServer] = [:]
    static func register(_ server: StockScopeServer, host: String) { lock.lock(); defer { lock.unlock() }; servers[host] = server }
    static func remove(host: String) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            Self.lock.lock(); let server = Self.servers[url.host ?? ""]; Self.lock.unlock()
            let data = try XCTUnwrap(server).respond(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class PickupStockPrivateScopeIntegrationTests: XCTestCase {
    private struct Fixture {
        let household: HouseholdModel
        let server: StockScopeServer
        let host: String
        let session: URLSession
    }
    private func signedIn(role: String, directory: URL) async throws -> Fixture {
        let host = UUID().uuidString.lowercased() + ".stock-scope.invalid", server = StockScopeServer(role: role)
        StockScopeProtocol.register(server, host: host)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StockScopeProtocol.self]
        let session = URLSession(configuration: configuration), transport = HTTPTransport(session: session)
        let base = try XCTUnwrap(URL(string: "https://" + host))
        let auth = AdultAuth(configuration: try .init(projectURL: base, publishableKey: "sb_publishable_stock_scope_fixture"), vault: StockScopeVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: base), auth: auth, deviceVault: StockScopeVault(), transport: transport)
        let household = HouseholdModel(auth: auth, service: service, outboxURL: directory.appendingPathComponent("household.json"),
            deletionVault: StockScopeVault(), exitVault: StockScopeVault(), guardianVault: StockScopeVault())
        household.email = "owner@example.invalid"; household.code = "123456"; await household.verifyCode()
        XCTAssertNotNil(household.identity)
        household.keepLocalPrivate = true; await household.join(try XCTUnwrap(household.workspaces.first))
        XCTAssertEqual(household.projection?.role, role)
        return Fixture(household: household, server: server, host: host, session: session)
    }
    private func close(_ fixture: Fixture) { fixture.session.invalidateAndCancel(); StockScopeProtocol.remove(host: fixture.host) }
    private func ownerAccess() throws -> (WorkspaceAccess, UserDefaults, String) {
        let name = "StockScopeOwner." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (WorkspaceAccess(defaults: defaults), defaults, name)
    }
    func testActualSignedInHouseholdLockThenOwnerUnlockPostconditionAllowsPrivateCorrectionOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await signedIn(role: "organizer", directory: directory)
        defer { close(fixture) }
        let (access, defaults, name) = try ownerAccess()
        defer { defaults.removePersistentDomain(forName: name) }
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite")), food = UUID(), now = Date()
        func q(_ n: Int64) throws -> Quantity { .init(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
        let started = await pickup.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: try q(4), available: try q(0), due: nil, confirmedAt: now))
        XCTAssertTrue(started)
        let shop = try XCTUnwrap(pickup.journey?.id), workspace = try XCTUnwrap(pickup.sourceWorkspaceID), id = UUID()
        let original = ConfirmedStockLot(id: id, foodID: food, name: "Counted batch", usable: try q(3), confirmedAt: now, source: .freezer)
        let corrected = ConfirmedStockLot(id: id, foodID: food, name: "Counted batch", usable: try q(1), confirmedAt: now, source: .freezer)
        let saved = await pickup.saveStockLot(original, in: shop); XCTAssertTrue(saved)
        var session = PickupStockReviewSession()
        let online = PickupStockReviewPresentation.current(workspaceID: workspace, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: true, childPresented: false, household: fixture.household)
        session.refresh(online)
        let oldReview = try pickup.previewStockLot(corrected, in: shop, replacing: original, scope: XCTUnwrap(session.scope(for: online)))
        access.protect(); access.background(); fixture.household.lock()
        let count = fixture.server.requestCount
        XCTAssertFalse(access.unlocked); XCTAssertTrue(fixture.household.locked)
        XCTAssertEqual(fixture.household.identity?.subject, "signed-in-stock-owner"); XCTAssertNil(fixture.household.projection)
        let locked = PickupStockReviewPresentation.current(workspaceID: workspace, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: true, childPresented: false, household: fixture.household)
        session.refresh(locked); XCTAssertNil(session.scope(for: locked))
        // Exercise the pure factory's completed OS-owner-authentication postcondition.
        // No production authentication bypass is added, and this unit test does not invoke LAContext.
        let ownerUnlocked = PickupStockReviewPresentation.current(workspaceID: workspace, localActorID: access.localActorID,
            workspaceUnlocked: true, sceneActive: true, childPresented: false, household: fixture.household)
        session.refresh(ownerUnlocked)
        let scope = try XCTUnwrap(session.scope(for: ownerUnlocked))
        XCTAssertTrue(scope.householdLocked); XCTAssertNil(scope.projection)
        let stale = await pickup.applyStockLotReview(oldReview, scope: scope, confirmed: true); XCTAssertFalse(stale)
        let review = try pickup.previewStockLot(corrected, in: shop, replacing: original, scope: scope)
        let applied = await pickup.applyStockLotReview(review, scope: scope, confirmed: true); XCTAssertTrue(applied)
        XCTAssertEqual(pickup.allocation?.demands.first { $0.id == food }?.shortfall, try Rational(3))
        XCTAssertTrue(fixture.household.locked); XCTAssertNil(fixture.household.projection)
        XCTAssertEqual(fixture.server.requestCount, count, "Private review and save must not reauthorize or write to the household service.")
    }
    func testActualLiveContributorHelperAndEditorProjectionsDenyLocalScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (access, defaults, name) = try ownerAccess()
        defer { defaults.removePersistentDomain(forName: name) }
        for role in ["contributor", "helper", "editor"] {
            let fixture = try await signedIn(role: role, directory: directory.appendingPathComponent(role))
            let value = PickupStockReviewPresentation.current(workspaceID: UUID(), localActorID: access.localActorID,
                workspaceUnlocked: access.unlocked, sceneActive: true, childPresented: false, household: fixture.household)
            XCTAssertNil(value.scope(presentationID: UUID()), role)
            close(fixture)
        }
    }
    func testReminderSurvivesHouseholdSuspensionButSignOutCancelsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = try await signedIn(role: "organizer", directory: directory)
        defer { close(fixture) }
        let (access, defaults, name) = try ownerAccess()
        defer { defaults.removePersistentDomain(forName: name) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        await ledger.open(); await pickup.load()
        let surfaces = DeviceSurfacesComposition(directory: directory.appendingPathComponent("surfaces"), launchArguments: ["--ui-testing"])
        surfaces.bind(ledger: ledger, pickup: pickup, household: fixture.household, access: access)
        await surfaces.foreground()
        let store = try XCTUnwrap(surfaces.reminderStore)
        let persona = fixture.household.deviceReminderPersona
        let now = Date(), expires = now.addingTimeInterval(7200)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: now.addingTimeInterval(3600))
        let time = CivilReminderTime(year: try XCTUnwrap(parts.year), month: try XCTUnwrap(parts.month), day: try XCTUnwrap(parts.day),
            hour: try XCTUnwrap(parts.hour), minute: try XCTUnwrap(parts.minute), timeZoneID: "UTC")
        let intent = try ReminderIntent(personaID: access.localActorID, targetID: UUID(), subject: .deferral,
            sourceRevision: 1, routeHandle: .random(), localTime: time, expiresAt: expires, language: .english, now: now)
        surfaces.background()
        let desired = try await store.put(intent, expectedVersion: nil, now: now)

        fixture.household.lock()
        await surfaces.sourceDidChange()
        XCTAssertNil(fixture.household.projection)
        XCTAssertEqual(fixture.household.deviceReminderPersona, persona)
        let suspended = try await store.get(intent.id)
        XCTAssertEqual(suspended, desired)

        // A real sign-out invalidates the old scope even while the device is still locked.
        access.protect()
        await fixture.household.signOut()
        await surfaces.sourceDidChange()
        XCTAssertNotEqual(fixture.household.deviceReminderPersona, persona)
        let signedOut = try await store.get(intent.id)
        XCTAssertEqual(signedOut?.status, .cancelled)
    }
    func testActualDeviceLockAndChildPresentationRemainDenied() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let household = HouseholdModel(outboxURL: directory.appendingPathComponent("unused-household.json"), guardianVault: StockScopeVault())
        let (access, defaults, name) = try ownerAccess()
        defer { defaults.removePersistentDomain(forName: name) }
        let workspace = UUID()
        XCTAssertNotNil(PickupStockReviewPresentation.current(workspaceID: workspace, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: true, childPresented: false, household: household).scope(presentationID: UUID()))
        XCTAssertNil(PickupStockReviewPresentation.current(workspaceID: workspace, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: true, childPresented: true, household: household).scope(presentationID: UUID()))
        access.protect()
        XCTAssertNil(PickupStockReviewPresentation.current(workspaceID: workspace, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: true, childPresented: false, household: household).scope(presentationID: UUID()))
        let childOnly = HouseholdModel(outboxURL: directory.appendingPathComponent("child-household.json"), guardianVault: StockScopeVault(), guardianChildOnly: true)
        XCTAssertNil(PickupStockReviewPresentation.current(workspaceID: workspace, localActorID: access.localActorID,
            workspaceUnlocked: true, sceneActive: true, childPresented: false, household: childOnly).scope(presentationID: UUID()))
    }
}
