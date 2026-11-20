import CoreDomain
import SwiftUI

func quickGroceryText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "QuickGrocery")
}

func quickGroceryFormat(_ key: String, _ value: String) -> String {
    String(format: quickGroceryText(key), locale: .current, value)
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
                QuickGroceryField(model: model, workspaceID: workspaceID, prominent: prominent, available: available, householdMember: household.projection != nil, authorize: {
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
            if prominent, scene == .active, model.hasPendingSave || model.error != nil || (model.saving && model.shop == nil) {
                LedgerSaveStatus(model: model)
            }
        }
    }

    private struct EntryOwner: Hashable { let persona: Data; let workspace: UUID }
}

private struct QuickGroceryField: View {
    @ObservedObject var model: LedgerModel
    let workspaceID: UUID
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
    @State private var undoBatch: UUID?
    @State private var review: Review?
    @FocusState private var editing: Bool

    private struct Review: Identifiable {
        let id = UUID()
        let shopID: UUID?
        let text: String
        let preview: StagedListImport?
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
                    submit()
                    return
                }
            }
            text = updated
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(quickGroceryText(householdMember ? "Add to my private list" : "Add a grocery"))
                .font(prominent ? .largeTitle.bold() : .headline)
                .foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Text(quickGroceryText("Grocery name")).font(.subheadline)
                .foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                TextField("", text: groceryInput, axis: .vertical)
                    .textFieldStyle(.plain).font(.body)
                    .fixedSize(horizontal: false, vertical: !text.isEmpty)
                    .frame(height: emptyLineHeight)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(editing ? Theme.action : Theme.controlEdge, lineWidth: editing ? 2 : 1) }
                    .focused($editing)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { editing = true })
                    .accessibilityLabel(quickGroceryText("Grocery name"))
                    .accessibilityIdentifier("quickGrocery.name")
                    .submitLabel(.next).onSubmit { submit() }
                Button(quickGroceryText("Add")) { submit() }
                    .buttonStyle(PrimaryAction()).fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(quickGroceryText("Add grocery"))
                    .accessibilityIdentifier("quickGrocery.add")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            if let batch = model.shop?.importBatches.last(where: { $0.id == undoBatch && $0.undoneAt == nil }) {
                let result = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
                result {
                    Label(quickGroceryFormat("Added %@", batch.originalText), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.onSelection)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("quickGrocery.added")
                    Button {
                        guard let shopID = model.shop?.id else { return }
                        Task {
                            if await model.editShop(key: "undo-quick-\(batch.id)", shopID: shopID,
                                authorize: { authorize() && model.shop?.id == shopID }, { try $0.undoImport(batchID: batch.id) }) {
                                undoBatch = nil
                            }
                        }
                    } label: {
                        Text(quickGroceryText("Undo")).underline()
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.onSelection)
                    .accessibilityLabel(quickGroceryFormat("Undo adding %@", batch.originalText))
                    .disabled(busy).accessibilityIdentifier("quickGrocery.undo")
                    if prominent {
                        RestorableShoppingListLink {
                            Text(quickGroceryText("View list")).underline()
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.onSelection)
                        .accessibilityIdentifier("quickGrocery.viewList")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 2)
                .background(Theme.selection, in: RoundedRectangle(cornerRadius: 12))
            }
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
                                   authorize: authorize, addingDisabled: busy, keepOnList: submit)
            }
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
            if undoBatch.flatMap({ id in model.shop?.importBatches.contains(where: { $0.id == id }) }) == true { return }
            text = ""; undoBatch = nil; submitted = nil; review = nil
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

    private func submit() {
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
        submitted = preview
        Task {
            defer { submitting = false }
            if await model.addQuickGrocery(preview, selectedShopID: selectedID, workspaceID: workspaceID,
                authorize: { authorize() && model.shop?.id == selectedID }) { finishCommittedEntry() }
        }
    }

    private func finishCommittedEntry(announce: Bool = true) {
        guard authorize(), let preview = submitted, model.shop?.id == preview.shopID,
              model.shop?.importBatches.contains(where: { $0.id == preview.id && $0.undoneAt == nil }) == true else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == preview.originalText { text = "" }
        submitted = nil
        undoBatch = preview.id
        if announce && visible {
            editing = true
            UIAccessibility.post(notification: .announcement, argument: quickGroceryFormat("Added %@", preview.originalText))
        }
    }
}

struct LedgerDepartmentPicker: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    let labels: [String]
    private var department: String { line.aisle }

    var body: some View {
        Menu {
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
        } label: {
            Text(department.isEmpty ? quickGroceryText("Department") : department)
                .font(.footnote).frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(quickGroceryFormat("Department for %@", line.name))
        .accessibilityHint(shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
            quickGroceryText("Applies to this list.") : quickGroceryText("Remembers this department for this product at this branch."))
        .accessibilityValue(department.isEmpty ? ledgerText("No aisle assigned") : department)
        .disabled(model.saving || model.hasPendingSave)
    }
}
