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
        let contributions = Dictionary(grouping: shop.contributions.filter { $0.removedAt == nil }, by: \.lineID)
        return rows.compactMap { row in
            guard let line = sources[row.id], !line.isHandled, !line.isChecked, !line.isTrashed else { return nil }
            let measure = row.quantity.map { TripMeasure(need: $0, packages: packages[line.id] ?? []) }
            var amount: String?
            if let measure {
                var remaining = measure.need.amount
                if let pick = line.tripPick {
                    guard let picked = try? pick.amount.converted(to: measure.need.unit),
                          let rest = try? remaining.subtractingClampedToZero(picked) else { return nil }
                    remaining = rest
                }
                guard remaining > .zero else { return nil }
                amount = measure.display(remaining)
            } else if let pick = line.packagePick {
                let need = GroceryPackageCount(reviewedSources: contributions[line.id] ?? [])
                guard let remaining = need?.remaining(after: pick) else { return nil }
                amount = remaining.shoppingLabel
            } else {
                amount = ShoppingLedger.shoppingLabelWithoutTotal(for: line, sources: contributions[line.id] ?? [])
            }
            return Self(id: line.id, name: line.name, amount: amount, packNote: measure?.packNote)
        }
    }

    func text(includePack: Bool) -> String {
        [name, amount, includePack ? packNote : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

struct TripHandoffEntry: View {
    private var dinnerPantry = ShoppingDinnerPantry()
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    @State private var selected: Set<UUID> = []
    @State private var includePack: Set<UUID> = []
    @State private var preview: Preview?
    @State private var sharing = false
    private struct Preview { let revision: UUID; let text: String }

    init(model: LedgerModel, shopID: UUID) {
        self.model = model
        self.shopID = shopID
    }

    var body: some View {
        WorkingForm {
            if authorize(), let shop = model.shop, shop.id == shopID {
                let covered = dinnerPantry.covered(in: shop, ledger: model)
                let rows = TripHandoffRow.outstanding(in: shop).filter { !covered.contains($0.id) }
                if let preview, preview.revision == shop.revisionID {
                    Section(tripText("Message preview")) {
                        Text(verbatim: preview.text).accessibilityIdentifier("tripShareBody")
                        Text(tripText("The recipient can read this copy without the app. Later changes stay on your list."))
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
                    NavigationLink(tripText("Split by department")) { DepartmentHandoffView(model: model, shopID: shopID) }
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
                        preview = Preview(revision: shop.revisionID, text: ([tripFormat("Shopping list copy · %@", date)] + content).joined(separator: "\n"))
                    }.buttonStyle(PrimaryAction()).disabled(selected.isDisjoint(with: rows.map(\.id)))
                }
            }
        }.navigationTitle(tripText("Preview list copy"))
        .onChange(of: model.shop.map { dinnerPantry.covered(in: $0, ledger: model) }) { _, _ in preview = nil; sharing = false }
        .onChange(of: model.shop?.revisionID) { _, _ in preview = nil; sharing = false }
    }

    private func binding(_ id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { checked in
            if checked { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
        })
    }
}

struct TripNextStoreEntry: View {
    private var dinnerPantry = ShoppingDinnerPantry()
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @State private var name = ""
    @FocusState private var editing: Bool
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerModel, shopID: UUID) {
        self.model = model
        self.shopID = shopID
    }

    var body: some View {
        WorkingForm {
            if let shop = model.shop, shop.id == shopID {
                let covered = dinnerPantry.covered(in: shop, ledger: model)
                let rows = TripHandoffRow.outstanding(in: shop).filter { !covered.contains($0.id) }
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
                NavigationLink {
                    SkippedStoreView(model: model, shopID: shopID, suggested: store)
                } label: { Text(tripText("Preview skipping a store")) }
                .accessibilityIdentifier("trip.skipPreview")
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

/// Compares only the shopper's explicitly selected stops. Store preferences describe
/// where a line was listed, never stock or a route the shopper has agreed to take.
struct SkippedStorePreview {
    enum Group: CaseIterable {
        case stranded, alternatives, outsidePlan, unassigned
        var title: String {
            switch self {
            case .stranded: tripText("Would lose its last planned store")
            case .alternatives: tripText("Still has a planned store")
            case .outsidePlan: tripText("Already outside the plan")
            case .unassigned: tripText("Unassigned groceries")
            }
        }
    }
    struct Item: Identifiable {
        let row: TripHandoffRow
        let stores: [String]
        var id: UUID { row.id }
    }
    private(set) var groups: [Group: [Item]] = [:]

    init?(shop: ShoppingLedger, remaining: Set<String>, skipping: String, excluding: Set<UUID>) {
        let planned = Set(remaining.map { $0.lowercased() })
        let skipped = skipping.lowercased()
        guard !skipped.isEmpty, planned.contains(skipped) else { return nil }
        let lines = Dictionary(uniqueKeysWithValues: shop.lines.map { ($0.id, $0) })
        for row in TripHandoffRow.outstanding(in: shop) {
            guard !excluding.contains(row.id), let line = lines[row.id], !shop.isLeftForNextTrip(line) else { continue }
            let assigned = line.preferredStores ?? []
            let matched = assigned.filter { planned.contains($0.lowercased()) }
            let other = matched.filter { $0.lowercased() != skipped }
            let group: Group
            if assigned.isEmpty { group = .unassigned }
            else if !other.isEmpty { group = .alternatives }
            else if !matched.isEmpty { group = .stranded }
            else { group = .outsidePlan }
            groups[group, default: []].append(Item(row: row, stores: group == .alternatives ? other : assigned))
        }
    }
}

private struct SkippedStoreView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let suggested: String
    @Environment(\.shoppingListAuthorization) private var authorize
    @State private var entered: [String] = []
    @State private var remaining = Set<String>()
    @State private var skipping = ""
    @State private var newStore = ""
    @FocusState private var editing: Bool
    private var pantry = ShoppingDinnerPantry()

    var body: some View {
        WorkingForm {
            if authorize(), let shop = model.shop, shop.id == shopID {
                let candidates = storeChoices(shop)
                let selected = candidates.filter { remaining.contains($0.lowercased()) }
                Section {
                    Text(tripText("Choose only the stops you still plan to visit. This preview leaves your list and current stop unchanged."))
                    ForEach(candidates, id: \.self) { name in
                        Toggle(isOn: selection(for: name)) { Text(verbatim: name) }
                            .frame(minHeight: 44)
                    }
                    let name = newStore.trimmingCharacters(in: .whitespacesAndNewlines)
                    workingTextField(tripText("Another planned store"), text: $newStore)
                        .focused($editing)
                    Button(tripText("Include this store")) {
                        if !candidates.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { entered.append(name) }
                        remaining.insert(name.lowercased())
                        newStore = ""
                        editing = false
                    }
                    .disabled(name.isEmpty || name.utf8.count > 512)
                } header: { Text(tripText("Remaining planned stops")) }
                if !selected.isEmpty {
                    Section {
                        Picker(tripText("Preview skipping"), selection: $skipping) {
                            Text(tripText("Choose a stop")).tag("")
                            ForEach(selected, id: \.self) { name in Text(verbatim: name).tag(name.lowercased()) }
                        }
                        .accessibilityIdentifier("trip.skipChoice")
                    } footer: { Text(tripText("Based on your store preferences. Store stock is unknown.")) }
                }
                if selected.contains(where: { $0.lowercased() == skipping }) {
                    let status = pantry.status(in: shop, ledger: model)
                    let excluded = status.covered.union(status.pending.flatMap { $0.lines.map(\.id) })
                    if let result = SkippedStorePreview(shop: shop, remaining: Set(selected), skipping: skipping, excluding: excluded) {
                        ForEach(SkippedStorePreview.Group.allCases, id: \.self) { group in
                            let items = result.groups[group] ?? []
                            if !items.isEmpty || group == .stranded {
                                Section(group.title) {
                                    if items.isEmpty { Text(tripText("No groceries would lose a planned store.")) }
                                    ForEach(items) { item in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(verbatim: item.row.text(includePack: false))
                                            if !item.stores.isEmpty {
                                                Text(verbatim: item.stores.joined(separator: " · "))
                                                    .font(.footnote).foregroundStyle(Theme.secondary)
                                            }
                                        }.accessibilityElement(children: .combine)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle(tripText("Preview skipping a store"))
        .keyboardDoneAction(visible: editing, title: ledgerText("Done"), identifier: "tripSkipKeyboardDone") { editing = false }
    }

    private func storeChoices(_ shop: ShoppingLedger) -> [String] {
        let names = shop.lines.filter { !$0.isTrashed && !$0.isHandled }.flatMap { $0.preferredStores ?? [] }
            + [shop.currentStop.name, suggested] + entered
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func selection(for store: String) -> Binding<Bool> {
        let key = store.lowercased()
        return Binding(get: { remaining.contains(key) }, set: { included in
            if included { remaining.insert(key) }
            else {
                remaining.remove(key)
                if skipping == key { skipping = "" }
            }
        })
    }
}

/// A local, one-time snapshot of reviewed rows. No connected permissions or claims are created.
struct DepartmentChecklist: Equatable, Identifiable {
    let department: String
    let rows: [TripHandoffRow]
    var id: String { department }
    var title: String { department.isEmpty ? ledgerText("No aisle assigned") : department }

    static func outstanding(in shop: ShoppingLedger, layout: LedgerListLayout, excluding: Set<UUID>) -> [Self] {
        let rows = Dictionary(uniqueKeysWithValues: TripHandoffRow.outstanding(in: shop).map { ($0.id, $0) })
        var grouped: [String: [TripHandoffRow]] = [:]
        var order: [String] = []
        for line in layout.groups(shop: shop, excluding: excluding).flatMap(\.lines) {
            guard let row = rows[line.id], shop.outcomeAtCurrentStop(line) == nil,
                  line.eligibleForStop(named: shop.currentStop.name) else { continue }
            let department = layout.department(for: line, in: shop).trimmingCharacters(in: .whitespacesAndNewlines)
            if grouped[department] == nil { order.append(department) }
            grouped[department, default: []].append(row)
        }
        return order.map { Self(department: $0, rows: grouped[$0] ?? []) }
    }

    static func copy(for selected: Set<UUID>, from sections: [Self], heading: String, date: Date) -> String? {
        var lines: [String] = []
        for section in sections {
            let rows = section.rows.filter { selected.contains($0.id) }
            if !rows.isEmpty {
                lines.append(section.title)
                lines += rows.map { $0.text(includePack: false) }
            }
        }
        guard !lines.isEmpty else { return nil }
        return ([heading, date.formatted(date: .long, time: .shortened)] + lines).joined(separator: "\n")
    }
}

private struct DepartmentHandoffView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    @State private var assignments: [UUID: Int] = [:]
    @State private var preview: DatedPair?
    @State private var sharing: Int?
    private var pantry = ShoppingDinnerPantry()

    init(model: LedgerModel, shopID: UUID) {
        self.model = model
        self.shopID = shopID
    }

    private struct DatedPair {
        let revision: UUID
        let sections: [DepartmentChecklist]
        let first: String
        let second: String
    }
    private func label(_ slot: Int) -> String {
        slot == 1 ? tripText("First shopper") : tripText("Second shopper")
    }

    var body: some View {
        WorkingForm {
            if authorize(), let shop = model.shop, shop.id == shopID {
                let status = pantry.status(in: shop, ledger: model)
                let sections = DepartmentChecklist.outstanding(in: shop, layout: model.workspace.listLayout,
                    excluding: status.covered.union(status.pending.flatMap { $0.lines.map(\.id) }))
                Group {
                    if let preview, preview.revision == shop.revisionID, preview.sections == sections {
                        ForEach(1...2, id: \.self) { slot in
                            Section(label(slot)) {
                                Text(verbatim: slot == 1 ? preview.first : preview.second)
                                Button(tripText("Choose how to send")) { sharing = slot }
                            }
                        }
                        Text(tripText("Each copy is dated. Later changes require a new selection."))
                        Button(tripText("Edit selection")) { self.preview = nil }
                    } else {
                        Text(verbatim: shop.title).font(.headline)
                        Text(tripText("Choose a shopper for each department you want to send. Review both copies before sharing."))
                        if sections.isEmpty { Text(shoppingText("No items left to pick.")) }
                        ForEach(sections) { section in
                            Section(section.title) {
                                Picker(tripText("Shopper"), selection: Binding(get: {
                                    section.rows.first.flatMap { assignments[$0.id] } ?? 0
                                }, set: { slot in
                                    for row in section.rows { assignments[row.id] = slot == 0 ? nil : slot }
                                })) {
                                    Text(tripText("Leave out")).tag(0)
                                    Text(label(1)).tag(1)
                                    Text(label(2)).tag(2)
                                }
                                ForEach(section.rows) { row in Text(verbatim: row.text(includePack: false)) }
                            }
                        }
                        Button(tripText("Preview both checklists")) {
                            let date = Date()
                            guard authorize(), let a = DepartmentChecklist.copy(for: ids(1), from: sections, heading: label(1), date: date),
                                  let b = DepartmentChecklist.copy(for: ids(2), from: sections, heading: label(2), date: date) else { return }
                            preview = DatedPair(revision: shop.revisionID, sections: sections, first: a, second: b)
                        }.disabled(ids(1).isEmpty || ids(2).isEmpty)
                    }
                }
                .onChange(of: sections) { _, _ in reset() }
                .onChange(of: shop.revisionID) { _, _ in reset() }
                .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                    if authorize(), model.shop?.id == shopID, let slot = sharing, let preview,
                       preview.sections == sections, preview.revision == model.shop?.revisionID {
                        PickupActivitySheet(text: slot == 1 ? preview.first : preview.second) { _, _ in sharing = nil }
                    }
                }
            }
        }.navigationTitle(tripText("Split by department"))
    }

    private func ids(_ slot: Int) -> Set<UUID> { Set(assignments.compactMap { $0.value == slot ? $0.key : nil }) }
    private func reset() { assignments = [:]; preview = nil; sharing = nil }
}
