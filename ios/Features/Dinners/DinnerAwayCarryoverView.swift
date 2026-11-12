import SwiftUI
import CoreDomain

/// Small shared-file hook. The actual coordinator and forms live in this file.
struct DinnerAwayCarryoverLink: View {
    @ObservedObject var model: DinnerFeatureModel
    var occurrenceID: UUID? = nil
    var day: MealDay? = nil
    @EnvironmentObject private var pickup: PickupModel
    var body: some View {
        if pickup.journeys.contains(where: { $0.id == model.shop?.id && $0.pickup != nil }) {
            NavigationLink {
                DinnerAwayCarryoverView(dinner: model, pickup: pickup, occurrenceID: occurrenceID, day: day)
            } label: { Text(pTr("Away after purchase: review physical carryover")) }
                .accessibilityIdentifier("awayCarryover.open")
        }
    }
}

struct DinnerAwayCarryoverView: View {
    @ObservedObject var dinner: DinnerFeatureModel
    @ObservedObject var pickup: PickupModel
    @StateObject private var model: DinnerAwayCarryoverModel
    let day: MealDay?
    @State private var operationID = UUID()
    @State private var mealID: UUID?
    @State private var needID: UUID?
    @State private var supplyID: UUID?
    @State private var counted = ""
    @State private var reserved = ""
    @State private var servings = ""
    @State private var observedAt = Date()
    @State private var targetDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var physicallyChecked = false
    @State private var approved = false
    @State private var completed = false
    @State private var formError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(dinner: DinnerFeatureModel, pickup: PickupModel, occurrenceID: UUID? = nil, day: MealDay? = nil) {
        self.dinner = dinner; self.pickup = pickup; self.day = day
        _model = StateObject(wrappedValue: DinnerAwayCarryoverModel(dinner: dinner, pickup: pickup))
        _mealID = State(initialValue: occurrenceID)
    }
    private var journey: PickupJourney? { pickup.journeys.first { $0.id == dinner.shop?.id } }
    private var meals: [MealOccurrence] {
        let current = (dinner.shop?.mealOccurrences ?? []).compactMap { original -> MealOccurrence? in
            guard let journey else { return original }
            return try? AwayCarryoverEngine.currentMeal(original, in: journey)
        }
        return current.filter { $0.removedAt == nil && $0.carryover == nil && $0.scheduledDay != nil && (day == nil || $0.scheduledDay == day) }
    }
    private var meal: MealOccurrence? { meals.first { $0.id == mealID } }
    private var earliestTargetDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: dinner.shop?.basis.timeZoneIdentifier ?? "") ?? .current
        let today = calendar.startOfDay(for: Date())
        guard let source = meal?.scheduledDay?.date,
              let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: source)) else { return today }
        return max(today, next)
    }
    private var needs: [AllocationNeed] {
        guard let meal, let journey else { return [] }; return AwayCarryoverEngine.sourceNeeds(meal, in: journey)
    }
    private var need: AllocationNeed? { needs.first { $0.id == needID } }
    private var supplies: [AwayCarryoverSupply] {
        guard let need, let journey else { return [] }; return AwayCarryoverEngine.supplies(for: need, in: journey)
    }
    private var supply: AwayCarryoverSupply? { supplies.first { $0.id == supplyID } }
    var body: some View {
        Form {
            PickupSaveStatus(model: pickup)
            if let ledger = dinner.store as? LedgerModel { LedgerSaveStatus(model: ledger) }
            if pickup.journey?.id != dinner.shop?.id {
                Text(pTr("Open this dinner's pickup before recounting its saved physical food."))
                Button(pTr("Open this pickup's physical food")) { pickup.selectedID = dinner.shop?.id }
                    .accessibilityIdentifier("awayCarryover.selectPickup")
            } else if let pending = model.pending {
                pendingSection(pending)
            } else if let review = model.review {
                reviewSection(review)
            } else if !completed && journey?.closedAt == nil {
                inputSections
            }
            if let message = model.message { Text(message).accessibilityIdentifier("awayCarryover.status") }
            if let formError { Text(formError).foregroundStyle(.red) }
            if completed {
                Button(pTr("Review another physical carryover")) {
                    operationID = UUID(); completed = false; counted = ""; reserved = ""; servings = ""
                    physicallyChecked = false; approved = false; supplyID = nil
                }
            }
            Section(pTr("Saved dated carryovers")) {
                ForEach(model.records.filter { $0.phase == .completed }) { record in
                    NavigationLink {
                        DinnerCarryoverDetailsView(model: dinner, occurrenceID: record.intent.plan.occurrenceID)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(record.intent.plan.source.title)
                            Text(dinnerDay(record.intent.plan.day))
                            Text(pQuantity(record.intent.plan.link.quantity))
                        }
                    }.accessibilityIdentifier("awayCarryover.saved.\(record.id.uuidString)")
                }
            }
        }
        .navigationTitle(pTr("Physical carryover"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pTr("Close")) { dismiss() } } }
        .dinnerAccess(dinner)
        .environment(\.timeZone, TimeZone(identifier: dinner.shop?.basis.timeZoneIdentifier ?? "") ?? .current)
        .onChange(of: earliestTargetDate, initial: true) { _, firstDay in
            if targetDate < firstDay { targetDate = firstDay }
        }
        .onChange(of: mealID) { _, _ in needID = nil; supplyID = nil; resetApproval() }
        .onChange(of: needID) { _, _ in supplyID = nil; resetApproval() }
        .onChange(of: supplyID) { _, _ in counted = ""; reserved = ""; resetApproval() }
        .onChange(of: [counted, reserved, servings]) { _, _ in resetApproval() }
        .onChange(of: observedAt) { _, _ in resetApproval() }
        .onChange(of: targetDate) { _, _ in resetApproval() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { approved = false; physicallyChecked = false } }
        .scrollDismissesKeyboard(.interactively)
    }
    @ViewBuilder private var inputSections: some View {
        Section(pTr("Original purchased dinner")) {
            Text(pTr("An away note does not create food. Recount one existing physical source before reserving an eligible dinner portion for a later date."))
            Picker(pTr("Dinner that will not be eaten as planned"), selection: $mealID) {
                Text(pTr("Choose a dinner")).tag(UUID?.none)
                ForEach(meals) { Text($0.title).tag(Optional($0.id)) }
            }.accessibilityIdentifier("awayCarryover.meal")
            Picker(pTr("Eligible dinner portion"), selection: $needID) {
                Text(pTr("Choose a food need")).tag(UUID?.none)
                ForEach(needs) { Text("\($0.name) · \(pQuantity($0.amount))").tag(Optional($0.id)) }
            }.accessibilityIdentifier("awayCarryover.need")
            Text(pTr("Protected lunch portions cannot be transferred here. The original meal, order, receipt, and charges stay in their history."))
        }
        if let need {
            Section(pTr("Recount an existing physical source")) {
                Picker(pTr("Saved batch or confirmed received food"), selection: $supplyID) {
                    Text(pTr("Choose the physical source")).tag(UUID?.none)
                    ForEach(supplies) { item in Text("\(item.name) · \(pQuantity(item.quantity))").tag(Optional(item.id)) }
                }.accessibilityIdentifier("awayCarryover.supply")
                if supplies.isEmpty { Text(pTr("No confirmed physical source matches this need. Record and review its actual arrival or existing pantry batch first; an expected order is not stock.")) }
                if let supply {
                    Text("\(pTr("Previous observation")): \(supply.observedAt.formatted()) · \(pQuantity(supply.quantity))")
                    Text(pTr("Current physically counted amount in this source")).font(.caption)
                    TextField(pTr("Current physically counted amount in this source"), text: $counted).accessibilityIdentifier("awayCarryover.counted")
                    Text(pTr(supply.quantity.unit.rawValue))
                    DatePicker(pTr("Physical food checked at"), selection: $observedAt, in: ...Date())
                    Text(pTr("Amount to reserve from this dinner portion")).font(.caption)
                    TextField(pTr("Amount to reserve from this dinner portion"), text: $reserved).accessibilityIdentifier("awayCarryover.reserved")
                    Text(pTr(need.amount.unit.rawValue))
                    if let detail = journey?.recoveryCurrentDetails.first(where: { $0.id == need.id }), !detail.exclusions.isEmpty {
                        Text("\(pTr("Keep these exclusions")): \(pExclusions(detail.exclusions))")
                    }
                    Toggle(pTr("I physically checked this same food, its identity, exclusions, and remaining usable amount."), isOn: $physicallyChecked)
                        .accessibilityIdentifier("awayCarryover.checked")
                }
            }
            Section(pTr("Real dated dinner target")) {
                DatePicker(pTr("Carryover dinner date"), selection: $targetDate, in: earliestTargetDate..., displayedComponents: .date)
                    .accessibilityIdentifier("awayCarryover.date")
                Text(dinner.shop?.basis.timeZoneIdentifier ?? "")
                Text(pTr("Planned servings, not verified whole-meal coverage")).font(.caption)
                TextField(pTr("Planned servings, not verified whole-meal coverage"), text: $servings)
                    .accessibilityIdentifier("awayCarryover.servings")
                Text(pTr("Only the named physical food is reserved. Other ingredients, complete meal coverage, and future purchase costs remain unverified."))
                Button(pTr("Review dated carryover")) { prepare() }
                    .accessibilityIdentifier("awayCarryover.review").frame(minHeight: 44)
                    .disabled(!physicallyChecked || supply == nil || model.busy)
            }
        }
    }
    private func reviewSection(_ intent: AwayCarryoverIntent) -> some View {
        Section(pTr("Review before saving carryover")) {
            Text(intent.plan.source.title).font(.headline)
            Text("\(pTr("Physical source")): \(intent.supply.name)")
            Text("\(pTr("Counted now")): \(pQuantity(intent.counted))")
            Text("\(pTr("Reserved for carryover")): \(pQuantity(intent.plan.link.quantity))")
            Text(dinnerDay(intent.plan.day))
            Text("\(pTr("Planned servings")): \(intent.plan.servings.description)")
            Text(pTr("The selected amount moves from the eligible original dinner need to one pinned physical-food reservation. It is not added twice. Protected lunches stay reserved on their original dates."))
            ForEach(journey?.recoveryCurrentAllocationNeeds.filter { $0.priority == .protected } ?? []) { need in Text("\(need.name) · \(pQuantity(need.amount))") }
            Toggle(pTr("I approve this physical reservation and its dated carryover target."), isOn: $approved)
                .accessibilityIdentifier("awayCarryover.approve")
            Button(pTr("Save physical reservation and dated dinner")) { Task { if await model.apply() { completed = true } } }
                .accessibilityIdentifier("awayCarryover.apply").frame(minHeight: 44).disabled(!approved || model.busy)
            Button(pTr("Cancel carryover review")) { model.cancelReview(); approved = false }
                .accessibilityIdentifier("awayCarryover.cancel").frame(minHeight: 44)
        }
    }
    private func pendingSection(_ record: AwayCarryoverRecord) -> some View {
        Section(pTr("Carryover needs reconciliation")) {
            Text(record.intent.plan.source.title)
            Text(dinnerDay(record.intent.plan.day))
            Text(pTr(record.phase == .prepared ? "The operation is saved; physical recount and calendar target are not yet complete." : "The physical reservation is saved; the calendar target still needs confirmation."))
            Text(pTr("Closing keeps this operation. Retry its original identities after resolving pending save controls; do not create another copy."))
            Button(pTr("Retry this saved carryover")) { Task { if await model.retry(record) { completed = true } } }
                .accessibilityIdentifier("awayCarryover.retry").frame(minHeight: 44).disabled(model.busy)
        }
    }
    private func resetApproval() { approved = false; physicallyChecked = false; formError = nil; model.cancelReview() }
    private func prepare() {
        do {
            guard let meal, let need, let supply, let zone = dinner.shop?.basis.timeZoneIdentifier else { throw AwayCarryoverError.invalid }
            let count = try quantity(counted, supply.quantity.unit)
            let amount = try quantity(reserved, need.amount.unit)
            let servings = try DinnerEntry.positive(servings)
            if model.prepare(id: operationID, occurrenceID: meal.id, needID: need.id, supply: supply, counted: count, reserved: amount,
                servings: servings, day: try MealDay(date: targetDate, timeZoneIdentifier: zone), observedAt: observedAt) { approved = false }
        } catch { formError = pTr("Enter exact positive amounts and a real later date. Nothing has been saved.") }
    }
    private func quantity(_ text: String, _ unit: UnitOfMeasure) throws -> Quantity {
        Quantity(amount: try DinnerEntry.positive(text), unit: unit, originalLiteral: text)
    }
}

/// Use instead of the ordinary recipe/guest editor for a typed carryover target.
struct DinnerCarryoverDetailsView: View {
    @ObservedObject var model: DinnerFeatureModel
    let occurrenceID: UUID
    @EnvironmentObject private var pickup: PickupModel
    private var meal: MealOccurrence? { model.shop?.mealOccurrences.first { $0.id == occurrenceID && $0.removedAt == nil } }
    var body: some View {
        Form {
            if let meal, let link = meal.carryover {
                Section(pTr("Confirmed-food carryover, not a new recipe")) {
                    Text(meal.title).font(.headline)
                    Text(meal.scheduledDay.map(dinnerDay) ?? pTr("Unresolved"))
                    Text("\(pTr("Reserved quantity")): \(pQuantity(link.quantity))")
                    Text("\(pTr("Physical food checked at")): \(link.observedAt.formatted())")
                    Text(pTr("Only this linked physical reservation is claimed. Whole-meal coverage and new-purchase costs are not evaluated here."))
                }
                if let journey = pickup.journeys.first(where: { $0.id == link.sourceShopID }),
                   let record = journey.awayCarryovers.first(where: { $0.id == link.operationID && $0.intent.plan.link == link }) {
                    Text(record.intent.supply.name)
                    Text("\(pTr("Original dinner")): \(record.intent.plan.source.title)")
                    if let sourceDay = record.intent.plan.source.scheduledDay { Text(dinnerDay(sourceDay)) }
                    if let demand = try? journey.carryoverAllocation(at: pickup.stockReviewDate).demands.first(where: { $0.id == link.reservationID }) {
                        Text("\(pTr("Currently allocated from confirmed food")): \(demand.allocated.map { pQuantity($0, unit: demand.unit) } ?? pTr("Unresolved"))")
                        Text("\(pTr("Still short")): \(demand.shortfall.map { pQuantity($0, unit: demand.unit) } ?? pTr("Unresolved"))")
                    } else { Text(pTr("The physical reservation needs review. Do not assume this dinner is covered.")) }
                    if record.phase != .completed { Text(pTr("The physical reservation and calendar target have not finished reconciling.")) }
                    NavigationLink(pTr("Review original physical carryover")) {
                        DinnerAwayCarryoverView(dinner: model, pickup: pickup, occurrenceID: record.intent.plan.source.id)
                    }
                } else {
                    Text(pTr("The linked physical evidence is missing on this device. This calendar entry does not establish available food."))
                }
                Text(pTr("Generic recipe, guest, and calendar edits cannot change this physical reservation. Recount and review the original carryover before changing its commitments."))
            } else { Text(pTr("This carryover target is no longer available.")) }
        }.navigationTitle(pTr("Dated physical carryover")).dinnerAccess(model)
    }
}
