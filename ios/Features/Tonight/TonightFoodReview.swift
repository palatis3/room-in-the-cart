import SwiftUI
import CoreDomain

struct TonightFoodReview: View {
    let food: TonightMealModel.Food
    let authorize: () -> Bool
    let save: (MealEligibilityEvidence) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var details = ""
    @State private var brands = ""
    @State private var ingredientsReviewed = false
    @State private var brandsReviewed = false
    @State private var error = false
    var body: some View {
        Group {
            if !authorize() { Text(tonightText("Unlock your private workspace to review tonight’s meals.")) }
            else {
                Form {
                    Text(food.name).font(.headline)
                    Text(food.detail)
                    Text(tonightText("Review the actual pantry product labels. If several batches share this food, review every batch. Recipe text does not establish these facts."))
                    Toggle(tonightText("I reviewed all ingredient details"), isOn: $ingredientsReviewed)
                    if ingredientsReviewed { TextField(tonightText("Complete ingredient details, one per line"), text: $details, axis: .vertical) }
                    Toggle(tonightText("I reviewed the brands of these batches"), isOn: $brandsReviewed)
                    if brandsReviewed { TextField(tonightText("Brands, one per line; empty means none"), text: $brands, axis: .vertical) }
                    Text(tonightText("This evidence is used only for this pantry review. Refreshing changed stock clears it."))
                    Button(tonightText("Use reviewed food details")) {
                        guard authorize() else { return }
                        var evidence = MealEligibilityEvidence()
                        evidence.reviewedIngredientDetails = ingredientsReviewed ? lines(details) : nil
                        evidence.brands = brandsReviewed ? lines(brands) : nil
                        do { try save(evidence); dismiss() } catch { self.error = true }
                    }
                    if error { Text(tonightText("The pantry or review changed. Close this sheet and refresh.")) }
                }
            }
        }.navigationTitle(tonightText("Review pantry food"))
            .privacySensitive()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tonightText("Cancel")) { dismiss() } } }
    }
    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
