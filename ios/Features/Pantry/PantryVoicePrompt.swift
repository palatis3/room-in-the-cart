import SwiftUI
import UIKit

struct PantryVoicePromptScope: Equatable {
    let adult: CapturePrivateIdentity
    let origin: UUID
    let ledger: UUID
    let generation: UUID
}

typealias PantryVoicePromptWindow = SystemPermissionWindow<PantryVoicePromptScope>

/// Retains only the mounted review during a system permission interruption.
@MainActor final class SystemPermissionWindow<Scope: Equatable>: ObservableObject {
    @Published private(set) var token: UUID?
    private var scope: Scope?
    private var phase: ScenePhase = .active
    private var finished = false
    private var sawInactive = false
    private var permissionReturn: CheckedContinuation<Void, Never>?
    private var completedRequest: UUID?

    func begin(_ scope: Scope, phase: ScenePhase) -> UUID? {
        guard phase == .active else { return nil }
        // A completed permission request can hand off to the next explicit prompt
        // when iOS did not interrupt the scene for its earlier request.
        if let completedRequest, token == completedRequest, self.phase == .active { clear() }
        guard token == nil else { return nil }
        self.phase = phase
        self.scope = scope
        finished = false
        let id = UUID()
        token = id
        return id
    }

    func holdsPresentation(_ current: Scope?) -> Bool {
        return token != nil && self.phase != .background && scope == current
    }

    func retains(_ current: Scope?, phase: ScenePhase) -> Bool {
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

    /// Release the answer only on return to the same live workspace.
    /// A real background transition cancels the token even if the adult later unlocks.
    func request(in expected: Scope, phase: ScenePhase,
                             currentScope: () -> Scope?, appActive: () -> Bool,
                             request: PantryNotificationRequest) async throws -> Bool {
        guard currentScope() == expected, appActive(), let id = begin(expected, phase: phase) else {
            throw PantryDigestFailure.changed
        }
        let result: Result<Bool, Error>
        do { result = .success(try await request()) }
        catch { result = .failure(error) }
        if token == id, self.phase != .active || !appActive() {
            await withCheckedContinuation { permissionReturn = $0 }
        }
        guard token == id, self.phase == .active, appActive(), currentScope() == expected else {
            cancel(id)
            throw PantryDigestFailure.changed
        }
        // On iOS the answer may be delivered before SwiftUI receives the inactive
        // transition. Cover that transition just as we do for the voice prompt.
        completedRequest = id
        recognitionReady(id, appActive: true)
        return try result.get()
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
        if next == .active { resumePermissionReturn() }
    }

    private func clear() {
        guard token != nil else { return }
        scope = nil
        completedRequest = nil
        finished = false
        sawInactive = false
        token = nil
        resumePermissionReturn()
    }

    private func resumePermissionReturn() {
        let waiter = permissionReturn
        permissionReturn = nil
        waiter?.resume()
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
