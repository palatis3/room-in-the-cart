import CoreDomain
import SwiftUI
import LocalStore

struct PantryPortionControls: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let allowSplit: Bool
    @State private var moving = false
    @State private var discarding = false
    @State private var moved = ""
    @State private var moveUnit: UnitOfMeasure?
    @State private var discarded = ""
    @State private var reason = ""
    @State private var destination = InventoryLocation.freezer

    private var free: Quantity? { model.snapshot?.availability.lots.first { $0.id == lot.id }?.free }
    private var moveAmount: Quantity? { try? DinnerEntry.quantity(moved, unit: moveUnit ?? lot.unit) }
    private var canMove: Bool {
        guard let moveAmount, let free, let physical = lot.count.quantity,
              let amount = try? moveAmount.converted(to: lot.unit) else { return false }
        return amount > .zero && amount <= free.amount && amount < physical.amount
    }
    private var discardAmount: Quantity? { try? DinnerEntry.quantity(discarded, unit: lot.unit) }
    private var productDiscards: Int {
        (model.snapshot?.lots ?? []).filter { $0.foodID == lot.foodID }.reduce(0) { $0 + ($1.discardedTimes ?? 0) }
    }

    var body: some View {
        DisclosureGroup(pantryText("Move some"), isExpanded: $moving) {
            if allowSplit, let free, free.amount > .zero {
                LabeledContent(pantryText("Available for other meals"), value: pantryQuantity(free))
                TextField(pantryText("Amount to move"), text: $moved)
                Picker(pantryText("Unit"), selection: Binding(get: { moveUnit ?? lot.unit }, set: { moveUnit = $0 })) {
                    ForEach(UnitOfMeasure.allCases.filter { $0.dimension == lot.unit.dimension }, id: \.self) { Text(pantryUnit($0)).tag($0) }
                }
                Picker(pantryText("Move to"), selection: $destination) {
                    ForEach(InventoryLocation.allCases.filter { $0 != lot.location }, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                }
                Button(pantryText("Review transfer")) {
                    guard let moveAmount else { return }
                    Task { await model.preparePortion(.split(amount: moveAmount, destination: destination, lotID: UUID(),
                                                              eventID: UUID(), observationID: UUID()), from: lot) }
                }.disabled(!canMove)
            } else { Text(pantryText("Recount this batch and review its reservations before moving part of it.")) }
        }.onAppear { if destination == lot.location { destination = .cupboard } }
        DisclosureGroup(pantryText("Discarded"), isExpanded: $discarding) {
            TextField(pantryText("Amount discarded (optional)") + " · " + pantryUnit(lot.unit), text: $discarded)
            TextField(pantryText("Reason (optional)"), text: $reason)
            if discarded.isEmpty { Text(pantryText("Without a measured amount, the remaining count becomes unknown.")) }
            Button(pantryText("Review discard")) {
                let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                let action = InventoryPortionAction.discard(amount: discardAmount, reason: note.isEmpty ? nil : note)
                Task { await model.preparePortion(action, from: lot) }
            }.disabled(lot.count.quantity?.amount == .zero || reason.utf8.count > 256 ||
                       (!discarded.isEmpty && discardAmount.map { $0.amount > .zero && $0.amount <= (lot.count.quantity?.amount ?? .zero) } != true))
        }
        if productDiscards > 0 {
            NavigationLink {
                PantryDiscardHistory(model: model, foodID: lot.foodID)
            } label: {
                LabeledContent(pantryText("Recorded discards for this product"), value: productDiscards.formatted())
            }
        }
        if let undo = lot.discardUndo {
            Button(pantryText("Undo discard")) { Task { await model.preparePortion(.undoDiscard(eventID: undo.eventID), from: lot) } }
        }
    }
}

struct PantryPortionSummary: View {
    let action: InventoryPortionAction
    var body: some View {
        switch action {
        case let .split(quantity, destination, _, _, _):
            LabeledContent(pantryFormat("Move to %@", pantryLocationName(destination)), value: pantryQuantity(quantity))
        case let .discard(quantity, reason):
            LabeledContent(pantryText("Discarded"), value: pantryQuantity(quantity))
            if let reason { Text(verbatim: reason) }
        case .undoDiscard: Text(pantryText("Undo discard"))
        }
    }
}

private struct PantryDiscardHistory: View {
    @ObservedObject var model: PantryModel
    let foodID: UUID
    @State private var rows: [PantryDiscardRow] = []
    @State private var loaded: InventoryState?
    @State private var failed = false

    var body: some View {
        JournalList {
            if model.canEdit, let basis = model.snapshot?.state, loaded == basis {
                ForEach(rows) { row in
                    VStack(alignment: .leading) {
                        Text(row.date.formatted(date: .abbreviated, time: .shortened))
                        Text(pantryFormat("Batch %@", String(row.lotID.uuidString.suffix(8))))
                        Text(pantryQuantity(row.amount))
                        if let reason = row.reason { Text(verbatim: reason) }
                    }
                }
            } else if failed || !model.canEdit { Text(pantryText("This review is unavailable. Return to My Pantry.")) }
            else { ProgressView() }
        }
        .task(id: model.snapshot?.state) {
            rows = []; loaded = nil; failed = false
            guard let basis = model.snapshot?.state, model.canEdit else { return }
            do {
                let result = try await model.discardHistory(foodID: foodID, basis: basis)
                guard !Task.isCancelled else { return }
                rows = result; loaded = basis
            } catch { if !Task.isCancelled { failed = true } }
        }
        .navigationTitle(pantryText("Discard history")).privacySensitive()
    }
}
