import DeclaredAgeRange
import SwiftUI

/// The response describes the iCloud account on this device, independently of any
/// household or guardian profile. Keep only the outcome of this foreground check.
@MainActor final class RegionalAgeCheck: ObservableObject {
    enum State: Equatable { case waiting, checking, ready, declined, unavailable }

    @Published private(set) var state: State = .waiting
    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
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
                state = outcome
            } catch {
                if !Task.isCancelled { state = .unavailable }
            }
        }
        task = work
        return work
    }
}

@available(iOS 26.2, *)
struct RegionalAgeCheckWindow<Content: View>: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestAgeRange) private var requestAgeRange
    @StateObject private var check = RegionalAgeCheck()
    @State private var deferredURL: URL?
    let onDeferredURL: (URL) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            if check.state == .ready {
                content()
            } else {
                status.onOpenURL { deferredURL = $0 }
            }
        }
        .onChange(of: check.state) { _, state in
            if state == .ready, let url = deferredURL {
                deferredURL = nil
                onDeferredURL(url)
            }
        }
        .onChange(of: phase, initial: true) { _, phase in
            switch phase {
            case .background:
                deferredURL = nil
                check.reset()
            case .active:
                if check.state == .waiting { start() }
            default: break // Apple's own presentation can temporarily make the scene inactive.
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
            deferredURL = nil
            check.reset()
            if phase == .active { start() }
        }
        .onDisappear { check.reset() }
    }

    @ViewBuilder private var status: some View {
        switch check.state {
        case .waiting, .checking:
            ProgressView("Checking age requirements…")
        case .declined, .unavailable:
            VStack(spacing: 16) {
                Text("Apple Account age check").font(.headline)
                if check.state == .declined {
                    Text("An age range is required for this Apple Account. You can try sharing it again.")
                } else {
                    Text("The age check couldn’t finish. Check your connection and Apple Account, then try again.")
                }
                Button("Try again") { start() }.buttonStyle(.borderedProminent)
            }
            .multilineTextAlignment(.center)
            .padding()
        case .ready: EmptyView()
        }
    }

    private func start() {
        check.start {
            if #available(iOS 26.4, *) {
                return try await AgeRangeService.shared.requiredRegulatoryFeatures.contains(.declaredAgeRangeRequired)
            }
            return try await AgeRangeService.shared.isEligibleForAgeFeatures
        } request: {
            // Apple defines the categories for a regulated account. These US
            // request boundaries confer no household permissions or minimum age.
            switch try await requestAgeRange(ageGates: 13, 16, 18) {
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
