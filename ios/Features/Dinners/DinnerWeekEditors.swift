import SwiftUI
import CoreDomain

struct DinnerOccurrenceView: View {
    @ObservedObject var model: DinnerFeatureModel
    let occurrenceID: UUID
    @State private var date = Date()
    @State private var scheduled = false
    @State private var showPreview = false
    private var meal: MealOccurrence? { model.shop?.mealOccurrences.first { $0.id == occurrenceID && $0.removedAt == nil } }
    var body: some View {
        Form {
            if let meal {
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
                Section(dinnerText("Move this dinner")) {
                    Toggle(dinnerText("Assign a date"), isOn: $scheduled)
                    if scheduled { DatePicker(dinnerText("Dinner date"), selection: $date, displayedComponents: .date) }
                    Text(model.shop?.basis.timeZoneIdentifier ?? "")
                    Button(dinnerText("Preview calendar change")) {
                        do {
                            guard let shop = model.shop else { return }
                            showPreview = model.prepare([.move(occurrenceID: meal.id, day: try DinnerEntry.date(date, zone: shop.basis.timeZoneIdentifier, scheduled: scheduled))])
                        } catch { model.report(error) }
                    }.disabled(!model.editable)
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
            .onAppear { if let day = meal?.scheduledDay { scheduled = true; date = day.date ?? date } }
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
struct DinnerManualAdjustmentView: View {
    @ObservedObject var model: DinnerFeatureModel
    let meal: MealOccurrence
    let baseRevision: UUID?
    @State private var servings: String
    @State private var groups: [DinnerGroupDraft]
    @State private var amounts: [DinnerIngredientDraft]
    @State private var showPreview = false
    init(model: DinnerFeatureModel, meal: MealOccurrence) {
        self.model = model; self.meal = meal; baseRevision = model.shop?.revisionID
        _servings = State(initialValue: meal.servings.description)
        _groups = State(initialValue: meal.servingGroups.map(DinnerGroupDraft.init))
        _amounts = State(initialValue: meal.ingredientContributionIDs.compactMap { id in
            model.shop?.contributions.first(where: { $0.id == id }).map {
                DinnerIngredientDraft(MealIngredient(id: $0.id, name: $0.productName, quantity: $0.quantity))
            }
        })
    }
    var body: some View {
        Form {
            Section {
                Text(dinnerText("Enter each resulting amount explicitly. This Free editor does not scale ingredients automatically."))
                TextField(dinnerText("Total servings"), text: $servings)
            }
            Section(dinnerText("Serving groups")) {
                ForEach($groups) { $group in
                    TextField(dinnerText("Group name"), text: $group.name)
                    TextField(dinnerText("Group servings"), text: $group.servings)
                    if group.isProtected { Text(dinnerText("Protected group")) }
                }
                Button(dinnerText("Add serving group")) { groups.append(DinnerGroupDraft()) }.disabled(groups.count >= 100)
            }
            Section(dinnerText("Resulting grocery amounts")) {
                ForEach($amounts) { $amount in
                    VStack(alignment: .leading) {
                        Text(amount.name).font(.headline)
                        TextField(dinnerText("Amount, optional"), text: $amount.amount)
                        DinnerUnitPicker(unit: $amount.unit)
                    }
                }
            }
            Section {
                Button(dinnerText("Review")) {
                    do {
                        let changes = try amounts.map { DinnerQuantityEdit(contributionID: $0.id, quantity: try DinnerEntry.quantity($0.amount, unit: $0.unit)) }
                        showPreview = model.prepare([.adjust(DinnerAdjustment(occurrenceID: meal.id, servings: try DinnerEntry.positive(servings),
                            groups: try groups.map { try $0.group() }, quantities: changes))], expectedRevision: baseRevision)
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
                            Text(dinnerFormat("Protected: %@ servings", group.servings))
                        } else { TextField(dinnerText("New total servings for this group"), text: $group.servings).focused($enteringServings).accessibilityIdentifier("dinnerGuestServings") }
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
    @State private var kind = DinnerWeekNote.Kind.away
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section {
                Text(dinnerDay(day))
                Picker(dinnerText("Note type"), selection: $kind) {
                    ForEach([DinnerWeekNote.Kind.away, .guests, .side, .carryoverReview], id: \.self) { Text(dinnerNoteKind($0)).tag($0) }
                }
                TextField(dinnerText("Notes"), text: $text, axis: .vertical)
                Text(dinnerText("A day note does not remove or rescale chosen dinners. Review those changes separately."))
                Button(dinnerText("Save day note")) {
                    guard let shop = model.shop else { return }
                    Task { if await model.saveNote(DinnerWeekNote(id: id, shopID: shop.id, day: day, kind: kind, text: text)) { dismiss() } }
                }.disabled(!model.editable)
            }
            Section(dinnerText("Existing notes")) {
                ForEach(model.state.weekNotes.filter { $0.shopID == model.shop?.id && $0.day == day }) { note in
                    Button { id = note.id; kind = note.kind; text = note.text } label: {
                        VStack(alignment: .leading) { Text(dinnerNoteKind(note.kind)); Text(note.text) }
                    }
                }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Day note")).dinnerAccess(model)
    }
}
struct DinnerReservationView: View {
    @ObservedObject var model: DinnerFeatureModel
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
                TextField(dinnerText("Food name"), text: $name)
                TextField(dinnerText("Protected amount"), text: $amount)
                DinnerUnitPicker(unit: $unit)
                TextField(dinnerText("Purpose, such as lunch"), text: $purpose)
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
                    do {
                        guard let shop = model.shop, let quantity = try DinnerEntry.quantity(amount, unit: unit) else { throw DomainError.invalidNumber }
                        let day = try DinnerEntry.date(date, zone: shop.basis.timeZoneIdentifier, scheduled: scheduled)
                        showPreview = model.prepare([.reserve(DinnerReservation(name: name, quantity: quantity, purpose: purpose, day: day, withinContributionID: parent))])
                    } catch { model.report(error) }
                }.disabled(!model.editable)
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Protect food")).dinnerAccess(model)
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
