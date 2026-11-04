import XCTest
import SwiftUI
import DeviceSurfaces
@testable import RoomInTheCart

#if DEBUG
@MainActor final class DeviceSurfacesCompositionStartupTests: XCTestCase {
    func testRetainedWidgetRouteCannotOpenPreviouslySelectedShop() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let surfaceDirectory = base.appendingPathComponent("surfaces")
        var now = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite")); await ledger.open()
        let madeA = await ledger.startShop(title: "Fictional widget A"); XCTAssertTrue(madeA)
        let shopA = try XCTUnwrap(ledger.shop?.id)
        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: []); await pickup.load()
        let bundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: bundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "RetainedWidget." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let widget = try WidgetProjectionFile(directory: surfaceDirectory.appendingPathComponent("TestWidget"))
        let composition = DeviceSurfacesComposition(directory: surfaceDirectory, bundle: bundle,
            clock: { now }, launchArguments: ["--ui-testing"])
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let projectionA = try await publishedWidget(widget, at: now)
        let handleA = try XCTUnwrap(projectionA.routeHandle)
        now += 60
        let madeB = await ledger.startShop(title: "Fictional widget B"); XCTAssertTrue(madeB)
        let shopB = try XCTUnwrap(ledger.shop?.id)
        let projectionB = try await publishedWidget(widget, at: now)
        let handleB = try XCTUnwrap(projectionB.routeHandle)
        XCTAssertNotEqual(handleA, handleB)
        let saved = ledger.workspace, revision = ledger.revision
        await composition.open(handleA)
        guard case .unavailable = composition.destination else { return XCTFail("Retained A handle must not select A after B becomes current") }
        XCTAssertEqual(ledger.workspace, saved); XCTAssertEqual(ledger.revision, revision)
        XCTAssertEqual(Set(ledger.workspace.shops.map(\.id)), [shopA, shopB])
        await composition.open(handleB)
        guard case .shop(let opened) = composition.destination else { return XCTFail("Current B widget route must remain usable") }
        XCTAssertEqual(opened, shopB); XCTAssertEqual(ledger.workspace, saved)
        let routes = try SurfaceRouteStore(url: surfaceDirectory.appendingPathComponent("routes.json"))
        XCTAssertFalse(try routes.all().contains { $0.route.handle == handleA })
        composition.background(); await composition.foreground()
        await composition.open(handleA)
        guard case .unavailable = composition.destination else { return XCTFail("Foreground reconciliation must not resurrect retained A") }
        XCTAssertEqual(ledger.workspace, saved); XCTAssertEqual(ledger.revision, revision)
    }

    func testResolvedWidgetDestinationDoesNotReselectAfterPickupChanges() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let surfaceDirectory = base.appendingPathComponent("surfaces")
        var now = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite")); await ledger.open()
        let madeA = await ledger.startShop(title: "Fictional widget A"); XCTAssertTrue(madeA)
        let shopA = try XCTUnwrap(ledger.shop?.id)
        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: []); await pickup.load()
        let bundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: bundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "WidgetPresentation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let widget = try WidgetProjectionFile(directory: surfaceDirectory.appendingPathComponent("TestWidget"))
        let composition = DeviceSurfacesComposition(directory: surfaceDirectory, bundle: bundle,
            clock: { now }, launchArguments: ["--ui-testing"])
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let projectionA = try await publishedWidget(widget, at: now)
        await composition.open(try XCTUnwrap(projectionA.routeHandle))
        let resolvedA = try XCTUnwrap(composition.destination)
        guard case .shop(let resolvedID) = resolvedA else { return XCTFail("A must resolve while it is current") }
        XCTAssertEqual(resolvedID, shopA)

        // Deliberately change selection after successful resolution, before the
        // real SwiftUI destination mounts and runs its presentation task.
        now += 60
        let madeB = await ledger.startShop(title: "Fictional widget B"); XCTAssertTrue(madeB)
        _ = try await publishedWidget(widget, at: now)
        let saved = ledger.workspace, revision = ledger.revision
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let appeared = expectation(description: "Resolved widget destination appeared")
        let view = DeviceSurfacesDestination(composition: composition, destination: resolvedA,
            ledger: ledger, pickup: pickup, household: household).onAppear { appeared.fulfill() }
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        await fulfillment(of: [appeared], timeout: 5)
        // Permit the real destination's asynchronous presentation task to run.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(ledger.workspace, saved, "Presentation must not reselect the formerly current pickup")
        XCTAssertEqual(ledger.revision, revision, "Opening a widget must not create a ledger commit")
    }

    func testLargeListSearchLeavesWidgetAloneAndCommittedChangesRefreshIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let privateDirectory = base.appendingPathComponent("isolated-surfaces")
        var now = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite"))
        await ledger.open()
        let started = await ledger.startShop(title: "Fictional pickup")
        XCTAssertTrue(started)
        let shop = try XCTUnwrap(ledger.shop)
        let source = (0..<500).map { "Fixture arroz item \($0)" }.joined(separator: "\n")
        let preview = try shop.stageImport(text: source, source: .paste)
        let imported = await ledger.editShop(key: "surface-performance-import", shopID: shop.id) {
            try $0.commitImport(preview)
        }
        XCTAssertTrue(imported)
        let savedShop = try XCTUnwrap(ledger.shop)
        XCTAssertEqual(savedShop.lines.count, 500)

        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        await pickup.load()
        let bundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: bundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "SurfaceSearchTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let widget = try WidgetProjectionFile(directory: privateDirectory.appendingPathComponent("TestWidget"))
        let composition = DeviceSurfacesComposition(directory: privateDirectory, bundle: bundle,
            clock: { now }, launchArguments: ["--ui-testing"])
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let original = try await publishedWidget(widget, at: now)
        let route = try XCTUnwrap(original.routeHandle)

        now += 60
        for index in 0..<20 {
            ledger.search = "item \(480 + index)"
            XCTAssertEqual(savedShop.search(ledger.search).count, 1)
            try await Task.sleep(for: .milliseconds(25))
        }
        ledger.error = "Fictional form error"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try widget.read(), original, "Search and form errors should leave the published shortcut alone.")

        now += 60
        let line = try XCTUnwrap(savedShop.lines.first)
        let checked = await ledger.editShop(key: "surface-performance-check", shopID: shop.id) {
            try $0.setChecked(lineID: line.id, checked: true)
        }
        XCTAssertTrue(checked)
        let updated = try await publishedWidget(widget, at: now)
        XCTAssertEqual(updated.routeHandle, route)

        now += 60
        let newPickup = await ledger.startShop(title: "Next fictional pickup")
        XCTAssertTrue(newPickup)
        let selected = try await publishedWidget(widget, at: now)
        XCTAssertNotNil(selected.routeHandle)
        XCTAssertNotEqual(selected.routeHandle, route)

        composition.background()
        XCTAssertNil(try widget.read().routeHandle)
    }

    private func publishedWidget(_ file: WidgetProjectionFile, at time: Date) async throws -> WidgetProjection {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let value = try? file.read(), value.writtenAt == time { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(nil, "The bound composition did not publish a widget for \(time).")
    }

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
