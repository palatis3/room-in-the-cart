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
    @State private var initialSourceRows: [MealIngredient] = []
    @State private var details = ""
    @State private var appliances = ""
    @State private var brands = ""
    @State private var detailsReviewed = false
    @State private var appliancesReviewed = false
    @State private var brandsReviewed = false
    @State private var effort: MealEffort?
    @State private var candidate: MealTemplate?
    @State private var savedRecipe: MealTemplate?
    @State private var showRestrictions = false
    @AccessibilityFocusState private var savedHeadingFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var error: String?
    @State private var invalidAmountID: UUID?
    @FocusState private var focusedInput: String?
    @State private var busy = false
    private struct Ingredient: Identifiable {
        var id = UUID()
        var name = ""
        var amount = ""
        var unit: UnitOfMeasure = .count
        var originalWording: String?
        var originalQuantity: Quantity?
        var checkedWithoutAmount = false
        init() {}
        init(_ row: MealIngredient) {
            id = row.id; name = row.name; unit = row.quantity?.unit ?? .count
            amount = row.quantity?.amount.description ?? ""
            originalQuantity = row.quantity
            originalWording = row.originalWording; checkedWithoutAmount = row.checkedWithoutAmount == true
        }
        @MainActor var positiveQuantity: Quantity? {
            guard let quantity = try? DinnerEntry.quantity(amount, unit: unit, preserving: originalQuantity), quantity.amount > .zero else { return nil }
            return quantity
        }
    }
    private var authorized: Bool {
        identity != nil && currentIdentity() == identity && ledger.sourceWorkspaceID == origin
    }
    private var replacedRecipe: MealTemplate? {
        guard let original, template.map(original.mealTemplates.contains) != true else { return nil }
        return original.mealTemplates.first
    }
    var body: some View {
        ScrollViewReader { scroll in form(scroll) }
    }

    private func form(_ scroll: ScrollViewProxy) -> some View {
        Group {
            if !authorized { Text(tonightText("Unlock your private workspace to review tonight’s meals.")) }
            else {
                WorkingForm {
                    if let savedRecipe {
                        Section {
                            Label(ledgerText("Saved on this iPhone"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.action)
                                .accessibilityFocused($savedHeadingFocused)
                                .accessibilityIdentifier("tonight.recipe.saved")
                                .id("savedHeading")
                            Text(verbatim: savedRecipe.title).font(.system(.title2, design: .serif, weight: .semibold))
                            fact(ledgerText("Servings"), amountText(savedRecipe.servings))
                            SavedDinnerHandoffLink(recipe: savedRecipe)
                            Button(ledgerText("Done")) { dismiss() }.accessibilityIdentifier("tonight.recipe.done")
                        }
                        .onAppear {
                            scroll.scrollTo("savedHeading", anchor: .top)
                            savedHeadingFocused = true
                        }
                    } else if let candidate {
                        Section(tonightText("Review recipe facts")) {
                            Text(candidate.title).font(.system(.title2, design: .serif, weight: .semibold))
                            if let template, original?.mealTemplates.contains(template) != true {
                                Text(tonightText("This saves a reviewed Free copy. The accepted recipe and previously chosen dinners keep their original facts."))
                            }
                            fact(ledgerText("Servings"), amountText(candidate.servings))
                            if let minutes = candidate.leadTimeMinutes {
                                fact(tonightText("Preparation time"), Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes])))
                                    .accessibilityIdentifier("tonight.recipe.reviewedMinutes")
                            }
                            ForEach(candidate.ingredients) { ingredient in fact(ingredient.name, ingredient.reviewedAmountLabel) }
                            if let template, original?.mealTemplates.contains(template) == true {
                                Text(tonightText("Saving updates this recipe in your library."))
                            } else if let replacedRecipe {
                                Text(String(format: tonightText("Saving replaces “%@” as your Free reusable dinner. Previously chosen dinners and imported recipes keep their saved details."), replacedRecipe.title))
                            } else {
                                Text(tonightText("Saving creates your Free reusable dinner. It does not start a pickup or add groceries."))
                            }
                            Button(tonightText(replacedRecipe == nil ? "Save reviewed recipe" : "Replace recipe")) { Task { await save(candidate) } }.buttonStyle(PrimaryAction())
                                .disabled(busy || ledger.hasPendingSave).accessibilityIdentifier("tonight.recipe.save")
                            Button(tonightText("Keep editing")) { self.candidate = nil }.disabled(busy)
                        }
                    } else {
                        if let source {
                            Section(tonightText("Original saved source")) {
                                Text(source.recipe.title)
                                Text(source.recipe.yieldText)
                                ForEach(Array(source.recipe.ingredients.enumerated()), id: \.offset) { _, line in Text(line) }
                                Text(tonightText("Check the suggested amounts against the original recipe. Enter servings and review any unmeasured ingredients."))
                            }
                        }
                        Section(tonightText("Recipe")) {
                            WorkingField(ledgerText("Dinner title")) {
                                TextField(ledgerText("Dinner title"), text: $title, prompt: Text(verbatim: "—"))
                                    .focused($focusedInput, equals: "title")
                                    .submitLabel(.next)
                                    .onSubmit { advance(to: "servings", using: scroll) }
                                    .accessibilityIdentifier("tonight.recipe.title")
                            }
                            .dinnerInputRow($focusedInput, field: "title")
                            WorkingField(ledgerText("Servings")) {
                                TextField(ledgerText("Servings"), text: $servings, prompt: Text(verbatim: "—"))
                                    .keyboardType(.numbersAndPunctuation)
                                    .focused($focusedInput, equals: "servings")
                                    .submitLabel(.next)
                                    .onSubmit { advance(to: "minutes", using: scroll) }
                                    .accessibilityIdentifier("tonight.recipe.servings")
                            }
                            .dinnerInputRow($focusedInput, field: "servings")
                            .id("servings")
                            WorkingField(tonightText("Prep time in minutes (optional)")) {
                                TextField(tonightText("Prep time in minutes (optional)"), text: $minutes, prompt: Text(verbatim: "—"))
                                    .keyboardType(.numberPad)
                                    .focused($focusedInput, equals: "minutes")
                                    .accessibilityIdentifier("tonight.recipe.minutes")
                            }
                            .dinnerInputRow($focusedInput, field: "minutes")
                            .id("minutes")
                        }
                        Section(ledgerText("Ingredients")) {
                            ForEach(ingredients) { ingredient in
                                let row = dinnerDraftBinding(ingredient, in: $ingredients)
                                if let wording = ingredient.originalWording {
                                    Text(verbatim: wording).font(.subheadline).foregroundStyle(Theme.secondary)
                                }
                                WorkingField(tonightText("Ingredient")) {
                                    TextField(tonightText("Ingredient"), text: row.name, prompt: Text(verbatim: "—"))
                                        .focused($focusedInput, equals: "ingredient-\(ingredient.id)")
                                        .submitLabel(ingredient.checkedWithoutAmount ? .done : .next)
                                        .onSubmit {
                                            if ingredient.checkedWithoutAmount { focusedInput = nil }
                                            else { advance(to: ingredient.id.uuidString, using: scroll) }
                                        }
                                        .accessibilityIdentifier("tonight.recipe.ingredient")
                                }
                                .dinnerInputRow($focusedInput, field: "ingredient-\(ingredient.id)")
                                .id("ingredient-\(ingredient.id)")
                                if invalidAmountID == ingredient.id {
                                    Label(amountError(for: ingredient), systemImage: "exclamationmark.circle")
                                        .foregroundStyle(Theme.warning)
                                        .accessibilityIdentifier("tonight.recipe.amountError")
                                }
                                Toggle(tonightText("Use without a measured amount"), isOn: row.checkedWithoutAmount)
                                    .accessibilityLabel(ingredient.name.isEmpty ? tonightText("Use without a measured amount") :
                                        ingredient.name + ", " + tonightText("Use without a measured amount"))
                                    .accessibilityIdentifier("tonight.recipe.manual." + ingredient.id.uuidString)
                                    .onChange(of: ingredient.checkedWithoutAmount) { _, checked in
                                        if checked && invalidAmountID == ingredient.id { invalidAmountID = nil }
                                    }
                                if !ingredient.checkedWithoutAmount {
                                    LedgerQuantityFields(amount: row.amount, unit: row.unit,
                                    amountFocus: ($focusedInput, ingredient.id.uuidString), amountLabel: tonightText("Amount (required)"))
                                    .onChange(of: ingredient.amount) { _, _ in
                                        if invalidAmountID == ingredient.id, ingredient.positiveQuantity != nil { invalidAmountID = nil }
                                    }
                                }
                            }
                            .onDelete { ingredients.remove(atOffsets: $0) }
                            Button(tonightText("Add ingredient")) { ingredients.append(Ingredient()) }
                        }
                        Section {
                            DisclosureGroup(isExpanded: $showRestrictions) {
                                restrictionFields
                            } label: { Text(tonightText("Ingredients, brands and equipment (optional)")) }
                            .disclosureGroupStyle(LabeledFormDisclosureStyle(label: tonightText("Ingredients, brands and equipment (optional)"),
                                identifier: "tonight.recipe.restrictions"))
                        }
                        Button(tonightText("Review recipe facts")) { review(scroll) }
                            .buttonStyle(PrimaryAction())
                            .accessibilityIdentifier("tonight.recipe.review")
                    }
                    if let error { Text(error) }
                    if ledger.saving || ledger.hasPendingSave || ledger.error != nil {
                        LedgerSaveStatus(model: ledger, showsLastSave: false) {
                            if let candidate { confirmSaved(candidate) }
                        }
                    } else {
                        Text(ledgerText("Local to this iPhone")).font(.footnote)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if focusedInput != nil {
                        HStack {
                            if let nextInput {
                                Button { advance(to: nextInput, using: scroll) } label: {
                                    Text(tonightText("Next")).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("tonight.recipe.keyboardNext")
                            }
                            Spacer()
                            Button { focusedInput = nil } label: {
                                Text(ledgerText("Done")).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("tonight.recipe.keyboardDone")
                        }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal)
                        .background(.bar)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .disabled(busy)
            }
        }.navigationTitle(tonightText("Review a recipe"))
            .privacySensitive()
            .toolbar {
                if savedRecipe == nil || !authorized {
                    ToolbarItem(placement: .cancellationAction) { Button(tonightText("Cancel")) { dismiss() }.disabled(busy) }
                }
            }
            .onAppear {
                guard identity == nil else { return }
                identity = currentIdentity(); origin = ledger.sourceWorkspaceID; original = ledger.workspace
                title = template?.title ?? source?.recipe.title ?? ""
                if let template {
                    servings = ledgerAmountInput(template.servings)
                    minutes = template.leadTimeMinutes.map(String.init) ?? ""
                    ingredients = template.ingredients.map(Ingredient.init)
                    let facts = template.eligibilityEvidence
                    detailsReviewed = facts?.reviewedIngredientDetails != nil; details = facts?.reviewedIngredientDetails?.joined(separator: "\n") ?? ""
                    appliancesReviewed = facts?.requiredAppliances != nil; appliances = facts?.requiredAppliances?.joined(separator: "\n") ?? ""
                    brandsReviewed = facts?.brands != nil; brands = facts?.brands?.joined(separator: "\n") ?? ""
                    effort = facts?.effort
                    return
                }
                if let source, source.recipe.ingredients.count > 200 {
                    ingredients = []; error = tonightText("This source exceeds the supported recipe size. Review a smaller recipe in Records before continuing.")
                } else if let source {
                    servings = source.recipe.suggestedServings?.description ?? ""
                    initialSourceRows = source.recipe.ingredients.map(ImportedRecipe.ingredientDraft)
                    ingredients = initialSourceRows.map(Ingredient.init)
                } else { ingredients = [Ingredient()] }
            }
    }
    private var nextInput: String? {
        switch focusedInput {
        case "title": return "servings"
        case "servings": return "minutes"
        case "minutes": return ingredients.first.map { "ingredient-\($0.id)" }
        default:
            if let ingredient = ingredients.first(where: { "ingredient-\($0.id)" == focusedInput }), !ingredient.checkedWithoutAmount {
                return ingredient.id.uuidString
            }
            return nil
        }
    }

    private func advance(to field: String, using scroll: ScrollViewProxy) {
        scroll.scrollTo(field, anchor: .center)
        focusedInput = field
    }

    @ViewBuilder private func fact(_ label: String, _ value: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: label).font(.headline)
                Text(verbatim: value)
            }
            .accessibilityElement(children: .combine)
        } else {
            LabeledContent(label, value: value)
        }
    }

    @ViewBuilder private var restrictionFields: some View {
        Text(tonightText("Leave details unknown unless you reviewed them. Recipe details never confirm the ingredients or brand of a pantry product."))
        Toggle(tonightText("I reviewed all ingredient details"), isOn: $detailsReviewed)
        if detailsReviewed {
            TextField(tonightText("Complete ingredient details, one per line"), text: $details, axis: .vertical)
                .focused($focusedInput, equals: "details")
        }
        Toggle(tonightText("I reviewed required appliances"), isOn: $appliancesReviewed)
        if appliancesReviewed {
            TextField(tonightText("Required appliances, one per line; empty means none"), text: $appliances, axis: .vertical)
                .focused($focusedInput, equals: "appliances")
        }
        Toggle(tonightText("I reviewed recipe brands"), isOn: $brandsReviewed)
        if brandsReviewed {
            TextField(tonightText("Brands, one per line; empty means none"), text: $brands, axis: .vertical)
                .focused($focusedInput, equals: "brands")
        }
        DinnerOptionField(title: tonightText("Preparation effort")) {
            Picker(tonightText("Preparation effort"), selection: $effort) {
                Text(tonightText("Unknown")).tag(MealEffort?.none)
                ForEach(MealEffort.allCases, id: \.self) { Text(tonightText($0.rawValue)).tag(Optional($0)) }
            }
        }
    }

    private func confirmSaved(_ recipe: MealTemplate) {
        guard authorized, ledger.workspace.mealTemplates.contains(recipe) else { return }
        savedRecipe = recipe
        error = nil
    }

    private func lines(_ text: String) -> [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func amountError(for ingredient: Ingredient) -> String {
        let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return tonightText("Enter an ingredient amount greater than zero.") }
        return String(format: tonightText("Enter an amount greater than zero for %@."), name)
    }
    private func review(_ scroll: ScrollViewProxy) {
        do {
            guard (source?.recipe.ingredients.count ?? 0) <= 200, authorized, let servings = try LedgerEntry.rational(servings), servings > .zero else { throw TonightMealModel.Failure.unavailable }
            let amount = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard amount.isEmpty || Int(amount) != nil else { throw TonightMealModel.Failure.unavailable }
            var rows: [MealIngredient] = []
            for ingredient in ingredients {
                let quantity = ingredient.checkedWithoutAmount ? nil : ingredient.positiveQuantity
                guard ingredient.checkedWithoutAmount || quantity != nil else {
                    error = nil
                    invalidAmountID = ingredient.id
                    advance(to: ingredient.id.uuidString, using: scroll)
                    UIAccessibility.post(notification: .announcement, argument: amountError(for: ingredient))
                    return
                }
                let prior = template?.ingredients.first { $0.id == ingredient.id }
                rows.append(MealIngredient(id: ingredient.id, name: ingredient.name, quantity: quantity,
                    notes: prior?.notes ?? "", exclusions: prior?.exclusions ?? [], originalWording: ingredient.originalWording,
                    checkedWithoutAmount: ingredient.checkedWithoutAmount))
            }
            guard !rows.isEmpty else { throw TonightMealModel.Failure.unavailable }
            // Editing the current Free recipe preserves its identity. Reviewing
            // an accepted recipe creates a new Free copy; its original stays in
            // the accepted library and previous ledger revisions.
            let editingFree = template.flatMap { selected in original?.mealTemplates.first(where: { $0 == selected }) }
            var result = MealTemplate(id: editingFree?.id ?? UUID(), title: title, servings: servings,
                ingredients: rows, notes: template?.notes ?? source.map { [$0.recipe.yieldText, $0.recipe.notes].filter { !$0.isEmpty }.joined(separator: "\n") } ?? "",
                sourceURL: template?.sourceURL ?? source?.recipe.sourceURL, exclusions: template?.exclusions ?? [],
                revision: (editingFree?.revision ?? -1) + 1, servingGroups: template?.servingGroups ?? [],
                leadTimeMinutes: Int(amount), completedSteps: template?.completedSteps ?? [], sourceEvidence: template?.sourceEvidence)
            if let template, let steps = template.recipeSteps {
                result.recipeSteps = RecipeStep.rebinding(steps, from: template.ingredients, to: rows)
            } else if let source, !source.recipe.steps.isEmpty {
                // Each imported instruction initially targets an index in the source ingredient list.
                let sourceRows = initialSourceRows
                result.recipeSteps = RecipeStep.rebinding(source.recipe.cookingSteps, from: sourceRows, to: rows)
            }
            var evidence = MealEligibilityEvidence()
            evidence.reviewedIngredientDetails = detailsReviewed ? lines(details) : nil
            evidence.requiredAppliances = appliancesReviewed ? lines(appliances) : nil
            evidence.brands = brandsReviewed ? lines(brands) : nil
            evidence.effort = effort
            result.eligibilityEvidence = evidence
            try result.validate()
            focusedInput = nil; invalidAmountID = nil
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
                if let source, let owner = identity?.mealFeedbackOwner {
                    let sourcePin = CookSoonPin(owner: owner, recipe: .imported(source.id))
                    if workspace.cookSoonPins.contains(sourcePin) {
                        try workspace.setCookSoon(sourcePin, pinned: false)
                        try workspace.setCookSoon(.init(owner: owner, recipe: .reviewed(candidate.id)), pinned: true)
                    }
                }
            }
            if ok && authorized { confirmSaved(candidate) }
            else { error = tonightText("Recipe was not confirmed. Review changed information or the pending save.") }
        } catch { self.error = tonightText("The saved source or private workspace changed. Open the review again.") }
    }
}
