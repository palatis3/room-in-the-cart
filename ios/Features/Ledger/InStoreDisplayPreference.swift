import SwiftUI
import UIKit

/// The idle timer is process-wide, even when a shopper opens more than one window.
@MainActor
final class ShoppingDisplayTimer: ObservableObject {
    static let shared = ShoppingDisplayTimer(
        current: { UIApplication.shared.isIdleTimerDisabled },
        apply: { UIApplication.shared.isIdleTimerDisabled = $0 }
    )

    @Published private(set) var active: Set<UUID> = []
    private let current: () -> Bool
    private let apply: (Bool) -> Void
    private let duration: Duration
    private(set) var deadlines: [UUID: Date] = [:]
    private var previousSetting = false
    private var expirations: [UUID: Task<Void, Never>] = [:]

    init(duration: Duration = .seconds(15 * 60), current: @escaping () -> Bool, apply: @escaping (Bool) -> Void) {
        self.duration = duration
        self.current = current
        self.apply = apply
    }

    func begin(_ owner: UUID) {
        guard !active.contains(owner) else { return }
        if active.isEmpty {
            previousSetting = current()
            apply(true)
        }
        deadlines[owner] = Date.now.addingTimeInterval(TimeInterval(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        active.insert(owner)
        expirations[owner] = Task { [weak self, duration] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.end(owner)
        }
    }

    func end(_ owner: UUID) {
        guard active.remove(owner) != nil else { return }
        deadlines.removeValue(forKey: owner)
        expirations.removeValue(forKey: owner)?.cancel()
        if active.isEmpty { apply(previousSetting) }
    }
}

struct InStoreDisplayToggle: View {
    let owner: UUID
    @Environment(\.shoppingListAuthorization) private var authorize

    var body: some View {
        ScreenAwakeToggle(owner: owner, identifier: "inStoreKeepAwake", authorize: authorize)
    }
}

struct ScreenAwakeToggle: View {
    let owner: UUID
    let identifier: String
    let authorize: () -> Bool
    var deadlineLabel: ((Date) -> String)? = nil
    @Environment(\.scenePhase) private var scene
    @ObservedObject private var timer = ShoppingDisplayTimer.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { timer.active.contains(owner) },
            set: { enabled in
                if enabled && scene == .active && authorize() {
                    timer.begin(owner)
                } else {
                    timer.end(owner)
                }
            }
        )) {
            VStack(alignment: .leading) {
                Label(shoppingText("Keep screen awake for 15 minutes"), systemImage: "sun.max")
                if let deadlineLabel, let deadline = timer.deadlines[owner] {
                    Text(deadlineLabel(deadline))
                        .font(.footnote)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

struct InStoreDisplayPreference<Scope: Equatable>: ViewModifier {
    let trip: Scope
    let owner: UUID
    let available: Bool
    @Environment(\.scenePhase) private var scene
    private let timer = ShoppingDisplayTimer.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: scene) { _, newPhase in
                if newPhase != .active { timer.end(owner) }
            }
            .onChange(of: available) { _, available in
                if !available { timer.end(owner) }
            }
            .onChange(of: trip) { _, _ in timer.end(owner) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                timer.end(owner)
            }
            .onDisappear { timer.end(owner) }
    }
}
