import SwiftUI
import CoreDomain

private enum LedgerHomeSheet: String, Identifiable {
    case newShop, entry, facts, history, layout, printList
    var id: String { rawValue }
}

struct LedgerHomeView: View {
    @ObservedObject var model: LedgerModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: LedgerHomeSheet?
    private enum Focus: Hashable { case result, error, line(UUID) }
    @AccessibilityFocusState private var focus: Focus?

    var body: some View {
        VStack(spacing: 0) {
            if model.ready, let shop = model.shop {
                if !dynamicTypeSize.isAccessibilitySize { controls(shop) }
                List {
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
                    Section {
                        LedgerSaveStatus(model: model)
                            .accessibilityFocused($focus, equals: model.error == nil ? .result : .error)
                        factsSummary(shop)
                    }
                    let groups = model.workspace.listLayout.groups(shop: shop, search: model.search)
                    if groups.allSatisfy({ $0.lines.isEmpty }) {
                        Section(ledgerText("Shopping list")) {
                            Text(ledgerText(model.search.isEmpty ? "Add the groceries you need for this pickup." : "No active items match your search."))
                                .foregroundStyle(Theme.secondary)
                        }
                    } else {
                        ForEach(groups) { group in
                            Section(group.aisle.isEmpty ? ledgerText(model.workspace.listLayout.layout(for: shop).mode == .aisle ? "No aisle assigned" : "Shopping list") : group.aisle) {
                                ForEach(group.lines) { line in
                                    row(line, shop: shop).id(line.id).accessibilityFocused($focus, equals: .line(line.id))
                                }
                            }
                        }
                    }
                    Section {
                        Button { sheet = .history } label: {
                            Label(ledgerText("Recently checked, Handled and Trash"), systemImage: "clock.arrow.circlepath")
                                .frame(minHeight: 44, alignment: .leading)
                        }.accessibilityIdentifier("ledgerHistory")
                        if let batch = shop.importBatches.last(where: { $0.undoneAt == nil }) {
                            Button(ledgerText("Undo last list import"), role: .destructive) {
                                Task {
                                    _ = await model.editShop(key: "undo-\(batch.id)", shopID: shop.id) { try $0.undoImport(batchID: batch.id) }
                                    focus = model.error == nil ? .result : .error
                                }
                            }.disabled(model.saving || model.hasPendingSave)
                                .accessibilityIdentifier("ledgerUndoImport")
                        }
                    }
                }.listStyle(.insetGrouped).workingSurface()
            } else if model.opening {
                ProgressView(ledgerText("Opening your pickups…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(ledgerText("Your pickup, one list")).font(.title2.bold())
                        Text(ledgerText("Type or paste a list, keep each meal's needs, and pick up where you left off."))
                        LedgerSaveStatus(model: model)
                        if model.ready {
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
        .background(Theme.canvas)
        .task { await model.open() }
        .sheet(item: $sheet) { destination in
            NavigationStack {
                switch destination {
                case .newShop: LedgerNewShopView(model: model)
                case .entry:
                    if let shop = model.shop { LedgerImportView(model: model, shopID: shop.id) }
                case .facts:
                    if let shop = model.shop { LedgerFactsView(model: model, shop: shop) }
                case .layout:
                    if let shop = model.shop { LedgerLayoutEditor(model: model, shop: shop) }
                case .printList:
                    if let shop = model.shop { LargePrintList(shop: shop, layout: model.workspace.listLayout) }
                case .history:
                    if let shop = model.shop { LedgerHistoryView(model: model, shopID: shop.id) }
                }
            }
        }
        .onChange(of: model.error) { _, error in if error != nil { focus = .error } }
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
        Menu {
            ForEach(model.workspace.shops, id: \.id) { item in
                Button(item.title) { Task { await model.selectShop(item.id) } }
            }
            Button(ledgerText("Start another pickup")) { sheet = .newShop }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Label {
                    Text(shop.title).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "chevron.down") }
                .font(.headline).frame(minHeight: 44)
            } else {
                Label(shop.title, systemImage: "chevron.down").font(.headline).frame(minHeight: 44)
            }
        }.disabled(model.saving || model.hasPendingSave).accessibilityIdentifier("ledgerShopPicker")
    }

    private func listOptions(_ shop: ShoppingLedger) -> some View {
        Menu {
            Button(ledgerText("List order and aisles")) { sheet = .layout }
            NavigationLink(ledgerText("Review prior staples")) { StapleRecallView(ledger: model, targetID: shop.id) }
            Button(ledgerText("Large-print list")) { sheet = .printList }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Text(ledgerText("List options")).frame(minHeight: 44)
            } else {
                Label(ledgerText("List options"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }.accessibilityIdentifier("ledgerListOptions")
    }

    private var searchField: some View {
        let title = ledgerText("Search active items")
        return TextField(title, text: $model.search, prompt: dynamicTypeSize.isAccessibilitySize ? Text(verbatim: "") : nil)
            .textFieldStyle(.roundedBorder).accessibilityLabel(title).accessibilityIdentifier("ledgerSearch")
    }

    private var importButton: some View {
        Button { sheet = .entry } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Text(ledgerText("Type or paste a list"))
            } else {
                Label(ledgerText("Type or paste a list"), systemImage: "plus")
            }
        }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
            .accessibilityIdentifier("ledgerImport")
    }

    private func factsSummary(_ shop: ShoppingLedger) -> some View {
        Button { sheet = .facts } label: {
            VStack(alignment: .leading, spacing: 7) {
                Label(ledgerText("Pickup details"), systemImage: "slider.horizontal.3").font(.headline)
                Text(shop.basis.branch.isEmpty ? ledgerText("Store not set") : shop.basis.branch)
                Text(shop.basis.mode.ledgerLabel)
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

    private func row(_ line: ShoppingLine, shop: ShoppingLedger) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task {
                    _ = await model.editShop(key: "check-\(line.id)", shopID: shop.id) { try $0.setChecked(lineID: line.id, checked: true) }
                    focus = model.error == nil ? .result : .error
                }
            } label: { Image(systemName: "circle").font(.title2).frame(width: 44, height: 44) }
                .buttonStyle(.borderless).disabled(model.saving || model.hasPendingSave)
                .accessibilityLabel(ledgerFormat("Check %@", line.name))
                .accessibilityHint(ledgerText("Moves this item to Recently checked."))
                .accessibilityIdentifier("ledgerCheck-\(line.id)")
            NavigationLink {
                LedgerIngredientView(model: model, shopID: shop.id, lineID: line.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(line.name).font(.headline)
                    Text(ledgerQuantity(try? shop.quantity(forLineID: line.id))).foregroundStyle(Theme.secondary)
                    if !line.notes.isEmpty { Text(line.notes) }
                    if !line.aisle.isEmpty { Text(line.aisle).font(.footnote).foregroundStyle(Theme.secondary) }
                }.padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
            }.accessibilityLabel(ledgerFormat("Inspect %@", line.name))
                .accessibilityIdentifier("ledgerInspect-\(line.id)")
        }
    }
}

struct LedgerSaveStatus: View {
    @ObservedObject var model: LedgerModel
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
            if model.saving { ProgressView(ledgerText("Saving…")) }
            if model.hasPendingSave {
                Button(ledgerText("Retry save")) { Task { if await model.retrySave() { onRetried?() } } }
                    .disabled(model.saving).accessibilityIdentifier("ledgerRetrySave")
                Button(ledgerText("Discard unsaved change"), role: .destructive) { Task { await model.discardPendingSave() } }
                    .disabled(model.saving)
            } else if let savedAt = model.savedAt {
                Label(ledgerText("Saved on this iPhone"), systemImage: "checkmark.circle")
                    .accessibilityFocused($resultFocus, equals: .saved)
                Text(savedAt.formatted(date: .complete, time: .shortened)).font(.footnote)
            } else if model.ready { Text(ledgerText("Local to this iPhone")).font(.footnote) }
        }.fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.error) { _, error in if error != nil { resultFocus = .failure } }
            .onChange(of: model.saving) { _, saving in if !saving && model.error == nil { resultFocus = .saved } }
    }
}

struct LedgerNewShopView: View {
    @ObservedObject var model: LedgerModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    var body: some View {
        Form {
            TextField(ledgerText("Pickup name"), text: $title, axis: .vertical).accessibilityIdentifier("ledgerShopName")
                .disabled(model.saving || model.hasPendingSave)
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
            Button(ledgerText("Start pickup")) {
                Task { if await model.startShop(title: title.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() } }
            }.buttonStyle(PrimaryAction()).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving).accessibilityIdentifier("ledgerCreateShop")
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Start pickup"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}

struct LedgerHistoryView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @Environment(\.dismiss) private var dismiss
    private enum Focus: Hashable { case result }
    @AccessibilityFocusState private var focus: Focus?
    private var shop: ShoppingLedger? { model.workspace.shops.first { $0.id == shopID } }
    var body: some View {
        List {
            LedgerSaveStatus(model: model).accessibilityFocused($focus, equals: .result)
            if let shop {
                historySection("Recently checked", lines: shop.lines.filter { $0.checkedAt != nil && $0.handledAt == nil && $0.trashedAt == nil }, kind: 0)
                historySection("Handled", lines: shop.lines.filter { $0.handledAt != nil && $0.trashedAt == nil }, kind: 1)
                historySection("Trash", lines: shop.lines.filter { $0.trashedAt != nil }, kind: 2)
            }
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("List history"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
    }
    private func historySection(_ title: String, lines: [ShoppingLine], kind: Int) -> some View {
        Section(ledgerText(title)) {
            if lines.isEmpty { Text(ledgerText("Nothing here yet.")).foregroundStyle(Theme.secondary) }
            ForEach(lines.sorted { $0.originalOrder < $1.originalOrder }, id: \.id) { line in
                let canRestore = kind != 2 || !(shop?.contributions(forLineID: line.id).isEmpty ?? true)
                NavigationLink {
                    LedgerIngredientView(model: model, shopID: shopID, lineID: line.id)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(line.name)
                        if let who = line.handledBy { Text(ledgerFormat("Handled by %@", who)) }
                        if let date = line.trashedAt ?? line.handledAt ?? line.checkedAt {
                            Text(date.formatted(date: .complete, time: .shortened)).font(.footnote)
                        }
                        if !canRestore {
                            Text(ledgerText("All sources for this item were removed. Add a new item if you need it again."))
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                Button(ledgerText(kind == 2 ? "Restore" : "Reopen")) {
                    Task {
                        _ = await model.editShop(key: "restore-\(line.id)", shopID: shopID) { ledger in
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
