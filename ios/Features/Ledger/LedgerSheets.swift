import SwiftUI
import CoreDomain

struct LedgerImportView: View {
    @ObservedObject var model: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    let shopID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var original = ""
    @State private var preview: StagedListImport?
    @State private var choices: [UUID: ImportResolution] = [:]
    @State private var explicitSeparate: Set<UUID> = []
    @State private var matchesAreCurrent = true
    @State private var source: ImportSource = .typed
    @State private var importID = UUID()
    @State private var captured: ReviewedCapture?
    @State private var captureBinding: LedgerCaptureBinding?
    @State private var capturePresentation: LedgerCapturePresentation?
    @ScaledMetric(relativeTo: .body) private var importEditorHeight: CGFloat = 180
    @FocusState private var originalFocused: Bool
    private enum Focus: Hashable { case preview, status }
    @AccessibilityFocusState private var focus: Focus?
    private var shop: ShoppingLedger? { model.workspace.shops.first { $0.id == shopID } }

    var body: some View {
        let review = preview.map { LedgerImportReview(shop: shop, preview: $0, choices: choices) }
        return ScrollViewReader { scroll in
            Form {
                if showingImportStatus {
                    Section { importSaveStatus }
                        .id("ledgerImportSaveStatus")
                }
                if let preview, let review {
                    Section(ledgerText("Original wording")) {
                        Text(original).textSelection(.enabled).accessibilityFocused($focus, equals: .preview)
                        if let data = captured?.previewImageData ?? captured?.sourceImageData, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                                .accessibilityLabel(captureText("Selected source photo"))
                        }
                    }
                    Section {
                        ForEach(Array(preview.lines.enumerated()), id: \.element.id) { index, row in
                            LedgerImportRowView(number: index + 1, line: rowBinding(row, at: index, previewID: preview.id),
                                                matches: review.matches[row.id] ?? [],
                                                choice: Binding(get: { review.choices[row.id] },
                                                                set: { setChoice($0, for: row.id) }),
                                                onEdited: { refreshMatches() })
                        }
                    } header: { Text(ledgerText("Review every line")) } footer: {
                        Text(ledgerText("Merge confirms the same need. Add amount keeps an additional contribution. Unresolved amounts remain visibly unknown."))
                    }.disabled(model.saving || model.hasPendingSave)
                    Section {

                        if captured != nil {
                            Button(captureText("Edit captured fields")) { beginCapture() }
                                .disabled(model.saving || model.hasPendingSave || !captureAuthorized)
                        } else {
                            Button(ledgerText("Edit original text")) { self.preview = nil; choices = [:]; importID = UUID() }
                                .disabled(model.saving || model.hasPendingSave)
                        }
                    }
                } else {
                    Section {
                        Text(ledgerText("One item per line. For example: 12 wraps or 2 kg rice."))
                        TextEditor(text: $original)
                            .frame(height: min(importEditorHeight, 240))
                            .focused($originalFocused)
                            .accessibilityLabel(ledgerText("List to review")).accessibilityIdentifier("ledgerImportText")
                        PasteButton(payloadType: String.self) { values in
                            original = values.joined(separator: "\n")
                            source = .paste
                        }.accessibilityLabel(ledgerText("Paste list"))
                    }.disabled(model.saving || model.hasPendingSave)
                    Section {
                        Button(captureText("Capture and review fields")) { beginCapture() }
                            .disabled(model.saving || model.hasPendingSave || liveCaptureBinding == nil)
                            .accessibilityIdentifier("ledger.capture")
                        Text(captureText("Capture is for this private list. Guest changes use the dinner preview.")).font(.footnote)
                        Button(ledgerText("Review list")) {
                            guard let shop else { return }
                            originalFocused = false
                            let staged = shop.stageImport(text: original, source: source, importID: importID)
                            preview = staged
                            choices = LedgerImportReview.initialChoices(staged)
                            explicitSeparate = []
                            matchesAreCurrent = true
                            focus = .preview
                        }.buttonStyle(PrimaryAction()).disabled(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("ledgerReviewImport")
                    }
                }
                if !showingImportStatus {
                    Section { importSaveStatus }
                }
            }.accessibilityIdentifier("ledgerImportForm")
                .scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Bring the list"))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let preview, let review {
                        importConfirmation(preview, review: review)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(Theme.canvas)
                    }
                }
                .keyboardDoneAction(visible: originalFocused, title: ledgerText("Done")) { originalFocused = false }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
                .interactiveDismissDisabled(model.saving)
                .sheet(item: $capturePresentation) { presentation in
                    let binding = presentation.binding
                    NavigationStack {
                        CaptureReviewView(initialText: presentation.text, initialSource: presentation.source, localeIdentifier: binding.localeIdentifier,
                            destination: presentation.destination, existingCapture: presentation.reviewed,
                            correctionScope: CaptureCorrectionScope(profileID: "local:" + binding.workspaceID.uuidString, localeIdentifier: binding.localeIdentifier),
                            authorize: { liveCaptureBinding == binding }, onReviewed: { receiveCapture($0, binding: binding) })
                    }
                }
                .onChange(of: liveCaptureBinding) { _, current in
                    if let binding = capturePresentation?.binding ?? captureBinding, current != binding { invalidateCapture() }
                }
                .onChange(of: scenePhase) { _, phase in if phase == .background { invalidateCapture() } }
                .task(id: ImportStatusFocusKey(previewID: preview?.id, error: model.error,
                                               saving: model.saving, pending: model.hasPendingSave)) {
                    guard showingImportStatus else { return }
                    // Let the newly inserted status section mount before scrolling to it.
                    await Task.yield()
                    guard !Task.isCancelled, showingImportStatus else { return }
                    scroll.scrollTo("ledgerImportSaveStatus", anchor: .top)
                    focus = .status
                }
        }
    }

    private struct ImportStatusFocusKey: Equatable {
        let previewID: UUID?
        let error: String?
        let saving: Bool
        let pending: Bool
    }

    private var showingImportStatus: Bool {
        preview != nil && (model.saving || model.hasPendingSave || model.error != nil)
    }

    private var importSaveStatus: some View {
        LedgerSaveStatus(model: model, onRetried: { dismiss() })
            .accessibilityFocused($focus, equals: .status)
    }

    private func importConfirmation(_ preview: StagedListImport, review: LedgerImportReview) -> some View {
        Button(ledgerText("Add reviewed list")) {
            Task {
                guard captured == nil || captureAuthorized else {
                    model.error = captureText("This capture belongs to an earlier workspace or list revision. Review it again before adding anything.")
                    focus = .status; return
                }
                let decisions = review.choices
                if await model.editShop(key: "import-\(preview.id)", shopID: shopID, { try $0.commitImport(preview, decisions: decisions) }) {
                    dismiss()
                } else { focus = .status }
            }
        }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave || !matchesAreCurrent || !review.isComplete)
            .accessibilityIdentifier("ledgerCommitImport")
    }

    private var liveCaptureBinding: LedgerCaptureBinding? {
        guard access.unlocked, !household.locked, model.ready,
              !model.hasPendingLedgerDeletion, let workspaceID = model.sourceWorkspaceID,
              let shop, model.workspace.selectedShopID == shopID else { return nil }
        if let projection = household.projection {
            guard household.identity != nil, projection.enrolled, ["shopper", "organizer"].contains(projection.role) else { return nil }
        } else if household.identity != nil { return nil }
        return LedgerCaptureBinding(workspaceID: workspaceID, shopID: shopID, revision: shop.revision,
            actorID: access.localActorID, subject: household.identity?.subject,
            householdID: household.projection?.household.id, memberID: household.projection?.memberId,
            role: household.projection?.role, localeIdentifier: locale.identifier)
    }
    private var captureAuthorized: Bool { captureBinding != nil && liveCaptureBinding == captureBinding }
    private func beginCapture() {
        guard let binding = liveCaptureBinding, let shop, !model.saving, !model.hasPendingSave else { return }
        originalFocused = false
        capturePresentation = LedgerCapturePresentation(binding: binding, destination: shop.title,
            text: original, source: source == .paste ? .paste : .typed, reviewed: captured)
    }
    private func receiveCapture(_ capture: ReviewedCapture, binding: LedgerCaptureBinding) {
        guard liveCaptureBinding == binding, !model.saving, !model.hasPendingSave, let shop else { return }
        do {
            let staged = try CaptureLedgerImport.stage(capture, in: shop)
            if staged.alreadyApplied { capturePresentation = nil; dismiss(); return }
            captureBinding = binding
            captured = capture; importID = capture.id; original = capture.originalText
            source = staged.preview.source; preview = staged.preview
            choices = LedgerImportReview.initialChoices(staged.preview)
            explicitSeparate = []
            matchesAreCurrent = true
            capturePresentation = nil; focus = .preview; model.error = nil
        } catch {
            model.error = captureText("Review each item. Use a positive amount or leave it explicitly unknown; pack counts must be whole numbers.")
            focus = .status
        }
    }
    private func invalidateCapture() {
        guard capturePresentation != nil || captureBinding != nil else { return }
        capturePresentation = nil; captured = nil; captureBinding = nil
        preview = nil; choices = [:]; original = ""; importID = UUID()
    }

    private func rowBinding(_ row: StagedImportLine, at index: Int, previewID: UUID) -> Binding<StagedImportLine> {
        Binding(get: {
            guard let preview, preview.id == previewID, preview.lines.indices.contains(index),
                  preview.lines[index].id == row.id else { return row }
            return preview.lines[index]
        }, set: { updated in
            guard updated.id == row.id, preview?.id == previewID,
                  preview?.lines.indices.contains(index) == true, preview?.lines[index].id == row.id else { return }
            preview?.lines[index] = updated
        })
    }

    private func setChoice(_ value: ImportResolution?, for id: UUID) {
        guard let preview, let shop else { return }
        var next = choices
        next[id] = value
        if value == .addNew { explicitSeparate.insert(id) } else { explicitSeparate.remove(id) }
        choices = LedgerImportReview(shop: shop, preview: preview, choices: next).choices
    }

    private func refreshMatches() {
        guard let shop, let preview else { return }
        matchesAreCurrent = false
        if preview.lines.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return }
        do {
            let refreshed = try shop.refreshImportMatches(preview)
            choices = LedgerImportReview.afterEdit(from: preview, to: refreshed, shop: shop,
                                                   choices: choices, explicitSeparate: explicitSeparate)
            self.preview = refreshed
            matchesAreCurrent = true
            model.error = nil
        } catch LedgerError.stalePreview {
            model.error = ledgerText("This pickup changed after your preview. Return to the original text and review it again before adding it.")
        } catch {
            model.error = ledgerText("Check the amounts, units and links. This change could not be applied; your saved pickup is unchanged.")
        }
    }
}

private struct LedgerCaptureBinding: Equatable {
    let workspaceID: UUID
    let shopID: UUID
    let revision: Int
    let actorID: UUID
    let subject: String?
    let householdID: String?
    let memberID: String?
    let role: String?
    let localeIdentifier: String
}

private struct LedgerCapturePresentation: Identifiable {
    let id = UUID()
    let binding: LedgerCaptureBinding
    let destination: String
    let text: String
    let source: CaptureSource
    let reviewed: ReviewedCapture?
}

struct LedgerImportReview {
    struct Match: Identifiable {
        let option: ImportMatchOption
        let name: String
        var id: UUID { option.lineID }
    }

    var matches: [UUID: [Match]] = [:]
    var choices: [UUID: ImportResolution]
    let isComplete: Bool

    static func initialChoices(_ preview: StagedListImport) -> [UUID: ImportResolution] {
        Dictionary(uniqueKeysWithValues: preview.lines.filter { $0.duplicateLineIDs.isEmpty }.map { ($0.id, .addNew) })
    }

    static func afterEdit(from previous: StagedListImport, to preview: StagedListImport, shop: ShoppingLedger,
                          choices: [UUID: ImportResolution], explicitSeparate: Set<UUID>) -> [UUID: ImportResolution] {
        var updated = choices
        for (old, row) in zip(previous.lines, preview.lines)
        where old.duplicateLineIDs.isEmpty && !row.duplicateLineIDs.isEmpty && updated[row.id] == .addNew && !explicitSeparate.contains(row.id) {
            updated[row.id] = nil
        }
        return Self(shop: shop, preview: preview, choices: updated).choices
    }

    init(shop: ShoppingLedger?, preview: StagedListImport, choices: [UUID: ImportResolution]) {
        self.choices = choices
        guard let shop, shop.id == preview.shopID, shop.revision == preview.baseRevision else {
            self.choices = choices.filter { $0.value == .skip || $0.value == .addNew }
            isComplete = false
            return
        }
        // An invalidated link stays undecided even if its target was renamed away.
        // It must not supply a new target for a later row before another review.
        var projected = choices
        for row in preview.lines where choices[row.id] == nil && row.duplicateLineIDs.isEmpty {
            projected[row.id] = .skip
        }
        let options = shop.importMatchOptions(for: preview, decisions: projected)
        if !options.isEmpty {
            var targets = Set<UUID>()
            for candidates in options.values { targets.formUnion(candidates.lazy.map(\.lineID)) }
            var labels: [UUID: String] = [:]
            for line in shop.lines where targets.contains(line.id) {
                labels[line.id] = ledgerFormat("Item %lld: %@", Int64(line.originalOrder + 1), line.name)
            }
            for (index, row) in preview.lines.enumerated() where targets.contains(row.proposedLineID) {
                labels[row.proposedLineID] = ledgerFormat("Preview line %lld: %@", Int64(index + 1), row.name)
            }
            matches = options.mapValues { candidates in
                candidates.compactMap { candidate in labels[candidate.lineID].map { Match(option: candidate, name: $0) } }
            }
        }
        for (id, choice) in choices {
            switch choice {
            case .mergeDuplicate(let target) where options[id]?.contains(where: { $0.lineID == target && $0.canMerge }) != true:
                self.choices[id] = nil
            case .addToLine(let target) where options[id]?.contains(where: { $0.lineID == target && $0.canAdd }) != true:
                self.choices[id] = nil
            default: break
            }
        }
        let retained = self.choices
        isComplete = !preview.lines.isEmpty && preview.lines.allSatisfy {
            retained[$0.id] != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct LedgerImportResolutionPicker: View {
    let identifier: String
    let matches: [LedgerImportReview.Match]
    @Binding var choice: ImportResolution?
    var body: some View {
        if !matches.isEmpty && !matches.contains(where: { $0.option.canMerge || $0.option.canAdd }) {
            Text(ledgerText("The matching items cannot take this amount. Choose a separate line or skip it."))
                .font(.subheadline)
        }
        Picker(ledgerText("How to add this line"), selection: $choice) {
            if choice == nil { Text(ledgerText("Choose how to add")).tag(nil as ImportResolution?) }
            Text(ledgerText("Add as a separate line")).tag(ImportResolution.addNew as ImportResolution?)
            ForEach(matches) { match in
                if match.option.canMerge {
                    Text(ledgerFormat("Merge same need: %@", match.name)).tag(ImportResolution.mergeDuplicate(match.id) as ImportResolution?)
                }
                if match.option.canAdd {
                    Text(ledgerFormat("Add amount to: %@", match.name)).tag(ImportResolution.addToLine(match.id) as ImportResolution?)
                }
            }
            Text(ledgerText("Skip this line")).tag(ImportResolution.skip as ImportResolution?)
        }.pickerStyle(.menu).accessibilityIdentifier(identifier)
    }
}

struct LedgerPackLabelFacts: View {
    let pack: ListQuantityParser.PackLabel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let count = pack.count { Text(ledgerFormat("Packs on the original label: %lld", Int64(count))) }
            Text(ledgerFormat("Amount per pack on the original label: %@", ledgerQuantity(pack.amountPerPack)))
        }.font(.footnote)
    }
}

private struct LedgerImportRowView: View {
    let number: Int
    @Binding var line: StagedImportLine
    let matches: [LedgerImportReview.Match]
    @Binding var choice: ImportResolution?
    let onEdited: () -> Void
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    init(number: Int, line: Binding<StagedImportLine>, matches: [LedgerImportReview.Match], choice: Binding<ImportResolution?>, onEdited: @escaping () -> Void) {
        self.number = number
        _line = line
        self.matches = matches
        _choice = choice
        self.onEdited = onEdited
        _amount = State(initialValue: line.wrappedValue.quantity.map { ledgerAmountInput($0.amount) } ?? "")
        _unit = State(initialValue: line.wrappedValue.quantity?.unit ?? .count)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(line.originalText).font(.caption).foregroundStyle(Theme.secondary)
            if let pack = line.originalPack { LedgerPackLabelFacts(pack: pack) }
            if let capture = line.capture {
                Text(line.name).font(.headline)
                if let quantity = line.quantity { Text(ledgerAmountInput(quantity.amount) + " " + quantity.unit.displayName) }
                if let count = capture.packCount { Text(captureText("Packs") + ": " + String(count)) }
                if let amount = capture.amountPerPack { Text(captureText("Usable amount per pack") + ": " + ledgerAmountInput(amount.amount) + " " + amount.unit.displayName) }
                Text(captureText("Purpose") + ": " + capture.purpose)
                Text(captureText("Destination") + ": " + capture.destination)
                if !line.exclusions.isEmpty { Text(captureText("Exclusions") + ": " + line.exclusions.joined(separator: "; ")) }
            } else {
            TextField(ledgerText("Item name"), text: $line.name, axis: .vertical)
            TextField(ledgerText("Amount, unknown if blank"), text: $amount).keyboardType(.decimalPad)
                .accessibilityIdentifier("ledgerImportAmount-\(number)")
            Picker(ledgerText("Unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            }
            if line.quantity == nil {
                Label(ledgerText("Quantity unresolved"), systemImage: "questionmark.circle").foregroundStyle(Theme.warning)
                if let reason = line.unresolvedReason { Text(ledgerContributionNote(reason)).font(.footnote) }
            }
            if matches.contains(where: { $0.option.canMerge }) && matches.contains(where: { $0.option.canAdd }) {
                Text(ledgerText("A matching item is already listed. Is this the same need or an additional amount?"))
                    .font(.subheadline)
            }
            LedgerImportResolutionPicker(identifier: "ledgerImportResolution-\(number)", matches: matches, choice: $choice)
        }.padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            .onChange(of: amount) { _, _ in updateQuantity() }
            .onChange(of: unit) { _, _ in updateQuantity() }
            .onChange(of: line.name) { _, _ in onEdited() }
    }
    private func updateQuantity() {
        line.quantity = try? LedgerEntry.quantity(amount, unit)
        line.unresolvedReason = line.quantity == nil ? "quantityUnknown" : nil
        onEdited()
    }
}

struct LedgerFactsView: View {
    @ObservedObject var model: LedgerModel
    @State private var original: ShoppingLedger
    @Environment(\.dismiss) private var dismiss
    @State private var basis: ShopBasis
    @State private var cap: String
    @State private var reserve: String
    @State private var fees: String
    @State private var hasRetailerPreview: Bool
    @State private var retailerTotal: String
    @State private var retailerSource: String
    @State private var retailerDate: Date
    @State private var includedCharges: String
    @State private var hasSlot: Bool
    @State private var slot: Date
    @State private var reviewing = false
    @State private var workspaceID: UUID?
    @State private var evidenceTerms: ShopBasis.RetailerTerms
    @State private var validation: String?
    private enum Input: Hashable { case branch, timeZone, cap, reserve, fees, retailerTotal, retailerSource, includedCharges }
    @FocusState private var inputFocus: Input?
    init(model: LedgerModel, shop: ShoppingLedger) {
        self.model = model
        _original = State(initialValue: shop)
        _workspaceID = State(initialValue: model.sourceWorkspaceID)
        _evidenceTerms = State(initialValue: shop.basis.retailerTerms)
        _basis = State(initialValue: shop.basis)
        _cap = State(initialValue: shop.basis.cap.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _reserve = State(initialValue: shop.basis.fixedReserve.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _fees = State(initialValue: shop.basis.knownFees.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _hasRetailerPreview = State(initialValue: shop.basis.retailerPreview != nil)
        _retailerTotal = State(initialValue: shop.basis.retailerPreview?.total.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _retailerSource = State(initialValue: shop.basis.retailerPreview?.source ?? "")
        _retailerDate = State(initialValue: shop.basis.retailerPreview?.capturedAt ?? Date())
        _includedCharges = State(initialValue: shop.basis.retailerPreview?.includedCharges.joined(separator: ", ") ?? "")
        _hasSlot = State(initialValue: shop.basis.slot != nil)
        _slot = State(initialValue: shop.basis.slot ?? Date())
    }
    private var currentTerms: ShopBasis.RetailerTerms {
        var edited = basis
        edited.slot = hasSlot ? slot : nil
        return edited.retailerTerms
    }
    private var isCurrent: Bool {
        workspaceID != nil && model.sourceWorkspaceID == workspaceID && model.shop?.id == original.id
            && model.shop?.revisionID == original.revisionID
    }
    private var needsFreshEvidence: Bool {
        currentTerms != evidenceTerms && (hasRetailerPreview || !fees.isEmpty || !retailerSource.isEmpty
            || !retailerTotal.isEmpty || !includedCharges.isEmpty)
    }
    var body: some View {
        Form {
            if !isCurrent {
                Text(ledgerText("This pickup changed. Close these edits and reopen the current pickup details."))
                Button(ledgerText("Close")) { dismiss() }
            } else if reviewing {
                Section(ledgerText("Previously saved")) { summary(original.basis) }
                Section(ledgerText("Proposed pickup details")) { summary(basis) }
                Section {
                    Text(ledgerText("Changing the store, mode, date or costs invalidates earlier pickup quotes. Review them again before relying on a total."))
                    Button(ledgerText("Save pickup details")) {
                        Task { if await model.editShop(key: "basis-\(original.id)", shopID: original.id, {
                            guard isCurrent else { throw LedgerError.stalePreview }
                            try $0.updateBasis(basis, evidenceFor: evidenceTerms, reviewing: original.revisionID)
                        }) { dismiss() } }
                    }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("ledgerCommitFacts")
                    Button(ledgerText("Keep editing")) { reviewing = false }.disabled(model.saving || model.hasPendingSave)
                }
            } else {
                Section(ledgerText("Store and timing")) {
                    TextField(ledgerText("Store branch"), text: $basis.branch, axis: .vertical).accessibilityIdentifier("ledgerBranch")
                        .focused($inputFocus, equals: .branch)
                    Picker(ledgerText("How you will shop"), selection: $basis.mode) {
                        Text(FulfillmentMode.pickup.ledgerLabel).tag(FulfillmentMode.pickup)
                        Text(FulfillmentMode.delivery.ledgerLabel).tag(FulfillmentMode.delivery)
                        Text(FulfillmentMode.inStore.ledgerLabel).tag(FulfillmentMode.inStore)
                    }
                    Toggle(ledgerText("Set a pickup date and time"), isOn: $hasSlot)
                    if hasSlot {
                        DatePicker(ledgerText("Pickup date and time"), selection: $slot)
                            .environment(\.timeZone, TimeZone(identifier: basis.timeZoneIdentifier) ?? .current)
                    }
                    TextField(ledgerText("Time zone, for example America/New_York"), text: $basis.timeZoneIdentifier)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($inputFocus, equals: .timeZone)
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    TextField(ledgerText("Spending cap (USD, optional)"), text: $cap).keyboardType(.decimalPad)
                        .accessibilityIdentifier("ledgerCap")
                        .focused($inputFocus, equals: .cap)
                    Picker(ledgerText("What the cap covers"), selection: $basis.capScope) {
                        Text(BudgetScope.wholeShop.ledgerLabel).tag(BudgetScope.wholeShop)
                        Text(BudgetScope.dinnersOnly.ledgerLabel).tag(BudgetScope.dinnersOnly)
                        Text(BudgetScope.selectedItems.ledgerLabel).tag(BudgetScope.selectedItems)
                    }
                    Picker(ledgerText("How firm is this cap?"), selection: $basis.capFirmness) {
                        Text(ledgerText("Firm limit")).tag(CapFirmness.firm)
                        Text(ledgerText("Flexible limit")).tag(CapFirmness.flexible)
                    }
                    TextField(ledgerText("Fixed reserve (USD, optional)"), text: $reserve).keyboardType(.decimalPad)
                        .focused($inputFocus, equals: .reserve)
                    if !needsFreshEvidence {
                        TextField(ledgerText("Known fees (USD, unknown if blank)"), text: $fees).keyboardType(.decimalPad)
                            .focused($inputFocus, equals: .fees)
                    }
                    Text(ledgerText("Currency: USD"))
                } header: { Text(ledgerText("Spending cap")) } footer: {
                    Text(ledgerText("A dinner-only cap does not cover the whole pickup. Missing prices and fees remain unknown."))
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    if needsFreshEvidence {
                        Text(ledgerText("Earlier fees and retailer evidence belong to different pickup details. The proposed fees and preview are unknown."))
                        Button(ledgerText("Enter evidence for these pickup details")) {
                            fees = ""; hasRetailerPreview = false; retailerTotal = ""; retailerSource = ""
                            retailerDate = Date(); includedCharges = ""; evidenceTerms = currentTerms
                        }
                    } else {
                        Toggle(ledgerText("Record a retailer preview"), isOn: $hasRetailerPreview)
                    }
                    if hasRetailerPreview && !needsFreshEvidence {
                        TextField(ledgerText("Retailer total (USD, unknown if blank)"), text: $retailerTotal).keyboardType(.decimalPad)
                            .focused($inputFocus, equals: .retailerTotal)
                        TextField(ledgerText("Source of the retailer preview"), text: $retailerSource, axis: .vertical)
                            .focused($inputFocus, equals: .retailerSource)
                        DatePicker(ledgerText("When this preview was shown"), selection: $retailerDate)
                            .environment(\.timeZone, TimeZone(identifier: basis.timeZoneIdentifier) ?? .current)
                        TextField(ledgerText("Included charges, separated by commas"), text: $includedCharges, axis: .vertical)
                            .focused($inputFocus, equals: .includedCharges)
                        Text(ledgerText("This records what the retailer displayed. It is not a calculated whole-pickup quote."))
                    }
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    Button(ledgerText("Review pickup details")) { review() }
                        .buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("ledgerReviewFacts")
                }
            }
            if isCurrent {
                let history = original.revisions.reversed().filter { $0.previousRetailerBasis != nil }
                if !history.isEmpty {
                    DisclosureGroup(ledgerText("Earlier retailer evidence")) {
                        ForEach(history) { revision in
                            if let earlier = revision.previousRetailerBasis { summary(earlier); Divider() }
                        }
                    }
                }
            }
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Describe this pickup"))
            .onChange(of: currentTerms) { old, new in
                if old == evidenceTerms, !hasRetailerPreview, fees.isEmpty, retailerSource.isEmpty, retailerTotal.isEmpty, includedCharges.isEmpty {
                    evidenceTerms = new; retailerDate = Date()
                }
            }
            .keyboardDoneAction(visible: inputFocus != nil, title: ledgerText("Done"), identifier: "ledgerFactsKeyboardDone") { inputFocus = nil }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
    private func review() {
        inputFocus = nil
        do {
            guard TimeZone(identifier: basis.timeZoneIdentifier) != nil else {
                validation = ledgerText("Enter a valid time zone, such as America/New_York.")
                return
            }
            basis.cap = try ComparisonModel.money(cap)
            basis.fixedReserve = try ComparisonModel.money(reserve)
            basis.knownFees = needsFreshEvidence ? nil : try ComparisonModel.money(fees)
            if hasRetailerPreview && !needsFreshEvidence {
                let charges: [String]
                if let saved = original.basis.retailerPreview, currentTerms == original.basis.retailerTerms,
                   includedCharges == saved.includedCharges.joined(separator: ", ") {
                    charges = saved.includedCharges
                } else {
                    charges = includedCharges.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                }
                basis.retailerPreview = LedgerRetailerPreview(total: try ComparisonModel.money(retailerTotal), source: retailerSource,
                                                              capturedAt: retailerDate, includedCharges: charges)
            } else { basis.retailerPreview = nil }
            basis.slot = hasSlot ? slot : nil
            try basis.validate()
            guard isCurrent else { return }
            validation = nil
            reviewing = true
        } catch { validation = ledgerText("Use a nonnegative USD amount with no more than two decimal places.") }
    }
    private func summary(_ value: ShopBasis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.branch.isEmpty ? ledgerText("Store not set") : value.branch)
            Text(value.mode.ledgerLabel)
            if let date = value.slot { Text(ledgerDate(date, zone: value.timeZoneIdentifier)) }
            else { Text(ledgerText("Date not set")); Text(value.timeZoneIdentifier) }
            if let cap = value.cap { Text("\(moneyText(cap)) · \(value.capScope.ledgerLabel)") }
            else { Text(ledgerText("No spending cap entered")); Text(value.capScope.ledgerLabel) }
            Text(ledgerText(value.capFirmness == .firm ? "Firm limit" : "Flexible limit"))
            Text(ledgerFormat("Fixed reserve: %@", value.fixedReserve.map(moneyText) ?? ledgerText("Unknown")))
            Text(ledgerFormat("Fees: %@", value.knownFees.map(moneyText) ?? ledgerText("Unknown")))
            if let preview = value.retailerPreview {
                Text(ledgerFormat("Retailer preview: %@", preview.total.map(moneyText) ?? ledgerText("Unknown")))
                Text(preview.source)
                Text(ledgerDate(preview.capturedAt, zone: value.timeZoneIdentifier))
                Text(ledgerFormat("Included charges: %@", preview.includedCharges.joined(separator: ", ")))
            } else { Text(ledgerFormat("Retailer preview: %@", ledgerText("Unknown"))) }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
