import SwiftUI

/// This entry is independent of the selected shopping list. A setup review
/// retains the coordinator and original source revisions until confirm or cancel.
struct PantrySetupView: View {
    @ObservedObject var pickup: PickupModel
    @ObservedObject var ledger: LedgerModel
    enum Destination { case home, prices, receipts }
    var destination: Destination = .home
    var returnToCurrentShelf: (() -> Void)? = nil
    private var title: String {
        switch destination {
        case .home: pantryText("My Pantry")
        case .prices: pantryText("Private price history")
        case .receipts: pantryText("Receipt history")
        }
    }
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.pantryVoicePrompt) private var pantryVoicePrompt
    @Environment(\.guardianChildCoordinator) private var child
    @State private var phase: Phase = .loading
    @State private var generation = UUID()
    @State private var busy = false
    @State private var initialSheet: PantrySheet?
    @State private var shelfLot: ShelfLot?

    /// Retain the selected model and its original authorization basis until the user goes back.
    /// A newly authorized shelf must not rebind an open usage editor.
    private struct ShelfLot: Hashable {
        let id: UUID
        let model: PantryModel
        let scope: Scope

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.model === rhs.model && lhs.scope == rhs.scope }
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(ObjectIdentifier(model))
            hasher.combine(scope.generation)
        }
    }
    @State private var startPriceEntry = false

    private func setupExplanation(startsEmpty: Bool) -> String {
        guard startsEmpty else { return "Review the food and reservations from your saved pickups. You can add food by hand after setup." }
        if destination == .prices { return "Save a shelf price, checkout quote or amount you paid on this iPhone." }
        return "Add your first food by hand or review a receipt."
    }

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
        let retainingPrompt = scene != .background && pantryVoicePrompt?.holdsPresentation() == true
        guard UIApplication.shared.isProtectedDataAvailable, child?.presented != true,
              pickup.pantryRouteAvailable || retainingPrompt,
              let identity = CapturePrivateIdentity.current(access: access, household: household),
              let stockID = pickup.sourceWorkspaceID, let ledgerID = ledger.sourceWorkspaceID else { return nil }
        let current = Scope(adult: identity, inventory: stockID, ledger: ledgerID, generation: pickup.privatePantryGeneration)
        if scene == .active && pickup.pantryRouteAvailable { return current }
        if retainingPrompt, case .ready(let original, _) = phase, original == current { return current }
        return nil
    }

    var body: some View {
        Group {
            if scope == nil {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if case .ready(let original, let model) = phase, original == scope, model.phase != .accessDenied {
                switch destination {
                case .prices: PantryPriceHistoryView(model: model, startEntry: $startPriceEntry)
                case .receipts: PantryReceiptHistory(model: model, showsDone: false)
                case .home:
                    LivePantryHomeView(pickup: pickup, model: model, household: household, holdsLoadedReview: {
                        pantryVoicePrompt?.holdsPresentation() == true && scope == original
                    }, initialSheet: $initialSheet, openShelfLot: { [selection = $shelfLot] id in
                        selection.wrappedValue = ShelfLot(id: id, model: model, scope: original)
                    })
                }
            } else {
                JournalList {
                    if busy { ProgressView(pantryText("Working…")) }
                    switch phase {
                    case .loading: EmptyView()
                    case .review(_, let review):
                        let startsEmpty = review.sourceCount == 0 && review.lotCount == 0 && review.reservationCount == 0 && review.issues.isEmpty
                        Section {
                            if destination == .home {
                                PantryJournalHeading(title: pantryText(startsEmpty ? "Food at home" : "Set up My Pantry"))
                            }
                            if startsEmpty && destination == .home {
                                Button(pantryText("Add my first food")) {
                                    Task { await perform(.apply, opening: .add) }
                                }
                                .buttonStyle(PrimaryAction()).accessibilityIdentifier("pantry.setup.firstFood")
                                firstVisitAction("Review a receipt", systemImage: pantryReceiptSymbol, opening: .receipt)
                                    .accessibilityIdentifier("pantry.setup.receipt")
                                firstVisitAction("Scan products", systemImage: "barcode.viewfinder", opening: .products)
                                    .accessibilityIdentifier("pantry.setup.products")
                                firstVisitAction("Other pantry options", systemImage: "square.grid.2x2")
                                    .accessibilityIdentifier("pantry.setup.apply")
                            } else if startsEmpty && destination == .prices {
                                Button(pantryText("Record a price")) {
                                    startPriceEntry = true
                                    Task { await perform(.apply) }
                                }.buttonStyle(PrimaryAction()).accessibilityIdentifier("pantry.setup.firstPrice")
                            } else if startsEmpty { applySetup(startsEmpty: true) }
                            VStack(alignment: .leading, spacing: 12) {
                                if !startsEmpty && destination != .home { Text(pantryText("Set up My Pantry")).font(.title2.bold()) }
                                Text(pantryText(setupExplanation(startsEmpty: startsEmpty)))
                                    .foregroundStyle(Theme.secondary)
                                BrandScopeLabel(pantryText("Private · On this iPhone"), systemImage: "lock")
                            }
                            .padding(.vertical, 8)
                            if !startsEmpty {
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .top, spacing: 20) { setupFigures(review) }.fixedSize(horizontal: true, vertical: false)
                                    VStack(alignment: .leading, spacing: 12) { setupFigures(review) }
                                }
                            }
                            ForEach(issueRows(review), id: \.label) { row in
                                LabeledContent(pantryText(row.label), value: row.count.formatted())
                            }
                            if !startsEmpty { applySetup(startsEmpty: false) }
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
                    if destination == .home { HouseholdTonightLink(household: household) }
                }.disabled(busy)
            }
        }
        .navigationDestination(item: $shelfLot) { lot in
            PantryLotEntryView(model: lot.model, lotID: lot.id, accessAllowed: scope == lot.scope,
                               offersTonight: true, household: household,
                               returnToShelf: returnToCurrentShelf ?? { [selection = $shelfLot] in selection.wrappedValue = nil })
        }
        .privacySensitive()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(destination == .home ? .inline : .automatic)
        .task(id: scope) {
            if case .ready(let original, let model) = phase {
                if original == scope && model.phase != .accessDenied { return }
                model.accessLost()
            }
            generation = UUID(); phase = .loading; busy = false; initialSheet = nil; startPriceEntry = false
            if scope != nil { await perform(.inspect) }
        }
    }

    private func firstVisitAction(_ key: String, systemImage: String, opening sheet: PantrySheet? = nil) -> some View {
        Button {
            Task { await perform(.apply, opening: sheet) }
        } label: {
            JournalActionLabel(pantryText(key), systemImage: systemImage)
        }
    }

    private func applySetup(startsEmpty: Bool) -> some View {
        Button(pantryText(startsEmpty ? "Start my pantry" : "Confirm pantry setup")) { Task { await perform(.apply) } }
            .buttonStyle(PrimaryAction())
            .accessibilityIdentifier("pantry.setup.apply")
    }

    @ViewBuilder private func setupFigures(_ review: PantryMigrationCoordinator.Review) -> some View {
        setupFigure("Saved pickups", count: review.sourceCount)
        setupFigure("Food batches", count: review.lotCount)
        setupFigure("Reservations", count: review.reservationCount)
    }

    private func setupFigure(_ label: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
            Text(pantryText(label)).font(.subheadline).foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pantryText(label))
        .accessibilityValue(count.formatted())
    }

    @MainActor private func perform(_ action: Action, opening sheet: PantrySheet? = nil) async {
        guard !busy, let original = scope else { return }
        if action == .apply { initialSheet = sheet }
        if action == .discard { initialSheet = nil }
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

/// Tabs can keep the shelf mounted while cooking changes the same inventory.
struct LivePantryHomeView: View {
    @ObservedObject var pickup: PickupModel
    @ObservedObject var model: PantryModel
    let household: HouseholdModel
    let holdsLoadedReview: () -> Bool
    @Binding var initialSheet: PantrySheet?
    var openShelfLot: ((UUID) -> Void)? = nil

    private var newerRevision: Int64? {
        guard model.canEdit, !pickup.saving, pickup.pantryRouteAvailable, pickup.pantryReadIsCurrent,
              let current = pickup.pantrySnapshot?.state, let shown = model.snapshot?.state,
              current.workspaceID == shown.workspaceID, current.revision > shown.revision else { return nil }
        return current.revision
    }

    var body: some View {
        PantryHomeView(model: model, accessAllowed: true, offersTonight: true, offersStaplePrompts: true,
                       allowsPackageReview: true, household: household, holdsLoadedReview: holdsLoadedReview,
                       initialSheet: $initialSheet, openShelfLot: openShelfLot)
            .onChange(of: newerRevision, initial: true) { _, revision in
                guard let revision else { return }
                Task { @MainActor in
                    // A newly opened review keeps its exact basis. Once it closes,
                    // newerRevision changes again and the shelf can take a fresh read.
                    if newerRevision == revision { await model.load() }
                }
            }
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
