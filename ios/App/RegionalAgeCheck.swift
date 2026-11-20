import DeclaredAgeRange
import SwiftUI

/// The response describes the iCloud account on this device, independently of any
/// household or guardian profile. Keep only the outcome of this foreground check.
@MainActor final class RegionalAgeCheck: ObservableObject {
    enum State: Equatable { case waiting, checking, ready, declined, unavailable }

    @Published private(set) var state: State = .waiting
    private(set) var hasOpenedWorkspace = false
    @Published var deferredURL: URL?
    private var task: Task<Void, Never>?

    func approvedURL(active: Bool) -> URL? {
        active && state == .ready ? deferredURL : nil
    }

    func reset() {
        task?.cancel()
        task = nil
        deferredURL = nil
        state = .waiting
    }

    @discardableResult
    func start(required: @escaping @MainActor () async throws -> Bool,
               request: @escaping @MainActor () async throws -> Bool) -> Task<Void, Never>? {
        guard state != .checking, state != .ready else { return nil }
        state = .checking
        let work = Task { @MainActor in
            do {
                let isRequired = try await required()
                try Task.checkCancellation()
                var outcome: State = .ready
                if isRequired {
                    let shared = try await request()
                    outcome = shared ? .ready : .declined
                }
                try Task.checkCancellation()
                if outcome == .ready { hasOpenedWorkspace = true }
                state = outcome
            } catch {
                if !Task.isCancelled { state = .unavailable }
            }
        }
        task = work
        return work
    }
}

struct GroceryURLDelivery: ViewModifier {
    let approvedURL: Binding<URL?>?
    let receive: (URL) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if let approvedURL {
            content.onChange(of: approvedURL.wrappedValue, initial: true) { _, url in
                guard let url else { return }
                approvedURL.wrappedValue = nil
                receive(url)
            }
        } else {
            content.onOpenURL(perform: receive)
        }
    }
}

@available(iOS 26.2, *)
struct RegionalAgeCheckWindow<Content: View>: View {
    @Environment(\.scenePhase) private var phase
    @StateObject private var check = RegionalAgeCheck()
    @StateObject private var shield = RegionalAgeWindowShield()
    @ViewBuilder let content: (Binding<URL?>) -> Content

    private var allowed: Bool { check.state == .ready && phase == .active }

    var body: some View {
        CheckedShoppingWorkspace(check: check, phase: phase, content: content)
            .background(RegionalAgeWindowAnchor(shield: shield))
            .onOpenURL { check.deferredURL = $0 }
            .onChange(of: shield.attached, initial: true) { _, _ in synchronize() }
            .onChange(of: check.state) { _, _ in synchronize() }
            .onChange(of: phase, initial: true) { _, phase in
                if phase == .background {
                    check.reset()
                }
                synchronize()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
                check.reset()
                synchronize()
            }
            .onDisappear {
                check.reset()
                shield.uncover()
            }
    }

    private func synchronize() {
        if allowed {
            shield.uncover()
            return
        }
        // The separate opaque window also covers a sheet presented by the workspace.
        guard let presenter = shield.cover(with: RegionalAgeStatus(check: check, retry: start),
                                           active: phase == .active) else { return }
        if phase == .active && check.state == .waiting { start(in: presenter) }
    }

    private func start() {
        guard phase == .active, let presenter = shield.presenter else { return }
        start(in: presenter)
    }

    private func start(in presenter: UIViewController) {
        check.start {
            if #available(iOS 26.4, *) {
                #if compiler(>=6.3)
                return try await AgeRangeService.shared.requiredRegulatoryFeatures.contains(.declaredAgeRangeRequired)
                #else
                // Xcode 26.3's SDK cannot determine the required features on this OS.
                throw AgeRangeService.Error.invalidRequest
                #endif
            }
            return try await AgeRangeService.shared.isEligibleForAgeFeatures
        } request: {
            // Apple defines the categories for a regulated account. These request
            // boundaries confer no household permissions or minimum age.
            switch try await AgeRangeService.shared.requestAgeRange(ageGates: 13, 16, 18, in: presenter) {
            case .sharing(let range):
                guard range.lowerBound != nil || range.upperBound != nil else {
                    throw AgeRangeService.Error.invalidRequest
                }
                return true
            case .declinedSharing: return false
            @unknown default: throw AgeRangeService.Error.invalidRequest
            }
        }
    }
}

/// Keep the same view identity after the first successful check, including while
/// the scene's shield covers a shop that has an unsaved local editor.
struct CheckedShoppingWorkspace<Content: View>: View {
    @ObservedObject var check: RegionalAgeCheck
    let phase: ScenePhase
    @ViewBuilder let content: (Binding<URL?>) -> Content

    var body: some View {
        let allowed = check.state == .ready && phase == .active
        ZStack {
            if check.hasOpenedWorkspace {
                content(Binding(get: { check.approvedURL(active: phase == .active) }, set: { check.deferredURL = $0 }))
                    .environment(\.scenePhase, check.state == .ready ? phase : .background)
                    .allowsHitTesting(allowed)
                    .accessibilityHidden(!allowed)
            }
            if !allowed { Color(uiColor: .systemBackground).ignoresSafeArea() }
        }
    }
}

struct RegionalAgeStatus: View {
    @ObservedObject var check: RegionalAgeCheck
    let retry: () -> Void

    var body: some View {
        switch check.state {
        case .declined, .unavailable:
            VStack(spacing: 16) {
                Text("Apple Account age check").font(.headline)
                if check.state == .declined {
                    Text("An age range is required for this Apple Account. You can try sharing it again.")
                } else {
                    Text("The age check couldn’t finish. Check your connection and Apple Account, then try again.")
                }
                Button("Try again", action: retry).buttonStyle(.borderedProminent)
            }
            .multilineTextAlignment(.center)
            .padding()
        case .ready, .waiting, .checking:
            ProgressView("Checking age requirements…")
        }
    }
}

/// Block the scene above its presented controllers while leaving their view hierarchy intact.
@MainActor final class RegionalAgeWindowShield: ObservableObject {
    @Published private(set) var attached = false
    private weak var source: UIWindow?
    private weak var previousKey: UIWindow?
    private var coverWindow: UIWindow?
    private var priorInteraction = true
    private var priorAccessibilityHidden = false

    var presenter: UIViewController? { coverWindow?.rootViewController }

    func attach(to window: UIWindow?) {
        guard window !== source else { return }
        uncover()
        source = window
        attached = window != nil
    }

    func cover(with status: RegionalAgeStatus, active: Bool) -> UIViewController? {
        guard let source, let scene = source.windowScene else { return nil }
        if let coverWindow {
            if active && !coverWindow.isKeyWindow {
                source.endEditing(true)
                coverWindow.makeKey()
            }
            return presenter
        }
        let cover = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: status)
        controller.view.backgroundColor = .systemBackground
        controller.view.accessibilityViewIsModal = true
        cover.rootViewController = controller
        cover.backgroundColor = .systemBackground
        cover.isOpaque = true
        cover.windowLevel = .init(rawValue: UIWindow.Level.alert.rawValue + 1)
        previousKey = scene.keyWindow
        priorInteraction = source.isUserInteractionEnabled
        priorAccessibilityHidden = source.accessibilityElementsHidden
        source.isUserInteractionEnabled = false
        source.accessibilityElementsHidden = true
        coverWindow = cover
        if active {
            source.endEditing(true)
            cover.makeKeyAndVisible()
        } else {
            cover.isHidden = false
        }
        return controller
    }

    func uncover() {
        guard let coverWindow else { return }
        let restoreKey = coverWindow.isKeyWindow
        coverWindow.isHidden = true
        source?.isUserInteractionEnabled = priorInteraction
        source?.accessibilityElementsHidden = priorAccessibilityHidden
        if restoreKey {
            let target = previousKey?.isHidden == false ? previousKey : source
            target?.makeKey()
        }
        self.coverWindow = nil
        previousKey = nil
    }
}

private struct RegionalAgeWindowAnchor: UIViewRepresentable {
    let shield: RegionalAgeWindowShield
    func makeUIView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.isUserInteractionEnabled = false
        view.shield = shield
        return view
    }
    func updateUIView(_ view: WindowProbe, context: Context) {}

    final class WindowProbe: UIView {
        weak var shield: RegionalAgeWindowShield?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                shield?.attach(to: window)
            }
        }
    }
}
