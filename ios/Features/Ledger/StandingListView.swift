import SwiftUI
import CoreDomain

struct StandingListView: View {
    @Environment(\.shoppingListAuthorization) private var authorize
    @ObservedObject var model: LedgerModel
    @State private var store: String?
    @State private var savedItem: StandingListItem?
    @Environment(\.dismiss) private var dismiss

    private var stores: [String] {
        let tags = Set(model.workspace.shoppingLists.standing.flatMap(\.stores))
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [StandingListItem] {
        guard let store else { return model.workspace.shoppingLists.standing }
        return model.workspace.shoppingLists.standing.filter { $0.eligible(at: store) }
    }

    var body: some View {
        let rows = filtered
        JournalList {
            NavigationLink(shoppingText("Add standing item")) {
                StandingItemEditor(model: model, original: nil) { savedItem = $0 }
            }
            Picker(shoppingText("Store"), selection: $store) {
                Text(shoppingText("All stores")).tag(String?.none)
                ForEach(stores, id: \.self) { Text($0).tag(Optional($0)) }
            }
            availableSection(rows.filter { $0.transfer == nil && $0.checkedAt == nil })
            checkedSection(rows.filter { $0.checkedAt != nil })
            transferredSection(rows.filter { $0.transfer != nil })
            if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model) }
        }.listStyle(.plain).navigationTitle(shoppingText("Standing list"))
        .onChange(of: stores) { _, options in if let store, !options.contains(store) { self.store = nil } }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
    }

    private func availableSection(_ rows: [StandingListItem]) -> some View {
        Section(shoppingText("Available to take into a pickup")) {
            if rows.isEmpty { Text(shoppingText("No available items for this filter.")) }
            ForEach(rows) { item in
                HStack {
                    Button { check(item, checked: true) } label: {
                        Image(systemName: "circle").frame(width: 44, height: 44)
                    }.buttonStyle(.borderless).accessibilityLabel(ledgerFormat("Check %@", item.row.name))
                    NavigationLink {
                        StandingItemDetail(model: model, item: item)
                    } label: {
                        VStack(alignment: .leading) {
                            ShoppingIntentLabel(row: item.row)
                            if savedItem == item {
                                Label(ledgerText("Saved on this iPhone"), systemImage: "checkmark.circle")
                                    .font(.footnote).foregroundStyle(Theme.secondary)
                            }
                            Text(item.stores.joined(separator: " · ")).font(.footnote)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func checkedSection(_ rows: [StandingListItem]) -> some View {
        if !rows.isEmpty {
            Section(ledgerText("Recently checked")) {
                ForEach(rows) { item in
                    Button(shoppingFormat("Undo pick of %@", item.row.name)) { check(item, checked: false) }
                }
            }
        }
    }

    @ViewBuilder private func transferredSection(_ rows: [StandingListItem]) -> some View {
        if !rows.isEmpty {
            Section(shoppingText("Taken into a pickup")) {
                ForEach(rows) { item in
                    NavigationLink {
                        StandingItemDetail(model: model, item: item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.row.name)
                            if let title = model.workspace.shops.first(where: { $0.id == item.transfer?.shopID })?.title { Text(title).font(.subheadline) }
                        }
                    }
                }
            }
        }
    }

    private func check(_ item: StandingListItem, checked: Bool) {
        Task {
            _ = await model.change(key: "standing-check-\(item.id)", reviewedPantryBasis: nil, authorize: authorize) { workspace in
                try workspace.shoppingLists.setStandingChecked(item, checked: checked)
            }
        }
    }
}

private struct StandingItemDetail: View {
    @Environment(\.shoppingListAuthorization) private var authorize
    @ObservedObject var model: LedgerModel
    let item: StandingListItem
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    var body: some View {
        WorkingForm {
            if let current = model.workspace.shoppingLists.standing.first(where: { $0.id == item.id }) {
                ShoppingIntentLabel(row: current.row)
                Text(current.stores.joined(separator: " · "))
                if let transfer = current.transfer {
                    if let shop = model.workspace.shops.first(where: { $0.id == transfer.shopID }) {
                        Section(shoppingFormat("Taken into %@", shop.title)) {
                            if model.workspace.selectedShopID == shop.id, model.workspace.canReturnStanding(current, from: shop) {
                                Text(shoppingText("Returning removes the transferred row from this pickup and makes the standing item available at its stores again."))
                                Button(shoppingText("Return to standing list")) { move(current, shop: shop, returning: true) }
                            } else {
                                Text(shoppingText("To return this item, select its original pickup and undo any pick. A changed or linked item needs review in the pickup."))
                            }
                        }
                    }
                } else {
                    Section {
                        NavigationLink(shoppingText("Edit standing item")) { StandingItemEditor(model: model, original: current) }
                        Button(shoppingText("Delete standing item"), role: .destructive) { deleting = true }
                    }
                    if let shop = model.shop {
                        Section(shoppingFormat("Review transfer to %@", shop.title)) {
                            if !current.eligible(at: shop.basis.branch) {
                                Text(shoppingText("Set the pickup’s store to one of this item’s eligible stores to transfer it."))
                            } else if !current.row.overlaps(in: shop).isEmpty {
                                ForEach(current.row.overlaps(in: shop)) { line in
                                    Text(shoppingFormat("Already on list: %@ · %@", line.name, ledgerQuantity(try? shop.quantity(forLineID: line.id))))
                                }
                                Text(shoppingText("Resolve this overlap in the pickup before transferring."))
                            } else {
                                Text(shop.basis.branch)
                                Text(shoppingText("Move this one intent into the selected pickup. It will leave every store’s available list."))
                                Button(shoppingText("Transfer to pickup")) { move(current, shop: shop, returning: false) }
                                    .accessibilityIdentifier("standingConfirmTransfer")
                            }
                        }
                    } else { Text(shoppingText("Start a pickup to transfer this item.")) }
                }
                LedgerSaveStatus(model: model, onRetried: { dismiss() })
                .confirmationDialog(shoppingText("Delete standing item?"), isPresented: $deleting) {
                    Button(shoppingText("Delete standing item"), role: .destructive) {
                        Task {
                            if await model.change(key: "delete-standing-\(current.id)", reviewedPantryBasis: nil, authorize: authorize, { try $0.shoppingLists.deleteStanding(current) }) { dismiss() }
                        }
                    }
                }
            }
        }.navigationTitle(item.row.name)
    }

    private func move(_ current: StandingListItem, shop: ShoppingLedger, returning: Bool) {
        Task {
            if await model.change(key: "standing-\(current.id)-\(shop.revisionID)", reviewedPantryBasis: nil, authorize: authorize, { workspace in
                if returning { try workspace.returnStanding(current, shopID: shop.id, revision: shop.revisionID) }
                else { try workspace.transferStanding(current, shopID: shop.id, revision: shop.revisionID) }
            }) { dismiss() }
        }
    }
}

private struct StandingItemEditor: View {
    @Environment(\.shoppingListAuthorization) private var authorize
    @ObservedObject var model: LedgerModel
    @State private var original: StandingListItem?
    @State private var id: UUID
    @State private var name: String
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    @State private var notes: String
    @State private var stores: String
    @State private var exclusions: String
    @Environment(\.dismiss) private var dismiss

    private let onSaved: ((StandingListItem) -> Void)?

    init(model: LedgerModel, original: StandingListItem?, onSaved: ((StandingListItem) -> Void)? = nil) {
        self.model = model
        self.onSaved = onSaved
        _original = State(initialValue: original)
        _id = State(initialValue: original?.id ?? UUID())
        _name = State(initialValue: original?.row.name ?? "")
        _amount = State(initialValue: original?.row.quantity.map { ledgerAmountInput($0.amount) } ?? "")
        _unit = State(initialValue: original?.row.quantity?.unit ?? .count)
        _notes = State(initialValue: original?.row.notes ?? "")
        _stores = State(initialValue: original?.stores.joined(separator: "\n") ?? "")
        _exclusions = State(initialValue: original?.row.exclusions.joined(separator: "\n") ?? "")
    }

    private func entries(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        WorkingForm {
            TextField(shoppingText("Item name"), text: $name)
            TextField(shoppingText("Quantity (optional)"), text: $amount)
            Picker(shoppingText("Unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField(shoppingText("Brand or notes"), text: $notes, axis: .vertical)
            TextField(shoppingText("Exclusions, one per line"), text: $exclusions, axis: .vertical)
            Section(shoppingText("Eligible stores")) {
                TextField(shoppingText("Store names, one per line"), text: $stores, axis: .vertical)
                if let branch = model.shop?.basis.branch, !branch.isEmpty,
                   !entries(stores).contains(where: { $0.caseInsensitiveCompare(branch) == .orderedSame }) {
                    Button(shoppingFormat("Use %@", branch)) { stores = (entries(stores) + [branch]).joined(separator: "\n") }
                }
            }
            if model.saving || model.hasPendingSave || model.error != nil {
                LedgerSaveStatus(model: model, showsLastSave: false, onRetried: finishSave)
            }
            Button(shoppingText("Save standing item")) {
                Task {
                    if await model.change(key: "standing-edit-\(id)", reviewedPantryBasis: nil, authorize: authorize, { workspace in
                        let row = ShoppingKitRow(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            quantity: try LedgerEntry.quantity(amount, unit), notes: notes, exclusions: entries(exclusions))
                        try workspace.shoppingLists.saveStanding(StandingListItem(row: row, stores: entries(stores)), replacing: original)
                    }) { finishSave() }
                }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entries(stores).isEmpty || model.saving || model.hasPendingSave)
        }.navigationTitle(shoppingText("Standing item"))
    }

    private func finishSave() {
        guard let item = model.workspace.shoppingLists.standing.first(where: { $0.id == id }) else { return }
        onSaved?(item)
        dismiss()
    }
}
