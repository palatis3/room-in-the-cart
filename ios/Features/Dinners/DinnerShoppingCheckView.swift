import SwiftUI
import CoreDomain

struct DinnerShoppingCheckLink: View {
    let shopID: UUID
    let occurrenceID: UUID
    var linkedProducts = false

    var body: some View {
        NavigationLink {
            DinnerShoppingCheckView(shopID: shopID, occurrenceID: occurrenceID)
        } label: {
            Label(dinnerText(linkedProducts ? "Review pantry purchases" : "Check what to buy"), systemImage: "checklist")
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
                let linked = pickup.sourceWorkspaceID.map {
                    ledger.workspace.dinnerPantryLines(shop: shop, workspaceID: admitted.ledger, originID: $0,
                        actorID: admitted.identity.actorID.uuidString, occurrenceID: occurrenceID)
                } ?? []
                if !linked.isEmpty, admitted.identity.subject == nil, admitted.identity.householdID == nil,
                   refreshed == admitted {
                    DinnerPurchaseChoices(ledger: ledger, pickup: pickup, shop: shop, occurrenceID: occurrenceID,
                        linked: linked, identity: admitted.identity, authorize: { origin == admitted })
                    NavigationLink(ledgerText("Shopping list")) { LedgerHomeView(model: ledger) }
                } else if needsListReview(shop: shop, check: check) {
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

/// The saved checkout proof is the single authority for both purchase views.
/// Missing authority, replacement stock and reopened edits all show the gross row.
@MainActor enum DinnerPantryPurchases {
    static func lines(ledger: LedgerModel, pickup: PickupModel, shop: ShoppingLedger,
                      identity: CapturePrivateIdentity?, occurrenceID: UUID? = nil) -> Set<UUID> {
        guard let identity, identity.subject == nil, identity.householdID == nil, pickup.currentDinnerActorID == identity.actorID, ledger.ready,
              !ledger.hasPendingSave, !ledger.saving, !ledger.hasPendingPantryProjection,
              let id = ledger.sourceWorkspaceID, let origin = pickup.sourceWorkspaceID,
              ledger.shop?.id == shop.id, !ledger.workspace.packSelections.isEmpty,
              let context = try? pickup.quickGroceryPantryContext(ledgerWorkspaceID: id),
              let journey = pickup.journeys.first(where: { $0.id == shop.id }),
              journey.closedAt == nil, journey.pickup == nil, journey.basket?.phase == .draft else { return [] }
        let eligible = ledger.workspace.dinnerPantryLines(shop: shop, workspaceID: id, originID: origin,
            actorID: identity.actorID.uuidString, occurrenceID: occurrenceID)
        guard !eligible.isEmpty,
              let review = try? LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision,
                  previous: journey, packSelections: ledger.workspace.packSelections, workspaceID: id, pickupWorkspaceID: origin,
                  bindings: ledger.workspace.dinnerPlanning.portionBindings, pantryContext: context, pantryIsActive: true)
        else { return [] }
        return Set(review.packSelections.filter { $0.isNoPurchase && $0.request.offerA.id == DinnerPantryProducts.atHomeOfferID && $0.canonicalStockEvidence?.basis.originID == origin }
            .map(\.lineID)).intersection(eligible)
    }
}

struct ShoppingDinnerPantry: DynamicProperty {
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child

    @MainActor func covered(in shop: ShoppingLedger, ledger: LedgerModel) -> Set<UUID> {
        guard scene == .active, UIApplication.shared.isProtectedDataAvailable, child?.presented != true,
              !household.guardianChildOnly, household.projection?.grantId == nil else { return [] }
        return DinnerPantryPurchases.lines(ledger: ledger, pickup: pickup, shop: shop,
            identity: CapturePrivateIdentity.current(access: access, household: household))
    }
}

struct SavedDinnerProductChoice {
    let reservedFoods: Set<UUID>
    let match: PantryMealMatcher.Review
    let basis: LedgerCanonicalPackStockEvidence.Basis
    let generation: UUID
}

struct SavedDinnerProductPicker: View {
    let recipe: MealTemplate
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    let authorize: @MainActor () -> Bool
    let choose: (SavedDinnerProductChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input: TonightMealModel.Input?
    @State private var matches: [UUID: UUID] = [:]
    @State private var failed = false

    var body: some View {
        WorkingForm {
            if authorize(), let input {
                Text(dinnerText("Choose each pantry product you want to use. Only a separately confirmed allocation can remove a purchase."))
                ForEach(recipe.ingredients.filter { ($0.quantity?.amount ?? .zero) > .zero }) { row in
                    Picker(row.name, selection: Binding(get: { matches[row.id] }, set: { matches[row.id] = $0 })) {
                        Text(tonightText("Not matched")).tag(UUID?.none)
                        ForEach(input.foods) { food in
                            Text(verbatim: food.name + " · " + food.detail + " · " + food.id.uuidString.suffix(6))
                                .tag(Optional(food.id))
                        }
                    }.pickerStyle(.menu)
                }
                Button(dinnerText("Use these product matches")) {
                    do {
                        let match = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: matches,
                            globallyFreeLots: input.freeLots, unresolvedFoods: input.unresolvedFoods,
                            profile: input.workspace.dinnerPlanning.privateMealPreferences)
                        _ = try DinnerPantryProducts(review: match, workspace: ledger.workspace, originID: input.basis.originID,
                            destinationShopID: ledger.shop?.id, reservedFoods: input.reservedFoods)
                        guard authorize(), ledger.revision == input.ledgerRevision,
                              pickup.sourceWorkspaceID == input.basis.originID else { throw DinnerPlanningError.stalePreview }
                        choose(.init(reservedFoods: input.reservedFoods, match: match, basis: input.basis, generation: pickup.privatePantryGeneration))
                        dismiss()
                    } catch { failed = true }
                }.disabled(matches.isEmpty)
            } else if !failed && authorize() { ProgressView() }
            if failed { Text(dinnerText("Check the product, available amount and other list commitments before trying again.")) }
        }.navigationTitle(dinnerText("Match food at home")).navigationBarTitleDisplayMode(.inline).privacySensitive()
            .toolbar { Button(ledgerText("Cancel")) { dismiss() } }
            .task {
                guard authorize(), let id = ledger.sourceWorkspaceID, pickup.pantryIsActive, pickup.pantryRouteAvailable,
                      await pickup.refreshPantryStock(), authorize(),
                      let context = try? pickup.quickGroceryPantryContext(ledgerWorkspaceID: id),
                      let value = try? TonightMealModel.input(workspace: ledger.workspace, ledgerRevision: ledger.revision,
                          context: context, sources: []) else { failed = true; return }
                input = value
            }
    }
}

private struct DinnerPurchaseChoices: View {
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    let shop: ShoppingLedger
    let occurrenceID: UUID
    let linked: Set<UUID>
    let identity: CapturePrivateIdentity
    let authorize: @MainActor () -> Bool
    @State private var allocation: DinnerAllocationChoice?
    @State private var review: DinnerPurchaseDecision?
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        Section(dinnerText("Use food at home")) {
            let covered = DinnerPantryPurchases.lines(ledger: ledger, pickup: pickup, shop: shop, identity: identity,
                occurrenceID: occurrenceID)
            if !pickup.journeys.contains(where: { $0.id == shop.id }) {
                if let allocation {
                    Text(dinnerFormat("Save a draft checkout for %@ with these needs. This sets aside available food without changing physical counts.", shop.title))
                    ForEach(allocation.checkout.lines) { line in
                        LabeledContent(line.name, value: ledgerQuantity(line.quantity))
                    }
                    Button(dinnerText("Save meal allocations")) {
                        Task {
                            guard !busy else { return }
                            busy = true
                            let saved = try? await LedgerCheckoutAdapter.apply(allocation.checkout, ledger: ledger, pickup: pickup,
                                freshDinnerBasis: allocation.basis, authorize: authorize)
                            busy = false; self.allocation = nil; failed = saved != true
                        }
                    }.buttonStyle(PrimaryAction()).disabled(busy)
                    Button(ledgerText("Cancel")) { self.allocation = nil }.disabled(busy)
                } else {
                    Button(dinnerText("Review shopping allocations")) {
                        do {
                            guard authorize() else { throw DinnerPlanningError.forbidden }
                            allocation = try DinnerAllocationChoice(ledger: ledger, pickup: pickup, shop: shop,
                                occurrenceID: occurrenceID, identity: identity, linked: linked)
                            failed = false
                        } catch { failed = true }
                    }
                }
            } else if pickup.journeys.first(where: { $0.id == shop.id })?.ledgerSourceRevisionID != shop.revisionID {
                Text(dinnerText("Review this list’s checkout copy to allocate confirmed pantry food to its meal needs. Saving the copy keeps pantry counts intact."))
                NavigationLink(dinnerText("Review shopping allocations")) {
                    LedgerCheckoutEntry(ledger: ledger, pickup: pickup)
                }
            } else if !covered.isEmpty && covered == linked {
                Text(dinnerText("Putting these back restores the purchases. The meal keeps its allocation in the checkout copy."))
                ForEach(shop.lines.filter { covered.contains($0.id) }) { line in
                    LabeledContent(line.name, value: dinnerText("Using food at home"))
                }
                NavigationLink(ledgerText("Review checkout")) { LedgerCheckoutEntry(ledger: ledger, pickup: pickup) }
                Button(dinnerText("Put these ingredients back on the shopping list")) {
                    Task { await undo(covered) }
                }.disabled(busy)
            } else if let review {
                Text(dinnerFormat("Remove the following purchases from %@ using the confirmed food allocated to this dinner.", shop.title))
                ForEach(review.selections) { selection in
                    LabeledContent(selection.request.itemName, value: ledgerQuantity(selection.request.needed))
                    if let proof = selection.canonicalStockEvidence {
                        ForEach(proof.lots.filter { batch in proof.allocations.contains { $0.lotID == batch.lot.id } }, id: \.lot.id) { batch in
                            let lot = batch.lot
                            Text(verbatim: lot.name + " · " + lot.confirmedAt.formatted(date: .abbreviated, time: .shortened) + " · " + lot.id.uuidString.suffix(6))
                                .font(.caption)
                        }
                    }
                }
                Text(dinnerText("Every meal ingredient stays in the plan. Cooking records the amount actually used."))
                Button(dinnerText("Use the allocated food")) {
                    Task {
                        guard !busy else { return }
                        busy = true
                        let saved = await review.save(ledger: ledger, authorize: authorize)
                        busy = false
                        self.review = nil
                        failed = !saved
                    }
                }.buttonStyle(PrimaryAction()).disabled(busy)
                Button(ledgerText("Cancel")) { self.review = nil }.disabled(busy)
            } else {
                Button(dinnerText("Review food to use at home")) {
                    do {
                        guard authorize() else { throw DinnerPlanningError.forbidden }
                        review = try DinnerPurchaseDecision(ledger: ledger, pickup: pickup, shop: shop,
                            occurrenceID: occurrenceID, identity: identity, linked: linked)
                        failed = false
                    } catch { failed = true }
                }
            }
            if failed {
                Text(dinnerText("Check the product, available amount and other list commitments before trying again."))
            }
        }
    }

    private func undo(_ covered: Set<UUID>) async {
        guard !busy else { return }
        busy = true
        let saved = await DinnerPurchaseDecision.restore(covered, shop: shop, occurrenceID: occurrenceID, ledger: ledger,
            pickup: pickup, identity: identity, authorize: authorize)
        busy = false
        failed = !saved
    }
}

extension PantryPackStockReview.Context {
    var reservedFoods: Set<UUID> { Set(snapshot.reservations.lazy.filter { $0.state != .released }.map(\.foodID)) }

    var dinnerBasis: LedgerCanonicalPackStockEvidence.Basis {
        .init(originID: snapshot.state.workspaceID, inventoryRevision: snapshot.state.revision,
            sourceHeads: mapping.sourceHeads.map { .init(journeyID: $0.id, revision: $0.revision) }
                .sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
    }
}

@MainActor struct DinnerAllocationChoice {
    let checkout: LedgerCheckoutReview
    let basis: LedgerCanonicalPackStockEvidence.Basis

    init(ledger: LedgerModel, pickup: PickupModel, shop: ShoppingLedger, occurrenceID: UUID,
         identity: CapturePrivateIdentity, linked: Set<UUID>) throws {
        guard !linked.isEmpty, identity.subject == nil, identity.householdID == nil,
              pickup.currentDinnerActorID == identity.actorID, ledger.shop == shop, let id = ledger.sourceWorkspaceID,
              !pickup.journeys.contains(where: { $0.id == shop.id }),
              let context = try pickup.quickGroceryPantryContext(ledgerWorkspaceID: id),
              ledger.workspace.dinnerPantryLines(shop: shop, workspaceID: id, originID: context.snapshot.state.workspaceID,
                  actorID: identity.actorID.uuidString, occurrenceID: occurrenceID) == linked
        else { throw DinnerPlanningError.stalePreview }
        basis = context.dinnerBasis
        let saved = ledger.workspace.mealTemplates + ledger.workspace.dinnerPlanning.acceptedDinners.map(\.template)
        let check = try DinnerShoppingCheck(shop: shop, occurrenceID: occurrenceID, savedTemplates: saved)
        let input = try TonightMealModel.input(workspace: ledger.workspace, ledgerRevision: ledger.revision, context: context, sources: [])
        let sources = shop.contributions.filter { linked.contains($0.lineID) && $0.source == .meal(occurrenceID: occurrenceID) && $0.removedAt == nil }
        let matches = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.lineID) })
        let review = try check.review(matches: matches, input: input, workspace: ledger.workspace, journeys: pickup.journeys)
        guard review.eligibility.eligible, Set(review.ingredients.filter(\.covered).compactMap(\.foodID)) == linked
        else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
        checkout = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        let foods = Set(checkout.needs.map(\.orderLineID))
        let peers = context.snapshot.reservations.filter { foods.contains($0.foodID) && $0.state != .released }
        let reused = ledger.workspace.previouslyListedPantryProducts(in: shop.id, among: linked)
        guard reused.isDisjoint(with: peers.map(\.foodID)) else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
        let coverage = Dictionary(uniqueKeysWithValues: context.snapshot.availability.reservations.map { ($0.id,$0) })
        // A new checkout may project every list line. Admit only older fully
        // backed, lot-specific protected claims, which allocate before our needs.
        guard ledger.workspace.packSelections.allSatisfy({ $0.shopID != shop.id }), peers.allSatisfy({ hold in
            hold.lotID != nil && hold.priority == .protected && coverage[hold.id]?.issues.isEmpty == true &&
                coverage[hold.id]?.shortfall?.amount == .zero
        }) else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
    }
}

@MainActor struct DinnerPurchaseDecision {
    let selections: [LedgerPackSelection]
    let basis: LedgerCanonicalPackStockEvidence.Basis
    private let workspace: LedgerWorkspace
    private let workspaceID: UUID
    private let operationID = UUID()

    init(ledger: LedgerModel, pickup: PickupModel, shop: ShoppingLedger, occurrenceID: UUID,
         identity: CapturePrivateIdentity, linked: Set<UUID>) throws {
        guard identity.subject == nil, identity.householdID == nil, pickup.currentDinnerActorID == identity.actorID, let id = ledger.sourceWorkspaceID,
              !linked.isEmpty, ledger.shop == shop,
              let context = try pickup.quickGroceryPantryContext(ledgerWorkspaceID: id),
              let journey = pickup.journeys.first(where: { $0.id == shop.id }), journey.closedAt == nil,
              journey.pickup == nil, journey.basket?.phase == .draft, journey.ledgerSourceRevisionID == shop.revisionID,
              journey.cookedMeals?.contains(where: { $0.isActive }) != true, journey.mealRecovery == nil,
              ledger.workspace.dinnerPantryLines(shop: shop, workspaceID: id, originID: context.snapshot.state.workspaceID,
                  actorID: identity.actorID.uuidString, occurrenceID: occurrenceID) == linked
        else { throw DinnerPlanningError.stalePreview }
        workspaceID = id
        workspace = ledger.workspace
        basis = context.dinnerBasis
        let bindings = workspace.dinnerPlanning.portionBindings
        let coverage = Dictionary(uniqueKeysWithValues: context.snapshot.availability.reservations.map { ($0.id, $0) })
        let claims = context.snapshot.reservations.filter { linked.contains($0.foodID) && $0.state != .released }
        guard claims.allSatisfy({ coverage[$0.id]?.issues.isEmpty == true && coverage[$0.id]?.shortfall?.amount == .zero })
        else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
        let offers = (PackOffer(id: DinnerPantryProducts.atHomeOfferID, label: ledgerText("Confirmed food at home"), usableQuantity: nil, price: nil),
                      PackOffer(id: DinnerPantryProducts.alternateOfferID, label: ledgerText("Confirmed food at home"), usableQuantity: nil, price: nil))
        let current = DinnerPantryPurchases.lines(ledger: ledger, pickup: pickup, shop: shop, identity: identity, occurrenceID: occurrenceID)
        let reused = workspace.previouslyListedPantryProducts(in: shop.id, among: linked)
        let remaining = linked.subtracting(current)
        guard !remaining.isEmpty else { throw DinnerPlanningError.stalePreview }
        selections = try shop.lines.filter { remaining.contains($0.id) }.map { line in
            let requirement = try LedgerPackRequirement.review(shop: shop, lineID: line.id, bindings: bindings)
            let evidence = try PantryPackStockReview.evidence(shop: shop, lineID: line.id, requirement: requirement,
                bindings: bindings, context: context)
            if reused.contains(line.id) {
                let owned = Set(evidence.partition.compactMap { $0.binding.reservationID })
                let physical = Set(claims.lazy.filter { $0.foodID == line.id }.map(\.id))
                guard !owned.isEmpty, physical == owned else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
            }
            let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
                confirmedAtHome: try evidence.confirmedQuantity(for: requirement), protectedAmount: requirement.protectedQuantity,
                offerA: offers.0, offerB: offers.1, itemCap: nil)
            let selection = try LedgerPackSelection(workspaceID: id, shop: shop, lineID: line.id, request: request,
                selectedOfferID: offers.0.id, at: context.asOf, source: ledgerText("Reviewed pantry or freezer allocation"),
                bindings: bindings, canonicalStockEvidence: evidence)
            guard selection.isNoPurchase else { throw DinnerPlanningError.reviewRequired("pantryProduct") }
            return selection
        }
    }

    static func restore(_ covered: Set<UUID>, shop: ShoppingLedger, occurrenceID: UUID, ledger: LedgerModel, pickup: PickupModel,
                        identity: CapturePrivateIdentity, authorize: @escaping @MainActor () -> Bool) async -> Bool {
        guard !covered.isEmpty, authorize(), let id = ledger.sourceWorkspaceID,
              let context = try? pickup.quickGroceryPantryContext(ledgerWorkspaceID: id),
              DinnerPantryPurchases.lines(ledger: ledger, pickup: pickup, shop: shop,
                  identity: identity, occurrenceID: occurrenceID) == covered else { return false }
        let workspace = ledger.workspace
        let rows = workspace.packSelections.filter { $0.shopID == shop.id && covered.contains($0.lineID) }
        guard rows.allSatisfy({ $0.isNoPurchase && $0.request.offerA.id == DinnerPantryProducts.atHomeOfferID && $0.canonicalStockEvidence?.basis.originID == context.snapshot.state.workspaceID }),
              Set(rows.map(\.lineID)) == covered else { return false }
        let ids = Set(rows.map(\.id))
        return await ledger.change(key: "restore-dinner-purchases-\(UUID())", reviewedPantryBasis: context.dinnerBasis,
            authorize: authorize) { current in
            guard current == workspace else { throw DinnerPlanningError.stalePreview }
            current.packSelections.removeAll { ids.contains($0.id) }
        }
    }

    func save(ledger: LedgerModel, authorize: @escaping @MainActor () -> Bool) async -> Bool {
        guard authorize(), ledger.sourceWorkspaceID == workspaceID else { return false }
        return await ledger.change(key: "dinner-purchases-\(operationID)", reviewedPantryBasis: basis, authorize: authorize) { current in
            if selections.allSatisfy({ current.packSelections.contains($0) }) { return }
            guard current == workspace else { throw DinnerPlanningError.stalePreview }
            for choice in selections {
                _ = try current.recordPackSelection(choice, workspaceID: workspaceID, currentCanonicalEvidence: choice.canonicalStockEvidence)
            }
        }
    }
}
