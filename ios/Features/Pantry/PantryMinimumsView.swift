import CoreDomain
import SwiftUI

struct PantryMinimumsView: View {
    @ObservedObject var model: PantryModel
    let scope: PantryDigestScope
    @Environment(\.pantryDigestAccess) private var currentAccess
    @EnvironmentObject private var pickup: PickupModel
    @ObservedObject private var store = PantryDigestStore.shared
    @State private var selected: UUID?
    @State private var amount = ""
    @State private var unit = UnitOfMeasure.count
    @State private var afterHolds = true
    @State private var error = false

    private var access: PantryDigestAccess? {
        guard let currentAccess, currentAccess.scope == scope, currentAccess.authorized(),
              model.snapshot?.state.workspaceID == scope.origin else { return nil }
        return currentAccess
    }
    private var products: [InventoryLot] {
        var seen = Set<UUID>()
        return (model.snapshot?.lots ?? []).sorted {
            ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString)
        }.filter { seen.insert($0.foodID).inserted }
    }
    private var quantity: Quantity? { try? DinnerEntry.quantity(amount, unit: unit) }

    private func unresolvedProducts(in snapshot: PantryRepository.Snapshot) -> Set<UUID> {
        guard let context = try? pickup.pantryReviewContext(), context.snapshot.state == snapshot.state,
              let live = try? PantryLiveStockProjection.buildGlobal(snapshot: snapshot, mapping: context.mapping, at: context.asOf) else {
            return Set(snapshot.lots.map(\.foodID))
        }
        return Set(live.lots.compactMap { lot in
            lot.issues.contains(where: {
                switch $0 { case .receiptNotCurrent, .receiptEvidenceUnresolved, .receiptIneligible: true; default: false }
            }) ? lot.current.foodID : nil
        })
    }

    var body: some View {
        WorkingForm {
            if let access, let snapshot = model.snapshot, let doc = try? store.document(scope) {
                Section(pantryText("Set a minimum")) {
                    Picker(pantryText("Food identity"), selection: $selected) {
                        Text(pantryText("Choose a saved food")).tag(nil as UUID?)
                        ForEach(products) { lot in
                            Text(lot.name + " · " + String(lot.foodID.uuidString.suffix(8))).tag(Optional(lot.foodID))
                        }
                    }
                    TextField(pantryText("Minimum amount"), text: $amount)
                    Picker(pantryText("Unit"), selection: $unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
                    }
                    Toggle(pantryText("Count only stock available after holds"), isOn: $afterHolds)
                    Button(pantryText("Save minimum")) {
                        guard let lot = products.first(where: { $0.foodID == selected }), let quantity else { return }
                        let old = doc.minimums?.first { $0.foodID == lot.foodID }
                        let next = PantryStapleMinimum(foodID: lot.foodID, anchorLotID: lot.id, target: quantity, afterHolds: afterHolds)
                        Task {
                            do {
                                try await model.verifyDigestLot(lot, origin: scope.origin, inventoryRevision: snapshot.state.revision)
                                try store.updateMinimum(old, next: next, foodID: lot.foodID, access: access)
                                selected = nil; amount = ""; error = false
                            } catch { self.error = true }
                        }
                    }.disabled(!model.canEdit || selected == nil || quantity.map { $0.amount > .zero } != true)
                }
                let unresolved = unresolvedProducts(in: snapshot)
                let placed = PantryPlacedProductLinks(journeys: pickup.journeys)
                ForEach(doc.minimums ?? []) { target in
                    if let lot = products.first(where: { $0.foodID == target.foodID }) {
                        let link = target.productLink(in: scope)
                        let linked = placed.byProduct[link] ?? []
                        let uncertain = placed.uncertain.contains(link) || !unresolved.isDisjoint(with: linked.union([target.foodID]))
                        let missing = uncertain ? nil : try? target.shortfall(lots: snapshot.lots, projection: snapshot.availability, linkedLineIDs: linked)
                        let incoming = placed.uncertain.contains(link) ? nil : try? target.incoming(pickup.journeys, linkedLineIDs: linked)
                        let shopping = target.proposal(shortfall: missing, incoming: incoming)
                        Section(lot.name) {
                            LabeledContent(pantryText(target.afterHolds ? "Minimum available after holds" : "Minimum total on hand"),
                                           value: pantryQuantity(target.target))
                            LabeledContent(pantryText("Confirmed incoming from linked orders"), value: pantryQuantity(incoming))
                            if pickup.journeys.contains(where: { $0.closedAt == nil && $0.pickup != nil }) {
                                Text(pantryText("Check older or unlinked orders separately.")).font(.footnote)
                            }
                            if let shopping {
                                LabeledContent(pantryText("Amount to review for shopping"), value: pantryQuantity(shopping))
                            } else {
                                Text(pantryText("Check the amount before choosing a shopping quantity."))
                            }
                            if shopping?.amount != .zero {
                                PantryRestockActions(model: model, lot: lot, sourceCurrent: {
                                    guard let live = self.access, let latest = try? store.document(live.scope) else { return false }
                                    let current = PantryPlacedProductLinks(journeys: pickup.journeys)
                                    return latest.minimums?.contains(target) == true && model.snapshot?.state == snapshot.state &&
                                        current.byProduct[link] == placed.byProduct[link] && current.uncertain.contains(link) == placed.uncertain.contains(link) &&
                                        (placed.uncertain.contains(link) || (try? target.incoming(pickup.journeys, linkedLineIDs: linked)) == incoming) &&
                                        self.unresolvedProducts(in: snapshot) == unresolved
                                }, suggestedAmount: shopping, productLink: link, showCheckDates: false)
                            }
                            Button(pantryText("Remove minimum")) {
                                do { try store.updateMinimum(target, next: nil, foodID: target.foodID, access: access) }
                                catch { self.error = true }
                            }
                        }
                    }
                }
                if error { Text(pantryText("Food or reservations changed. Refresh and review again before saving.")) }
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }
        .onChange(of: selected) { _, id in
            guard let id, let lot = products.first(where: { $0.foodID == id }), let access,
                  let doc = try? store.document(access.scope) else { return }
            let saved = doc.minimums?.first { $0.foodID == id }
            unit = saved?.target.unit ?? lot.unit
            afterHolds = saved?.afterHolds ?? true
            amount = saved?.target.amount.description ?? ""
        }
        .navigationTitle(pantryText("Staple minimums")).privacySensitive()
    }
}
