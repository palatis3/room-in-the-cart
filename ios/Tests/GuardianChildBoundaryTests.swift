import XCTest
import DeviceSurfaces
@testable import RoomInTheCart

@MainActor final class GuardianChildBoundaryTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("guardian-boundary-" + UUID().uuidString) }
    private func testBundle(_ directory: URL, settings: [String: String] = [:]) throws -> Bundle {
        let url = directory.appendingPathComponent("Fixture.bundle")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        var info = settings
        info["CFBundleIdentifier"] = "invalid.fixture.guardian." + UUID().uuidString
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to:url.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url:url))
    }
    func testMarkerColdLaunchAndCorruptionFailToChildRootInsteadOfAdultTabs() throws {
        let directory = directory(), marker = GuardianChildPresentationMarker(url:directory.appendingPathComponent("child.json"))
        let bundle = try testBundle(directory)
        XCTAssertFalse(try marker.read()); try marker.activate()
        XCTAssertTrue(try marker.read()); XCTAssertTrue(GuardianChildCoordinator(bundle:bundle,marker:marker).presented)
        try Data("corrupt".utf8).write(to:marker.url)
        let blocked = GuardianChildCoordinator(bundle:bundle,marker:marker)
        XCTAssertTrue(blocked.presented); XCTAssertEqual(blocked.destination,.blocked)
    }
    func testUnconfiguredInvitationLeavesPrivateWorkspaceOpenAcrossRelaunch() throws {
        let directory = directory(), bundle = try testBundle(directory, settings: [
            "HouseholdServiceURL": "", "SupabaseProjectURL": "",
            "SupabasePublishableKey": "", "RITCEmailOTPEnabled": "NO"
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = GuardianChildPresentationMarker(url: directory.appendingPathComponent("child.json"))
        let coordinator = GuardianChildCoordinator(bundle: bundle, marker: marker)
        let suite = "GuardianChildBoundary." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let adult = HouseholdModel(bundle: bundle, outboxURL: directory.appendingPathComponent("outbox.json"))
        let surfaces = DeviceSurfacesComposition(directory: directory, bundle: bundle, launchArguments: ["--ui-testing"])
        XCTAssertFalse(coordinator.canOpenInvitation)
        coordinator.open(adult: adult, access: access, surfaces: surfaces)
        XCTAssertFalse(coordinator.presented)
        XCTAssertTrue(access.unlocked)
        XCTAssertFalse(try marker.read())
        XCTAssertFalse(GuardianChildCoordinator(bundle: bundle, marker: marker).presented)
        XCTAssertTrue(WorkspaceAccess(defaults: defaults).unlocked)
    }
    func testChildBoundarySynchronouslyClearsWidgetAndExitKeepsAdultLocked() async throws {
        let directory = directory(), bundle = try testBundle(directory, settings: [
            "HouseholdServiceURL": "https://service.fixture.invalid",
            "SupabaseProjectURL": "https://identity.fixture.invalid",
            "SupabasePublishableKey": "sb_publishable_fixture"
        ])
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
        let identity = try XCTUnwrap(CapturePrivateIdentity.current(access: access, household: adult))
        let scope = PantryDigestScope(origin: try XCTUnwrap(ledger.sourceWorkspaceID), identity: identity)
        let permission = PantryDigestAccess(scope: scope, authorized: { true })
        try surfaces.homeSummaries.setEnabled(true, kind: .useSoon, access: permission)
        try surfaces.homeSummaries.update(.useSoon, access: permission, count: 2)
        surfaces.destination = .capture(UUID())
        let marker = GuardianChildPresentationMarker(url:directory.appendingPathComponent("child-root.json")), coordinator = GuardianChildCoordinator(bundle:bundle,marker:marker)
        XCTAssertTrue(coordinator.canOpenInvitation)
        coordinator.open(adult:adult,access:access,surfaces:surfaces)
        XCTAssertTrue(coordinator.presented); XCTAssertFalse(access.unlocked); XCTAssertTrue(access.isProtected)
        XCTAssertFalse(surfaces.privateAuthorized); XCTAssertNil(surfaces.destination); XCTAssertNil(surfaces.draft); XCTAssertTrue(surfaces.entries.isEmpty)
        XCTAssertNil(try widget.read().routeHandle); XCTAssertTrue(try marker.read())
        XCTAssertFalse(surfaces.homeSummaries.enabled(.useSoon, scope: scope))
        let summaryFile = try AdultFoodSummaryFile(directory: widget.url.deletingLastPathComponent(), kind: .useSoon)
        XCTAssertThrowsError(try summaryFile.read())
        // Leave before the asynchronous invitation service lookup begins.
        await coordinator.removeChildSession()
        XCTAssertFalse(coordinator.presented); XCTAssertFalse(try marker.read())
        XCTAssertFalse(access.unlocked); XCTAssertFalse(WorkspaceAccess(defaults:defaults).unlocked)
        XCTAssertFalse(surfaces.privateAuthorized); XCTAssertNil(try widget.read().routeHandle)
    }
}
