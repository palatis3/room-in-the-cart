import CoreDomain
import SwiftUI

struct PickupSavedStockSection: View {
    @ObservedObject var model: PickupModel
    let journey: PickupJourney
    var onlyFoodID: UUID? = nil
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var guardianChild

    private var privateReadAllowed: Bool {
        PickupStockReviewPresentation.current(workspaceID: model.sourceWorkspaceID, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: scenePhase == .active,
            childPresented: guardianChild?.presented == true, household: household).scope(presentationID: UUID()) != nil
    }

    var body: some View {
        if model.pantryIsActive {
            if privateReadAllowed {
                if journey.closedAt == nil {
                    PickupLivePantrySection(model: model, journeyID: journey.id, onlyFoodID: onlyFoodID)
                } else { legacySections }
            } else {
                Section { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
            }
        } else { legacySections }
    }

    @ViewBuilder private var legacySections: some View {
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
        if !model.pantryIsActive, onlyFoodID == nil, !older.isEmpty {
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

/// Live records are global physical lots. A previous-trip alias is navigation
/// evidence only; there is deliberately no "carry/copy" action after cutover.
private struct PickupLivePantrySection: View {
    @ObservedObject var model: PickupModel
    let journeyID: UUID
    let onlyFoodID: UUID?
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var guardianChild

    private var presentation: PickupStockReviewPresentation {
        .current(workspaceID: model.sourceWorkspaceID, localActorID: access.localActorID,
                 workspaceUnlocked: access.unlocked, sceneActive: scenePhase == .active,
                 childPresented: guardianChild?.presented == true, household: household)
    }
    private var canRead: Bool { presentation.scope(presentationID: UUID()) != nil }

    var body: some View {
        Section(pTr("Saved pantry and freezer batches")) {
            if !canRead {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if let projection = try? model.liveStockProjection(for: journeyID) {
                let lots = projection.lots.filter { onlyFoodID == nil || $0.current.foodID == onlyFoodID }
                if lots.isEmpty { Text(pantryText("No food recorded here.")) }
                ForEach(lots) { row in
                    NavigationLink {
                        PickupPantryLotDestination(model: model, journeyID: journeyID, lotID: row.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            PantryLotSummary(lot: row.current, availability: row.availability,
                                             availabilityNeedsReview: !row.issues.isEmpty)
                            LabeledContent(pantryText("Storage location"), value: pantryLocationName(row.current.location))
                            if row.current.useFirst == true { Text(pTr("Use this batch first")) }
                        }.accessibilityElement(children: .combine)
                    }.accessibilityIdentifier("stockBatch-" + row.readerID.uuidString)
                }
            } else {
                Text(pantryText("Could not load a complete pantry. No partial availability is shown."))
                Button(pantryText("Refresh pantry")) { Task { _ = await model.refreshPantryStock() } }
                    .disabled(model.saving).frame(minHeight: 44)
            }
        }.privacySensitive()
    }
}

/// This view owns one factory-created editor. A persona/guardian/scene change
/// immediately hides its contents and invalidates any suspended repository work.
private struct PickupPantryLotDestination: View {
    @ObservedObject var model: PickupModel
    let journeyID: UUID
    let lotID: UUID
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var guardianChild
    @State private var pantry: PantryModel?
    @State private var admittedPresentation: PickupStockReviewPresentation?

    private var presentation: PickupStockReviewPresentation {
        .current(workspaceID: model.sourceWorkspaceID, localActorID: access.localActorID,
                 workspaceUnlocked: access.unlocked, sceneActive: scenePhase == .active,
                 childPresented: guardianChild?.presented == true, household: household)
    }
    private var accessAllowed: Bool {
        admittedPresentation == presentation && presentation.scope(presentationID: UUID()) != nil
    }
    private var projectionRow: PantryLiveStockProjection.Lot? {
        (try? model.liveStockProjection(for: journeyID))?.lot(canonicalID: lotID)
    }

    var body: some View {
        Group {
            if let pantry, accessAllowed {
                PantryLotEntryView(model: pantry, lotID: lotID, accessAllowed: accessAllowed,
                                   availabilityNeedsReview: projectionRow?.issues.isEmpty != true)
            } else {
                WorkingForm {
                    if presentation.scope(presentationID: UUID()) == nil {
                        Text(pantryText("Unlock the authorized private workspace to view pantry food."))
                    } else {
                        PickupSaveStatus(model: model, onRetried: openEntry)
                        if model.hasPendingSave, model.error == nil {
                            Text(pantryText("A saved change is waiting for recovery. Retry it or review its saved status."))
                            Button(pTr("Retry save")) { Task { if await model.retrySave() { openEntry() } } }
                                .disabled(model.saving)
                        }
                        if !model.hasPendingSave, !model.saving {
                            Text(pantryText("Could not load a complete pantry. No partial availability is shown."))
                            Button(pantryText("Refresh pantry")) {
                                Task { if await model.refreshPantryStock() { openEntry() } }
                            }.frame(minHeight: 44)
                        }
                    }
                }.navigationTitle(pantryText("Pantry food"))
            }
        }
        .privacySensitive()
        .onAppear(perform: openEntry)
        .onChange(of: presentation) { _, _ in openEntry() }
        .onChange(of: model.hasPendingSave) { _, pending in if !pending && pantry == nil { openEntry() } }
        .onChange(of: model.saving) { _, saving in if !saving && pantry == nil { openEntry() } }
        .onDisappear { pantry?.accessLost(); pantry = nil; admittedPresentation = nil }
    }

    private func openEntry() {
        if pantry != nil, admittedPresentation == presentation { return }
        pantry?.accessLost(); pantry = nil; admittedPresentation = nil
        guard presentation.scope(presentationID: UUID()) != nil,
              let journey = model.journeys.first(where: { $0.id == journeyID }), journey.closedAt == nil,
              let entry = model.makePantryModel() else { return }
        admittedPresentation = presentation; pantry = entry
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
    @Environment(\.guardianChildCoordinator) private var guardianChild
    @State private var reviewSession = PickupStockReviewSession()
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
        if model.pantryIsActive, !isClosedHistory {
            // A detail screen that was already pushed when cutover completed
            // must resolve its source alias, never keep editing the copied count.
            if presentation.scope(presentationID: UUID()) != nil,
               let projection = try? model.liveStockProjection(for: journeyID),
               let row = projection.lots.first(where: {
                   $0.current.foodID == lot.foodID && $0.scopedLegacyLotIDs.contains(lot.id)
               }) {
                PickupPantryLotDestination(model: model, journeyID: journeyID, lotID: row.id)
            } else {
                WorkingForm {
                    PickupSaveStatus(model: model)
                    Text(pantryText("This food is unavailable. Return to My Pantry and refresh."))
                }.navigationTitle(pantryText("Pantry food"))
            }
        } else { legacyDetail }
    }

    private var isClosedHistory: Bool {
        model.journeys.first(where: { $0.id == journeyID })?.closedAt != nil
    }

    private var legacyDetail: some View {
        WorkingForm {
            if !model.pantryIsActive || presentation.scope(presentationID: UUID()) != nil {
                PickupSaveStatus(model: model)
                Section(lot.name) {
                    Text(pTr(lot.source == .freezer ? "Freezer" : "Pantry"))
                    Text("\(pQuantity(lot.usable)) · \(lot.confirmedAt.formatted())")
                    if !carrying, let allocation = displayedAllocation {
                        let reservations = allocation.allocations.filter { $0.lotID == lot.id }
                        ForEach(reservations, id: \.needID) { edge in
                            let source = model.journeys.first { $0.id == journeyID }
                            let name = source?.needs.first { $0.id == edge.needID }?.name ??
                                source?.stockNeeds.first { $0.id == edge.needID }?.name ??
                                source?.plannedNeeds.first { $0.id == edge.needID }?.name
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
                if !model.pantryIsActive, model.journey?.id == journeyID, model.journey?.closedAt == nil {
                    Section(pTr(carrying ? "Confirm for this shop" : "Correct the observed batch")) {
                        if carrying || lot.id == lot.foodID {
                            Picker(pTr("Reviewed matching food need"), selection: $foodID) {
                                Text(pTr("Keep unassigned until a meal is reviewed")).tag(UUID?.none)
                                ForEach(model.journey?.reviewedStockMatches ?? []) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pTr("Confirmed usable amount"))
                            TextField(pTr("Confirmed usable amount"), text: $amount)
                                .keyboardType(.numbersAndPunctuation).focused($amountFocused)
                                .accessibilityIdentifier("stockReview.amount")
                        }
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
                if let review, !model.pantryIsActive {
                    Section {
                        Text(pTr("Review dependent meals")).font(.headline).accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($previewFocused)
                        Text("\(pTr("Confirmed usable amount")): \(pQuantity(review.lot.usable))")
                        Text(review.lot.confirmedAt.formatted())
                        if review.lot.useFirst == true { Text(pTr("Use this batch first")) }
                        if review.meals.isEmpty { Text(pTr("No reviewed meal depends on this batch.")) }
                        ForEach(review.meals) { effect in
                            PickupStockMealEffectRow(effect: effect)
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
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }.navigationTitle(pTr("Batch details"))
            .onChange(of: amount) { _, _ in checked = false; cancelPreview() }
            .onChange(of: foodID) { _, _ in checked = false; cancelPreview() }
            .onChange(of: observedAt) { _, _ in checked = false; cancelPreview() }
            .onChange(of: useFirst) { _, _ in checked = false; cancelPreview() }
            .onAppear { if reviewSession.refresh(presentation) { cancelPreview() } }
            .onChange(of: presentation) { _, value in
                if reviewSession.refresh(value) { cancelPreview() }
            }
            .onChange(of: model.pantryIsActive) { _, _ in cancelPreview() }
            .onChange(of: model.journey?.revision) { _, _ in effectsConfirmed = false }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelPreview() } }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneAction(visible: amountFocused, title: tr("Done")) { amountFocused = false }
    }

    private var displayedAllocation: StockAllocationResult? {
        if let historical = model.journeys.first(where: { $0.id == journeyID }), historical.closedAt != nil {
            return try? historical.carryoverAllocation(at: model.stockReviewDate)
        }
        return model.allocation
    }
    private var presentation: PickupStockReviewPresentation {
        .current(workspaceID: model.sourceWorkspaceID, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: scenePhase == .active,
            childPresented: guardianChild?.presented == true, household: household)
    }
    private var currentScope: PickupStockReviewScope? { reviewSession.scope(for: presentation) }
    private func cancelPreview() { review = nil; effectsConfirmed = false }
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

struct PickupStockMealEffectRow: View {
    let effect: PickupStockMealEffect
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(effect.need.name).font(.headline)
            if effect.need.priority == .protected { Text(pTr("set aside first")) }
            Text("\(pTr("Required")): \(pQuantity(effect.need.amount))")
            Text("\(pTr("Before this change")): \(coverage(effect.before))")
            Text("\(pTr("After this change")): \(coverage(effect.after))")
            Text("\(pTr("Allocation change")): \(delta(effect.before?.allocated, effect.after?.allocated, unit: effect.after?.unit ?? effect.need.amount.unit))")
            Text("\(pTr("Shortfall change")): \(delta(effect.before?.shortfall, effect.after?.shortfall, unit: effect.after?.unit ?? effect.need.amount.unit))")
        }.accessibilityElement(children: .combine)
    }
    private func coverage(_ value: StockDemandCoverage?) -> String {
        let allocated = value.flatMap { value in value.allocated.map { pQuantity($0, unit: value.unit) } } ?? pTr("Unresolved")
        let short = value.flatMap { value in value.shortfall.map { pQuantity($0, unit: value.unit) } } ?? pTr("Unresolved")
        return "\(pTr("Allocated")): \(allocated) · \(pTr("Still short")): \(short)"
    }
    private func delta(_ before: Rational?, _ after: Rational?, unit: UnitOfMeasure) -> String {
        guard let before, let after, let amount = try? max(before, after).subtracting(min(before, after)) else { return pTr("Unresolved") }
        return (after == before ? "" : (after > before ? "+" : "−")) + pQuantity(amount, unit: unit)
    }
}

struct PickupStockEntryView: View {
    @ObservedObject var model: PickupModel
    let title: String
    var shopID: UUID? = nil
    var ingredientID: UUID? = nil
    @FocusState private var field: PickupNewStockSection.Field?

    var body: some View {
        WorkingForm {
            PickupSaveStatus(model: model)
            if canShowStock {
                if model.journey?.closedAt == nil {
                    PickupNewStockSection(model: model, ingredientID: ingredientID, field: $field).id(model.selectedID)
                }
                if let journey = model.journey {
                    PickupSavedStockSection(model: model, journey: journey, onlyFoodID: ingredientID)
                }
            }
        }.navigationTitle(title)
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneAction(visible: field != nil, title: tr("Done")) { field = nil }
            .onAppear { if let shopID { model.selectedID = shopID } }
    }

    private var canShowStock: Bool {
        guard let shopID, let ingredientID else { return true }
        guard let current = model.journey, current.id == shopID else { return false }
        return current.basket?.current.lines.contains(where: { $0.id == ingredientID }) == true ||
            current.plannedNeeds.contains(where: { $0.orderLineID == ingredientID })
    }
}

struct PickupNewStockSection: View {
    enum Field: Hashable { case stockName, stockAmount }
    @ObservedObject var model: PickupModel
    let ingredientID: UUID?
    let field: FocusState<Field?>.Binding
    init(model: PickupModel, ingredientID: UUID? = nil, field: FocusState<Field?>.Binding) {
        self.model = model
        self.ingredientID = ingredientID
        self.field = field
        _stockFoodID = State(initialValue: ingredientID)
    }
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
        if model.pantryIsActive {
            PickupCanonicalAddSection(model: model, ingredientID: ingredientID)
        } else { legacyForm }
    }
    private var legacyForm: some View {
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
            VStack(alignment: .leading, spacing: 6) {
                Text(pTr("Actual food or freezer batch"))
                TextField(pTr("Actual food or freezer batch"), text: $stockName).focused(field, equals: .stockName)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(pTr("Confirmed usable amount"))
                TextField(pTr("Confirmed usable amount"), text: $stockAmount)
                    .keyboardType(.numbersAndPunctuation).focused(field, equals: .stockAmount)
            }
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
            .disabled(model.saving || model.hasPendingSave)
            .onChange(of: savedDraft) { _, saved in
                if saved != nil { finishSavedStock() }
            }
            .onChange(of: [stockName, stockAmount, stockUnit.rawValue, stockSource.rawValue]) { _, _ in stockConfirmed = false }
            .onChange(of: stockFoodID) { _, _ in stockConfirmed = false }
            .onChange(of: stockObservedAt) { _, _ in stockConfirmed = false }
            .onChange(of: useFirst) { _, _ in stockConfirmed = false }
    }
    private func addStock() {
        guard !model.pantryIsActive else { return }
        do {
            guard !stockName.isEmpty, let quantity = try ComparisonModel.quantity(stockAmount, stockUnit) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let journeyID = model.journey?.id ?? newJourneyID
            let startsWorkspace = model.journey == nil
            let lot = ConfirmedStockLot(id: stockID, foodID: ingredientID ?? stockFoodID ?? stockID, name: stockName, usable: quantity,
                                        confirmedAt: stockObservedAt, source: stockSource, useFirst: useFirst)
            field.wrappedValue = nil
            Task {
                if await model.saveStockLot(lot, in: journeyID, createIfEmpty: startsWorkspace) {
                    finishSavedStock()
                }
            }
        } catch { model.error = pTr("Check the confirmed food amounts and matching units.") }
    }
    private var savedDraft: ConfirmedStockLot? {
        model.journey?.stockLots.first { $0.id == stockID }
    }
    private func finishSavedStock() {
        // A successful retry publishes the same lot without returning through addStock.
        // Another operation's retry must never clear this form's unsaved batch.
        guard savedDraft != nil else { return }
        stockID = UUID(); stockName = ""; stockAmount = ""; stockConfirmed = false
        useFirst = false; stockObservedAt = Date()
    }
}

/// A route is an explicit identity binding, not permission to read or write.
/// It is resolved after an authorized refresh and expires when that source changes.
struct PickupPantryAddContext: Equatable {
    let workspaceID: UUID
    let journeyID: UUID?
    let journeyRevision: Int64?
    let reviewedFood: PantryReviewedFood?

    @MainActor static func resolve(model: PickupModel, ingredientID: UUID?) throws -> Self {
        guard let context = try model.pantryReviewContext(), model.journey?.closedAt == nil else {
            throw PickupStockReviewError.stale
        }
        let food: PantryReviewedFood?
        if let ingredientID {
            guard let match = model.journey?.reviewedStockMatches.first(where: { $0.id == ingredientID }) else {
                throw PickupStockReviewError.stale
            }
            food = .init(id: match.id, name: match.name, inventoryWorkspaceID: context.snapshot.state.workspaceID,
                         inventoryRevision: context.snapshot.state.revision)
        } else { food = nil }
        return .init(workspaceID: context.snapshot.state.workspaceID, journeyID: model.journey?.id,
                     journeyRevision: model.journey?.revision, reviewedFood: food)
    }

    @MainActor func matches(model: PickupModel) -> Bool {
        guard model.pantryIsActive, model.sourceWorkspaceID == workspaceID,
              model.journey?.id == journeyID, model.journey?.revision == journeyRevision,
              model.journey?.closedAt == nil else { return false }
        guard let reviewedFood else { return true }
        return model.journey?.reviewedStockMatches.contains {
            $0.id == reviewedFood.id && $0.name == reviewedFood.name
        } == true
    }
}

private struct PickupCanonicalAddSection: View {
    @ObservedObject var model: PickupModel
    let ingredientID: UUID?
    @State private var selectedFoodID: UUID?
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var guardianChild
    private var presentation: PickupStockReviewPresentation {
        .current(workspaceID: model.sourceWorkspaceID, localActorID: access.localActorID,
                 workspaceUnlocked: access.unlocked, sceneActive: scenePhase == .active,
                 childPresented: guardianChild?.presented == true, household: household)
    }
    var body: some View {
        Section(pantryText("Add food")) {
            if presentation.scope(presentationID: UUID()) == nil {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else {
                if ingredientID == nil, model.pantryReadIsCurrent {
                    Picker(pTr("Reviewed matching food need"), selection: $selectedFoodID) {
                        Text(pTr("Keep unassigned until a meal is reviewed")).tag(UUID?.none)
                        ForEach(model.journey?.reviewedStockMatches ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                NavigationLink {
                    PickupPantryAddDestination(model: model, ingredientID: ingredientID ?? selectedFoodID)
                } label: { Text(pantryText("Add food")).frame(minHeight: 44) }
                Text(pTr("Only confirmed matching food enters allocation. Do not enter the same batch twice."))
            }
        }
        .privacySensitive()
    }
}

private struct PickupPantryAddDestination: View {
    @ObservedObject var model: PickupModel
    let ingredientID: UUID?
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var guardianChild
    @State private var pantry: PantryModel?
    @State private var admittedPresentation: PickupStockReviewPresentation?
    @State private var admittedContext: PickupPantryAddContext?
    @State private var generation = UUID()
    @State private var opening = false
    private var presentation: PickupStockReviewPresentation {
        .current(workspaceID: model.sourceWorkspaceID, localActorID: access.localActorID,
                 workspaceUnlocked: access.unlocked, sceneActive: scenePhase == .active,
                 childPresented: guardianChild?.presented == true, household: household)
    }
    private var accessAllowed: Bool {
        admittedPresentation == presentation && presentation.scope(presentationID: UUID()) != nil
            && admittedContext?.matches(model: model) == true
    }
    var body: some View {
        Group {
            if let pantry, accessAllowed {
                PantryAddFoodEntryView(model: pantry, accessAllowed: accessAllowed, reviewedFood: admittedContext?.reviewedFood,
                                       refreshContext: { invalidate(); await openEntry() })
            } else {
                WorkingForm {
                    if presentation.scope(presentationID: UUID()) == nil {
                        Text(pantryText("Unlock the authorized private workspace to view pantry food."))
                    } else {
                        PickupSaveStatus(model: model, onRetried: { Task { await openEntry() } })
                        if model.hasPendingSave, model.error == nil {
                            Text(pantryText("A saved change is waiting for recovery. Retry it or review its saved status."))
                            Button(pTr("Retry save")) { Task { if await model.retrySave() { await openEntry() } } }
                                .disabled(model.saving)
                        }
                        if opening || model.saving { ProgressView(pantryText("Working…")) }
                        else if !model.hasPendingSave {
                            Text(pantryText("Could not load a complete pantry. No partial availability is shown."))
                            Button(pantryText("Refresh pantry")) { Task { await openEntry() } }.frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .navigationTitle(pantryText("Add food"))
        .privacySensitive()
        .task { await openEntry() }
        .onChange(of: presentation) { _, _ in invalidate(); Task { await openEntry() } }
        .onChange(of: model.selectedID) { _, _ in invalidate() }
        .onChange(of: model.journey?.revision) { _, _ in
            if admittedContext?.matches(model: model) == false { invalidate() }
        }
        .onChange(of: model.hasPendingSave) { _, pending in
            if !pending && pantry == nil { Task { await openEntry() } }
        }
        .onDisappear { invalidate() }
    }
    private func invalidate() {
        generation = UUID(); pantry?.accessLost(); pantry = nil
        admittedPresentation = nil; admittedContext = nil; opening = false
    }
    private func openEntry() async {
        guard pantry == nil, !opening else { return }
        invalidate()
        let token = generation, initialPresentation = presentation
        guard initialPresentation.scope(presentationID: UUID()) != nil, model.pantryIsActive,
              !model.hasPendingSave, !model.saving else { return }
        opening = true
        defer { if generation == token { opening = false } }
        guard await model.refreshPantryStock(), !Task.isCancelled, generation == token,
              presentation == initialPresentation,
              let context = try? PickupPantryAddContext.resolve(model: model, ingredientID: ingredientID),
              let entry = model.makePantryModel() else { return }
        admittedPresentation = initialPresentation; admittedContext = context; pantry = entry
    }
}

// The factory reads live app facts; imported/recovered documents never supply this admission.
extension PickupStockReviewPresentation {
    @MainActor static func current(workspaceID: UUID?, localActorID: UUID, workspaceUnlocked: Bool,
                                   sceneActive: Bool, childPresented: Bool, household: HouseholdModel) -> Self {
        let projection = household.projection.map {
            PickupStockReviewProjection(householdID: $0.household.id, memberID: $0.memberId, role: $0.role,
                enrolled: $0.enrolled, shopID: $0.shopId, grantID: $0.grantId, capabilities: $0.capabilities.sorted(),
                selectionRequired: $0.selectionRequired, canSelectShop: $0.canSelectShop)
        }
        return Self(workspaceID: workspaceID, localActorID: localActorID, workspaceUnlocked: workspaceUnlocked,
            sceneActive: sceneActive, childPresented: childPresented, guardianChildOnly: household.guardianChildOnly,
            accountSubject: household.identity?.subject, householdLocked: household.locked, projection: projection)
    }
}
