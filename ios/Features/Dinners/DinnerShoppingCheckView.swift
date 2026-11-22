import SwiftUI
import CoreDomain

struct DinnerShoppingCheckLink: View {
    let shopID: UUID
    let occurrenceID: UUID

    var body: some View {
        NavigationLink {
            DinnerShoppingCheckView(shopID: shopID, occurrenceID: occurrenceID)
        } label: {
            Label(dinnerText("Check what to buy"), systemImage: "checklist")
        }.accessibilityIdentifier("dinner.checkShopping")
    }
}

private struct DinnerShoppingCheckView: View {
    let shopID: UUID
    let occurrenceID: UUID
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.scenePhase) private var scene
    @State private var admitted: Origin?
    @State private var refreshed: Origin?

    private struct Origin: Equatable {
        let identity: CapturePrivateIdentity
        let ledger: UUID
        let accessGeneration: UUID
        let pantryGeneration: UUID
    }
    private var origin: Origin? {
        guard scene == .active, UIApplication.shared.isProtectedDataAvailable, !household.guardianChildOnly,
              child?.presented != true, household.projection?.grantId == nil,
              let identity = CapturePrivateIdentity.current(access: access, household: household),
              ledger.ready, !ledger.hasPendingLedgerDeletion, !ledger.hasPendingPantryProjection, ledger.shop?.id == shopID,
              let id = ledger.sourceWorkspaceID else { return nil }
        return Origin(identity: identity, ledger: id, accessGeneration: access.generation, pantryGeneration: pickup.privatePantryGeneration)
    }
    var body: some View {
        WorkingForm {
            if let admitted, admitted == origin, let shop = ledger.shop,
               !ledger.saving, !ledger.hasPendingSave, pickup.ready, !pickup.saving, !pickup.hasPendingSave,
               let check = try? DinnerShoppingCheck(shop: shop, occurrenceID: occurrenceID,
                    savedTemplates: ledger.workspace.mealTemplates + ledger.workspace.dinnerPlanning.acceptedDinners.map(\.template)) {
                if needsListReview(shop: shop, check: check) {
                    Text(dinnerText("Review the current shopping list for this dinner’s purchases and allocations."))
                    NavigationLink(ledgerText("Shopping list")) { LedgerHomeView(model: ledger) }
                } else {
                    let context = refreshed == admitted ? try? pickup.quickGroceryPantryContext(ledgerWorkspaceID: admitted.ledger) : nil
                    DinnerShoppingEstimate(check: check, context: context, workspace: ledger.workspace, ledgerRevision: ledger.revision,
                                           journeys: pickup.journeys)
                        .id(shop.revisionID)
                }
            } else if origin != nil && (admitted == nil || pickup.saving || ledger.saving) {
                ProgressView()
            } else {
                Text(currentDinnerText("Current dinners could not be verified. Reopen the same pickup and review its saved changes."))
            }
        }.navigationTitle(dinnerText("Check what to buy")).navigationBarTitleDisplayMode(.inline)
            .privacySensitive()
            .task(id: origin) {
                refreshed = nil
                guard let current = origin else { return }
                if admitted == nil { admitted = current }
                guard admitted == current, pickup.pantryIsActive, pickup.pantryRouteAvailable,
                      !pickup.saving, !pickup.hasPendingSave, !ledger.saving, !ledger.hasPendingSave else { return }
                if await pickup.refreshPantryStock(), !Task.isCancelled, origin == current { refreshed = current }
            }
    }

    // Free stock has already had existing allocations subtracted. A meal that
    // has reached checkout must use its real purchase and allocation review.
    private func needsListReview(shop: ShoppingLedger, check: DinnerShoppingCheck) -> Bool {
        let started = shop.lines.contains { line in
            check.lineIDs.contains(line.id) && (line.isTrashed || line.isChecked || line.isHandled ||
                line.tripPick != nil || line.packagePick != nil || line.stopObservation != nil)
        }
        if started { return true }
        guard let journey = pickup.journeys.first(where: { $0.id == shop.id }) else { return false }
        return journey.closedAt != nil || journey.pickup != nil || (journey.basket?.phase ?? .draft) != .draft ||
            journey.cookedMeals?.contains(where: { $0.isActive && $0.draft.meal.id == occurrenceID }) == true ||
            journey.mealRecovery?.domain.events.contains(where: { $0.request.target.id == occurrenceID }) == true ||
            journey.plannedNeeds.contains { check.lineIDs.contains($0.orderLineID) } ||
            journey.needDetails.contains { $0.sourceOccurrenceID == occurrenceID }
    }
}

private struct DinnerShoppingEstimate: View {
    let check: DinnerShoppingCheck
    let context: PantryPackStockReview.Context?
    let workspace: LedgerWorkspace
    let ledgerRevision: Int64
    let journeys: [PickupJourney]
    @State private var input: TonightMealModel.Input?
    @State private var matches: [UUID: UUID] = [:]
    private var basis: LedgerCanonicalPackStockEvidence.Basis? {
        context.map { context in
            .init(originID: context.snapshot.state.workspaceID, inventoryRevision: context.snapshot.state.revision,
                  sourceHeads: context.mapping.sourceHeads.map { .init(journeyID: $0.id, revision: $0.revision) }
                    .sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
        }
    }
    var body: some View {
        let current = input.flatMap { $0.basis == basis ? $0 : nil }
        let review = current.flatMap { input in
            try? check.review(matches: matches, input: input, workspace: workspace, journeys: journeys)
        }
        Section {
            Text(verbatim: check.recipe.title).font(.headline)
            Text(dinnerText("Preview for this dinner only. Your matches last until you leave. The shopping list and pantry stay as they are."))
        }.task(id: basis) {
            if let basis, input?.basis == basis { return }
            matches = [:]
            guard let context else { input = nil; return }
            input = try? TonightMealModel.input(workspace: workspace, ledgerRevision: ledgerRevision, context: context, sources: [])
        }
        if let review, review.eligibility.eligible {
            let remaining = review.ingredients.filter { DinnerShoppingCheck.remainder($0) != .covered }
            Section(dinnerText("Still to buy or check")) {
                if review.ingredients.isEmpty {
                    Text(dinnerText("This dinner has no planned ingredients."))
                } else if remaining.isEmpty {
                    Text(dinnerText("No additional amount needed for this dinner."))
                }
                ForEach(remaining) { row in
                    if case .buy(let quantity) = DinnerShoppingCheck.remainder(row) {
                        LabeledContent(row.ingredient.name, value: ledgerQuantity(quantity))
                    } else {
                        LabeledContent(row.ingredient.name, value: dinnerText("Check amount"))
                    }
                }
            }.accessibilityIdentifier("dinner.shoppingRemainder")
        } else {
            Section(dinnerText("Planned ingredients")) {
                ForEach(check.recipe.ingredients) { ingredient in
                    LabeledContent(ingredient.name, value: ingredient.reviewedAmountLabel)
                }
                Text(dinnerText(current == nil ? "Pantry availability could not be verified." :
                    "Check meal preferences and ingredient details before using these pantry matches."))
            }
        }
        if let current, !current.foods.isEmpty {
            let names = Dictionary(grouping: current.foods, by: \.name)
            Section(dinnerText("Match food at home")) {
                Text(dinnerText("Choose the pantry product for each ingredient you have. Only its unreserved amount counts. Unmatched ingredients show their full planned amount."))
                ForEach(check.recipe.ingredients.filter { $0.quantity != nil }) { ingredient in
                    Picker(ingredient.name, selection: Binding(get: { matches[ingredient.id] }, set: { matches[ingredient.id] = $0 })) {
                        Text(tonightText("Not matched")).tag(UUID?.none)
                        ForEach(current.foods) { food in
                            let duplicate = (names[food.name]?.count ?? 0) > 1
                            Text(verbatim: duplicate ? food.name + " · " + food.detail + " · " + food.id.uuidString.suffix(6) : food.name)
                                .tag(Optional(food.id))
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("dinner.shoppingMatch." + ingredient.id.uuidString)
                }
            }
        }
    }
}

extension DinnerShoppingCheck {
    @MainActor func review(matches: [UUID: UUID], input: TonightMealModel.Input, workspace: LedgerWorkspace,
                           journeys: [PickupJourney]) throws -> PantryMealMatcher.Review {
        let shopRevisions = Dictionary(uniqueKeysWithValues: workspace.shops.map { ($0.id, $0.revisionID) })
        let checkedOutLines = journeys.reduce(into: [UUID: Set<UUID>]()) { result, journey in
            if let revision = journey.ledgerSourceRevisionID, revision == shopRevisions[journey.id] {
                result[journey.id] = Set(journey.plannedNeeds.map(\.orderLineID))
            }
        }
        let awaiting = foodsAwaitingAllocation(in: workspace.shops, matched: Set(matches.values), currentCheckoutLines: checkedOutLines)
        return try PantryMealMatcher.review(recipe: recipe, reviewedFoods: matches, globallyFreeLots: input.freeLots,
            unresolvedFoods: input.unresolvedFoods.union(awaiting), profile: workspace.dinnerPlanning.privateMealPreferences)
    }
}
