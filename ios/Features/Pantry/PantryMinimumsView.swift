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

struct PantryStandingChecksView: View {
    let scope: PantryDigestScope
    @Environment(\.pantryDigestAccess) private var currentAccess
    @Environment(\.scenePhase) private var scene
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @ObservedObject private var store = PantryDigestStore.shared
    @State private var name = ""
    @State private var weeks = 1
    @State private var first = Date()
    @State private var busy = false
    @State private var error = false

    private var access: PantryDigestAccess? {
        guard scene == .active, let currentAccess, currentAccess.scope == scope, currentAccess.authorized() else { return nil }
        return currentAccess
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { clock in
            WorkingForm {
                if let access, let doc = try? store.document(scope) {
                    Section(pantryText("Schedule a stock check")) {
                        TextField(pantryText("Food name"), text: $name)
                            .accessibilityIdentifier("pantry.standing.name")
                        DatePicker(pantryText("First check"), selection: $first, displayedComponents: .date)
                        Stepper(weeks == 1 ? pantryText("Every week") : pantryFormat("Every %lld weeks", Int64(weeks)), value: $weeks, in: 1...12)
                        Button(pantryText("Save stock check")) {
                            do {
                                let day = try MealDay(date: first, timeZoneIdentifier: TimeZone.current.identifier)
                                let check = try PantryStandingCheck(name: name, weeks: weeks, first: day)
                                try store.updateStandingCheck(nil, next: check, access: access)
                                name = ""; error = false
                            } catch { self.error = true }
                        }.disabled(PantryRestockReview.foodName(name).isEmpty)
                    }
                    ForEach((doc.standingChecks ?? []).sorted { ($0.next.iso8601, $0.name) < ($1.next.iso8601, $1.name) }) { check in
                        Section(check.name) {
                            LabeledContent(pantryText("Next check"), value: check.next.iso8601 + " · " + check.next.timeZoneIdentifier)
                            if let last = check.lastAnswer {
                                let answer = switch last {
                                case .have: pantryText("Already have it")
                                case .skipped: pantryText("Skipped")
                                case .shopping: pantryText("Marked for shopping")
                                }
                                LabeledContent(pantryText("Last check"), value: answer)
                                    .accessibilityIdentifier("pantry.standing.lastAnswer")
                            }
                            if check.due(at: clock.date) {
                                if check.adding == nil {
                                    Button(pantryText("Already have it")) { answer(check, .have, access) }
                                    Button(pantryText("Skip this time")) { answer(check, .skipped, access) }
                                }
                                if let destination = destination(for: check) {
                                    let title = ledger.workspace.shops.first { $0.id == destination.shop }?.title ?? ledgerText("Pickup")
                                    Button(pantryFormat("Add to this trip: %@", title)) { add(check, to: destination, access: access) }
                                        .accessibilityIdentifier("pantry.standing.add")
                                } else {
                                    Text(pantryText("Choose an open shopping list to review this item."))
                                }
                            }
                            Button(pantryText("Remove stock check"), role: .destructive) {
                                do { try store.updateStandingCheck(check, next: nil, access: access); error = false }
                                catch { self.error = true }
                            }.disabled(busy || ledger.hasPendingSave || ledger.saving)
                        }
                    }
                    if error { Text(pantryText("The stock check changed. Review it and try again.")) }
                } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
            }.disabled(busy)
        }.navigationTitle(pantryText("Standing stock checks")).privacySensitive()
    }

    private func answer(_ check: PantryStandingCheck, _ value: PantryStandingCheck.Answer, _ access: PantryDigestAccess) {
        do { try store.updateStandingCheck(check, next: check.answering(value, at: Date()), access: access); error = false }
        catch { self.error = true }
    }

    private func destination(for check: PantryStandingCheck) -> PantryStandingCheck.Destination? {
        guard access != nil, ledger.ready, pickup.ready, !ledger.hasPendingLedgerDeletion,
              let workspace = ledger.sourceWorkspaceID else { return nil }
        if let pending = check.adding { return pending.workspace == workspace ? pending : nil }
        if let id = ledger.workspace.selectedShopID,
           ledger.workspace.shops.contains(where: { $0.id == id }),
           !pickup.journeys.contains(where: { $0.id == id && $0.closedAt != nil }) {
            return .init(workspace: workspace, shop: id, createFirst: false)
        }
        guard ledger.workspace.shops.isEmpty else { return nil }
        return .init(workspace: workspace, shop: ReceiptAcquisition.identity(["first-stock-check-shop", check.occurrence.uuidString]), createFirst: true)
    }

    private func add(_ check: PantryStandingCheck, to target: PantryStandingCheck.Destination, access: PantryDigestAccess) {
        guard !busy, access.authorized(), destination(for: check) == target, check.due(at: Date()) else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                var staged = check
                staged.adding = target
                if check.adding == nil { try store.updateStandingCheck(check, next: staged, access: access) }
                let expected = staged
                @MainActor func stillCurrent() -> Bool {
                    access.authorized() && ledger.sourceWorkspaceID == target.workspace &&
                        (try? store.document(scope).standingChecks?.contains(expected)) == true
                }
                guard stillCurrent() else { throw PantryDigestFailure.changed }
                let existing = ledger.workspace.shops.first { $0.id == target.shop }
                let alreadyCommitted = existing?.importBatches.contains { $0.id == check.occurrence } == true
                if !alreadyCommitted {
                    @MainActor func destinationCurrent() -> Bool {
                        stillCurrent() && !pickup.journeys.contains { $0.id == target.shop && $0.closedAt != nil }
                    }
                    guard destinationCurrent() else { throw PantryDigestFailure.changed }
                    if let existing {
                        guard ledger.workspace.selectedShopID == existing.id else { throw PantryDigestFailure.changed }
                        let saved = await ledger.editShop(key: "standing-check-" + check.occurrence.uuidString, shopID: existing.id,
                            authorize: { destinationCurrent() && ledger.workspace.selectedShopID == existing.id }) { shop in
                                try check.addToTrip(&shop)
                            }
                        guard saved else { throw PantryDigestFailure.changed }
                    } else {
                        guard target.createFirst, ledger.workspace.shops.isEmpty else { throw PantryDigestFailure.changed }
                        let shop = ShoppingLedger(id: target.shop, title: ledgerText("Pickup"))
                        let preview = try check.shoppingPreview(for: shop)
                        guard await ledger.addQuickGrocery(preview, selectedShopID: nil, workspaceID: target.workspace,
                                                          authorize: { destinationCurrent() }) else { throw PantryDigestFailure.changed }
                    }
                }
                guard stillCurrent() else { throw PantryDigestFailure.changed }
                try store.updateStandingCheck(expected, next: expected.answering(.shopping, at: Date()), access: access)
                error = false
            } catch { self.error = true }
        }
    }
}
