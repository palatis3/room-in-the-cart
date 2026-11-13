import CoreDomain
import Foundation
import HouseholdClient
import SwiftUI

func fallbackText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "SharedFallback")
}

struct DisclosedFallbackDraft {
    var title = ""
    var portions = ""
    var sourceURL = ""
    var notes = ""
    var exclusions = ""
    var elapsed = ""
    var lead = ""
    var ingredients = [DinnerIngredientDraft()]

    func recipe() throws -> SharedFallbackRecipe {
        guard let count = Int(portions.trimmingCharacters(in: .whitespacesAndNewlines)), (1...1000).contains(count),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ingredients.isEmpty else {
            throw ClientError.configuration
        }
        let address = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            guard let url = URLComponents(string: address), ["https", "http"].contains(url.scheme?.lowercased()),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw ClientError.configuration }
        }
        let recipe = try SharedFallbackRecipe(title: title.trimmingCharacters(in: .whitespacesAndNewlines), portions: count,
            notes: notes, sourceURL: address.isEmpty ? nil : address, exclusions: DinnerEntry.list(exclusions),
            requiredLeadMinutes: DinnerEntry.minutes(lead, maximum: 1_000_000), elapsedMinutes: DinnerEntry.minutes(elapsed, maximum: 1_000_000),
            ingredients: ingredients.map { row in
                let ingredient = try row.ingredient()
                let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let quantity = try ingredient.quantity.map { quantity in
                    guard quantity.amount > .zero, quantity.amount.numerator <= 1_000_000_000,
                          quantity.amount.denominator <= 1_000_000_000 else { throw ClientError.configuration }
                    return SharedMealQuantity(amount: .init(numerator: Int(quantity.amount.numerator), denominator: Int(quantity.amount.denominator)),
                                              unit: quantity.unit.rawValue, originalLiteral: quantity.originalLiteral)
                }
                return .init(id: row.id, name: name, quantity: quantity, exclusions: ingredient.exclusions, notes: ingredient.notes)
            })
        try recipe.validateForDisclosure()
        return recipe
    }
}

struct SharedFallbackRecipeEditor: View {
    private enum Field: Hashable {
        case title, portions, notes, url, restrictions, elapsed, lead
        case ingredient(UUID), quantity(UUID), exclusions(UUID), preparation(UUID)
    }
    @State private var draft = DisclosedFallbackDraft()
    @State private var validationFailed = false
    @FocusState private var input: Field?
    let review: (SharedFallbackRecipe) -> Void

    var body: some View {
        Form {
            Section {
                TextField(ht("Meal name"), text: $draft.title)
                    .focused($input, equals: .title).accessibilityIdentifier("fallback.recipe.title")
                TextField(ht("Portions"), text: $draft.portions).keyboardType(.numberPad)
                    .focused($input, equals: .portions).accessibilityIdentifier("fallback.recipe.portions")
                TextField(sharedRecoveryText("Preparation notes"), text: $draft.notes, axis: .vertical)
                    .focused($input, equals: .notes)
                TextField(fallbackText("Recipe source URL"), text: $draft.sourceURL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($input, equals: .url)
                TextField(fallbackText("Meal exclusions, one per line"), text: $draft.exclusions, axis: .vertical)
                    .focused($input, equals: .restrictions)
            }
            ForEach(draft.ingredients) { snapshot in
                let row = dinnerDraftBinding(snapshot, in: $draft.ingredients)
                let id = snapshot.id
                Section(ht("Ingredient")) {
                    TextField(ht("Ingredient"), text: row.name)
                        .focused($input, equals: .ingredient(id)).accessibilityIdentifier("fallback.recipe.ingredient")
                    TextField(ht("Ingredient quantity"), text: row.amount)
                        .focused($input, equals: .quantity(id)).accessibilityIdentifier("fallback.recipe.quantity")
                    Picker(sharedRecoveryText("Unit"), selection: row.unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(dinnerUnit(unit)).tag(unit) }
                    }
                    TextField(fallbackText("Ingredient exclusions, one per line"), text: row.exclusions, axis: .vertical)
                        .focused($input, equals: .exclusions(id))
                    TextField(sharedRecoveryText("Preparation notes"), text: row.notes, axis: .vertical)
                        .focused($input, equals: .preparation(id))
                    if draft.ingredients.count > 1 {
                        Button(pTr("Remove"), role: .destructive) { draft.ingredients.removeAll { $0.id == id } }
                    }
                }
            }
            Button(sharedRecoveryText("Add an ingredient")) { draft.ingredients.append(.init()) }
            Section {
                TextField(fallbackText("Total preparation minutes"), text: $draft.elapsed).keyboardType(.numberPad)
                    .focused($input, equals: .elapsed)
                TextField(sharedRecoveryText("Required lead time in minutes"), text: $draft.lead).keyboardType(.numberPad)
                    .focused($input, equals: .lead)
            } footer: { Text(sharedRecoveryText("Leave an unknown time blank.")) }
            if validationFailed { Text(fallbackText("Check the name, portions, ingredients, source and preparation times.")) }
            Button(fallbackText("Review recipe for this household")) {
                input = nil
                do { review(try draft.recipe()); validationFailed = false }
                catch { validationFailed = true }
            }.accessibilityIdentifier("fallback.recipe.review")
        }
        .keyboardDoneAction(visible: input != nil, title: ht("Done"), identifier: "fallback.recipe.done") { input = nil }
        .navigationTitle(fallbackText("Share one fallback recipe"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
