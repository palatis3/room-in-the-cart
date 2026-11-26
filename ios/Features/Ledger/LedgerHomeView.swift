import SwiftUI
import CoreDomain

private enum LedgerHomeSheet: Hashable, Identifiable {
    case newShop, entry, facts, history, layout, printList, familyGuide
    case inStore(UUID), shareItems(UUID), shoppingCSV(UUID), kits(UUID?), pastTrip(UUID), standing
    case renameShop(id: UUID, title: String)
    case editLine(workspace: UUID, shop: UUID, line: UUID)
    case editAmount(workspace: UUID, shop: UUID, line: UUID, source: UUID)
    var id: Self { self }
}

struct LedgerHomeView: View {
    private var dinnerPantry = ShoppingDinnerPantry()
    @ObservedObject var model: LedgerModel
    var onShopSelected: ((UUID) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: LedgerHomeSheet?
    @State private var showingShopPicker = false
    @State private var showingListOptions = false
    @State private var stapleRecallShopID: UUID?
    private enum Focus: Hashable { case result, error, undo, line(UUID), amount(UUID) }
    @State private var editedAmountID: UUID?
    private enum SearchAnchor { case empty }
    @State private var submittedSearch = false
    @State private var returnToLine: UUID?
    @State private var checkCue: GroceryCheckCue?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    @AccessibilityFocusState private var focus: Focus?

    init(model: LedgerModel, onShopSelected: ((UUID) -> Void)? = nil) {
        self.model = model
        self.onShopSelected = onShopSelected
    }

    var body: some View {
        ledgerContent
            .background(Theme.canvas)
            .task { await model.open() }
            .navigationDestination(item: $stapleRecallShopID) { shopID in
                StapleRecallView(ledger: model, targetID: shopID)
            }
            .sheet(item: $sheet, onDismiss: {
                if let id = editedAmountID, UIAccessibility.isVoiceOverRunning { focus = .amount(id) }
                editedAmountID = nil
            }) { destination in
                switch destination {
                case .shareItems(let id):
                    PrivateShoppingSheet(model: model) {
                        TripHandoffEntry(model: model, shopID: id)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(ledgerText("Close")) { sheet = nil }
                                        .accessibilityIdentifier("tripShare.close")
                                }
                            }
                    }
                case .shoppingCSV(let id):
                    PrivateShoppingSheet(model: model) { ShoppingCSVImportView(model: model, shopID: id) }
                case .inStore(let id):
                    PrivateShoppingSheet(model: model) {
                        InStoreShoppingView(model: model, shopID: id) { selected in
                            sheet = nil
                            onShopSelected?(selected)
                        }
                    }
                case .pastTrip(let id):
                    PrivateShoppingSheet(model: model) { PreviousGroceryTrips(model: model, destinationID: id) }
                case .kits(let id):
                    PrivateShoppingSheet(model: model) { ShoppingKitsView(model: model, shopID: id) }
                case .layout:
                    PrivateShoppingSheet(model: model) { existingSheet(destination) }
                case .standing:
                    PrivateShoppingSheet(model: model) { StandingListView(model: model) }
                default:
                    NavigationStack { existingSheet(destination) }
                }
            }
            .onChange(of: model.error) { _, error in if error != nil { focus = .error } }
    }

    private var ledgerContent: some View {
        VStack(spacing: 0) {
            if model.ready, let shop = model.shop {
                if !dynamicTypeSize.isAccessibilitySize { controls(shop) }
                ScrollViewReader { reader in
                    let dinner = dinnerPantry.status(in: shop, ledger: model)
                    let covered = dinner.covered
                    let reviewIDs = Set(dinner.pending.flatMap { $0.lines.map(\.id) })
                    let groups = model.workspace.listLayout.groups(shop: shop, search: model.search, excluding: covered.union(reviewIDs))
                    JournalList {
                        if dynamicTypeSize.isAccessibilitySize {
                            Section {
                                shopPicker(shop).buttonStyle(.borderless)
                                listOptions(shop).buttonStyle(.borderless)
                                Text(ledgerText("Search active items"))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .listRowSeparator(.hidden, edges: .bottom)
                                    .accessibilityHidden(true)
                                searchField.listRowSeparator(.hidden, edges: .top)
                                importButton
                            }
                        }
                        if model.error != nil || model.hasPendingSave {
                            Section { LedgerSaveStatus(model: model).accessibilityFocused($focus, equals: .error) }
                        }
                        Section { LedgerQuickGroceryEntry(model: model) }
                        Section {
                            TripDepartureLink(model: model, shop: shop)
                            Button { sheet = .inStore(shop.id) } label: {
                                Label(shoppingText("Shop in store"), systemImage: "cart")
                                    .font(.headline).frame(minHeight: 44)
                            }.accessibilityIdentifier("ledgerInStore")
                        }
                        let checked = shop.recentlyChecked.filter { !$0.isHandled }
                        if let last = checked.first {
                            Section {
                                checkedResult(last, shop: shop)
                                    .listRowBackground(Theme.selection)
                                recentHistory(count: checked.count)
                            }
                        }
                        grocerySections(in: shop, groups: groups, dinner: dinner,
                                        hasExcludedLines: !covered.isEmpty || !reviewIDs.isEmpty,
                                        hasCheckedItems: !checked.isEmpty)
                        Section {
                            factsSummary(shop)
                        }
                        Section {
                            Button { sheet = .history } label: {
                                Label(ledgerText("Recently checked, Handled and Trash"), systemImage: "clock.arrow.circlepath")
                                    .frame(minHeight: 44, alignment: .leading)
                            }.accessibilityIdentifier("ledgerHistory")
                            if let batch = shop.importBatches.last(where: { $0.undoneAt == nil }) {
                                let entries = shop.remainingEntries(in: batch)
                                if !entries.isEmpty {
                                    Button(ledgerFormat(entries.count == 1 ? "Undo last import · %lld entry" : "Undo last import · %lld entries", Int64(entries.count)), role: .destructive) {
                                        Task {
                                            _ = await model.editShop(key: "undo-\(batch.id)", shopID: shop.id) { current in
                                                guard current.revisionID == shop.revisionID else { throw LedgerError.stalePreview }
                                                try current.undoImport(batchID: batch.id)
                                            }
                                            focus = model.error == nil ? .result : .error
                                        }
                                    }.disabled(model.saving || model.hasPendingSave)
                                        .accessibilityIdentifier("ledgerUndoImport")
                                }
                            }
                        }
                        if model.error == nil && !model.hasPendingSave {
                            Section { LedgerSaveStatus(model: model).accessibilityFocused($focus, equals: .result) }
                        }
                    }.listStyle(.plain)
                    .onChange(of: submittedSearch) { _, _ in
                        guard !model.search.isEmpty else { return }
                        if let first = groups.first(where: { !$0.lines.isEmpty })?.lines.first {
                            reader.scrollTo(first.id, anchor: .top)
                        } else if let first = shop.search(model.search).first(where: { covered.contains($0.id) || reviewIDs.contains($0.id) }) {
                            reader.scrollTo(first.id, anchor: .top)
                        } else {
                            reader.scrollTo(SearchAnchor.empty, anchor: .top)
                        }
                    }
                    .onChange(of: returnToLine) { _, line in
                        guard let line else { return }
                        reader.scrollTo(line, anchor: .center)
                        Task { @MainActor in
                            await Task.yield()
                            guard returnToLine == line else { return }
                            focus = .line(line)
                            returnToLine = nil
                        }
                    }
                }
            } else if model.opening {
                ProgressView(ledgerText("Opening your pickups…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(ledgerText("Your pickup, one list")).font(.title2.bold())
                        Text(ledgerText("Type or paste a list, keep each meal's needs, and pick up where you left off."))
                        LedgerSaveStatus(model: model)
                        if model.ready {
                            if !model.workspace.shoppingLists.kits.isEmpty {
                                Button(shoppingText("Shopping kits")) { sheet = .kits(nil) }
                            }
                            Button(shoppingText("Standing list")) { sheet = .standing }
                            Button(ledgerText("Start pickup")) { sheet = .newShop }
                                .buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerStartShop")
                                .disabled(model.saving || model.hasPendingSave)
                        } else {
                            Button(ledgerText("Try opening again")) { Task { await model.open() } }
                                .buttonStyle(PrimaryAction())
                        }
                    }.padding()
                }.frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func grocerySections(in shop: ShoppingLedger, groups: [LedgerListLayout.Group],
                                            dinner: ShoppingDinnerPantry.Status, hasExcludedLines: Bool,
                                            hasCheckedItems: Bool) -> some View {
        let exclusions = shop.listExclusions
        let packages = shop.itemPackages
        let typedBatches = shop.typedItemBatchIDs
        let departmentChoices = model.workspace.listLayout.departmentChoices(in: shop)
        DinnerPantryReviewSection(shopID: shop.id, reviews: dinner.pending,
            matching: model.search.isEmpty || dinner.pending.isEmpty ? nil : Set(shop.search(model.search).map(\.id)))
        if groups.allSatisfy({ $0.lines.isEmpty }) {
            Section(ledgerText("Shopping list")) {
                Text(model.search.isEmpty && (hasCheckedItems || hasExcludedLines) ? quickGroceryText("No active items.") :
                    ledgerText(model.search.isEmpty ? "Add the groceries you need for this pickup." : "No active items match your search."))
                    .foregroundStyle(Theme.secondary)
                    .id(SearchAnchor.empty)
                if !hasCheckedItems { recentHistory(count: 0) }
            }
        } else {
            ForEach(groups) { group in
                Section(group.aisle.isEmpty ? ledgerText(model.workspace.listLayout.layout(for: shop).mode == .aisle ? "No aisle assigned" : "Shopping list") : group.aisle) {
                    ForEach(group.lines) { line in
                        row(line, shop: shop, packages: packages[line.id] ?? [], typedBatches: typedBatches,
                            exclusions: exclusions[line.id], departmentChoices: departmentChoices)
                            .id(line.id)
                    }
                }
            }
        }
        if !dinner.atHome.isEmpty {
            Section(dinnerText("Using food at home")) {
                ForEach(shop.search(model.search).filter { dinner.atHome.contains($0.id) }) { line in
                    Label(line.name, systemImage: "house").id(line.id)
                }
            }
        }
        if !dinner.used.isEmpty {
            Section(dinnerText("Used for dinner")) {
                ForEach(shop.search(model.search).filter { dinner.used.contains($0.id) }) { line in
                    Label(line.name, systemImage: "fork.knife").id(line.id)
                }
            }
        }
    }

    @ViewBuilder private func existingSheet(_ destination: LedgerHomeSheet) -> some View {
        switch destination {
        case .inStore, .shareItems, .shoppingCSV, .kits, .pastTrip, .standing: EmptyView()
        case .newShop: LedgerNewShopView(model: model, onShopSelected: onShopSelected)
        case let .renameShop(id, title):
            LedgerNewShopView(model: model, shopID: id, title: title)
        case let .editLine(workspaceID, shopID, lineID):
            if model.sourceWorkspaceID == workspaceID, let shop = model.shop, shop.id == shopID,
               let line = shop.lines.first(where: { $0.id == lineID && !$0.isChecked && !$0.isTrashed && !$0.isHandled }) {
                LedgerLineEditor(model: model, shop: shop, line: line)
            } else {
                Text(ledgerText("This pickup changed. Close these edits and reopen the current pickup details."))
            }
        case let .editAmount(workspace, shopID, lineID, sourceID):
            if model.sourceWorkspaceID == workspace, let shop = model.shop, shop.id == shopID,
               let line = shop.lines.first(where: { $0.id == lineID }),
               let source = shop.ordinaryQuantitySource(for: line, contributions: shop.contributions(forLineID: lineID),
                                                        typedItemBatches: shop.typedItemBatchIDs), source.id == sourceID {
                LedgerContributionEditor(model: model, shopID: shopID, contribution: source)
            } else {
                Text(ledgerText("This pickup changed. Close these edits and reopen the current pickup details."))
            }
        case .entry:
            if let shop = model.shop { LedgerImportView(model: model, shopID: shop.id) }
        case .facts:
            if let shop = model.shop { LedgerFactsView(model: model, shop: shop) }
        case .layout:
            if let shop = model.shop { LedgerLayoutEditor(model: model, shop: shop) }
        case .familyGuide:
            FamilyPermissionGuide { sheet = nil }
        case .printList:
            if let shop = model.shop { LargePrintList(shop: shop, layout: model.workspace.listLayout) }
        case .history:
            if let shop = model.shop { LedgerHistoryView(model: model, shopID: shop.id) }
        }
    }

    private func controls(_ shop: ShoppingLedger) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                shopPicker(shop)
                Spacer()
                listOptions(shop)
            }
            searchField
            importButton
        }.padding(.horizontal).padding(.bottom, 10).background(Theme.canvas)
    }

    private func shopPicker(_ shop: ShoppingLedger) -> some View {
        Button { showingShopPicker = true } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Label {
                    Text(shop.title).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "chevron.down") }
                .font(.headline).frame(minHeight: 44)
            } else {
                Label(shop.title, systemImage: "chevron.down").font(.headline).frame(minHeight: 44)
            }
        }
        .disabled(model.saving || model.hasPendingSave)
        .accessibilityIdentifier("ledgerShopPicker")
        .confirmationDialog(ledgerFormat("Current list: %@", shop.title), isPresented: $showingShopPicker, titleVisibility: .visible) {
            ForEach(model.workspace.shops.filter { $0.id != shop.id }, id: \.id) { item in
                Button(item.title) { Task { await model.selectShop(item.id, onSelected: onShopSelected) } }
            }
            Button(ledgerText("Rename pickup")) { sheet = .renameShop(id: shop.id, title: shop.title) }
                .accessibilityIdentifier("ledgerRenameShop")
            Button(ledgerText("Start another pickup")) { sheet = .newShop }
            Button(ledgerText("Cancel"), role: .cancel) {}
        }
    }

    private func listOptions(_ shop: ShoppingLedger) -> some View {
        Button { showingListOptions = true } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Text(ledgerText("List options")).frame(minHeight: 44)
            } else {
                Label(ledgerText("List options"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .accessibilityIdentifier("ledgerListOptions")
        .confirmationDialog(ledgerText("List options"), isPresented: $showingListOptions, titleVisibility: .visible) {
            Button(ledgerText("Import shopping CSV")) { sheet = .shoppingCSV(shop.id) }
                .accessibilityIdentifier("ledger.shoppingCSV")
            Button(tripText("Preview list copy")) { sheet = .shareItems(shop.id) }
                .accessibilityIdentifier("tripShare.previewCopy")
            Button(GuardianCopy.text("Child permissions")) { sheet = .familyGuide }
            if model.workspace.shops.contains(where: { $0.id != shop.id }) {
                Button(shoppingText("Choose groceries from a previous trip")) { sheet = .pastTrip(shop.id) }
            }
            Button(shoppingText("Shopping kits")) { sheet = .kits(shop.id) }
            Button(shoppingText("Standing list")) { sheet = .standing }
            Button(ledgerText("List order and aisles")) { sheet = .layout }
            Button(ledgerText("List history")) { sheet = .history }
            Button(ledgerText("Review prior staples")) { stapleRecallShopID = shop.id }
            Button(ledgerText("Large-print list")) { sheet = .printList }
            Button(ledgerText("Cancel"), role: .cancel) {}
        }
    }

    private var searchField: some View {
        let title = ledgerText("Search active items")
        let prompt = dynamicTypeSize.isAccessibilitySize ? Text(verbatim: "") : Text(title).foregroundStyle(Theme.secondary)
        return HStack {
            TextField(title, text: $model.search, prompt: prompt)
                .submitLabel(.search)
                .onSubmit { submittedSearch.toggle() }
                .textFieldStyle(.roundedBorder).accessibilityLabel(title).accessibilityIdentifier("ledgerSearch")
            if !model.search.isEmpty {
                Button { model.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(ledgerText("Clear search"))
                .accessibilityIdentifier("ledgerClearSearch")
            }
        }
    }

    private var importButton: some View {
        Button { sheet = .entry } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Text(ledgerText("Add several items"))
            } else {
                Label(ledgerText("Add several items"), systemImage: "plus")
            }
        }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
            .accessibilityIdentifier("ledgerImport")
    }

    private func factsSummary(_ shop: ShoppingLedger) -> some View {
        Button { sheet = .facts } label: {
            VStack(alignment: .leading, spacing: 7) {
                Label(ledgerText("Pickup details"), systemImage: "slider.horizontal.3").font(.headline)
                Text(shop.basis.branch.isEmpty ? ledgerText("Store not set") : shop.basis.branch)
                Text(shop.basis.mode.ledgerLabel + " · " + ledgerFormat("Currency: %@", shop.basis.currency.rawValue))
                if let date = shop.basis.slot { Text(ledgerDate(date, zone: shop.basis.timeZoneIdentifier)) }
                else { Text(ledgerText("Date not set")) }
                if let cap = shop.basis.cap {
                    Text("\(moneyText(cap)) · \(shop.basis.capScope.ledgerLabel)")
                } else { Text(ledgerText("No spending cap entered")) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("ledgerFacts")
            .disabled(model.saving || model.hasPendingSave)
    }

    private func recentHistory(count: Int) -> some View {
        Button { sheet = .history } label: {
            Label {
                Text(ledgerText("Recently checked"))
                Text(count.formatted()).foregroundStyle(Theme.secondary)
            } icon: { Image(systemName: "clock.arrow.circlepath") }
            .frame(minHeight: 44)
        }
        .accessibilityLabel(ledgerText("Recently checked"))
        .accessibilityValue(count.formatted())
        .accessibilityIdentifier("ledgerRecentlyChecked")
    }

    private func checkedResult(_ line: ShoppingLine, shop: ShoppingLedger) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Label(quickGroceryFormat("Checked %@", line.name), systemImage: "checkmark.square.fill")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task {
                    guard await changeCheck(line, shop: shop, checked: false) else { focus = .error; return }
                    let visible = model.shop.map { model.workspace.listLayout.groups(shop: $0, search: model.search, excluding: dinnerPantry.covered(in: $0, ledger: model)) } ?? []
                    if visible.contains(where: { $0.lines.contains(where: { $0.id == line.id }) }) {
                        returnToLine = line.id
                    } else { focus = .result }
                }
            } label: { Text(quickGroceryText("Undo")).underline().frame(minWidth: 44, minHeight: 44) }
            .buttonStyle(.borderless).disabled(model.saving || model.hasPendingSave)
            .accessibilityLabel(quickGroceryFormat("Undo checking %@", line.name))
            .accessibilityIdentifier("ledgerUndoCheck")
            .accessibilityFocused($focus, equals: .undo)
        }.foregroundStyle(Theme.onSelection)
            .overlay { GroceryCheckInset(cue: checkCue, lineID: line.id) }
    }

    private func changeCheck(_ line: ShoppingLine, shop: ShoppingLedger, checked: Bool) async -> Bool {
        let saved = await model.changeGroceryCheck(line, in: shop, checked: checked)
        if saved { checkCue = checked && !reduceMotion && scene == .active ? GroceryCheckCue(lineID: line.id) : nil }
        return saved
    }

    private func row(_ line: ShoppingLine, shop: ShoppingLedger, packages: [BasketPackage], typedBatches: Set<UUID>,
                     exclusions: String?, departmentChoices: [String]) -> some View {
        let measure = TripMeasure(shop, line: line, packages: packages)
        let source = shop.ordinaryQuantitySource(for: line, contributions: shop.contributions(forLineID: line.id), typedItemBatches: typedBatches)
        let quantity = shop.groceryRowAmount(line, measure: measure)
        let spokenAmount = shop.tripAmountLabel(line, measure: measure)
        let tripReason = shop.mainTripReasonID == line.id ? tripReminderText("Main reason for this trip") : ""
        let details = [spokenAmount ?? "", exclusions ?? "", line.notes, line.aisle, tripReason].filter { !$0.isEmpty }.joined(separator: ", ")
        let editItem = {
            guard !model.saving, !model.hasPendingSave, model.shop?.id == shop.id,
                  let workspace = model.sourceWorkspaceID else { return }
            sheet = .editLine(workspace: workspace, shop: shop.id, line: line.id)
        }
        return HStack(alignment: .top, spacing: 10) {
            Button {
                let visible = model.workspace.listLayout.groups(shop: shop, search: model.search, excluding: dinnerPantry.covered(in: shop, ledger: model)).flatMap(\.lines)
                let index = visible.firstIndex { $0.id == line.id }
                let next = index.flatMap { index in
                    visible.dropFirst(index + 1).first ?? visible.prefix(index).last
                }
                Task {
                    guard await changeCheck(line, shop: shop, checked: true) else { focus = .error; return }
                    if UIAccessibility.isVoiceOverRunning, let next { returnToLine = next.id }
                    else if next == nil { focus = .undo }
                }
            } label: {
                Image(systemName: "square").font(.title2.weight(.regular))
                    .foregroundStyle(Theme.controlEdge).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).disabled(model.saving || model.hasPendingSave)
            .accessibilityLabel(ledgerFormat("Check %@", line.name))
            .accessibilityHint(ledgerText("Moves this item to Recently checked."))
            .accessibilityFocused($focus, equals: .line(line.id))
            .accessibilityIdentifier("ledgerCheck-\(line.id)")
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 6))
            layout {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink {
                        LedgerIngredientView(model: model, shopID: shop.id, lineID: line.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            GroceryNameAndAmount(name: line.name, amount: source == nil || model.sourceWorkspaceID == nil ? quantity : nil)
                            TripRequestSummary(shop: shop, line: line)
                            if let exclusions { Text(verbatim: exclusions) }
                            if !line.notes.isEmpty { Text(line.notes) }
                        }.padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }.accessibilityLabel(ledgerFormat("Inspect %@", line.name))
                        .buttonStyle(.plain)
                        .accessibilityValue(Text(verbatim: details))
                        .accessibilityIdentifier("ledgerInspect-\(line.id)")
                        .accessibilityAction(named: Text(ledgerText("Edit item")), editItem)
                    LedgerDepartmentPicker(model: model, shop: shop, line: line, labels: departmentChoices)
                }

                if let source, let workspace = model.sourceWorkspaceID {
                    GroceryAmountEditButton(amount: quantity, name: line.name, spokenAmount: spokenAmount) {
                        editedAmountID = line.id
                        sheet = .editAmount(workspace: workspace, shop: shop.id, line: line.id, source: source.id)
                    }
                    .accessibilityFocused($focus, equals: .amount(line.id))
                    .accessibilityIdentifier("ledgerEditAmount-\(line.id)")
                    .disabled(model.saving || model.hasPendingSave)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: editItem) {
                Label(ledgerText("Edit item"), systemImage: "pencil")
            }
            .tint(Theme.action)
            .disabled(model.saving || model.hasPendingSave)
            .accessibilityIdentifier("ledgerEditRow-\(line.id)")
        }
    }
}

extension LedgerModel {
    func changeGroceryCheck(_ line: ShoppingLine, in shop: ShoppingLedger, checked: Bool,
                            authorize: (@MainActor () -> Bool)? = nil) async -> Bool {
        await editShop(key: "check-\(line.id)", shopID: shop.id, authorize: authorize) { current in
            guard self.workspace.selectedShopID == shop.id, current.revisionID == shop.revisionID,
                  let source = current.lines.first(where: { $0.id == line.id }),
                  source.checkedAt == line.checkedAt, source.isChecked != checked, !source.isHandled, !source.isTrashed else {
                throw LedgerError.stalePreview
            }
            if !checked, source.tripUndo?.action == .pick {
                try current.undoTripChange(lineID: line.id, expectedRevision: shop.revisionID)
            } else {
                try current.setChecked(lineID: line.id, checked: checked)
            }
        }
    }
}

private struct GroceryAmountEditButton: View {
    let amount: String?
    let name: String
    let spokenAmount: String?
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 6) {
                if let amount {
                    Text(verbatim: amount).monospacedDigit().foregroundStyle(Theme.ink)
                }
                Image(systemName: "pencil").font(.footnote).foregroundStyle(Theme.action)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(quickGroceryText("Edit quantity and notes"))
        .accessibilityValue([name, spokenAmount].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Keep the shopping amount beside the name where space permits. An amount can be
/// absent on an ordinary typed grocery, or carry a meaningful unresolved state.
struct GroceryNameAndAmount: View {
    let name: String
    let amount: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(verbatim: name)
                .font(.headline).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let amount {
                Text(verbatim: amount).font(.body).monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
    }
}

struct ShopGroceryPreview: View {
    private var dinnerPantry = ShoppingDinnerPantry()
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let showsListLink: Bool
    let authorize: @MainActor () -> Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    private enum Destination: Hashable, Identifiable {
        case detail(UUID), amount(line: UUID, source: UUID)
        var id: Self { self }
    }
    @State private var destination: Destination?
    @State private var editedAmountID: UUID?
    @AccessibilityFocusState private var focusedAmountID: UUID?
    @Environment(\.scenePhase) private var scene
    @State private var retainedIDs: [UUID] = []
    @State private var measuredHeights: [UUID: CGFloat] = [:]
    @State private var retainedHeights: [UUID: CGFloat] = [:]

    private struct RowHeights: PreferenceKey {
        static let defaultValue: [UUID: CGFloat] = [:]
        static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
            value.merge(nextValue()) { _, latest in latest }
        }
    }

    init(model: LedgerModel, shop: ShoppingLedger, showsListLink: Bool, authorize: @escaping @MainActor () -> Bool) {
        self.model = model
        self.shop = shop
        self.showsListLink = showsListLink
        self.authorize = authorize
    }

    private func releaseRows() {
        retainedIDs = []
        retainedHeights = [:]
    }

    private func previewRows(active: [ShoppingLine]) -> [ShoppingLine] {
        guard !retainedIDs.isEmpty else { return Array(active.prefix(4)) }
        // Keep only IDs in view state. Every name, amount and check comes from the current shop.
        let retained = retainedIDs.compactMap { id in
            shop.lines.first { $0.id == id && !$0.isTrashed && !$0.isHandled }
        }
        let ids = Set(retained.map(\.id))
        return retained + active.lazy.filter { !ids.contains($0.id) }.prefix(4 - retained.count)
    }

    var body: some View {
        let dinner = dinnerPantry.status(in: shop, ledger: model)
        let reviewIDs = Set(dinner.pending.flatMap { $0.lines.map(\.id) })
        let excluded = dinner.covered.union(reviewIDs)
        let rows = model.workspace.listLayout.groups(shop: shop, excluding: excluded).flatMap(\.lines)
        let visible = previewRows(active: rows).filter { !excluded.contains($0.id) }
        let packages = shop.itemPackages
        let typedItemBatches = shop.typedItemBatchIDs
        VStack(alignment: .leading, spacing: 0) {
            if model.error != nil || model.hasPendingSave {
                LedgerSaveStatus(model: model, showsLastSave: false)
            }
            ForEach(dinner.pending) { review in
                VStack(alignment: .leading) {
                    Text(verbatim: review.mealTitle).font(.headline)
                    Text(verbatim: review.lines.map(\.name).formatted(.list(type: .and)))
                    DinnerShoppingCheckLink(shopID: shop.id, occurrenceID: review.id, linkedProducts: true)
                }
            }
            ForEach(visible) { line in
                let measure = TripMeasure(shop, line: line, packages: packages[line.id] ?? [])
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        if retainedIDs.isEmpty {
                            retainedIDs = visible.map(\.id)
                            retainedHeights = measuredHeights
                        }
                        Task {
                            let saved = await model.changeGroceryCheck(line, in: shop, checked: !line.isChecked, authorize: authorize)
                            if saved && !line.isChecked && UIAccessibility.isVoiceOverRunning {
                                UIAccessibility.post(notification: .announcement, argument: quickGroceryFormat("Checked %@", line.name))
                            }
                        }
                    } label: {
                        Image(systemName: line.isChecked ? "checkmark.square.fill" : "square").font(.title2)
                            .foregroundStyle(line.isChecked ? Theme.action : Theme.controlEdge)
                            .frame(width: 44, height: 48).contentShape(Rectangle())
                    }.accessibilityLabel(line.isChecked ? shoppingFormat("Uncheck %@", line.name) : ledgerFormat("Check %@", line.name))
                        .accessibilityAddTraits(line.isChecked ? .isSelected : [])
                        .accessibilityIdentifier("shop.check-\(line.id)")
                    let amount = shop.groceryRowAmount(line, measure: measure)
                    let source = shop.ordinaryQuantitySource(for: line,
                        contributions: shop.contributions(forLineID: line.id), typedItemBatches: typedItemBatches)
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                        : AnyLayout(HStackLayout(spacing: 4))
                    layout {
                        Button { destination = .detail(line.id) } label: {
                            GroceryNameAndAmount(name: line.name, amount: source == nil ? amount : nil)
                                .frame(minHeight: 48).contentShape(Rectangle())
                        }
                        .accessibilityLabel(ledgerFormat("Inspect %@", line.name))
                        .accessibilityValue(shop.tripAmountLabel(line, measure: measure) ?? "")
                        .accessibilityIdentifier("shop.inspect-\(line.id)")
                        if let source {
                            GroceryAmountEditButton(amount: amount, name: line.name, spokenAmount: shop.tripAmountLabel(line, measure: measure)) {
                                editedAmountID = line.id
                                destination = .amount(line: line.id, source: source.id)
                            }
                            .accessibilityFocused($focusedAmountID, equals: line.id)
                            .accessibilityIdentifier("shop.editAmount-\(line.id)")
                        }
                    }
                }
                .padding(.vertical, 3)
                .frame(minHeight: retainedHeights[line.id], alignment: .top)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: RowHeights.self, value: [line.id: geometry.size.height])
                    }
                    .accessibilityHidden(true).allowsHitTesting(false)
                }
                .disabled(model.saving || model.hasPendingSave)
            }
            if !visible.isEmpty { Divider() }
            if !rows.isEmpty, !visible.isEmpty, visible.allSatisfy(\.isChecked) {
                Button(quickGroceryText("Show next groceries"), action: releaseRows)
                    .frame(minHeight: 44).foregroundStyle(Theme.action)
            }
            if showsListLink {
                RestorableShoppingListLink {
                    Label(rows.count > 4 ? quickGroceryFormat("View all %lld groceries", Int64(rows.count)) :
                            quickGroceryText("View shopping list"), systemImage: "list.bullet")
                        .frame(minHeight: 44)
                }
                .foregroundStyle(Theme.action)
            }
            if let last = shop.recentlyChecked.first(where: { !$0.isHandled }) {
                Button {
                    Task {
                        _ = await model.changeGroceryCheck(last, in: shop, checked: false, authorize: authorize)
                    }
                } label: {
                    Label(quickGroceryFormat("Undo checking %@", last.name), systemImage: "arrow.uturn.backward")
                        .frame(minHeight: 44)
                }.foregroundStyle(Theme.action)
                    .disabled(model.saving || model.hasPendingSave)
                    .accessibilityIdentifier("shop.undoCheck")
            }
        }
        .buttonStyle(.plain)
        .onPreferenceChange(RowHeights.self) { measuredHeights = $0 }
        .onDisappear(perform: releaseRows)
        .onChange(of: scene) { _, phase in if phase == .background { releaseRows() } }
        .onChange(of: shop.importBatches.last?.id) { _, _ in releaseRows() }
        .onChange(of: typeSize) { _, _ in releaseRows() }
        .sheet(item: $destination, onDismiss: {
            if let id = editedAmountID, authorize(), UIAccessibility.isVoiceOverRunning { focusedAmountID = id }
            editedAmountID = nil
        }) { target in
            PrivateShoppingSheet(model: model) {
                if let current = model.shop, current.id == shop.id {
                    switch target {
                    case let .detail(id):
                        LedgerIngredientView(model: model, shopID: current.id, lineID: id)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(ledgerText("Close")) { destination = nil }
                                }
                            }
                    case let .amount(lineID, sourceID):
                        if let line = current.lines.first(where: { $0.id == lineID }),
                           let source = current.ordinaryQuantitySource(for: line, contributions: current.contributions(forLineID: lineID),
                                                                       typedItemBatches: current.typedItemBatchIDs), source.id == sourceID {
                            LedgerContributionEditor(model: model, shopID: current.id, contribution: source)
                        } else {
                            Text(ledgerText("This pickup changed. Close these edits and reopen the current pickup details."))
                        }
                    }
                }
            }
        }
    }
}

struct LedgerSaveStatus: View {
    @ObservedObject var model: LedgerModel
    var showsLastSave = true
    var onRetried: (() -> Void)? = nil
    private enum ResultFocus: Hashable { case failure, saved }
    @AccessibilityFocusState private var resultFocus: ResultFocus?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("ledgerError")
                    .accessibilityFocused($resultFocus, equals: .failure)
            }
            if model.saving {
                ProgressView(ledgerText("Saving…"))
            } else if model.hasPendingSave {
                // Keep each recovery action independent inside Form and List rows.
                Button(ledgerText("Retry save")) { Task { if await model.retrySave() { onRetried?() } } }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("ledgerRetrySave")
                Button(ledgerText("Discard unsaved change"), role: .destructive) { Task { await model.discardPendingSave() } }
                    .buttonStyle(.borderless)
            } else if showsLastSave, let savedAt = model.savedAt {
                Label(ledgerText("Saved on this iPhone"), systemImage: "checkmark.circle")
                    .accessibilityFocused($resultFocus, equals: .saved)
                Text(savedAt.formatted(date: .complete, time: .shortened)).font(.footnote)
            } else if showsLastSave && model.ready { Text(ledgerText("Local to this iPhone")).font(.footnote) }
        }.fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.error) { _, error in if error != nil { resultFocus = .failure } }
            .onChange(of: model.saving) { _, saving in if !saving && model.error == nil { resultFocus = .saved } }
    }
}

struct LedgerNewShopView: View {
    @ObservedObject var model: LedgerModel
    @Environment(\.dismiss) private var dismiss
    private let originalID: UUID?
    @State private var currency: Currency = .groceryDefault()
    private let namingShoppingList: Bool
    private let originalTitle: String
    private let onShopSelected: ((UUID) -> Void)?
    private let authorize: (@MainActor () -> Bool)?
    @FocusState private var editingName: Bool
    @State private var title: String

    init(model: LedgerModel, shopID: UUID? = nil, title: String = "", namingShoppingList: Bool = false, authorize: (@MainActor () -> Bool)? = nil, onShopSelected: ((UUID) -> Void)? = nil) {
        self.model = model
        self.namingShoppingList = namingShoppingList && shopID == nil
        self.onShopSelected = onShopSelected
        self.authorize = authorize
        originalID = shopID
        originalTitle = title
        _title = State(initialValue: title)
    }

    private var createLabel: String {
        namingShoppingList ? dinnerText("Create shopping list") : ledgerText("Start pickup")
    }

    var body: some View {
        WorkingForm {
            WorkingField(namingShoppingList ? dinnerText("Shopping list name (required)") : ledgerText("Pickup name (required)")) {
                TextField(namingShoppingList ? dinnerText("Shopping list name (required)") : ledgerText("Pickup name"), text: $title, prompt: Text(verbatim: "—"), axis: .vertical)
                    .focused($editingName).accessibilityIdentifier("ledgerShopName")
            }.contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { editingName = true })
                .disabled(model.saving || model.hasPendingSave)
            if originalID == nil {
                GroceryCurrencyPicker(selection: $currency)
                    .accessibilityIdentifier("ledgerShopCurrency")
                    .disabled(model.saving || model.hasPendingSave)
            }
            if model.saving || model.hasPendingSave || model.error != nil {
                LedgerSaveStatus(model: model, showsLastSave: false, onRetried: { dismiss() })
            }
            Button(originalID == nil ? createLabel : ledgerText("Save name")) {
                Task { await save() }
            }.buttonStyle(PrimaryAction())
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving || model.hasPendingSave)
                .accessibilityIdentifier(originalID == nil ? "ledgerCreateShop" : "ledgerSaveShopName")
        }.keyboardDoneAction(visible: editingName, title: ledgerText("Done"), identifier: "ledger.shopName.done") { editingName = false }
            .scrollDismissesKeyboard(.interactively).workingSurface()
            .navigationTitle(originalID == nil ? createLabel : ledgerText("Rename pickup"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }

    private func save() async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, authorize?() != false else { return }
        editingName = false
        if let id = originalID {
            if await model.editShop(key: "rename-\(id)", shopID: id, { shop in
                guard model.workspace.selectedShopID == id, shop.title == originalTitle else { throw LedgerError.stalePreview }
                shop.title = name
            }) { dismiss() }
        } else if await model.startShop(title: name, currency: currency, authorize: authorize, onSelected: onShopSelected) { dismiss() }
    }
}

struct CheckedGroceriesHistoryLink: View {
    @ObservedObject var model: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @State private var opened: Target?

    private struct Target: Identifiable, Equatable {
        let id: UUID
        let workspace: UUID
        let owner: CapturePrivateIdentity
    }
    private var target: Target? {
        guard model.firstListStore != nil, let workspace = model.sourceWorkspaceID,
              let shop = model.shop, UIApplication.shared.isProtectedDataAvailable,
              child?.presented != true, household.projection?.grantId == nil,
              let owner = CapturePrivateIdentity.current(access: access, household: household) else { return nil }
        return Target(id: shop.id, workspace: workspace, owner: owner)
    }

    var body: some View {
        Group {
            if let current = target {
                Button { opened = current } label: {
                    Label(quickGroceryText("Recently checked groceries"), systemImage: "checklist")
                }.accessibilityIdentifier("records.checkedGroceries")
            }
        }
        .sheet(item: $opened) { original in
            PrivateShoppingSheet(model: model) {
                if target == original {
                    LedgerHistoryView(model: model, shopID: original.id, authorize: { target == original })
                } else {
                    Text(captureText("Unlock your private workspace to review this source."))
                }
            }
        }
    }
}

struct LedgerHistoryView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    var authorize: @MainActor () -> Bool = { true }
    @Environment(\.dismiss) private var dismiss
    private enum Focus: Hashable { case result }
    @AccessibilityFocusState private var focus: Focus?
    private var shop: ShoppingLedger? { model.workspace.shops.first { $0.id == shopID } }
    var body: some View {
        List {
            LedgerSaveStatus(model: model).accessibilityFocused($focus, equals: .result)
            if let shop {
                historySection("Recently checked", lines: shop.recentlyChecked.filter { !$0.isHandled }, kind: 0)
                historySection("Handled", lines: shop.handled, kind: 1)
                historySection("Trash", lines: shop.trash, kind: 2)
            }
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("List history"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
    }
    private func historySection(_ title: String, lines: [ShoppingLine], kind: Int) -> some View {
        Section(ledgerText(title)) {
            if lines.isEmpty { Text(ledgerText("Nothing here yet.")).foregroundStyle(Theme.secondary) }
            ForEach(lines, id: \.id) { line in
                let canRestore = kind != 2 || !(shop?.contributions(forLineID: line.id).isEmpty ?? true)
                NavigationLink {
                    LedgerIngredientView(model: model, shopID: shopID, lineID: line.id)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(line.name)
                        if let who = line.handledBy { Text(ledgerFormat("Handled by %@", who)) }
                        if let date = line.trashedAt ?? line.handledAt ?? line.checkedAt {
                            Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                                .font(.subheadline).foregroundStyle(Theme.secondary)
                        }
                        if !canRestore {
                            Text(ledgerText("All sources for this item were removed. Add a new item if you need it again."))
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                Button(ledgerText(kind == 2 ? "Restore" : "Reopen")) {
                    let revision = shop?.revisionID
                    Task {
                        _ = await model.editShop(key: "restore-\(line.id)", shopID: shopID, authorize: authorize) { ledger in
                            guard ledger.revisionID == revision else { throw LedgerError.stalePreview }
                            if kind == 2 { try ledger.restore(lineID: line.id) }
                            else if kind == 1 { try ledger.reopen(lineID: line.id) }
                            else { try ledger.setChecked(lineID: line.id, checked: false) }
                        }
                        focus = .result
                    }
                }.disabled(model.saving || model.hasPendingSave || !canRestore).frame(minHeight: 44)
                    .accessibilityLabel(ledgerFormat(kind == 2 ? "Restore %@" : "Reopen %@", line.name))
            }
        }
    }
}
