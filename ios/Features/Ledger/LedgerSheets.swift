import SwiftUI
import CoreDomain
import DeviceSurfaces

struct InvalidImportAmount: Codable, Equatable {
    let text: String
    let unit: UnitOfMeasure
}

private enum LedgerImportField: Hashable {
    case original, name(UUID), amount(UUID)
}

struct LedgerImportView: View {
    @ObservedObject var model: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let shopID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.guardianChildCoordinator) private var child
    @State private var reminderPicker: LedgerReminderPresentation?
    @State private var reminderDestination: UUID?
    @State private var original = ""
    @State private var originalExpanded = false
    @State private var showingReviewTotals = false
    @State private var inputLimit: ImportTextLimit?
    @State private var preview: StagedListImport?
    @State private var choices: [UUID: ImportResolution] = [:]
    @State private var invalidAmounts: [UUID: InvalidImportAmount] = [:]
    @State private var explicitSeparate: Set<UUID> = []
    @State private var matchesAreCurrent = true
    @State private var source: ImportSource = .typed
    @State private var importID = UUID()
    @State private var captured: ReviewedCapture?
    @State private var captureBinding: LedgerCaptureBinding?
    @State private var capturePresentation: LedgerCapturePresentation?
    @ScaledMetric(relativeTo: .body) private var importEditorHeight: CGFloat = 180
    @FocusState private var inputFocus: LedgerImportField?
    private enum Focus: Hashable { case preview, status, inputLimit }
    @AccessibilityFocusState private var focus: Focus?
    let firstDraft: FirstListEditor?
    let onSaved: ((UUID) -> Void)?
    let authorizeEntry: @MainActor () -> Bool
    private let prefill: String
    private let pantryFoodPrefill: Bool
    private let pantrySuggestedAmount: Quantity?
    private let pantryProductLink: UUID?
    @State private var incomingWording: String?
    @State private var appendError: String?
    init(model: LedgerModel, shopID: UUID, firstDraft: FirstListEditor? = nil, prefill: String = "", initialPreview: StagedListImport? = nil, pantryFoodPrefill: Bool = false, pantrySuggestedAmount: Quantity? = nil, pantryProductLink: UUID? = nil, authorizeEntry: @escaping @MainActor () -> Bool = { true }, onSaved: ((UUID) -> Void)? = nil) {
        self.model = model; self.shopID = shopID; self.firstDraft = firstDraft; self.onSaved = onSaved
        self.authorizeEntry = authorizeEntry
        self.prefill = prefill
        self.pantryFoodPrefill = pantryFoodPrefill
        self.pantrySuggestedAmount = pantrySuggestedAmount
        self.pantryProductLink = pantryProductLink
        _original = State(initialValue: prefill)
        if firstDraft == nil, let initialPreview, initialPreview.shopID == shopID,
           initialPreview.originalText == prefill {
            _preview = State(initialValue: initialPreview)
            _importID = State(initialValue: initialPreview.id)
            _choices = State(initialValue: LedgerImportReview.initialChoices(initialPreview))
        }
        if let firstDraft { _importID = State(initialValue: firstDraft.content.importID) }
        if let content = firstDraft?.content, firstDraft?.version != nil {
            _original = State(initialValue: content.original); _source = State(initialValue: content.source)
            let alreadyInDraft = pantryFoodPrefill && PantryRestockReview.draftIncludes(food: prefill, text: content.original, preview: content.preview, choices: content.choices)
            _incomingWording = State(initialValue: prefill.isEmpty || alreadyInDraft ? nil : prefill)
            _importID = State(initialValue: content.importID); _preview = State(initialValue: content.preview)
            _choices = State(initialValue: content.choices); _invalidAmounts = State(initialValue: content.invalidAmounts)
            _explicitSeparate = State(initialValue: content.explicitSeparate); _matchesAreCurrent = State(initialValue: content.matchesAreCurrent)
        }
    }
    private var firstContents: FirstListContents {
        .init(shopID: shopID, importID: importID, original: original, source: source,
              preview: preview, choices: choices, invalidAmounts: invalidAmounts, explicitSeparate: explicitSeparate,
              matchesAreCurrent: matchesAreCurrent)
    }
    /// The first-list editor owns one provisional pickup until its byte-bound draft is committed.
    private var reviewWorkspace: LedgerWorkspace? {
        guard let firstDraft else {
            var workspace = model.workspace
            if pantryFoodPrefill { workspace.shops.removeAll { $0.id != shopID } }
            return workspace
        }
        guard firstDraft.authorize(), firstDraft.content.shopID == shopID else { return nil }
        let proposed = ShoppingLedger(id: shopID, title: ledgerText("Pickup"))
        return LedgerWorkspace(shops: [proposed], selectedShopID: shopID)
    }
    private var currentShop: ShoppingLedger? { reviewWorkspace?.shops.first { $0.id == shopID } }
    private var shop: ShoppingLedger? {
        reviewWorkspace?.shops.first { $0.id == (preview?.shopID ?? reminderDestination ?? shopID) }
    }

    var body: some View {
        let review = preview.map { LedgerImportReview(shop: shop, preview: $0, choices: choices) }
        return ScrollViewReader { scroll in
            WorkingForm {
                if let incomingWording {
                    Section(SurfaceCopy.text("Shortcut item")) {
                        Text(verbatim: incomingWording)
                        Button(SurfaceCopy.text("Append to saved draft")) {
                            appendToDraft(incomingWording)
                        }.disabled(model.saving || model.hasPendingSave)
                        if let appendError { Text(appendError).foregroundStyle(Theme.warning) }
                    }
                }
                if let firstDraft {
                    FirstListDraftStatus(editor: firstDraft, contents: firstContents, blocked: model.saving || model.hasPendingSave)
                }
                if showingImportStatus {
                    Section { importSaveStatus }
                        .id("ledgerImportSaveStatus")
                }
                if let preview, let review {
                    if !review.similarEarlierLines.isEmpty,
                       let index = preview.lines.firstIndex(where: { review.similarEarlierLines[$0.id] != nil }) {
                        Section {
                            Button(ledgerFormat("Review possible repeat on line %lld", Int64(index + 1))) {
                                inputFocus = nil
                                scroll.scrollTo(preview.lines[index].id, anchor: .top)
                            }.accessibilityIdentifier("ledgerReviewRepeat")
                        }
                    }
                    Section(ledgerText("Original wording")) {
                        if preview.source == .selectedText, let shop {
                            LabeledContent(applePlanningText("Destination pickup"), value: shop.title)
                        }
                        if preview.lines.count > 1, captured == nil, original.contains(where: \.isNewline) {
                            DisclosureGroup(ledgerText("Show original list"), isExpanded: $originalExpanded) {
                                Text(verbatim: original).textSelection(.enabled)
                            }.accessibilityIdentifier("ledgerOriginalDisclosure")
                        } else {
                            Text(verbatim: original).textSelection(.enabled)
                        }
                        if let pickup = captured?.naturalBatch?.pickup {
                            Text(captureText("Pickup for all items") + ": " + pickup.title)
                            if !availablePickup(pickup) {
                                Text(captureText("This pickup changed. Edit captured fields to choose a pickup again."))
                            }
                        }
                        if let data = captured?.previewImageData ?? captured?.sourceImageData, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                                .accessibilityLabel(captureText("Selected source photo"))
                        }
                    }
                    Section {
                        ForEach(Array(preview.lines.enumerated()), id: \.element.id) { index, row in
                            LedgerImportRowView(number: index + 1, similarLine: review.similarEarlierLines[row.id].map {
                                ledgerFormat("Similar to line %lld: %@", Int64($0 + 1), preview.lines[$0].originalText)
                            }, line: rowBinding(row, at: index, previewID: preview.id),
                                                inputFocus: $inputFocus, invalidAmount: Binding(get: { invalidAmounts[row.id] },
                                                    set: { invalidAmounts[row.id] = $0 }),
                                                matches: review.matches[row.id] ?? [],
                                                explicitlySeparate: explicitSeparate.contains(row.id),
                                                restoreChoice: { setChoice($0, for: row.id, explicitlySeparate: $1) },
                                                choice: Binding(get: { review.choices[row.id] },
                                                                set: { setChoice($0, for: row.id) }),
                                                onEdited: { refreshMatches() })
                        }
                    } header: { Text(ledgerText("Review every line")).accessibilityFocused($focus, equals: .preview) } footer: {
                        Text(ledgerText("Merge confirms the same need. Add amount keeps an additional contribution. Unresolved amounts remain visibly unknown."))
                    }.disabled(model.saving || model.hasPendingSave)
                    Section {
                        if captured != nil {
                            Button(captureText("Edit captured fields")) { beginCapture() }
                                .disabled(model.saving || model.hasPendingSave || liveCaptureBinding != captureBinding)
                        } else {
                            Button(ledgerText("Edit original text")) { self.preview = nil; choices = [:]; importID = UUID() }
                                .disabled(model.saving || model.hasPendingSave)
                        }
                    }
                } else {
                    Section {
                        Text(ledgerText("Type or paste your list")).font(.headline)
                        TextEditor(text: $original)
                            .frame(height: min(importEditorHeight, 240))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlEdge).allowsHitTesting(false))
                            .focused($inputFocus, equals: .original)
                            .accessibilityLabel(ledgerText("List to review")).accessibilityIdentifier("ledgerImportText")
                        PasteButton(payloadType: String.self) { values in
                            original = values.joined(separator: "\n")
                            source = .paste
                        }.accessibilityLabel(ledgerText("Paste list"))
                        Text(ledgerText("One item per line. For example: 12 wraps or 2 kg rice.")).font(.footnote).foregroundStyle(Theme.secondary)
                    }.disabled(model.saving || model.hasPendingSave)
                    if let inputLimit {
                        Section {
                            Text(ledgerImportLimitMessage(inputLimit))
                                .accessibilityFocused($focus, equals: .inputLimit)
                                .accessibilityIdentifier("ledgerImportSizeError")
                        }
                    }
                    Section {
                        if !pantryFoodPrefill, let binding = reminderCopyBinding {
                            Button(applePlanningText("Copy from Reminders")) {
                                inputFocus = nil
                                reminderPicker = LedgerReminderPresentation(binding: binding)
                            }.accessibilityIdentifier("ledger.remindersCopy")
                        }
                        Button(firstDraft == nil ? captureText("Capture and review fields") : ledgerText("Add by photo or voice")) { beginCapture() }
                            .disabled(model.saving || model.hasPendingSave || liveCaptureBinding == nil)
                            .accessibilityIdentifier("ledger.capture")
                    } footer: {
                        Text(captureText("Capture is for this private list. Guest changes use the dinner preview."))
                    }.disabled(model.saving || model.hasPendingSave)
                }
                if firstDraft == nil && !showingImportStatus {
                    Section { importSaveStatus }
                }
            }.accessibilityIdentifier("ledgerImportForm")
                .scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Bring the list"))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let preview, let review, inputFocus == nil {
                        Group {
                            if preview.lines.count > 1, let shop {
                                let totals = review.selectionTotals(for: preview, destination: shop.title)
                                if typeSize.isAccessibilitySize {
                                    compactConfirmation(preview, review: review, totals: totals, scroll: scroll)
                                } else {
                                    VStack(spacing: 4) {
                                        Text(totals.summary)
                                            .font(.subheadline).foregroundStyle(Theme.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .accessibilityIdentifier("ledgerImportSummary")
                                        importConfirmation(preview, review: review)
                                    }
                                }
                            } else {
                                importConfirmation(preview, review: review)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.canvas)
                    } else if preview == nil {
                        reviewListButton
                            .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.canvas)
                    }
                }
                .keyboardDoneAction(visible: inputFocus != nil, title: ledgerText("Done")) { inputFocus = nil }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText(firstDraft == nil ? "Cancel" : "Close")) {
                    if let firstDraft {
                        Task { if await firstDraft.closeSavingEdits(firstContents, prefill: prefill) { dismiss() } }
                    } else { dismiss() }
                }.disabled(model.saving) } }
                .interactiveDismissDisabled(model.saving || firstDraft != nil)
                .sheet(item: $reminderPicker, content: reminderSelection)
                .onChange(of: reminderCopyBinding) { _, value in
                    if let picker = reminderPicker, picker.binding != value { reminderPicker = nil }
                    if reminderDestination != nil, let binding = captureBinding, binding != value { invalidateCapture() }
                }
                .sheet(item: $capturePresentation) { presentation in
                    let binding = presentation.binding
                    let pickups = liveCaptureBinding == binding ? reviewWorkspace?.shops.map(CapturePickup.init) ?? [] : []
                    NavigationStack {
                        CaptureReviewView(initialText: presentation.text, initialSource: presentation.source, localeIdentifier: binding.captureLanguage,
                            destination: presentation.destination, existingCapture: presentation.reviewed,
                            correctionScope: CaptureCorrectionScope(profileID: "local:" + binding.workspaceID.uuidString, localeIdentifier: binding.captureLanguage),
                            currentPickup: pickups.first { $0.id == binding.shopID }, availablePickups: pickups,
                            authorizePickup: { liveCaptureBinding == binding && availablePickup($0) },
                            authorize: { liveCaptureBinding == binding }, onReviewed: { receiveCapture($0, binding: binding) })
                    }
                }
                .onChange(of: firstDraft == nil ? nil : firstContents) { _, next in if let next { firstDraft?.update(next) } }
                .onChange(of: original) { _, _ in inputLimit = nil }
                .onChange(of: liveCaptureBinding) { _, current in
                    if let binding = capturePresentation?.binding ?? captureBinding, current != binding { invalidateCapture() }
                }
                .onChange(of: scenePhase) { _, phase in if phase == .background { reminderPicker = nil; invalidateCapture() } }
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

    private func appendToDraft(_ wording: String) {
        guard let firstDraft, firstDraft.authorize(), authorizeEntry(), !model.saving, !model.hasPendingSave,
              let currentShop, incomingWording == wording else { return }
        do {
            let next = try firstContents.appending(wording, pantryFood: pantryFoodPrefill, shop: currentShop, pantrySuggestedAmount: pantrySuggestedAmount, pantryProductLink: pantryProductLink)
            original = next.original
            preview = next.preview
            choices = next.choices
            // A single capture editor cannot reopen a combined manual/capture review.
            // The original rows still carry their reviewed capture fields.
            captured = nil
            captureBinding = nil
            inputLimit = nil
            appendError = nil
            incomingWording = nil
            firstDraft.update(next)
            model.error = nil
        } catch let limit as ImportTextLimit {
            appendError = ledgerImportLimitMessage(limit)
        } catch LedgerError.stalePreview {
            appendError = ledgerText("This pickup changed after your preview. Return to the original text and review it again before adding it.")
        } catch {
            appendError = ledgerText("This change is too large to save. Reduce the amount of data and try again.")
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
        LedgerSaveStatus(model: model, onRetried: {
            if let preview,
               model.workspace.shops.first(where: { $0.id == preview.shopID })?.importBatches
                .contains(where: { $0.id == preview.id && $0.undoneAt == nil }) == true {
                onSaved?(preview.shopID)
            }
            dismiss()
        }).accessibilityFocused($focus, equals: .status)
    }

    private func compactConfirmation(_ preview: StagedListImport, review: LedgerImportReview,
                                     totals: (included: Int, summary: String), scroll: ScrollViewProxy) -> some View {
        let needsReview = preview.lines.firstIndex { row in
            review.choices[row.id] == nil || row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                (review.choices[row.id] != .skip && invalidAmounts[row.id] != nil)
        }
        let title = ledgerText("Review totals")
        return HStack(spacing: 8) {
            Button { showingReviewTotals = true } label: {
                Image(systemName: needsReview == nil ? "info.circle" : "exclamationmark.circle")
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(title)
            .accessibilityValue(Text(verbatim: totals.summary))
            .accessibilityIdentifier("ledgerImportSummary")
            .alert(title, isPresented: $showingReviewTotals) {
                if let needsReview {
                    Button(ledgerFormat("Review line %lld", Int64(needsReview + 1))) {
                        inputFocus = nil
                        scroll.scrollTo(preview.lines[needsReview].id, anchor: .top)
                    }
                }
                Button(ledgerText("Done"), role: .cancel) {}
            } message: { Text(verbatim: totals.summary) }
            importConfirmation(preview, review: review, title: ledgerFormat("Add %lld", Int64(totals.included)))
                .accessibilityValue(Text(verbatim: totals.summary))
        }
    }

    private var reviewListButton: some View {
        Button(ledgerText("Review list")) {
            guard let shop else { return }
            inputFocus = nil
            do {
                let staged = try pantryFoodPrefill
                    ? PantryRestockReview.stage(food: prefill, text: original, source: source, id: importID, shop: shop, suggestedAmount: pantrySuggestedAmount, productLink: pantryProductLink)
                    : shop.stageImport(text: original, source: source, importID: importID)
                invalidAmounts = [:]
                preview = staged
                choices = LedgerImportReview.initialChoices(staged)
                explicitSeparate = []
                matchesAreCurrent = true
                inputLimit = nil
                originalExpanded = false
                focus = .preview
            } catch let limit as ImportTextLimit {
                inputLimit = limit
                focus = .inputLimit
            } catch {
                model.error = ledgerText("Check the amounts, units and links. This change could not be applied; your saved pickup is unchanged.")
            }
        }.buttonStyle(PrimaryAction()).disabled(!original.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) })
            .accessibilityIdentifier("ledgerReviewImport")
    }

    private func importConfirmation(_ preview: StagedListImport, review: LedgerImportReview, title: String? = nil) -> some View {
        let needsAmountCorrection = invalidAmounts.keys.contains { review.choices[$0] != .skip }
        let reviewedBinding = captureBinding
        let reminderBinding = reminderDestination == nil ? nil : reviewedBinding
        let authorizeSave: @MainActor () -> Bool = {
            authorizeEntry() && (reminderBinding == nil || reminderCopyBinding == reminderBinding)
        }
        return Button(title ?? ledgerText("Add reviewed list")) {
            guard inputFocus == nil else { return }
            Task {
                guard authorizeSave(), self.preview == preview, captureBinding == reviewedBinding,
                      reviewedBinding == nil || captureAuthorized else {
                    model.error = captureText("This capture belongs to an earlier workspace or list revision. Review it again before adding anything.")
                    focus = .status; return
                }
                let decisions = review.choices
                if let firstDraft {
                    guard preview.shopID == shopID, firstDraft.authorize(), let draft = await firstDraft.flush(firstContents) else { return }
                    if await model.commitFirstList(preview, decisions: decisions, draft: draft, title: ledgerText("Pickup"), authorize: firstDraft.authorize) {
                        onSaved?(shopID); dismiss()
                    } else {
                        if !model.hasPendingSave, model.error == nil {
                            model.error = ledgerText("Could not save on this iPhone. Your entries are still here. Retry the same change.")
                        }
                        focus = .status
                    }
                } else if await model.editShop(key: "import-\(preview.id)", shopID: preview.shopID, authorize: authorizeSave, { try $0.commitImport(preview, decisions: decisions) }) {
                    onSaved?(preview.shopID)
                    dismiss()
                } else { focus = .status }
            }
        }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave || !matchesAreCurrent || !review.isComplete || needsAmountCorrection || (firstDraft != nil && !review.choices.values.contains(where: { $0 != .skip })))
            .accessibilityLabel(ledgerText("Add reviewed list"))
            .accessibilityIdentifier("ledgerCommitImport")
    }

    @ViewBuilder private func reminderSelection(_ presentation: LedgerReminderPresentation) -> some View {
        if reminderCopyBinding == presentation.binding, let destination = shop {
            let destinations = original.isEmpty ? reviewWorkspace?.shops.map(CapturePickup.init) ?? [] : [CapturePickup(destination)]
            AppleGroceryReminders(original: original, destinations: destinations, destination: destination.id,
                authorize: { reminderCopyBinding == presentation.binding },
                review: { text, target in reviewReminderCopy(text, target: target, binding: presentation.binding) })
        }
    }

    private func reviewReminderCopy(_ text: String, target: CapturePickup, binding: LedgerCaptureBinding) -> Bool {
        guard reminderCopyBinding == binding, !model.saving, !model.hasPendingSave, availablePickup(target),
              let pickedShop = reviewWorkspace?.shops.first(where: { $0.id == target.id }),
              let staged = try? pickedShop.stageImport(text: text, source: .selectedText, importID: importID) else { return false }
        reminderDestination = target.id
        original = text
        source = .selectedText
        captureBinding = binding
        captured = nil
        preview = staged
        choices = LedgerImportReview.initialChoices(staged)
        invalidAmounts = [:]
        explicitSeparate = []
        matchesAreCurrent = true
        inputLimit = nil
        focus = .preview
        model.error = nil
        return true
    }

    private var reminderCopyBinding: LedgerCaptureBinding? {
        guard child?.presented != true, household.projection?.grantId == nil, UIApplication.shared.isProtectedDataAvailable else { return nil }
        return liveCaptureBinding
    }

    private var liveCaptureBinding: LedgerCaptureBinding? {
        guard authorizeEntry(), access.unlocked, !household.locked, model.ready,
              !model.hasPendingLedgerDeletion, let workspaceID = model.sourceWorkspaceID,
              let shop = currentShop, reviewWorkspace?.selectedShopID == shopID else { return nil }
        if let projection = household.projection {
            guard household.identity != nil, projection.enrolled, ["shopper", "organizer"].contains(projection.role) else { return nil }
        } else if household.identity != nil { return nil }
        return LedgerCaptureBinding(workspaceID: workspaceID, shopID: shopID, revision: shop.revision,
            actorID: access.localActorID, subject: household.identity?.subject,
            householdID: household.projection?.household.id, memberID: household.projection?.memberId,
            role: household.projection?.role, localeIdentifier: locale.identifier, captureLanguage: CaptureCorrectionScope.appLanguage())
    }
    private func availablePickup(_ pickup: CapturePickup) -> Bool {
        reviewWorkspace?.shops.first(where: { $0.id == pickup.id }).map(CapturePickup.init) == pickup
    }
    private var captureAuthorized: Bool {
        guard let captureBinding, liveCaptureBinding == captureBinding else { return false }
        guard let batch = captured?.naturalBatch else { return true }
        return batch.pickup.map(availablePickup) == true
    }
    private func beginCapture() {
        guard let binding = liveCaptureBinding, let shop = currentShop, !model.saving, !model.hasPendingSave else { return }
        inputFocus = nil
        capturePresentation = LedgerCapturePresentation(binding: binding, destination: shop.title,
            text: original, source: source == .paste ? .paste : .typed, reviewed: captured)
    }
    private func receiveCapture(_ capture: ReviewedCapture, binding: LedgerCaptureBinding) {
        guard liveCaptureBinding == binding, !model.saving, !model.hasPendingSave, let reviewWorkspace else { return }
        do {
            let staged = try CaptureLedgerImport.stage(capture, in: reviewWorkspace, currentShopID: shopID)
            if staged.alreadyApplied { capturePresentation = nil; dismiss(); return }
            captureBinding = binding
            reminderDestination = nil
            captured = capture; importID = capture.id; original = capture.originalText
            source = staged.preview.source; preview = staged.preview
            invalidAmounts = [:]
            choices = LedgerImportReview.initialChoices(staged.preview)
            explicitSeparate = []
            matchesAreCurrent = true
            capturePresentation = nil; focus = .preview; model.error = nil
        } catch StructuredCaptureFailure.destinationMismatch {
            model.error = captureText("Choose an available pickup before continuing.")
            focus = .status
        } catch {
            model.error = captureText("Review each item. Use a positive amount or leave it explicitly unknown; pack counts must be whole numbers.")
            focus = .status
        }
    }
    private func invalidateCapture() {
        guard capturePresentation != nil || captureBinding != nil else { return }
        capturePresentation = nil; captured = nil; captureBinding = nil; reminderDestination = nil
        if firstDraft != nil { return } // Only reviewed text/fields survive; captured media is dropped above.
        invalidAmounts = [:]
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

    private func setChoice(_ value: ImportResolution?, for id: UUID, explicitlySeparate: Bool = true) {
        guard let preview, let shop else { return }
        var next = choices
        next[id] = value
        if value == .addNew && explicitlySeparate { explicitSeparate.insert(id) } else { explicitSeparate.remove(id) }
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
    let captureLanguage: String
}

private struct LedgerReminderPresentation: Identifiable {
    let id = UUID()
    let binding: LedgerCaptureBinding
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
    var similarEarlierLines: [UUID: Int] = [:]

    /// Do not suggest combining quantities. Flag only repeated names and literal plural variants in this draft
    /// with the same measured amount and unit, excluding packages, captures and qualified wording.
    private static func similarLines(in preview: StagedListImport, choices: [UUID: ImportResolution]) -> [UUID: Int] {
        guard preview.lines.count > 1 else { return [:] }
        struct Measure: Hashable { let amount: Rational; let unit: UnitOfMeasure }
        var earlier: [Measure: [String: Int]] = [:]
        var result: [UUID: Int] = [:]
        for (index, row) in preview.lines.enumerated() {
            guard choices[row.id] != .skip, let quantity = row.quantity, row.unresolvedReason == nil,
                  row.originalPack == nil, row.capture == nil, row.exclusions.isEmpty, row.pantryProductLink == nil,
                  let plain = QuickGrocery.plainName(row.name) else { continue }
            let words = GroceryNameSpelling.folded(plain).split(separator: " ")
            guard let last = words.last, words.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { continue }
            let name = words.joined(separator: " ")
            let measure = Measure(amount: quantity.amount, unit: quantity.unit)
            var variants = [name]
            if last.count >= 3 {
                variants.append(contentsOf: GroceryNameSpelling.pluralEndings.map { name + $0 })
            }
            for ending in GroceryNameSpelling.pluralEndings where last.hasSuffix(ending) && last.count >= ending.count + 3 {
                variants.append(String(name.dropLast(ending.count)))
            }
            result[row.id] = variants.compactMap { earlier[measure]?[$0] }.min()
            if choices[row.id] != nil && earlier[measure]?[name] == nil {
                earlier[measure, default: [:]][name] = index
            }
        }
        return result
    }

    func selectionTotals(for preview: StagedListImport, destination: String) -> (included: Int, summary: String) {
        let selected = preview.lines.compactMap { choices[$0.id] }
        let skipped = selected.filter { $0 == .skip }.count
        let summary = ledgerFormat("%@ · Selected: %lld · Skipped: %lld", destination, Int64(selected.count - skipped), Int64(skipped))
        let undecided = preview.lines.count - selected.count
        return (selected.count - skipped, undecided == 0 ? summary : summary + " · " + ledgerFormat("To review: %lld", Int64(undecided)))
    }

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
        similarEarlierLines = Self.similarLines(in: preview, choices: retained)
        isComplete = !preview.lines.isEmpty && preview.lines.allSatisfy {
            retained[$0.id] != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct LedgerImportResolutionPicker: View {
    let identifier: String
    let matches: [LedgerImportReview.Match]
    @Binding var choice: ImportResolution?
    var offersSkip = true
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
            if offersSkip {
                Text(ledgerText("Skip this line")).tag(ImportResolution.skip as ImportResolution?)
            }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let number: Int
    let similarLine: String?
    @Binding var line: StagedImportLine
    let inputFocus: FocusState<LedgerImportField?>.Binding
    @Binding var invalidAmount: InvalidImportAmount?
    let matches: [LedgerImportReview.Match]
    let explicitlySeparate: Bool
    let restoreChoice: (ImportResolution?, Bool) -> Void
    @Binding var choice: ImportResolution?
    @State private var previousChoice: ImportResolution?
    @State private var previousWasExplicit = false
    let onEdited: () -> Void
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    init(number: Int, similarLine: String?, line: Binding<StagedImportLine>, inputFocus: FocusState<LedgerImportField?>.Binding,
         invalidAmount: Binding<InvalidImportAmount?>, matches: [LedgerImportReview.Match],
         explicitlySeparate: Bool, restoreChoice: @escaping (ImportResolution?, Bool) -> Void,
         choice: Binding<ImportResolution?>, onEdited: @escaping () -> Void) {
        self.number = number
        self.similarLine = similarLine
        _line = line
        self.inputFocus = inputFocus
        _invalidAmount = invalidAmount
        self.matches = matches
        self.explicitlySeparate = explicitlySeparate
        self.restoreChoice = restoreChoice
        _choice = choice
        self.onEdited = onEdited
        _amount = State(initialValue: invalidAmount.wrappedValue?.text ?? line.wrappedValue.quantity.map { ledgerAmountInput($0.amount) } ?? "")
        _unit = State(initialValue: invalidAmount.wrappedValue?.unit ?? line.wrappedValue.quantity?.unit ?? .count)
    }
    var body: some View {
        let heading = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout())
        VStack(alignment: .leading, spacing: 8) {
            heading {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.originalText).font(.subheadline)
                    if choice == .skip {
                        Text(ledgerText("Skipped")).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer() }
                if choice == .skip {
                    Button(action: includeLine) {
                        Text(ledgerText("Include")).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(ledgerFormat("Include %@", line.originalText))
                    .accessibilityIdentifier("ledgerImportInclude-\(number)")
                } else {
                    Button {
                        previousChoice = choice
                        previousWasExplicit = explicitlySeparate
                        inputFocus.wrappedValue = nil
                        choice = .skip
                    } label: {
                        Text(ledgerText("Skip")).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(ledgerFormat("Skip %@", line.originalText))
                    .accessibilityIdentifier("ledgerImportSkip-\(number)")
                }
            }.buttonStyle(.borderless)
            if let similarLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.magnifyingglass").accessibilityHidden(true)
                    Text(verbatim: similarLine)
                        .accessibilityIdentifier("ledgerImportRepeat-\(number)")
                }.font(.subheadline)
            }
            if choice != .skip || line.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rowFields
            }
        }.padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            .onChange(of: amount) { _, _ in updateQuantity() }
            .onChange(of: unit) { _, _ in updateQuantity() }
            .onChange(of: line.name) { _, _ in onEdited() }
    }
    private func includeLine() {
        if let previousChoice, previousChoice != .addNew || previousWasExplicit {
            // setChoice revalidates the target against the current preview.
            restoreChoice(previousChoice, previousWasExplicit)
        } else {
            let hasCandidate = !line.duplicateLineIDs.isEmpty || !matches.isEmpty
            restoreChoice(hasCandidate ? nil : .addNew, false)
        }
    }

    @ViewBuilder private var rowFields: some View {
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
            WorkingField(ledgerText("Item name")) {
                TextField(ledgerText("Item name"), text: $line.name, prompt: Text(""), axis: .vertical)
                    .focused(inputFocus, equals: .name(line.id))
                    .accessibilityIdentifier("ledgerImportName-\(number)")
                    .textFieldStyle(.roundedBorder)
            }
            WorkingField(shoppingText("Quantity (optional)")) {
                TextField(shoppingText("Quantity (optional)"), text: $amount, prompt: Text(""))
                    .keyboardType(.numbersAndPunctuation)
                    .focused(inputFocus, equals: .amount(line.id))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ledgerImportAmount-\(number)")
            }
            Picker(ledgerText("Unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        if invalidAmount != nil && choice != .skip {
            Text(ledgerText("Enter a nonnegative amount with up to six decimal places, or leave it unknown."))
                .foregroundStyle(Theme.warning)
                .accessibilityIdentifier("ledgerImportAmountError-\(number)")
        } else if line.quantity == nil, line.originalPack == nil, line.capture == nil,
                  QuickGrocery.plainName(line.originalText) != nil, QuickGrocery.plainName(line.name) != nil {
            Text(ledgerText("Quantity optional")).font(.footnote).foregroundStyle(Theme.secondary)
        } else if line.quantity == nil && line.originalPack?.count == nil {
            Label(ledgerText("Quantity unresolved"), systemImage: "questionmark.circle").foregroundStyle(Theme.warning)
            if let reason = line.unresolvedReason { Text(ledgerContributionNote(reason)).font(.footnote) }
        }
        if matches.contains(where: { $0.option.canMerge }) && matches.contains(where: { $0.option.canAdd }) {
            Text(ledgerText("A matching item is already listed. Is this the same need or an additional amount?"))
                .font(.subheadline)
        }
        if !matches.isEmpty || choice == nil {
            LedgerImportResolutionPicker(identifier: "ledgerImportResolution-\(number)", matches: matches, choice: $choice, offersSkip: false)
        }
    }

    private func updateQuantity() {
        do {
            line.quantity = try LedgerEntry.quantity(amount, unit)
            line.unresolvedReason = line.quantity == nil ? "quantityUnknown" : nil
            invalidAmount = nil
        } catch {
            invalidAmount = InvalidImportAmount(text: amount, unit: unit)
            line.quantity = nil
            line.unresolvedReason = nil
        }
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
    private struct ScreenshotRequest: Identifiable {
        let id = UUID()
        let terms: ShopBasis.RetailerTerms
    }
    @State private var screenshotRequest: ScreenshotRequest?
    @State private var screenshot: ReviewedCheckoutImage?
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
        _screenshot = State(initialValue: shop.basis.retailerPreview?.screenshot)
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
        WorkingForm {
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
                            retailerDate = Date(); includedCharges = ""; evidenceTerms = currentTerms; screenshot = nil
                        }
                    } else {
                        Button(pantryText("Read a checkout screenshot")) {
                            screenshotRequest = ScreenshotRequest(terms: currentTerms)
                        }.accessibilityIdentifier("priceImage.readCheckout")
                        Toggle(ledgerText("Record a retailer preview"), isOn: $hasRetailerPreview)
                    }
                    if hasRetailerPreview && !needsFreshEvidence {
                        if let screenshot {
                            imageSummary(screenshot)
                            DatePicker(ledgerText("When this preview was shown"), selection: $retailerDate)
                                .environment(\.timeZone, TimeZone(identifier: basis.timeZoneIdentifier) ?? .current)
                            Button(pantryText("Replace screenshot with manual evidence")) {
                                self.screenshot = nil; retailerTotal = ""; retailerSource = ""; includedCharges = ""
                            }
                        } else {
                        TextField(ledgerText("Retailer total (USD, unknown if blank)"), text: $retailerTotal).keyboardType(.decimalPad)
                            .focused($inputFocus, equals: .retailerTotal)
                        TextField(ledgerText("Source of the retailer preview"), text: $retailerSource, axis: .vertical)
                            .focused($inputFocus, equals: .retailerSource)
                        DatePicker(ledgerText("When this preview was shown"), selection: $retailerDate)
                            .environment(\.timeZone, TimeZone(identifier: basis.timeZoneIdentifier) ?? .current)
                        TextField(ledgerText("Included charges, separated by commas"), text: $includedCharges, axis: .vertical)
                            .focused($inputFocus, equals: .includedCharges)
                        }
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
                    .disclosureGroupStyle(LabeledFormDisclosureStyle(label: ledgerText("Earlier retailer evidence"),
                                                                     identifier: "ledger.earlierRetailerEvidence"))
                }
            }
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Describe this pickup"))
            .sheet(item: $screenshotRequest) { request in
                NavigationStack { checkoutImage(for: request.terms) }
            }
            .onChange(of: currentTerms) { old, new in
                if old == evidenceTerms, !hasRetailerPreview, fees.isEmpty, retailerSource.isEmpty, retailerTotal.isEmpty, includedCharges.isEmpty {
                    evidenceTerms = new; retailerDate = Date()
                }
            }
            .keyboardDoneAction(visible: inputFocus != nil, title: ledgerText("Done"), identifier: "ledgerFactsKeyboardDone") { inputFocus = nil }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
    private func checkoutImage(for terms: ShopBasis.RetailerTerms) -> some View {
        PriceImageReview(purpose: .checkout, authorized: { isCurrent && terms == currentTerms }, acceptCheckout: { reviewed in
            guard isCurrent, terms == currentTerms else { return }
            screenshot = reviewed
            hasRetailerPreview = true
            retailerTotal = reviewed.displayedTotal.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? ""
            retailerSource = pantryText("Checkout screenshot")
            includedCharges = reviewed.charges.filter { $0.inclusion == .included }.map { priceImageField($0.field) }.joined(separator: ", ")
            retailerDate = Date()
            evidenceTerms = terms
        })
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
                                                              capturedAt: retailerDate, includedCharges: charges, screenshot: screenshot)
            } else { basis.retailerPreview = nil }
            basis.slot = hasSlot ? slot : nil
            try basis.validate()
            guard isCurrent else { return }
            validation = nil
            reviewing = true
        } catch { validation = ledgerText("Use a nonnegative USD amount with no more than two decimal places.") }
    }
    private func imageSummary(_ screenshot: ReviewedCheckoutImage) -> some View {
        ForEach(screenshot.charges, id: \.field) { charge in
            VStack(alignment: .leading) {
                LabeledContent(priceImageField(charge.field), value: charge.amount.map(moneyText) ?? ledgerText("Unknown"))
                if !charge.line.wording.isEmpty { Text(verbatim: charge.line.wording) }
                if let reading = charge.line.reviewedReading { ReviewedImageWordingLabel(reading: reading) }
                if charge.field != .total { Text(priceImageInclusion(charge.inclusion)).font(.caption) }
            }
        }
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
                if let screenshot = preview.screenshot { imageSummary(screenshot) }
                Text(ledgerDate(preview.capturedAt, zone: value.timeZoneIdentifier))
                Text(ledgerFormat("Included charges: %@", preview.includedCharges.joined(separator: ", ")))
            } else { Text(ledgerFormat("Retailer preview: %@", ledgerText("Unknown"))) }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
