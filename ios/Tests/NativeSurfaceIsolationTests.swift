import XCTest
import DeviceSurfaces
@testable import RoomInTheCart

final class SurfaceReconciliationGateTests: XCTestCase {
    private let workspace = UUID(), journey = UUID()
    private func snapshot(ledgerReady: Bool = true, pickupReady: Bool = true, ledgerSaving: Bool = false,
                          pickupSaving: Bool = false, ledgerPending: Bool = false, pickupPending: Bool = false,
                          deleting: Bool = false, workspaceID: UUID? = nil, revision: Int64 = 4,
                          pickupRevisions: [UUID: Int64]? = nil) -> SurfaceSourceSnapshot {
        SurfaceSourceSnapshot(ledgerReady: ledgerReady, pickupReady: pickupReady, ledgerSaving: ledgerSaving,
            pickupSaving: pickupSaving, ledgerHasPendingSave: ledgerPending, pickupHasPendingSave: pickupPending,
            ledgerHasPendingDeletion: deleting, ledgerWorkspaceID: workspaceID ?? workspace,
            ledgerRevision: revision, pickupRevisions: pickupRevisions ?? [journey: 2])
    }
    private func fixture() async throws -> (SurfaceRouteStore, ReminderStore, ReminderCoordinator, SurfaceRouteRecord, ReconciliationScheduler) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SurfaceRouteStore(url: dir.appendingPathComponent("routes.json"))
        let reminders = try ReminderStore(url: dir.appendingPathComponent("reminders.sqlite"))
        let now = Date(timeIntervalSince1970: 1_793_664_000), target = UUID(), handle = RouteHandle.random(), persona = UUID()
        let local = CivilReminderTime(year: 2026, month: 11, day: 3, hour: 13, minute: 0, timeZoneID: "UTC", confirmedGMTOffset: 0)
        let intent = try ReminderIntent(personaID: persona, targetID: target, subject: .offer, sourceRevision: 2, routeHandle: handle, localTime: local,
            expiresAt: now.addingTimeInterval(172_800), cutoff: now.addingTimeInterval(86_400), language: .english, now: now)
        _ = try await reminders.put(intent, expectedVersion: nil, now: now)
        let route = try PrivateRoute(handle: handle, personaID: persona, targetID: target, generation: UUID(), destination: .shoppingList, expiresAt: .distantFuture)
        let row = SurfaceRouteRecord(route: route, target: .offer(workspaceID: workspace, journeyID: journey, offerID: target), sourceRevision: 2, reminderID: intent.id)
        try store.put(row)
        let scheduler = ReconciliationScheduler()
        let coordinator = ReminderCoordinator(store: reminders, scheduler: scheduler, now: { now })
        return (store, reminders, coordinator, row, scheduler)
    }
    private func cleanup(expected: SurfaceSourceSnapshot, current: SurfaceSourceSnapshot, routes: SurfaceRouteStore, reminders: ReminderCoordinator, row: SurfaceRouteRecord) async throws -> Bool {
        do { try SurfaceReconciliationGate(expected: expected).requireCurrent(current) }
        catch SurfaceError.stale { return false }
        try await reminders.erase(try XCTUnwrap(row.reminderID))
        try routes.remove(row.route.handle)
        return true
    }
    func testPreReadyPickupPreservesDurableRouteAndReminder() async throws {
        let (routes, store, coordinator, row, scheduler) = try await fixture()
        let initial = snapshot(pickupReady: false)
        let ran = try await cleanup(expected: initial, current: initial, routes: routes, reminders: coordinator, row: row)
        XCTAssertFalse(ran); XCTAssertEqual(try routes.all(), [row])
        let saved = try await store.get(try XCTUnwrap(row.reminderID)); XCTAssertEqual(saved?.status, .desired)
        let calls = await scheduler.removals; XCTAssertEqual(calls, 0)
    }
    func testPreReadyLedgerPreservesDurableRouteAndReminder() async throws {
        let (routes, store, coordinator, row, _) = try await fixture()
        let initial = snapshot(ledgerReady: false)
        let ran = try await cleanup(expected: initial, current: initial, routes: routes, reminders: coordinator, row: row)
        XCTAssertFalse(ran); XCTAssertEqual(try routes.all(), [row])
        let saved = try await store.get(try XCTUnwrap(row.reminderID)); XCTAssertNotNil(saved)
    }
    func testSavingPendingAndRetirementSnapshotsNeverInferOrphans() async throws {
        let (routes, store, coordinator, row, scheduler) = try await fixture()
        for blocked in [snapshot(ledgerSaving: true), snapshot(pickupSaving: true), snapshot(ledgerPending: true), snapshot(pickupPending: true), snapshot(deleting: true)] {
            let ran = try await cleanup(expected: blocked, current: blocked, routes: routes, reminders: coordinator, row: row)
            XCTAssertFalse(ran); XCTAssertEqual(try routes.all(), [row])
        }
        let saved = try await store.get(try XCTUnwrap(row.reminderID)); XCTAssertNotNil(saved)
        let calls = await scheduler.removals; XCTAssertEqual(calls, 0)
    }
    func testSourceChangingAcrossAwaitPreventsCleanupUntilFreshCompleteReview() async throws {
        let (routes, store, coordinator, row, _) = try await fixture()
        let initial = snapshot()
        for changed in [snapshot(revision: 5), snapshot(workspaceID: UUID()), snapshot(pickupRevisions: [:]), snapshot(pickupPending: true)] {
            let ran = try await cleanup(expected: initial, current: changed, routes: routes, reminders: coordinator, row: row)
            XCTAssertFalse(ran); XCTAssertEqual(try routes.all(), [row])
        }
        let saved = try await store.get(try XCTUnwrap(row.reminderID)); XCTAssertNotNil(saved)
        let current = snapshot(pickupRevisions: [:])
        let cleaned = try await cleanup(expected: current, current: current, routes: routes, reminders: coordinator, row: row)
        XCTAssertTrue(cleaned); XCTAssertTrue(try routes.all().isEmpty)
        let absent = try await store.get(try XCTUnwrap(row.reminderID)); XCTAssertNil(absent)
    }
}
private actor ReconciliationScheduler: NotificationScheduling {
    var removals = 0
    func permission() async -> NotificationPermission { .authorized }
    func requestPermission() async throws -> Bool { true }
    func add(_ notification: ReminderNotification) async throws {}
    func remove(_ identifiers: [String]) async { removals += identifiers.count }
}

import XCTest
import DeviceSurfaces
@testable import RoomInTheCart

final class SurfaceRuntimeIsolationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testDefaultUIFlagUsesOwnedTestRootOnlyInDebug() throws {
        let base = try directory()
        let runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: ["--ui-testing", "--reset-test-workspace"], applicationSupport: base)
        #if DEBUG
        XCTAssertTrue(runtime.isUITesting); XCTAssertTrue(runtime.shouldReset)
        XCTAssertEqual(runtime.directory, base.appendingPathComponent("UITestWorkspace/DeviceSurfacesPrivate", isDirectory: true))
        #else
        XCTAssertFalse(runtime.isUITesting); XCTAssertFalse(runtime.shouldReset)
        XCTAssertEqual(runtime.directory, base.appendingPathComponent("RoomInTheCart/DeviceSurfacesPrivate", isDirectory: true))
        #endif
    }
    func testInjectedDirectoryWinsAndCanNeverBeResetByFlags() throws {
        let base = try directory(), injected = try directory()
        let marker = injected.appendingPathComponent("keep.json"); try Data("preserve".utf8).write(to: marker)
        let runtime = SurfaceRuntimeIsolation(directory: injected, launchArguments: ["--ui-testing", "--reset-test-workspace"], applicationSupport: base)
        XCTAssertEqual(runtime.directory, injected); XCTAssertFalse(runtime.shouldReset)
        try runtime.resetOwnedTestDirectory()
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
    }
    func testResetFlagWithoutUITestingNeverDeletesLiveDirectory() throws {
        let base = try directory()
        let runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: ["--reset-test-workspace"], applicationSupport: base)
        try FileManager.default.createDirectory(at: runtime.directory, withIntermediateDirectories: true)
        let marker = runtime.directory.appendingPathComponent("routes.json"); try Data("real route".utf8).write(to: marker)
        try runtime.resetOwnedTestDirectory()
        XCTAssertFalse(runtime.shouldReset); XCTAssertEqual(try Data(contentsOf: marker), Data("real route".utf8))
    }
    func testNormalRuntimeUsesExplicitLiveFactoriesAndEffects() async throws {
        let base = try directory(), runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: [], applicationSupport: try directory())
        var calls = 0
        _ = try runtime.makeInbox { calls += 1; return try SelectedTextInbox(url: base.appendingPathComponent("inbox.sqlite")) }
        _ = try runtime.makeWidget { calls += 1; return try WidgetProjectionFile(directory: base) }
        _ = runtime.makeScheduler { calls += 1; return SpyScheduler() }
        runtime.performSystemEffect { calls += 1 }
        XCTAssertEqual(calls, 4)
    }
    #if DEBUG
    func testResetDeletesOnlyOwnedTestDirectoryAndPreservesDevelopmentFiles() throws {
        let base = try directory()
        let live = base.appendingPathComponent("RoomInTheCart/DeviceSurfacesPrivate", isDirectory: true)
        let runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: ["--ui-testing", "--reset-test-workspace"], applicationSupport: base)
        for folder in [live, runtime.directory] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try Data("sentinel".utf8).write(to: folder.appendingPathComponent("routes.json")) }
        try runtime.resetOwnedTestDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.directory.path))
        XCTAssertEqual(try Data(contentsOf: live.appendingPathComponent("routes.json")), Data("sentinel".utf8))
    }
    func testRedirectedTestRootCannotDeleteDevelopmentState() throws {
        let base = try directory(), live = try directory()
        let marker = live.appendingPathComponent("keep.sqlite"); try Data("private".utf8).write(to: marker)
        let testRoot = base.appendingPathComponent("UITestWorkspace", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: testRoot, withDestinationURL: live)
        let runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: ["--ui-testing", "--reset-test-workspace"], applicationSupport: base)
        XCTAssertThrowsError(try runtime.resetOwnedTestDirectory())
        let noReset = SurfaceRuntimeIsolation(directory: nil, launchArguments: ["--ui-testing"], applicationSupport: base)
        XCTAssertThrowsError(try noReset.resetOwnedTestDirectory())
        XCTAssertEqual(try Data(contentsOf: marker), Data("private".utf8))
    }
    func testUITestFactoriesCannotOpenLiveGroupsOrInvokeSystemEffects() async throws {
        let base = try directory(), runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: ["--ui-testing"], applicationSupport: try directory())
        let liveInbox = try SelectedTextInbox(url: base.appendingPathComponent("real-inbox.sqlite"))
        let now = Date(timeIntervalSince1970: 1_793_664_000)
        let realID = UUID(); _ = try await liveInbox.stage(operationID: realID, originalText: "Private development groceries", now: now)
        let realWidget = try WidgetProjectionFile(directory: base.appendingPathComponent("real-widget"))
        let original = try WidgetProjection(writtenAt: now, routeHandle: .random(), destination: .shoppingList)
        try realWidget.publishAfterCommit(original)
        let before = try Data(contentsOf: realWidget.url)
        var calls = 0
        let testInbox = try runtime.makeInbox { calls += 1; return liveInbox }
        let testWidget = try runtime.makeWidget { calls += 1; return realWidget }
        _ = try await testInbox.stage(operationID: UUID(), originalText: "Test groceries", now: now)
        try testWidget.clear(now: now)
        runtime.performSystemEffect { calls += 1 }
        _ = runtime.makeScheduler { calls += 1; return SpyScheduler() }
        XCTAssertEqual(calls, 0)
        let untouched = try await liveInbox.pending(now: now)
        XCTAssertEqual(untouched.map(\.id), [realID]); XCTAssertEqual(try Data(contentsOf: realWidget.url), before)
        XCTAssertTrue(testWidget.url.path.hasPrefix(runtime.directory.path + "/"))
    }
    func testUITestReminderCannotRequestRegisterOrRemoveRealNotifications() async throws {
        let runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: ["--ui-testing"], applicationSupport: try directory())
        let live = SpyScheduler(); var factoryCalls = 0
        let scheduler = runtime.makeScheduler { factoryCalls += 1; return live }
        let now = Date(timeIntervalSince1970: 1_793_664_000)
        let local = CivilReminderTime(year: 2026, month: 11, day: 3, hour: 13, minute: 0, timeZoneID: "UTC", confirmedGMTOffset: 0)
        let intent = try ReminderIntent(personaID: UUID(), targetID: UUID(), subject: .deferral, sourceRevision: 1, routeHandle: .random(), localTime: local, expiresAt: now.addingTimeInterval(172_800), language: .english, now: now)
        let store = try ReminderStore(url: runtime.directory.appendingPathComponent("reminders.sqlite"))
        let coordinator = ReminderCoordinator(store: store, scheduler: scheduler, now: { now })
        let saved = try await coordinator.save(intent, expectedVersion: nil, requestPermission: true)
        XCTAssertEqual(saved.status, .denied)
        let permitted = try await scheduler.requestPermission(); XCTAssertFalse(permitted)
        do { try await scheduler.add(ReminderNotification(intent)); XCTFail() } catch {}
        try await coordinator.erase(intent.id)
        XCTAssertEqual(factoryCalls, 0)
        let calls = await live.calls; XCTAssertEqual(calls, 0)
    }
    #endif
}
private actor SpyScheduler: NotificationScheduling {
    var calls = 0
    func permission() async -> NotificationPermission { calls += 1; return .authorized }
    func requestPermission() async throws -> Bool { calls += 1; return true }
    func add(_ notification: ReminderNotification) async throws { calls += 1 }
    func remove(_ identifiers: [String]) async { calls += 1 }
}
