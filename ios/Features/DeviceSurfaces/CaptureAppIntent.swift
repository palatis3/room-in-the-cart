import AppIntents
import SwiftUI
import DeviceSurfaces
import CoreDomain

/// Lives only in the foreground app. Food text never enters the widget group or an intent result.
struct ShoppingIntentRequest {
    enum Action { case openList, addItem(String) }
    let action: Action
    let issuedAt: Date
    let binding: ShoppingIntentBinding?
    var expiresAt: Date { issuedAt.addingTimeInterval(10 * 60) }
}

struct ShoppingIntentBinding: Equatable {
    let identity: CapturePrivateIdentity
    let workspace: UUID?
    let shop: UUID?
}

@MainActor public final class SurfaceCaptureRequests: ObservableObject {
    public static let shared = SurfaceCaptureRequests()
    enum Request { case capture, shopping(ShoppingIntentRequest), unavailable }
    @Published public private(set) var pending = false
    private var request: Request?
    var binding: (() -> ShoppingIntentBinding?)?
    var now: () -> Date = Date.init

    public func requestCapture() { request = .capture; pending = true }
    func requestShopping(_ action: ShoppingIntentRequest.Action) {
        let origin = binding?()
        if binding != nil && origin == nil {
            request = .unavailable
        } else if case .addItem(let text) = action, text.utf8.count > StagedListImport.maximumTextBytes {
            request = .unavailable
        } else {
            request = .shopping(.init(action: action, issuedAt: now(), binding: origin))
        }
        pending = true
    }
    @discardableResult func takeRequest() -> Request? {
        defer { request = nil; pending = false }
        return request
    }
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
struct OpenShoppingListIntent: AppIntent {
    static var title = LocalizedStringResource("Open shopping list", table: "DeviceSurfaces")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun: Bool = true
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }
    @MainActor func perform() async throws -> some IntentResult {
        SurfaceCaptureRequests.shared.requestShopping(.openList)
        return .result()
    }
}

struct AddGroceryItemIntent: AppIntent {
    static var title = LocalizedStringResource("Add grocery item", table: "DeviceSurfaces")
    static var description = IntentDescription(LocalizedStringResource("Open an editable draft and confirm before adding anything.", table: "DeviceSurfaces"))
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun: Bool = true
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }
    @Parameter(title: LocalizedStringResource("Item wording", table: "DeviceSurfaces")) var wording: String?
    @MainActor func perform() async throws -> some IntentResult {
        SurfaceCaptureRequests.shared.requestShopping(.addItem(wording ?? ""))
        return .result()
    }
}
struct GroceryCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenShoppingListIntent(), phrases: ["Open my shopping list in \(.applicationName)"], shortTitle: LocalizedStringResource("Open shopping list", table: "DeviceSurfaces"), systemImageName: "list.bullet")
        AppShortcut(intent: AddGroceryItemIntent(), phrases: ["Add a grocery item in \(.applicationName)"], shortTitle: LocalizedStringResource("Add grocery item", table: "DeviceSurfaces"), systemImageName: "cart.badge.plus")
        AppShortcut(intent: OpenShoppingCaptureIntent(), phrases: ["Open grocery entry in \(.applicationName)"], shortTitle: LocalizedStringResource("Grocery entry", table: "DeviceSurfaces"), systemImageName: "cart")
    }
}
