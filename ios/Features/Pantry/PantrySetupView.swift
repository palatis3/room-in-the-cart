import SwiftUI

/// This entry is independent of the selected shopping list. A setup review
/// retains the coordinator and original source revisions until confirm or cancel.
struct PantrySetupView: View {
    @ObservedObject var pickup: PickupModel
    @ObservedObject var ledger: LedgerModel
    var opensPriceHistory = false
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @State private var phase: Phase = .loading
    @State private var generation = UUID()
    @State private var busy = false

    private enum Phase {
        case loading, staging, unavailable
        case review(PantryMigrationCoordinator, PantryMigrationCoordinator.Review)
        case ready(Scope, PantryModel)
    }
    private enum Action { case inspect, apply, resume, discard }
    private struct Scope: Equatable {
        let adult: CapturePrivateIdentity
        let inventory: UUID
        let ledger: UUID
        let generation: UUID
    }
    private var scope: Scope? {
        guard scene == .active, child?.presented != true, pickup.pantryRouteAvailable,
              let identity = CapturePrivateIdentity.current(access: access, household: household),
              let stockID = pickup.sourceWorkspaceID, let ledgerID = ledger.sourceWorkspaceID else { return nil }
        return Scope(adult: identity, inventory: stockID, ledger: ledgerID, generation: pickup.privatePantryGeneration)
    }

    var body: some View {
        Group {
            if scope == nil {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if case .ready(let original, let model) = phase, original == scope, model.phase != .accessDenied {
                if opensPriceHistory { PantryPriceHistoryView(model: model) }
                else { PantryHomeView(model: model, accessAllowed: true, offersTonight: true, offersStaplePrompts: true, household: household) }
            } else {
                List {
                    if !opensPriceHistory { HouseholdTonightLink(household: household) }
                    if busy { ProgressView(pantryText("Working…")) }
                    switch phase {
                    case .loading: EmptyView()
                    case .review(_, let review):
                        Section(pantryText("Set up My Pantry")) {
                            Text(pantryText("Review the food and reservations from your saved pickups. You can add food by hand after setup."))
                            LabeledContent(pantryText("Saved pickups"), value: review.sourceCount.formatted())
                            LabeledContent(pantryText("Food batches"), value: review.lotCount.formatted())
                            LabeledContent(pantryText("Reservations"), value: review.reservationCount.formatted())
                            ForEach(issueRows(review), id: \.label) { row in
                                LabeledContent(pantryText(row.label), value: row.count.formatted())
                            }
                            Button(pantryText("Confirm pantry setup")) { Task { await perform(.apply) } }
                                .accessibilityIdentifier("pantry.setup.apply")
                        }
                    case .staging:
                        Text(pantryText("Pantry setup was interrupted. Continue the reviewed setup or discard it and review again."))
                        Button(pantryText("Continue pantry setup")) { Task { await perform(.resume) } }
                        Button(pantryText("Discard unfinished setup"), role: .destructive) { Task { await perform(.discard) } }
                    case .unavailable:
                        Text(pantryText("Pantry setup could not finish. Check any pending shopping or pickup changes, then retry."))
                        Button(pantryText("Review pantry setup again")) { Task { await perform(.inspect) } }
                    case .ready: EmptyView()
                    }
                }.disabled(busy)
            }
        }
        .privacySensitive()
        .navigationTitle(opensPriceHistory ? pantryText("Private price history") : pantryText("My Pantry"))
        .task(id: scope) {
            if case .ready(let original, let model) = phase {
                if original == scope && model.phase != .accessDenied { return }
                model.accessLost()
            }
            generation = UUID(); phase = .loading; busy = false
            if scope != nil { await perform(.inspect) }
        }
    }

    @MainActor private func perform(_ action: Action) async {
        guard !busy, let original = scope else { return }
        let token = generation
        let current = { @MainActor in generation == token && scope == original && !Task.isCancelled }
        busy = true
        defer { if token == generation { busy = false } }
        do {
            let coordinator: PantryMigrationCoordinator
            if action == .apply, case .review(let reviewed, let review) = phase {
                coordinator = reviewed
                _ = try await coordinator.apply(review)
            } else {
                coordinator = try pickup.makePantrySetupCoordinator(authorize: current)
                switch action {
                case .inspect: break
                case .resume: _ = try await coordinator.resume()
                case .discard:
                    try await coordinator.cancelPending()
                    await pickup.load()
                case .apply: return
                }
            }
            guard current() else { return }
            let state = try await coordinator.setupState()
            guard current() else { return }
            switch state {
            case .inactive:
                let review = try await coordinator.prepare()
                if current() { phase = .review(coordinator, review) }
            case .staging: phase = .staging
            case .active:
                if !pickup.pantryIsActive || !pickup.pantryReadIsCurrent {
                    guard await pickup.refreshPantryStock() else { throw PantryMigrationCoordinator.Failure.sourceChanged }
                }
                guard current(), let model = pickup.makePantryModel() else { throw PantryMigrationCoordinator.Failure.unauthorized }
                phase = .ready(original, model)
            }
        } catch { if current() { phase = .unavailable } }
    }

    private func issueRows(_ review: PantryMigrationCoordinator.Review) -> [(label: String, count: Int)] {
        let counts = Dictionary(grouping: review.issues) { issue in
            switch issue.kind {
            case .conflictingSource, .ambiguousManualCount: "Food counts to review"
            case .receiptBranch, .unconfirmedReceipt: "Receipt details to review"
            case .missingAncestor, .cyclicAncestry: "Food history to review"
            case .conflictingClaim, .missingPinnedSource, .pendingCarryover: "Reservations to review"
            case .ledgerNeedsReview: "Shopping lists to review"
            }
        }
        return counts.keys.sorted().map { ($0, counts[$0]?.count ?? 0) }
    }
}

/// The previous pickup and pantry workspace remains retired after a fresh start.
struct PantryRestartButton: View {
    @ObservedObject var pickup: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @State private var confirming = false
    @State private var busy = false
    @State private var failed = false

    private var identity: CapturePrivateIdentity? {
        guard scene == .active, child?.presented != true else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    var body: some View {
        if let adult = identity, let origin = pickup.sourceWorkspaceID {
            Button(pantryText("Start a new private pantry")) { confirming = true }
                .disabled(busy)
                .accessibilityIdentifier("shop.restartPantry")
                .confirmationDialog(pantryText("Start a new private pantry?"), isPresented: $confirming, titleVisibility: .visible) {
                    Button(pantryText("Start empty workspace")) {
                        Task {
                            guard !busy, identity == adult, pickup.sourceWorkspaceID == origin else { return }
                            busy = true
                            defer { busy = false }
                            do {
                                try await pickup.restartRetiredPantry { identity == adult && !Task.isCancelled }
                            } catch { failed = identity == adult }
                        }
                    }
                } message: {
                    Text(pantryText("This creates an empty workspace for pantry food and pickup history. Your shopping lists stay available."))
                }
                .alert(pantryText("Couldn’t open the new pantry. Try again."), isPresented: $failed) {
                    Button(pantryText("Done")) {}
                }
                .onChange(of: identity) { confirming = false; failed = false }
        }
    }
}
