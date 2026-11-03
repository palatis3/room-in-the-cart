import CoreDomain
import SwiftUI

struct PickupSavedStockSection: View {
    @ObservedObject var model: PickupModel
    let journey: PickupJourney
    var onlyFoodID: UUID? = nil

    var body: some View {
        let batches = journey.stockLots.filter { $0.source != .manual && (onlyFoodID == nil || $0.foodID == onlyFoodID) }
        let previous = model.journeys.first { $0.id == journey.originShopID }
        let older = (previous?.stockLots ?? []).filter { lot in
            lot.source != .manual && !batches.contains(where: { $0.id == lot.id })
        }
        if !batches.isEmpty {
            Section(pTr("Saved pantry and freezer batches")) {
                ForEach(batches) { lot in
                    NavigationLink {
                        PickupBatchReview(model: model, journeyID: journey.id, lot: lot, carrying: false)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(lot.name)
                            Text("\(pQuantity(lot.usable)) · \(lot.confirmedAt.formatted())")
                                .font(.subheadline)
                            if lot.useFirst == true { Text(pTr("Use this batch first")) }
                        }
                    }.accessibilityIdentifier("stockBatch-" + lot.id.uuidString)
                }
            }
        }
        if onlyFoodID == nil, !older.isEmpty {
            Section(pTr("Recheck a batch from the previous shop")) {
                ForEach(older) { lot in
                    NavigationLink(lot.name) {
                        PickupBatchReview(model: model, journeyID: journey.id, lot: lot, carrying: true)
                    }
                }
            }
        }
    }
}

private struct PickupBatchReview: View {
    @ObservedObject var model: PickupModel
    let journeyID: UUID
    let lot: ConfirmedStockLot
    let carrying: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var foodID: UUID?
    @State private var observedAt = Date()
    @State private var useFirst: Bool
    @State private var checked = false

    init(model: PickupModel, journeyID: UUID, lot: ConfirmedStockLot, carrying: Bool) {
        self.model = model
        self.journeyID = journeyID
        self.lot = lot
        self.carrying = carrying
        _useFirst = State(initialValue: lot.useFirst == true)
    }

    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Section(lot.name) {
                Text(pTr(lot.source == .freezer ? "Freezer" : "Pantry"))
                Text("\(pQuantity(lot.usable)) · \(lot.confirmedAt.formatted())")
                if !carrying, let allocation = model.allocation {
                    let reservations = allocation.allocations.filter { $0.lotID == lot.id }
                    ForEach(reservations, id: \.needID) { edge in
                        let name = model.journey?.needs.first { $0.id == edge.needID }?.name ??
                            model.journey?.stockNeeds.first { $0.id == edge.needID }?.name ??
                            model.journey?.plannedNeeds.first { $0.id == edge.needID }?.name
                        if let name {
                            Text("\(name) · \(pQuantity(edge.amount, unit: edge.unit))")
                        }
                    }
                    if let balance = allocation.remainingLots.first(where: { $0.lotID == lot.id }) {
                        if balance.issues.isEmpty {
                            Text("\(pTr("Unreserved")): \(pQuantity(balance.remainingUnallocated, unit: balance.unit))")
                        } else {
                            Text(pTr("Unresolved"))
                        }
                    }
                }
            }
            if model.journey?.id == journeyID, model.journey?.closedAt == nil {
                Section(pTr(carrying ? "Confirm for this shop" : "Correct the observed batch")) {
                    if carrying || lot.id == lot.foodID {
                        Picker(pTr("Reviewed matching food need"), selection: $foodID) {
                            Text(pTr("Keep unassigned until a meal is reviewed")).tag(UUID?.none)
                            ForEach(model.journey?.stockNeeds ?? []) { Text($0.name).tag(Optional($0.foodID)) }
                            ForEach(model.journey?.basket?.current.lines ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    TextField(pTr("Confirmed usable amount"), text: $amount).keyboardType(.decimalPad)
                    Text(pTr(lot.usable.unit.rawValue))
                    DatePicker(pTr("Batch observed at"), selection: $observedAt, in: ...Date())
                    Toggle(pTr("Use this batch first"), isOn: $useFirst)
                    Toggle(pTr("I reviewed identity, exclusions and usable quantity"), isOn: $checked)
                    Button(pTr("Save reviewed batch")) { save() }
                        .disabled(!checked || amount.isEmpty || model.saving)
                }
            }
        }.navigationTitle(pTr("Batch details"))
            .onChange(of: amount) { _, _ in checked = false }
            .onChange(of: foodID) { _, _ in checked = false }
            .onChange(of: observedAt) { _, _ in checked = false }
            .onChange(of: useFirst) { _, _ in checked = false }
            .scrollDismissesKeyboard(.interactively)
    }

    private func save() {
        do {
            let target = carrying || lot.id == lot.foodID ? foodID ?? lot.id : lot.foodID
            guard let quantity = try ComparisonModel.quantity(amount, lot.usable.unit) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let updated = ConfirmedStockLot(id: lot.id, foodID: target, name: lot.name, usable: quantity,
                                            confirmedAt: observedAt, source: lot.source, useFirst: useFirst)
            Task {
                if await model.saveStockLot(updated, in: journeyID, replacing: carrying ? nil : lot,
                                            carriedFrom: carrying ? lot : nil) { dismiss() }
            }
        } catch { model.error = pTr("Check the confirmed food amounts and matching units.") }
    }
}

struct PickupNewStockSection: View {
    @ObservedObject var model: PickupModel
    let ingredientID: UUID?
    init(model: PickupModel, ingredientID: UUID? = nil) {
        self.model = model
        self.ingredientID = ingredientID
        _stockFoodID = State(initialValue: ingredientID)
    }
    private enum Field { case stockName, stockAmount }
    @FocusState private var field: Field?
    @State private var newJourneyID = UUID()
    @State private var stockFoodID: UUID?
    @State private var stockAmount = ""
    @State private var stockName = ""
    @State private var stockUnit: UnitOfMeasure = .count
    @State private var stockSource: ConfirmedStockSource = .freezer
    @State private var stockConfirmed = false
    @State private var stockID = UUID()
    @State private var stockObservedAt = Date()
    @State private var useFirst = false
    var body: some View {
        Section(pTr("Confirm pantry or freezer food")) {
            if let ingredientID,
               let line = model.journey?.basket?.current.lines.first(where: { $0.id == ingredientID }) {
                LabeledContent(pTr("Reviewed matching food need"), value: line.name)
            } else {
                Picker(pTr("Reviewed matching food need"), selection: $stockFoodID) {
                    Text(pTr("Keep unassigned until a meal is reviewed")).tag(UUID?.none)
                    ForEach(model.journey?.stockNeeds ?? []) { Text($0.name).tag(Optional($0.foodID)) }
                    ForEach(model.journey?.basket?.current.lines ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            TextField(pTr("Actual food or freezer batch"), text: $stockName).focused($field, equals: .stockName)
            TextField(pTr("Confirmed usable amount"), text: $stockAmount).keyboardType(.decimalPad).focused($field, equals: .stockAmount)
            Picker(pTr("Unit"), selection: $stockUnit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) } }
            Picker(pTr("Stock source"), selection: $stockSource) {
                Text(pTr("Freezer")).tag(ConfirmedStockSource.freezer)
                Text(pTr("Pantry")).tag(ConfirmedStockSource.pantry)
            }
            DatePicker(pTr("Batch observed at"), selection: $stockObservedAt, in: ...Date())
            Toggle(pTr("Use this batch first"), isOn: $useFirst)
            Toggle(pTr("I reviewed identity, exclusions and usable quantity"), isOn: $stockConfirmed)
            Button(pTr("Confirm this separate stock lot")) { addStock() }.disabled(!stockConfirmed)
            Text(pTr("Only confirmed matching food enters allocation. Do not enter the same batch twice."))
        }
            .onChange(of: [stockName, stockAmount, stockUnit.rawValue, stockSource.rawValue]) { _, _ in stockConfirmed = false }
            .onChange(of: stockFoodID) { _, _ in stockConfirmed = false }
            .onChange(of: stockObservedAt) { _, _ in stockConfirmed = false }
            .onChange(of: useFirst) { _, _ in stockConfirmed = false }

            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if field != nil {
                        Spacer()
                        Button(tr("Done")) { field = nil }
                    }
                }
            }
    }
    private func addStock() {
        do {
            guard !stockName.isEmpty, let quantity = try ComparisonModel.quantity(stockAmount, stockUnit) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let journeyID = model.journey?.id ?? newJourneyID
            let startsWorkspace = model.journey == nil
            let lot = ConfirmedStockLot(id: stockID, foodID: stockFoodID ?? stockID, name: stockName, usable: quantity,
                                        confirmedAt: stockObservedAt, source: stockSource, useFirst: useFirst)
            Task {
                if await model.saveStockLot(lot, in: journeyID, createIfEmpty: startsWorkspace) {
                    stockID = UUID(); stockName = ""; stockAmount = ""; stockConfirmed = false
                    useFirst = false; stockObservedAt = Date()
                }
            }
        } catch { model.error = pTr("Check the confirmed food amounts and matching units.") }
    }
}
