import Foundation
import UIKit
import UserNotifications
import DeviceSurfaces

/// Install at launch, before SwiftUI builds the workspace. Only an opaque
/// handle can wait here for the scene that will authorize it.
@MainActor final class SurfaceNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var receiveTap: ((RouteHandle) -> Void)?
    private var pendingTap: RouteHandle?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !SurfaceRuntimeIsolation.usesUITestWorkspace(launchArguments: ProcessInfo.processInfo.arguments) {
            UNUserNotificationCenter.current().delegate = self
        }
        return true
    }

    func bind(receiveTap: @escaping (RouteHandle) -> Void) {
        self.receiveTap = receiveTap
        if let pendingTap {
            self.pendingTap = nil
            receiveTap(pendingTap)
        }
    }

    func acceptTap(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let info = userInfo as? [String: String], Set(info.keys) == ["surfaceHandle"],
              let raw = info["surfaceHandle"], let handle = try? RouteHandle(raw) else { return }
        if let receiveTap { receiveTap(handle) }
        else { pendingTap = handle }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        acceptTap(actionIdentifier: response.actionIdentifier, userInfo: response.notification.request.content.userInfo)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The visible app already carries current state; don't duplicate announcements while editing.
        []
    }
}
