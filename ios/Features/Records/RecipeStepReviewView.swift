import CoreDomain
import SwiftUI

struct RecipeStepEdits: Equatable, Sendable {
    var reviewed: [RecipeStep] = []
    var ingredientLines: [String] = []

    func current(instructions: [String], ingredients: [String]) -> [RecipeStep] {
        let rebound = RecipeStep.rebinding(reviewed, from: ingredientLines, to: ingredients)
        if instructions == rebound.map(\.instruction) { return rebound }
        // Unchanged, unique instructions can move. Repeated or edited lines need review.
        let previous = Dictionary(grouping: rebound, by: \.instruction)
        let counts = Dictionary(grouping: instructions, by: { $0 })
        return instructions.map { text in
            if let matches = previous[text], matches.count == 1, counts[text]?.count == 1 { return matches[0] }
            return RecipeStep(text)
        }
    }
    mutating func apply(_ step: RecipeStep, at index: Int, instructions: [String], ingredients: [String]) {
        var updated = current(instructions: instructions, ingredients: ingredients)
        guard updated.indices.contains(index), updated[index].instruction == step.instruction else { return }
        updated[index] = step
        reviewed = updated
        ingredientLines = ingredients
    }
}

struct RecipeStepReviewView: View {
    let steps: [RecipeStep]
    let ingredients: [String]
    var save: ((Int, RecipeStep) -> Void)? = nil

    var body: some View {
        List(steps.indices, id: \.self) { index in
            NavigationLink {
                RecipeStepDetail(step: steps[index], ingredients: ingredients, save: save.map { action in
                    { value in action(index, value) }
                })
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: recordsText("Step %lld"), Int64(index + 1))).font(.headline)
                    Text(verbatim: steps[index].instruction)
                }
            }.accessibilityIdentifier("records.cookingStep." + String(index))
        }.navigationTitle(recordsText("Cooking steps"))
    }
}

private struct RecipeStepDetail: View {
    @Environment(\.dismiss) private var dismiss
    let step: RecipeStep
    let ingredients: [String]
    let save: ((RecipeStep) -> Void)?
    @State private var selected: Set<Int>
    @State private var minutes: String
    @FocusState private var editingMinutes: Bool

    init(step: RecipeStep, ingredients: [String], save: ((RecipeStep) -> Void)?) {
        self.step = step
        self.ingredients = ingredients
        self.save = save
        _selected = State(initialValue: Set(step.ingredientIndices))
        _minutes = State(initialValue: step.suggestedTimerMinutes.map(String.init) ?? "")
    }

    var body: some View {
        WorkingForm {
            Text(verbatim: step.instruction).font(.title3).textSelection(.enabled)
            if let save {
                Section(recordsText("Choose ingredients for this step")) {
                    ForEach(ingredients.indices, id: \.self) { index in
                        Toggle(isOn: Binding(get: { selected.contains(index) }, set: { enabled in
                            if enabled { selected.insert(index) } else { selected.remove(index) }
                        })) { Text(verbatim: ingredients[index]) }
                            .accessibilityIdentifier("records.stepIngredient." + String(index))
                    }
                }
                TextField(recordsText("Suggested timer in minutes (optional)"), text: $minutes)
                    .keyboardType(.numberPad).focused($editingMinutes)
                if !minutes.isEmpty && !validMinutes {
                    Text(recordsText("Enter a whole number from 1 to 1440 minutes."))
                }
                Button(recordsText("Save step details")) {
                    var value = step
                    value.ingredientIndices = selected.sorted()
                    value.suggestedTimerMinutes = Int(minutes)
                    save(value)
                    dismiss()
                }.disabled(!validMinutes).accessibilityIdentifier("records.saveStepDetails")
            } else {
                Section(step.ingredientIndices.isEmpty ? recordsText("All recipe ingredients") : recordsText("Ingredients for this step")) {
                    if step.ingredientIndices.isEmpty {
                        Text(recordsText("This step has no reviewed ingredient links. Use the original wording below.")).font(.footnote)
                    }
                    ForEach(step.ingredientIndices.isEmpty ? Array(ingredients.indices) : step.ingredientIndices, id: \.self) { index in
                        if ingredients.indices.contains(index) { Text(verbatim: ingredients[index]) }
                    }
                }
                if let minutes = step.suggestedTimerMinutes {
                    Text(String(format: recordsText("Suggested timer: %lld min"), Int64(minutes)))
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: editingMinutes, title: ledgerText("Done"), identifier: "records.stepTimerDone") { editingMinutes = false }
        .navigationTitle(recordsText("Cooking step"))
    }

    private var validMinutes: Bool {
        minutes.isEmpty || Int(minutes).map { (1...1440).contains($0) } == true
    }
}
