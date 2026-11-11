import SwiftUI
import CoreDomain

struct DinnerOccurrenceView: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var ledger: LedgerModel
    let occurrenceID: UUID
    @State private var date = Date()
    @State private var scheduled = false
    @State private var showPreview = false
    @State private var calendarZone = TimeZone.current.identifier
    @State private var calendarRevision: UUID?
    @State private var planningRevision: UUID?
    private var meal: MealOccurrence? { model.shop?.mealOccurrences.first { $0.id == occurrenceID && $0.removedAt == nil } }
    var body: some View {
        Group {
            switch currentRoute {
            case .success(.recovered(let shopID, let currentID)):
                PickupMealRecoveryEntry(model: pickup, ledger: ledger, pickupID: shopID, occurrenceID: currentID, carryoverPlanner: model)
            case .success(.original(let current)):
                if current.carryover != nil {
                    DinnerCarryoverDetailsView(model: model, occurrenceID: occurrenceID)
                } else { occurrenceForm }
            case .failure:
                ContentUnavailableView(currentDinnerText("Current dinner unavailable"), systemImage: "arrow.triangle.2.circlepath",
                    description: Text(currentDinnerText("Current dinners could not be verified. Reopen the same pickup and review its saved changes.")))
                    .accessibilityIdentifier("dinner.currentMealsUnavailable")
            }
        }
    }
    private var currentRoute: Result<DinnerMealDestination, Error> {
        Result { try model.currentMealDestination(occurrenceID, pickup: pickup) }
    }
    private var occurrenceForm: some View {
        WorkingForm {
            if let meal {
                let proposedDay = try? DinnerEntry.date(date, zone: calendarZone, scheduled: scheduled)
                Section {
                    Text(meal.title).font(.title2.bold())
                    Text(dinnerFormat("Servings: %@", meal.servings.description))
                    Text(meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled"))
                    if !meal.notes.isEmpty { Text(meal.notes) }
                    if let evidence = meal.sourceEvidence {
                        if let templateID = meal.templateID {
                            NavigationLink(captureText("Original recipe source")) { RecipeSourceReview(model: model, templateID: templateID, evidence: evidence) }
                        } else { RecipeSourceDisclosure(evidence: evidence) }
                    }
                }
                Section { DinnerAwayCarryoverLink(model: model, occurrenceID: meal.id) }
                Section(dinnerText("Move this dinner")) {
                    Toggle(dinnerText("Assign a date"), isOn: $scheduled)
                    if scheduled {
                        DatePicker(dinnerText("Dinner date"), selection: $date, displayedComponents: .date)
                            .environment(\.timeZone, TimeZone(identifier: calendarZone) ?? .current)
                            .accessibilityIdentifier("dinnerMoveDate")
                    }
                    Text(calendarZone)
                    Button(dinnerText("Preview calendar change")) {
                        do {
                            guard let shop = model.shop else { return }
                            guard calendarRevision == shop.revisionID, planningRevision == model.state.revisionID else {
                                resetCalendarDraft()
                                throw DinnerPlanningError.stalePreview
                            }
                            let day = try DinnerEntry.date(date, zone: calendarZone, scheduled: scheduled)
                            guard day != meal.scheduledDay else { return }
                            showPreview = model.prepare([.move(occurrenceID: meal.id, day: day)], expectedRevision: calendarRevision)
                        } catch { model.report(error) }
                    }.disabled(!model.editable || calendarRevision == nil || proposedDay == meal.scheduledDay)
                        .accessibilityIdentifier("dinnerMoveReview")
                }
                Section(dinnerText("Portions and needs")) {
                    NavigationLink(dinnerText("Edit quantities manually")) { DinnerManualAdjustmentView(model: model, meal: meal) }
                    DinnerDecisionButton(model: model, title: dinnerText("Review ingredient portions and guests"), identifier: "dinnerGuests") { DinnerGuestsView(model: model, meal: meal) }
                    ForEach(meal.ingredientContributionIDs, id: \.self) { id in
                        if let source = model.shop?.contributions.first(where: { $0.id == id && $0.removedAt == nil }) {
                            VStack(alignment: .leading) { Text(source.productName); Text(dinnerQuantity(source.quantity)) }
                                .accessibilityElement(children: .combine)
                        }
                    }
                }
                Section {
                    Text(dinnerText("Removing this chosen dinner preserves independent manual items and protected lunch reservations."))
                    Button(dinnerText("Preview removing this dinner"), role: .destructive) { showPreview = model.prepare([.remove(occurrenceID: meal.id)]) }
                        .disabled(!model.editable)
                }
            } else { Text(dinnerText("This chosen dinner is no longer available.")) }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Chosen dinner")).dinnerAccess(model)
            .onAppear(perform: resetCalendarDraft)
            .onChange(of: showPreview) { _, presented in
                if !presented, calendarRevision != model.shop?.revisionID { resetCalendarDraft() }
            }
            .dinnerApplyPresentation(model, presented: $showPreview)
    }

    private func resetCalendarDraft() {
        let day = meal?.scheduledDay
        scheduled = day != nil
        date = day?.date ?? Date()
        calendarZone = day?.timeZoneIdentifier ?? model.shop?.basis.timeZoneIdentifier ?? TimeZone.current.identifier
        calendarRevision = model.shop?.revisionID
        planningRevision = model.state.revisionID
    }
}
struct DinnerManualAdjustmentView: View {
    @ObservedObject var model: DinnerFeatureModel
    let meal: MealOccurrence
    let baseRevision: UUID?
    @State private var servings: String
    @State private var groups: [DinnerGroupDraft]
    @State private var amounts: [DinnerIngredientDraft]
    @State private var bindings: [DinnerBindingDraft]
    @State private var showPreview = false
    private var reviewsAllocations: Bool { meal.servingGroups.contains(where: \.isProtected) }
    init(model: DinnerFeatureModel, meal: MealOccurrence) {
        self.model = model; self.meal = meal; baseRevision = model.shop?.revisionID
        _servings = State(initialValue: meal.servings.description)
        _groups = State(initialValue: meal.servingGroups.map(DinnerGroupDraft.init))
        _amounts = State(initialValue: meal.ingredientContributionIDs.compactMap { id in
            model.shop?.contributions.first(where: { $0.id == id }).map {
                DinnerIngredientDraft(MealIngredient(id: $0.id, name: $0.productName, quantity: $0.quantity))
            }
        })
        let baseline = model.shop.flatMap { try? DinnerPlanningEngine.manualPortionBindings(occurrenceID: meal.id, ledger: $0, state: model.state) } ?? []
        _bindings = State(initialValue: meal.ingredientContributionIDs.compactMap { id in
            model.shop?.contributions.first { $0.id == id && $0.removedAt == nil }
        }.flatMap { source in meal.servingGroups.map { group in
            DinnerBindingDraft(contribution: source, group: group,
                existing: baseline.first { $0.contributionID == source.id && $0.groupID == group.id })
        } })
    }
    var body: some View {
        WorkingForm {
            Section {
                Text(dinnerText("Enter each resulting amount explicitly. This Free editor does not scale ingredients automatically."))
                VStack(alignment: .leading, spacing: 5) {
                    Text(dinnerText("Total servings")).font(.caption).foregroundStyle(Theme.secondary)
                    TextField(dinnerText("Total servings"), text: $servings)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 44)
                }
            }
            Section(dinnerText("Serving groups")) {
                ForEach($groups) { $group in
                    if group.isProtected {
                        Text(group.name)
                        Text(dinnerFormat("Protected servings: %@", group.servings))
                    } else {
                        TextField(dinnerText("Group name"), text: $group.name)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(dinnerText("Group servings")).font(.caption).foregroundStyle(Theme.secondary)
                            TextField(dinnerText("Group servings"), text: $group.servings)
                                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .frame(minHeight: 44)
                        }
                    }
                }
                Button(dinnerText("Add serving group")) {
                    let group = DinnerGroupDraft(); groups.append(group)
                    if reviewsAllocations {
                        for id in meal.ingredientContributionIDs {
                            if let source = model.shop?.contributions.first(where: { $0.id == id }) {
                                bindings.append(DinnerBindingDraft(contribution: source,
                                    group: ServingGroup(id: group.id, name: "", servings: .one), existing: nil))
                            }
                        }
                    }
                }.disabled(groups.count >= 100)
            }
            Section(dinnerText("Resulting grocery amounts")) {
                ForEach($amounts) { $amount in
                    VStack(alignment: .leading) {
                        Text(amount.name).font(.headline)
                        Text(dinnerText("Amount, optional")).font(.caption).foregroundStyle(Theme.secondary)
                        TextField(dinnerText("Amount, optional"), text: $amount.amount)
                            .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .frame(minHeight: 44)
                        DinnerUnitPicker(unit: $amount.unit)
                    }
                }
            }
            if reviewsAllocations {
                Section(dinnerText("Resulting ingredient portions")) {
                    Text(dinnerText("Keep protected food as saved. Enter the resulting amount for every other group, including zero. Together they must equal each new ingredient total."))
                    ForEach(bindings) { snapshot in
                        let row = dinnerDraftBinding(snapshot, in: $bindings)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(snapshot.product).font(.headline)
                            Text(groups.first { $0.id == snapshot.groupID }?.name ?? snapshot.group.name)
                            if snapshot.group.isProtected {
                                Text(dinnerText("Protected group"))
                                Text(dinnerQuantity(snapshot.protectedQuantity))
                            } else {
                                Text(dinnerText("Resulting amount for this group")).font(.caption).foregroundStyle(Theme.secondary)
                                TextField(dinnerText("Resulting amount for this group"), text: row.amount)
                                    .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("dinnerManualBinding.\(snapshot.contributionID).\(snapshot.groupID)")
                                DinnerUnitPicker(unit: row.unit)
                            }
                        }
                    }
                    if bindings.contains(where: { $0.group.isProtected && $0.protectedQuantity == nil }) {
                        Text(dinnerText("The current protected amount is unresolved. Review the current ingredient quantities before changing this dinner."))
                    }
                }
            }
            Section {
                Button(dinnerText("Review")) {
                    do {
                        let changes = try amounts.map { DinnerQuantityEdit(contributionID: $0.id, quantity: try $0.reviewedQuantity()) }
                        let reviewedGroups = try groups.map { try $0.group() }
                        let reviewedBindings = reviewsAllocations ? try bindings.map { row in
                            guard let group = reviewedGroups.first(where: { $0.id == row.groupID }) else { throw DinnerPlanningError.reviewRequired("portionBinding") }
                            return try row.binding(occurrenceID: meal.id, servings: group.servings)
                        } : nil
                        showPreview = model.prepare([.adjust(DinnerAdjustment(occurrenceID: meal.id, servings: try DinnerEntry.positive(servings),
                            groups: reviewedGroups, quantities: changes, portionBindings: reviewedBindings))], expectedRevision: baseRevision)
                    } catch { model.report(error) }
                }.disabled(!model.editable)
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Manual quantities")).dinnerAccess(model)
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
struct DinnerGuestsView: View {
    @ObservedObject var model: DinnerFeatureModel
    let meal: MealOccurrence
    @State private var baseRevision: UUID?
    @State private var planningRevision: UUID
    @State private var bindings: [DinnerBindingDraft]
    @State private var groups: [DinnerGroupDraft]
    @State private var showPreview = false
    @Environment(\.closeDinnerDecision) private var closeDecision
    @State private var showCapturedPreview = false
    private struct GuestReview: Identifiable, Hashable {
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.shopID == rhs.shopID && lhs.actorID == rhs.actorID }
        func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(shopID); hasher.combine(actorID) }
        let id: UUID
        let shopID: UUID
        let planningRevision: UUID
        let scope: DinnerAccessContext.Scope
        let actorID: String
        let choice: CaptureGuestMealChoice
    }
    @State private var guestReview: GuestReview?
    private func authorized(_ review: GuestReview) -> Bool {
        guard model.editable, model.accessAvailable, model.shop?.id == review.shopID,
              model.shop?.revisionID == review.id, model.state.revisionID == review.planningRevision, let access = model.accessProvider(review.shopID) else { return false }
        return access.scope == review.scope && access.actorID == review.actorID
    }

    init(model: DinnerFeatureModel, meal: MealOccurrence) {
        self.model = model; self.meal = meal
        _baseRevision = State(initialValue: model.shop?.revisionID)
        _planningRevision = State(initialValue: model.state.revisionID)
        _groups = State(initialValue: meal.servingGroups.map(DinnerGroupDraft.init))
        let sources = meal.ingredientContributionIDs.compactMap { id in model.shop?.contributions.first { $0.id == id && $0.removedAt == nil } }
        _bindings = State(initialValue: sources.flatMap { source in meal.servingGroups.map { group in
            DinnerBindingDraft(contribution: source, group: group,
                existing: model.state.portionBindings.first { $0.occurrenceID == meal.id && $0.contributionID == source.id && $0.groupID == group.id })
        } })
    }
    @FocusState private var enteringServings: Bool
    @State private var keyboardVisible = false
    @State private var reviewAfterTyping = false
    private func reviewGuestTotals() {
        if enteringServings && keyboardVisible {
            reviewAfterTyping = true
            enteringServings = false
        } else { prepareGuestTotals() }
    }
    private func prepareGuestTotals() {
        do {
            guard model.shop?.revisionID == baseRevision, model.state.revisionID == planningRevision else { throw DinnerPlanningError.stalePreview }
            let values = try Dictionary(uniqueKeysWithValues: groups.map { ($0.id, try DinnerEntry.positive($0.servings)) })
            showPreview = model.previewGuests(occurrenceID: meal.id, servings: values, isolated: !model.paid)
        } catch { model.report(error) }
    }
    var body: some View {
        Form {
            if groups.isEmpty {
                Section { Text(dinnerText("This dinner has no named serving groups. Use manual quantity editing or choose a dinner with reviewed groups.")) }
            } else {
                Section(dinnerText("Review the current ingredient portions")) {
                    Text(dinnerText("For every ingredient, enter the current amount assigned to each group. These amounts must total the current ingredient need. Enter zero explicitly when a group uses none."))
                    ForEach($bindings) { $binding in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(binding.product).font(.headline)
                            Text(dinnerFormat("%@ · %@ servings", binding.group.name, binding.group.servings.description))
                            TextField(dinnerText("Current amount for this group"), text: $binding.amount)
                                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                            DinnerUnitPicker(unit: $binding.unit)
                            if binding.group.isProtected { Text(dinnerText("Protected group")) }
                        }.padding(.vertical, 5)
                    }
                    Button(dinnerText("Save reviewed ingredient bindings")) {
                        Task {
                            do {
                                guard model.shop?.revisionID == baseRevision, model.state.revisionID == planningRevision else { throw DinnerPlanningError.stalePreview }
                                if await model.saveBindings(try bindings.map { try $0.binding(occurrenceID: meal.id) }, occurrenceID: meal.id) {
                                    planningRevision = model.state.revisionID
                                }
                            }
                            catch { model.report(error) }
                        }
                    }.disabled(!model.editable)
                }
                Section(dinnerText("New serving totals")) {
                    Button(captureText("Review guest change")) {
                        guard let shop = model.shop, let access = model.accessProvider(shop.id),
                              let saved = shop.mealOccurrences.first(where: { $0.id == meal.id && $0.removedAt == nil }) else { return }
                        let choice = CaptureGuestMealChoice(id: saved.id, title: saved.title,
                            groups: saved.servingGroups.map { .init(id: $0.id, name: $0.name, currentServings: $0.servings, isProtected: $0.isProtected) })
                        guestReview = GuestReview(id: shop.revisionID, shopID: shop.id, planningRevision: model.state.revisionID, scope: access.scope, actorID: access.actorID, choice: choice)
                    }.disabled(!model.editable || !model.accessAvailable || groups.allSatisfy(\.isProtected))
                    ForEach($groups) { $group in
                        Text(group.name).font(.headline)
                        if group.isProtected {
                            Text(dinnerFormat("Protected servings: %@", group.servings))
                        } else { TextField(dinnerText("New total servings for this group"), text: $group.servings).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled().focused($enteringServings).accessibilityIdentifier("dinnerGuestServings") }
                    }
                    Text(dinnerText("The assisted preview uses saved ingredient bindings. Protected groups remain unchanged."))
                    Button(model.paid ? dinnerText("Preview guest changes") : dinnerText("Explore guest changes without applying")) {
                        reviewGuestTotals()
                    }.disabled(!model.editable)
                }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Guests and protected portions")).dinnerAccess(model)
            .scrollDismissesKeyboard(.immediately)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                keyboardVisible = false
                if reviewAfterTyping { reviewAfterTyping = false; prepareGuestTotals() }
            }
             .toolbar {
                if groups.contains(where: { !$0.isProtected }) {
                    ToolbarItem(placement: .primaryAction) {
                        Button(dinnerText("Review"), action: reviewGuestTotals)
                            .disabled(!model.editable).accessibilityIdentifier("dinnerGuestPreview")
                    }
                }
            }
            .navigationDestination(item: $guestReview) { review in
                    GuestCaptureReviewView(meals: [review.choice], dismissAfterPreview: false, cancelDecision: closeDecision, authorize: { authorized(review) }) { result in
                        guard authorized(review) else { return }
                        showCapturedPreview = model.previewGuestTotal(occurrenceID: result.occurrenceID, groupID: result.groupID,
                            total: result.total, reviewedRevision: review.id)
                    }.dinnerApplyPresentation(model, presented: $showCapturedPreview)
            }
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
struct DinnerNoteView: View {
    @ObservedObject var model: DinnerFeatureModel
    let day: MealDay
    @State private var id = UUID()
    @State private var existingDay: MealDay?
    @State private var kind = DinnerWeekNote.Kind.away
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    private var editingDay: MealDay { existingDay ?? day }
    var body: some View {
        Form {
            Section {
                Text(dinnerDay(editingDay))
                Picker(dinnerText("Note type"), selection: $kind) {
                    ForEach([DinnerWeekNote.Kind.away, .guests, .side, .carryoverReview], id: \.self) { Text(dinnerNoteKind($0)).tag($0) }
                }
                TextField(dinnerText("Notes"), text: $text, axis: .vertical)
                Text(dinnerText("A day note does not remove or rescale chosen dinners. Review those changes separately."))
                Button(dinnerText("Save day note")) {
                    guard let shop = model.shop else { return }
                    Task { if await model.saveNote(DinnerWeekNote(id: id, shopID: shop.id, day: editingDay, kind: kind, text: text)) { dismiss() } }
                }.disabled(!model.editable)
            }
            if kind == .away || kind == .carryoverReview {
                Section { DinnerAwayCarryoverLink(model: model, day: editingDay) }
            }
            Section(dinnerText("Existing notes")) {
                ForEach(model.state.weekNotes.filter { $0.shopID == model.shop?.id && $0.day.hasSameCivilDate(as: day) }) { note in
                    Button { id = note.id; existingDay = note.day; kind = note.kind; text = note.text } label: {
                        VStack(alignment: .leading) { Text(dinnerNoteKind(note.kind)); Text(note.text) }
                    }
                }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Day note")).dinnerAccess(model)
    }
}
struct DinnerReservationView: View {
    private enum Field: Hashable { case food, amount, purpose }
    @ObservedObject var model: DinnerFeatureModel
    @FocusState private var field: Field?
    @State private var name = ""
    @State private var amount = ""
    @State private var unit = UnitOfMeasure.count
    @State private var purpose = ""
    @State private var scheduled = false
    @State private var date = Date()
    @State private var parent: UUID?
    @State private var showPreview = false
    var body: some View {
        Form {
            Section {
                TextField(dinnerText("Food name"), text: $name).focused($field, equals: .food)
                TextField(dinnerText("Protected amount"), text: $amount).focused($field, equals: .amount)
                    .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                DinnerUnitPicker(unit: $unit)
                TextField(dinnerText("Purpose, such as lunch"), text: $purpose).focused($field, equals: .purpose)
                Toggle(dinnerText("Assign a date"), isOn: $scheduled)
                if scheduled { DatePicker(dinnerText("Needed date"), selection: $date, displayedComponents: .date) }
            }
            Section(dinnerText("Use existing quantity")) {
                Picker(dinnerText("Existing source"), selection: $parent) {
                    Text(dinnerText("Add a separate grocery need")).tag(UUID?.none)
                    ForEach((model.shop?.contributions ?? []).filter { $0.removedAt == nil && $0.source.canSupplyExistingQuantity }) { source in
                        Text(dinnerFormat("%@ · %@", source.productName, dinnerQuantity(source.quantity))).tag(Optional(source.id))
                    }
                }
                Text(dinnerText("Link only when this is the same food and the existing amount covers it. A linked reservation does not add the same quantity twice."))
            }
            Section {
                Button(dinnerText("Review protected need")) {
                    field = nil
                    do {
                        guard let shop = model.shop, let quantity = try DinnerEntry.quantity(amount, unit: unit) else { throw DomainError.invalidNumber }
                        let day = try DinnerEntry.date(date, zone: shop.basis.timeZoneIdentifier, scheduled: scheduled)
                        showPreview = model.prepare([.reserve(DinnerReservation(name: name, quantity: quantity, purpose: purpose, day: day, withinContributionID: parent))])
                    } catch { model.report(error) }
                }.disabled(!model.editable)
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Protect food")).dinnerAccess(model)
            .keyboardDoneAction(visible: field != nil, title: dinnerText("Done"), identifier: "dinnerReservationKeyboardDone") { field = nil }
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
