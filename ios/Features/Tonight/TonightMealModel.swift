import Foundation
import Combine
import CoreDomain
import RecordArchive

/// A private, no-shop read. The source library and pantry basis are reloaded before
/// opening a choice; reviewed names never allocate another shop's held stock.
@MainActor final class TonightMealModel: ObservableObject {
    struct Batch: Equatable {
        let originID: UUID
        let lotID: UUID
    }
    let batch: Batch?
    init(batch: Batch? = nil) { self.batch = batch }

    var selectedLot: ConfirmedStockLot? {
        guard let batch, let input, batch.originID == input.basis.originID else { return nil }
        return input.freeLots.first { $0.id == batch.lotID && !input.unresolvedFoods.contains($0.foodID) }
    }

    struct Food: Identifiable, Equatable {
        let id: UUID
        let name: String
        let detail: String
        var productUnit: UnitOfMeasure?
        var packIdentity: [String] = []
        var packLabel: String?
        var productDigest: String? {
            guard let productUnit else { return nil }
            return try? ArchiveCodec.digest(ArchiveCodec.canonical([productUnit.rawValue, name] + packIdentity))
        }
    }
    struct Source: Identifiable, Equatable {
        let id: String
        let recipe: ImportedRecipe
    }
    struct SavedRecipe: Identifiable, Equatable {
        let id: String
        let template: MealTemplate
        let acceptedAt: Date?
    }
    struct Input: Equatable {
        let workspace: LedgerWorkspace
        let ledgerRevision: Int64
        let basis: LedgerCanonicalPackStockEvidence.Basis
        let foods: [Food]
        let freeLots: [ConfirmedStockLot]
        let unresolvedFoods: Set<UUID>
        let sources: [Source]
        var reservedFoods: Set<UUID> = []
        var feedbackOwner: String? = nil
        var rememberedProducts: [RecipeProductMatch] = []
    }
    enum Failure: Error { case unavailable, stale, recipeChanged }
    @Published private(set) var input: Input?
    @Published private(set) var reviews: [PantryMealMatcher.Review] = []
    @Published private(set) var firstRecipeID: UUID?
    private(set) var pairingRevision = UUID()
    @Published private(set) var followingMeals: [PantryMealMatcher.Review] = []
    @Published private(set) var matches: [UUID: [UUID: UUID]] = [:]
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    private var generation = UUID()
    private var reading = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var manualMatches: [UUID: [UUID: UUID]] = [:]
    private var overriddenIngredients: [UUID: Set<UUID>] = [:]
    private var selectedVersions: [UUID: MealTemplate] = [:]
    private var foodEvidence: [UUID: MealEligibilityEvidence] = [:]

    var recipes: [MealTemplate] {
        guard let input else { return [] }
        // Two persisted copies with the same identity but different contents are
        // ambiguous. Do not silently pick whichever happens to sort first.
        let unique = Self.recipes(in: input.workspace)
        let resolved = selectedVersions.values.filter { selected in savedRecipes.contains { $0.template == selected } }
        return (unique + resolved.filter { selected in !unique.contains { $0.id == selected.id } })
            .sorted { $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    static func recipes(in workspace: LedgerWorkspace) -> [MealTemplate] {
        let all = workspace.mealTemplates + workspace.dinnerPlanning.acceptedDinners.map(\.template)
        return Dictionary(grouping: all, by: \.id).values.compactMap { values in
            guard let first = values.first, values.allSatisfy({ $0 == first }), !first.ingredients.isEmpty else { return nil }
            return first
        }.sorted { $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var savedRecipes: [SavedRecipe] {
        guard let input else { return [] }
        return input.workspace.mealTemplates.map { SavedRecipe(id: "free:" + $0.id.uuidString, template: $0, acceptedAt: nil) } +
            input.workspace.dinnerPlanning.acceptedDinners.map { SavedRecipe(id: "accepted:" + $0.id.uuidString, template: $0.template, acceptedAt: $0.acceptedAt) }
    }
    var conflictingRecipes: [SavedRecipe] {
        let groups = Dictionary(grouping: savedRecipes, by: { $0.template.id })
        return savedRecipes.filter { source in
            groups[source.template.id]?.contains { $0.template != source.template } == true
        }
    }
    func selectVersion(_ source: SavedRecipe) throws {
        guard savedRecipes.contains(source) else { throw Failure.recipeChanged }
        selectedVersions[source.template.id] = source.template
        manualMatches[source.template.id] = nil; overriddenIngredients[source.template.id] = nil
        try rebuild()
    }
    var suggestions: [PantryMealMatcher.Review] {
        let feedback = input.flatMap { current in
            current.feedbackOwner.map { current.workspace.mealFeedbackSignals(owner: $0, at: Date()) }
        } ?? [:]
        if let batch {
            guard selectedLot != nil else { return [] }
            return DinnerLibraryPairings.usingBatch(batch.lotID, reviews: reviews, feedback: feedback)
        }
        return PantryMealMatcher.ranked(reviews, feedback: feedback)
    }
    var homeScreenChoices: [PantryMealMatcher.Review] {
        guard let input, !failed, let profile = input.workspace.dinnerPlanning.privateMealPreferences,
              profile.settings.availableAppliances != nil else { return [] }
        // Reactions personalize the private Tonight screen. Widget consent
        // covers the reviewed meal title and count without that preference signal.
        return PantryMealMatcher.ranked(reviews).filter {
            $0.preferenceRevision == profile.revision && $0.recipe.eligibilityEvidence?.requiredAppliances != nil &&
                $0.allIngredientsCovered && Self.canChoose($0)
        }
    }
    var needsReview: [PantryMealMatcher.Review] {
        let suggestions = Set(suggestions.map(\.id))
        return reviews.filter { !suggestions.contains($0.id) }
    }
    func invalidate() {
        clearPairing()
        generation = UUID(); input = nil; matches = [:]; manualMatches = [:]; overriddenIngredients = [:]; foodEvidence = [:]; selectedVersions = [:]; reviews = []; busy = false; failed = false
    }
    func refresh(authorize: @escaping () -> Bool, load: () async throws -> Input) async {
        guard authorize() else { invalidate(); return }
        guard !busy else { return }
        let token = generation
        busy = true
        // Invalidation clears the visible data immediately. Let its old pantry read finish
        // before the replacement request uses the same pickup model.
        if reading {
            await withCheckedContinuation { readWaiters.append($0) }
            guard generation == token else { return }
            guard authorize() else { invalidate(); return }
        }
        reading = true
        defer {
            reading = false
            let waiters = readWaiters
            readWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if generation == token { busy = false }
        }
        do {
            let next = try await load()
            guard token == generation else { return }
            guard authorize() else { invalidate(); return }
            let identicalInput = input == next
            if !identicalInput, let old = input, old.basis != next.basis || old.workspace.withoutMealFeedback().withoutRecipeShortcuts() != next.workspace.withoutMealFeedback().withoutRecipeShortcuts() || old.feedbackOwner != next.feedbackOwner || old.foods != next.foods || old.freeLots != next.freeLots || old.unresolvedFoods != next.unresolvedFoods || old.sources != next.sources {
                clearPairing()
                matches = [:]; manualMatches = [:]; overriddenIngredients = [:]; foodEvidence = [:]; selectedVersions = [:]
            }
            input = next
            try rebuild(retainingCharges: identicalInput)
            failed = false
        } catch {
            guard token == generation else { return }
            clearPairing()
            input = nil; reviews = []; matches = [:]; manualMatches = [:]; overriddenIngredients = [:]; foodEvidence = [:]; selectedVersions = [:]; failed = true
        }
    }
    func match(recipeID: UUID, ingredientID: UUID, foodID: UUID?) throws {
        guard let input, let recipe = recipes.first(where: { $0.id == recipeID }),
              recipe.ingredients.contains(where: { $0.id == ingredientID && $0.checkedWithoutAmount != true }),
              foodID == nil || input.foods.contains(where: { $0.id == foodID }) else { throw Failure.stale }
        manualMatches[recipeID, default: [:]][ingredientID] = foodID
        overriddenIngredients[recipeID, default: []].insert(ingredientID)
        try rebuild()
    }
    /// Allocation coverage can normalize repeated ingredients to a shared unit.
    /// Unknown stock never becomes a known zero merely because a provisional
    /// coverage row happened to contain zero shortfall.
    static func missingQuantity(_ row: PantryMealMatcher.IngredientReview) -> Quantity? {
        guard !row.hasUnresolvedStock else { return nil }
        guard let coverage = row.coverage else { return row.ingredient.quantity }
        guard coverage.issues.isEmpty, let amount = coverage.shortfall else { return nil }
        return Quantity(amount: amount, unit: coverage.unit, originalLiteral: amount.description)
    }
    static func saveReviewedTemplate(_ candidate: MealTemplate, editing source: MealTemplate?, in workspace: inout LedgerWorkspace) throws {
        try candidate.validate()
        if let source, let index = workspace.mealTemplates.firstIndex(of: source) {
            guard source.id == candidate.id else { throw Failure.recipeChanged }
            workspace.mealTemplates[index] = candidate
        } else {
            if let source, !workspace.dinnerPlanning.acceptedDinners.contains(where: { $0.template == source }) { throw Failure.recipeChanged }
            // The first slot is the Free reusable recipe. Imported older files
            // can contain additional templates; replacing Free must retain them.
            if workspace.mealTemplates.isEmpty { workspace.mealTemplates.append(candidate) }
            else { workspace.mealTemplates[0] = candidate }
        }
    }
    static func canChoose(_ review: PantryMealMatcher.Review) -> Bool {
        review.canChooseUsingPantry
    }
    func reviewFood(_ food: Food, evidence: MealEligibilityEvidence, original: Input) throws {
        guard let input, input.basis == original.basis, input.workspace == original.workspace,
              input.foods.contains(food) else { throw Failure.stale }
        try evidence.validate()
        foodEvidence[food.id] = evidence
        try rebuild()
    }
    func assertCurrent(_ original: Input, recipe: MealTemplate, matches originalMatches: [UUID: UUID]) throws {
        guard let input, original.basis == input.basis, original.workspace.withoutRecipeShortcuts() == input.workspace.withoutRecipeShortcuts(),
              original.sources == input.sources, original.rememberedProducts == input.rememberedProducts, original.foods == input.foods, recipes.contains(recipe), matches[recipe.id, default: [:]] == originalMatches else { throw Failure.stale }
    }
    private func rebuild(retainingCharges: Bool = false) throws {
        guard let input else { return }
        matches = manualMatches
        if let owner = input.feedbackOwner, !input.rememberedProducts.isEmpty {
            let byRecipe = Dictionary(grouping: input.rememberedProducts.filter {
                $0.key.owner == owner && $0.key.pantryID == input.basis.originID
            }, by: \.key.recipeID)
            for recipe in recipes {
                guard let saved = byRecipe[recipe.id] else { continue }
                let digest = try ArchiveCodec.digest(ArchiveCodec.canonical(recipe))
                for entry in saved {
                    guard entry.recipeRevision == recipe.revision, entry.recipeDigest == digest,
                          overriddenIngredients[recipe.id]?.contains(entry.key.ingredientID) != true,
                          let ingredient = recipe.ingredients.first(where: { $0.id == entry.key.ingredientID }),
                          let food = input.foods.first(where: { $0.id == entry.foodID }),
                          food.productDigest == entry.productDigest, usableProduct(food, for: ingredient, recipe: recipe, input: input)
                    else { continue }
                    matches[recipe.id, default: [:]][ingredient.id] = food.id
                }
            }
        }
        reviews = try evaluate(recipes, lots: input.freeLots, input: input)
        if let firstRecipeID {
            if retainingCharges { try updateFollowingMeals(after: firstRecipeID) }
            else { try showFollowingMeals(after: firstRecipeID) }
        }
    }
    func matchKey(recipe: MealTemplate, ingredient: MealIngredient) -> RecipeProductMatch.Key? {
        guard let input, let owner = input.feedbackOwner else { return nil }
        return .init(owner: owner, pantryID: input.basis.originID, recipeID: recipe.id, ingredientID: ingredient.id)
    }
    func storedProduct(_ key: RecipeProductMatch.Key) -> RecipeProductMatch? {
        input?.rememberedProducts.first { $0.key == key }
    }
    private func usableProduct(_ food: Food, for ingredient: MealIngredient, recipe: MealTemplate, input: Input) -> Bool {
        guard ingredient.quantity != nil, food.productDigest != nil, !input.unresolvedFoods.contains(food.id),
              input.freeLots.contains(where: { $0.foodID == food.id && $0.usable.amount > .zero }) else { return false }
        var rules = MealPreferenceSettings()
        rules.exclusions = recipe.exclusions + ingredient.exclusions
        let evidence = foodEvidence[food.id]
        return MealEligibilityPolicy.evaluate(profile: input.workspace.dinnerPlanning.privateMealPreferences, template: recipe).eligible &&
            MealEligibilityPolicy.evaluateFood(profile: input.workspace.dinnerPlanning.privateMealPreferences, labels: [food.name], evidence: evidence).eligible &&
            MealEligibilityPolicy.evaluateFood(profile: .init(settings: rules), labels: [food.name], evidence: evidence).eligible
    }
    func rememberedCandidate(recipe: MealTemplate, ingredient: MealIngredient) -> RecipeProductMatch? {
        guard let input, let key = matchKey(recipe: recipe, ingredient: ingredient),
              let id = matches[recipe.id]?[ingredient.id], let food = input.foods.first(where: { $0.id == id }),
              let product = food.productDigest, usableProduct(food, for: ingredient, recipe: recipe, input: input),
              reviews.first(where: { $0.recipe == recipe })?.ingredients.first(where: { $0.id == ingredient.id })?.hasConfirmedStock == true,
              let digest = try? ArchiveCodec.digest(ArchiveCodec.canonical(recipe)) else { return nil }
        return .init(key: key, recipeRevision: recipe.revision, recipeDigest: digest, foodID: id, productDigest: product)
    }
    func clearSelectionAfterForgetting(_ key: RecipeProductMatch.Key) {
        manualMatches[key.recipeID]?[key.ingredientID] = nil
        overriddenIngredients[key.recipeID, default: []].insert(key.ingredientID)
        try? rebuild()
    }
    private func evaluate(_ recipes: [MealTemplate], lots: [ConfirmedStockLot], input: Input) throws -> [PantryMealMatcher.Review] {
        try recipes.map {
            try PantryMealMatcher.review(recipe: $0, reviewedFoods: matches[$0.id, default: [:]],
                globallyFreeLots: lots, unresolvedFoods: input.unresolvedFoods,
                profile: input.workspace.dinnerPlanning.privateMealPreferences, foodEvidence: foodEvidence, firstLotID: selectedLot?.id)
        }
    }
    func clearPairing() {
        pairingRevision = UUID()
        firstRecipeID = nil
        followingMeals = []
    }
    func showFollowingMeals(after recipeID: UUID) throws {
        clearPairing()
        try updateFollowingMeals(after: recipeID)
    }
    private func updateFollowingMeals(after recipeID: UUID) throws {
        guard let input, let lot = selectedLot, let first = reviews.first(where: { $0.id == recipeID }),
              first.batchUse?.lotID == lot.id, first.canProjectRemainder else { clearPairing(); return }
        let projected = try PantryMealMatcher.review(recipe: first.recipe, reviewedFoods: matches[first.id, default: [:]],
            globallyFreeLots: input.freeLots, unresolvedFoods: input.unresolvedFoods,
            profile: input.workspace.dinnerPlanning.privateMealPreferences, foodEvidence: foodEvidence,
            firstLotID: lot.id, projectRemainder: true)
        guard let remaining = projected.stockAfterMeal else { clearPairing(); return }
        let candidates = try evaluate(recipes.filter { $0.id != recipeID }, lots: remaining, input: input)
        followingMeals = DinnerLibraryPairings.usingBatch(lot.id, reviews: candidates.filter { Self.canChoose($0) })
        firstRecipeID = recipeID
    }
    static func input(workspace: LedgerWorkspace, ledgerRevision: Int64,
                      context: PantryPackStockReview.Context, sources: [Source], confirmedPacks: [ConfirmedPantryPack]? = []) throws -> Input {
        let live = try PantryLiveStockProjection.buildGlobal(snapshot: context.snapshot, mapping: context.mapping, at: context.asOf)
        let basis = LedgerCanonicalPackStockEvidence.Basis(originID: live.basis.originID,
            inventoryRevision: live.basis.inventoryRevision,
            sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) })
        let grouped = Dictionary(grouping: live.lots, by: { $0.current.foodID })
        let packs = Dictionary(grouping: confirmedPacks ?? [], by: \.id)
        var foods: [Food] = []
        for (foodID, rows) in grouped {
            var names: [String] = []
            var details: [String] = []
            for row in rows {
                names.append(row.current.name)
                let count: String = pantryCount(row.current.count)
                let date: String = row.current.confirmedAt.formatted(date: .abbreviated, time: .shortened)
                details.append([pantryLocationName(row.current.location), count, date].joined(separator: " · "))
            }
            let distinctNames = Set(names)
            let name = distinctNames.sorted().joined(separator: " / ")
            let units = Set(rows.map { $0.current.unit })
            let variants = packs[foodID, default: []]
            let pack = variants.first
            let canRemember = distinctNames.count == 1 && units.count == 1 && confirmedPacks != nil && variants.count <= 1
            let identity = pack.map { [$0.key ?? "", $0.name, $0.size.amount.description, $0.size.unit.rawValue] } ?? []
            foods.append(Food(id: foodID, name: name, detail: details.joined(separator: "\n"),
                              productUnit: canRemember ? units.first : nil, packIdentity: identity, packLabel: pack?.label))
        }
        foods.sort { left, right in
            if left.name == right.name { return left.id.uuidString < right.id.uuidString }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        let resolved = Set(live.lots.filter { $0.free != nil }.map(\.current.foodID))
        let unresolved = Set(live.lots.filter { $0.free == nil }.map(\.current.foodID)).subtracting(resolved)
            .union(context.snapshot.reservations.filter { $0.state == .unresolved }.map(\.foodID))
        return Input(workspace: workspace, ledgerRevision: ledgerRevision, basis: basis, foods: foods,
                     freeLots: live.canonicalFreeLots, unresolvedFoods: unresolved, sources: sources, reservedFoods: context.reservedFoods)
    }
}
