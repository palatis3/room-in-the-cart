import CoreDomain
import LocalStore
import SwiftUI

/// Editable choices for one phrase. Ambiguous names, package units and remaining estimates
/// stay unresolved until the user supplies them. No transcript is part of a save command.
struct VoicePantryRow {
    enum Mode { case amount, remaining, all, usedSome, skip }
    let food: String
    let original: String
    var lotID: UUID?
    var reportsUse = true
    var mode: Mode
    var amount = ""
    var unit: UnitOfMeasure?
    var spokenDimension: UnitDimension?
    var estimate = ""
    var isLowEstimate = false
    var estimateLotID: UUID?

    mutating func applyRemaining(_ answer: PantryVoiceObservation) {
        estimate = answer.remainingWording
        estimateLotID = lotID
        mode = answer.remaining == .empty ? .all : .remaining
        switch answer.remaining {
        case .low, .nearlyEmpty: isLowEstimate = true
        case .lessThanFraction(let limit, _): isLowEstimate = limit.numerator <= limit.denominator / 2
        default: isLowEstimate = false
        }
    }
    var showsAllLots = false

    static func consumption(_ item: PantryVoiceItem) -> Self {
        var row = VoicePantryRow(food: item.food, original: item.original, mode: .remaining)
        switch item.amount {
        case .measured(let q): row.mode = .amount; row.amount = q.amount.description; row.unit = q.unit
        case .pieces(let n, _): row.mode = .amount; row.amount = n.description; row.spokenDimension = .count
        case .all: row.mode = .all
        case .someUsed: row.mode = .usedSome
        case .someUsedWithRemaining(let observation): row.applyRemaining(observation)
        case .unknown: break
        }
        return row
    }

    mutating func restoreSelection(from previous: [VoicePantryRow], in lots: [InventoryLot]) -> Bool {
        guard let prior = previous.first(where: { $0.food == food }),
              let id = prior.lotID, let current = lots.first(where: { $0.id == id }) else { return false }
        showsAllLots = prior.showsAllLots
        choose(current)
        return true
    }

    mutating func choose(_ lot: InventoryLot) {
        if let estimateLotID, estimateLotID != lot.id {
            if mode == .remaining || mode == .all { mode = .remaining }
            estimate = ""
            isLowEstimate = false
            self.estimateLotID = nil
        }
        lotID = lot.id
        // A spoken estimate initially has no batch. Bind it to the first choice
        // so changing that choice requires reviewing the remainder again.
        if !estimate.isEmpty { estimateLotID = lot.id }
        if let originalDimension = unit?.dimension ?? spokenDimension, originalDimension != lot.unit.dimension {
            // The number of pieces or cups cannot be carried into a weight or package count.
            amount = ""; unit = nil; spokenDimension = nil
        }
    }

    var selection: PantryConsumptionSelection? {
        guard let lotID else { return nil }
        switch mode {
        case .amount:
            guard let unit, let quantity = try? ComparisonModel.quantity(amount, unit), quantity.amount > .zero else { return nil }
            return .init(lotID: lotID, use: .amount(quantity))
        case .remaining:
            let trimmed = estimate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return nil }
            return .init(lotID: lotID, use: reportsUse ? .usedSome(remainingWording: trimmed) : .low(trimmed))
        case .all: return .init(lotID: lotID, use: reportsUse ? .all : .empty)
        case .usedSome: return .init(lotID: lotID, use: .usedSome(remainingWording: nil))
        case .skip: return nil
        }
    }
}

@MainActor struct PantryVoiceView: View {
    @ObservedObject var model: PantryModel
    @ObservedObject var household: HouseholdModel
    let origin: UUID
    var startingLot: InventoryLot? = nil
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.pantryDigestAccess) private var digestAccess
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scene
    @Environment(\.pantryVoicePrompt) private var pantryVoicePrompt
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = PantryVoiceSession()
    @FocusState private var editing: Bool
    @State private var reviewAfterEditing = false
    @State private var remainingChoices: Int?
    @State private var identity: CapturePrivateIdentity?
    @State private var generation: UUID?
    @State private var token = UUID()
    @State private var draft = ""
    @State private var rows: [VoicePantryRow] = []
    @State private var basis: InventoryState?
    @State private var dateOnly = false
    @State private var balanceFood: String?
    @State private var balanceHistoryLot: InventoryLot?
    @State private var editedBasis: InventoryState?
    @State private var editedRows: [VoicePantryRow] = []
    @State private var dateEvidence: PantryVoiceDateEvidence?
    @State private var review: PantryConsumptionReview?
    @State private var saved: [InventoryLot]?
    @State private var savedRevision: Int64?
    private struct RemainingReply {
        let id = UUID()
        let rowIndex: Int
        let lotID: UUID
        var text: String
        var clarification: String?
    }
    @State private var remainingReply: RemainingReply?
    @State private var restockIDs: Set<UUID> = []
    @State private var recordedUseIDs: Set<UUID> = []
    @State private var working = false
    @State private var message: String?
    @AccessibilityFocusState private var entryFeedbackFocused: Bool

    private var currentIdentity: CapturePrivateIdentity? {
        let retainingPrompt = identity != nil && scene != .background && pantryVoicePrompt?.holdsPresentation() == true
        guard scene == .active || retainingPrompt, UIApplication.shared.isProtectedDataAvailable,
              child?.presented != true, household.projection?.grantId == nil,
              pickup.pantryRouteAvailable || retainingPrompt, pickup.sourceWorkspaceID == origin,
              model.phase == .ready, model.snapshot?.state.workspaceID == origin else { return nil }
        return .current(access: access, household: household)
    }
    private var boundScope: Bool {
        identity != nil && identity == currentIdentity && generation == pickup.privatePantryGeneration
    }

    private var authorized: Bool { boundScope && scene == .active && UIApplication.shared.applicationState == .active }
    private var canRetainDictation: Bool {
        guard boundScope, model.canEdit, !working, saved == nil else { return false }
        if basis == nil { return startingLot == nil }
        guard let remainingReply else { return false }
        return currentReply(remainingReply)
    }

    private func currentReply(_ reply: RemainingReply) -> Bool {
        remainingReply?.id == reply.id && basis == model.snapshot?.state && review == nil && !dateOnly &&
            rows.indices.contains(reply.rowIndex) && rows[reply.rowIndex].lotID == reply.lotID
    }

    private enum Stage { case entry, choices, review, saved }
    private var stage: Stage {
        if saved != nil { return .saved }
        if review != nil { return .review }
        return basis == nil ? .entry : .choices
    }

    var body: some View {
        ScrollViewReader { scroll in
            voiceForm
                .task(id: token) {
                    guard stage == .entry, startingLot == nil, message != nil else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo("pantry.entryFeedback", anchor: .top)
                    entryFeedbackFocused = true
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    if editing, stage == .entry, startingLot == nil {
                        scroll.scrollTo("pantry.entryEditor", anchor: .bottom)
                    }
                }
        }
    }

    private var voiceForm: some View {
        WorkingForm {
            if !boundScope {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if let pending = model.pending {
                if working || model.busy {
                    ProgressView(pantryText("Saving your change…"))
                        .accessibilityIdentifier("pantry.saveProgress")
                } else {
                    Text(pantryText(model.pendingWasCommitted || pending.acknowledgment != nil
                        ? "Your change is saved. Retry to finish recovery."
                        : "The save result is uncertain. Retry the same reviewed change before starting another."))
                    Button(pantryText("Review pending save")) { dismiss() }
                }
            } else if let saved {
                savedSection(saved)
            } else {
                if startingLot == nil && stage == .entry {
                    Section {
                        Text(pantryText("What changed in your pantry?"))
                            .marketJournalTitle()
                        if let message {
                            Label(message, systemImage: "exclamationmark.circle")
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityFocused($entryFeedbackFocused)
                                .accessibilityIdentifier("pantry.voiceStatus")
                                .id("pantry.entryFeedback")
                        }
                        TextField(pantryText("What did you use, or what would you like to check?"),
                                  text: Binding(get: { draft }, set: { text in
                                      guard stage == .entry, draft != text else { return }
                                      draft = text
                                      resetReview()
                                  }), axis: .vertical)
                            .lineLimit(2...6)
                            .padding(12)
                            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlEdge) }
                            .focused($editing)
                            .accessibilityIdentifier("pantry.voiceText")
                            .disabled(working || !model.canEdit)
                            .id("pantry.entryEditor")
                        if draft.isEmpty && !editing {
                            let example = pantryText("I have about half a bottle of ketchup left")
                            Button {
                                draft = example
                                editing = true
                            } label: {
                                Label(pantryFormat("Try “%@”", example), systemImage: "text.quote")
                                    .multilineTextAlignment(.leading)
                                    .frame(minHeight: 44)
                            }
                            .disabled(working || !model.canEdit)
                            .accessibilityIdentifier("pantry.voiceExample")
                        }
                    } footer: {
                        Label(pantryText("Private · On this iPhone"), systemImage: "lock")
                    }
                }
                if basis == nil, startingLot != nil {
                    Text(pantryText("This batch changed. Return to My Pantry and review it again."))
                } else if basis == nil {
                    PantryVoiceInput(voice: voice, authorized: { canRetainDictation }) { spoken in
                        guard authorized, model.canEdit, !working, basis == nil else { return }
                        draft = draft.isEmpty ? spoken : draft + " " + spoken
                        resetReview()
                    }
                    if !editing {
                        reviewWordsButton().buttonStyle(PrimaryAction())
                    }
                } else if let balanceFood {
                    balanceSection(balanceFood)
                } else if let review {
                    previewSection(review)
                } else {
                    ForEach(rows.indices, id: \.self) { index in
                        choiceSection(index)
                        if let reply = remainingReply, reply.rowIndex == index, currentReply(reply) {
                            PantryVoiceInput(voice: voice, authorized: { canRetainDictation && currentReply(reply) }) { words in
                                guard authorized, currentReply(reply) else { return }
                                updateRemaining(words, reply: reply)
                            }
                        }
                    }
                    if dateOnly {
                        dateSection
                    } else if remainingReply == nil && !rows.isEmpty && rows.allSatisfy({ $0.mode == .skip }) {
                        Text(pantryText("No pantry changes selected."))
                            .accessibilityIdentifier("pantry.voiceStatus")
                    } else {
                        Button(pantryText(confirmsSingleUse ? "Record one use" : "Preview pantry changes")) {
                            Task { await prepare(confirmUse: confirmsSingleUse) }
                        }.buttonStyle(PrimaryAction())
                            .disabled(!readyToReview)
                            .accessibilityIdentifier(confirmsSingleUse ? "pantry.recordOneUse" : "pantry.voicePreview")
                    }
                }
                if startingLot == nil && (stage == .choices || stage == .review) {
                    Button {
                        editedBasis = basis
                        editedRows = rows
                        resetReview()
                        editing = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "text.quote").foregroundStyle(Theme.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pantryText("Edit your words")).font(.subheadline.weight(.semibold))
                                Text(draft).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "pencil").foregroundStyle(Theme.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(working || !model.canEdit)
                    .accessibilityLabel(pantryText("Edit your words"))
                    .accessibilityValue(draft)
                    .accessibilityIdentifier("pantry.voiceTranscript")
                }
                if let message, stage != .entry || startingLot != nil {
                    Text(message).accessibilityIdentifier("pantry.voiceStatus")
                }
                if working { ProgressView(pantryText("Working…")) }
            }
        }
        .id(stage)
        .sheet(item: $balanceHistoryLot) { lot in
            NavigationStack {
                PantryUsageHistoryView(model: model, lotID: lot.id, origin: origin, authorized: { authorized })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(pantryText("Close")) { balanceHistoryLot = nil }
                                .accessibilityIdentifier("pantry.balanceHistoryClose")
                        }
                    }
            }
        }
        .navigationTitle(pantryText(stage == .review ? "Review pantry changes" : (startingLot == nil ? "Talk or type" : "Record use")))
        .toolbar(.hidden, for: .tabBar)
        .privacySensitive()
        .keyboardDoneAction(visible: editing && stage != .entry, title: pantryText("Done"), identifier: "pantry.voiceKeyboardDone") { editing = false }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editing, stage == .entry {
                HStack(spacing: 12) {
                    Button { editing = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                        .accessibilityLabel(pantryText("Hide keyboard"))
                        .accessibilityIdentifier("pantry.voiceKeyboardDone")
                    Spacer(minLength: 0)
                    reviewWordsButton(compact: true).buttonStyle(PrimaryAction())
                }
                .padding(.horizontal).background(.bar)
            }
        }
        .toolbar {
            if saved == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(pantryText("Cancel")) { erase(); dismiss() }.disabled(working)
                        .accessibilityIdentifier("pantry.voiceCancel")
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(pantryText("Done")) { dismiss() }
                }
            }
        }
        .onAppear {
            if identity == nil, scene == .active {
                identity = currentIdentity; generation = pickup.privatePantryGeneration
                if let startingLot, authorized, model.canEdit, lots.contains(startingLot) {
                    basis = model.snapshot?.state
                    rows = [.init(food: startingLot.name, original: startingLot.name, lotID: startingLot.id, mode: .usedSome)]
                }
            }
        }
        .disabled(scene != .active)
        .onChange(of: editing) { _, isEditing in
            if !isEditing, reviewAfterEditing {
                reviewAfterEditing = false
                if stage == .entry { parse() }
            }
        }
        .onChange(of: canRetainDictation) { _, allowed in if !allowed { voice.cancel() } }
        .onChange(of: boundScope) { _, allowed in
            if !allowed { erase() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in erase() }
        .onChange(of: model.snapshot?.state.revision) { _, _ in
            if !working, basis != nil, model.snapshot?.state != basis { resetReview(); message = pantryNotice(.stale) }
        }
        .onDisappear {
            // A pushed shopping/reminder handoff still needs its saved lot and live identity.
            voice.cancel()
            if balanceFood == nil {
                draft = ""; resetReview(); editedRows = []; editedBasis = nil
            }
        }
    }

    private func reviewWordsButton(compact: Bool = false) -> some View {
        Button(pantryText(compact ? "Review" : "Review my words")) {
            if editing {
                reviewAfterEditing = true
                editing = false
            } else {
                parse()
            }
        }
        .disabled(!model.canEdit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(pantryText("Review my words"))
        .accessibilityIdentifier("pantry.voiceReview")
    }

    private func resetReview() {
        remainingChoices = nil
        closeRemaining()
        token = UUID(); basis = nil; rows = []; review = nil; dateOnly = false
        balanceHistoryLot = nil
        dateEvidence = nil; balanceFood = nil; message = nil; working = false
    }

    private func erase() {
        reviewAfterEditing = false
        voice.cancel()
        draft = ""; resetReview(); editedRows = []; editedBasis = nil; saved = nil; savedRevision = nil; identity = nil; generation = nil; editing = false
    }

    private func parse() {
        guard authorized, model.canEdit, let snapshot = model.snapshot else { return }
        voice.cancel()
        editing = false; resetReview()
        switch PantryVoiceParser.parse(draft, localeIdentifier: locale.identifier) {
        case .consume(let items):
            rows = items.map(VoicePantryRow.consumption)
        case .askRemaining(let food, let original):
            rows = [.init(food: food ?? "", original: original, mode: .remaining)]
        case .observation(let observation):
            var row = VoicePantryRow(food: observation.food, original: observation.original, reportsUse: false, mode: .remaining)
            row.applyRemaining(observation)
            rows = [row]
        case .balanceQuery(let food):
            balanceFood = food
        case .dateQuery(let food):
            dateOnly = true; rows = [.init(food: food, original: draft, mode: .skip)]
        case .needsReview:
            message = pantryText("Nothing changed. Try one instruction, like “I used two eggs.”")
            return
        }
        for index in rows.indices where !rows[index].food.isEmpty {
            if editedBasis == snapshot.state, rows[index].restoreSelection(from: editedRows, in: snapshot.lots) { continue }
            if let lot = PantryVoiceBatchMatcher.uniqueExact(for: rows[index].food, in: snapshot.lots) {
                rows[index].choose(lot)
            }
        }
        editedRows = []; editedBasis = nil
        basis = snapshot.state
    }

    private func balanceSection(_ food: String) -> some View {
        let matches = PantryVoiceBatchMatcher.suggestions(for: food, in: lots)
        return Section(pantryText("Recorded pantry amounts")) {
            if matches.isEmpty {
                Text(pantryFormat("No pantry batch matches %@.", food))
            }
            ForEach(matches) { lot in
                batchHeading(lot)
                Button(pantryText("Usage history") + " · " + pantryLocationName(lot.location)) {
                    guard authorized, basis == model.snapshot?.state else { return }
                    balanceHistoryLot = lot
                }
            }
        }
        .accessibilityIdentifier("pantry.voiceBalance")
    }

    private var lots: [InventoryLot] { model.snapshot?.lots ?? [] }

    private func lotLabel(_ lot: InventoryLot) -> String {
        [lot.name, pantryLocationName(lot.location), pantryCount(lot.count, estimate: lot.countWording),
         pantryFormat("Batch %@", String(lot.id.uuidString.suffix(8)))].joined(separator: " · ")
    }

    private func batchDetail(_ lot: InventoryLot, includeCount: Bool = true) -> String {
        var details = [pantryLocationName(lot.location)]
        if includeCount { details.append(pantryCount(lot.count, estimate: lot.countWording)) }
        if lots.contains(where: { $0.id != lot.id && $0.location == lot.location && $0.name.localizedCaseInsensitiveCompare(lot.name) == .orderedSame }) {
            details.append(pantryFormat("Batch %@", String(lot.id.uuidString.suffix(8))))
        }
        return details.joined(separator: " · ")
    }

    private func batchHeading(_ lot: InventoryLot, includeCount: Bool = true) -> some View {
        let symbol = switch lot.location {
        case .cupboard: "shippingbox"
        case .fridge: "refrigerator"
        case .freezer: "snowflake"
        }
        return WorkingRecordHeading(lot.name, detail: batchDetail(lot, includeCount: includeCount), systemImage: symbol)
    }

    private func change(_ index: Int, _ update: (inout VoicePantryRow) -> Void) {
        guard authorized, !working, rows.indices.contains(index) else { return }
        closeRemaining()
        update(&rows[index]); dateEvidence = nil; review = nil; message = nil; token = UUID()
    }

    private func choiceSection(_ index: Int) -> some View {
        let row = rows[index]
        let suggestions = PantryVoiceBatchMatcher.suggestions(for: row.food, in: lots)
        let selected = lots.first { $0.id == row.lotID }
        let unnamed = row.food.isEmpty
        let unmatched = !unnamed && suggestions.isEmpty && !lots.isEmpty
        let candidates = row.showsAllLots || unnamed ? lots : suggestions
        return Section {
            if let startingLot {
                batchHeading(startingLot)
            } else if unmatched && !row.showsAllLots {
                Text(pantryFormat("No pantry batch matches %@.", row.food))
                Button(pantryText("Show all pantry batches")) { change(index) { $0.showsAllLots = true } }
                    .accessibilityIdentifier("pantry.voiceBrowse.\(index)")
            } else if !candidates.isEmpty {
                Menu {
                    ForEach(candidates) { lot in
                        Button(lotLabel(lot)) { change(index) { $0.choose(lot) } }
                    }
                    if !row.showsAllLots, candidates.count < lots.count {
                        Button(pantryText("Show all pantry batches")) { change(index) { $0.showsAllLots = true } }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let selected {
                            batchHeading(selected)
                        } else {
                            WorkingRecordHeading(row.food.isEmpty ? pantryText("Which pantry batch?") : pantryFormat("Which %@?", row.food),
                                                 detail: pantryText("Choose a batch"), systemImage: "shippingbox")
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(selected.map(lotLabel) ?? pantryText("Choose a batch"))
                .accessibilityIdentifier("pantry.voiceLot.\(index)")
            }
            if startingLot == nil && rows.count > 1 {
                Label { Text(row.original) } icon: { Image(systemName: "text.quote") }
                    .font(.subheadline).foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("pantry.voiceOriginal.\(index)")
            }
            if unmatched && !dateOnly && row.mode != .skip {
                Button(pantryText("Leave this item unchanged")) { change(index) { $0.mode = .skip } }
                    .accessibilityIdentifier("pantry.voiceSkip.\(index)")
            }
            if lots.isEmpty { Text(pantryText("Add a pantry batch before reviewing these words.")) }
            if !dateOnly { amountChoices(index, row: row, lot: selected) }
        }
        .disabled(working || !model.canEdit)
    }

    @ViewBuilder private func amountChoices(_ index: Int, row: VoicePantryRow, lot: InventoryLot?) -> some View {
        if row.mode == .amount {
            WorkingField(pantryText("Amount used")) {
                TextField(pantryText("Amount used"), text: Binding(get: { row.amount }, set: { text in change(index) { $0.amount = text } }))
                    .focused($editing).accessibilityIdentifier("pantry.voiceAmount.\(index)")
            }
            if startingLot != nil, lot?.unit == .count, row.unit == .count {
                LabeledContent(pantryText("Unit"), value: pantryUnit(.count))
            } else {
                Menu {
                    ForEach(UnitOfMeasure.allCases.filter { $0.dimension == lot?.unit.dimension }, id: \.self) { unit in
                        Button(pantryUnit(unit)) { change(index) { $0.unit = unit } }
                    }
                } label: {
                    LabeledContent(pantryText("Unit"), value: row.unit.map { pantryUnit($0) } ?? pantryText("Choose a unit"))
                }
                .disabled(lot == nil).accessibilityIdentifier("pantry.voiceUnit.\(index)")
            }
        } else if row.mode == .remaining && row.estimate.isEmpty {
            Text(pantryText("How much is left?")).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
        } else {
            let currentChoice = switch row.mode {
            case .remaining: row.estimate
            case .all: pantryText(row.reportsUse ? "Used all of the selected batch" : "The selected batch is empty")
            case .usedSome: pantryText("Used some")
            case .skip: pantryText("Leave unchanged")
            case .amount: ""
            }
            VStack(alignment: .leading, spacing: 7) {
                if row.mode == .remaining {
                    Label(pantryText("Remaining estimate"), systemImage: "text.quote")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                    Text(verbatim: currentChoice)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .foregroundStyle(Theme.onSelection)
                        .background(Theme.selection, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("pantry.voiceEstimate.\(index)")
                } else {
                    BrandScopeLabel(currentChoice, systemImage: "checkmark", showsSelection: true)
                        .accessibilityIdentifier("pantry.voiceEstimate.\(index)")
                }
                if row.mode == .usedSome {
                    Text(pantryText("Record one use. The amount remaining will be unknown."))
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }
            }.padding(.vertical, 3)
        }
        if (row.mode == .remaining && row.estimate.isEmpty) || row.mode == .usedSome {
            Button {
                chooseEstimate("About half left", for: index)
            } label: {
                Label(pantryText("About half left"), systemImage: "circle.lefthalf.filled")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(lot == nil)
            .accessibilityIdentifier("pantry.voiceHalf.\(index)")
        }
        Button {
            remainingChoices = index
        } label: {
            Label(pantryText("Choose how much is left"), systemImage: "slider.horizontal.3")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pantry.voiceRemaining.\(index)")
        .confirmationDialog(pantryText("Choose how much is left"), isPresented: Binding(
            get: { remainingChoices == index },
            set: { if !$0, remainingChoices == index { remainingChoices = nil } }
        ), titleVisibility: .visible) {
            ForEach(["Mostly full", "More than half left", "About half left", "Less than half left", "Nearly empty"], id: \.self) { key in
                Button(pantryText(key)) {
                    chooseEstimate(key, for: index)
                }
            }
            if let lot {
                Button(pantryText("Describe what is left")) {
                    guard authorized, model.canEdit, basis == model.snapshot?.state else { return }
                    closeRemaining()
                    remainingReply = RemainingReply(rowIndex: index, lotID: lot.id, text: row.estimate)
                }
            }
            Button(pantryText("Used it all")) { change(index) { $0.mode = .all; $0.reportsUse = true } }
            Button(pantryText("Not sure")) { change(index) { $0.mode = .skip } }
            Button(pantryText("Cancel"), role: .cancel) {}
        }
        if let reply = remainingReply, reply.rowIndex == index, currentReply(reply) {
            TextField(pantryText("How much is left in this batch?"),
                      text: Binding(get: { remainingReply?.text ?? "" }, set: { updateRemaining($0, reply: reply) }))
                .focused($editing)
                .accessibilityIdentifier("pantry.voiceRemainingText.\(index)")
            if let clarification = reply.clarification { Text(clarification) }
            Button(pantryText("Use this estimate")) { applyRemaining(reply) }
                .disabled(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("pantry.voiceApplyRemaining.\(index)")
        }
        if row.mode != .usedSome {
            Button {
                change(index) { $0.mode = .usedSome; $0.reportsUse = true }
            } label: {
                Label(pantryText("Record a use without measuring"), systemImage: "checklist")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
                .accessibilityIdentifier("pantry.voiceSome.\(index)")
        }
        if row.mode != .amount {
            Button {
                change(index) {
                    $0.mode = .amount
                    $0.reportsUse = true
                    if startingLot != nil, lot?.unit == .count { $0.unit = .count }
                }
            } label: {
                Label(pantryText("Enter amount used"), systemImage: "number")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
                .accessibilityIdentifier("pantry.voiceUseAmount.\(index)")
        }
    }

    private func chooseEstimate(_ key: String, for index: Int) {
        change(index) {
            $0.mode = .remaining
            $0.estimate = pantryText(key)
            $0.estimateLotID = $0.lotID
            $0.isLowEstimate = key == "Less than half left" || key == "Nearly empty"
        }
    }

    private func updateRemaining(_ words: String, reply: RemainingReply) {
        guard authorized, currentReply(reply) else { return }
        // Overlong or multi-line dictation cannot become a partial, valid interpretation.
        guard words.utf8.count <= 512, !words.contains(where: \.isNewline) else {
            remainingReply?.text = ""
            remainingReply?.clarification = pantryText("Describe one remaining amount for this batch, or choose an estimate.")
            return
        }
        remainingReply?.text = words
        remainingReply?.clarification = nil
    }

    private func applyRemaining(_ reply: RemainingReply) {
        guard authorized, model.canEdit, currentReply(reply), let words = remainingReply?.text else { return }
        guard let result = PantryVoiceParser.parseRemainingReply(words, localeIdentifier: locale.identifier) else {
            remainingReply?.clarification = pantryText("Describe one remaining amount for this batch, or choose an estimate.")
            return
        }
        if result.remaining == .empty, rows[reply.rowIndex].reportsUse {
            remainingReply?.clarification = pantryText("If you used the whole batch, choose Used it all.")
            return
        }
        editing = false
        change(reply.rowIndex) { $0.applyRemaining(result) }
    }

    private func closeRemaining() {
        guard remainingReply != nil else { return }
        voice.cancel()
        remainingReply = nil
    }

    private var confirmsSingleUse: Bool {
        startingLot != nil && rows.count == 1 && rows[0].mode == .usedSome
    }

    private var readyToReview: Bool {
        remainingReply == nil && !rows.isEmpty && rows.allSatisfy { $0.mode == .skip || $0.selection != nil } &&
        !working && authorized && model.canEdit && basis == model.snapshot?.state
    }

    private func prepare(confirmUse: Bool = false) async {
        guard readyToReview, let basis else { return }
        editing = false
        let selections = rows.compactMap(\.selection)
        guard !selections.isEmpty else {
            message = pantryText("No pantry changes selected."); return
        }
        let request = token
        working = true
        defer { if request == token { working = false } }
        do {
            let result = try await model.reviewConsumption(selections, basis: basis)
            guard request == token, authorized, model.snapshot?.state == basis else { return }
            if confirmUse, confirmsSingleUse {
                // The batch screen already names the food and explains the unknown remainder.
                // Still bind the reviewed command and write to the same original inventory revision.
                working = false
                await save(result, returnToBatch: true)
            } else {
                review = result; message = nil
            }
        } catch { handle(error, request: request) }
    }

    private func previewSection(_ review: PantryConsumptionReview) -> some View {
        Section {
            ForEach(Array(review.lines.enumerated()), id: \.offset) { index, line in
                let use = review.entry.consumption?.selections[index].use
                VStack(alignment: .leading, spacing: 12) {
                    batchHeading(line.lot, includeCount: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(pantryText("After this change"), systemImage: "arrow.right")
                            .font(.subheadline.weight(.medium))
                        Text(pantryCount(line.after, estimate: use?.remainingWording)).font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(Theme.onSelection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Theme.selection, in: RoundedRectangle(cornerRadius: 12))
                    reviewAmount(pantryText("Previously recorded"), value: pantryCount(line.before, estimate: line.lot.countWording))
                        .foregroundStyle(Theme.secondary)
                    if let used = line.used {
                        reviewAmount(pantryText("Amount used"), value: pantryQuantity(used))
                    }
                    if let use {
                        switch use {
                        case .usedSome: Text(pantryText("Used some"))
                        case .all: Text(pantryText("Used all of the selected batch"))
                        case .empty: Text(pantryText("The selected batch is empty"))
                        case .amount, .low, .unknown: EmptyView()
                        }
                    }
                }.padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pantry.voiceSummary.\(index)")
            }
            ForEach(rows.indices.filter { rows[$0].mode == .skip }, id: \.self) { index in
                Text(pantryFormat("Left unchanged: %@", rows[index].original))
            }
            Button(pantryText("Edit choices")) { self.review = nil; message = nil }
                .accessibilityIdentifier("pantry.voiceEdit")
            Button(pantryText("Confirm pantry changes")) { Task { await save(review) } }
                .buttonStyle(PrimaryAction())
                .accessibilityIdentifier("pantry.voiceConfirm")
        }.disabled(working || !model.canEdit)
    }

    private func save(_ review: PantryConsumptionReview, returnToBatch: Bool = false) async {
        guard authorized, !working, model.canEdit, basis == model.snapshot?.state else { return }
        let request = token
        working = true
        defer { if request == token { working = false } }
        do {
            try await model.saveConsumption(review)
            guard request == token, authorized else { return }
            recordedUseIDs = Set(rows.filter { $0.reportsUse && $0.mode != .skip }.compactMap(\.lotID))
            restockIDs = Set(rows.filter { $0.mode == .all || ($0.mode == .remaining && $0.isLowEstimate) }.compactMap(\.lotID))
            let selectedIDs = rows.filter { $0.mode != .skip }.compactMap(\.lotID)
            saved = selectedIDs.compactMap { id in lots.first { $0.id == id } }
            savedRevision = model.snapshot?.state.revision
            draft = ""; resetReview()
            if returnToBatch { dismiss() }
        } catch { handle(error, request: request) }
    }

    private func handle(_ error: Error, request: UUID) {
        guard request == token, authorized else { return }
        switch error as? PantryConsumptionFailure {
        case .invalidAmount: message = pantryText("Check the food name, amount and unit before reviewing.")
        case .incompatibleUnit: message = pantryText("Choose a unit that matches this batch.")
        case .insufficientFree, .reserved: message = pantryText("Enter an amount available in this batch after existing reservations.")
        case .emptyBatch: message = pantryText("This batch is empty. Choose another batch or correct its count in My Pantry.")
        case .countNeeded: message = pantryText("This batch needs a measured count before you can subtract an amount.")
        case .stale: resetReview(); message = pantryNotice(.stale)
        default: message = pantryText("Could not complete this pantry review. Return to My Pantry and refresh.")
        }
    }

    private func savedSection(_ saved: [InventoryLot]) -> some View {
        Section {
            Label {
                if saved.count == 1, let lot = saved.first, recordedUseIDs.contains(lot.id) {
                    Text(pantryFormat("Recorded one use of %@.", lot.name))
                } else { Text(pantryText("Food saved on this device.")) }
            } icon: { Image(systemName: "checkmark.circle") }
            .accessibilityIdentifier("pantry.voiceSaved")
            ForEach(Array(saved.enumerated()), id: \.element.id) { index, lot in
                Text(pantryLocationName(lot.location))
                if let wording = lot.countWording {
                    Text(pantryFormat("%@ · Remaining estimate: %@", lot.name, wording))
                        .accessibilityIdentifier("pantry.voiceSavedWording.\(index)")
                } else {
                    Text(pantryFormat("%@ · %@", lot.name, pantryCount(lot.count)))
                }
                if restockIDs.contains(lot.id) {
                    PantryRestockActions(model: model, lot: lot, sourceCurrent: {
                        authorized && model.canEdit && savedRevision == model.snapshot?.state.revision &&
                            model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot
                    })
                }
            }
        }
    }

    @ViewBuilder private func reviewAmount(_ title: String, value: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(verbatim: value).fontWeight(.medium)
            }.font(.subheadline)
        } else {
            LabeledContent(title, value: value).font(.subheadline)
        }
    }

    @ViewBuilder private var dateSection: some View {
        let lot = lots.first { $0.id == rows.first?.lotID }
        Section {
            Button(pantryText("Check recorded dates")) { Task { await readDate() } }
                .disabled(working || !model.canEdit || lot == nil || digestAccess == nil)
                .accessibilityIdentifier("pantry.voiceDate")
            if digestAccess == nil { Text(pantryText("Date records are unavailable. Return to My Pantry and refresh.")) }
            if let dateEvidence, let lot, let digestAccess {
                PantryVoiceDateResult(evidence: dateEvidence, lot: lot, model: model, access: digestAccess)
                    .accessibilityIdentifier("pantry.voiceDateResult")
            }
        }
    }

    private func readDate() async {
        guard authorized, model.canEdit, !working, dateOnly, basis == model.snapshot?.state,
              let lot = lots.first(where: { $0.id == rows.first?.lotID }), let digestAccess else { return }
        let request = token
        working = true; dateEvidence = nil; editing = false
        defer { if request == token { working = false } }
        do {
            let result = try await PantryVoiceDateEvidence.read(lot: lot, model: model, access: digestAccess)
            guard request == token, authorized, result.isCurrent(lot: lot, model: model, access: digestAccess) else { return }
            dateEvidence = result; message = nil
        } catch {
            if request == token, authorized { message = pantryText("Date records are unavailable. Return to My Pantry and refresh.") }
        }
    }
}

@MainActor private struct PantryVoiceDateResult: View {
    let evidence: PantryVoiceDateEvidence
    let lot: InventoryLot
    @ObservedObject var model: PantryModel
    let access: PantryDigestAccess
    @ObservedObject private var digest = PantryDigestStore.shared
    @ObservedObject private var printed = PantryDigestStore.shared.packageDates
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if evidence.isCurrent(lot: lot, model: model, access: access, now: context.date) {
                VStack(alignment: .leading, spacing: 10) {
                    if let printed = evidence.printed {
                        Label(printed.sourceLabel, systemImage: "tag").font(.headline).foregroundStyle(Theme.action)
                        LabeledContent(printed.meaningLabel, value: printed.meaning.label)
                        if let original = printed.originalPrintedWording {
                            LabeledContent(pantryText("Original printed wording"), value: original)
                        }
                        if let day = printed.verifiedDay {
                            Text(PantryVoiceDateEvidence.formatted(day, locale: locale))
                            if let today = try? MealDay(date: context.date, timeZoneIdentifier: day.timeZoneIdentifier) {
                                if day.iso8601 == today.iso8601 { Text(pantryText(printed.selectedAI == nil ? "The printed date is today." : "The encoded date is today.")) }
                                else if day.iso8601 < today.iso8601 { Text(pantryText(printed.selectedAI == nil ? "The printed date has passed." : "The encoded date has passed.")) }
                            }
                        }
                    } else { Text(pantryText("No verified printed package date available.")) }
                    Divider().accessibilityHidden(true)
                    if let quality = evidence.quality {
                        Label(pantryText("FoodKeeper quality range"), systemImage: "book")
                            .font(.headline).foregroundStyle(Theme.action)
                        Text(verbatim: "USDA FSIS · FoodKeeper v" + String(quality.version) + " · #" + String(quality.productID))
                        Text(pantryFormat("%@ – %@", PantryVoiceDateEvidence.formatted(quality.earliest, locale: locale),
                                          PantryVoiceDateEvidence.formatted(quality.latest, locale: locale)))
                        Text(pantryText("This storage range describes quality. It does not establish an expiration date."))
                    } else if evidence.guide == .needsReview {
                        Text(pantryText("The saved FoodKeeper range needs review. Check whether the package is open, where it is stored, and the starting date."))
                        NavigationLink(pantryText("Review FoodKeeper guidance for this batch")) {
                            PantryLotStorageReference(model: model, lotID: lot.id,
                                accessAllowed: access.authorized() && model.snapshot?.lots.contains(lot) == true)
                                .environment(\.pantryDigestAccess, access)
                        }.accessibilityIdentifier("pantry.voiceReviewFoodKeeper")
                    } else { Text(pantryText("No verified FoodKeeper quality range available.")) }
                }.accessibilityElement(children: .contain)
            } else { Text(pantryText("Date information changed. Check the recorded dates again.")) }
        }
    }
}

extension PantryUsageHistoryRow {
    static func usesInLast30Days(_ entries: [Self], asOf now: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -29, to: today) else { return 0 }
        return entries.filter { start <= $0.occurredAt && $0.occurredAt <= now }.count
    }
}

/// Reads only explicitly recorded usage, keyed to the live private pantry revision.
@MainActor struct PantryUsageHistoryView: View {
    @ObservedObject var model: PantryModel
    let lotID: UUID
    let origin: UUID
    let authorized: @MainActor () -> Bool
    var showsLink = false
    @Environment(\.scenePhase) private var scene
    @State private var entries: [PantryUsageHistoryRow]?
    @State private var loadedRevision: Int64?
    @State private var failed = false

    private var revision: Int64? {
        guard scene == .active, UIApplication.shared.isProtectedDataAvailable, authorized(), model.canEdit,
              model.snapshot?.state.workspaceID == origin, model.snapshot?.lots.contains(where: { $0.id == lotID }) == true
        else { return nil }
        return model.snapshot?.state.revision
    }

    var body: some View {
        Group {
            if showsLink {
                NavigationLink {
                    PantryUsageHistoryView(model: model, lotID: lotID, origin: origin, authorized: authorized)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pantryText("Usage history")).font(.headline)
                        if let revision, loadedRevision == revision, let latest = entries?.first {
                            Text(pantryFormat(latest.kind == .some ? "Used some · %@" : "Last use: %@",
                                              latest.occurredAt.formatted(date: .abbreviated, time: .shortened)))
                                .font(.body).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.accessibilityIdentifier("pantry.usageHistory")
            } else {
                history.navigationTitle(pantryText("Usage history"))
            }
        }
        .privacySensitive()
        .task(id: revision) { await read() }
        .onDisappear { entries = nil; loadedRevision = nil }
    }

    private var history: some View {
        WorkingForm {
            if revision == nil { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
            else if loadedRevision == revision, let entries, let lot = model.snapshot?.lots.first(where: { $0.id == lotID }) {
                Section {
                    let similarBatch = model.snapshot?.lots.contains {
                        $0.id != lot.id && $0.location == lot.location &&
                            $0.name.localizedCaseInsensitiveCompare(lot.name) == .orderedSame
                    } == true
                    PantryBatchHeading(lot: lot, showsBatchIdentifier: similarBatch ||
                        lot.intakeOrdinal != nil || lot.packageCode?.gs1?.lot != nil)
                }
                Section {
                    LabeledContent(pantryText("Recorded uses"), value: entries.count.formatted())
                        .accessibilityIdentifier("pantry.usageCount")
                    TimelineView(.everyMinute) { _ in
                        let count = PantryUsageHistoryRow.usesInLast30Days(entries, asOf: Date())
                        LabeledContent(pantryText("Uses in the last 30 days"), value: count.formatted())
                            .accessibilityIdentifier("pantry.usageCount30Days")
                    }
                    if let latest = entries.first {
                        LabeledContent(pantryText("Last used"), value: latest.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, row in
                    VStack(alignment: .leading, spacing: 4) {
                        switch row.kind {
                        case .measured(let quantity): LabeledContent(pantryText("Amount used"), value: pantryQuantity(quantity))
                        case .some: Text(pantryText("Used some"))
                        case .all: Text(pantryText("Used all of the selected batch"))
                        }
                        if let wording = row.remainingWording {
                            Text(pantryFormat("Remaining estimate: %@", wording)).font(.headline)
                        }
                        Text(row.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                    }.accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pantry.usageEvent.\(index)")
                }
            } else if failed {
                Button(pantryText("Retry usage history")) { Task { await read() } }
            } else { ProgressView(pantryText("Working…")) }
        }
    }

    private func read() async {
        entries = nil; loadedRevision = nil; failed = false
        guard let revision, let basis = model.snapshot?.state else { return }
        do {
            let result = try await model.usageHistory(lotID: lotID, basis: basis)
            guard !Task.isCancelled, self.revision == revision else { return }
            entries = result; loadedRevision = revision
        } catch { if !Task.isCancelled, self.revision == revision { failed = true } }
    }
}
