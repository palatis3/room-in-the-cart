import SwiftUI
import CoreDomain

struct ThreeDinnerBasketView: View {
    @ObservedObject var model: DinnerFeatureModel
    @Environment(\.advanceToDinnerApply) private var advance
    @State private var days: [Date]
    @State private var minutes = ["", "", ""]
    @State private var lunch = 0
    @State private var budget = ""
    @State private var selected: Set<UUID>
    @State private var groceries: [DinnerBasketGroceryDraft] = []
    @State private var plans: [ThreeDinnerBasket.Plan] = []
    @State private var page = 0
    @State private var message: String?
    @State private var searching = false
    let shopID: UUID
    let revision: UUID
    let planningRevision: UUID
    let editor: DinnerFeatureModel.EditorIdentity?
    init(model: DinnerFeatureModel, shop: ShoppingLedger) {
        self.model = model; shopID = shop.id; revision = shop.revisionID
        planningRevision = model.state.revisionID; editor = model.editorIdentity
        let recipes = model.state.acceptedDinners.filter { MealEligibilityPolicy.evaluate(profile: model.mealPreferences, template: $0.template).eligible }
        _selected = State(initialValue: Set(recipes.prefix(12).map(\.id)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: shop.basis.timeZoneIdentifier) ?? .current
        let today = calendar.startOfDay(for: model.clock())
        let dates = (0..<366).compactMap { offset -> Date? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  let day = try? MealDay(date: date, timeZoneIdentifier: shop.basis.timeZoneIdentifier),
                  !shop.mealOccurrences.contains(where: { $0.removedAt == nil && $0.scheduledDay?.hasSameCivilDate(as: day) == true }),
                  !model.state.weekNotes.contains(where: { $0.shopID == shop.id && $0.kind == .away && $0.day.hasSameCivilDate(as: day) }) else { return nil }
            return date
        }.prefix(3)
        _days = State(initialValue: Array(dates) + Array(repeating: today, count: 3 - dates.count))
    }
    private var current: Bool {
        model.basketPrepAccess() && editor != nil && editor == model.editorIdentity && model.localIdeaWorkspaceID != nil && model.paid && model.budgetVisible &&
            model.shop?.id == shopID && model.shop?.revisionID == revision && model.state.revisionID == planningRevision &&
            model.phaseProvider(shopID) == .draft
    }
    private var recipes: [AcceptedDinner] { model.state.acceptedDinners.filter { selected.contains($0.id) } }
    var body: some View {
        Form {
            if current {
                if page == 0 { setup }
                if page == 1 { evidence }
                if page == 2 { results }
                if let message { Text(message).accessibilityAddTraits(.updatesFrequently) }
                DinnerFeedback(model: model)
            } else if !model.paid {
                Text(dinnerText("This assisted tool requires paid access. Manual dinner editing remains available."))
            } else { Text(dinnerText("The pickup or dinner plan changed. Make a new preview before applying.")) }
        }.disabled(searching).overlay { if searching { ProgressView() } }
            .navigationTitle(dinnerPlanText("Three dinners, one basket")).dinnerAccess(model, budget: true)
    }
    @ViewBuilder private var setup: some View {
        Section {
            ForEach(0..<3, id: \.self) { index in
                DatePicker(dinnerPlanFormat("Night %lld", Int64(index + 1)), selection: $days[index], displayedComponents: .date)
                TextField(dinnerPlanText("Available minutes (optional)"), text: $minutes[index]).keyboardType(.numberPad)
            }
            TextField(dinnerPlanText("Grocery subtotal budget (optional)"), text: $budget).keyboardType(.decimalPad)
            Stepper(dinnerPlanFormat("Additional lunch portions per dinner: %lld", Int64(lunch)), value: $lunch, in: 0...20)
        } footer: { Text(dinnerPlanText("Choose three open nights. Each new lunch hold comes from the recipe’s unassigned servings.")) }
        if let shop = model.shop {
            let holds = shop.contributions.filter { $0.removedAt == nil && $0.source.isProtected }
            let meals = shop.mealOccurrences.filter { $0.removedAt == nil && $0.servingGroups.contains(where: \.isProtected) }
            if !holds.isEmpty || !meals.isEmpty {
                Section(dinnerPlanText("Existing holds")) {
                    ForEach(holds) { row in
                        if case .protectedNeed(let purpose) = row.source {
                            Text(dinnerPlanFormat("%@ · %@ · %@", row.productName, dinnerQuantity(row.quantity), purpose))
                        }
                    }
                    ForEach(meals) { meal in
                        ForEach(meal.servingGroups.filter(\.isProtected)) { group in
                            Text(dinnerPlanFormat("%@ · %@ · %@", meal.title, group.name, dinnerFormat("Servings: %@", group.servings.description)))
                        }
                    }
                }
            }
        }
        Section {
            ForEach(model.state.acceptedDinners.filter { MealEligibilityPolicy.evaluate(profile: model.mealPreferences, template: $0.template).eligible }) { recipe in
                Toggle(isOn: Binding(get: { selected.contains(recipe.id) }, set: { enabled in
                    if enabled { selected.insert(recipe.id) } else { selected.remove(recipe.id) }
                })) {
                    VStack(alignment: .leading) {
                        Text(recipe.template.title)
                        Text(recipe.template.leadTimeMinutes.map { dinnerPlanFormat("%lld minutes", Int64($0)) } ?? dinnerPlanText("Time unknown")).font(.caption)
                    }
                }.disabled(!selected.contains(recipe.id) && selected.count >= 12)
            }
        } header: { Text(dinnerPlanText("Saved recipes")) } footer: { Text(dinnerPlanText("Select 3–12 recipes. A time limit requires a saved duration.")) }
        Button(dinnerPlanText("Review groceries and prices")) {
            guard current, let shop = model.shop, let workspace = model.localIdeaWorkspaceID else { return }
            do {
                let dates = try civilDays(shop)
                guard Set(dates).count == 3, dates.allSatisfy({ day in
                    !shop.mealOccurrences.contains { $0.removedAt == nil && $0.scheduledDay?.hasSameCivilDate(as: day) == true } &&
                    !model.state.weekNotes.contains { $0.shopID == shop.id && $0.kind == .away && $0.day.hasSameCivilDate(as: day) }
                }) else { message = dinnerPlanText("Choose three different open nights."); return }
                _ = try minutes.map { try DinnerEntry.minutes($0, maximum: 1440) }
                _ = try DinnerEntry.money(budget)
                groceries = try DinnerBasketGroceryDraft.prepare(recipes: recipes, shop: shop, history: model.workspace.packSelections, workspace: workspace)
                page = 1; message = nil
            } catch { model.report(error) }
        }.disabled(selected.count < 3)
    }
    @ViewBuilder private var evidence: some View {
        Section { Text(dinnerPlanText("Review the current list and recipe ingredients. Combine rows only when the same product can cover each need. Enter dated pack evidence or leave the price open.")) }
        ForEach($groceries) { $row in
            Section(row.label.name) {
                if row.existingLine != nil { Text(dinnerPlanFormat("Already on list · %@", dinnerQuantity(row.existingQuantity))) }
                ForEach(Array(row.members.enumerated()), id: \.offset) { _, member in Text(member.1) }
                if !row.label.notes.isEmpty { Text(row.label.notes) }
                if !row.label.exclusions.isEmpty { Text(dinnerPlanFormat("Exclusions · %@", row.label.exclusions.joined(separator: ", "))) }
                let multiple = row.members.count + (row.existingLine == nil ? 0 : 1) > 1
                if multiple { Toggle(dinnerPlanText("Use the same grocery for these needs"), isOn: $row.combine) }
                if !multiple || row.combine || row.existingLine != nil {
                    DisclosureGroup(dinnerPlanText("Pack and store evidence")) {
                        TextField(dinnerPlanText("Usable quantity per pack"), text: $row.amount).keyboardType(.numbersAndPunctuation)
                        Picker(dinnerText("Unit"), selection: $row.unit) {
                            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(dinnerUnit($0)).tag($0) }
                        }
                        TextField(dinnerPlanText("Price per pack"), text: $row.price).keyboardType(.decimalPad)
                        TextField(dinnerPlanText("Store and pack label"), text: $row.source)
                        DatePicker(dinnerPlanText("Price observed"), selection: $row.observed, in: ...Date(), displayedComponents: .date)
                    }
                }
            }
        }
        Button(dinnerPlanText("Find dinner combinations")) { search() }.accessibilityIdentifier("dinner.basket.search")
        Button(dinnerPlanText("Change nights or recipes")) { page = 0; message = nil }
    }
    @ViewBuilder private var results: some View {
        if plans.isEmpty { Text(dinnerPlanText("No combination fits these nights, portions, times and known prices.")) }
        ForEach(Array(plans.enumerated()), id: \.offset) { offset, plan in
            Section(dinnerPlanFormat("Option %lld", Int64(offset + 1))) {
                ForEach(Array(plan.meals.enumerated()), id: \.offset) { index, meal in
                    VStack(alignment: .leading) {
                        Text(days[index], style: .date)
                        Text(meal.template.title).font(.headline)
                        Button(dinnerPlanText("Swap this meal")) {
                            var pins: [Int: UUID] = [:]
                            for (i, keep) in plan.meals.enumerated() where i != index { pins[i] = keep.id }
                            search(pins: pins, exclude: [meal.id])
                        }.buttonStyle(.borderless)
                    }
                }
                if lunch > 0 { Text(dinnerPlanFormat("Additional lunch portions per dinner: %lld", Int64(lunch))) }
                Text(dinnerPlanFormat("Known grocery subtotal · %@", dinnerMoney(plan.subtotal))).font(.headline)
                if plan.missing > 0 { Text(dinnerPlanFormat("Unpriced groceries: %lld. The total is uncertain.", Int64(plan.missing))) }
                Text(dinnerPlanText("Grocery estimate before tax, fees and stock deductions."))
                ForEach(plan.lines) { line in
                    VStack(alignment: .leading) {
                        Text(line.food.name).bold()
                        if !line.recipes.isEmpty { Text(line.recipes.joined(separator: " · ")) }
                        if let count = line.packs { Text(dinnerPlanFormat("Whole packs: %lld", count)) }
                        Text(line.cost.map { dinnerMoney($0) } ?? dinnerPlanText("Unpriced"))
                        if let source = line.food.source, !source.isEmpty, let date = line.food.observedAt {
                            Text(source); Text(date, style: .date)
                        }
                    }.accessibilityElement(children: .combine)
                }
                Button(dinnerPlanText("Review adding these dinners")) {
                    guard current, let shop = model.shop else { return }
                    do {
                        let changes = try ThreeDinnerBasket.changes(for: plan, days: civilDays(shop), lunch: Rational(Int64(lunch)),
                                                                    lunchName: dinnerPlanText("Reserved lunch"))
                        if model.prepare(changes, tool: .threeDinnerBasket, expectedRevision: revision) { advance?() }
                    } catch { model.report(error) }
                }
            }
        }
        Button(dinnerPlanText("Review groceries and prices")) { page = 1; message = nil }
    }
    private func civilDays(_ shop: ShoppingLedger) throws -> [MealDay] { try days.map { try MealDay(date: $0, timeZoneIdentifier: shop.basis.timeZoneIdentifier) } }
    private func search(pins: [Int: UUID] = [:], exclude: Set<UUID> = []) {
        guard current, let shop = model.shop else { return }
        do {
            let dates = try civilDays(shop), cap = try DinnerEntry.money(budget), holds = try Rational(Int64(lunch))
            let limits = try minutes.map { try DinnerEntry.minutes($0, maximum: 1440) }
            let foods = try groceries.flatMap { try $0.resolved() }
            let access = try model.access(for: shopID), state = model.state, choices = recipes, now = model.clock()
            searching = true
            Task {
                defer { searching = false }
                do {
                    let options = try await Task.detached(priority: .userInitiated) {
                        try ThreeDinnerBasket.search(recipes: choices, days: dates, minutes: limits, lunch: holds, budget: cap,
                            foods: foods, shop: shop, state: state, access: access, now: now, pins: pins, exclude: exclude)
                    }.value
                    guard current else { return }
                    if !pins.isEmpty && options.isEmpty { message = dinnerPlanText("No other saved meal fits this slot."); return }
                    plans = options; page = 2; message = nil
                } catch { model.report(error) }
            }
        } catch { model.report(error) }
    }
}
