import SwiftUI
import HouseholdClient

struct HouseholdTonightReturn {
    let recipeID: UUID
    let session: HouseholdPantrySession
    let subject: String
    let generation: UUID
    let grantEpoch: Int
    let expires: Date
}

struct HouseholdTonightLink: View {
    @ObservedObject var household: HouseholdModel
    var body: some View {
        if household.projection?.canBrowseHouseholdTonight == true, let scope = household.householdPantryScope {
            NavigationLink(tonightText("Household Tonight")) {
                HouseholdTonightView(household: household, scope: scope)
            }.accessibilityIdentifier("household.tonight")
        }
    }
}

private struct HouseholdTonightView: View {
    @ObservedObject var household: HouseholdModel
    let scope: HouseholdPantryRuntime
    @Environment(\.scenePhase) private var scene
    @State private var session: HouseholdPantrySession?
    @State private var page: HouseholdTonightPage?
    @State private var selection: HouseholdTonightPage.Recipe?
    @State private var preview: Preview?
    @State private var day = sharedMealPickerToday()
    @State private var notice: String?
    @State private var busy = false
    @State private var generation = UUID()
    @State private var recipeLots: [HouseholdPantryPage.Lot] = []
    @State private var editingRecipe = false
    @State private var originalRecipe: HouseholdTonightPage.EditableRecipe?
    @State private var recipeWrite: HouseholdTonightRecipeWrite?
    @State private var managingShop = false
    @State private var choosingShop = false

    private struct Preview {
        let recipe: HouseholdTonightPage.Recipe
        let page: HouseholdTonightPage
        let shop: ShopperShop
        let day: String
        let occurrence = UUID()
    }

    private var live: Bool {
        scene == .active && UIApplication.shared.isProtectedDataAvailable && household.projection?.canBrowseHouseholdTonight == true && household.householdPantryScope == scope
    }
    var body: some View {
        Group {
            if live {
                JournalList {
                    Section {
                        Text(verbatim: household.projection?.household.label ?? "").font(.headline)
                        Text(tonightText("Only recipes reviewed for this household and food available after reservations are shown here."))
                    }
                    if let notice { Text(notice).accessibilityIdentifier("householdTonight.notice") }
                    if busy { ProgressView() }
                    if let page {
                        if let preview { confirmation(preview) }
                        else if let selection { destination(selection, page: page) }
                        else { browse(page) }
                    } else if !busy {
                        Button(ht("Refresh household")) { Task { await load() } }
                    }
                }
            } else { Text(ht("Refresh the household and check meal planning access.")) }
        }
        .navigationTitle(tonightText("Household Tonight")).privacySensitive()
        .task(id: live) { reset(); if live { await load() } }
        .onDisappear { reset() }
        .sheet(isPresented: $editingRecipe, onDismiss: { if live { Task { await load() } } }) {
            if live, let page, page.canReviewRecipes {
                NavigationStack {
                    HouseholdTonightRecipeEditor(householdName: household.projection?.household.label ?? "", lots: recipeLots, original: originalRecipe?.reviewedRecipe) { meal, evidence, lots, labels in
                        try await save(meal, evidence: evidence, lots: lots, labels: labels, page: page)
                    }
                }
            }
        }
        .sheet(isPresented: $choosingShop, onDismiss: { if live { Task { await load() } } }) {
            NavigationStack { HouseholdShopSelector(household: household) }
        }
        .sheet(isPresented: $managingShop, onDismiss: { if live { Task { await load() } } }) {
            NavigationStack { HouseholdShopView(model: household)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Close")) { managingShop = false } } } }
        }
    }

    @ViewBuilder private func browse(_ page: HouseholdTonightPage) -> some View {
        Section {
            if let date = serviceDate(page.asOf) { LabeledContent(ht("Previously confirmed"), value: date.formatted()) }
            if page.recipes.isEmpty {
                Text(tonightText("No household recipes are available for tonight."))
                if !page.canReviewRecipes { Text(tonightText("Ask a household organizer to review a recipe or update its ingredient details.")) }
            }
            if page.excludedCount > 0 { LabeledContent(tonightText("Recipes excluded by household restrictions"), value: page.excludedCount.formatted()) }
            if page.canReviewRecipes {
                Button(tonightText("Review a household recipe")) { Task { await openRecipe(page) } }.disabled(busy)
                    .accessibilityIdentifier("householdTonight.recipe.new")
            }
            Button(tonightText("Refresh recipes and pantry")) { Task { await load() } }.disabled(busy)
        }
        if page.canReviewRecipes, let excluded = page.excludedReviewedRecipes, !excluded.isEmpty {
            Section(tonightText("Your recipes excluded from Tonight")) {
                ForEach(excluded) { record in
                    Button {
                        Task { await openRecipe(page, original: record) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: record.reviewedRecipe.title)
                            Text(tonightText("Edit household recipe")).font(.caption)
                        }
                    }.disabled(busy)
                }
            }
        }
        ForEach(page.recipes) { recipe in
            Section {
                Text(verbatim: recipe.title).font(.headline)
                if page.canReviewRecipes, let editable = recipe.editable {
                    Button(tonightText("Edit household recipe")) { Task { await openRecipe(page, original: editable) } }
                        .disabled(busy)
                }
                LabeledContent(ledgerText("Servings"), value: recipe.portions.formatted())
                if let minutes = recipe.minutes { LabeledContent(tonightText("Preparation minutes"), value: minutes.formatted()) }
                else { Text(dinnerText("Total elapsed preparation time is unknown.")) }
                ForEach(recipe.ingredients) { ingredient in
                    VStack(alignment: .leading) {
                        Text(verbatim: ingredient.name)
                        if let missing = ingredient.missing { LabeledContent(tonightText("Still needed"), value: deliveryQuantityText(missing)) }
                        else { Text(tonightText(ingredient.status == .covered ? "Covered by available household food" : "Available quantity needs review")) }
                        if let time = ingredient.evidenceAt.flatMap(serviceDate) { Text(time.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                        if ingredient.useSoon { Text(pantryText("Use soon")).font(.caption) }
                    }
                }
                Text(tonightText(recipe.checkoutEstimate == .noPurchaseNeeded ?
                    "Confirmed pantry food covers these recipe amounts." : "Some amounts or package prices still need review."))
                if recipe.status == .eligible {
                    Button(tonightText("Choose a shared dinner destination")) { selection = recipe; notice = nil }
                        .accessibilityIdentifier("householdTonight.choose." + recipe.id.uuidString)
                } else { Text(tonightText("Review household restrictions and recipe details before choosing this meal.")) }
            }
        }
    }

    @ViewBuilder private func destination(_ recipe: HouseholdTonightPage.Recipe, page: HouseholdTonightPage) -> some View {
        Section(tonightText("Choose a shared dinner destination")) {
            Text(verbatim: recipe.title).font(.headline)
            DatePicker(ht("Meal day"), selection: $day, displayedComponents: .date)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            if let shop = household.sharedShop, shop.canManage, let id = household.projection?.shopId {
                Button {
                    Task { await prepare(recipe, page: page, shop: shop) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(tonightText("Review this shared shop"))
                        Text(verbatim: String(id.suffix(8))).font(.caption.monospaced())
                    }
                }.accessibilityIdentifier("householdTonight.destination")
            }
            if household.projection?.canSelectShop == true || household.projection?.selectionRequired == true {
                Button(ht("Choose shared shop")) { remember(recipe, page: page); choosingShop = true }
            }
            if let shop = household.sharedShop, shop.canCreate || shop.canStartAnother {
                Button(tonightText("Review a new shared shop")) {
                    remember(recipe, page: page)
                    if shop.canCreate { shop.beginEditing() } else { shop.beginAnotherShop() }
                    managingShop = true
                }
            }
            if household.sharedShop?.canManage != true {
                Text(tonightText("You can browse the shared recipes and available food. Ask the assigned shopper to plan this dinner, or choose a draft shop assigned to you."))
            } else { Text(tonightText("Only the assigned shopper can add a dinner to a draft shared shop.")) }
            Button(ht("Cancel")) { household.tonightDestinationReturn = nil; selection = nil; notice = nil }.accessibilityIdentifier("householdTonight.cancel")
        }.disabled(busy)
    }

    @ViewBuilder private func confirmation(_ value: Preview) -> some View {
        Section(tonightText("Review dinner choice")) {
            Text(verbatim: value.recipe.title).font(.headline)
            LabeledContent(ht("Shared household shop"), value: String(value.shop.shopId.suffix(8)))
            Text(verbatim: sharedMealScheduleText(value.day))
            Text(tonightText("Confirm to add one dinner to this shared shop. Pantry quantities and shopping items stay as reviewed."))
            Button(tonightText("Confirm shared dinner")) { Task { await apply(value) } }
                .accessibilityIdentifier("householdTonight.confirm")
            Button(ht("Cancel")) { preview = nil; selection = nil }.accessibilityIdentifier("householdTonight.cancel")
        }.disabled(busy)
    }

    private func remember(_ recipe: HouseholdTonightPage.Recipe, page: HouseholdTonightPage) {
        guard let session, live else { return }
        household.tonightDestinationReturn = .init(recipeID: recipe.id, session: session, subject: scope.subject,
            generation: scope.generation, grantEpoch: page.grantEpoch, expires: Date().addingTimeInterval(600))
    }
    private func reset() {
        generation = UUID(); session = nil; page = nil; selection = nil; preview = nil; notice = nil; busy = false
        editingRecipe = false; originalRecipe = nil; recipeWrite = nil; recipeLots = []; choosingShop = false; managingShop = false
    }
    private func current(_ start: UUID) -> Bool { live && generation == start && !Task.isCancelled }

    @MainActor private func load() async {
        guard live, !busy, let p = household.projection, let service = household.service else { return }
        let start = generation
        busy = true; page = nil; preview = nil; selection = nil; notice = nil
        defer { if generation == start { busy = false } }
        do {
            let session = try await service.householdPantrySession(for: p)
            let result = try await service.householdTonight(for: session)
            guard current(start) else { return }
            self.session = session
            page = result
            if let resume = household.tonightDestinationReturn {
                household.tonightDestinationReturn = nil
                if resume.subject == scope.subject, resume.generation == scope.generation, resume.session == session,
                   resume.grantEpoch == result.grantEpoch, resume.expires > Date() {
                    selection = result.recipes.first { $0.id == resume.recipeID && $0.status == .eligible }
                }
            }
        } catch { if current(start) { await fail(error) } }
    }

    @MainActor private func openRecipe(_ reviewed: HouseholdTonightPage, original: HouseholdTonightPage.EditableRecipe? = nil) async {
        guard live, !busy, page == reviewed, reviewed.canReviewRecipes, let service = household.service, let session else { return }
        let start = generation
        busy = true
        defer { if generation == start { busy = false } }
        do {
            var previous: HouseholdPantryPage?
            var lots: [HouseholdPantryPage.Lot] = []
            repeat {
                let next = try await service.householdPantryPage(for: session, after: previous)
                guard current(start), next.grantEpoch == reviewed.grantEpoch, next.pantryRevision == reviewed.pantryRevision else {
                    throw ClientError.service(status: 409, code: "stale_review", correlationID: nil, retryAfter: nil)
                }
                lots += next.lots
                previous = next
            } while previous?.nextCursor != nil
            if current(start) { recipeWrite = nil; originalRecipe = original; recipeLots = lots; editingRecipe = true }
        } catch { if current(start) { await fail(error) } }
    }

    @MainActor private func save(_ meal: SharedMeal, evidence: SharedMealPreferenceEvidence, lots: [UUID: [UUID]], labels: [HouseholdTonightProductReview], page: HouseholdTonightPage) async throws {
        guard live, self.page == page, page.canReviewRecipes, let projection = household.projection, let service = household.service else { throw ClientError.accessEnded }
        let start = generation
        let session = try await service.householdPantrySession(for: projection)
        if recipeWrite == nil { recipeWrite = try await service.prepareTonightRecipe(meal, evidence: evidence, reviewedLots: lots, productReviews: labels, page: page, session: session, replacing: originalRecipe) }
        guard current(start), let recipeWrite, recipeWrite.session == session else { throw ClientError.cancelled }
        // Retain exact bytes for a lost reply. A different draft needs a fresh explicit review.
        do { try await service.saveTonightRecipe(recipeWrite) }
        catch {
            guard current(start) else { throw ClientError.cancelled }
            if case ClientError.service(let code, _, _, _) = error, [403,404,409].contains(code) { await fail(error) }
            throw error
        }
        guard current(start) else { throw ClientError.cancelled }
        self.recipeWrite = nil
    }

    @MainActor private func prepare(_ recipe: HouseholdTonightPage.Recipe, page: HouseholdTonightPage, shop: HouseholdShopModel) async {
        guard !busy, live, selection == recipe, self.page == page else { return }
        let start = generation
        busy = true
        defer { if generation == start { busy = false } }
        await shop.load()
        guard current(start), household.sharedShop === shop, shop.canManage, shop.pending == nil,
              !shop.editing, let destination = shop.shop, destination.phase == "draft", destination.shopId == shop.scope.shopId else {
            if current(start) { notice = tonightText("Choose a current draft shop and resolve any saved change first.") }
            return
        }
        preview = Preview(recipe: recipe, page: page, shop: destination, day: sharedMealDay(day)); notice = nil
    }

    @MainActor private func apply(_ value: Preview) async {
        guard !busy, live, let shop = household.sharedShop, preview?.occurrence == value.occurrence else { return }
        let start = generation
        busy = true
        defer { if generation == start { busy = false } }
        do {
            try await shop.chooseTonight(value.recipe, from: value.page, destination: value.shop, day: value.day, occurrence: value.occurrence)
            guard current(start) else { return }
            preview = nil; selection = nil; notice = tonightText("Dinner added to the shared shop.")
        } catch { if current(start) { await fail(error) } }
    }

    @MainActor private func fail(_ error: Error) async {
        household.tonightDestinationReturn = nil
        preview = nil; selection = nil; page = nil; editingRecipe = false; recipeWrite = nil
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded, .service(status: 403, code: _, correlationID: _, retryAfter: _),
             .service(status: 404, code: _, correlationID: _, retryAfter: _):
            notice = ht("Refresh the household and check meal planning access.")
            await household.refresh()
        case .service(status: 409, code: _, correlationID: _, retryAfter: _):
            notice = tonightText("Household stock, the recipe or planning access changed. Refresh before choosing again.")
        default: notice = tonightText("The result could not be confirmed. Check the shared shop for a saved change before retrying.")
        }
    }
}
