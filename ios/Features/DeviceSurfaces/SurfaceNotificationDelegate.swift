import Foundation
import UserNotifications
import DeviceSurfaces

/// Retain in the app composition root (UNUserNotificationCenter.delegate is weak).
/// The callback supplies a locator only and must go through current persona/target authorization.
public final class SurfaceNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let openAuthorizedRoute: @MainActor @Sendable (RouteHandle) -> Void
    public init(openAuthorizedRoute: @escaping @MainActor @Sendable (RouteHandle) -> Void) { self.openAuthorizedRoute = openAuthorizedRoute; super.init() }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let info = response.notification.request.content.userInfo as? [String: String], Set(info.keys) == ["surfaceHandle"],
              let raw = info["surfaceHandle"], let handle = try? RouteHandle(raw) else { return }
        await openAuthorizedRoute(handle)
    }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The visible app already carries current state; don't duplicate announcements while editing.
        []
    }
}
