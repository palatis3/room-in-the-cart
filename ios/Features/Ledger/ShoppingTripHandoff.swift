import SwiftUI
import CoreDomain

/// An allowlist projection used by both selection and the plain-text handoff.
/// No source lines, personal notes, dinner names or price evidence leave here.
struct TripHandoffRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let amount: String?
    let packNote: String?

    static func outstanding(in shop: ShoppingLedger) -> [Self] {
        guard let rows = try? shop.shoppingKitRows() else { return [] }
        let sources = Dictionary(uniqueKeysWithValues: shop.lines.map { ($0.id, $0) })
        let packages = shop.itemPackages
        return rows.compactMap { row in
            guard let line = sources[row.id], !line.isHandled, !line.isChecked, !line.isTrashed else { return nil }
            let measure = row.quantity.map { TripMeasure(need: $0, packages: packages[line.id] ?? []) }
            var amount: String? = ledgerText("Quantity unresolved")
            if let measure {
                var remaining = measure.need.amount
                if let pick = line.tripPick {
                    guard let picked = try? pick.amount.converted(to: measure.need.unit),
                          let rest = try? remaining.subtractingClampedToZero(picked) else { return nil }
                    remaining = rest
                }
                guard remaining > .zero else { return nil }
                amount = measure.display(remaining)
            }
            return Self(id: line.id, name: line.name, amount: amount, packNote: measure?.packNote)
        }
    }

    func text(includePack: Bool) -> String {
        [name, amount, includePack ? packNote : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

struct TripHandoffEntry: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    @State private var selected: Set<UUID> = []
    @State private var includePack: Set<UUID> = []
    @State private var preview: Preview?
    @State private var sharing = false
    private struct Preview { let revision: UUID; let text: String }

    var body: some View {
        WorkingForm {
            if authorize(), let shop = model.shop, shop.id == shopID {
                let rows = TripHandoffRow.outstanding(in: shop)
                if let preview, preview.revision == shop.revisionID {
                    Section(tripText("Message preview")) {
                        Text(verbatim: preview.text).accessibilityIdentifier("tripShareBody")
                        Text(tripText("The recipient can keep this copy and read it without the app. The assigned shopper records what arrived."))
                            .font(.footnote)
                    }
                    Button(tripText("Choose how to send")) {
                        if authorize(), model.shop?.revisionID == preview.revision { sharing = true }
                    }.buttonStyle(PrimaryAction())
                    Button(tripText("Edit selection")) { self.preview = nil }
                    .sheet(isPresented: $sharing) {
                        if authorize(), model.shop?.id == shopID, model.shop?.revisionID == preview.revision {
                            PickupActivitySheet(text: preview.text) { _, _ in sharing = false }
                        }
                    }
                } else {
                    Section(tripText("Select outstanding items")) {
                        if rows.isEmpty { Text(shoppingText("No items left to pick.")) }
                        ForEach(rows) { row in
                            Toggle(isOn: binding(row.id, in: $selected)) {
                                Text(verbatim: row.text(includePack: false)).fixedSize(horizontal: false, vertical: true)
                            }.frame(minHeight: 44)
                            if selected.contains(row.id), let pack = row.packNote {
                                Toggle(tripFormat("Include %@", pack), isOn: binding(row.id, in: $includePack)).frame(minHeight: 44)
                            }
                        }
                    }
                    Button(tripText("Preview message")) {
                        let content = rows.filter { selected.contains($0.id) }.map { $0.text(includePack: includePack.contains($0.id)) }
                        guard authorize(), !content.isEmpty, model.shop?.revisionID == shop.revisionID else { return }
                        let date = Date().formatted(date: .long, time: .omitted)
                        preview = Preview(revision: shop.revisionID, text: ([tripFormat("Shopping list · %@", date)] + content).joined(separator: "\n"))
                    }.buttonStyle(PrimaryAction()).disabled(selected.isDisjoint(with: rows.map(\.id)))
                }
            }
        }.navigationTitle(tripText("Send selected items"))
        .onChange(of: model.shop?.revisionID) { _, _ in preview = nil; sharing = false }
    }

    private func binding(_ id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { checked in
            if checked { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
        })
    }
}

struct TripNextStoreEntry: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @State private var name = ""
    @FocusState private var editing: Bool
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WorkingForm {
            if let shop = model.shop, shop.id == shopID {
                let rows = TripHandoffRow.outstanding(in: shop)
                let byID = Dictionary(uniqueKeysWithValues: shop.lines.map { ($0.id, $0) })
                let store = name.trimmingCharacters(in: .whitespacesAndNewlines)
                Section {
                    workingTextField(tripText("Store name"), text: $name).focused($editing)
                    let stores = Set(shop.lines.flatMap { $0.preferredStores ?? [] } + [shop.currentStop.name]).filter { !$0.isEmpty }.sorted()
                    if !stores.isEmpty {
                        Menu(tripText("Choose a saved store")) {
                            ForEach(stores, id: \.self) { saved in Button(saved) { name = saved; editing = false } }
                        }
                    }
                }
                ForEach(0..<3) { group in
                    let choices = rows.filter { row in
                        guard let line = byID[row.id], !shop.isLeftForNextTrip(line),
                              line.eligibleForStop(named: store) else { return false }
                        switch line.preferredStores?.count ?? 0 {
                        case 0: return group == 2
                        case 1: return group == 0
                        default: return group == 1
                        }
                    }
                    if !choices.isEmpty {
                        Section(tripText(["Store-specific items", "Either store", "Unassigned groceries"][group])) {
                            ForEach(choices) { row in
                                VStack(alignment: .leading) {
                                    Text(verbatim: row.text(includePack: false))
                                    if let stores = byID[row.id]?.preferredStores { Text(verbatim: stores.joined(separator: " · ")).font(.footnote) }
                                }
                            }
                        }
                    }
                }
                Button(tripText("Start this stop")) {
                    Task {
                        if await model.editShop(key: "trip-stop-\(shop.id)", shopID: shop.id,
                            authorize: { authorize() && model.shop?.id == shopID }, { current in
                                try current.startShoppingStop(named: store, expectedRevision: shop.revisionID)
                            }) { dismiss() }
                    }
                }.buttonStyle(PrimaryAction()).disabled(store.isEmpty || model.saving || model.hasPendingSave)
                if model.hasPendingSave || model.error != nil { LedgerSaveStatus(model: model, onRetried: { dismiss() }) }
            }
        }.navigationTitle(tripText("Next store"))
        .keyboardDoneAction(visible: editing, title: ledgerText("Done"), identifier: "tripStoreKeyboardDone") { editing = false }
    }
}
