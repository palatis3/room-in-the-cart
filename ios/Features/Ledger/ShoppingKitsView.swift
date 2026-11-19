import SwiftUI
import CoreDomain

struct ShoppingKitsView: View {
    @Environment(\.shoppingListAuthorization) private var authorize
    @ObservedObject var model: LedgerModel
    let shopID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var toDelete: ShoppingKit?
    var body: some View {
        List {
            if let shop = model.shop, shop.id == shopID {
                NavigationLink(shoppingText("Save a kit from this list")) {
                    ShoppingKitEditor(model: model, shop: shop, original: nil)
                }
            }
            ForEach(model.workspace.shoppingLists.kits) { kit in
                if let shop = model.shop, shop.id == shopID {
                    Section(kit.name) {
                        NavigationLink(shoppingText("Review for this pickup")) {
                            ShoppingKitReview(model: model, shop: shop, kit: kit)
                        }
                        NavigationLink(shoppingText("Edit kit")) { ShoppingKitEditor(model: model, shop: shop, original: kit) }
                        Button(shoppingText("Delete kit"), role: .destructive) { toDelete = kit }
                    }
                } else if model.shop == nil && shopID == nil {
                    Section(kit.name) {
                        ForEach(kit.rows) { row in
                            ShoppingIntentLabel(row: row)
                            if row.optional { Text(shoppingText("Optional")) }
                        }
                    }
                }
            }
            if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model) }
        }.navigationTitle(shoppingText("Shopping kits"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
        .confirmationDialog(shoppingText("Delete kit?"), isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), presenting: toDelete) { kit in
            Button(shoppingText("Delete kit"), role: .destructive) {
                Task { _ = await model.change(key: "delete-kit-\(kit.id)", reviewedPantryBasis: nil, authorize: authorize) { try $0.shoppingLists.deleteKit(kit) } }
            }
        }
    }
}

struct ShoppingIntentLabel: View {
    let row: ShoppingKitRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.name).font(.headline)
            Text(ledgerQuantity(row.quantity)).font(.subheadline)
            if !row.notes.isEmpty { Text(row.notes) }
            if !row.exclusions.isEmpty {
                Text(ledgerFormat("Exclusions: %@", row.exclusions.joined(separator: ", ")))
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShoppingKitEditor: View {
    @Environment(\.shoppingListAuthorization) private var authorize
    @ObservedObject var model: LedgerModel
    @State private var original: ShoppingKit?
    @State private var shop: ShoppingLedger
    @State private var draft: ShoppingKit
    @State private var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerModel, shop: ShoppingLedger, original: ShoppingKit?) {
        self.model = model
        _shop = State(initialValue: shop)
        _original = State(initialValue: original)
        var kit = original ?? ShoppingKit(name: "", rows: [])
        let existing = Set(kit.rows.map(\.id))
        let listRows = (try? shop.shoppingKitRows()) ?? []
        kit.rows.append(contentsOf: listRows.filter { !existing.contains($0.id) })
        _draft = State(initialValue: kit)
        _selected = State(initialValue: Set(original?.rows.map(\.id) ?? []))
    }

    var body: some View {
        Form {
            TextField(shoppingText("Kit name"), text: $draft.name)
            Section(shoppingText("Choose kit items")) {
                ForEach($draft.rows) { $row in
                    Toggle(isOn: selection(row.id)) { ShoppingIntentLabel(row: row) }
                    if selected.contains(row.id) {
                        NavigationLink(shoppingFormat("Edit %@", row.name)) {
                            ShoppingKitItemEditor(row: $row)
                        }
                        Toggle(shoppingText("Optional on reuse"), isOn: $row.optional)
                            .accessibilityLabel(shoppingFormat("Optional on reuse: %@", row.name))
                    }
                }
            }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
            Button(shoppingText("Save kit")) {
                let chosen = ShoppingKit(id: draft.id, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                         rows: draft.rows.filter { selected.contains($0.id) })
                Task {
                    if await model.change(key: "save-kit-\(draft.id)", reviewedPantryBasis: nil, authorize: authorize, { workspace in
                        guard workspace.selectedShopID == shop.id, workspace.shops.first(where: { $0.id == shop.id })?.revisionID == shop.revisionID else {
                            throw LedgerError.stalePreview
                        }
                        try workspace.shoppingLists.saveKit(chosen, replacing: original)
                    }) { dismiss() }
                }
            }.disabled(selected.isEmpty || selected.count > 100 || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving || model.hasPendingSave)
        }.navigationTitle(shoppingText("Edit shopping kit"))
    }

    private func selection(_ id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { on in
            if on { selected.insert(id) } else { selected.remove(id) }
        })
    }
}

private struct ShoppingKitItemEditor: View {
    @Binding var row: ShoppingKitRow
    @State private var name: String
    @State private var notes: String
    @State private var exclusions: String
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    @Environment(\.dismiss) private var dismiss

    init(row: Binding<ShoppingKitRow>) {
        _row = row
        let item = row.wrappedValue
        _name = State(initialValue: item.name)
        _notes = State(initialValue: item.notes)
        _exclusions = State(initialValue: item.exclusions.joined(separator: "\n"))
        _amount = State(initialValue: item.quantity.map { ledgerAmountInput($0.amount) } ?? "")
        _unit = State(initialValue: item.quantity?.unit ?? .count)
    }

    private var draft: ShoppingKitRow? {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        var copy = row
        copy.name = label
        copy.notes = notes
        copy.exclusions = exclusions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            if amount != (row.quantity.map { ledgerAmountInput($0.amount) } ?? "") || unit != (row.quantity?.unit ?? .count) {
                copy.quantity = try LedgerEntry.quantity(amount, unit)
            }
            return copy
        } catch { return nil }
    }

    var body: some View {
        Form {
            TextField(shoppingText("Item name"), text: $name)
            TextField(shoppingText("Quantity (optional)"), text: $amount)
            Picker(shoppingText("Unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField(shoppingText("Brand or notes"), text: $notes, axis: .vertical)
            TextField(shoppingText("Exclusions, one per line"), text: $exclusions, axis: .vertical)
            Button(ledgerText("Done")) {
                if let draft { row = draft; dismiss() }
            }.disabled(draft == nil)
        }.navigationTitle(row.name)
    }
}

private struct ShoppingKitReview: View {
    @Environment(\.shoppingListAuthorization) private var authorize
    @ObservedObject var model: LedgerModel
    @State private var shop: ShoppingLedger
    @State private var kit: ShoppingKit
    @State private var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerModel, shop: ShoppingLedger, kit: ShoppingKit) {
        self.model = model
        _shop = State(initialValue: shop)
        _kit = State(initialValue: kit)
        _selected = State(initialValue: Set(kit.rows.filter { !$0.optional && $0.overlaps(in: shop).isEmpty }.map(\.id)))
    }

    var body: some View {
        Form {
            Section(shoppingFormat("Add to %@", shop.title)) {
                ForEach(kit.rows) { row in
                    Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: { on in
                        if on { selected.insert(row.id) } else { selected.remove(row.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 5) {
                            ShoppingIntentLabel(row: row)
                            if row.optional { Text(shoppingText("Optional")).font(.caption) }
                            ForEach(row.overlaps(in: shop)) { line in
                                Text(shoppingFormat("Already on list: %@ · %@", line.name, ledgerQuantity(try? shop.quantity(forLineID: line.id))))
                            }
                            if !row.overlaps(in: shop).isEmpty { Text(shoppingText("Select to add a separate row.")).font(.footnote) }
                        }
                    }
                }
            }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
            Button(shoppingText("Add selected items")) {
                Task {
                    if await model.change(key: "apply-kit-\(kit.id)-\(shop.revisionID)", reviewedPantryBasis: nil, authorize: authorize, { workspace in
                        try workspace.applyKit(kit, selected: selected, shopID: shop.id, revision: shop.revisionID)
                    }) { dismiss() }
                }
            }.disabled(selected.isEmpty || model.saving || model.hasPendingSave)
        }.navigationTitle(kit.name)
    }
}
