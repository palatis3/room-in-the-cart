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
            if let amount { parts.append(dinnerQuantity(amount)) }
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

    init(original meal: MealOccurrence, shop: ShoppingLedger) throws {
        guard meal.carryover == nil, meal.removedAt == nil else { throw PickupMealRecoveryError.sourceChanged }
        id = meal.id; replacement = nil; title = meal.title; servings = meal.servings; notes = meal.notes
        let rows = try meal.ingredientContributionIDs.compactMap { id -> LedgerContribution? in
            guard let row = shop.contributions.first(where: { $0.id == id }),
                  row.source == .meal(occurrenceID: meal.id) else { throw PickupMealRecoveryError.sourceChanged }
            return row.removedAt == nil ? row : nil
        }
        ingredients = rows.map { Ingredient(name: $0.productName, amount: $0.quantity, group: nil, protected: false) }
        steps = RecipeStep.rebinding(meal.recipeSteps ?? [], from: meal.ingredientContributionIDs, to: rows.map(\.id))
        try RecipeStep.validate(steps, ingredientCount: ingredients.count)
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
