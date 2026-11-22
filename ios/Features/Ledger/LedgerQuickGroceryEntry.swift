import CoreDomain
import LocalStore
import Observation
import SwiftUI

func quickGroceryText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "QuickGrocery")
}

func quickGroceryFormat(_ key: String, _ values: CVarArg...) -> String {
    String(format: quickGroceryText(key), locale: .current, arguments: values)
}

private struct ReviewedQuickGroceryDraftKey: EnvironmentKey {
    static let defaultValue: FirstListDraftVersion? = nil
}

extension EnvironmentValues {
    var reviewedQuickGroceryDraft: FirstListDraftVersion? {
        get { self[ReviewedQuickGroceryDraftKey.self] }
        set { self[ReviewedQuickGroceryDraftKey.self] = newValue }
    }
}

/// One field writes to one immutable destination. Coalesce typing while a SQLite
/// write is in flight; version checks protect edits made in another window.
@MainActor @Observable final class QuickGroceryDraft {
    let shopID: UUID?
    let store: LedgerStore
    let owner: Data
    private(set) var text: String
    private(set) var version: FirstListDraftVersion?
    private var saved: String
    private var writer: Task<Void, Never>?
    private(set) var failure: LedgerStoreError?

    init(shopID: UUID?, store: LedgerStore, owner: Data, record: StoredFirstListDraft?) throws {
        self.shopID = shopID
        self.store = store
        self.owner = owner
        version = record?.version
        if let record {
            guard record.version.workspaceID == store.workspaceID, record.version.owner == owner,
                  let wording = String(data: record.payload, encoding: .utf8) else { throw LedgerStoreError.corruptRecord }
            text = wording
            saved = wording
        } else {
            text = ""
            saved = ""
        }
    }

    var hasLocalEdits: Bool { writer != nil || text != saved }

    func update(_ wording: String, revision: Int64) {
        text = wording
        guard writer == nil else { return }
        failure = nil
        guard text != saved else { return }
        writer = Task {
            defer { writer = nil }
            do {
                while text != saved {
                    let value = text
                    if value.isEmpty {
                        if let version { try await store.discardFirstListDraft(version) }
                        version = nil
                    } else {
                        guard value.utf8.count <= StagedListImport.maximumTextBytes else { throw LedgerStoreError.payloadTooLarge }
                        version = try await store.replaceFirstListDraft(owner: owner, expected: version,
                            baseRevision: revision, payload: Data(value.utf8))
                    }
                    saved = value
                }
            } catch {
                failure = (error as? LedgerStoreError) ?? .invalidInput
            }
        }
    }

    func prepareToSubmit(_ wording: String, revision: Int64) async -> Bool {
        guard wording == text else { return false }
        update(wording, revision: revision)
        await writer?.value
        guard wording == text else { return false }
        // A full draft table or an oversized paste can still use the normal Add
        // and review paths. SQLite clears only the last version actually saved.
        return (failure == nil && saved == wording) || failure == .payloadTooLarge
    }

    func committed(_ consumed: FirstListDraftVersion?, wording: String, revision: Int64) async {
        await writer?.value
        guard version == consumed else { return }
        version = nil
        if text == wording { text = "" }
        saved = ""
        update(text, revision: revision)
    }
}

/// The parent keeps a secondary route for workspaces without an active quick-entry field.
struct ShopListLinkProvided: PreferenceKey {
    static let defaultValue: UUID? = nil
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        if let shop = nextValue() { value = shop }
    }
}

/// This entry exists only on the adult's local Shop and private ledger surfaces.
/// Household requests continue through the household inbox and approval flow.
struct LedgerQuickGroceryEntry: View {
    @ObservedObject var model: LedgerModel
    var prominent = false
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.scenePhase) private var scene

    var body: some View {
        if !model.hasPendingLedgerDeletion, UIApplication.shared.isProtectedDataAvailable,
           child?.presented != true, household.projection?.grantId == nil,
           let identity = CapturePrivateIdentity.current(access: access, household: household) {
            if let owner = try? firstListOwner(identity), let workspaceID = model.sourceWorkspaceID {
                let available = scene == .active && model.firstListStore != nil
                QuickGroceryField(model: model, workspaceID: workspaceID, owner: owner, prominent: prominent, available: available, householdMember: household.projection != nil, authorize: {
                    UIApplication.shared.isProtectedDataAvailable && UIApplication.shared.applicationState == .active &&
                    child?.presented != true && household.projection?.grantId == nil &&
                    CapturePrivateIdentity.current(access: access, household: household) == identity &&
                    model.sourceWorkspaceID == workspaceID && model.firstListStore != nil && !model.hasPendingLedgerDeletion
                }).id(EntryOwner(persona: owner, workspace: workspaceID))
                    .opacity(available ? 1 : 0)
                    .frame(height: available ? nil : 0)
                    .accessibilityHidden(!available)
                    .allowsHitTesting(available)
            }
            if prominent, scene == .active, model.shop == nil || model.firstListStore == nil || model.sourceWorkspaceID == nil,
               model.hasPendingSave || model.error != nil || model.saving {
                LedgerSaveStatus(model: model)
            }
        }
    }

    private struct EntryOwner: Hashable { let persona: Data; let workspace: UUID }
}

private struct QuickGroceryField: View {
    @ObservedObject var model: LedgerModel
    let workspaceID: UUID
    let owner: Data
    let prominent: Bool
    let available: Bool
    let householdMember: Bool
    let authorize: @MainActor () -> Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft: QuickGroceryDraft?
    @State private var loadFailed = false
    @State private var loadAttempt = 0
    private var currentDraft: QuickGroceryDraft? {
        guard let draft, draft.shopID == model.shop?.id, draft.store === model.firstListStore else { return nil }
        return draft
    }
    private var text: String { currentDraft?.text ?? "" }
    private struct DraftQuery: Hashable {
        let shopID: UUID?
        let store: ObjectIdentifier?
        let attempt: Int
    }
    @State private var recent: [String] = []
    @State private var visible = false
    @State private var submitting = false
    private struct Submission {
        let preview: StagedListImport
        let wording: String
        let draft: QuickGroceryDraft
        let version: FirstListDraftVersion?
    }
    @State private var submitted: Submission?
    @State private var receipt: Receipt?
    @State private var continueTyping = false
    private struct Receipt {
        let batchID: UUID
        let revisionID: UUID
    }
    @State private var review: Review?
    @FocusState private var editing: Bool

    private struct Review: Identifiable {
        let id = UUID()
        let shopID: UUID?
        let text: String
        let preview: StagedListImport?
        let draft: QuickGroceryDraft
        let version: FirstListDraftVersion?
    }
    private var confirmedBatch: LedgerImportBatch? {
        guard let receipt, let shop = model.shop, shop.revisionID == receipt.revisionID else { return nil }
        return shop.importBatches.last { $0.id == receipt.batchID && $0.undoneAt == nil }
    }
    private var listTitle: String {
        if householdMember { return quickGroceryText("Add to my private list") }
        if let shop = model.shop, shop.title != ledgerText("Pickup") { return shop.title }
        return ledgerText("Shopping list")
    }
    private var busy: Bool { submitting || model.saving || model.hasPendingSave }
    private var suggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Array(recent.lazy.filter { query.isEmpty || $0.lowercased().hasPrefix(query) }.prefix(4))
    }
    private var emptyLineHeight: CGFloat? {
        guard text.isEmpty else { return nil }
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return ceil(UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight)
    }

    private var groceryInput: Binding<String> {
        Binding(get: { text }, set: { updated in
            // A wrapping field inserts the Return key as a newline. Commit that
            // single edit while preserving pasted lists for the normal review.
            if updated.utf8.count == text.utf8.count + 1, updated.contains("\n") {
                let prefix = updated.commonPrefix(with: text).count
                let suffix = updated.dropFirst(prefix)
                if suffix.first == "\n", suffix.dropFirst() == text.dropFirst(prefix) {
                    submit(keepKeyboard: true)
                    return
                }
            }
            edit(updated)
        })
    }

    private func edit(_ updated: String) {
        guard authorize(), let draft = currentDraft, draft.text != updated else { return }
        receipt = nil
        draft.update(updated, revision: model.revision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prominent {
                HStack(alignment: .center, spacing: 8) {
                    Text(listTitle)
                        .marketJournalTitle(.largeTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !typeSize.isAccessibilitySize {
                        Image(decorative: "MarketGroceries")
                            .resizable().scaledToFit().frame(width: 110, height: 68)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: listTitle))
                .accessibilityAddTraits(.isHeader)
            } else if householdMember {
                Text(quickGroceryText("Add to my private list"))
                    .font(.headline).accessibilityAddTraits(.isHeader)
            }
            if typeSize.isAccessibilitySize {
                Text(quickGroceryText("Grocery name"))
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                TextField("", text: groceryInput, axis: .vertical)
                    .textFieldStyle(.plain).font(.body)
                    .fixedSize(horizontal: false, vertical: !text.isEmpty)
                    .frame(height: emptyLineHeight)
                    .focused($editing)
                    .disabled(currentDraft == nil)
                    .submitLabel(.done).onSubmit { submit(keepKeyboard: true) }
                    .accessibilityLabel(quickGroceryText("Grocery name"))
                    .accessibilityIdentifier("quickGrocery.name")
                    .overlay(alignment: .leading) {
                        if text.isEmpty && !typeSize.isAccessibilitySize {
                            Text(quickGroceryText("Add a grocery"))
                                .font(.body).foregroundStyle(Theme.secondary)
                                .accessibilityRepresentation { EmptyView() }
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(editing ? Theme.action : Theme.controlEdge, lineWidth: editing ? 2 : 1) }
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        if !editing { receipt = nil }
                        editing = true
                    })
                Button(quickGroceryText("Add")) { submit() }
                    .buttonStyle(PrimaryAction()).fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(quickGroceryText("Add grocery"))
                    .accessibilityHint(quickGroceryFormat("For the list “%@”.", model.shop?.title ?? ledgerText("Pickup")))
                    .accessibilityIdentifier("quickGrocery.add")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            if loadFailed || currentDraft?.failure != nil {
                let reopen = loadFailed || currentDraft?.failure == .operationConflict
                Text(ledgerText(loadFailed ? "Draft unavailable" : reopen ? "This draft changed or expired. Reopen it to review the saved version." :
                        "Draft could not be saved. Keep this screen open or reopen the saved version."))
                    .foregroundStyle(Theme.warning)
                Button(ledgerText(reopen ? "Reopen" : "Retry saving draft")) {
                    guard authorize() else { return }
                    if reopen { draft = nil; loadAttempt += 1 }
                    else { currentDraft?.update(text, revision: model.revision) }
                }.buttonStyle(.borderless).frame(minHeight: 44)
            }
            if editing { addReceipt }
            if editing {
                Button { editing = false } label: {
                    Label(quickGroceryText("Dismiss keyboard"), systemImage: "keyboard.chevron.compact.down")
                        .font(.subheadline).frame(minHeight: 44)
                }.buttonStyle(.borderless).accessibilityIdentifier("quickGrocery.dismissKeyboard")
            }
            if editing && !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) { edit(name) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(quickGroceryFormat("Use recent grocery %@", name))
                        }
                    }
                }
            }
            if let name = QuickGrocery.plainName(text) {
                QuickGroceryAtHome(name: name, branch: model.shop?.basis.branch ?? "", ledgerWorkspaceID: workspaceID,
                                   authorize: authorize, addingDisabled: busy, keepOnList: { submit() })
            }
            if prominent, let shop = model.shop {
                ShopGroceryPreview(model: model, shop: shop, showsListLink: confirmedBatch == nil, authorize: authorize)
                    .id(shop.id)
                    .preference(key: ShopListLinkProvided.self, value: available ? shop.id : nil)
            }
            if !editing { addReceipt }
        }
        .task(id: DraftQuery(shopID: model.shop?.id, store: available ? model.firstListStore.map(ObjectIdentifier.init) : nil, attempt: loadAttempt)) {
            await restoreDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if currentDraft == nil { loadAttempt += 1 }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: available) { _, ready in
            if ready { finishCommittedEntry(announce: false) }
        }
        .onChange(of: model.revision, initial: true) { _, _ in
            recent = QuickGrocery.recentNames(in: model.workspace)
            finishCommittedEntry()
        }
        .onChange(of: model.workspace.selectedShopID) { old, next in
            guard old != nil || next != submitted?.preview.shopID else { return }
            if let receipt, model.shop?.importBatches.contains(where: { $0.id == receipt.batchID }) == true { return }
            receipt = nil; submitted = nil; review = nil
        }
        .sheet(item: $review) { original in
            NavigationStack {
                if authorize(), model.shop?.id == original.shopID {
                    if let id = original.shopID {
                        LedgerImportView(model: model, shopID: id, prefill: original.text, initialPreview: original.preview,
                            authorizeEntry: { authorize() && model.shop?.id == id },
                            onSaved: { _ in finishReview(original) })
                    } else {
                        FirstListEntry(model: model, prefill: original.text,
                            authorizeEntry: { authorize() && model.shop == nil }) { _ in finishReview(original) }
                    }
                }
            }
            .environment(\.reviewedQuickGroceryDraft, original.version)
        }
    }

    private func restoreDraft() async {
        guard available, authorize(), let store = model.firstListStore else { return }
        let id = model.shop?.id
        if currentDraft?.hasLocalEdits == true { return }
        let previous = currentDraft
        let priorVersion = previous?.version
        let key = LedgerStore.quickGroceryDraftOwner(persona: owner, shopID: id)
        do {
            let record = try await store.firstListDraft(owner: key)
            guard !Task.isCancelled, authorize(), model.shop?.id == id, model.firstListStore === store,
                  currentDraft === previous, currentDraft?.version == priorVersion, currentDraft?.hasLocalEdits != true else { return }
            loadFailed = false
            if let previous, previous.version == record?.version { return }
            draft = try QuickGroceryDraft(shopID: id, store: store, owner: key, record: record)
        } catch {
            if !Task.isCancelled, authorize(), model.shop?.id == id { loadFailed = true }
        }
    }

    private func finishReview(_ original: Review) {
        review = nil
        Task { await original.draft.committed(original.version, wording: original.text, revision: model.revision) }
    }

    @ViewBuilder private var addReceipt: some View {
        if let receipt, let shop = model.shop, let batch = confirmedBatch {
            VStack(alignment: .leading, spacing: 0) {
                Label(quickGroceryFormat("Added %@ to %@ on this iPhone.", batch.originalText, shop.title), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.onSelection)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quickGrocery.added")
                let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 16))
                actions {
                    Button {
                        Task {
                            if await model.editShop(key: "undo-quick-\(batch.id)", shopID: shop.id,
                                authorize: { authorize() && model.shop?.id == shop.id && model.shop?.revisionID == receipt.revisionID }, { current in
                                    guard current.revisionID == receipt.revisionID else { throw LedgerError.stalePreview }
                                    try current.undoImport(batchID: batch.id)
                                }) { self.receipt = nil }
                        }
                    } label: {
                        Text(quickGroceryText("Undo")).underline()
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.onSelection)
                    .accessibilityLabel(quickGroceryFormat("Undo adding %@", batch.originalText))
                    .disabled(busy || shop.revisionID != receipt.revisionID).accessibilityIdentifier("quickGrocery.undo")
                    if prominent {
                        RestorableShoppingListLink {
                            Text(quickGroceryText("View shopping list")).underline()
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.onSelection)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
            .background(Theme.selection, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func submit(keepKeyboard: Bool = false) {
        guard authorize(), !busy, let draft = currentDraft,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let selectedID = model.shop?.id
        let shop = model.shop ?? ShoppingLedger(title: ledgerText("Pickup"))
        let original = text
        submitting = true
        continueTyping = keepKeyboard
        if !keepKeyboard { editing = false }
        Task {
            defer { submitting = false }
            guard await draft.prepareToSubmit(original, revision: model.revision),
                  authorize(), currentDraft === draft, model.shop?.id == selectedID else { return }
            let version = draft.version
            guard let preview = try? QuickGrocery.stage(original, in: shop) else {
                editing = false
                review = Review(shopID: selectedID, text: original,
                    preview: selectedID == nil ? nil : try? shop.stageImport(text: original), draft: draft, version: version)
                return
            }
            if selectedID == nil {
                do {
                    let bulk = try await draft.store.firstListDraft(owner: owner)
                    guard authorize(), currentDraft === draft, model.shop == nil else { return }
                    if bulk != nil {
                        editing = false
                        review = Review(shopID: nil, text: original, preview: nil, draft: draft, version: version)
                        return
                    }
                } catch {
                    model.error = ledgerText("Could not save on this iPhone. Your entries are still here. Retry the same change.")
                    return
                }
            }
            submitted = Submission(preview: preview, wording: original, draft: draft, version: version)
            if await model.addQuickGrocery(preview, selectedShopID: selectedID, workspaceID: workspaceID, quickDraft: version,
                authorize: { authorize() && model.shop?.id == selectedID }) { finishCommittedEntry() }
        }
    }

    private func finishCommittedEntry(announce: Bool = true) {
        guard authorize(), let submission = submitted, let shop = model.shop, shop.id == submission.preview.shopID,
              shop.importBatches.contains(where: { $0.id == submission.preview.id && $0.undoneAt == nil }) else { return }
        submitted = nil
        let preview = submission.preview
        // A first add creates a new, previously unaddressable list. Keep Return
        // focused on its empty field while SwiftUI switches the selected shop.
        if submission.draft.shopID == nil, currentDraft == nil {
            let key = LedgerStore.quickGroceryDraftOwner(persona: owner, shopID: shop.id)
            draft = try? QuickGroceryDraft(shopID: shop.id, store: submission.draft.store, owner: key, record: nil)
        }
        if submission.draft.version == submission.version && submission.draft.text == submission.wording {
            receipt = Receipt(batchID: preview.id, revisionID: shop.revisionID)
        }
        Task { await submission.draft.committed(submission.version, wording: submission.wording, revision: model.revision) }
        if announce && visible {
            editing = continueTyping
            UIAccessibility.post(notification: .announcement, argument: quickGroceryFormat("Added %@ to %@ on this iPhone.", preview.originalText, shop.title))
        }
    }
}

struct LedgerDepartmentPicker: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    let labels: [String]
    @State private var showingDepartments = false
    private var department: String { line.aisle }
    private var title: String { quickGroceryFormat("Department for %@", line.name) }

    var body: some View {
        Button { showingDepartments = true } label: {
            Label(department.isEmpty ? quickGroceryText("Set department") : department, systemImage: "chevron.up.chevron.down")
                .font(.footnote)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityHint(shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
            quickGroceryText("Applies to this list.") : quickGroceryText("Remembers this department for this product at this branch."))
        .accessibilityValue(department.isEmpty ? ledgerText("No aisle assigned") : department)
        .disabled(model.saving || model.hasPendingSave)
        .confirmationDialog(title, isPresented: $showingDepartments, titleVisibility: .visible) {
            ForEach([""] + labels, id: \.self) { label in
                Button {
                    Task {
                        _ = await model.change(key: "department-\(line.id)") { candidate in
                            guard candidate.selectedShopID == shop.id, let current = candidate.shops.first(where: { $0.id == shop.id }),
                                  current.revisionID == shop.revisionID, let source = current.lines.first(where: { $0.id == line.id }),
                                  candidate.listLayout.department(for: source, in: current) == department else { throw LedgerError.stalePreview }
                            try candidate.listLayout.setDepartment(label, for: source, in: current,
                                remember: !current.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } label: {
                    let value = label.isEmpty ? ledgerText("No aisle assigned") : label
                    if label == department { Label(value, systemImage: "checkmark") } else { Text(value) }
                }
            }
            Button(ledgerText("Cancel"), role: .cancel) {}
        }
    }
}
