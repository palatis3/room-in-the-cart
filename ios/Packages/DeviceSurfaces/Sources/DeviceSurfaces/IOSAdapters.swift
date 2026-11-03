import Foundation

public enum SurfaceInfo {
    public static let inboxGroupKey = "RITCShareInboxAppGroup"
    public static let widgetGroupKey = "RITCWidgetAppGroup"
    public static let schemeKey = "RITCSurfaceURLScheme"
}
public enum SurfaceCopy {
    public static func text(_ key: String, bundle: Bundle = .main) -> String { bundle.localizedString(forKey: key, value: key, table: "DeviceSurfaces") }
    public static func reminderBody(_ language: SurfaceLanguage) -> String {
        language == .spanish ? "Abre la app para revisar tu recordatorio." : "Open the app to review your reminder."
    }
}

#if os(iOS)
import UserNotifications
public enum IOSSurfaceContainers {
    public static func directory(groupKey: String, bundle: Bundle = .main) throws -> URL {
        guard [SurfaceInfo.inboxGroupKey, SurfaceInfo.widgetGroupKey].contains(groupKey),
              let identifier = bundle.object(forInfoDictionaryKey: groupKey) as? String,
              identifier.hasPrefix("group."), identifier.count > 6, identifier.count <= 150,
              identifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }),
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { throw SurfaceError.unconfigured }
        return group.appendingPathComponent("DeviceSurfaces", isDirectory: true)
    }
    public static func inbox(bundle: Bundle = .main) throws -> SelectedTextInbox {
        try SelectedTextInbox(url: directory(groupKey: SurfaceInfo.inboxGroupKey, bundle: bundle).appendingPathComponent("selected-text.sqlite"))
    }
    public static func urls(bundle: Bundle = .main) throws -> SurfaceURLCodec { try SurfaceURLCodec(scheme: bundle.object(forInfoDictionaryKey: SurfaceInfo.schemeKey) as? String) }
}

public struct IOSNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    public init(center: UNUserNotificationCenter = .current()) { self.center = center }
    public func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined, .provisional: return .unknown
        default: return .denied
        }
    }
    public func requestPermission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    public func add(_ notification: ReminderNotification) async throws {
        guard validDate(notification.fireAt), notification.fireAt > Date(), let selectedZone = TimeZone(identifier: notification.timeZoneID),
              let offsetZone = TimeZone(secondsFromGMT: selectedZone.secondsFromGMT(for: notification.fireAt)) else { throw SurfaceError.expired }
        // Fixed confirmed offset represents the reviewed instant even in the second half of a DST fold.
        // The private intent retains the original IANA zone and reviewed civil time.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = offsetZone
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notification.fireAt)
        components.calendar = calendar; components.timeZone = offsetZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        guard let next = trigger.nextTriggerDate(), abs(next.timeIntervalSince(notification.fireAt)) < 1 else { throw SurfaceError.invalidCivilTime }
        let content = UNMutableNotificationContent()
        content.title = "Room in the Cart"; content.body = SurfaceCopy.reminderBody(notification.language); content.sound = .default
        content.userInfo = ["surfaceHandle": notification.routeHandle.rawValue]
        try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
    }
    public func remove(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
#endif

public struct WidgetProjectionFile: Sendable {
    public let url: URL
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw SurfaceError.unconfigured }
        url = directory.appendingPathComponent("widget-projection-v1.json")
    }
    public func read() throws -> WidgetProjection {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 4096 else { throw SurfaceError.corrupt }
        return try WidgetProjection.decode(Data(contentsOf: url))
    }
    /// Root calls only after the underlying private transaction commits.
    public func publishAfterCommit(_ projection: WidgetProjection) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try canonical(projection); _ = try WidgetProjection.decode(data)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
    public func clear(now: Date) throws { try publishAfterCommit(WidgetProjection(writtenAt: now, routeHandle: nil, destination: .capture)) }
}
