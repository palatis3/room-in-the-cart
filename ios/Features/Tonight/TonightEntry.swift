import SwiftUI
import CoreDomain
import RecordArchive
import DeviceSurfaces

extension MealIngredient {
    var reviewedAmountLabel: String {
        checkedWithoutAmount == true ? tonightText("Checked by hand · unmeasured") : ledgerQuantity(quantity)
    }
}

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
    private enum ChoiceSection: Hashable { case destination, review }
    private enum RecipeSection { case matches, needsReview }
    private struct OpenRecipe {
        let id: UUID
        let section: RecipeSection
        let index: Int
    }
    private struct IngredientAnchor: Hashable {
        let recipe: UUID
        let ingredient: UUID
    }
    @State private var openRecipe: OpenRecipe?
    @State private var requestedIngredient: IngredientAnchor?
    @State private var requestedSection: ChoiceSection?
    @AccessibilityFocusState private var focusedSection: ChoiceSection?
    @State private var choosing: MealTemplate?
    @State private var sourceToReview: TonightMealModel.Source?
    @State private var manual = false
    @State private var recipeToReview: MealTemplate?
    @State private var foodToReview: TonightMealModel.Food?
    @State private var destination: UUID?
    @State private var newTitle = ""
    @State private var newShopCurrency: Currency = .groceryDefault()
    @State private var query = ""
    @State private var pinnedOnly = false
    @State private var plannedDate = Date()
    @State private var includeMatchedProducts = true
    @State private var linkedReceipt: (shop: UUID, meal: UUID, owner: UUID)?
    @State private var preview: TonightPlanChoice.Review?
    @State private var message: String?
    @State private var applying = false
    @State private var localProductGeneration: UUID?
    @ObservedObject private var productMemoryStore = PantryDigestStore.shared.recipeProductMemory
    @ObservedObject private var packMemory = PantryDigestStore.shared.packMemory
    @ObservedObject private var home = AdultHomeSummaryStore.shared
    private var homeAccess: PantryDigestAccess? {
        guard model.batch == nil, scope != nil, let child else { return nil }
        return .current(pickup: pickup, access: access, household: household, child: child)
    }
    private func refreshHome() {
        guard model.batch == nil, let current = homeAccess, let ledgerID = ledger.sourceWorkspaceID,
              (try? home.refreshPlannedTonight(access: current, ledger: ledger, pickup: pickup)) == false else { return }
        home.refreshTonight(model, access: current, ledgerID: ledgerID) {
            try TonightHomeBasis.current(ledger: ledger, pickup: pickup)
        }
    }
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
                    plannedMeals
                    Section {
                        Text(tonightText("Set up My Pantry to review recipes against food available at home."))
                        NavigationLink(tonightText("Open My Pantry")) { PantrySetupView(pickup: pickup, ledger: ledger) }
                        Button(dinnerText("Enter your own recipe")) { manual = true }
                            .accessibilityIdentifier("tonight.addRecipe")
                    }.listRowBackground(Theme.surface)
                }.workingSurface()
            } else if let batch = model.batch, let scope, batch.originID != scope.inventory {
                Text(tonightText("This batch is no longer in the open pantry."))
            } else {
                ScrollViewReader { scroll in
                    content.task(id: requestedSection) {
                        guard let section = requestedSection else { return }
                        // The section is inserted above the recipe that opened it.
                        await Task.yield()
                        guard !Task.isCancelled, requestedSection == section else { return }
                        requestedSection = nil
                        guard choosing != nil, (preview != nil) == (section == .review) else { return }
                        scroll.scrollTo(section, anchor: .top)
                        focusedSection = section
                    }
                    .task(id: requestedIngredient) {
                        guard let anchor = requestedIngredient else { return }
                        await Task.yield()
                        guard !Task.isCancelled, openRecipe?.id == anchor.recipe, choosing == nil else { return }
                        scroll.scrollTo(anchor, anchor: .center)
                        requestedIngredient = nil
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(tonightText("Add recipe")) { manual = true }
                            .accessibilityHint(dinnerText("Enter your own recipe"))
                            .accessibilityIdentifier("tonight.addRecipe")
                    }
                }
            }
        }
        .navigationTitle(tonightText("Tonight"))
        .privacySensitive()
        .onChange(of: query) { _, _ in closeRecipe() }
        .onChange(of: pinnedOnly) { _, _ in closeRecipe() }
        .onDisappear { closeRecipe() }
        .task(id: scope) {
            closeRecipe()
            localProductGeneration = nil
            linkedReceipt = nil
            model.invalidate(); preview = nil; choosing = nil; sourceToReview = nil; manual = false; foodToReview = nil; recipeToReview = nil
            query = ""; pinnedOnly = false; message = nil; newTitle = ""; destination = nil; suggestedSecond = nil; requestedSection = nil
            if scope != nil && pickup.pantryIsActive { await refresh() }
        }
        .onChange(of: model.reviews) { _, _ in refreshHome() }
        .onChange(of: home.generation) { _, _ in refreshHome() }
        .onChange(of: ledger.workspace.dinnerPlanning.privateMealPreferences?.revision) { _, _ in
            model.invalidate(); preview = nil; choosing = nil
            Task { await refresh() }
        }
        .onChange(of: productMemoryStore.generation) { _, generation in
            preview = nil
            guard generation != localProductGeneration else { return }
            model.invalidate()
            Task { await refresh() }
        }
        .onChange(of: packMemory.generation) { _, _ in
            preview = nil
            Task { await refresh() }
        }
        .onChange(of: ledger.workspace.cookSoonPins) { _, _ in
            preview = nil
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
    @ViewBuilder private var plannedMeals: some View {
        if model.batch == nil, ledger.ready, pickup.ready, !ledger.hasPendingSave, !pickup.hasPendingSave,
           let origin = ledger.sourceWorkspaceID {
            Section {
                TimelineView(.everyMinute) { timeline in
                    if let rows = try? TonightPlannedDinners.meals(workspace: ledger.workspace, ledgerID: origin,
                        journeys: pickup.journeys, now: timeline.date, zone: .current) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(dinnerText("Private dinner plan"), systemImage: "calendar").font(.headline).foregroundStyle(Theme.action)
                                .accessibilityAddTraits(.isHeader)
                            if rows.isEmpty { Text(dinnerText("No dinner planned")).font(.title2.weight(.semibold)) }
                            ForEach(rows) { meal in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: meal.title).font(.system(.title2, design: .serif, weight: .semibold))
                                    Text(verbatim: meal.pickup).font(.body).foregroundStyle(Theme.secondary)
                                }.accessibilityElement(children: .combine)
                            }
                        }.padding(.vertical, 6)
                    } else {
                        Text(currentDinnerText("Current dinners could not be verified. Reopen the same pickup and review its saved changes."))
                    }
                }
            }.listRowBackground(Theme.surface)
        }
    }

    private var content: some View {
        List {
            Group {
                if choosing == nil, !filtering { plannedMeals }
                if model.input != nil {
                    Section {
                        PrivateRecipeSearchField(query: $query)
                        Toggle(tonightText("Show Cook soon only"), isOn: $pinnedOnly)
                    }
                }
                if filtering, model.input != nil {
                    matchedRecipes
                    recipesNeedingReview
                    if !visibleSources.isEmpty {
                        Section(tonightText("Saved sources to review")) { importedRecipes }
                    }
                    if !model.busy, !model.failed, visibleSuggestions.isEmpty, visibleReview.isEmpty, visibleSources.isEmpty,
                       !model.conflictingRecipes.contains(where: { visible($0.template) }) {
                        Text(tonightText("No matching recipes")).accessibilityIdentifier("tonight.recipeNoMatch")
                    }
                    if choosing == nil { plannedMeals }
                }
                if model.batch != nil, model.input != nil {
                    Section(tonightText("Selected batch")) {
                        if let lot = model.selectedLot {
                            LabeledContent(lot.name, value: ledgerQuantity(lot.usable))
                                .accessibilityIdentifier("tonight.batch.available")
                            Text(tonightText("Available after reservations. Match a recipe ingredient to this food to see how much it can use."))
                        } else {
                            Text(tonightText("This batch has no confirmed unreserved quantity. Check its count and reservations in My Pantry."))
                        }
                    }
                }
                NavigationLink(tonightText("Private meal preferences")) { PrivateMealPreferencesEntry(ledger: ledger) }
                    .accessibilityIdentifier("tonight.preferences")
                if model.busy { ProgressView(tonightText("Refreshing recipes and pantry…")) }
                if model.failed {
                    Section { Text(tonightText("Recipes or pantry changed or could not be read. Refresh before reviewing a meal.")) }
                }
                if let message { Section { Text(message).accessibilityIdentifier("tonight.status") } }
                if let receipt = linkedReceipt, scope?.adult.actorID == receipt.owner, pickup.currentDinnerActorID == receipt.owner,
                   ledger.shop?.id == receipt.shop, choosing == nil {
                    Section { DinnerShoppingCheckLink(shopID: receipt.shop, occurrenceID: receipt.meal, linkedProducts: true) }
                }
                if let preview {
                    Section(tonightText("Review dinner choice")) {
                        Text(preview.recipe.title).font(.system(.title2, design: .serif, weight: .semibold))
                            .id(ChoiceSection.review)
                            .accessibilityFocused($focusedSection, equals: .review)
                        Text(preview.destinationTitle)
                        Text(ledgerMealDay(preview.plannedDay))
                        Text(tonightText(preview.createsPickup ? "Apply creates a new pickup and one dinner. Cancel creates neither." : "Apply adds one dinner to this pickup."))
                        if let purchase = preview.purchaseReview {
                            Text(tonightText("Matched at home for purchase review")).font(.headline)
                            ForEach(purchase.matched) { ingredient in
                                LabeledContent(ingredient.name, value: ingredient.reviewedAmountLabel)
                            }
                            Text(dinnerText("Still to buy or check")).font(.headline)
                            if purchase.remaining.isEmpty {
                                Text(dinnerText("No additional amount needed for this dinner."))
                            }
                            ForEach(purchase.remaining) { ingredient in
                                LabeledContent(ingredient.name, value: ingredient.reviewedAmountLabel)
                            }
                            Text(tonightText("After planning, open Review pantry purchases to confirm which groceries to leave off your list."))
                        } else {
                            ForEach(preview.recipe.ingredients) { ingredient in
                                LabeledContent(ingredient.name, value: ingredient.reviewedAmountLabel)
                            }
                        }
                        TonightPricesView(estimate: preview.estimate, hasHandCheckedIngredients: preview.recipe.ingredients.contains { $0.checkedWithoutAmount == true })
                        Text(tonightText("Choosing records the full recipe need. It does not consume pantry food or reserve the matched batches."))
                        Button(tonightText("Apply dinner choice")) { Task { await apply(preview) } }.buttonStyle(PrimaryAction())
                            .disabled(applying || ledger.saving || ledger.hasPendingSave).accessibilityIdentifier("tonight.apply")
                        Button(tonightText("Cancel preview")) { self.preview = nil; choosing = nil }.disabled(applying)
                    }
                } else if let choosing {
                    Section(tonightText("Choose a destination")) {
                        Text(choosing.title).font(.system(.title2, design: .serif, weight: .semibold))
                            .id(ChoiceSection.destination)
                            .accessibilityFocused($focusedSection, equals: .destination)
                        Picker(tonightText("Pickup"), selection: $destination) {
                            Text(tonightText("Start a new pickup")).tag(UUID?.none)
                            ForEach(ledger.workspace.shops) { shop in Text(shop.title).tag(Optional(shop.id)) }
                        }
                        DatePicker(tonightText("Plan for a day"), selection: $plannedDate, displayedComponents: .date)
                            .environment(\.timeZone, destinationZone)
                        if canLinkProducts(for: choosing) {
                            Toggle(dinnerText("Link matched pantry products for purchase review"), isOn: $includeMatchedProducts)
                                .accessibilityIdentifier("tonight.includeMatchedProducts")
                        }
                        if destination == nil {
                            TextField(tonightText("New pickup name"), text: $newTitle)
                            GroceryCurrencyPicker(selection: $newShopCurrency)
                        }
                        Button(tonightText("Preview dinner choice")) { Task { await prepareChoice(choosing) } }
                            .disabled(model.busy || (destination == nil && newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        Button(tonightText("Cancel")) { self.choosing = nil }
                    }
                }
                if !filtering, model.input != nil, model.savedRecipes.isEmpty, !model.busy {
                    Section(tonightText("Save a reviewed recipe")) {
                        Text(tonightText("No reviewed recipes are available. Add a familiar recipe or review a saved import’s servings and ingredient amounts. Browsing does not start a pickup."))
                    }
                }
                if !filtering { matchedRecipes }
                if let original = scope, let ledgerID = ledger.sourceWorkspaceID {
                    if model.suggestions.contains(where: canChoose) {
                        wordingLink(following: false)
                    }
                    TonightExplanationEntry(meals: model, ledgerID: ledgerID,
                        authorize: { scope == original && !ledger.saving && !ledger.hasPendingSave },
                        refresh: { await refresh() }, choose: { recipe in
                            guard scope == original else { return }
                            beginChoice(recipe)
                        })
                }
                if !filtering { recipesNeedingReview }
                Section(tonightText("Recipe library")) {
                    RecordsRecoveryLink(accessibilityID: "tonight.records")
                    if !filtering { importedRecipes }
                    Button(tonightText("Refresh recipes and pantry")) { Task { await refresh() } }.disabled(model.busy || applying)
                        .accessibilityIdentifier("tonight.refresh")
                }
                if let current = homeAccess { AdultHomeSummaryPreference(kind: .tonight, access: current, ledgerID: ledger.sourceWorkspaceID) }
                Section {
                    if let input = model.input, input.workspace.dinnerPlanning.privateMealPreferences == nil {
                        Text(tonightText("No private preference profile is saved. Restrictions have not been checked."))
                    }
                    Text(tonightText("This view is private. It does not use a household pantry or change a shopping list while you browse."))
                }
                Section { LedgerSaveStatus(model: ledger) }
            }.listRowBackground(Theme.surface)
        }.listStyle(.insetGrouped).workingSurface()
    }
    private var filtering: Bool { pinnedOnly || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @ViewBuilder private var matchedRecipes: some View {
        if model.conflictingRecipes.contains(where: { visible($0.template) }) {
            Section(tonightText("Choose the saved recipe version")) {
                Text(tonightText("These saved copies share a recipe identity but have different facts. Select the exact source before reviewing pantry matches."))
                ForEach(model.conflictingRecipes.filter { visible($0.template) }) { source in
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
        if !visibleSuggestions.isEmpty {
            Section {
                ForEach(visibleSuggestions) { review in recipeRow(review, in: .matches) }
            } header: {
                Text(tonightText("Pantry matches to review")).accessibilityIdentifier("tonight.section.matches")
            }
        }
    }

    @ViewBuilder private var recipesNeedingReview: some View {
        if !visibleReview.isEmpty {
            Section(tonightText("Needs information or a pantry match")) {
                ForEach(visibleReview) { review in recipeRow(review, in: .needsReview) }
            }
        }
    }

    @ViewBuilder private var importedRecipes: some View {
        ForEach(visibleSources) { source in
            Button { sourceToReview = source } label: {
                VStack(alignment: .leading) {
                    Text(source.recipe.title)
                    Text(tonightText("Saved source — review servings and ingredient amounts")).font(.caption)
                }
            }.accessibilityIdentifier("tonight.source.\(source.id)")
            pinButton(.imported(source.id))
        }
    }

    private func closeRecipe() {
        requestedIngredient = nil
        openRecipe = nil
    }
    private func expansion(_ id: UUID, in section: RecipeSection) -> Binding<Bool> {
        Binding(get: { openRecipe?.id == id }, set: { expanded in
            if expanded {
                let rows = section == .matches ? visibleSuggestions : visibleReview
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                openRecipe = OpenRecipe(id: id, section: section, index: index)
            } else if openRecipe?.id == id {
                closeRecipe()
            }
        })
    }
    @ViewBuilder private func recipeRow(_ review: PantryMealMatcher.Review, in section: RecipeSection) -> some View {
        DisclosureGroup(isExpanded: expansion(review.id, in: section)) {
            NavigationLink(dinnerText("Private meal feedback")) {
                MealFeedbackEntry(ledger: ledger, source: .recipe(id: review.id, revision: review.recipe.revision),
                                  title: review.recipe.title)
            }
            Button(tonightText("Review recipe facts")) { recipeToReview = review.recipe }
            pinButton(.reviewed(review.id))
            ForEach(Array((review.eligibility.blocked + review.eligibility.unresolved + review.eligibility.softDifferences).enumerated()), id: \.offset) { _, issue in
                Text(tonightIssue(issue))
            }
            ForEach(review.recipe.ingredients) { ingredient in
                let row = review.ingredients.first { $0.id == ingredient.id }
                let foodID = model.matches[review.id]?[ingredient.id]
                VStack(alignment: .leading, spacing: 5) {
                    Text(ingredient.name).font(.headline)
                    Text(ingredient.reviewedAmountLabel)
                    if ingredient.checkedWithoutAmount != true {
                        Picker(tonightText("Reviewed pantry match"), selection: Binding(get: {
                            model.matches[review.id]?[ingredient.id]
                        }, set: { food in
                            do {
                                try model.match(recipeID: review.id, ingredientID: ingredient.id, foodID: food)
                                preview = nil
                                requestedIngredient = IngredientAnchor(recipe: review.id, ingredient: ingredient.id)
                            }
                            catch { message = tonightText("Refresh before reviewing this match.") }
                        })) {
                            Text(tonightText("Not matched")).tag(UUID?.none)
                            ForEach(model.input?.foods ?? []) { food in
                                let label = food.packLabel ?? food.name
                                let tied = model.input?.foods.contains { $0.id != food.id && ($0.packLabel ?? $0.name) == label } == true
                                Text(verbatim: tied ? label + " · " + food.detail : label).tag(Optional(food.id))
                            }
                        }.accessibilityIdentifier("tonight.match." + ingredient.id.uuidString)
                        if let foodID, let food = model.input?.foods.first(where: { $0.id == foodID }) {
                            Text(food.detail).font(.caption)
                            Button(tonightText("Review this food’s ingredient and brand details")) { foodToReview = food }
                        }
                        productMemory(review.recipe, ingredient: ingredient)
                        Text(tonightText(row?.hasUnresolvedStock == true ? "Stock count or reservation needs review." :
                            row?.covered == true ? "Covered by currently free pantry food." : "Missing or unresolved quantity — review before choosing."))
                    }
                }.id(IngredientAnchor(recipe: review.id, ingredient: ingredient.id))
            }
            if let use = review.batchUse {
                LabeledContent(tonightText("Would use from this batch"), value: ledgerQuantity(use.used))
                    .accessibilityIdentifier("tonight.batch.used." + review.id.uuidString)
                LabeledContent(tonightText("Unreserved amount left afterward"), value: ledgerQuantity(use.remaining))
                    .accessibilityIdentifier("tonight.batch.remaining." + review.id.uuidString)
                if review.canProjectRemainder {
                    if model.firstRecipeID == review.id {
                        followingMeals(after: review)
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
                ForEach(review.ingredients.filter { !$0.covered && $0.ingredient.checkedWithoutAmount != true }) { row in
                    Text(tonightText("Missing or not credited") + ": " + row.ingredient.name + " · " +
                        ledgerQuantity(TonightMealModel.missingQuantity(row)))
                        .accessibilityIdentifier("tonight.shortfall." + row.id.uuidString)
                }
                Button(tonightText("Plan for a day")) {
                    beginChoice(review.recipe)
                }.disabled(!canChoose(review) || model.busy || applying)
                    .accessibilityIdentifier("tonight.choose.\(review.id)")
            }
            if let minutes = review.recipe.leadTimeMinutes { Text(tonightText("Reviewed preparation minutes") + ": \(minutes)") }
            else { Text(tonightText("Preparation time has not been reviewed.")) }
            if review.eligibility.eligible, let input = model.input, let ledgerID = ledger.sourceWorkspaceID {
                TonightPricesView(estimate: try? TonightPurchaseEstimate.estimate(review, workspace: input.workspace,
                    workspaceID: ledgerID, shopID: input.workspace.selectedShopID, at: Date()), hasHandCheckedIngredients: review.hasHandCheckedIngredients)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(review.recipe.title).font(.system(.title3, design: .serif, weight: .semibold))
                Text(tonightText(!review.eligibility.eligible ? "Review restrictions and missing information" :
                    review.allIngredientsCovered ? "Ingredients covered — review to choose" :
                    review.measuredIngredientsCovered ? "Measured ingredients covered" : "Review ingredient matches and missing amounts"))
                    .font(.body).foregroundStyle(Theme.secondary)
            }.padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tonight.result." + review.id.uuidString)
        }
    }
    @ViewBuilder private func productMemory(_ recipe: MealTemplate, ingredient: MealIngredient) -> some View {
        if let key = model.matchKey(recipe: recipe, ingredient: ingredient) {
            let stored = model.storedProduct(key)
            let next = model.rememberedCandidate(recipe: recipe, ingredient: ingredient)
            if let next, next != stored {
                Button {
                    Task { await updateProduct(recipe: recipe, ingredient: ingredient, key: key, previous: stored, next: next) }
                } label: {
                    Text(tonightText(stored == nil ? "Remember for this recipe" : "Change remembered product"))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.borderless)
                .accessibilityIdentifier("tonight.remember." + ingredient.id.uuidString)
            }
            if let stored {
                Text(tonightText(next == stored ? "Remembered for this recipe" : "Review the remembered product against current stock."))
                    .font(.subheadline)
                Button {
                    Task { await updateProduct(recipe: recipe, ingredient: ingredient, key: key, previous: stored, next: nil) }
                } label: {
                    Text(tonightText("Forget remembered product"))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.borderless)
                    .accessibilityIdentifier("tonight.forget." + ingredient.id.uuidString)
            }
        }
    }
    @MainActor private func updateProduct(recipe: MealTemplate, ingredient: MealIngredient, key: RecipeProductMatch.Key,
                                          previous: RecipeProductMatch?, next: RecipeProductMatch?) async {
        guard let original = scope, let input = model.input, !applying else { return }
        preview = nil
        applying = true
        defer { applying = false }
        let packGeneration = packMemory.generation
        let authorized = { (next == nil || packMemory.generation == packGeneration) && scope == original && key.owner == original.adult.mealFeedbackOwner && key.pantryID == original.inventory }
        do {
            if next != nil {
                await refresh()
                guard model.input == input, model.rememberedCandidate(recipe: recipe, ingredient: ingredient) == next
                else { throw TonightMealModel.Failure.stale }
            }
            guard ledger.workspace == input.workspace, ledger.ready, !ledger.saving, !ledger.hasPendingSave else {
                throw TonightMealModel.Failure.stale
            }
            let memory = PantryDigestStore.shared.recipeProductMemory
            try memory.replace(previous, with: next,
                scope: .init(ledger: original.ledger, pantry: original.inventory, owner: key.owner), authorized: authorized)
            localProductGeneration = memory.generation
            if next == nil { model.clearSelectionAfterForgetting(key) }
            await refresh()
            if openRecipe?.id == recipe.id {
                requestedIngredient = IngredientAnchor(recipe: recipe.id, ingredient: ingredient.id)
            }
        } catch { message = tonightText("Refresh before reviewing this match.") }
    }
    @ViewBuilder private func followingMeals(after first: PantryMealMatcher.Review) -> some View {
        Text(tonightText("If you make the first meal")).font(.headline)
        Text(tonightText("The second meal uses the remaining pantry food. Its cost includes only extra packages beyond those needed for the first meal."))
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
                        .accessibilityIdentifier("tonight.batch.secondRemaining." + next.id.uuidString)
                }
                if let minutes = next.recipe.leadTimeMinutes {
                    LabeledContent(tonightText("Reviewed preparation minutes"), value: minutes.formatted())
                } else {
                    Text(tonightText("Preparation time has not been reviewed."))
                }
                ForEach(Array(next.eligibility.softDifferences.enumerated()), id: \.offset) { _, issue in
                    Text(tonightIssue(issue))
                }
                ForEach(next.ingredients.filter { !$0.covered && $0.ingredient.checkedWithoutAmount != true }) { row in
                    LabeledContent(row.ingredient.name, value: ledgerQuantity(TonightMealModel.missingQuantity(row)))
                }
                if let input = model.input, let workspaceID = ledger.sourceWorkspaceID {
                    SecondMealPricesView(first: first, second: next, input: input, workspaceID: workspaceID,
                                         ledgerRevision: ledger.revision, pairingRevision: model.pairingRevision)
                }
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("tonight.batch.second.\(next.id)")
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
                    beginChoice(chosen.recipe)
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
            guard authorized(), await pickup.refreshPantryStock(waitForShelf: true), authorized(),
                  let context = try pickup.pantryReviewContext() else { throw TonightMealModel.Failure.unavailable }
            let workspace = ledger.workspace, revision = ledger.revision
            let sources = try await TonightRecipeLibrary.read(authorize: authorized)
            guard authorized(), workspace == ledger.workspace, revision == ledger.revision else { throw TonightMealModel.Failure.stale }
            let packs = try? packMemory.recent(.init(origin: original.inventory, identity: original.adult))
            var input = try TonightMealModel.input(workspace: workspace, ledgerRevision: revision, context: context, sources: sources,
                                                   confirmedPacks: packs)
            let owner = original.adult.mealFeedbackOwner
            input.feedbackOwner = owner
            input.rememberedProducts = (try? PantryDigestStore.shared.recipeProductMemory.records(
                .init(ledger: original.ledger, pantry: original.inventory, owner: owner), in: workspace)) ?? []
            return input
        }
    }
    private var destinationZone: TimeZone {
        let zone = ledger.workspace.shops.first(where: { $0.id == destination })?.basis.timeZoneIdentifier
        return zone.flatMap(TimeZone.init(identifier:)) ?? .current
    }
    private func visiblePin(_ id: CookSoonPin.Recipe) -> Bool {
        guard pinnedOnly else { return true }
        guard let owner = scope?.adult.mealFeedbackOwner else { return false }
        return ledger.workspace.cookSoonPins.contains(.init(owner: owner, recipe: id))
    }
    private func visible(_ template: MealTemplate) -> Bool {
        visiblePin(.reviewed(template.id)) && template.matchesRecipeSearch(query)
    }
    private var visibleSuggestions: [PantryMealMatcher.Review] { visibleRows(model.suggestions, in: .matches) }
    private var visibleReview: [PantryMealMatcher.Review] { visibleRows(model.needsReview, in: .needsReview) }
    private func visibleRows(_ ranked: [PantryMealMatcher.Review], in section: RecipeSection) -> [PantryMealMatcher.Review] {
        var rows = ranked.filter { visible($0.recipe) && $0.id != openRecipe?.id }
        // Matching can move a recipe to the other section. Keep this disclosure in its current
        // list slot until it closes, while displaying its live stock and eligibility.
        if let openRecipe, openRecipe.section == section,
           let review = model.reviews.first(where: { $0.id == openRecipe.id }), review.recipe.matchesRecipeSearch(query) {
            rows.insert(review, at: min(openRecipe.index, rows.count))
        }
        return rows
    }
    private var visibleSources: [TonightMealModel.Source] {
        (model.input?.sources ?? []).filter {
            visiblePin(.imported($0.id)) && PrivateRecipeSearch.matches(query, title: $0.recipe.title, ingredients: $0.recipe.ingredients)
        }
    }
    @ViewBuilder private func pinButton(_ recipe: CookSoonPin.Recipe) -> some View {
        if let original = scope {
            RecipePinButton(ledger: ledger, recipe: recipe, owner: original.adult.mealFeedbackOwner,
                            authorize: { scope == original })
        }
    }
    private func canLinkProducts(for recipe: MealTemplate) -> Bool {
        guard let scope, let input = model.input, input.workspace == ledger.workspace,
              let context = try? pickup.pantryReviewContext(), context.dinnerBasis == input.basis,
              let match = model.reviews.first(where: { $0.recipe == recipe }) else { return false }
        return TonightPlanChoice.canLinkProducts(match: match, basis: input.basis, destination: destination,
            workspace: ledger.workspace, pickup: pickup, identity: scope.adult, reservedFoods: context.reservedFoods)
    }

    private func beginChoice(_ recipe: MealTemplate) {
        linkedReceipt = nil
        closeRecipe()
        plannedDate = Date()
        choosing = recipe
        newShopCurrency = .groceryDefault()
        includeMatchedProducts = true
        destination = ledger.workspace.selectedShopID
        preview = nil
        message = nil
        requestedSection = .destination
    }

    @MainActor private func prepareChoice(_ recipe: MealTemplate) async {
        guard let original = model.input, let originalScope = scope else { return }
        let matches = model.matches[recipe.id, default: [:]]
        let selectedDestination = destination, selectedPreference = includeMatchedProducts
        let selectedCurrency = newShopCurrency
        let includeProducts = selectedPreference && canLinkProducts(for: recipe)
        await refresh()
        guard choosing == recipe, destination == selectedDestination, includeMatchedProducts == selectedPreference,
              destination != nil || newShopCurrency == selectedCurrency else { return }
        do {
            guard scope == originalScope else { throw TonightMealModel.Failure.unavailable }
            try model.assertCurrent(original, recipe: recipe, matches: matches)
            guard let review = model.reviews.first(where: { $0.recipe == recipe }), canChoose(review) else { throw TonightMealModel.Failure.stale }
            preview = try TonightPlanChoice.prepare(match: review, pantryBasis: original.basis,
                destinationShopID: destination, newShopTitle: newTitle, newShopCurrency: newShopCurrency, ledger: ledger, pickup: pickup,
                plannedDate: plannedDate, includeMatchedProducts: includeProducts, currentIdentity: currentIdentity)
            requestedSection = .review
        } catch { preview = nil; message = tonightText("The recipe, preferences, pantry or destination changed. Review the current information again.") }
    }
    @MainActor private func apply(_ review: TonightPlanChoice.Review) async {
        guard !applying, let startingScope = scope else { return }
        applying = true
        let ok = await TonightPlanChoice.apply(review, ledger: ledger, pickup: pickup, currentIdentity: currentIdentity)
        applying = false
        guard scope == startingScope else { return }
        if ok {
            if case .choose(let meal) = review.preview.proposal.changes.first, meal.pantryProducts != nil {
                linkedReceipt = (review.preview.proposal.shopID, meal.occurrenceID, startingScope.adult.actorID)
            }
            preview = nil; choosing = nil; message = tonightText("One dinner was added to your pickup."); await refresh()
        }
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
