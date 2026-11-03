import XCTest
import DeviceSurfaces
@testable import RoomInTheCart

@MainActor final class DeviceSurfaceIntegrationTests: XCTestCase {
    func testCompiledSurfaceConfigurationResolvesSeparateSimulatorContainers() throws {
        let inbox = try IOSSurfaceContainers.directory(groupKey: SurfaceInfo.inboxGroupKey)
        let widget = try IOSSurfaceContainers.directory(groupKey: SurfaceInfo.widgetGroupKey)
        XCTAssertNotEqual(inbox.standardizedFileURL, widget.standardizedFileURL)
        let urls = try IOSSurfaceContainers.urls()
        XCTAssertNil(try urls.parse(urls.url(handle: nil)))
        XCTAssertEqual(urls.url(handle: nil).scheme, "roominthecart-debug")
    }

    func testSelectedTextPersistsInActualAppGroupWithoutMutatingWidgetContainer() async throws {
        let inboxDirectory = try IOSSurfaceContainers.directory(groupKey: SurfaceInfo.inboxGroupKey)
        let widgetDirectory = try IOSSurfaceContainers.directory(groupKey: SurfaceInfo.widgetGroupKey)
        let name = "NativeTest-" + UUID().uuidString
        let testDirectory = inboxDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let url = testDirectory.appendingPathComponent("inbox.sqlite")
        let inbox = try SelectedTextInbox(url: url)
        let operation = UUID(), now = Date()
        let first = try await inbox.stage(operationID: operation, originalText: "12 tortillas\n2 kg rice", now: now)
        let replay = try await inbox.stage(operationID: operation, originalText: "12 tortillas\n2 kg rice", now: now)
        XCTAssertEqual(first, replay)
        let reopened = try SelectedTextInbox(url: url)
        let entries = try await reopened.pending(now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.originalText, "12 tortillas\n2 kg rice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: widgetDirectory.appendingPathComponent(name).path))
    }
}
