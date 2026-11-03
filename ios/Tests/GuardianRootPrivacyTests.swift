import XCTest
import DeviceSurfaces
@testable import RoomInTheCart

@MainActor final class GuardianRootPrivacyTests: XCTestCase {
    func testColdPrivacyBoundaryClearsPriorShortcutWithoutOpeningAdultStoresOrTouchingInbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let widget = try WidgetProjectionFile(directory: directory.appendingPathComponent("TestWidget"))
        try widget.publishAfterCommit(WidgetProjection(writtenAt: now, routeHandle: .random(), destination: .shoppingList))
        let inbox = try SelectedTextInbox(url: directory.appendingPathComponent("TestInbox/selected-text.sqlite"))
        let operation = UUID()
        _ = try await inbox.stage(operationID: operation, originalText: "Adult private draft", now: now)
        let surfaces = DeviceSurfacesComposition(directory: directory, clock: { now }, launchArguments: ["--ui-testing"])

        // Deliberately do not bind or open a ledger, pickup, or adult account.
        surfaces.background()

        XCTAssertNil(try widget.read().routeHandle)
        XCTAssertEqual(try widget.read().destination, .capture)
        XCTAssertFalse(surfaces.privateAuthorized)
        let retained = try await inbox.pending(now: now)
        XCTAssertEqual(retained.map(\.id), [operation])
    }

    func testUnreadableChildMarkerCannotReopenAdultRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = GuardianChildPresentationMarker(url: directory.appendingPathComponent("marker.json"))
        try Data("{not a complete marker".utf8).write(to: marker.url)
        let child = GuardianChildCoordinator(marker: marker)
        XCTAssertTrue(child.presented)
        XCTAssertEqual(child.destination, .blocked)
    }
}
