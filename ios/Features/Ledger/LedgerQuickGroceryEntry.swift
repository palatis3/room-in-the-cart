import CoreDomain
import SwiftUI

func quickGroceryText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "QuickGrocery")
}

func quickGroceryFormat(_ key: String, _ values: CVarArg...) -> String {
    String(format: quickGroceryText(key), locale: .current, arguments: values)
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
    @State private var text = ""
    @State private var recent: [String] = []
    @State private var visible = false
    @State private var submitting = false
    @State private var submitted: StagedListImport?
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
    }
    private var confirmedBatch: LedgerImportBatch? {
        // Keep confirmed entry feedback stable above an open keyboard. A later revision
        // invalidates the add-undo operation even if the original batch still exists.
        guard let receipt, let shop = model.shop, editing || shop.revisionID == receipt.revisionID else { return nil }
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
            text = updated
        })
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
                    .simultaneousGesture(TapGesture().onEnded { editing = true })
                Button(quickGroceryText("Add")) { submit() }
                    .buttonStyle(PrimaryAction()).fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(quickGroceryText("Add grocery"))
                    .accessibilityHint(quickGroceryFormat("For the list “%@”.", model.shop?.title ?? ledgerText("Pickup")))
                    .accessibilityIdentifier("quickGrocery.add")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
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
                            Button(name) { text = name }
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
            guard old != nil || next != submitted?.shopID else { return }
            if let receipt, model.shop?.importBatches.contains(where: { $0.id == receipt.batchID }) == true { return }
            text = ""; receipt = nil; submitted = nil; review = nil
        }
        .sheet(item: $review) { original in
            NavigationStack {
                if authorize(), model.shop?.id == original.shopID {
                    if let id = original.shopID {
                        LedgerImportView(model: model, shopID: id, prefill: original.text, initialPreview: original.preview,
                            authorizeEntry: { authorize() && model.shop?.id == id },
                            onSaved: { _ in if text == original.text { text = "" } })
                    } else {
                        FirstListEntry(model: model, prefill: original.text,
                            authorizeEntry: { authorize() && model.shop == nil }) { _ in review = nil; text = "" }
                    }
                }
            }
        }
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
        guard authorize(), !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let selectedID = model.shop?.id
        let shop = model.shop ?? ShoppingLedger(title: ledgerText("Pickup"))
        guard let preview = try? QuickGrocery.stage(text, in: shop) else {
            editing = false
            review = Review(shopID: selectedID, text: text,
                            preview: selectedID == nil ? nil : try? shop.stageImport(text: text))
            return
        }
        submitting = true
        continueTyping = keepKeyboard
        let original = text
        if !keepKeyboard { editing = false }
        Task {
            defer { submitting = false }
            if selectedID == nil {
                guard let store = model.firstListStore else { return }
                do {
                    let draft = try await store.firstListDraft(owner: owner)
                    guard authorize(), model.shop == nil, model.firstListStore === store else { return }
                    if draft != nil {
                        // The existing draft can keep or append the incoming wording in review.
                        editing = false
                        review = Review(shopID: nil, text: original, preview: nil)
                        return
                    }
                } catch {
                    model.error = ledgerText("Could not save on this iPhone. Your entries are still here. Retry the same change.")
                    return
                }
            }
            submitted = preview
            if await model.addQuickGrocery(preview, selectedShopID: selectedID, workspaceID: workspaceID,
                authorize: { authorize() && model.shop?.id == selectedID }) { finishCommittedEntry() }
        }
    }

    private func finishCommittedEntry(announce: Bool = true) {
        guard authorize(), let preview = submitted, let shop = model.shop, shop.id == preview.shopID,
              shop.importBatches.contains(where: { $0.id == preview.id && $0.undoneAt == nil }) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == preview.originalText { text = "" }
        submitted = nil
        receipt = Receipt(batchID: preview.id, revisionID: shop.revisionID)
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
