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
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var amountFocused: Bool
    @AccessibilityFocusState private var previewFocused: Bool
    @State private var review: PickupStockLotReview?
    @State private var effectsConfirmed = false
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
                            ForEach(model.journey?.reviewedStockMatches ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    TextField(pTr("Confirmed usable amount"), text: $amount).keyboardType(.decimalPad).focused($amountFocused)
                        .accessibilityIdentifier("stockReview.amount")
                    Text(pTr(lot.usable.unit.rawValue))
                    DatePicker(pTr("Batch observed at"), selection: $observedAt, in: ...Date())
                    Toggle(pTr("Use this batch first"), isOn: $useFirst)
                    Toggle(pTr("I reviewed identity, exclusions and usable quantity"), isOn: $checked)
                        .accessibilityIdentifier("stockReview.identityChecked")
                    Button(pTr("Preview batch effects")) { preview() }
                        .disabled(!checked || amount.isEmpty || model.saving || model.hasPendingSave || currentScope == nil)
                        .accessibilityIdentifier("stockReview.preview")
                }
            }
            if let review {
                Section {
                    Text(pTr("Review dependent meals")).font(.headline).accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($previewFocused)
                    Text("\(pTr("Confirmed usable amount")): \(pQuantity(review.lot.usable))")
                    Text(review.lot.confirmedAt.formatted())
                    if review.lot.useFirst == true { Text(pTr("Use this batch first")) }
                    if review.meals.isEmpty { Text(pTr("No reviewed meal depends on this batch.")) }
                    ForEach(review.meals) { effect in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(effect.need.name).font(.headline)
                            if effect.need.priority == .protected { Text(pTr("set aside first")) }
                            Text("\(pTr("Required")): \(pQuantity(effect.need.amount))")
                            Text("\(pTr("Before this change")): \(coverage(effect.before))")
                            Text("\(pTr("After this change")): \(coverage(effect.after))")
                            Text("\(pTr("Allocation change")): \(delta(effect.before?.allocated, effect.after?.allocated, unit: effect.after?.unit ?? effect.need.amount.unit))")
                            Text("\(pTr("Shortfall change")): \(delta(effect.before?.shortfall, effect.after?.shortfall, unit: effect.after?.unit ?? effect.need.amount.unit))")
                        }.accessibilityElement(children: .combine)
                            .accessibilityIdentifier("stockReview.meal." + effect.id.uuidString)
                    }
                    if !model.isCurrentStockLotReview(review, scope: currentScope) {
                        Text(pTr("The batch or meal commitments changed. Review the effects again before saving."))
                            .accessibilityIdentifier("stockReview.stale")
                    }
                    Toggle(pTr("I reviewed the effects on every dependent meal"), isOn: $effectsConfirmed)
                        .accessibilityIdentifier("stockReview.effectsChecked")
                    Button(pTr("Save reviewed batch")) {
                        Task {
                            if await model.applyStockLotReview(review, scope: currentScope, confirmed: effectsConfirmed) { dismiss() }
                        }
                    }.disabled(!effectsConfirmed || !model.isCurrentStockLotReview(review, scope: currentScope))
                        .accessibilityIdentifier("stockReview.apply")
                    Button(pTr("Cancel batch preview"), role: .cancel) { cancelPreview() }
                        .disabled(model.saving).accessibilityIdentifier("stockReview.cancel")
                }
            }
        }.navigationTitle(pTr("Batch details"))
            .onChange(of: amount) { _, _ in checked = false; cancelPreview() }
            .onChange(of: foodID) { _, _ in checked = false; cancelPreview() }
            .onChange(of: observedAt) { _, _ in checked = false; cancelPreview() }
            .onChange(of: useFirst) { _, _ in checked = false; cancelPreview() }
            .onChange(of: currentScope) { _, _ in effectsConfirmed = false }
            .onChange(of: model.journey?.revision) { _, _ in effectsConfirmed = false }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelPreview() } }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if amountFocused { Spacer(); Button(tr("Done")) { amountFocused = false } }
                }
            }
    }

    private var currentScope: PickupStockReviewScope? {
        guard scenePhase == .active, access.unlocked, !household.locked, let workspaceID = model.sourceWorkspaceID else { return nil }
        if let projection = household.projection {
            guard household.identity != nil, projection.enrolled, ["shopper", "organizer"].contains(projection.role) else { return nil }
        } else if household.identity != nil { return nil }
        return .init(workspaceID: workspaceID, localActorID: access.localActorID, accountSubject: household.identity?.subject,
            householdID: household.projection?.household.id, memberID: household.projection?.memberId, role: household.projection?.role)
    }
    private func cancelPreview() { review = nil; effectsConfirmed = false }
    private func coverage(_ value: StockDemandCoverage?) -> String {
        let allocated = value.flatMap { value in value.allocated.map { pQuantity($0, unit: value.unit) } } ?? pTr("Unresolved")
        let short = value.flatMap { value in value.shortfall.map { pQuantity($0, unit: value.unit) } } ?? pTr("Unresolved")
        return "\(pTr("Allocated")): \(allocated) · \(pTr("Still short")): \(short)"
    }
    private func delta(_ before: Rational?, _ after: Rational?, unit: UnitOfMeasure) -> String {
        guard let before, let after, let amount = try? max(before, after).subtracting(min(before, after)) else { return pTr("Unresolved") }
        return (after == before ? "" : (after > before ? "+" : "−")) + pQuantity(amount, unit: unit)
    }
    private func preview() {
        do {
            let target = carrying || lot.id == lot.foodID ? foodID ?? lot.id : lot.foodID
            guard let quantity = try ComparisonModel.quantity(amount, lot.usable.unit) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let updated = ConfirmedStockLot(id: lot.id, foodID: target, name: lot.name, usable: quantity,
                                            confirmedAt: observedAt, source: lot.source, useFirst: useFirst)
            guard let scope = currentScope else { throw PickupStockReviewError.stale }
            amountFocused = false
            review = try model.previewStockLot(updated, in: journeyID, replacing: carrying ? nil : lot,
                carriedFrom: carrying ? lot : nil, scope: scope)
            effectsConfirmed = false; previewFocused = true
        } catch {
            model.error = pTr((error as? PickupStockReviewError) == .stale
                ? "Review the saved batch again before changing it." : "Check the confirmed food amounts and matching units.")
        }
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
               let match = model.journey?.reviewedStockMatches.first(where: { $0.id == ingredientID }) {
                LabeledContent(pTr("Reviewed matching food need"), value: match.name)
            } else {
                Picker(pTr("Reviewed matching food need"), selection: $stockFoodID) {
                    Text(pTr("Keep unassigned until a meal is reviewed")).tag(UUID?.none)
                    ForEach(model.journey?.reviewedStockMatches ?? []) { Text($0.name).tag(Optional($0.id)) }
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
            let lot = ConfirmedStockLot(id: stockID, foodID: ingredientID ?? stockFoodID ?? stockID, name: stockName, usable: quantity,
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
