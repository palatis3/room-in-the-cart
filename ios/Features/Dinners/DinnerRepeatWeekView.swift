import SwiftUI
import CoreDomain

struct DinnerRepeatWeekView: View {
    @ObservedObject var model: DinnerFeatureModel
    let initialDate: Date
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.closeDinnerDecision) private var close
    @Environment(\.advanceToDinnerApply) private var advance
    @State private var start: Date?
    @State private var review: DinnerRepeatReview?
    @State private var choices: [DinnerRepeatChoice] = []
    private struct Amount {
        var text: String
        var unit: UnitOfMeasure
        init(_ previous: Quantity? = nil) {
            text = previous?.amount.description ?? ""
            unit = previous?.unit ?? .count
        }
        func quantity(preserving previous: Quantity? = nil) throws -> Quantity? {
            try DinnerEntry.quantity(text, unit: unit, preserving: previous)
        }
    }
    @State private var selected: Set<RepeatWeek.Source> = []
    @State private var portions: [RepeatWeek.Source: String] = [:]
    @State private var ingredientAmounts: [RepeatWeek.Source: [UUID: Amount]] = [:]
    @State private var confirmedAmounts: Set<RepeatWeek.Source> = []
    @State private var stapleAmounts: [StapleSource: Amount] = [:]
    @State private var staples: [StapleSource: StapleChoice] = [:]
    @State private var owner: DinnerFeatureModel.EditorIdentity?

    private var zone: TimeZone {
        model.shop.flatMap { TimeZone(identifier: $0.basis.timeZoneIdentifier) } ?? .current
    }

    var body: some View {
        WorkingForm {
            if let start, owner == model.editorIdentity, model.accessAvailable {
                Section {
                    DatePicker(dinnerText("Week starting"), selection: Binding(get: { start }, set: load),
                               displayedComponents: .date)
                        .accessibilityIdentifier("repeatWeek.start")
                    HStack {
                        Button(dinnerText("Previous week")) { moveWeek(-1, from: start) }
                            .accessibilityIdentifier("repeatWeek.earlier")
                        Spacer()
                        Button(dinnerText("Next week")) { moveWeek(1, from: start) }
                            .accessibilityIdentifier("repeatWeek.next")
                    }.buttonStyle(.borderless)
                    if let range = previousWeek(before: start) {
                        LabeledContent(dinnerText("Previous week"), value: range)
                    }
                }
                if let review, model.canReadRepeatSources(review.sourceShopIDs, identity: review.identity) {
                    meals
                    calendarNotes(review)
                    if !selected.isEmpty { shoppingEstimate(review) }
                    if model.paid {
                        if !review.staples.isEmpty { stapleSection(review) }
                        if !review.evidence.stapleChecks.isEmpty { stapleHistory(review) }
                    } else {
                        Section(dinnerText("Staples for this pickup")) {
                            Text(ledgerText("Assisted staple recall requires an active adult planning seat. You can still review open deferrals and enter items manually."))
                        }
                    }
                    if !review.stock.isEmpty { stockSection(review) }
                    if model.budgetVisible, !review.priceChecks.isEmpty {
                        Section(dinnerText("Prices to review")) {
                            ForEach(Array(review.priceChecks.enumerated()), id: \.offset) { _, price in
                                Text(price)
                            }
                        }
                    }
                    Button(dinnerText("Preview repeated week")) { prepare(review) }
                        .accessibilityIdentifier("repeatWeek.preview")
                        .disabled(!model.editable || (selected.isEmpty && staples.values.allSatisfy { $0 == .skip }))
                }
                Button(dinnerText("Reload week and current evidence")) { load(start) }
                    .accessibilityIdentifier("repeatWeek.reload")
                DinnerFeedback(model: model)
            } else {
                Text(dinnerText("Planning access changed or expired. Reconnect and review again."))
            }
        }
        .navigationTitle(dinnerText("Repeat last week"))
        .environment(\.timeZone, zone)
        .dinnerAccess(model)
        .onAppear {
            guard start == nil else { return }
            owner = model.editorIdentity
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = .current
            calendar.timeZone = zone
            load(calendar.dateInterval(of: .weekOfYear, for: initialDate)?.start ?? initialDate)
        }
        .onChange(of: model.editorIdentity) { _, current in
            if owner != current { review = nil; close?() }
        }
    }

    private var meals: some View {
        Section {
            if choices.isEmpty { Text(dinnerText("No scheduled dinners were found in the previous week.")) }
            ForEach($choices) { $meal in
                let id = meal.id
                Toggle(isOn: Binding(get: { selected.contains(id) }, set: { include in
                    if include { selected.insert(id) } else { selected.remove(id) }
                })) {
                    VStack(alignment: .leading) {
                        Text(meal.title)
                        Text(meal.candidate.shopTitle).font(.caption)
                        Text(dinnerDay(meal.day)).font(.subheadline)
                    }
                }.accessibilityIdentifier("repeatWeek.meal." + id.shopID.uuidString + "." + id.occurrenceID.uuidString)
                if selected.contains(id) {
                    DisclosureGroup(dinnerText("Change date or servings")) {
                        LabeledContent(dinnerText("Previous date"), value: dinnerDay(meal.sourceDay))
                        if let date = meal.day.date, let bounds = weekBounds {
                            DatePicker(dinnerText("Dinner date"), selection: Binding(get: { date }, set: { newValue in
                                if let day = try? MealDay(date: newValue, timeZoneIdentifier: zone.identifier) { meal.day = day }
                            }), in: bounds, displayedComponents: .date)
                        }
                        LabeledContent(dinnerText("Servings")) {
                            TextField(dinnerText("Servings"), text: Binding(get: { portions[id] ?? amountText(meal.servings) },
                                                                        set: { portions[id] = $0; confirmedAmounts.remove(id) }))
                                .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                                .accessibilityIdentifier("repeatWeek.servings." + id.shopID.uuidString + "." + id.occurrenceID.uuidString)
                        }
                        if needsIngredientReview(meal) {
                            Text(dinnerText("Keep the protected servings and review each ingredient amount."))
                            ForEach(meal.candidate.template.ingredients) { ingredient in
                                let amount = Binding<Amount>(
                                    get: { ingredientAmounts[id]?[ingredient.id] ?? Amount(ingredient.quantity) },
                                    set: {
                                        ingredientAmounts[id, default: [:]][ingredient.id] = $0
                                        confirmedAmounts.remove(id)
                                    })
                                Text(ingredient.name).font(.headline)
                                LedgerQuantityFields(amount: amount.text, unit: amount.unit)
                            }
                            Toggle(dinnerText("I reviewed these ingredient amounts"), isOn: Binding(
                                get: { confirmedAmounts.contains(id) },
                                set: { checked in
                                    if checked { confirmedAmounts.insert(id) } else { confirmedAmounts.remove(id) }
                                }))
                        }
                    }
                }
            }
        } header: { Text(dinnerText("Dinners to repeat")) }
    }

    @ViewBuilder private func calendarNotes(_ review: DinnerRepeatReview) -> some View {
        if !review.evidence.priorNotes.isEmpty {
            noteSection(dinnerText("Previous week’s calendar notes"), notes: review.evidence.priorNotes)
        }
        if !review.notes.isEmpty {
            noteSection(dinnerText("This week’s calendar changes"), notes: review.notes)
        }
        if !review.evidence.protectedLunches.isEmpty {
            Section(dinnerText("Protected lunches")) {
                ForEach(review.evidence.protectedLunches) { lunch in
                    VStack(alignment: .leading) {
                        Text(lunch.name).font(.headline)
                        Text(lunch.isPriorWeek ? dinnerText("Previous week") : dinnerText("This week"))
                        if let day = lunch.day { Text(dinnerDay(day)) }
                        Text(dinnerQuantity(lunch.quantity))
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func noteSection(_ title: String, notes: [DinnerWeekNote]) -> some View {
        Section(title) {
            ForEach(notes) { note in
                VStack(alignment: .leading) {
                    Text(dinnerDay(note.day) + " · " + dinnerNoteKind(note.kind)).font(.headline)
                    Text(note.text)
                }.accessibilityElement(children: .combine)
            }
        }
    }

    private func stapleHistory(_ review: DinnerRepeatReview) -> some View {
        Section(dinnerText("Staple history")) {
            ForEach(review.evidence.stapleChecks) { check in
                VStack(alignment: .leading) {
                    Text(check.name).font(.headline)
                    switch check.status {
                    case .reviewNeeded: Text(dinnerText("Choose whether this pickup needs it."))
                    case .needed: Text(dinnerText("Needed"))
                    case .alreadyHandled: Text(dinnerText("Already handled"))
                    case .skipped: Text(dinnerText("Skipped"))
                    case .stale: Text(dinnerText("The earlier decision needs review."))
                    }
                    if let who = check.handledBy { Text(dinnerFormat("Handled on this pickup by %@", who)) }
                    if let who = check.priorHandledBy { Text(dinnerFormat("Handled previously by %@", who)) }
                }.accessibilityElement(children: .combine)
            }
        }
    }

    private func stapleSection(_ review: DinnerRepeatReview) -> some View {
        Section(dinnerText("Staples for this pickup")) {
            ForEach(review.staples) { staple in
                Picker(selection: Binding(get: { staples[staple.id] ?? .skip }, set: { value in
                    if value == .skip { staples.removeValue(forKey: staple.id) }
                    else { staples[staple.id] = value }
                })) {
                    Text(dinnerText("Skip")).tag(StapleChoice.skip)
                    Text(dinnerText("Needed")).tag(StapleChoice.needed)
                    Text(dinnerText("Already handled")).tag(StapleChoice.alreadyHandled)
                } label: {
                    VStack(alignment: .leading) {
                        Text(staple.line.name)
                        Text(staple.approval.purpose).font(.caption)
                    }
                }.accessibilityIdentifier("repeatWeek.staple." + staple.source.lineID.uuidString)
                if staples[staple.id] == .needed {
                    let amount = Binding<Amount>(get: { stapleAmounts[staple.id] ?? Amount() },
                                                 set: { stapleAmounts[staple.id] = $0 })
                    LedgerQuantityFields(amount: amount.text, unit: amount.unit)
                }
            }
        }
    }

    private func shoppingEstimate(_ review: DinnerRepeatReview) -> some View {
        let result = Result {
            try review.evidence.shoppingNeeds(for: editedMeals().map(\.selection), candidates: review.meals.map(\.candidate))
        }
        return Section {
            switch result {
            case .success(let rows):
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.headline)
                        if !row.needed.isEmpty {
                            LabeledContent(dinnerText("Selected dinners need"), value: row.needed.map { dinnerQuantity($0) }.joined(separator: ", "))
                        }
                        if !row.free.isEmpty {
                            LabeledContent(dinnerText("Available in the pantry"), value: row.free.map { dinnerQuantity($0) }.joined(separator: ", "))
                        }
                        if !row.toObtain.isEmpty {
                            LabeledContent(dinnerText("Still to obtain"), value: row.toObtain.map { dinnerQuantity($0) }.joined(separator: ", "))
                        } else if !row.unresolved {
                            Text(dinnerText("Current available stock covers the selected dinners."))
                        }
                        if row.unresolved { Text(dinnerText("The remaining amount needs review.")) }
                    }.accessibilityElement(children: .combine)
                }
            case .failure:
                Text(dinnerText("Review the selected servings and ingredient amounts to update the estimate."))
            }
        } header: { Text(dinnerText("Shopping estimate")) }
          footer: { Text(dinnerText("Meals keep their full ingredient amounts. This estimate uses available pantry quantities.")) }
    }

    private func stockSection(_ review: DinnerRepeatReview) -> some View {
        Section(dinnerText("Current pantry stock")) {
            ForEach(review.stock) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.headline)
                    if row.unresolved { Text(dinnerText("Available quantity needs review.")) }
                    ForEach(Array(row.free.enumerated()), id: \.offset) { _, quantity in
                        LabeledContent(dinnerText("Available"), value: dinnerQuantity(quantity))
                    }
                    ForEach(row.reserved) { claim in
                        LabeledContent(claim.protected ? dinnerFormat("Protected for %@", claim.name) : dinnerFormat("Reserved for %@", claim.name),
                                       value: dinnerQuantity(claim.quantity))
                    }
                }
            }
        }
    }

    private var weekBounds: ClosedRange<Date>? {
        guard let start else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let first = calendar.startOfDay(for: start)
        guard let next = calendar.date(byAdding: .day, value: 7, to: first) else { return nil }
        return first...next.addingTimeInterval(-1)
    }

    private func moveWeek(_ direction: Int, from start: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if let date = calendar.date(byAdding: .weekOfYear, value: direction, to: start) { load(date) }
    }

    private func previousWeek(before start: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let first = calendar.date(byAdding: .day, value: -7, to: start),
              let last = calendar.date(byAdding: .day, value: -1, to: start) else { return nil }
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: first, to: last)
    }

    private func load(_ date: Date) {
        start = date
        review = nil; choices = []; selected = []; portions = [:]; staples = [:]
        ingredientAmounts = [:]; confirmedAmounts = []; stapleAmounts = [:]
        guard model.editorIdentity == owner, model.accessAvailable else { return }
        do {
            let day = try MealDay(date: date, timeZoneIdentifier: zone.identifier)
            let loaded = try model.repeatWeekReview(start: day, pickup: pickup)
            review = loaded; choices = loaded.meals; selected = Set(loaded.meals.map(\.id))
        } catch { model.report(error) }
    }

    private func needsIngredientReview(_ meal: DinnerRepeatChoice) -> Bool {
        guard let entered = portions[meal.id], let count = try? DinnerEntry.rational(entered) else { return false }
        return count != meal.candidate.template.servings && meal.candidate.template.servingGroups.contains(where: \.isProtected)
    }

    private func editedMeals() throws -> [DinnerRepeatChoice] {
        try choices.filter { selected.contains($0.id) }.map { original in
            var row = original
            if let entered = portions[row.id] {
                row.servings = try DinnerEntry.rational(entered)
                guard row.servings > .zero else { throw DinnerPlanningError.invalid("servings") }
            }
            if needsIngredientReview(row) {
                guard confirmedAmounts.contains(row.id) else {
                    throw DinnerPlanningError.reviewRequired("protectedIngredientAmounts")
                }
                row.ingredientEdits = try row.candidate.template.ingredients.map { ingredient in
                    let amount = ingredientAmounts[row.id]?[ingredient.id] ?? Amount(ingredient.quantity)
                    return DinnerQuantityEdit(contributionID: ingredient.id, quantity: try amount.quantity(preserving: ingredient.quantity))
                }
            }
            return row
        }
    }

    private func prepare(_ review: DinnerRepeatReview) {
        do {
            let rows = try editedMeals()
            let quantities = try stapleAmounts.filter { staples[$0.key] == .needed }.compactMapValues { try $0.quantity() }
            if model.prepareRepeatWeek(review, choices: rows, staples: staples, stapleQuantities: quantities, pickup: pickup) { advance?() }
        } catch { model.report(error) }
    }
}
