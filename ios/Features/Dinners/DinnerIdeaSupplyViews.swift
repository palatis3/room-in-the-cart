import SwiftUI
import CoreDomain

struct DinnerIdeaSupplyViews: View {
    @ObservedObject var model: DinnerFeatureModel
    let idea: DinnerIdeaDraft
    let update: (DinnerIdeaFoodEvidence?, UUID) -> Void
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.pickupLedger) private var ledger
    @State private var editing: MealIngredient?

    var body: some View {
        if let shop = model.shop, let workspaceID = model.localIdeaWorkspaceID {
            let now = Date()
            let journey = ledger?.sourceWorkspaceID == workspaceID ? pickup.journeys.first { $0.id == shop.id && $0.closedAt == nil } : nil
            let rows = try? DinnerIdeaSupplyReview.rows(idea: idea, shop: shop, workspace: model.workspace,
                workspaceID: workspaceID, journey: journey, at: now)
            VStack(alignment: .leading, spacing: 12) {
                Text(dinnerText("Stock and whole packs")).font(.headline).accessibilityAddTraits(.isHeader)
                Text(dinnerText("Only explicitly matched food is credited. Reviewing an idea leaves the shopping list and reservations unchanged."))
                if let rows {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.ingredients.map(\.name).joined(separator: " + ")).font(.headline)
                            if let matched = row.matchedName { Text(dinnerFormat("Matched food: %@", matched)) }
                            if row.excludedMatch { Text(dinnerText("This food or pack conflicts with the exclusions. Review the match.")) }
                            Text(dinnerFormat("Recipe needs: %@", dinnerQuantity(row.demand)))
                            ForEach(row.reservations) { reservation in
                                Text(dinnerFormat(reservation.protected ? "Protected for %@: %@" : "Reserved for %@: %@",
                                                  reservation.name, dinnerQuantity(reservation.quantity)))
                            }
                            Text(dinnerFormat("Confirmed stock free for this idea: %@", dinnerQuantity(row.credited)))
                            Text(dinnerFormat("Still to cover: %@", dinnerQuantity(row.uncovered)))
                            Text(dinnerFormat("Usable in one pack: %@", dinnerQuantity(row.pack?.usableQuantity)))
                            Text(dinnerFormat("Whole packs for the remainder: %@", row.packs.map(String.init) ?? dinnerText("Unresolved")))
                            if model.budgetVisible {
                                Text(dinnerFormat("Estimated item cost: %@", dinnerMoney(row.cost)))
                            }
                            if model.budgetVisible, let source = row.source, let date = row.observedAt {
                                Text(source + " · " + date.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                            }
                            if row.conflictingPacks { Text(dinnerText("These pack observations differ. Review one pack for this food.")) }
                            ForEach(row.ingredients) { ingredient in
                                Button(dinnerFormat("Review stock and pack for %@", ingredient.name)) { editing = ingredient }
                                    .buttonStyle(.borderless).frame(minHeight: 44)
                                    .accessibilityIdentifier("ideaSupplyEdit-" + ingredient.id.uuidString)
                            }
                        }
                        Divider()
                    }
                } else {
                    Text(dinnerText("Review quantities and units before using this estimate."))
                }
            }
            .onChange(of: shop.basisRevision) { _, _ in editing = nil }
            .sheet(item: $editing) { ingredient in
                let evidence = idea.supplyEvidence?.first { $0.id == ingredient.id && $0.ingredientName == ingredient.name &&
                    $0.workspaceID == workspaceID && $0.shopID == shop.id }
                IdeaSupplyEditor(ingredient: ingredient, shop: shop, workspaceID: workspaceID, previous: evidence,
                                 foods: DinnerIdeaSupplyReview.foods(shop: shop, journey: journey, at: now), budget: model.budgetVisible) { value in
                    defer { editing = nil }
                    guard model.shop?.id == shop.id, model.shop?.basisRevision == shop.basisRevision,
                          model.localIdeaWorkspaceID == workspaceID, model.editable else { return }
                    update(value, ingredient.id)
                }
            }
        } else {
            Text(dinnerText("Private pantry and pack evidence is available in the local shopper workspace."))
        }
    }
}

private struct IdeaSupplyEditor: View {
    let ingredient: MealIngredient
    let shop: ShoppingLedger
    let workspaceID: UUID
    let foods: [IdeaSupplyFood]
    let budget: Bool
    let save: (DinnerIdeaFoodEvidence?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var foodID: UUID?
    @State private var packYield: String
    @State private var unit: UnitOfMeasure
    @State private var price: String
    @State private var source: String
    @State private var observedAt: Date
    @State private var error: String?
    private enum Field { case packYield, price, source }
    @FocusState private var field: Field?

    init(ingredient: MealIngredient, shop: ShoppingLedger, workspaceID: UUID, previous: DinnerIdeaFoodEvidence?,
         foods: [IdeaSupplyFood], budget: Bool, save: @escaping (DinnerIdeaFoodEvidence?) -> Void) {
        self.ingredient = ingredient; self.shop = shop; self.workspaceID = workspaceID
        self.foods = foods; self.budget = budget; self.save = save
        let current = previous.flatMap { $0.basisRevision == shop.basisRevision ? $0 : nil }
        _foodID = State(initialValue: previous?.foodID.flatMap { id in foods.contains { $0.id == id } ? id : nil })
        _packYield = State(initialValue: current?.pack?.usableQuantity?.amount.description ?? "")
        _unit = State(initialValue: current?.pack?.usableQuantity?.unit ?? ingredient.quantity?.unit ?? .count)
        _price = State(initialValue: budget ? current?.pack?.price.map { String(format: "%lld.%02lld", $0.minorUnits / 100, $0.minorUnits % 100) } ?? "" : "")
        _source = State(initialValue: current?.source ?? "")
        _observedAt = State(initialValue: current?.observedAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ingredient.name).font(.headline)
                    Picker(dinnerText("Matched shopping list or pantry food"), selection: $foodID) {
                        Text(dinnerText("No confirmed match")).tag(nil as UUID?)
                        ForEach(foods) { food in Text(food.name + " · " + food.detail).tag(Optional(food.id)) }
                    }
                    Text(dinnerText("Check the food identity and exclusions before matching it."))
                }
                Section(dinnerText("Observed pack, optional")) {
                    TextField(dinnerText("Usable amount per pack"), text: $packYield)
                        .focused($field, equals: .packYield).accessibilityIdentifier("ideaSupplyYield")
                    DinnerUnitPicker(unit: $unit)
                    if budget {
                        TextField(dinnerText("Price per pack in USD"), text: $price)
                            .focused($field, equals: .price).accessibilityIdentifier("ideaSupplyPrice")
                    }
                    TextField(dinnerText("Evidence source"), text: $source)
                        .focused($field, equals: .source).accessibilityIdentifier("ideaSupplySource")
                    DatePicker(dinnerText("Observed at"), selection: $observedAt, in: ...Date())
                    Text(dinnerText("Leave missing pack terms blank. An existing current pack review can be used for the matched list food."))
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button(dinnerText("Use these reviewed details")) { apply() }.accessibilityIdentifier("ideaSupplyConfirm")
            }
            .keyboardDoneAction(visible: field != nil, title: dinnerText("Done")) { field = nil }
            .navigationTitle(dinnerText("Review ingredient supply"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(dinnerText("Cancel")) { dismiss() } }
            }
        }
    }

    private func apply() {
        do {
            let quantity = try DinnerEntry.quantity(packYield, unit: unit)
            let cost = budget ? try DinnerEntry.money(price) : nil
            guard cost.map({ $0 >= .zero }) ?? true else { throw DomainError.invalidNumber }
            let hasPack = quantity != nil || cost != nil
            if hasPack, source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw DomainError.invalidNumber }
            guard foodID != nil || hasPack else { save(nil); return }
            let pack = hasPack ? PackOffer(id: ingredient.id.uuidString, label: ingredient.name, usableQuantity: quantity, price: cost) : nil
            save(DinnerIdeaFoodEvidence(ingredient: ingredient, workspaceID: workspaceID, shopID: shop.id,
                basisRevision: shop.basisRevision, foodID: foodID, pack: pack, source: hasPack ? source : nil, observedAt: hasPack ? observedAt : nil))
        } catch { self.error = dinnerText("Check the usable quantity, price and evidence source.") }
    }
}
