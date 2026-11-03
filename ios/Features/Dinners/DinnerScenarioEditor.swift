import SwiftUI
import CoreDomain

struct DinnerScenarioEditor: View {
    @ObservedObject var model: DinnerFeatureModel
    @State private var draft: DinnerScenarioDraft
    @State private var reviewed: DinnerReviewedScenarios?
    @State private var showReview = false
    init(model: DinnerFeatureModel, shop: ShoppingLedger) {
        self.model = model; _draft = State(initialValue: DinnerScenarioDraft(shop: shop, state: model.state))
    }
    var body: some View {
        Form {
            Section {
                Text(dinnerText("Compare complete dinner plans using evidence you review here. Names alone never match ingredients, pantry food or packs."))
                Text(dinnerText("Manual dinner entry stays available without paid tools or price evidence."))
                NavigationLink(dinnerText("Add a manual dinner")) { DinnerTemplateEditor(model: model, purpose: .manual) }
            }
            if model.budgetVisible, let basis = model.shop?.basis {
                Section(dinnerText("Available budget")) {
                    Text(dinnerFormat("Amount available for %@: %@", dinnerBudgetScope(basis.capScope), dinnerMoney(basis.cap)))
                    if let reserve = basis.fixedReserve { Text(dinnerFormat("Reserve recorded separately: %@", dinnerMoney(reserve))) }
                    Text(dinnerText("The entered cap is already the amount available for its scope. A recorded reserve is not subtracted again."))
                }
            }
            if model.state.acceptedDinners.isEmpty {
                Section { NavigationLink(dinnerText("Accept a dinner before comparing scenarios")) { DinnerTemplateEditor(model: model, purpose: .reusable) } }
            } else {
                DinnerScenarioMealFields(model: model, draft: $draft)
                Section(dinnerText("Explicit recipe ingredient matches")) {
                    Text(dinnerText("Prepare matches after choosing recipes and portions. Then explicitly select the same food identity only where those ingredients really are interchangeable."))
                    Button(dinnerText("Prepare required ingredient matches")) {
                        do { try draft.prepareMatches(accepted: model.state.acceptedDinners); reviewed = nil }
                        catch { model.report(error) }
                    }
                    ForEach($draft.matches) { $match in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(match.recipeName).font(.headline)
                            Text(match.ingredientName)
                            Text(dinnerQuantity(match.quantity))
                            Picker(dinnerText("Reviewed food identity"), selection: $match.foodID) {
                                Text(dinnerText("Select a food identity")).tag(UUID?.none)
                                ForEach(draft.foods) { food in Text(food.name.isEmpty ? dinnerText("Unnamed food identity") : food.name).tag(Optional(food.id)) }
                            }
                        }.padding(.vertical, 5)
                    }
                    Toggle(dinnerText("I reviewed recipe yields and the resulting ingredient quantities"), isOn: $draft.recipeYieldsReviewed)
                    Text(dinnerText("Unknown recipe amounts remain unresolved. For a protected serving group, accept a manually reviewed recipe version before changing its total yield."))
                }
                Section(dinnerText("Food identities, stock and usable packs")) {
                    Text(dinnerText("Create each food identity explicitly. A confirmed lot is shared once across every matched need; outside reservations are protected first."))
                    ForEach($draft.foods) { $food in
                        NavigationLink(food.name.isEmpty ? dinnerText("Name and review this food") : food.name) { DinnerFoodEvidenceEditor(food: $food) }
                    }
                    Button(dinnerText("Add a reviewed food identity")) { draft.foods.append(DinnerFoodEvidenceDraft()) }.disabled(draft.foods.count >= 100)
                }
                DinnerScenarioBasketFields(draft: $draft)
                DinnerScenarioContextFields(draft: $draft)
                Section(dinnerText("Preparation timing")) {
                    TextField(dinnerText("Current plan hands-on minutes, optional"), text: $draft.currentHands)
                    TextField(dinnerText("Current plan remaining lead minutes, optional"), text: $draft.currentLead)
                    TextField(dinnerText("Candidate hands-on minutes, optional"), text: $draft.candidateHands)
                    TextField(dinnerText("Candidate remaining lead minutes, optional"), text: $draft.candidateLead)
                    TextField(dinnerText("Available minutes, optional"), text: $draft.availableMinutes)
                    Text(dinnerText("Enter the remaining elapsed preparation after any completed steps. Missing timing cannot prove a plan is feasible."))
                }
                Section {
                    Button(dinnerText("Review complete scenarios")) {
                        do {
                            guard let shop = model.shop else { return }
                            reviewed = try draft.build(shop: shop, state: model.state); showReview = true
                        } catch { model.report(error) }
                    }.disabled(!model.editable)
                }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Scenario evidence")).dinnerAccess(model, budget: true)
            .navigationDestination(isPresented: $showReview) {
                if let reviewed {
                    DinnerScenarioReviewView(model: model, current: reviewed.current, alternatives: [reviewed.candidate],
                        selectedAcceptedDinnerIDs: Set(reviewed.current.acceptedDinnerIDs), cap: reviewed.cap)
                }
            }
    }
}
private struct DinnerScenarioMealFields: View {
    @ObservedObject var model: DinnerFeatureModel
    @Binding var draft: DinnerScenarioDraft
    var body: some View {
        Section(dinnerText("Same meal commitments")) {
            ForEach($draft.meals) { $meal in
                VStack(alignment: .leading, spacing: 8) {
                    TextField(dinnerText("Commitment name"), text: $meal.name)
                    TextField(dinnerText("Required portions"), text: $meal.portions)
                    recipePicker(dinnerText("Current accepted recipe"), selection: $meal.currentDinnerID)
                    recipePicker(dinnerText("Candidate accepted recipe"), selection: $meal.candidateDinnerID)
                    Toggle(dinnerText("Protected commitment"), isOn: $meal.protected)
                    Toggle(dinnerText("Assign a date"), isOn: $meal.scheduled)
                    if meal.scheduled { DatePicker(dinnerText("Dinner date"), selection: $meal.date, displayedComponents: .date) }
                    Button(dinnerText("Remove commitment"), role: .destructive) { draft.meals.removeAll { $0.id == meal.id } }
                }.padding(.vertical, 5)
            }
            Button(dinnerText("Add meal commitment")) { draft.meals.append(DinnerScenarioMealDraft()) }.disabled(draft.meals.count >= 30)
            Text(dinnerText("An unselected recipe leaves that meal unresolved. Both plans use these same portions and dates."))
        }
    }
    private func recipePicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text(dinnerText("Not yet selected")).tag(UUID?.none)
            ForEach(model.state.acceptedDinners) { dinner in Text(dinner.template.title).tag(Optional(dinner.id)) }
        }
    }
}
private struct DinnerScenarioBasketFields: View {
    @Binding var draft: DinnerScenarioDraft
    var body: some View {
        Section(dinnerText("Unchanged basket costs")) {
            Text(dinnerText("Enter each remaining line cost after excluding the compared recipe purchases. Both plans reuse these exact lines. Review zero explicitly if a listed line is fully represented by the compared recipes."))
            ForEach($draft.baseline) { $line in
                VStack(alignment: .leading) {
                    Text(line.name).font(.headline)
                    TextField(dinnerText("Complete unchanged line cost in USD, optional"), text: $line.cost)
                }
            }
            Toggle(dinnerText("Every other dinner, lunch, side and staple is included once"), isOn: $draft.baselineComplete)
            Toggle(dinnerText("Compared recipe purchases are excluded from these remaining line costs"), isOn: $draft.baselineExcludesComparedRecipes)
            TextField(dinnerText("All checkout fees in USD, optional"), text: $draft.fee)
            TextField(dinnerText("Tax in USD, optional"), text: $draft.tax)
            TextField(dinnerText("Deposits in USD, optional"), text: $draft.deposits)
            Text(dinnerText("Use this entry path for confirmed fixed charges. Threshold fees, discounts or incomplete retailer terms need a reviewed inclusive store quote instead."))
        }
    }
}
private struct DinnerScenarioContextFields: View {
    @Binding var draft: DinnerScenarioDraft
    var body: some View {
        Section(dinnerText("Shared store and evidence basis")) {
            TextField(dinnerText("Retailer name or identifier"), text: $draft.store)
            TextField(dinnerText("Branch"), text: $draft.branch)
            Picker(dinnerText("Mode"), selection: $draft.mode) {
                Text(dinnerText("Pickup")).tag(ShoppingMode.pickup)
                Text(dinnerText("Delivery")).tag(ShoppingMode.delivery)
                Text(dinnerText("In store")).tag(ShoppingMode.inStore)
            }
            DatePicker(dinnerText("Store slot"), selection: $draft.slot)
            TextField(dinnerText("Evidence source"), text: $draft.source)
            DatePicker(dinnerText("Observed at"), selection: $draft.observedAt)
        }
    }
}
private struct DinnerFoodEvidenceEditor: View {
    @Binding var food: DinnerFoodEvidenceDraft
    var body: some View {
        Form {
            Section(dinnerText("Reviewed food identity")) {
                TextField(dinnerText("Food name"), text: $food.name)
                Text(dinnerText("Use this identity only for ingredients and packs you explicitly reviewed as the same food."))
            }
            Section(dinnerText("Confirmed usable stock")) {
                TextField(dinnerText("Usable amount at home, optional"), text: $food.stockAmount)
                DinnerUnitPicker(unit: $food.stockUnit)
                Picker(dinnerText("Stock source"), selection: $food.stockSource) {
                    Text(dinnerText("Pantry")).tag(ConfirmedStockSource.pantry)
                    Text(dinnerText("Freezer")).tag(ConfirmedStockSource.freezer)
                    Text(dinnerText("Manual confirmation")).tag(ConfirmedStockSource.manual)
                }
                DatePicker(dinnerText("Stock confirmed at"), selection: $food.stockDate)
                Toggle(dinnerText("I confirmed this dated usable amount"), isOn: $food.stockConfirmed)
                Text(dinnerText("Unconfirmed stock is not allocated. No pantry quantity is guessed."))
            }
            Section(dinnerText("Protect needs outside this comparison")) {
                TextField(dinnerText("Amount reserved for other needs, optional"), text: $food.outsideAmount)
                DinnerUnitPicker(unit: $food.outsideUnit)
                Toggle(dinnerText("I reviewed all outside reservations; blank means none"), isOn: $food.outsideReservationsReviewed)
                Text(dinnerText("Outside reservations are allocated before these dinner demands and are counted only once."))
            }
            Section(dinnerText("One usable pack")) {
                TextField(dinnerText("Pack description"), text: $food.packLabel)
                TextField(dinnerText("Confirmed usable amount per pack, optional"), text: $food.packAmount)
                DinnerUnitPicker(unit: $food.packUnit)
                Toggle(dinnerText("Usable pack yield reviewed"), isOn: $food.yieldReviewed)
                TextField(dinnerText("Price of one pack in USD, optional"), text: $food.packPrice)
                Picker(dinnerText("Required product availability"), selection: $food.availability) {
                    Text(dinnerText("Unknown")).tag(0)
                    Text(dinnerText("Reviewed available")).tag(1)
                    Text(dinnerText("Unavailable")).tag(2)
                }
                TextField(dinnerText("Maximum available packs, optional"), text: $food.maximumPacks)
                Text(dinnerText("Use reviewed usable quantities. Bone, peel, liquid loss and cooking yield are never inferred. Incompatible units remain unresolved."))
            }
        }.navigationTitle(dinnerText("Food evidence"))
    }
}
