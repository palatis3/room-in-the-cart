import Foundation
import Combine
import CoreDomain
import RecordArchive

/// A private, no-shop read. The source library and pantry basis are reloaded before
/// opening a choice; reviewed names never allocate another shop's held stock.
@MainActor final class TonightMealModel: ObservableObject {
    struct Food: Identifiable, Equatable {
        let id: UUID
        let name: String
        let detail: String
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
    struct Input {
        let workspace: LedgerWorkspace
        let ledgerRevision: Int64
        let basis: LedgerCanonicalPackStockEvidence.Basis
        let foods: [Food]
        let freeLots: [ConfirmedStockLot]
        let unresolvedFoods: Set<UUID>
        let sources: [Source]
    }
    enum Failure: Error { case unavailable, stale, recipeChanged }
    @Published private(set) var input: Input?
    @Published private(set) var reviews: [PantryMealMatcher.Review] = []
    @Published private(set) var matches: [UUID: [UUID: UUID]] = [:]
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    private var generation = UUID()
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
        matches[source.template.id] = nil
        try rebuild()
    }
    var suggestions: [PantryMealMatcher.Review] {
        PantryMealMatcher.ranked(reviews)
    }
    var homeScreenChoices: [PantryMealMatcher.Review] {
        guard let input, !failed, let profile = input.workspace.dinnerPlanning.privateMealPreferences,
              profile.settings.availableAppliances != nil else { return [] }
        return suggestions.filter {
            $0.preferenceRevision == profile.revision && $0.recipe.eligibilityEvidence?.requiredAppliances != nil &&
                $0.allIngredientsCovered && Self.canChoose($0)
        }
    }
    var needsReview: [PantryMealMatcher.Review] {
        let suggestions = Set(suggestions.map(\.id))
        return reviews.filter { !suggestions.contains($0.id) }
    }
    func invalidate() {
        generation = UUID(); input = nil; matches = [:]; foodEvidence = [:]; selectedVersions = [:]; reviews = []; busy = false; failed = false
    }
    func refresh(authorize: @escaping () -> Bool, load: () async throws -> Input) async {
        guard authorize() else { invalidate(); return }
        guard !busy else { return }
        let token = generation
        busy = true
        defer { if generation == token { busy = false } }
        do {
            let next = try await load()
            guard token == generation, authorize() else { invalidate(); return }
            if let old = input, old.basis != next.basis || old.workspace != next.workspace || old.sources != next.sources {
                matches = [:]; foodEvidence = [:]; selectedVersions = [:]
            }
            input = next
            try rebuild()
            failed = false
        } catch {
            guard token == generation else { return }
            input = nil; reviews = []; matches = [:]; foodEvidence = [:]; selectedVersions = [:]; failed = true
        }
    }
    func match(recipeID: UUID, ingredientID: UUID, foodID: UUID?) throws {
        guard let input, let recipe = recipes.first(where: { $0.id == recipeID }),
              recipe.ingredients.contains(where: { $0.id == ingredientID }),
              foodID == nil || input.foods.contains(where: { $0.id == foodID }) else { throw Failure.stale }
        matches[recipeID, default: [:]][ingredientID] = foodID
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
        review.eligibility.eligible && review.hasConfirmedPantryFood && !review.recipe.ingredients.isEmpty &&
            review.recipe.ingredients.allSatisfy { $0.quantity != nil } &&
            review.ingredients.allSatisfy { !$0.hasUnresolvedStock && ($0.coverage?.issues.isEmpty ?? true) }
    }
    func reviewFood(_ food: Food, evidence: MealEligibilityEvidence, original: Input) throws {
        guard let input, input.basis == original.basis, input.workspace == original.workspace,
              input.foods.contains(food) else { throw Failure.stale }
        try evidence.validate()
        foodEvidence[food.id] = evidence
        try rebuild()
    }
    func assertCurrent(_ original: Input, recipe: MealTemplate, matches originalMatches: [UUID: UUID]) throws {
        guard let input, original.basis == input.basis, original.workspace == input.workspace,
              original.sources == input.sources, recipes.contains(recipe), matches[recipe.id, default: [:]] == originalMatches else { throw Failure.stale }
    }
    private func rebuild() throws {
        guard let input else { return }
        reviews = try recipes.map {
            try PantryMealMatcher.review(recipe: $0, reviewedFoods: matches[$0.id, default: [:]],
                globallyFreeLots: input.freeLots, unresolvedFoods: input.unresolvedFoods,
                profile: input.workspace.dinnerPlanning.privateMealPreferences, foodEvidence: foodEvidence)
        }
    }
    static func input(workspace: LedgerWorkspace, ledgerRevision: Int64,
                      context: PantryPackStockReview.Context, sources: [Source]) throws -> Input {
        let live = try PantryLiveStockProjection.buildGlobal(snapshot: context.snapshot, mapping: context.mapping, at: context.asOf)
        let basis = LedgerCanonicalPackStockEvidence.Basis(originID: live.basis.originID,
            inventoryRevision: live.basis.inventoryRevision,
            sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) })
        let grouped = Dictionary(grouping: live.lots, by: { $0.current.foodID })
        let foods = grouped.map { id, rows in
            Food(id: id, name: rows.map(\.current.name).sorted().joined(separator: " / "),
                 detail: rows.map { pantryCount($0.current.count) + " · " + $0.current.confirmedAt.formatted(date: .abbreviated, time: .shortened) }.joined(separator: "\n"))
        }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let resolved = Set(live.lots.filter { $0.free != nil }.map(\.current.foodID))
        let unresolved = Set(live.lots.filter { $0.free == nil }.map(\.current.foodID)).subtracting(resolved)
            .union(context.snapshot.reservations.filter { $0.state == .unresolved }.map(\.foodID))
        return Input(workspace: workspace, ledgerRevision: ledgerRevision, basis: basis, foods: foods,
                     freeLots: live.globallyFreeLots, unresolvedFoods: unresolved, sources: sources)
    }
}
