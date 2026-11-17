import SwiftUI
import CoreDomain
import RecordArchive

/// Explicitly approves numeric facts from a source. The original imported text
/// remains in Records; this saves the existing Free reusable dinner slot.
struct TonightRecipeReview: View {
    @ObservedObject var ledger: LedgerModel
    let source: TonightMealModel.Source?
    var template: MealTemplate? = nil
    let currentIdentity: @MainActor () -> CapturePrivateIdentity?
    @Environment(\.dismiss) private var dismiss
    @State private var identity: CapturePrivateIdentity?
    @State private var origin: UUID?
    @State private var original: LedgerWorkspace?
    @State private var title = ""
    @State private var servings = ""
    @State private var minutes = ""
    @State private var ingredients: [Ingredient] = []
    @State private var details = ""
    @State private var appliances = ""
    @State private var brands = ""
    @State private var detailsReviewed = false
    @State private var appliancesReviewed = false
    @State private var brandsReviewed = false
    @State private var effort: MealEffort?
    @State private var candidate: MealTemplate?
    @State private var error: String?
    @State private var busy = false
    private struct Ingredient: Identifiable {
        var id = UUID()
        var name = ""
        var amount = ""
        var unit: UnitOfMeasure = .count
    }
    private var authorized: Bool {
        identity != nil && currentIdentity() == identity && ledger.sourceWorkspaceID == origin
    }
    var body: some View {
        Group {
            if !authorized { Text(tonightText("Unlock your private workspace to review tonight’s meals.")) }
            else {
                Form {
                    if let candidate {
                        Section(tonightText("Review recipe facts")) {
                            Text(candidate.title).font(.headline)
                            if let template, original?.mealTemplates.contains(template) != true {
                                Text(tonightText("This saves a reviewed Free copy. The accepted recipe and previously chosen dinners keep their original facts."))
                            }
                            LabeledContent(ledgerText("Servings"), value: amountText(candidate.servings))
                            ForEach(candidate.ingredients) { ingredient in LabeledContent(ingredient.name, value: ledgerQuantity(ingredient.quantity)) }
                            Text(tonightText(original?.mealTemplates.isEmpty == false ?
                                "Saving replaces your Free reusable dinner. Previously chosen dinners and the original Records import stay unchanged." :
                                "Saving creates your Free reusable dinner. It does not start a pickup or add groceries."))
                            Button(tonightText("Save reviewed recipe")) { Task { await save(candidate) } }
                                .disabled(busy || ledger.hasPendingSave).accessibilityIdentifier("tonight.recipe.save")
                            Button(tonightText("Keep editing")) { self.candidate = nil }.disabled(busy)
                        }
                    } else {
                        if let source {
                            Section(tonightText("Original saved source")) {
                                Text(source.recipe.title)
                                Text(source.recipe.yieldText)
                                ForEach(Array(source.recipe.ingredients.enumerated()), id: \.offset) { _, line in Text(line) }
                                Text(tonightText("Enter reviewed amounts below. Imported words do not establish a quantity or serving count."))
                            }
                        }
                        Section(tonightText("Recipe")) {
                            TextField(ledgerText("Dinner title"), text: $title).accessibilityIdentifier("tonight.recipe.title")
                            TextField(ledgerText("Servings"), text: $servings).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("tonight.recipe.servings")
                            TextField(tonightText("Preparation minutes, unknown if blank"), text: $minutes).keyboardType(.numberPad)
                            ForEach($ingredients) { $ingredient in
                                TextField(tonightText("Ingredient"), text: $ingredient.name).accessibilityIdentifier("tonight.recipe.ingredient")
                                LedgerQuantityFields(amount: $ingredient.amount, unit: $ingredient.unit)
                            }
                            .onDelete { ingredients.remove(atOffsets: $0) }
                            Button(tonightText("Add ingredient")) { ingredients.append(Ingredient()) }
                        }
                        Section(tonightText("Reviewed restriction details")) {
                            Text(tonightText("Leave details unknown unless you reviewed them. Recipe details never confirm the ingredients or brand of a pantry product."))
                            Toggle(tonightText("I reviewed all ingredient details"), isOn: $detailsReviewed)
                            if detailsReviewed { TextField(tonightText("Complete ingredient details, one per line"), text: $details, axis: .vertical) }
                            Toggle(tonightText("I reviewed required appliances"), isOn: $appliancesReviewed)
                            if appliancesReviewed { TextField(tonightText("Required appliances, one per line; empty means none"), text: $appliances, axis: .vertical) }
                            Toggle(tonightText("I reviewed recipe brands"), isOn: $brandsReviewed)
                            if brandsReviewed { TextField(tonightText("Brands, one per line; empty means none"), text: $brands, axis: .vertical) }
                            Picker(tonightText("Preparation effort"), selection: $effort) {
                                Text(tonightText("Unknown")).tag(MealEffort?.none)
                                ForEach(MealEffort.allCases, id: \.self) { Text(tonightText($0.rawValue)).tag(Optional($0)) }
                            }
                        }
                        Button(tonightText("Review recipe facts")) { review() }.accessibilityIdentifier("tonight.recipe.review")
                    }
                    if let error { Text(error) }
                    LedgerSaveStatus(model: ledger)
                }.disabled(busy)
            }
        }.navigationTitle(tonightText("Review a recipe"))
            .privacySensitive()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tonightText("Cancel")) { dismiss() }.disabled(busy) } }
            .onAppear {
                guard identity == nil else { return }
                identity = currentIdentity(); origin = ledger.sourceWorkspaceID; original = ledger.workspace
                title = template?.title ?? source?.recipe.title ?? ""
                if let template {
                    servings = ledgerAmountInput(template.servings)
                    minutes = template.leadTimeMinutes.map(String.init) ?? ""
                    ingredients = template.ingredients.map { Ingredient(id: $0.id, name: $0.name, amount: $0.quantity.map { ledgerAmountInput($0.amount) } ?? "", unit: $0.quantity?.unit ?? .count) }
                    let facts = template.eligibilityEvidence
                    detailsReviewed = facts?.reviewedIngredientDetails != nil; details = facts?.reviewedIngredientDetails?.joined(separator: "\n") ?? ""
                    appliancesReviewed = facts?.requiredAppliances != nil; appliances = facts?.requiredAppliances?.joined(separator: "\n") ?? ""
                    brandsReviewed = facts?.brands != nil; brands = facts?.brands?.joined(separator: "\n") ?? ""
                    effort = facts?.effort
                    return
                }
                if let source, source.recipe.ingredients.count > 200 {
                    ingredients = []; error = tonightText("This source exceeds the supported recipe size. Review a smaller recipe in Records before continuing.")
                } else { ingredients = source?.recipe.ingredients.map { Ingredient(name: $0) } ?? [Ingredient()] }
            }
    }
    private func lines(_ text: String) -> [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func review() {
        do {
            guard (source?.recipe.ingredients.count ?? 0) <= 200, authorized, let servings = try LedgerEntry.rational(servings), servings > .zero else { throw TonightMealModel.Failure.unavailable }
            let amount = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard amount.isEmpty || Int(amount) != nil else { throw TonightMealModel.Failure.unavailable }
            let rows = try ingredients.map { ingredient -> MealIngredient in
                guard let quantity = try LedgerEntry.quantity(ingredient.amount, ingredient.unit), quantity.amount > .zero else { throw TonightMealModel.Failure.unavailable }
                let prior = template?.ingredients.first { $0.id == ingredient.id }
                return MealIngredient(id: ingredient.id, name: ingredient.name, quantity: quantity, notes: prior?.notes ?? "", exclusions: prior?.exclusions ?? [])
            }
            guard !rows.isEmpty else { throw TonightMealModel.Failure.unavailable }
            // Editing the current Free recipe preserves its identity. Reviewing
            // an accepted recipe creates a new Free copy; its original stays in
            // the accepted library and previous ledger revisions.
            let editingFree = template.flatMap { selected in original?.mealTemplates.first(where: { $0 == selected }) }
            var result = MealTemplate(id: editingFree?.id ?? UUID(), title: title, servings: servings,
                ingredients: rows, notes: template?.notes ?? source.map { $0.recipe.notes + "\n" + $0.recipe.steps.joined(separator: "\n") } ?? "",
                sourceURL: template?.sourceURL ?? source?.recipe.sourceURL, exclusions: template?.exclusions ?? [],
                revision: (editingFree?.revision ?? -1) + 1, servingGroups: template?.servingGroups ?? [],
                leadTimeMinutes: Int(amount), completedSteps: template?.completedSteps ?? [], sourceEvidence: template?.sourceEvidence)
            var evidence = MealEligibilityEvidence()
            evidence.reviewedIngredientDetails = detailsReviewed ? lines(details) : nil
            evidence.requiredAppliances = appliancesReviewed ? lines(appliances) : nil
            evidence.brands = brandsReviewed ? lines(brands) : nil
            evidence.effort = effort
            result.eligibilityEvidence = evidence
            try result.validate()
            candidate = result; error = nil
        } catch { self.error = tonightText("Enter a title, positive servings and ingredient amounts, and valid reviewed details.") }
    }
    @MainActor private func save(_ candidate: MealTemplate) async {
        guard authorized, let original, !busy else { return }
        busy = true; defer { busy = false }
        do {
            if let source {
                let current = try await TonightRecipeLibrary.read(authorize: { authorized })
                guard current.contains(source) else { throw TonightMealModel.Failure.recipeChanged }
            }
            guard authorized else { throw TonightMealModel.Failure.unavailable }
            if let template {
                guard original.mealTemplates.contains(template) || original.dinnerPlanning.acceptedDinners.contains(where: { $0.template == template }) else { throw TonightMealModel.Failure.recipeChanged }
            }
            let ok = await ledger.change(key: "tonight-recipe-\(candidate.id)-\(candidate.revision)", reviewedPantryBasis: nil,
                authorize: { authorized }) { workspace in
                guard workspace == original else { throw TonightMealModel.Failure.stale }
                try TonightMealModel.saveReviewedTemplate(candidate, editing: template, in: &workspace)
            }
            if ok && authorized { dismiss() }
            else { error = tonightText("Recipe was not confirmed. Review changed information or the pending save.") }
        } catch { self.error = tonightText("The saved source or private workspace changed. Open the review again.") }
    }
}
