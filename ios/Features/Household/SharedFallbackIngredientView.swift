import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedFallbackIngredientView: View {
    @Binding var draft: CandidateReviewDraft
    let page: SharedRecoveryPage
    let includeOffers: Bool
    @FocusState private var input: Field?
    private enum Field: Hashable {
        case minutes, label(UUID), yield(UUID), price(UUID), stock(UUID), exclusions(UUID)
    }

    var body: some View {
        Form {
            let recipe = draft.candidate.recipe
            Section(recipe.title) {
                LabeledContent(ht("Portions"), value: recipe.portions.formatted())
                if !recipe.exclusions.isEmpty { LabeledContent(ht("Meal exclusions"), value: recipe.exclusions.joined(separator: ", ")) }
                if !recipe.notes.isEmpty { Text(verbatim: recipe.notes) }
                LabeledContent(sharedRecoveryText("Required lead time in minutes"), value: recipe.requiredLeadMinutes.map(String.init) ?? ht("Unknown"))
                TextField(sharedRecoveryText("Remaining preparation minutes"), text: $draft.remaining)
                    .keyboardType(.numberPad).focused($input, equals: .minutes)
                Toggle(sharedRecoveryText("Advance steps are complete for this meal"), isOn: $draft.stepsComplete)
            }
            ForEach($draft.ingredients) { $row in
                if let ingredient = recipe.ingredients.first(where: { $0.id == row.id }) {
                    Section(ingredient.name) {
                        LabeledContent(ht("Ingredient quantity"), value: deliveryQuantityText(ingredient.quantity))
                        if !ingredient.exclusions.isEmpty { LabeledContent(ht("Ingredient exclusions"), value: ingredient.exclusions.joined(separator: ", ")) }
                        if !ingredient.notes.isEmpty { Text(verbatim: ingredient.notes) }
                        ForEach((recipe.groups ?? []).filter { ingredient.groupIds?.contains($0.id) == true }) { group in
                            let amount = ingredient.bindings?.first(where: { $0.groupId == group.id })?.quantity
                            LabeledContent(group.name, value: deliveryQuantityText(amount))
                            if group.protected { Text(ht("Protected portions")) }
                        }
                        if page.sourceOptions.isEmpty { Text(fallbackText("No confirmed household sources to select.")) }
                        ForEach(page.sourceOptions) { source in
                            Toggle(isOn: Binding(get: { row.sources.contains(source.id) }, set: { checked in
                                if checked { row.sources.insert(source.id) } else { row.sources.remove(source.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(verbatim: source.name)
                                    Text(verbatim: recoverySourceKind(source.kind) + " · " + deliveryQuantityText(source.quantity))
                                    if !source.exclusionTags.isEmpty { Text(verbatim: source.exclusionTags.joined(separator: ", ")) }
                                }
                            }.accessibilityIdentifier("fallback.source." + ingredient.id.uuidString + "." + source.id.uuidString)
                        }
                        if includeOffers { packReview($row) }
                    }
                }
            }
        }
        .navigationTitle(fallbackText("Review ingredients, food and time"))
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneAction(visible: input != nil, title: ht("Done"), identifier: "fallback.food.done") { input = nil }
    }

    @ViewBuilder private func packReview(_ binding: Binding<CandidateFoodReview>) -> some View {
        let row = binding.wrappedValue
        let linked = draft.ingredients.filter { $0.id != row.id && $0.hasOwnPack && $0.sharedPackID == nil }
        if !linked.isEmpty || row.sharedPackID != nil {
            Picker(fallbackText("Use an already reviewed pack"), selection: binding.sharedPackID) {
                Text(fallbackText("Separate pack or no offer")).tag(UUID?.none)
                if let chosen = row.sharedPackID, !linked.contains(where: { $0.pack.id == chosen }) {
                    Text(fallbackText("Selected pack is no longer available")).tag(Optional(chosen))
                }
                ForEach(linked) { other in
                    Text(verbatim: other.name + " · " + other.pack.label).tag(Optional(other.pack.id))
                }
            }
        }
        if row.sharedPackID == nil {
            Toggle(fallbackText("Enter a reviewed pack offer"), isOn: binding.hasOwnPack)
            if row.hasOwnPack {
                TextField(fallbackText("Pack name"), text: binding.pack.label).focused($input, equals: .label(row.id))
                TextField(fallbackText("Usable food per pack"), text: binding.pack.amount).focused($input, equals: .yield(row.id))
                Picker(sharedRecoveryText("Unit"), selection: binding.pack.unit) {
                    ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(dinnerUnit(unit)).tag(unit) }
                }
                TextField(fallbackText("Price per pack (USD)"), text: binding.pack.price).keyboardType(.decimalPad).focused($input, equals: .price(row.id))
                TextField(fallbackText("Packs available"), text: binding.pack.availability).keyboardType(.numberPad).focused($input, equals: .stock(row.id))
                TextField(fallbackText("Pack exclusions, one per line"), text: binding.pack.exclusions, axis: .vertical)
                    .focused($input, equals: .exclusions(row.id))
            }
        }
    }
}
