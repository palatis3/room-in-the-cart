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
    private var foodEvidence: [UUID: MealEligibilityEvidence] = [:]

    var recipes: [MealTemplate] {
        guard let input else { return [] }
        // Two persisted copies with the same identity but different contents are
        // ambiguous. Do not silently pick whichever happens to sort first.
        return Self.recipes(in: input.workspace)
    }
    static func recipes(in workspace: LedgerWorkspace) -> [MealTemplate] {
        let all = workspace.mealTemplates + workspace.dinnerPlanning.acceptedDinners.map(\.template)
        return Dictionary(grouping: all, by: \.id).values.compactMap { values in
            guard let first = values.first, values.allSatisfy({ $0 == first }), !first.ingredients.isEmpty else { return nil }
            return first
        }.sorted { $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var suggestions: [PantryMealMatcher.Review] {
        PantryMealMatcher.ranked(reviews)
    }
    var needsReview: [PantryMealMatcher.Review] {
        let suggestions = Set(suggestions.map(\.id))
        return reviews.filter { !suggestions.contains($0.id) }
    }
    func invalidate() {
        generation = UUID(); input = nil; matches = [:]; foodEvidence = [:]; reviews = []; busy = false; failed = false
    }
    func refresh(authorize: @escaping () -> Bool, load: () async throws -> Input) async {
        guard authorize(), !busy else { return }
        let token = generation
        busy = true
        defer { if generation == token { busy = false } }
        do {
            let next = try await load()
            guard token == generation, authorize() else { invalidate(); return }
            if let old = input, old.basis != next.basis || old.workspace != next.workspace || old.sources != next.sources {
                matches = [:]; foodEvidence = [:]
            }
            input = next
            try rebuild()
            failed = false
        } catch {
            guard token == generation else { return }
            input = nil; reviews = []; matches = [:]; foodEvidence = [:]; failed = true
        }
    }
    func match(recipeID: UUID, ingredientID: UUID, foodID: UUID?) throws {
        guard let input, let recipe = recipes.first(where: { $0.id == recipeID }),
              recipe.ingredients.contains(where: { $0.id == ingredientID }),
              foodID == nil || input.foods.contains(where: { $0.id == foodID }) else { throw Failure.stale }
        matches[recipeID, default: [:]][ingredientID] = foodID
        try rebuild()
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
