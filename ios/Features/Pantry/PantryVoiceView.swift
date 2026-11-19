import CoreDomain
import LocalStore
import SwiftUI

/// Editable choices for one phrase. Ambiguous names, package units and remaining estimates
/// stay unresolved until the user supplies them. No transcript is part of a save command.
private struct VoicePantryRow {
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
    var showsAllLots = false

    mutating func choose(_ lot: InventoryLot) {
        lotID = lot.id
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
    @Environment(\.scenePhase) private var scene
    @Environment(\.pantryVoicePrompt) private var pantryVoicePrompt
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = PantryVoiceSession()
    @FocusState private var editing: Bool
    @State private var identity: CapturePrivateIdentity?
    @State private var generation: UUID?
    @State private var token = UUID()
    @State private var draft = ""
    @State private var rows: [VoicePantryRow] = []
    @State private var basis: InventoryState?
    @State private var dateOnly = false
    @State private var dateEvidence: PantryVoiceDateEvidence?
    @State private var review: PantryConsumptionReview?
    @State private var saved: [InventoryLot]?
    @State private var savedRevision: Int64?
    @State private var working = false
    @State private var message: String?

    private var currentIdentity: CapturePrivateIdentity? {
        let retainingPrompt = identity != nil && scene == .inactive && pantryVoicePrompt?.retainsInactiveScope == true
        guard scene == .active || retainingPrompt, UIApplication.shared.isProtectedDataAvailable,
              child?.presented != true, household.projection?.grantId == nil,
              pickup.pantryRouteAvailable || retainingPrompt, pickup.sourceWorkspaceID == origin,
              model.phase == .ready, model.snapshot?.state.workspaceID == origin else { return nil }
        return .current(access: access, household: household)
    }
    private var boundScope: Bool {
        identity != nil && identity == currentIdentity && generation == pickup.privatePantryGeneration
    }

    private var authorized: Bool { boundScope && scene == .active }
    private var canRetainDictation: Bool {
        boundScope && model.canEdit && !working && startingLot == nil && basis == nil && saved == nil
    }

    var body: some View {
        Form {
            if !boundScope {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if model.pending != nil {
                Text(pantryText("The save result is uncertain. Retry the same reviewed change before starting another."))
                Button(pantryText("Review pending save")) { dismiss() }
            } else if let saved {
                savedSection(saved)
            } else {
                if startingLot == nil {
                    Section(pantryText("Your words")) {
                        TextField(pantryText("What did you use, or what would you like to check?"),
                                  text: Binding(get: { draft }, set: { draft = $0; resetReview() }), axis: .vertical)
                            .lineLimit(2...6).focused($editing)
                            .accessibilityIdentifier("pantry.voiceText")
                            .disabled(working || !model.canEdit)
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
                    Button(pantryText("Review my words")) { parse() }
                        .disabled(!model.canEdit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("pantry.voiceReview")
                } else if let review {
                    previewSection(review)
                } else {
                    ForEach(rows.indices, id: \.self) { index in
                        choiceSection(index)
                    }
                    if dateOnly {
                        dateSection
                    } else {
                        Button(pantryText("Preview pantry changes")) { Task { await prepare() } }
                            .disabled(!readyToReview)
                            .accessibilityIdentifier("pantry.voicePreview")
                    }
                }
                if let message { Text(message).accessibilityIdentifier("pantry.voiceStatus") }
                if working { ProgressView(pantryText("Working…")) }
            }
        }
        .navigationTitle(pantryText("Talk or type about pantry food"))
        .privacySensitive()
        .keyboardDoneAction(visible: editing, title: pantryText("Done"), identifier: "pantry.voiceKeyboardDone") { editing = false }
        .toolbar {
            if saved == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(pantryText("Cancel")) { erase(); dismiss() }.disabled(working)
                        .accessibilityIdentifier("pantry.voiceCancel")
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
        .onChange(of: canRetainDictation) { _, allowed in if !allowed { voice.cancel() } }
        .onChange(of: boundScope) { _, allowed in if !allowed { erase() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in erase() }
        .onChange(of: model.snapshot?.state.revision) { _, _ in
            if !working, basis != nil, model.snapshot?.state != basis { resetReview(); message = pantryNotice(.stale) }
        }
        .onDisappear {
            // A pushed shopping/reminder handoff still needs its saved lot and live identity.
            voice.cancel()
            draft = ""; resetReview()
        }
    }

    private func resetReview() {
        token = UUID(); basis = nil; rows = []; review = nil; dateOnly = false
        dateEvidence = nil; message = nil; working = false
    }

    private func erase() {
        voice.cancel()
        draft = ""; resetReview(); saved = nil; savedRevision = nil; identity = nil; generation = nil; editing = false
    }

    private func parse() {
        guard authorized, model.canEdit, let snapshot = model.snapshot else { return }
        voice.cancel()
        editing = false; resetReview()
        switch PantryVoiceParser.parse(draft, localeIdentifier: locale.identifier) {
        case .consume(let items):
            rows = items.map { item in
                var row = VoicePantryRow(food: item.food, original: item.original, mode: .remaining)
                switch item.amount {
                case .measured(let q): row.mode = .amount; row.amount = q.amount.description; row.unit = q.unit
                case .pieces(let n, _): row.mode = .amount; row.amount = n.description; row.spokenDimension = .count
                case .all: row.mode = .all
                case .someUsed: row.mode = .usedSome
                case .unknown: break
                }
                return row
            }
        case .askRemaining(let food, let original):
            rows = [.init(food: food ?? "", original: original, mode: .remaining)]
        case .observation(let observation):
            var row = VoicePantryRow(food: observation.food, original: observation.original, reportsUse: false, mode: .remaining)
            if case .empty = observation.remaining { row.mode = .all }
            else { row.estimate = observation.remainingWording }
            rows = [row]
        case .dateQuery(let food):
            dateOnly = true; rows = [.init(food: food, original: draft, mode: .skip)]
        case .needsReview:
            message = pantryText("Edit your words and try again. Include the food and what you used, what remains, or the date you want to check.")
            return
        }
        for index in rows.indices where !rows[index].food.isEmpty {
            if let lot = PantryVoiceBatchMatcher.uniqueExact(for: rows[index].food, in: snapshot.lots) {
                rows[index].choose(lot)
            }
        }
        basis = snapshot.state
    }

    private var lots: [InventoryLot] { model.snapshot?.lots ?? [] }

    private func lotLabel(_ lot: InventoryLot) -> String {
        [lot.name, pantryLocationName(lot.location), pantryCount(lot.count),
         pantryFormat("Batch %@", String(lot.id.uuidString.suffix(8)))].joined(separator: " · ")
    }

    private func change(_ index: Int, _ update: (inout VoicePantryRow) -> Void) {
        guard authorized, !working, rows.indices.contains(index) else { return }
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
            Text(row.original).accessibilityIdentifier("pantry.voiceOriginal.\(index)")
            if let startingLot {
                Text(lotLabel(startingLot))
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
                    LabeledContent(pantryText("Pantry batch"), value: selected.map(lotLabel) ?? pantryText("Choose a batch"))
                }
                .accessibilityIdentifier("pantry.voiceLot.\(index)")
            }
            if unmatched && !dateOnly && row.mode != .skip {
                Button(pantryText("Leave this item unchanged")) { change(index) { $0.mode = .skip } }
                    .accessibilityIdentifier("pantry.voiceSkip.\(index)")
            }
            if lots.isEmpty { Text(pantryText("Add a pantry batch before reviewing these words.")) }
            if !dateOnly { amountChoices(index, row: row, lot: selected) }
        } header: {
            if let selected { Text(selected.name) }
            else { Text(unnamed ? pantryText("Which pantry batch?") : pantryFormat("Which %@?", row.food)) }
        }
        .disabled(working || !model.canEdit)
    }

    @ViewBuilder private func amountChoices(_ index: Int, row: VoicePantryRow, lot: InventoryLot?) -> some View {
        if row.mode == .amount {
            TextField(pantryText("Amount used"), text: Binding(get: { row.amount }, set: { text in change(index) { $0.amount = text } }))
                .focused($editing).accessibilityIdentifier("pantry.voiceAmount.\(index)")
            Menu {
                ForEach(UnitOfMeasure.allCases.filter { $0.dimension == lot?.unit.dimension }, id: \.self) { unit in
                    Button(pantryUnit(unit)) { change(index) { $0.unit = unit } }
                }
            } label: {
                LabeledContent(pantryText("Unit"), value: row.unit.map { pantryUnit($0) } ?? pantryText("Choose a unit"))
            }
            .disabled(lot == nil).accessibilityIdentifier("pantry.voiceUnit.\(index)")
        } else if row.mode == .remaining {
            Text(pantryText("How much is left?"))
            if !row.estimate.isEmpty {
                LabeledContent(pantryText("Remaining estimate"), value: row.estimate)
                    .accessibilityIdentifier("pantry.voiceEstimate.\(index)")
            }
        } else if row.mode == .all {
            Text(row.reportsUse ? pantryText("Used all of the selected batch") : pantryText("The selected batch is empty"))
        } else if row.mode == .usedSome {
            Text(pantryText("How much is left?"))
            Text(pantryText("Record one use. The amount remaining will be unknown."))
        } else {
            Text(pantryText("Not sure — leave this batch unchanged"))
        }
        Menu {
            ForEach(["About half left", "Less than half left", "Nearly empty"], id: \.self) { key in
                Button(pantryText(key)) { change(index) { $0.mode = .remaining; $0.estimate = pantryText(key) } }
            }
            Button(pantryText("Used it all")) { change(index) { $0.mode = .all; $0.reportsUse = true } }
            Button(pantryText("Not sure")) { change(index) { $0.mode = .skip } }
                .accessibilityIdentifier("pantry.voiceNotSure.\(index)")
        } label: {
            Text(pantryText("Choose how much is left"))
        }
        .accessibilityIdentifier("pantry.voiceRemaining.\(index)")
        if row.mode != .usedSome {
            Button(pantryText("Used some")) { change(index) { $0.mode = .usedSome; $0.reportsUse = true } }
                .accessibilityIdentifier("pantry.voiceSome.\(index)")
        }
        if row.mode != .amount {
            Button(pantryText("Enter amount used")) { change(index) { $0.mode = .amount; $0.reportsUse = true } }
                .accessibilityIdentifier("pantry.voiceUseAmount.\(index)")
        }
    }

    private var readyToReview: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.mode == .skip || $0.selection != nil } &&
        !working && authorized && model.canEdit && basis == model.snapshot?.state
    }

    private func prepare() async {
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
            review = result; message = nil
        } catch { handle(error, request: request) }
    }

    private func previewSection(_ review: PantryConsumptionReview) -> some View {
        Section(pantryText("Review pantry changes")) {
            ForEach(Array(review.lines.enumerated()), id: \.offset) { index, line in
                VStack(alignment: .leading, spacing: 6) {
                    Text(lotLabel(line.lot)).font(.headline)
                    LabeledContent(pantryText("Previously recorded"), value: pantryCount(line.before))
                    if let used = line.used { LabeledContent(pantryText("Amount used"), value: pantryQuantity(used)) }
                    LabeledContent(pantryText("After this change"), value: pantryCount(line.after))
                    if let selection = review.entry.consumption?.selections[index] {
                        switch selection.use {
                        case .low(let wording): Text(pantryFormat("Remaining estimate: %@", wording))
                        case .usedSome(let wording):
                            Text(pantryText("Used some"))
                            if let wording { Text(pantryFormat("Remaining estimate: %@", wording)) }
                        case .all: Text(pantryText("Used all of the selected batch"))
                        case .empty: Text(pantryText("The selected batch is empty"))
                        case .amount, .unknown: EmptyView()
                        }
                    }
                }.accessibilityElement(children: .combine)
                .accessibilityIdentifier("pantry.voiceSummary.\(index)")
            }
            ForEach(rows.indices.filter { rows[$0].mode == .skip }, id: \.self) { index in
                Text(pantryFormat("Left unchanged: %@", rows[index].original))
            }
            Button(pantryText("Edit choices")) { self.review = nil; message = nil }
                .accessibilityIdentifier("pantry.voiceEdit")
            Button(pantryText("Confirm pantry changes")) { Task { await save(review) } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pantry.voiceConfirm")
        }.disabled(working || !model.canEdit)
    }

    private func save(_ review: PantryConsumptionReview) async {
        guard authorized, !working, model.canEdit, basis == model.snapshot?.state else { return }
        let request = token
        working = true
        defer { if request == token { working = false } }
        do {
            try await model.saveConsumption(review)
            guard request == token, authorized else { return }
            let selectedIDs = rows.filter { $0.mode == .remaining || $0.mode == .all }.compactMap(\.lotID)
            saved = selectedIDs.compactMap { id in lots.first { $0.id == id } }
            savedRevision = model.snapshot?.state.revision
            draft = ""; resetReview()
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
            Text(pantryText("Food saved on this device.")).accessibilityIdentifier("pantry.voiceSaved")
            ForEach(Array(saved.enumerated()), id: \.element.id) { index, lot in
                if let wording = lot.countWording {
                    Text(pantryFormat("%@ · Remaining estimate: %@", lot.name, wording))
                        .accessibilityIdentifier("pantry.voiceSavedWording.\(index)")
                } else {
                    Text(pantryFormat("%@ · %@", lot.name, pantryCount(lot.count)))
                }
                PantryRestockActions(model: model, lot: lot, sourceCurrent: {
                    authorized && model.canEdit && savedRevision == model.snapshot?.state.revision &&
                        model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot
                })
            }
            Button(pantryText("Done")) { dismiss() }
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
                VStack(alignment: .leading, spacing: 8) {
                    if let printed = evidence.printed {
                        Text(pantryText("Printed package date")).font(.headline)
                        Text(printed.meaning.label)
                        Text(printed.wording)
                        if let day = printed.day {
                            Text(PantryVoiceDateEvidence.formatted(day, locale: locale))
                            if let today = try? MealDay(date: context.date, timeZoneIdentifier: day.timeZoneIdentifier) {
                                if day.iso8601 == today.iso8601 { Text(pantryText("The printed date is today.")) }
                                else if day.iso8601 < today.iso8601 { Text(pantryText("The printed date has passed.")) }
                            }
                        }
                    } else { Text(pantryText("No verified printed package date available.")) }
                    if let quality = evidence.quality {
                        Text(pantryText("FoodKeeper quality range")).font(.headline)
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
        List {
            if revision == nil { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
            else if loadedRevision == revision, let entries {
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
                        Text(row.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        switch row.kind {
                        case .measured(let quantity): LabeledContent(pantryText("Amount used"), value: pantryQuantity(quantity))
                        case .some: Text(pantryText("Used some"))
                        case .all: Text(pantryText("Used all of the selected batch"))
                        }
                        if let wording = row.remainingWording { Text(pantryFormat("Remaining estimate: %@", wording)) }
                    }.accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pantry.usageEvent.\(index)")
                }
            } else if failed {
                Button(pantryText("Retry usage history")) { Task { await read() } }
            } else { ProgressView(pantryText("Working…")) }
        }
        .navigationTitle(pantryText("Usage history"))
        .privacySensitive()
        .task(id: revision) { await read() }
        .onDisappear { entries = nil; loadedRevision = nil }
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
