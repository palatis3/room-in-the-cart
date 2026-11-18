import Foundation
import Combine
import CoreDomain

/// Presentation drafts only. PantryCookSession owns all reads, review authority,
/// receipt recovery and the single atomic write.
@MainActor final class CookCompletionEditorModel: ObservableObject {
    enum IngredientUse: String, CaseIterable { case undecided, notUsed, used }
    enum PartUse: String, CaseIterable { case undecided, measured, unmeasured, untracked }
    enum Relation: String, CaseIterable { case undecided, ingredient, substitution }
    enum LeftoverChoice: String, CaseIterable { case undecided, none, recorded }
    enum Notice: Equatable {
        case unavailable, invalidEntry, reviewChanged, insufficientStock, uncertain, saved, undoChanged, undoUncertain, undone
        case undoIndependentCount(String?), undoAmendedInputChanged(String?)
    }
    enum Failure: Error { case incomplete, stale, denied }
    struct Part: Identifiable, Equatable {
        let id: UUID
        var use: PartUse = .undecided
        var lotID: UUID?
        var amount = "" {
            didSet { if !amount.isEmpty { needsNewMeasurement = false } }
        }
        var unit: UnitOfMeasure = .count
        private(set) var needsNewMeasurement = false
        var relation: Relation = .undecided
        var substitution = ""
        init(id: UUID = UUID()) { self.id = id }

        mutating func selectBatch(_ lot: InventoryLot?) {
            guard lotID != lot?.id else { return }
            lotID = lot?.id
            needsNewMeasurement = false
            guard let lot, unit != lot.unit else { return }
            if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unit = lot.unit
                return
            }
            // Keep the cook's original measurement. The review converts it to the
            // batch unit using the same confirmed basis that governs the deduction.
            if unit.dimension == lot.unit.dimension { return }
            if let measured = try? LedgerEntry.quantity(amount, unit),
               (try? measured.converted(to: lot.unit, using: lot.count.quantity?.confirmedConversion)) != nil { return }
            amount = ""
            unit = lot.unit
            needsNewMeasurement = true
        }
    }
    struct Ingredient: Identifiable, Equatable {
        let id: UUID
        let name: String
        let planned: Quantity?
        let exclusions: [String]
        let notUsedID = UUID()
        var use: IngredientUse = .undecided
        var parts: [Part] = [Part()]
    }
    struct Leftover: Identifiable, Equatable {
        let id = UUID()
        let foodID = UUID()
        var name: String
        var portions = ""
        var location: InventoryLocation = .fridge
    }
    struct Suggestion: Identifiable {
        let lot: InventoryLot
        let issues: [MealEligibilityPolicy.Issue]
        let softDifferences: [MealEligibilityPolicy.Issue]
        let available: Quantity?
        var id: UUID { lot.id }
        var eligible: Bool { issues.isEmpty && (available?.amount ?? .zero) > .zero }
    }

    @Published private(set) var context: PantryCookSession.Context?
    @Published private(set) var review: CookCompletion.Review?
    @Published private(set) var completed: CookCompletionDraft?
    @Published private(set) var undoReview: PantryCookUndoReview?
    @Published private(set) var attemptedUndo = false
    @Published private(set) var busy = false
    @Published private(set) var attemptedApply = false
    @Published private(set) var notice: Notice?
    @Published var ingredients: [Ingredient] = []
    @Published var servings = ""
    @Published var cookedAt = Date()
    @Published var leftoverChoice: LeftoverChoice = .undecided
    @Published var leftovers: [Leftover] = []
    private var operationID = UUID()
    private var generation = UUID()
    private var session: PantryCookSession?
    private var shopID: UUID?
    private var mealID: UUID?
    private var authorize: () -> Bool = { false }
    private var foodDetails: [UUID: MealEligibilityEvidence] = [:]

    var canEdit: Bool { context != nil && completed == nil && review == nil && !busy && !attemptedApply && authorize() }
    var canConfirm: Bool { review != nil && completed == nil && !busy && authorize() }
    var hasAccess: Bool { authorize() }
    var remainingUnresolvedUseIDs: [UUID] {
        guard let completed else { return [] }
        if context?.completed?.id == completed.id { return context?.remainingUnresolvedUseIDs ?? [] }
        return completed.unresolvedUseIDs
    }
    var hasAttemptedMutation: Bool { attemptedApply || attemptedUndo }
    var canReviewUndo: Bool { completed != nil && undoReview == nil && !busy && authorize() }
    var canConfirmUndo: Bool { undoReview != nil && !busy && authorize() }
    func invalidate() {
        generation = UUID(); context = nil; review = nil; completed = nil; ingredients = []; leftovers = []
        servings = ""; foodDetails = [:]; busy = false; attemptedApply = false; session = nil
        authorize = { false }; notice = nil; undoReview = nil; attemptedUndo = false
    }
    func open(session: PantryCookSession, shopID: UUID, mealID: UUID, authorize: @escaping () -> Bool) async {
        invalidate()
        self.session = session; self.shopID = shopID; self.mealID = mealID; self.authorize = authorize
        await reload()
    }
    /// After an uncertain apply, this relies on the facade's completed/pending
    /// reconciliation. An unreadable or in-flight operation must throw, not look absent.
    func reload() async {
        guard !busy, let session, let shopID, let mealID, authorize() else { return }
        let token = generation; busy = true
        defer { if token == generation { busy = false } }
        do {
            let loaded = try await session.load(shopID: shopID, mealID: mealID)
            guard token == generation, authorize() else { invalidate(); return }
            let loadedIngredients: [Ingredient]
            if let recovery = loaded.recovery {
                let rules = Dictionary(uniqueKeysWithValues: recovery.ingredientRules.map { ($0.needID, $0.exclusions) })
                loadedIngredients = try recovery.meal.ingredients.map { row in
                    guard let exclusions = rules[row.need.id] else { throw Failure.stale }
                    return Ingredient(id: row.need.id, name: row.foodName, planned: row.need.amount, exclusions: exclusions)
                }
            } else {
                let contributions = Dictionary(uniqueKeysWithValues: loaded.shop.contributions.filter { $0.removedAt == nil }.map { ($0.id, $0) })
                loadedIngredients = try loaded.meal.ingredientContributionIDs.map { id in
                    guard let row = contributions[id] else { throw Failure.stale }
                    return Ingredient(id: id, name: row.productName, planned: row.quantity, exclusions: row.exclusions)
                }
            }
            context = loaded; completed = loaded.completed; review = nil; attemptedApply = false; notice = nil
            undoReview = nil; attemptedUndo = false
            operationID = UUID(); foodDetails = [:]
            cookedAt = loaded.asOf; servings = loaded.servings.description; ingredients = loadedIngredients
            leftoverChoice = .undecided; leftovers = []
        } catch {
            guard token == generation else { return }
            if !authorize() { invalidate() }
            else { notice = .unavailable }
        }
    }
    func addPart(ingredientID: UUID) {
        guard canEdit, let index = ingredients.firstIndex(where: { $0.id == ingredientID }),
              ingredients.reduce(0, { $0 + $1.parts.count }) < 500 else { return }
        ingredients[index].parts.append(Part())
    }
    func removePart(ingredientID: UUID, partID: UUID) {
        guard canEdit, let index = ingredients.firstIndex(where: { $0.id == ingredientID }), ingredients[index].parts.count > 1 else { return }
        ingredients[index].parts.removeAll { $0.id == partID }
    }
    func addLeftover() {
        guard canEdit, leftovers.count < 20, let context else { return }
        leftovers.append(Leftover(name: context.title))
    }
    func keepEditing() {
        guard !attemptedApply, !busy, authorize() else { return }
        review = nil; notice = nil
    }
    func chooseSuggestion(_ suggestion: Suggestion, ingredientID: UUID, partID: UUID) throws {
        guard canEdit, let ingredient = ingredients.firstIndex(where: { $0.id == ingredientID }),
              let part = ingredients[ingredient].parts.firstIndex(where: { $0.id == partID }),
              suggestions(for: ingredientID).contains(where: { $0.lot == suggestion.lot && $0.eligible }) else { throw Failure.stale }
        ingredients[ingredient].parts[part].selectBatch(suggestion.lot)
        ingredients[ingredient].parts[part].relation = .substitution
        ingredients[ingredient].parts[part].substitution = suggestion.lot.name
        ingredients[ingredient].parts[part].use = .measured
    }
    func reviewFoodDetails(lot: InventoryLot, evidence: MealEligibilityEvidence) throws {
        guard canEdit, context?.inventory.lots.contains(lot) == true else { throw Failure.stale }
        try evidence.validate(); foodDetails[lot.id] = evidence
        objectWillChange.send()
    }
    func suggestions(for ingredientID: UUID) -> [Suggestion] {
        guard let context, let ingredient = ingredients.first(where: { $0.id == ingredientID }), authorize() else { return [] }
        var restrictions = MealPreferenceSettings()
        restrictions.exclusions = context.exclusions + ingredient.exclusions
        let extra = MealPreferenceProfile(settings: restrictions)
        var results: [Suggestion] = []
        for lot in context.inventory.lots {
            let facts = foodDetails[lot.id]
            let personal = MealEligibilityPolicy.evaluateFood(profile: context.preferences, labels: [lot.name], evidence: facts)
            let recipe = MealEligibilityPolicy.evaluateFood(profile: extra, labels: [lot.name], evidence: facts)
            var issues = personal.blocked + personal.unresolved
            for issue in recipe.blocked + recipe.unresolved where !issues.contains(issue) { issues.append(issue) }
            let free = context.inventory.availability.lots.first { $0.id == lot.id }?.free
            results.append(Suggestion(lot: lot, issues: issues, softDifferences: personal.softDifferences + recipe.softDifferences, available: free))
        }
        return results.sorted {
            if $0.lot.name == $1.lot.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.lot.name.localizedStandardCompare($1.lot.name) == .orderedAscending
        }
    }
    func makeDraft() throws -> CookCompletionDraft {
        guard canEdit, let context, let made = try LedgerEntry.rational(servings), made > .zero,
              leftoverChoice != .undecided else { throw Failure.incomplete }
        var parts: [CookCompletionDraft.Part] = []
        for ingredient in ingredients {
            switch ingredient.use {
            case .undecided: throw Failure.incomplete
            case .notUsed:
                parts.append(.init(id: ingredient.notUsedID, contributionID: ingredient.id, use: .notUsed))
            case .used:
                guard !ingredient.parts.isEmpty else { throw Failure.incomplete }
                for part in ingredient.parts {
                    guard part.relation != .undecided else { throw Failure.incomplete }
                    let note = part.substitution.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard part.relation != .substitution || !note.isEmpty else { throw Failure.incomplete }
                    let use: CookCompletionDraft.Part.Use
                    switch part.use {
                    case .undecided: throw Failure.incomplete
                    case .untracked: use = .untracked
                    case .measured, .unmeasured:
                        guard let lot = context.inventory.lots.first(where: { $0.id == part.lotID }) else { throw Failure.incomplete }
                        let amount: Quantity?
                        if part.use == .measured {
                            guard let known = try LedgerEntry.quantity(part.amount, part.unit), known.amount > .zero else { throw Failure.incomplete }
                            amount = known
                        } else { amount = nil }
                        use = .lot(id: lot.id, revision: lot.revision, amount: amount)
                    }
                    parts.append(.init(id: part.id, contributionID: ingredient.id, use: use,
                        substitution: part.relation == .substitution ? note : nil))
                }
            }
        }
        var outputs: [CookCompletionDraft.Leftovers] = []
        if leftoverChoice == .recorded {
            guard !leftovers.isEmpty else { throw Failure.incomplete }
            for row in leftovers {
                guard let portions = try LedgerEntry.rational(row.portions), portions > .zero,
                      !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.incomplete }
                outputs.append(.init(id: row.id, foodID: row.foodID, name: row.name, portions: portions, location: row.location))
            }
        }
        return CookCompletionDraft(id: operationID, inventoryID: context.inventory.state.workspaceID,
            inventoryRevision: context.inventory.state.revision, ledgerID: context.ledgerID,
            shop: context.shop, meal: context.meal, cookedAt: cookedAt, servingsMade: made,
            parts: parts, leftovers: outputs, preferenceRevision: context.preferences?.revision, recoveredMeal: context.recovery?.meal)
    }
    func prepareReview() async {
        guard let session, canEdit else { return }
        let draft: CookCompletionDraft
        do { draft = try makeDraft() } catch { notice = .invalidEntry; return }
        let token = generation; busy = true
        defer { if token == generation { busy = false } }
        do {
            let prepared = try await session.review(draft)
            guard token == generation, authorize() else { invalidate(); return }
            review = prepared; notice = nil
        } catch {
            guard token == generation else { return }
            if !authorize() { invalidate(); return }
            if case InventoryError.invalid("cookUseExceedsAvailable") = error { notice = .insufficientStock }
            else { notice = .reviewChanged }
        }
    }
    func confirm() async {
        guard let session, let review, canConfirm else { return }
        let token = generation; busy = true; attemptedApply = true
        defer { if token == generation { busy = false } }
        do {
            try await session.apply(review)
            guard token == generation, authorize() else { invalidate(); return }
            completed = review.draft; self.review = nil; notice = .saved
        } catch {
            guard token == generation else { return }
            if !authorize() { invalidate() }
            else { notice = .uncertain }
        }
    }

    func prepareUndo() async {
        guard let session, let shopID, let mealID, canReviewUndo else { return }
        let token = generation; busy = true
        defer { if token == generation { busy = false } }
        do {
            let prepared = try await session.reviewUndo(shopID: shopID, mealID: mealID)
            guard token == generation, authorize() else { invalidate(); return }
            undoReview = prepared; notice = nil
        } catch {
            guard token == generation else { return }
            if !authorize() { invalidate() } else { notice = undoFailureNotice(error, uncertain: false) }
        }
    }
    func cancelUndo() {
        guard !attemptedUndo, !busy, authorize() else { return }
        undoReview = nil; notice = nil
    }
    func confirmUndo() async {
        guard let session, let undoReview, canConfirmUndo else { return }
        let token = generation; busy = true; attemptedUndo = true
        defer { if token == generation { busy = false } }
        do {
            try await session.applyUndo(undoReview)
            guard token == generation, authorize() else { invalidate(); return }
            busy = false
            await reload()
            if token == generation, authorize(), completed == nil, context != nil { notice = .undone }
        } catch {
            guard token == generation else { return }
            if !authorize() { invalidate() } else { notice = undoFailureNotice(error, uncertain: true) }
        }
    }

    private func undoFailureNotice(_ error: Error, uncertain: Bool) -> Notice {
        guard let failure = error as? PantryCookUndoFailure else { return uncertain ? .undoUncertain : .undoChanged }
        switch failure {
        case .independentPhysicalCount(let lot): return .undoIndependentCount(lot)
        case .amendedInputChanged(let lot): return .undoAmendedInputChanged(lot)
        }
    }
}
