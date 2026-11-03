import XCTest
import DeviceSurfaces
@testable import RoomInTheCart

#if DEBUG
@MainActor final class DeviceSurfacesCompositionStartupTests: XCTestCase {
    func testBindingBeforePickupLoadPreservesDurablePickupSurfaceState() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let privateDirectory = base.appendingPathComponent("isolated-surfaces")
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite")); await ledger.open()
        XCTAssertTrue(ledger.ready)
        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        XCTAssertFalse(pickup.ready)
        let testBundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: testBundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "SurfaceStartupTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let routes = try SurfaceRouteStore(url: privateDirectory.appendingPathComponent("routes.json"))
        let reminderStore = try ReminderStore(url: privateDirectory.appendingPathComponent("reminders.sqlite"))
        let target = UUID(), handle = RouteHandle.random(), reminderID = UUID()
        let route = try PrivateRoute(handle: handle, personaID: access.localActorID, targetID: target, generation: UUID(), destination: .shoppingList, expiresAt: .distantFuture)
        let savedRoute = SurfaceRouteRecord(route: route, target: .offer(workspaceID: UUID(), journeyID: UUID(), offerID: target), sourceRevision: 1, reminderID: reminderID)
        try routes.put(savedRoute)
        let intent = try ReminderIntent(id: reminderID, personaID: access.localActorID, targetID: target, subject: .offer, sourceRevision: 1, routeHandle: handle,
            localTime: CivilReminderTime(year: 2026, month: 11, day: 3, hour: 13, minute: 0, timeZoneID: "UTC", confirmedGMTOffset: 0),
            expiresAt: date.addingTimeInterval(172_800), cutoff: date.addingTimeInterval(86_400), language: .english, now: date)
        _ = try await reminderStore.put(intent, expectedVersion: nil, now: date)
        // Both the directory and the policy are explicit: no live group/notification ports.
        let composition = DeviceSurfacesComposition(directory: privateDirectory, bundle: testBundle, clock: { date }, launchArguments: ["--ui-testing"])
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        await composition.foreground()
        XCTAssertFalse(composition.available)
        XCTAssertEqual(try routes.all(), [savedRoute])
        let saved = try await reminderStore.get(reminderID); XCTAssertEqual(saved?.status, .desired)
    }
}

#endif
