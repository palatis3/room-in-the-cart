import SwiftUI
import CoreDomain
import RecordArchive

func tonightText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Tonight") }

/// Both tabs enter the same private workspace. No selected pickup is required.
struct TonightEntry: View {
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @StateObject private var model: TonightMealModel

    init(batch: TonightMealModel.Batch? = nil) {
        _model = StateObject(wrappedValue: TonightMealModel(batch: batch))
    }
    @State private var suggestedSecond: PantryMealMatcher.Review?
    @State private var choosing: MealTemplate?
    @State private var sourceToReview: TonightMealModel.Source?
    @State private var manual = false
    @State private var recipeToReview: MealTemplate?
    @State private var foodToReview: TonightMealModel.Food?
    @State private var destination: UUID?
    @State private var newTitle = ""
    @State private var preview: TonightPlanChoice.Review?
    @State private var message: String?
    @State private var applying = false
    private struct Scope: Equatable {
        let adult: CapturePrivateIdentity
        let inventory: UUID
        let ledger: UUID
        let generation: UUID
    }
    private var scope: Scope? {
        guard scene == .active, UIApplication.shared.isProtectedDataAvailable,
              UIApplication.shared.applicationState == .active,
              child?.presented != true, household.projection?.grantId == nil,
              let adult = CapturePrivateIdentity.current(access: access, household: household),
              let inventory = pickup.sourceWorkspaceID, let ledgerID = ledger.sourceWorkspaceID,
              pickup.pantryRouteAvailable else { return nil }
        return Scope(adult: adult, inventory: inventory, ledger: ledgerID, generation: pickup.privatePantryGeneration)
    }
    var body: some View {
        Group {
            if scope == nil {
                Text(tonightText("Unlock your private workspace to review tonight’s meals."))
            } else if !pickup.pantryIsActive {
                List {
                    Text(tonightText("Set up My Pantry to review recipes against food available at home."))
                    NavigationLink(tonightText("Open My Pantry")) { PantrySetupView(pickup: pickup, ledger: ledger) }
                }
            } else if let batch = model.batch, let scope, batch.originID != scope.inventory {
                Text(tonightText("This batch is no longer in the open pantry."))
            } else {
                content
            }
        }
        .navigationTitle(tonightText("Tonight"))
        .privacySensitive()
        .task(id: scope) {
            model.invalidate(); preview = nil; choosing = nil; sourceToReview = nil; manual = false; foodToReview = nil; recipeToReview = nil
            if scope != nil && pickup.pantryIsActive { await refresh() }
        }
        .onChange(of: ledger.workspace.dinnerPlanning.privateMealPreferences?.revision) { _, _ in
            model.invalidate(); preview = nil; choosing = nil
            Task { await refresh() }
        }
        .onChange(of: ledger.workspace.privateMealFeedback) { _, _ in
            preview = nil
            Task { await refresh() }
        }
        .sheet(item: $foodToReview) { food in
            if let original = model.input, let originalScope = scope {
                NavigationStack {
                    TonightFoodReview(food: food, authorize: { scope == originalScope }) { evidence in
                        try model.reviewFood(food, evidence: evidence, original: original)
                    }
                }
            }
        }
        .sheet(item: $recipeToReview, onDismiss: { Task { await refresh() } }) { recipe in
            NavigationStack { TonightRecipeReview(ledger: ledger, source: nil, template: recipe, currentIdentity: currentIdentity) }
        }
        .sheet(isPresented: $manual, onDismiss: { Task { await refresh() } }) {
            NavigationStack { TonightRecipeReview(ledger: ledger, source: nil, currentIdentity: currentIdentity) }
        }
        .sheet(item: $sourceToReview, onDismiss: { Task { await refresh() } }) { source in
            NavigationStack { TonightRecipeReview(ledger: ledger, source: source, currentIdentity: currentIdentity) }
        }
    }
    private var content: some View {
        List {
            if model.batch != nil, model.input != nil {
                Section(tonightText("Selected batch")) {
                    if let lot = model.selectedLot {
                        LabeledContent(lot.name, value: ledgerQuantity(lot.usable))
                        Text(tonightText("Available after reservations. Match a recipe ingredient to this food to see how much it can use."))
                    } else {
                        Text(tonightText("This batch has no confirmed unreserved quantity. Check its count and reservations in My Pantry."))
                    }
                }
            }
            Section {
                NavigationLink(tonightText("Private meal preferences")) { PrivateMealPreferencesEntry(ledger: ledger) }
                    .accessibilityIdentifier("tonight.preferences")
                Text(tonightText("Review your private preferences first, then match recipe ingredients to pantry food. Food reserved for other plans is already excluded."))
                if model.input?.workspace.dinnerPlanning.privateMealPreferences == nil {
                    Text(tonightText("No private preference profile is saved. Restrictions have not been checked."))
                }
                Text(tonightText("This view is private. It does not use a household pantry or change a shopping list while you browse."))
            }
            if model.busy { ProgressView(tonightText("Refreshing recipes and pantry…")) }
            if model.failed {
                Section { Text(tonightText("Recipes or pantry changed or could not be read. Refresh before reviewing a meal.")) }
            }
            if let message { Section { Text(message).accessibilityIdentifier("tonight.status") } }
            if let preview {
                Section(tonightText("Review dinner choice")) {
                    Text(preview.recipe.title).font(.headline)
                    Text(preview.destinationTitle)
                    Text(tonightText(preview.createsPickup ? "Apply creates a new pickup and one dinner. Cancel creates neither." : "Apply adds one dinner to this pickup."))
                    ForEach(preview.recipe.ingredients) { ingredient in
                        LabeledContent(ingredient.name, value: ledgerQuantity(ingredient.quantity))
                    }
                    TonightPricesView(estimate: preview.estimate)
                    Text(tonightText("Choosing records the full recipe need. It does not consume pantry food or reserve the matched batches."))
                    Button(tonightText("Apply dinner choice")) { Task { await apply(preview) } }
                        .disabled(applying || ledger.saving || ledger.hasPendingSave).accessibilityIdentifier("tonight.apply")
                    Button(tonightText("Cancel preview")) { self.preview = nil; choosing = nil }.disabled(applying)
                }
            } else if let choosing {
                Section(tonightText("Choose a destination")) {
                    Text(choosing.title).font(.headline)
                    Picker(tonightText("Pickup"), selection: $destination) {
                        Text(tonightText("Start a new pickup")).tag(UUID?.none)
                        ForEach(ledger.workspace.shops) { shop in Text(shop.title).tag(Optional(shop.id)) }
                    }
                    if destination == nil { TextField(tonightText("New pickup name"), text: $newTitle) }
                    Button(tonightText("Preview dinner choice")) { Task { await prepareChoice(choosing) } }
                        .disabled(model.busy || (destination == nil && newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    Button(tonightText("Cancel")) { self.choosing = nil }
                }
            }
            if model.input != nil && model.savedRecipes.isEmpty && !model.busy {
                Section(tonightText("Save a reviewed recipe")) {
                    Text(tonightText("No reviewed recipes are available. Add a familiar recipe or review a saved import’s servings and ingredient amounts. Browsing does not start a pickup."))
                }
            }
            if !model.conflictingRecipes.isEmpty {
                Section(tonightText("Choose the saved recipe version")) {
                    Text(tonightText("These saved copies share a recipe identity but have different facts. Select the exact source before reviewing pantry matches."))
                    ForEach(model.conflictingRecipes) { source in
                        VStack(alignment: .leading) {
                            Text(source.template.title).font(.headline)
                            Text(source.acceptedAt.map { tonightText("Accepted dinner") + " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? tonightText("Free reusable dinner"))
                            Text(tonightText("Recipe revision") + ": " + source.template.revision.formatted())
                            Button(tonightText("Use this saved version")) {
                                do { try model.selectVersion(source); preview = nil; choosing = nil }
                                catch { message = tonightText("Refresh before reviewing this match.") }
                            }
                            Button(tonightText("Review recipe facts")) { recipeToReview = source.template }
                        }
                    }
                }
            }
            if !model.suggestions.isEmpty {
                Section(tonightText("Pantry matches to review")) {
                    ForEach(model.suggestions) { review in recipeRow(review) }
                }
            }
            if let original = scope, let ledgerID = ledger.sourceWorkspaceID {
                if model.suggestions.contains(where: canChoose) {
                    wordingLink(following: false)
                }
                TonightExplanationEntry(meals: model, ledgerID: ledgerID,
                    authorize: { scope == original && !ledger.saving && !ledger.hasPendingSave },
                    refresh: { await refresh() }, choose: { recipe in
                        guard scope == original else { return }
                        choosing = recipe; destination = ledger.workspace.selectedShopID; preview = nil; message = nil
                    })
            }
            if !model.needsReview.isEmpty {
                Section(tonightText("Needs information or a pantry match")) {
                    ForEach(model.needsReview) { review in recipeRow(review) }
                }
            }
            Section(tonightText("Recipe library")) {
                Button(tonightText("Review a recipe by hand")) { manual = true }
                RecordsRecoveryLink(accessibilityID: "tonight.records")
                ForEach(model.input?.sources ?? []) { source in
                    Button { sourceToReview = source } label: {
                        VStack(alignment: .leading) {
                            Text(source.recipe.title)
                            Text(tonightText("Saved source — review servings and ingredient amounts")).font(.caption)
                        }
                    }.accessibilityIdentifier("tonight.source.\(source.id)")
                }
                Button(tonightText("Refresh recipes and pantry")) { Task { await refresh() } }.disabled(model.busy || applying)
                    .accessibilityIdentifier("tonight.refresh")
            }
            Section { LedgerSaveStatus(model: ledger) }
        }.listStyle(.insetGrouped).workingSurface()
    }
    @ViewBuilder private func recipeRow(_ review: PantryMealMatcher.Review) -> some View {
        DisclosureGroup {
            NavigationLink(dinnerText("Private meal feedback")) {
                MealFeedbackEntry(ledger: ledger, source: .recipe(id: review.id, revision: review.recipe.revision),
                                  title: review.recipe.title)
            }
            Button(tonightText("Review recipe facts")) { recipeToReview = review.recipe }
            ForEach(Array((review.eligibility.blocked + review.eligibility.unresolved + review.eligibility.softDifferences).enumerated()), id: \.offset) { _, issue in
                Text(tonightIssue(issue))
            }
            ForEach(review.recipe.ingredients) { ingredient in
                let row = review.ingredients.first { $0.id == ingredient.id }
                let foodID = model.matches[review.id]?[ingredient.id]
                VStack(alignment: .leading, spacing: 5) {
                    Text(ingredient.name).font(.headline)
                    Text(ledgerQuantity(ingredient.quantity))
                    Picker(tonightText("Reviewed pantry match"), selection: Binding(get: {
                        model.matches[review.id]?[ingredient.id]
                    }, set: { food in
                        do { try model.match(recipeID: review.id, ingredientID: ingredient.id, foodID: food); preview = nil }
                        catch { message = tonightText("Refresh before reviewing this match.") }
                    })) {
                        Text(tonightText("Not matched")).tag(UUID?.none)
                        ForEach(model.input?.foods ?? []) { food in Text(food.name).tag(Optional(food.id)) }
                    }
                    if let foodID, let food = model.input?.foods.first(where: { $0.id == foodID }) {
                        Text(food.detail).font(.caption)
                        Button(tonightText("Review this food’s ingredient and brand details")) { foodToReview = food }
                    }
                    Text(tonightText(row?.hasUnresolvedStock == true ? "Stock count or reservation needs review." :
                        row?.covered == true ? "Covered by currently free pantry food." : "Missing or unresolved quantity — review before choosing."))
                }
            }
            if let use = review.batchUse {
                LabeledContent(tonightText("Would use from this batch"), value: ledgerQuantity(use.used))
                LabeledContent(tonightText("Unreserved amount left afterward"), value: ledgerQuantity(use.remaining))
                if review.canProjectRemainder {
                    if model.firstRecipeID == review.id {
                        followingMeals
                        Button(tonightText("Close second-meal suggestions")) { model.clearPairing() }
                    } else {
                        Button(tonightText("Find a second meal for the remainder")) {
                            do { try model.showFollowingMeals(after: review.id) }
                            catch { message = tonightText("Refresh before reviewing this match.") }
                        }.accessibilityIdentifier("tonight.batch.followUp.\(review.id)")
                    }
                }
            }
            if review.eligibility.eligible {
                Text(tonightText("Similar names are not a match until you review them. Unknown quantities do not count as available."))
                ForEach(review.ingredients.filter { !$0.covered }) { row in
                    Text(tonightText("Missing or not credited") + ": " + row.ingredient.name + " · " +
                        ledgerQuantity(TonightMealModel.missingQuantity(row)))
                }
                Button(tonightText("Choose…")) {
                    choosing = review.recipe; destination = ledger.workspace.selectedShopID; preview = nil; message = nil
                }.disabled(!canChoose(review) || model.busy || applying)
                    .accessibilityIdentifier("tonight.choose.\(review.id)")
            }
            if let minutes = review.recipe.leadTimeMinutes { Text(tonightText("Reviewed preparation minutes") + ": \(minutes)") }
            else { Text(tonightText("Preparation time has not been reviewed.")) }
            if review.eligibility.eligible, let input = model.input, let ledgerID = ledger.sourceWorkspaceID {
                TonightPricesView(estimate: try? TonightPurchaseEstimate.estimate(review, workspace: input.workspace,
                    workspaceID: ledgerID, shopID: input.workspace.selectedShopID, at: Date()))
            }
        } label: {
            VStack(alignment: .leading) {
                Text(review.recipe.title).font(.headline)
                Text(tonightText(!review.eligibility.eligible ? "Review restrictions and missing information" :
                    review.allIngredientsCovered ? "Ingredients covered — review to choose" : "Review ingredient matches and missing amounts"))
                    .font(.caption)
            }
        }
    }
    @ViewBuilder private var followingMeals: some View {
        Text(tonightText("If you make the first meal")).font(.headline)
        Text(tonightText("These estimates use the pantry food left after the first recipe’s reviewed matches. Prices cover the second meal separately."))
            .font(.caption)
        if model.followingMeals.isEmpty {
            Text(tonightText("No other reviewed recipe uses this remainder yet. Check the ingredient matches in your recipe library."))
        }
        if !model.followingMeals.isEmpty { wordingLink(following: true) }
        let ordered = model.followingMeals.sorted { $0 == suggestedSecond && $1 != suggestedSecond }
        ForEach(ordered) { next in
            VStack(alignment: .leading, spacing: 6) {
                Text(next.recipe.title).font(.headline)
                if next == suggestedSecond { Text(mealExplanationText("Selected for local review")) }
                if let use = next.batchUse {
                    LabeledContent(tonightText("Would use from this batch"), value: ledgerQuantity(use.used))
                    LabeledContent(tonightText("Unreserved amount left afterward"), value: ledgerQuantity(use.remaining))
                }
                if let minutes = next.recipe.leadTimeMinutes {
                    LabeledContent(tonightText("Reviewed preparation minutes"), value: minutes.formatted())
                } else {
                    Text(tonightText("Preparation time has not been reviewed."))
                }
                ForEach(Array(next.eligibility.softDifferences.enumerated()), id: \.offset) { _, issue in
                    Text(tonightIssue(issue))
                }
                ForEach(next.ingredients.filter { !$0.covered }) { row in
                    LabeledContent(row.ingredient.name, value: ledgerQuantity(TonightMealModel.missingQuantity(row)))
                }
                if let input = model.input, let workspaceID = ledger.sourceWorkspaceID {
                    TonightPricesView(estimate: try? TonightPurchaseEstimate.estimate(next, workspace: input.workspace,
                        workspaceID: workspaceID, shopID: input.workspace.selectedShopID, at: Date()))
                }
            }.accessibilityIdentifier("tonight.batch.second.\(next.id)")
        }
    }
    private func wordingLink(following: Bool) -> some View {
        MealChoiceWordingLink(refresh: {
            await refresh()
            return scope != nil && !model.failed && !applying
        }, makeSource: {
            guard let original = scope, let ledgerID = ledger.sourceWorkspaceID else { throw TonightMealModel.Failure.stale }
            return try MealChoiceSource.tonight(model, ledgerID: ledgerID, following: following,
                authorized: { scope == original && !applying }) { chosen in
                if following {
                    // This is hypothetical stock left after the first meal. Retain the ordinary second-meal comparison.
                    suggestedSecond = chosen
                } else {
                    choosing = chosen.recipe; destination = ledger.workspace.selectedShopID; preview = nil; message = nil
                }
            }
        })
    }

    private func canChoose(_ review: PantryMealMatcher.Review) -> Bool {
        TonightMealModel.canChoose(review) && (model.batch == nil || review.batchUse?.lotID == model.batch?.lotID)
    }
    private func currentIdentity() -> CapturePrivateIdentity? { scope?.adult }
    @MainActor private func refresh() async {
        guard let original = scope, ledger.ready, !ledger.saving, !ledger.hasPendingSave else { return }
        guard model.batch == nil || model.batch?.originID == original.inventory else { return }
        let authorized = { scope == original && !Task.isCancelled }
        await model.refresh(authorize: authorized) {
            guard authorized(), await pickup.refreshPantryStock(), authorized(),
                  let context = try pickup.pantryReviewContext() else { throw TonightMealModel.Failure.unavailable }
            let workspace = ledger.workspace, revision = ledger.revision
            let sources = try await TonightRecipeLibrary.read(authorize: authorized)
            guard authorized(), workspace == ledger.workspace, revision == ledger.revision else { throw TonightMealModel.Failure.stale }
            var input = try TonightMealModel.input(workspace: workspace, ledgerRevision: revision, context: context, sources: sources)
            input.feedbackOwner = original.adult.mealFeedbackOwner
            return input
        }
    }
    @MainActor private func prepareChoice(_ recipe: MealTemplate) async {
        guard let original = model.input, let originalScope = scope else { return }
        let matches = model.matches[recipe.id, default: [:]]
        await refresh()
        do {
            guard scope == originalScope else { throw TonightMealModel.Failure.unavailable }
            try model.assertCurrent(original, recipe: recipe, matches: matches)
            guard let review = model.reviews.first(where: { $0.recipe == recipe }), canChoose(review) else { throw TonightMealModel.Failure.stale }
            preview = try TonightPlanChoice.prepare(match: review, pantryBasis: original.basis,
                destinationShopID: destination, newShopTitle: newTitle, ledger: ledger, pickup: pickup,
                currentIdentity: currentIdentity)
        } catch { preview = nil; message = tonightText("The recipe, preferences, pantry or destination changed. Review the current information again.") }
    }
    @MainActor private func apply(_ review: TonightPlanChoice.Review) async {
        guard !applying, scope != nil else { return }
        applying = true
        let ok = await TonightPlanChoice.apply(review, ledger: ledger, pickup: pickup, currentIdentity: currentIdentity)
        applying = false
        guard scope != nil else { model.invalidate(); preview = nil; return }
        if ok { preview = nil; choosing = nil; message = tonightText("One dinner was added to your pickup."); await refresh() }
        else { message = tonightText("Dinner was not confirmed. Review changed information or retry the pending save.") }
    }
}

func tonightIssue(_ issue: MealEligibilityPolicy.Issue) -> String {
    switch issue {
    case .excluded(let term): tonightText("Excluded ingredient") + ": " + term
    case .disliked(let term): tonightText("Preference difference") + ": " + term
    case .appliancesUnavailable(let items): tonightText("Unavailable appliances") + ": " + items.joined(separator: ", ")
    case .brandMismatch: tonightText("Brand preferences differ.")
    case .durationAboveLimit: dinnerText("Total preparation time exceeds your available time.")
    case .durationUnknown: dinnerText("Total elapsed preparation time is unknown.")
    case .effortAboveLimit: tonightText("Preparation effort exceeds your preference.")
    case .ingredientsUnknown: tonightText("Ingredient details need review for your restrictions.")
    case .appliancesUnknown: tonightText("Required appliances have not been reviewed.")
    case .brandsUnknown: tonightText("Brand details have not been reviewed.")
    case .effortUnknown: tonightText("Preparation effort has not been reviewed.")
    }
}
