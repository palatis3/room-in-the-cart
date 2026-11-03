import AppIntents
import SwiftUI
import DeviceSurfaces

/// App-target only. The root observes this request and resolves it through its persona/unlock router.
@MainActor public final class SurfaceCaptureRequests: ObservableObject {
    public static let shared = SurfaceCaptureRequests()
    @Published public private(set) var pending = false
    private init() {}
    public func requestCapture() { pending = true }
    public func consumeAfterRouting() { pending = false }
}

struct OpenShoppingCaptureIntent: AppIntent {
    static var title = LocalizedStringResource("Open grocery entry", table: "DeviceSurfaces")
    static var description = IntentDescription(LocalizedStringResource("Open Room in the Cart to review a grocery entry. This shortcut does not add or send anything.", table: "DeviceSurfaces"))
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    // Backward-compatible app-only foreground entry for the iOS 17 deployment floor.
    static var openAppWhenRun: Bool = true
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }
    @MainActor func perform() async throws -> some IntentResult {
        SurfaceCaptureRequests.shared.requestCapture()
        return .result()
    }
}
struct GroceryCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenShoppingCaptureIntent(), phrases: ["Open grocery entry in \(.applicationName)"], shortTitle: LocalizedStringResource("Grocery entry", table: "DeviceSurfaces"), systemImageName: "cart")
    }
}
