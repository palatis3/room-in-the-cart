import CoreDomain
import HouseholdClient
import SwiftUI

/// A household manual review begins blank. The editor has no private recipe, stock or ledger input.
struct HouseholdTonightRecipeEditor: View {
    let householdName: String
    let lots: [HouseholdPantryPage.Lot]
    let save: (SharedMeal, SharedMealPreferenceEvidence, [UUID: [UUID]]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var servings = ""
    @State private var minutes = ""
    @State private var ingredients = [Ingredient()]
    @State private var evidence = MealEligibilityEvidence()
    @State private var reviewed: SharedMeal?
    @State private var busy = false
    @State private var attempted = false
    @State private var failed = false
    @FocusState private var focus: String?

    private struct Ingredient: Identifiable {
        var id = UUID()
        var name = ""
        var amount = ""
        var unit = UnitOfMeasure.count
        var reviewedLots = Set<UUID>()
    }

    init(householdName: String, lots: [HouseholdPantryPage.Lot], original: HouseholdTonightRecipeWrite.Recipe?,
         save: @escaping (SharedMeal, SharedMealPreferenceEvidence, [UUID: [UUID]]) async throws -> Void) {
        self.householdName = householdName
        self.lots = lots
        self.save = save
        if let original {
            _title = State(initialValue: original.title)
            _servings = State(initialValue: String(original.portions))
            _minutes = State(initialValue: original.minutes.map(String.init) ?? "")
            _ingredients = State(initialValue: original.ingredients.map { item in
                Ingredient(id: item.id, name: item.name, amount: item.quantity.map {
                    $0.amount.denominator == 1 ? String($0.amount.numerator) : "\($0.amount.numerator)/\($0.amount.denominator)"
                } ?? "", unit: item.quantity.flatMap { UnitOfMeasure(rawValue: $0.unit) } ?? .count,
                reviewedLots: Set(item.reviewedLotIds).intersection(lots.map(\.id)))
            })
            _evidence = State(initialValue: MealEligibilityEvidence(shared: original.preferenceEvidence))
        }
    }

    var body: some View {
        Form {
            Section(tonightText("Household recipe")) {
                Text(verbatim: householdName).font(.headline)
                Text(tonightText("The adults with access to this household pantry can read this recipe."))
            }
            if let reviewed {
                Section(tonightText("Review recipe facts")) {
                    SharedMealFacts(meal: reviewed)
                    ForEach(ingredients) { row in
                        if !row.reviewedLots.isEmpty {
                            LabeledContent(row.name, value: lots.filter { row.reviewedLots.contains($0.id) }.map { $0.foodName + " · " + String($0.id.uuidString.suffix(8)) }.joined(separator: ", "))
                        }
                    }
                    Button(tonightText("Save recipe to household")) { Task { await commit(reviewed) } }
                        .accessibilityIdentifier("householdTonight.recipe.save")
                    if !attempted { Button(tonightText("Keep editing")) { self.reviewed = nil; failed = false } }
                }
            } else {
                Section(tonightText("Recipe")) {
                    TextField(ledgerText("Dinner title"), text: $title)
                        .focused($focus, equals: "title").accessibilityIdentifier("householdTonight.recipe.title")
                    TextField(ledgerText("Servings"), text: $servings).keyboardType(.numberPad)
                        .focused($focus, equals: "servings").accessibilityIdentifier("householdTonight.recipe.servings")
                    TextField(tonightText("Preparation minutes, unknown if blank"), text: $minutes)
                        .keyboardType(.numberPad).focused($focus, equals: "minutes")
                }
                ForEach($ingredients) { $row in
                    Section {
                        TextField(tonightText("Ingredient"), text: $row.name).focused($focus, equals: "name-" + row.id.uuidString)
                            .accessibilityIdentifier("householdTonight.recipe.ingredient")
                        TextField(tonightText("Amount, unknown if blank"), text: $row.amount).keyboardType(.numbersAndPunctuation)
                            .focused($focus, equals: "amount-" + row.id.uuidString).accessibilityIdentifier("householdTonight.recipe.amount")
                        Picker(pantryText("Unit"), selection: $row.unit) {
                            ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(pantryUnit(unit)).tag(unit) }
                        }
                        DisclosureGroup(tonightText("Match household batches")) {
                            Text(tonightText("Select only batches you reviewed for this ingredient. Similar names alone do not match food."))
                            ForEach(lots) { lot in
                                Toggle(isOn: Binding(get: { row.reviewedLots.contains(lot.id) }, set: { selected in
                                    if selected { row.reviewedLots.insert(lot.id) } else { row.reviewedLots.remove(lot.id) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(verbatim: lot.foodName)
                                        Text(verbatim: pantryLocation(lot.location.rawValue) + " · " + deliveryQuantityText(lot.observation?.quantity) + " · " + String(lot.id.uuidString.suffix(8)))
                                            .font(.caption)
                                    }
                                }.disabled(row.reviewedLots.count >= 12 && !row.reviewedLots.contains(lot.id))
                                    .accessibilityIdentifier("householdTonight.recipe.lot." + lot.id.uuidString)
                            }
                        }
                    }
                }.onDelete { ingredients.remove(atOffsets: $0) }
                Button(tonightText("Add ingredient")) { ingredients.append(.init()) }.disabled(ingredients.count >= 60)
                Section(tonightText("Reviewed restriction details")) { MealEvidenceFields(draft: $evidence) }
                Button(tonightText("Review recipe facts")) {
                    do { reviewed = try makeMeal(); focus = nil; failed = false }
                    catch { failed = true }
                }.accessibilityIdentifier("householdTonight.recipe.review")
            }
            if failed {
                Text(tonightText(reviewed == nil ? "Check the recipe title, servings and ingredient amounts." :
                                "Could not confirm the shared recipe. Check your connection and retry."))
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .keyboardDoneAction(visible: focus != nil, title: pantryText("Done"), identifier: "householdTonight.keyboardDone") { focus = nil }
        .navigationTitle(tonightText("Household recipe"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(busy) } }
    }

    private func makeMeal() throws -> SharedMeal {
        guard let portions = Int(servings), !ingredients.isEmpty, minutes.isEmpty || Int(minutes) != nil else {
            throw ClientError.configuration
        }
        let rows = try ingredients.map { ingredient in
            let quantity = try DinnerEntry.quantity(ingredient.amount, unit: ingredient.unit).map {
                SharedMealQuantity(amount: .init(numerator: Int($0.amount.numerator), denominator: Int($0.amount.denominator)),
                                   unit: $0.unit.rawValue, originalLiteral: $0.originalLiteral)
            }
            return SharedMealPlanning.Ingredient(id: ingredient.id, name: ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  quantity: quantity, groupIds: [], exclusions: [])
        }
        let meal = SharedMeal(title: title.trimmingCharacters(in: .whitespacesAndNewlines), day: nil, kind: "dinner", portions: portions,
                              protected: false, planning: .init(groups: [], ingredients: rows, leadTimeMinutes: Int(minutes)))
        try meal.validatePlanning()
        return meal
    }

    @MainActor private func commit(_ meal: SharedMeal) async {
        guard !busy else { return }
        busy = true; attempted = true
        defer { busy = false }
        do { try await save(meal, evidence.shared, Dictionary(uniqueKeysWithValues: ingredients.map { ($0.id, $0.reviewedLots.sorted { $0.uuidString < $1.uuidString }) })); dismiss() }
        catch { failed = true }
    }
}
