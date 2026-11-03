import XCTest
import DeviceSurfaces
@testable import RoomInTheCart

@MainActor final class GuardianChildBoundaryTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("guardian-boundary-" + UUID().uuidString) }
    private func unconfiguredBundle(_ directory: URL) throws -> Bundle {
        let url = directory.appendingPathComponent("Unconfigured.bundle")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        let data = try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"invalid.fixture.guardian"],format:.xml,options:0)
        try data.write(to:url.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url:url))
    }
    func testMarkerColdLaunchAndCorruptionFailToChildRootInsteadOfAdultTabs() throws {
        let directory = directory(), marker = GuardianChildPresentationMarker(url:directory.appendingPathComponent("child.json"))
        let bundle = try unconfiguredBundle(directory)
        XCTAssertFalse(try marker.read()); try marker.activate()
        XCTAssertTrue(try marker.read()); XCTAssertTrue(GuardianChildCoordinator(bundle:bundle,marker:marker).presented)
        try Data("corrupt".utf8).write(to:marker.url)
        let blocked = GuardianChildCoordinator(bundle:bundle,marker:marker)
        XCTAssertTrue(blocked.presented); XCTAssertEqual(blocked.destination,.blocked)
    }
    func testChildBoundarySynchronouslyClearsWidgetAndExitKeepsAdultLocked() async throws {
        let directory = directory(), bundle = try unconfiguredBundle(directory)
        let suite = "GuardianChildBoundary." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let access = WorkspaceAccess(defaults:defaults), adult = HouseholdModel(bundle:bundle,outboxURL:directory.appendingPathComponent("adult-outbox.json"))
        let ledger = LedgerModel(databaseURL:directory.appendingPathComponent("ledger.sqlite")); await ledger.open()
        let started = await ledger.startShop(title:"Fictional private pickup")
        XCTAssertTrue(started); XCTAssertNotNil(ledger.shop)
        let pickup = PickupModel(databaseURL:directory.appendingPathComponent("pickup.sqlite")); await pickup.load()
        let surfaces = DeviceSurfacesComposition(directory:directory.appendingPathComponent("surfaces"),bundle:bundle,launchArguments:["--ui-testing"])
        surfaces.bind(ledger:ledger,pickup:pickup,household:adult,access:access)
        await surfaces.foreground()
        let widget = try WidgetProjectionFile(directory:directory.appendingPathComponent("surfaces/TestWidget"))
        for _ in 0..<100 {
            if (try? widget.read().routeHandle) != nil { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertTrue(surfaces.privateAuthorized); XCTAssertNotNil(try widget.read().routeHandle)
        surfaces.destination = .capture(UUID())
        let marker = GuardianChildPresentationMarker(url:directory.appendingPathComponent("child-root.json")), coordinator = GuardianChildCoordinator(bundle:bundle,marker:marker)
        coordinator.open(adult:adult,access:access,surfaces:surfaces)
        XCTAssertTrue(coordinator.presented); XCTAssertFalse(access.unlocked); XCTAssertTrue(access.isProtected)
        XCTAssertFalse(surfaces.privateAuthorized); XCTAssertNil(surfaces.destination); XCTAssertNil(surfaces.draft); XCTAssertTrue(surfaces.entries.isEmpty)
        XCTAssertNil(try widget.read().routeHandle); XCTAssertTrue(try marker.read())
        for _ in 0..<100 {
            if coordinator.destination != .starting && !coordinator.busy { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        await coordinator.removeChildSession()
        XCTAssertFalse(coordinator.presented); XCTAssertFalse(try marker.read())
        XCTAssertFalse(access.unlocked); XCTAssertFalse(WorkspaceAccess(defaults:defaults).unlocked)
        XCTAssertFalse(surfaces.privateAuthorized); XCTAssertNil(try widget.read().routeHandle)
    }
}
