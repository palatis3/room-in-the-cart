import SwiftUI
import UIKit

struct PantryVoicePromptScope: Equatable {
    let adult: CapturePrivateIdentity
    let origin: UUID
    let ledger: UUID
    let generation: UUID
}

/// Retains only the mounted review during a system permission interruption.
@MainActor final class PantryVoicePromptWindow: ObservableObject {
    @Published private(set) var token: UUID?
    private var scope: PantryVoicePromptScope?
    private var phase: ScenePhase = .active
    private var finished = false
    private var sawInactive = false

    func begin(_ scope: PantryVoicePromptScope, phase: ScenePhase) -> UUID? {
        guard phase == .active, token == nil else { return nil }
        self.phase = phase
        self.scope = scope
        finished = false
        let id = UUID()
        token = id
        return id
    }

    func holdsPresentation(_ current: PantryVoicePromptScope?) -> Bool {
        return token != nil && self.phase != .background && scope == current
    }

    func retains(_ current: PantryVoicePromptScope?, phase: ScenePhase) -> Bool {
        phase == .inactive && holdsPresentation(current)
    }

    func allowsPantryAction(appActive: Bool) -> Bool {
        token == nil || (phase == .active && appActive)
    }

    func recognitionReady(_ id: UUID, appActive: Bool) {
        guard token == id else { return }
        finished = true
        // The permission response can arrive before the scene's inactive/active pair.
        if sawInactive && phase == .active && appActive { clear() }
    }

    func nextPermission(_ id: UUID) {
        guard token == id else { return }
        sawInactive = phase == .inactive
        finished = false
    }

    func cancel(_ id: UUID) { if token == id { clear() } }

    func sceneChanged(_ next: ScenePhase) {
        phase = next
        if next == .inactive && token != nil { sawInactive = true }
        if next == .background || (next == .active && finished && sawInactive) { clear() }
    }

    private func clear() {
        guard token != nil else { return }
        scope = nil
        finished = false
        sawInactive = false
        token = nil
    }
}

struct PantryVoicePromptAccess {
    let holdsPresentation: @MainActor () -> Bool
    let begin: @MainActor () -> UUID?
    let nextPermission: @MainActor (UUID) -> Void
    let ready: @MainActor (UUID) -> Void
    let cancel: @MainActor (UUID) -> Void
}

private struct PantryVoicePromptKey: EnvironmentKey {
    static let defaultValue: PantryVoicePromptAccess? = nil
}

extension EnvironmentValues {
    var pantryVoicePrompt: PantryVoicePromptAccess? {
        get { self[PantryVoicePromptKey.self] }
        set { self[PantryVoicePromptKey.self] = newValue }
    }
}

/// A pantry can be presented in a sheet above the root view. Cover the app window
/// without becoming key or replacing the system permission alert in SpringBoard.
struct PantryVoicePrivacyCover: UIViewRepresentable {
    final class Anchor: UIView {
        private(set) var cover: UIWindow?
        private weak var coveredWindow: UIWindow?
        private var wasAccessibilityHidden = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let scene = window.windowScene else { removeCover(); return }
            guard coveredWindow !== window else { return }
            removeCover()
            coveredWindow = window
            wasAccessibilityHidden = window.accessibilityElementsHidden
            let cover = UIWindow(windowScene: scene)
            let controller = UIViewController()
            controller.view.backgroundColor = UIColor(named: "canvas") ?? .systemBackground
            cover.rootViewController = controller
            cover.windowLevel = .alert + 1
            window.accessibilityElementsHidden = true
            self.cover = cover
            cover.isHidden = false
        }

        func removeCover() {
            cover?.isHidden = true
            cover = nil
            coveredWindow?.accessibilityElementsHidden = wasAccessibilityHidden
            coveredWindow = nil
        }
    }

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ uiView: Anchor, context: Context) {}
    static func dismantleUIView(_ uiView: Anchor, coordinator: ()) { uiView.removeCover() }
}
