import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedPantryView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let shopID: UUID
    @State private var registering = false

    private var delivery: SharedDeliveryPage? {
        guard model.canReadPantry, let record = model.deliveryRecord, record.shopId == shopID else { return nil }
        return record
    }

    var body: some View {
        List {
            if let delivery, let pantry = model.pantryRecord, pantry.shopId == shopID,
               pantry.shopRevision == delivery.shopRevision && pantry.supplyRevision == delivery.supplyRevision &&
               pantry.placedRevision == delivery.placedRevision && pantry.authorityEpoch == delivery.authorityEpoch {
                if !pantry.lots.isEmpty {
                    ForEach(pantry.lots) { lot in
                        NavigationLink {
                            SharedPantryLotView(model: model, shopID: shopID, lotID: lot.lotId)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(lot.foodName).font(.headline)
                                Text(pantryLocation(lot.location) + " · " + deliveryQuantityText(lot.observation?.quantity))
                                if lot.selected { Text(ht("Selected for this shop")).font(.footnote) }
                            }
                        }.accessibilityIdentifier("pantry.lot." + lot.id.uuidString)
                    }
                } else { Text(ht("No household batches recorded.")) }
                if model.shop?.phase == "placed" && model.pending == nil {
                    Button(ht("Add food to storage")) { registering = true }
                        .accessibilityIdentifier("pantry.create")
                }
                if delivery.meals?.isEmpty == false {
                    NavigationLink(ht("Available food by meal")) {
                        if (delivery.recoveryRevision ?? 0) > 0 {
                            SharedRecoveryCoverageView(model: model, household: household, delivery: delivery)
                        } else {
                            SharedFoodCoverageView(model: model, household: household, page: delivery)
                        }
                    }
                        .accessibilityIdentifier("pantry.coverage")
                }
            } else if model.busy { ProgressView() }
            else { Text(ht("Refresh deliveries and review the current record.")) }
            if model.canReadPantry {
                Button(ht("Refresh")) { Task { await refresh() } }.disabled(model.busy)
                if let notice = model.notice { Text(notice) }
            }
        }
        .navigationTitle(ht("Pantry and freezer"))
        .task(id: delivery) { if let delivery { await model.loadPantry(reviewed: delivery) } }
        .sheet(isPresented: $registering) {
            if let delivery, let pantry = model.pantryRecord, pantry.shopId == shopID {
                SharedPantryRegistration(model: model, delivery: delivery, pantry: pantry)
            }
        }
    }

    private func refresh() async {
        await model.load()
        await model.loadDelivery()
        if let delivery { await model.loadPantry(reviewed: delivery) }
    }
}

func pantryLocation(_ location: String) -> String {
    location == "freezer" ? ht("Freezer") : ht("Pantry")
}

private struct SharedPantryRegistration: View {
    @ObservedObject var model: HouseholdShopModel
    @State private var delivery: SharedDeliveryPage
    @State private var pantry: SharedPantryPage
    @Environment(\.dismiss) private var dismiss
    @State private var source: UUID?
    @State private var name = ""
    @State private var exclusions = ""
    @State private var location = "pantry"
    @State private var knowStored = false
    @State private var storedAt = Date()
    @State private var knowUseFirst = false
    @State private var useFirstAt = Date()
    @State private var error: String?
    private enum Field: Hashable { case name, exclusions }
    @FocusState private var editingField: Field?

    init(model: HouseholdShopModel, delivery: SharedDeliveryPage, pantry: SharedPantryPage) {
        self.model = model
        _delivery = State(initialValue: delivery)
        _pantry = State(initialValue: pantry)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(ht("Food source"), selection: $source) {
                        Text(ht("Food already at home")).tag(nil as UUID?)
                        ForEach(delivery.sources.filter { item in item.confirmed != nil && !pantry.lots.contains { $0.lotId == item.id } }) { item in
                            Text(item.foodName + " · " + item.segmentKey.uuidString.prefix(8)).tag(Optional(item.id))
                        }
                    }
                    if source == nil {
                        TextField(ht("Food name"), text: $name).focused($editingField, equals: .name)
                            .accessibilityIdentifier("pantry.name")
                        TextField(ht("Food exclusions, one per line"), text: $exclusions, axis: .vertical)
                            .focused($editingField, equals: .exclusions).lineLimit(1...5)
                    }
                } footer: { Text(ht("Choose the recorded delivery when storing food from this order. It keeps one physical count.")) }
                Section {
                    Picker(ht("Storage location"), selection: $location) {
                        Text(ht("Pantry")).tag("pantry")
                        Text(ht("Freezer")).tag("freezer")
                    }.accessibilityIdentifier("pantry.location")
                    Toggle(ht("Storage date known"), isOn: $knowStored)
                    if knowStored { DatePicker(ht("Stored at"), selection: $storedAt, in: ...Date.now) }
                    Toggle(ht("Use-first date known"), isOn: $knowUseFirst)
                    if knowUseFirst { DatePicker(ht("Use first by"), selection: $useFirstAt) }
                }
                if let error { Text(error) }
            }
            .navigationTitle(ht("Add food to storage"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ht("Save")) { editingField = nil; Task { await save() } }
                        .disabled(model.busy || (source == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("pantry.saveBatch")
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }

    private func save() async {
        let edit: SharedPantryEdit
        if let source {
            edit = .storeDelivery(source: source, location: location, storedAt: knowStored ? storedAt : nil,
                                  useFirstAt: knowUseFirst ? useFirstAt : nil)
        } else {
            let tags = exclusions.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            edit = .create(location: location, storedAt: knowStored ? storedAt : nil, useFirstAt: knowUseFirst ? useFirstAt : nil,
                           name: name.trimmingCharacters(in: .whitespacesAndNewlines), exclusions: tags)
        }
        if await model.savePantry(edit, reviewed: pantry, delivery: delivery) {
            dismiss()
        } else { error = model.notice ?? ht("Refresh deliveries and review the current record.") }
    }
}
