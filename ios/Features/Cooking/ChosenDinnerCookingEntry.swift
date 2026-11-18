import CoreDomain
import LocalStore
import RecordArchive
import SwiftUI

/// Step links belong to the exact chosen or replacement ingredient snapshot.
struct DinnerCookingPage: Equatable, Encodable {
    struct Ingredient: Equatable, Encodable {
        let name: String
        let amount: Quantity?
        let group: String?
        let protected: Bool

        var label: String {
            var parts = [name]
            if amount != nil || group != nil { parts.append(dinnerQuantity(amount)) }
            if let group { parts.append(group) }
            if protected { parts.append(ledgerText("Protected")) }
            return parts.joined(separator: " · ")
        }
    }
    let id: UUID
    let replacement: UUID?
    let title: String
    let servings: Rational
    let notes: String
    let ingredients: [Ingredient]
    let steps: [RecipeStep]

    init(original meal: MealOccurrence, shop: ShoppingLedger, planning: DinnerPlanningState) throws {
        guard meal.carryover == nil, meal.removedAt == nil else { throw PickupMealRecoveryError.sourceChanged }
        id = meal.id; replacement = nil; title = meal.title; servings = meal.servings; notes = meal.notes
        let hasSavedBindings = planning.portionBindings.contains { $0.occurrenceID == meal.id }
        let saved = hasSavedBindings
            ? (try? DinnerPlanningEngine.manualPortionBindings(occurrenceID: meal.id, ledger: shop, state: planning)) ?? [] : []
        let bindings = Dictionary(grouping: saved, by: \.contributionID)
        var displayed: [Ingredient] = []
        var positions: [Range<Int>] = []
        for id in meal.ingredientContributionIDs {
            guard let row = shop.contributions.first(where: { $0.id == id }),
                  row.source == .meal(occurrenceID: meal.id) else { throw PickupMealRecoveryError.sourceChanged }
            let start = displayed.count
            if row.removedAt == nil {
                // An incomplete saved split is unresolved. Only a meal with no saved
                // bindings can use the pickup's proportional calculation.
                let reviewed = hasSavedBindings ? bindings[id] ?? [] : nil
                displayed += Self.ingredients(for: row, meal: meal, shop: shop, bindings: reviewed)
            }
            positions.append(start..<displayed.count)
        }
        ingredients = displayed
        let originalSteps = meal.recipeSteps ?? []
        try RecipeStep.validate(originalSteps, ingredientCount: positions.count)
        steps = originalSteps.map { original in
            var step = original
            step.ingredientIndices = original.ingredientIndices.flatMap { positions[$0] }
            return step
        }
    }

    private static func ingredients(for row: LedgerContribution, meal: MealOccurrence, shop: ShoppingLedger,
                                    bindings: [DinnerPortionBinding]?) -> [Ingredient] {
        guard !meal.servingGroups.isEmpty else {
            return [.init(name: row.productName, amount: row.quantity, group: nil, protected: false)]
        }
        if let bindings {
            return meal.servingGroups.map { group in
                let bound = bindings.first { $0.groupID == group.id }
                return .init(name: row.productName, amount: bound?.quantity, group: group.name, protected: group.isProtected)
            }
        }
        // Match the pickup's portion calculation for meals without explicit bindings.
        // Unknown source amounts stay unknown for every group.
        let portions = row.quantity.flatMap {
            try? LedgerMealPortions.review(meal: meal, contribution: row, in: shop, unit: $0.unit, bindings: [])
        }
        func quantity(_ amount: Rational?) -> Quantity? {
            guard let amount, let original = row.quantity else { return nil }
            return Quantity(amount: amount, unit: original.unit, originalLiteral: amount.description,
                            confirmedConversion: original.confirmedConversion)
        }
        var rows = meal.servingGroups.map { group in
            Ingredient(name: row.productName, amount: quantity(portions?.groups[group.id]), group: group.name, protected: group.isProtected)
        }
        if let unassigned = portions?.unassigned, unassigned > .zero {
            rows.append(.init(name: row.productName, amount: quantity(unassigned), group: nil, protected: false))
        }
        return rows
    }

    init(recovered value: PickupRecoveryMealDefinition) throws {
        try value.validate()
        let meal = value.meal
        id = meal.id; replacement = meal.revisionID; title = meal.title; servings = meal.servings; notes = value.notes
        ingredients = meal.ingredients.map { item in
            let group = value.groups.first { $0.id == item.groupID }
            return Ingredient(name: item.foodName, amount: item.need.amount, group: group?.name,
                              protected: item.need.priority == .protected)
        }
        if let template = value.acceptedTemplate {
            steps = (template.recipeSteps ?? []).map { original in
                var step = original
                let linked = Set(original.ingredientIndices.compactMap { index in
                    template.ingredients.indices.contains(index) ? template.ingredients[index].id : nil
                })
                step.ingredientIndices = meal.ingredients.indices.filter { index in
                    let item = meal.ingredients[index]
                    return item.need.priority != .protected && linked.contains(item.ingredientID)
                }
                return step
            }
        } else { steps = [] }
        try RecipeStep.validate(steps, ingredientCount: ingredients.count)
    }
}

@MainActor struct ChosenDinnerCookingEntry: View {
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    let shopID: UUID
    let mealID: UUID
    let current: () throws -> DinnerCookingPage
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @State private var page: DinnerCookingPage?
    @State private var context: CookingSessionContext?

    var body: some View {
        Group {
            if let page, let context, context.authorize() {
                CookingSessionView(title: page.title, steps: page.steps, ingredients: page.ingredients.map(\.label),
                    legacyNotes: page.notes, yieldText: dinnerFormat("Servings: %@", page.servings.description), context: context,
                    finishTitle: finishTitle) {
                        if pickup.pantryIsActive {
                            CookCompletionEntry(ledger: ledger, pickup: pickup, shopID: shopID, mealID: mealID)
                        } else if pickup.pantryRouteAvailable {
                            PantrySetupView(pickup: pickup, ledger: ledger)
                        }
                    }
            } else {
                Text(recordsText("Open this recipe from your current private workspace."))
            }
        }
        .task { open() }
        .onChange(of: scene) { _, phase in
            if phase == .active { open() }
            else { page = nil; context = nil }
        }
    }
    private var finishTitle: String? {
        if pickup.pantryIsActive { return cookCompletionText("Record cooking and leftovers") }
        return pickup.pantryRouteAvailable ? cookCompletionText("Set up My Pantry to record cooking and leftovers") : nil
    }
    private var identity: CapturePrivateIdentity? {
        guard scene == .active, UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
              child?.presented != true, household.projection?.grantId == nil, ledger.ready, ledger.shop?.id == shopID,
              pickup.ready else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private func open() {
        guard let actor = identity, let workspace = ledger.sourceWorkspaceID, let source = try? current(), source.id == mealID,
              let bytes = try? ArchiveCodec.canonical(source),
              let key = try? CookingSessionKey(workspace: workspace, actor: actor.actorID,
                audience: [actor.subject, actor.householdID, actor.memberID, actor.role, shopID.uuidString],
                kind: .dinner, source: mealID, revision: ArchiveCodec.digest(bytes)) else {
            page = nil; context = nil; return
        }
        page = source
        context = CookingSessionContext(key: key, authorize: {
            identity == actor && ledger.sourceWorkspaceID == workspace && (try? current()) == source
        })
    }
}
