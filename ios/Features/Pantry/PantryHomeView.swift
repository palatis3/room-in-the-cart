import CoreDomain
import SwiftUI

private enum PantrySheet: Identifiable {
    case add, recount(UUID), purchase(PantryRecentPurchase), review
    var id: String {
        switch self { case .add: return "add"; case .recount(let id): return "recount-\(id)"; case .purchase(let row): return "purchase-\(row.id)"; case .review: return "review" }
    }
}

/// Composition owns authorization and migration. This surface never activates a database.
struct PantryHomeView: View {
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    @State private var sheet: PantrySheet?
    @AccessibilityFocusState private var resultFocused: Bool

    var body: some View {
        Group {
            if accessAllowed {
                List {
                    if let notice = model.notice {
                        Section {
                            Text(pantryNotice(notice)).accessibilityIdentifier("pantry.status")
                                .accessibilityFocused($resultFocused)
                        }
                    }
                    if model.phase == .ready, let snapshot = model.snapshot {
                        Section {
                            Button(pantryText("Add food")) { sheet = .add }
                                .frame(minHeight: 44).disabled(!model.canEdit)
                                .accessibilityIdentifier("pantry.add")
                            let purchases = model.recentPurchases
                            if !purchases.isEmpty {
                                DisclosureGroup(pantryText("Choose a recent purchase")) {
                                    ForEach(purchases) { row in
                                        Button {
                                            sheet = .purchase(row)
                                        } label: {
                                            VStack(alignment: .leading) {
                                                Text(row.reviewedFood.name)
                                                Text(pantryFormat("Received %@ on %@", pantryQuantity(row.received),
                                                    row.receivedAt.formatted(date: .abbreviated, time: .omitted)))
                                                Text(pantryFormat("Batch %@", String(row.id.uuidString.suffix(8))))
                                            }.accessibilityElement(children: .combine)
                                        }.disabled(!model.canEdit)
                                        .frame(minHeight: 44)
                                        .accessibilityIdentifier("pantry.purchase.\(row.id)")
                                    }
                                }.accessibilityIdentifier("pantry.recentPurchases")
                            }
                        }
                        ForEach(InventoryLocation.allCases, id: \.self) { location in
                            Section(pantryLocationName(location)) {
                                let lots = snapshot.lots.filter { $0.location == location }.sorted {
                                    $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                }
                                if lots.isEmpty { Text(pantryText("No food recorded here.")) }
                                ForEach(lots) { lot in
                                    NavigationLink {
                                        PantryLotEntryView(model: model, lotID: lot.id, accessAllowed: accessAllowed)
                                    } label: {
                                        PantryLotSummary(lot: lot, availability: snapshot.availability.lots.first { $0.id == lot.id })
                                    }.accessibilityIdentifier("pantry.lot.\(lot.id)")
                                }
                            }
                        }
                    } else {
                        Section { Text(pantryPhase(model.phase)) }
                    }
                    if model.pending != nil {
                        Section {
                            Button(pantryText("Review pending save")) { sheet = .review }.frame(minHeight: 44)
                        }
                    }
                    if model.phase != .accessDenied {
                        Section {
                            Button(pantryText("Refresh pantry")) { Task { await model.load() } }
                                .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("pantry.refresh")
                        }
                    }
                    if model.busy { ProgressView(pantryText("Working…")) }
                }
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }
        .navigationTitle(pantryText("My Pantry"))
        .privacySensitive()

        .modifier(PantryEntryPresentation(model: model, accessAllowed: accessAllowed, sheet: $sheet,
                                          handlesReview: sheet != nil) {
            resultFocused = true
        })
    }
}

/// Shared canonical lot entry for My Pantry and live pickup readers. A source
/// alias never becomes a new acquisition: every action names this canonical ID.
struct PantryLotEntryView: View {
    @ObservedObject var model: PantryModel
    let lotID: UUID
    let accessAllowed: Bool
    var availabilityNeedsReview = false
    @State private var sheet: PantrySheet?

    var body: some View {
        PantryLotView(model: model, lotID: lotID, accessAllowed: accessAllowed,
                      availabilityNeedsReview: availabilityNeedsReview) { sheet = .recount(lotID) }
            .safeAreaInset(edge: .bottom) {
                if accessAllowed, model.pending != nil {
                    Button(pantryText("Review pending save")) { sheet = .review }
                        .frame(minHeight: 44).buttonStyle(.borderedProminent)
                } else if accessAllowed, model.phase != .ready, model.phase != .accessDenied {
                    Button(pantryText("Refresh pantry")) { Task { await model.load() } }
                        .frame(minHeight: 44).disabled(model.busy)
                }
            }
            .navigationBarBackButtonHidden(model.busy || model.pending != nil)
            .interactiveDismissDisabled(model.busy || model.pending != nil)
            .modifier(PantryEntryPresentation(model: model, accessAllowed: accessAllowed, sheet: $sheet,
                                             availabilityNeedsReview: availabilityNeedsReview))
    }
}

/// Shared manual acquisition entry. Pending recovery is shown before another
/// batch can be entered; the repository retains the exact original command.
struct PantryAddFoodEntryView: View {
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    var reviewedFood: PantryReviewedFood? = nil
    let refreshContext: () async -> Void
    @State private var sheet: PantrySheet?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if accessAllowed, model.phase == .ready, model.pending == nil, !model.requiresFreshReview {
                PantryFoodEditor(model: model, lotID: nil, accessAllowed: accessAllowed, reviewedFood: reviewedFood)
            } else {
                Form {
                    Text(accessAllowed ? pantryPhase(model.phase)
                         : pantryText("Unlock the authorized private workspace to view pantry food."))
                    if accessAllowed {
                        if let notice = model.notice { Text(pantryNotice(notice)) }
                        if model.pending != nil {
                            Button(pantryText("Review pending save")) { sheet = .review }.frame(minHeight: 44)
                        }
                        if model.phase != .accessDenied {
                            Button(pantryText("Refresh pantry")) {
                                Task {
                                    if model.pending == nil { await refreshContext() }
                                    else { await model.load() }
                                }
                            }.frame(minHeight: 44).disabled(model.busy)
                        }
                        if model.busy { ProgressView(pantryText("Working…")) }
                    }
                }
            }
        }
        .navigationTitle(pantryText("Add food"))
        .privacySensitive()
        .navigationBarBackButtonHidden(model.busy || model.pending != nil)
        .interactiveDismissDisabled(model.busy || model.pending != nil)
        .modifier(PantryEntryPresentation(model: model, accessAllowed: accessAllowed, sheet: $sheet) { dismiss() })
    }
}

/// One lifecycle keeps add/recount/review behavior and access-loss redaction the
/// same regardless of the reader that opened a lot.
private struct PantryEntryPresentation: ViewModifier {
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    @Binding var sheet: PantrySheet?
    // The list owns its add and purchase sheets. A pushed lot owns its own actions.
    var handlesReview = true
    var availabilityNeedsReview = false
    var didSave: () -> Void = {}

    func body(content: Content) -> some View {
        content
        .task(id: accessAllowed) {
            if !accessAllowed { sheet = nil }
            await model.loadOnAppearance(accessAllowed: accessAllowed)
        }
        .onChange(of: accessAllowed) { _, allowed in
            if !allowed { sheet = nil; model.accessLost() }
        }
        .onChange(of: model.review?.command.id) { _, id in
            if id != nil && accessAllowed && handlesReview { sheet = .review }
        }
        .onChange(of: model.savedLotID) { _, id in
            if id != nil && handlesReview { sheet = nil; didSave() }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .accessDenied { sheet = nil }
        }
        .sheet(isPresented: Binding(get: { accessAllowed && model.phase != .accessDenied && sheet != nil }, set: { shown in
            if !shown {
                if case .review = sheet, model.pending == nil { model.cancelReview() }
                sheet = nil
            }
        })) {
            NavigationStack {
                if let value = sheet {
                    switch value {
                    case .add: PantryFoodEditor(model: model, lotID: nil, accessAllowed: accessAllowed)
                    case .recount(let id): PantryFoodEditor(model: model, lotID: id, accessAllowed: accessAllowed)
                    case .purchase(let row): PantryFoodEditor(model: model, lotID: row.id, accessAllowed: accessAllowed, purchase: row)
                    case .review: PantryReviewView(model: model, accessAllowed: accessAllowed,
                                                   availabilityNeedsReview: availabilityNeedsReview)
                    }
                }
            }
        }
    }
}

struct PantryLotSummary: View {
    let lot: InventoryLot
    let availability: InventoryLotAvailability?
    var availabilityNeedsReview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lot.name).font(.headline)
            Text(pantryCount(lot.count))
            Text(pantryFormat("Batch %@", String(lot.id.uuidString.suffix(8))))
                .font(.caption)
            LabeledContent(pantryText("Reserved"), value: pantryQuantity(availability?.held))
            LabeledContent(pantryText("Available for other meals"), value: pantryQuantity(availabilityNeedsReview ? nil : availability?.free))
            if availabilityNeedsReview || availability == nil || availability?.issues.isEmpty == false {
                Text(pantryText("Availability needs review. Unknown food is not counted as free."))
            }
            LabeledContent(pantryText("Last quantity confirmation"), value: lot.confirmedAt.formatted(date: .abbreviated, time: .shortened))
        }.accessibilityElement(children: .combine)
    }
}

private struct PantryLotView: View {
    @ObservedObject var model: PantryModel
    let lotID: UUID
    let accessAllowed: Bool
    var availabilityNeedsReview = false
    let recount: () -> Void
    @AccessibilityFocusState private var resultFocused: Bool
    private var lot: InventoryLot? { accessAllowed ? model.snapshot?.lots.first { $0.id == lotID } : nil }
    var body: some View {
        Form {
            if let lot {
                Section {
                    PantryLotSummary(lot: lot, availability: model.snapshot?.availability.lots.first { $0.id == lotID },
                                     availabilityNeedsReview: availabilityNeedsReview)
                    LabeledContent(pantryText("Storage location"), value: pantryLocationName(lot.location))
                    if let opened = lot.openedAt {
                        LabeledContent(pantryText("Opened"), value: opened.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                PantryReservationSection(model: model, lot: lot, availabilityNeedsReview: availabilityNeedsReview)
                    .id(lot.id)
                Section {
                    action("Have enough", .haveEnough)
                    action("Some left", .someLeft)
                    Button(pantryText("Recount food"), action: recount).frame(minHeight: 44)
                        .accessibilityIdentifier("pantry.recount")
                    action("Opened now", .opened)
                    ForEach(InventoryLocation.allCases.filter { $0 != lot.location }, id: \.self) { location in
                        Button(pantryFormat("Move to %@", pantryLocationName(location))) {
                            Task { await model.prepare(lotID: lotID, action: .move(location)) }
                        }.frame(minHeight: 44)
                    }
                    action("Used up", .usedUp)
                } footer: {
                    Text(pantryText("Have enough and Some left replace the old count with an unknown amount. Reservations stay protected and may need review."))
                }.disabled(!model.canEdit)
                if let notice = model.notice { Text(pantryNotice(notice)).accessibilityFocused($resultFocused) }
            } else if !accessAllowed {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if model.phase != .ready {
                Text(pantryPhase(model.phase))
                if model.busy { ProgressView(pantryText("Working…")) }
            } else { Text(pantryText("This food is unavailable. Return to My Pantry and refresh.")) }
        }
        .navigationTitle(lot?.name ?? pantryText("Pantry food"))
        .onChange(of: model.notice) { _, notice in if notice == .saved { resultFocused = true } }
        .privacySensitive()
    }
    private func action(_ title: String, _ action: PantryModel.Action) -> some View {
        Button(pantryText(title)) { Task { await model.prepare(lotID: lotID, action: action) } }
            .frame(minHeight: 44)
    }
}

private struct PantryFoodEditor: View {
    @ObservedObject var model: PantryModel
    let lotID: UUID?
    let accessAllowed: Bool
    var reviewedFood: PantryReviewedFood? = nil
    var purchase: PantryRecentPurchase? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var existingFoodID: UUID?
    @State private var name = ""
    @State private var amount = ""
    @State private var unit = UnitOfMeasure.count
    @State private var location = InventoryLocation.cupboard
    @FocusState private var editing: Bool
    private var lot: InventoryLot? { lotID.flatMap { id in model.snapshot?.lots.first { $0.id == id } } }
    private var foods: [InventoryLot] {
        var seen = Set<UUID>()
        return (model.snapshot?.lots ?? []).sorted { $0.id.uuidString < $1.id.uuidString }.filter { seen.insert($0.foodID).inserted }
    }
    var body: some View {
        Form {
            if accessAllowed && model.phase == .ready {
                if lotID == nil {
                    Section {
                        if let reviewedFood {
                            LabeledContent(pantryText("Food identity"), value: reviewedFood.name)
                        } else {
                            Picker(pantryText("Food identity"), selection: $existingFoodID) {
                                Text(pantryText("New food identity")).tag(nil as UUID?)
                                ForEach(foods) { food in
                                    Text(food.name + " · " + food.foodID.uuidString.suffix(8)).tag(Optional(food.foodID))
                                }
                            }
                            if existingFoodID == nil {
                                TextField(pantryText("Food name"), text: $name).focused($editing)
                                    .accessibilityIdentifier("pantry.foodName")
                            }
                        }
                        Picker(pantryText("Storage location"), selection: $location) {
                            ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                        }
                    } footer: {
                        Text(pantryText("Choose an existing food only when it is the same product. This adds a separate physical batch; matching names are never merged automatically."))
                    }
                }
                if let purchase {
                    Section {
                        Text(purchase.reviewedFood.name).font(.headline)
                        LabeledContent(pantryText("Received quantity"), value: pantryQuantity(purchase.received))
                        Picker(pantryText("Storage location"), selection: $location) {
                            ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                        }
                    }
                }
                Section {
                    TextField(pantryText(purchase == nil ? "Confirmed amount" : "Amount remaining"), text: $amount).focused($editing)
                        .accessibilityIdentifier("pantry.amount")
                    if purchase != nil {
                        LabeledContent(pantryText("Unit"), value: pantryUnit(unit))
                    } else {
                        Picker(pantryText("Unit"), selection: $unit) {
                            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
                        }
                    }
                } footer: {
                    Text(pantryText("Leave blank if unknown. Enter 0 only for confirmed none. Count means individual units, not an assumed package size."))
                }
                if let notice = model.notice { Text(pantryNotice(notice)) }
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }
        .navigationTitle(pantryText(purchase != nil ? "Review recent purchase" : lotID == nil ? "Add food" : "Recount food"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pantryText("Cancel")) { dismiss() }.disabled(model.busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(pantryText("Review")) {
                    editing = false
                    Task {
                        if let purchase { await model.prepareRecentPurchase(purchase, amount: amount, location: location) }
                        else if let lotID { await model.prepare(lotID: lotID, action: .recount(amount, unit)) }
                        else { await model.prepareNewFood(name: name, existingFoodID: existingFoodID, reviewedFood: reviewedFood, location: location, amount: amount, unit: unit) }
                    }
                }.disabled(!accessAllowed || !model.canEdit || (lotID == nil && reviewedFood == nil && existingFoodID == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("pantry.review")
            }
        }
        .onAppear { if let lot { amount = lot.count.quantity?.amount.description ?? ""; unit = lot.unit; location = lot.location } }
        .interactiveDismissDisabled(model.busy)
        .privacySensitive()
    }
}

private struct PantryReviewView: View {
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    var availabilityNeedsReview = false
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    var body: some View {
        Form {
            if accessAllowed, let review = model.review {
                Section(pantryText("Proposed food record")) {
                    PantryLotSummary(lot: review.proposedLot,
                        availability: review.proposedAvailability.lots.first { $0.id == review.command.lotID },
                        availabilityNeedsReview: availabilityNeedsReview)
                    LabeledContent(pantryText("Storage location"), value: pantryLocationName(review.proposedLot.location))
                    if let opened = review.proposedLot.openedAt {
                        LabeledContent(pantryText("Opened"), value: opened.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let before = review.before.lots.first(where: { $0.id == review.command.lotID }) {
                        LabeledContent(pantryText("Previously recorded"), value: pantryCount(before.count))
                        LabeledContent(pantryText("Previous location"), value: pantryLocationName(before.location))
                    }
                }
                if case let .reservation(edit) = review.command.change {
                    Section(pantryText("Reservation change")) {
                        PantryReservationSummary(edit: edit, claim: review.before.reservations.first { $0.id == edit.id })
                        LabeledContent(pantryText("Previously available"), value: pantryQuantity(review.before.availability.lots.first {
                            $0.id == review.command.lotID
                        }?.free))
                    }
                }
                if !review.affectedReservations.isEmpty {
                    Section(pantryText("Affected reservations")) {
                        ForEach(review.affectedReservations) { coverage in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(review.before.reservations.first { $0.id == coverage.id }?.name ?? pantryText("Reservation")).font(.headline)
                                LabeledContent(pantryText("Reserved need"), value: pantryQuantity(coverage.requested))
                                LabeledContent(pantryText("Covered before"), value: pantryQuantity(review.before.availability.reservations.first { $0.id == coverage.id }?.backed))
                                LabeledContent(pantryText("Covered after"), value: pantryQuantity(coverage.backed))
                                LabeledContent(pantryText("Still missing"), value: pantryQuantity(coverage.shortfall))
                                if coverage.unresolved { Text(pantryText("This reservation needs review. Its promise is not released.")) }
                            }.accessibilityElement(children: .combine)
                        }
                        Toggle(pantryText("I reviewed the affected reservations."), isOn: $acknowledged)
                            .accessibilityIdentifier("pantry.acknowledgeReservations")
                    }
                }
                if let notice = model.notice {
                    Text(model.pendingWasCommitted ? pantryText("Your change is saved. Retry to finish recovery.") : pantryNotice(notice))
                        .accessibilityIdentifier("pantry.reviewStatus")
                }
            } else if accessAllowed, let pending = model.pending {
                Section(pantryText("Review pending save")) {
                    PantryPendingSummary(entry: pending)
                    Text(pantryText("A saved change is waiting for recovery. Retry it or review its saved status."))
                    if let notice = model.notice {
                        Text(model.pendingWasCommitted ? pantryText("Your change is saved. Retry to finish recovery.") : pantryNotice(notice))
                    }
                }
            } else { Text(pantryText("This review is unavailable. Return to My Pantry.")) }
            if accessAllowed {
                if model.pending != nil {
                    Section {
                        if model.requiresFreshReview {
                            Button(pantryText("Discard stale review and refresh")) {
                                Task { await model.discardStaleReview(); if model.pending == nil { dismiss() } }
                            }.frame(minHeight: 44).disabled(model.busy)
                        } else {
                            Button(pantryText("Retry exact save")) { Task { await model.retryPending() } }
                                .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("pantry.retrySave")
                            Text(pantryText(model.pendingWasCommitted || model.pending?.acknowledgment != nil
                                ? "Your change is saved. Retry to finish recovery."
                                : "The save result is uncertain. Retry the same reviewed change before starting another."))
                        }
                    }
                }
            }

        }
        .navigationTitle(pantryText("Review pantry change"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pantryText("Cancel")) { model.cancelReview(); dismiss() }
                    .disabled(model.busy || model.pending != nil)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(pantryText("Confirm")) { Task { await model.confirmReview(acknowledgingReservations: acknowledged) } }
                    .disabled(!accessAllowed || model.busy || model.pending != nil || model.review == nil || (!acknowledged && model.review?.affectedReservations.isEmpty == false))
                    .accessibilityIdentifier("pantry.confirm")
            }
        }
        .interactiveDismissDisabled(model.busy || model.pending != nil)
        .privacySensitive()
    }
}

/// Original intent only. No old before/after reservation preview is reconstructed
/// from today's inventory when an editor reopens after process death.
private struct PantryPendingSummary: View {
    let entry: PantryPendingStore.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pantryFormat("Batch %@", String(entry.command.lotID.uuidString.suffix(8))))
            switch entry.command.change {
            case .create(let seed, _):
                Text(pantryText("Add food")).font(.headline)
                Text(seed.name)
                Text(pantryCount(seed.count))
                Text(pantryLocationName(seed.location))
            case .count(let count, _):
                Text(pantryText("Recount food")).font(.headline)
                Text(pantryCount(count))
            case .opened(let date):
                LabeledContent(pantryText("Opened"), value: date.formatted(date: .abbreviated, time: .shortened))
            case .move(let location): Text(pantryFormat("Move to %@", pantryLocationName(location)))
            case .usedUp: Text(pantryText("Used up"))
            case .revise: Text(pantryText("Review pantry change"))
            case .reservation(let edit): PantryReservationSummary(edit: edit, claim: nil)
            }
            Text(entry.command.occurredAt.formatted(date: .abbreviated, time: .shortened))
        }.accessibilityElement(children: .combine)
    }
}
