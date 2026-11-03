import Foundation
import DeviceSurfaces

/// DEBUG UI tests have separate storage and no access to live OS surface adapters.
/// An injected directory always wins; launch flags never authorize resetting it.
struct SurfaceRuntimeIsolation {
    let directory: URL
    let isUITesting: Bool
    let shouldReset: Bool
    private let ownedTestDirectory: URL

    init(directory: URL?, launchArguments: [String], applicationSupport: URL) {
        ownedTestDirectory = applicationSupport.appendingPathComponent("UITestWorkspace", isDirectory: true)
            .appendingPathComponent("DeviceSurfacesPrivate", isDirectory: true)
        #if DEBUG
        isUITesting = launchArguments.contains("--ui-testing")
        #else
        isUITesting = false
        #endif
        self.directory = directory ?? (isUITesting ? ownedTestDirectory : applicationSupport.appendingPathComponent("RoomInTheCart/DeviceSurfacesPrivate", isDirectory: true))
        shouldReset = directory == nil && isUITesting && launchArguments.contains("--reset-test-workspace")
    }
    func resetOwnedTestDirectory() throws {
        guard isUITesting, directory.standardizedFileURL == ownedTestDirectory.standardizedFileURL else { return }
        // Refuse a redirected test root rather than recursively deleting through it.
        for candidate in [ownedTestDirectory.deletingLastPathComponent(), ownedTestDirectory] where FileManager.default.fileExists(atPath: candidate.path) {
            guard try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SurfaceError.unavailable }
        }
        guard shouldReset else { return }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func makeInbox(live: () throws -> SelectedTextInbox) throws -> SelectedTextInbox {
        if isUITesting { return try SelectedTextInbox(url: directory.appendingPathComponent("TestInbox/selected-text.sqlite")) }
        return try live()
    }
    func makeWidget(live: () throws -> WidgetProjectionFile) throws -> WidgetProjectionFile {
        if isUITesting { return try WidgetProjectionFile(directory: directory.appendingPathComponent("TestWidget", isDirectory: true)) }
        return try live()
    }
    func makeScheduler(live: () -> any NotificationScheduling) -> any NotificationScheduling {
        isUITesting ? IsolatedSurfaceNotificationScheduler() : live()
    }
    func performSystemEffect(_ action: () -> Void) { if !isUITesting { action() } }
}

/// Explicitly unscheduled in UI tests. This adapter never calls UserNotifications,
/// requests permission, registers, or removes a real notification.
struct IsolatedSurfaceNotificationScheduler: NotificationScheduling {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func add(_ notification: ReminderNotification) async throws { throw SurfaceError.unavailable }
    func remove(_ identifiers: [String]) async {}
}
