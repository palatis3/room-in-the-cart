import Foundation
import CoreDomain

struct DinnerSwapOption: Identifiable {
    enum Issue: Equatable { case servingsMismatch, protectedTarget, targetNeedsGroup, linkedTarget, unavailableRecipe, paidAccessRequired }
    let id: UUID
    let title: String
    let template: MealTemplate
    let eligibility: MealEligibilityPolicy.Result
    let foods: [IdeaSupplyFood]
    let groupID: UUID?
    let issue: Issue?
    var canChoose: Bool { issue == nil && eligibility.eligible }
    fileprivate let targetID: UUID
    fileprivate let binding: DinnerSwapBinding
}

fileprivate struct DinnerSwapBinding: Equatable {
    let identity: DinnerFeatureModel.EditorIdentity
    let shopRevision: UUID
    let planningRevision: UUID
    let preferenceRevision: UUID?
    let pantryBasis: DinnerPantrySupply.Basis?
}

struct DinnerSwapReview {
    struct Ingredient: Identifiable {
        let id: UUID
        let name: String
        let before: Quantity?
        let after: Quantity?
    }
    struct Food: Identifiable {
        let id: UUID
        let name: String
        let beforeNeeded: Quantity?
        let afterNeeded: Quantity?
        let free: [Quantity]
        let holds: [IdeaSupplyReservation]
        let unresolved: Bool
        let packageLabel: String?
        let packagePrice: Money?
        let beforePacks: Int64?
        let afterPacks: Int64?
        let beforeCost: Money?
        let afterCost: Money?
        let priceSource: String?
        let priceDate: Date?
    }
    struct Retained: Identifiable {
        let id: UUID
        let name: String
        let count: InventoryCount
        let location: InventoryLocation
        let confirmedAt: Date
        let purchased: Bool
    }
    let preview: DinnerPreview
    let original: MealOccurrence
    let replacement: MealTemplate
    let pantryBasis: DinnerPantrySupply.Basis?
    let ingredients: [Ingredient]
    let foods: [Food]
    let retained: [Retained]
}

@MainActor extension DinnerFeatureModel {
    private struct SwapContext {
        let shop: ShoppingLedger
        let original: MealOccurrence
        let access: DinnerAccessContext
        let binding: DinnerSwapBinding
        let canonical: PantryPackStockReview.Context?
        let supply: DinnerPantrySupply.Snapshot?
        let foods: [IdeaSupplyFood]
        let now: Date
    }

    private func swapContext(occurrenceID: UUID, pickup: PickupModel) throws -> SwapContext {
        guard editable, let shop, let identity = editorIdentity, let workspaceID = localIdeaWorkspaceID,
              pickup.ready, !pickup.saving, !pickup.hasPendingSave, pickup.recoveryLedger === store,
              phaseProvider(shop.id) == .draft,
              case .original(let original) = try currentMealDestination(occurrenceID, pickup: pickup),
              original.removedAt == nil, !original.isHidden, original.carryover == nil
        else { throw DinnerPlanningError.forbidden }
        let access = try access(for: shop.id), now = clock()
        guard case .local(let origin) = access.scope, origin == workspaceID else { throw DinnerPlanningError.forbidden }
        let canonical: PantryPackStockReview.Context?
        if pickup.pantryIsActive {
            guard let current = try pickup.pantryReviewContext() else { throw DinnerPlanningError.forbidden }
            canonical = current
        } else { canonical = nil }
        let supply = try canonical.map { try DinnerPantrySupply.build(context: $0, shopID: shop.id) }
        // A label is only a displayed choice. The caller must confirm each new
        // ingredient's food ID explicitly before it receives pantry/pack credit.
        var seen = Set<UUID>()
        let lineChoices = shop.lines.filter { !$0.isTrashed }.map {
            IdeaSupplyFood(id: $0.id, name: $0.name, detail: shop.title)
        }
        let foods = ((supply?.foods ?? []) + lineChoices).filter { seen.insert($0.id).inserted }
        let binding = DinnerSwapBinding(identity: identity, shopRevision: shop.revisionID,
            planningRevision: state.revisionID, preferenceRevision: state.preferences(for: access)?.revision, pantryBasis: supply?.basis)
        return SwapContext(shop: shop, original: original, access: access, binding: binding,
                           canonical: canonical, supply: supply, foods: foods, now: now)
    }

    func swapOptions(occurrenceID: UUID, groupID: UUID? = nil, pickup: PickupModel) throws -> [DinnerSwapOption] {
        let context = try swapContext(occurrenceID: occurrenceID, pickup: pickup)
        let original = context.original
        let group = groupID.flatMap { id in original.servingGroups.first { $0.id == id } }
        if groupID != nil && group == nil { throw DinnerPlanningError.stalePreview }
        let portions = group?.servings ?? original.servings
        let linked = context.shop.allocations.contains {
            original.ingredientContributionIDs.contains($0.demandContributionID) || original.ingredientContributionIDs.contains($0.supplyContributionID)
        }
        let alreadyChosen = Set(context.shop.mealOccurrences.filter { $0.removedAt == nil }.compactMap(\.templateID))
        return state.acceptedDinners.filter { !alreadyChosen.contains($0.template.id) }.map { accepted in
            let template = accepted.template
            let issue: DinnerSwapOption.Issue?
            if !context.access.hasPaidTools && state.freeReusableDinnerID != accepted.id { issue = .paidAccessRequired }
            else if group?.isProtected == true { issue = .protectedTarget }
            else if groupID == nil && !original.servingGroups.isEmpty { issue = .targetNeedsGroup }
            else if groupID == nil && linked { issue = .linkedTarget }
            else if template.servings != portions { issue = .servingsMismatch }
            else if (try? template.validate()) == nil || !Set(original.exclusions).isSubset(of: Set(template.exclusions)) {
                issue = .unavailableRecipe
            } else { issue = nil }
            return DinnerSwapOption(id: accepted.id, title: template.title, template: template,
                eligibility: MealEligibilityPolicy.evaluate(profile: state.preferences(for: context.access), template: template),
                foods: context.foods, groupID: groupID, issue: issue, targetID: occurrenceID, binding: context.binding)
        }
    }

    func prepareSwap(_ option: DinnerSwapOption, pickup: PickupModel, reviewedFoods: [UUID: UUID] = [:]) throws -> DinnerSwapReview {
        let context = try swapContext(occurrenceID: option.targetID, pickup: pickup)
        guard case .local(let workspaceID) = context.access.scope, context.binding == option.binding,
              let current = try swapOptions(occurrenceID: option.targetID, groupID: option.groupID, pickup: pickup).first(where: { $0.id == option.id }),
              current.template == option.template, current.canChoose,
              Set(reviewedFoods.keys).isSubset(of: Set(option.template.ingredients.map(\.id))),
              Set(reviewedFoods.values).isSubset(of: Set(context.foods.map(\.id)))
        else { throw DinnerPlanningError.stalePreview }
        try validateSwapMatches(template: option.template, reviewedFoods: reviewedFoods, context: context)
        let planned = PlannedDinner(acceptedDinnerID: option.id, template: option.template, day: context.original.scheduledDay)
        let preview = try DinnerSwapEngine.preview(occurrenceID: option.targetID, groupID: option.groupID,
            replacement: planned, ledger: context.shop, state: state, access: context.access,
            phase: phaseProvider(context.shop.id), at: context.now)
        return try DinnerSwapEvidence.build(preview: preview, original: context.original, replacement: planned,
            reviewedFoods: reviewedFoods, workspace: workspace, workspaceID: workspaceID,
            supply: context.supply, canonical: context.canonical, at: context.now)
    }

    /// Existing paid pairings retain their domain-vetted one-slot changes. The
    /// final confirmation recomputes canonical food evidence, never adopting a
    /// scenario's typed quantities as physical pantry stock.
    func prepareSwap(library: DinnerLibraryPairings, scenario: DinnerScenario,
                     reviewedPantryBasis: DinnerPantrySupply.Basis?, pickup: PickupModel) throws -> DinnerSwapReview {
        guard let shop else { throw DinnerPlanningError.forbidden }
        let changes = try library.replacement(for: scenario, shop: shop, state: state)
        guard changes.count == 2, case .choose(let planned) = changes[1] else { throw DinnerPlanningError.stalePreview }
        let targetID: UUID, groupID: UUID?
        switch changes[0] {
        case .remove(let id): targetID = id; groupID = nil
        case .adjust(let adjustment):
            targetID = adjustment.occurrenceID
            let removed = shop.mealOccurrences.first { $0.id == targetID }?.servingGroups.filter { group in
                !adjustment.groups.contains { $0.id == group.id }
            } ?? []
            guard removed.count == 1 else { throw DinnerPlanningError.stalePreview }
            groupID = removed.first?.id
        default: throw DinnerPlanningError.stalePreview
        }
        let context = try swapContext(occurrenceID: targetID, pickup: pickup)
        guard case .local(let workspaceID) = context.access.scope,
              reviewedPantryBasis == nil || reviewedPantryBasis == context.supply?.basis,
              let option = try swapOptions(occurrenceID: targetID, groupID: groupID, pickup: pickup).first(where: { $0.id == planned.acceptedDinnerID }),
              option.canChoose, option.template == planned.template else { throw DinnerPlanningError.stalePreview }
        let known = Set(context.foods.map(\.id))
        var matches: [UUID: UUID] = [:]
        for demand in scenario.demands where demand.acceptedDinnerID == planned.acceptedDinnerID {
            guard let ingredientID = demand.ingredientID, known.contains(demand.foodID),
                  planned.template.ingredients.contains(where: { $0.id == ingredientID }) else { continue }
            if let previous = matches[ingredientID], previous != demand.foodID { throw DinnerPlanningError.stalePreview }
            matches[ingredientID] = demand.foodID
        }
        try validateSwapMatches(template: planned.template, reviewedFoods: matches, context: context)
        let preview = try DinnerPlanningEngine.preview(changes: changes, tool: .pairing, ledger: shop, state: state,
            access: context.access, phase: phaseProvider(shop.id), at: context.now, swapOriginalID: targetID)
        return try DinnerSwapEvidence.build(preview: preview, original: context.original, replacement: planned,
            reviewedFoods: matches, workspace: workspace, workspaceID: workspaceID,
            supply: context.supply, canonical: context.canonical, at: context.now)
    }

    private func validateSwapMatches(template: MealTemplate, reviewedFoods: [UUID: UUID], context: SwapContext) throws {
        for ingredient in template.ingredients {
            guard let foodID = reviewedFoods[ingredient.id] else { continue }
            let labels = Array(Set(context.foods.filter { $0.id == foodID }.map(\.name)
                + (context.canonical?.snapshot.lots.filter { $0.foodID == foodID }.map(\.name) ?? [])))
            guard MealEligibilityPolicy.evaluateFood(profile: state.preferences(for: context.access), labels: labels, evidence: nil).eligible
            else { throw DinnerPlanningError.reviewRequired("foodPreferences") }
            let restrictions = Array(Set(context.original.exclusions + template.exclusions + ingredient.exclusions))
            try MealTemplate(title: template.title, ingredients: labels.map { .init(name: $0, quantity: nil) }, exclusions: restrictions).validate()
        }
    }
}

/// Pure scoped evidence projection: no writer, no reservation release and no old
/// selection's pantry credit. Both counterfactuals use the same already-free lots.
@MainActor enum DinnerSwapEvidence {
    static func build(preview: DinnerPreview, original: MealOccurrence, replacement: PlannedDinner,
                      reviewedFoods: [UUID: UUID], workspace: LedgerWorkspace, workspaceID: UUID,
                      supply: DinnerPantrySupply.Snapshot?, canonical: PantryPackStockReview.Context?, at now: Date) throws -> DinnerSwapReview {
        guard let shop = workspace.shops.first(where: { $0.id == preview.proposal.shopID }),
              shop.revisionID == preview.proposal.baseRevisionID,
              workspace.dinnerPlanning.revisionID == preview.proposal.planningRevisionID,
              preview.proposal.namespace == "local:\(workspaceID.uuidString)",
              shop.mealOccurrences.contains(original),
              preview.proposal.changes.contains(where: { if case .choose(let planned) = $0 { return planned == replacement }; return false })
        else { throw DinnerPlanningError.stalePreview }
        let changed = Set(preview.changedContributionIDs)
        let ingredients = preview.projectedContributions.filter { changed.contains($0.id) }.map { row in
            DinnerSwapReview.Ingredient(id: row.id, name: row.productName,
                before: shop.contributions.first { $0.id == row.id && $0.removedAt == nil }?.quantity,
                after: row.removedAt == nil ? row.quantity : nil)
        }
        var beforeLines: [UUID: Set<UUID>] = [:], afterLines: [UUID: Set<UUID>] = [:]
        var names: [UUID: String] = [:], order: [UUID] = []
        func include(_ food: UUID, name: String) {
            if names[food] == nil { names[food] = name; order.append(food) }
        }
        for row in shop.contributions where changed.contains(row.id) {
            include(row.lineID, name: row.productName)
            beforeLines[row.lineID, default: []].insert(row.lineID)
            afterLines[row.lineID, default: []].insert(row.lineID)
        }
        for (index, ingredient) in replacement.template.ingredients.enumerated() {
            let line = replacement.lineIDs[index], food = reviewedFoods[ingredient.id] ?? line
            include(food, name: ingredient.name)
            afterLines[food, default: []].insert(line)
            if shop.lines.contains(where: { $0.id == food && !$0.isTrashed && !$0.isHandled }) {
                beforeLines[food, default: []].insert(food); afterLines[food, default: []].insert(food)
            }
        }
        let confirmedIDs = Set(supply?.foods.map(\.id) ?? [])
        let live = try canonical.map { try PantryLiveStockProjection.buildGlobal(snapshot: $0.snapshot, mapping: $0.mapping, at: $0.asOf) }
        let unknown = Set(live?.lots.filter { $0.free == nil }.map { $0.current.foodID } ?? [])
        let rows = try order.map { id -> DinnerSwapReview.Food in
            let beforeIDs = beforeLines[id] ?? [], afterIDs = afterLines[id] ?? []
            let beforeValues = try beforeIDs.sorted(by: { $0.uuidString < $1.uuidString }).map { try shop.quantity(forLineID: $0) }
            let afterValues = try afterIDs.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { line -> Quantity?? in
                // Removed rows mean no remaining requirement, unlike a live row with unknown quantity.
                guard preview.projectedContributions.contains(where: { $0.lineID == line && $0.removedAt == nil }) else { return nil }
                return .some(try preview.projectedQuantity(forLineID: line))
            }
            let unit = beforeValues.compactMap { $0 }.first?.unit ?? afterValues.compactMap { $0 }.first?.unit
            let before = try sum(beforeValues, unit: unit), after = try sum(afterValues, unit: unit)
            let free = supply?.globallyFreeLots.filter { $0.foodID == id }.map(\.usable) ?? []
            let unresolved = supply == nil || !confirmedIDs.contains(id) || unknown.contains(id)
                || supply?.unresolvedFoodIDs.contains(id) == true || before == nil || after == nil
            let requirement = try? LedgerPackRequirement.review(shop: shop, lineID: id, bindings: workspace.dinnerPlanning.portionBindings)
            let candidates = workspace.packSelections.filter { selection in
                guard let requirement else { return false }
                return selection.sourceWorkspaceID == workspaceID && selection.shopID == shop.id && selection.lineID == id && selection.reviewedAt <= now
                    && selection.shopRevisionID == shop.revisionID && selection.basisRevision == shop.basisRevision
                    && (try? selection.validateReference(in: shop)) != nil
                    && selection.request.itemName == requirement.name && selection.request.needed == requirement.quantity
                    && selection.request.protectedAmount == requirement.protectedQuantity
            }
            let selected = candidates.last
            let offer = selected.map { $0.request.offerA.id == $0.selectedOfferID ? $0.request.offerA : $0.request.offerB }
            let beforePacks = try !unresolved ? packs(needed: before, free: free, offer: offer) : nil
            let afterPacks = try !unresolved ? packs(needed: after, free: free, offer: offer) : nil
            let beforeCost = try preview.budgetBasis == nil ? nil : beforePacks.flatMap { try offer?.price?.multiplied(by: $0) }
            let afterCost = try preview.budgetBasis == nil ? nil : afterPacks.flatMap { try offer?.price?.multiplied(by: $0) }
            return .init(id: id, name: names[id]!, beforeNeeded: before, afterNeeded: after, free: free,
                holds: supply?.reservations[id] ?? [], unresolved: unresolved, packageLabel: offer?.label,
                packagePrice: preview.budgetBasis == nil ? nil : offer?.price,
                beforePacks: beforePacks, afterPacks: afterPacks, beforeCost: beforeCost, afterCost: afterCost,
                priceSource: selected?.source, priceDate: selected?.reviewedAt)
        }
        let relevant = Set(order)
        let retained = (canonical?.snapshot.lots ?? []).filter { relevant.contains($0.foodID) }.map { lot in
            let purchased: Bool
            if case .receipt = lot.source { purchased = true } else { purchased = false }
            return DinnerSwapReview.Retained(id: lot.id, name: lot.name, count: lot.count, location: lot.location,
                                             confirmedAt: lot.confirmedAt, purchased: purchased)
        }
        return .init(preview: preview, original: original, replacement: replacement.template, pantryBasis: supply?.basis,
                     ingredients: ingredients, foods: rows, retained: retained)
    }

    private static func sum(_ quantities: [Quantity?], unit: UnitOfMeasure?) throws -> Quantity? {
        guard let unit else { return nil }
        var total = Rational.zero
        for quantity in quantities {
            guard let value = try quantity?.converted(to: unit) else { return nil }
            total = try total.adding(value)
        }
        return .init(amount: total, unit: unit, originalLiteral: total.description)
    }

    private static func packs(needed: Quantity?, free: [Quantity], offer: PackOffer?) throws -> Int64? {
        guard let needed else { return nil }
        var amount = Rational.zero
        for quantity in free {
            guard let value = try quantity.converted(to: needed.unit, using: offer?.confirmedConversion) else { return nil }
            amount = try amount.adding(value)
        }
        // Rational rejects negatives before max could clamp them. A fully
        // covered need is a known zero, including when free stock exceeds it.
        let remaining = try needed.amount.subtractingClampedToZero(amount)
        if remaining == .zero { return 0 }
        guard let offer, let yield = try offer.usableQuantity?.converted(to: needed.unit, using: offer.confirmedConversion), yield > .zero else { return nil }
        return try remaining.divided(by: yield).roundedUp()
    }
}
