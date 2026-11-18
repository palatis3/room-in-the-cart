import Foundation

public extension DinnerPreview {
    func projectedQuantity(forLineID id: UUID) throws -> Quantity? {
        try projectedLedger.quantity(forLineID: id)
    }
}

/// The inverse keeps only the facts for the two affected meal slots. Other
/// meals, purchases, inventory and checkout totals do not belong to a swap.
public struct DinnerSwapEffect: Codable, Equatable, Sendable {
    public var original: MealOccurrence { before.meal }
    public var replacementID: UUID { replacement.id }
    public let replacement: MealOccurrence
    let before: Facts
    let after: Facts
    let basisRevision: Int

    struct Facts: Codable, Equatable, Sendable {
        let meal: MealOccurrence
        let ingredients: [LedgerContribution]
        let lines: [ShoppingLine]
        let lineMembers: [UUID]
        let edges: [AllocationEdge]
        let bindings: [DinnerPortionBinding]

        init(meal: MealOccurrence, sourceIDs: Set<UUID>, lineIDs: Set<UUID>, mealIDs: Set<UUID>,
             ledger: ShoppingLedger, state: DinnerPlanningState) {
            self.meal = meal
            ingredients = ledger.contributions.filter { sourceIDs.contains($0.id) }
            lines = ledger.lines.filter { lineIDs.contains($0.id) }
            lineMembers = ledger.contributions.filter { lineIDs.contains($0.lineID) && $0.removedAt == nil }.map(\.id)
            edges = ledger.allocations.filter { sourceIDs.contains($0.supplyContributionID) || sourceIDs.contains($0.demandContributionID) }
            bindings = state.portionBindings.filter { mealIDs.contains($0.occurrenceID) }
        }
    }

    static func record(_ receipt: DinnerApplyReceipt, prior: ShoppingLedger, planning: DinnerPlanningState,
                       current: ShoppingLedger, updated: DinnerPlanningState) throws -> Self {
        let (target, choice) = try shape(receipt.proposal)
        guard let original = prior.mealOccurrences.first(where: { $0.id == target && $0.removedAt == nil }),
              let amended = current.mealOccurrences.first(where: { $0.id == target }),
              let replacement = current.mealOccurrences.first(where: { $0.id == choice.occurrenceID })
        else { throw DinnerPlanningError.stalePreview }
        let ids = Set(original.ingredientContributionIDs + choice.contributionIDs)
        let lines = Set(prior.contributions.filter { ids.contains($0.id) }.map(\.lineID) + choice.lineIDs)
        let meals: Set<UUID> = [target, choice.occurrenceID]
        let before = Facts(meal: original, sourceIDs: ids, lineIDs: lines, mealIDs: meals, ledger: prior, state: planning)
        let after = Facts(meal: amended, sourceIDs: ids, lineIDs: lines, mealIDs: meals, ledger: current, state: updated)
        let effect = Self(replacement: replacement, before: before, after: after, basisRevision: prior.basisRevision)
        try effect.validate(receipt.proposal)
        return effect
    }

    static func shape(_ proposal: DinnerProposal) throws -> (UUID, PlannedDinner) {
        guard let id = proposal.swapOriginalID, proposal.repeatWeek == nil, proposal.quoteSelection == nil,
              proposal.tool == .pairing || proposal.tool == .manual, proposal.changes.count == 2,
              case .choose(let chosen) = proposal.changes[1], chosen.occurrenceID != id else {
            throw DinnerPlanningError.invalid("swap")
        }
        switch proposal.changes[0] {
        case .remove(let old) where old == id: return (id, chosen)
        case .adjust(let change) where change.occurrenceID == id: return (id, chosen)
        default: throw DinnerPlanningError.invalid("swapSource")
        }
    }

    static func validateSlot(_ proposal: DinnerProposal, ledger: ShoppingLedger, state: DinnerPlanningState) throws {
        let (id, chosen) = try shape(proposal)
        guard let original = ledger.mealOccurrences.first(where: { $0.id == id && $0.removedAt == nil && !$0.isHidden }),
              original.carryover == nil, original.scheduledDay == chosen.day else { throw DinnerPlanningError.stalePreview }
        switch proposal.changes[0] {
        case .remove:
            let owned = Set(original.ingredientContributionIDs)
            guard original.servingGroups.isEmpty, original.servings == chosen.template.servings,
                  !ledger.allocations.contains(where: { owned.contains($0.demandContributionID) || owned.contains($0.supplyContributionID) })
            else { throw DinnerPlanningError.reviewRequired("linkedOccurrence") }
        case .adjust(let change):
            let retained = Set(change.groups.map(\.id))
            let removed = original.servingGroups.filter { !retained.contains($0.id) }
            guard removed.count == 1, let group = removed.first, !group.isProtected,
                  chosen.template.servings == group.servings,
                  let expected = try DinnerPlanningEngine.removingServingGroup(group.id, from: id, ledger: ledger, state: state),
                  expected.groups == change.groups, expected.servings == change.servings, expected.quantities == change.quantities
            else { throw DinnerPlanningError.reviewRequired("reviewPortionBindings") }
        default: throw DinnerPlanningError.invalid("swapSource")
        }
    }

    func validate(_ proposal: DinnerProposal) throws {
        let (id, chosen) = try Self.shape(proposal)
        let oldIDs = Set(original.ingredientContributionIDs), newIDs = Set(chosen.contributionIDs)
        let oldLines = Set(before.ingredients.map(\.lineID)), newLines = Set(chosen.lineIDs)
        guard original.id == id, original.removedAt == nil, original.carryover == nil, after.meal.id == id,
              after.meal.ingredientContributionIDs == original.ingredientContributionIDs,
              replacement.id == chosen.occurrenceID, replacement.ingredientContributionIDs == chosen.contributionIDs,
              replacement.removedAt == nil, basisRevision == proposal.basisRevision, oldIDs.isDisjoint(with: newIDs),
              Set(before.ingredients.map(\.id)) == oldIDs, Set(after.ingredients.map(\.id)) == oldIDs.union(newIDs),
              before.ingredients.allSatisfy({ $0.source == .meal(occurrenceID: id) }),
              oldLines.isDisjoint(with: newLines), Set(before.lines.map(\.id)) == oldLines,
              Set(after.lines.map(\.id)) == oldLines.union(newLines),
              before.bindings.allSatisfy({ $0.occurrenceID == id && oldIDs.contains($0.contributionID) }),
              after.bindings.allSatisfy({ $0.occurrenceID == id && oldIDs.contains($0.contributionID) })
        else { throw DinnerPlanningError.invalid("swapFacts") }
        for facts in [before, after] {
            try dinnerUnique(facts.ingredients.map(\.id))
            try dinnerUnique(facts.lines.map(\.id))
            try dinnerUnique(facts.edges.map(\.id))
            try dinnerUnique(facts.bindings.map(\.id))
        }
    }

    func checkCurrent(ledger: ShoppingLedger, state: DinnerPlanningState) throws {
        let ids = Set(after.ingredients.map(\.id)), lineIDs = Set(after.lines.map(\.id))
        guard ledger.basisRevision == basisRevision,
              ledger.mealOccurrences.first(where: { $0.id == replacement.id }) == replacement,
              let current = ledger.mealOccurrences.first(where: { $0.id == original.id }),
              Facts(meal: current, sourceIDs: ids, lineIDs: lineIDs, mealIDs: [original.id, replacement.id],
                    ledger: ledger, state: state) == after else { throw DinnerPlanningError.stalePreview }
    }
}

public enum DinnerSwapEngine {
    public static func preview(occurrenceID: UUID, groupID: UUID? = nil, replacement: PlannedDinner,
                               ledger: ShoppingLedger, state: DinnerPlanningState, access: DinnerAccessContext,
                               phase: BasketPhase, at now: Date) throws -> DinnerPreview {
        guard phase == .draft, case .local = access.scope,
              let old = ledger.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil && !$0.isHidden }),
              old.carryover == nil, replacement.day == old.scheduledDay
        else { throw DinnerPlanningError.reviewRequired("swapSlot") }
        let change: DinnerLedgerChange
        if let groupID {
            guard let group = old.servingGroups.first(where: { $0.id == groupID && !$0.isProtected }),
                  replacement.template.servings == group.servings,
                  let adjustment = try DinnerPlanningEngine.removingServingGroup(groupID, from: occurrenceID, ledger: ledger, state: state)
            else { throw DinnerPlanningError.reviewRequired("reviewPortionBindings") }
            let retained = Set(adjustment.groups.map(\.id))
            let bindings = state.portionBindings.filter { $0.occurrenceID == occurrenceID && retained.contains($0.groupID) }
            change = .adjust(DinnerAdjustment(occurrenceID: occurrenceID, servings: adjustment.servings,
                groups: adjustment.groups, quantities: adjustment.quantities, portionBindings: bindings))
        } else {
            let ingredients = Set(old.ingredientContributionIDs)
            guard old.servingGroups.isEmpty, replacement.template.servings == old.servings,
                  !ledger.allocations.contains(where: { ingredients.contains($0.demandContributionID) || ingredients.contains($0.supplyContributionID) })
            else { throw DinnerPlanningError.reviewRequired("linkedOccurrence") }
            change = .remove(occurrenceID: occurrenceID)
        }
        return try DinnerPlanningEngine.preview(changes: [change, .choose(replacement)], tool: .manual, ledger: ledger,
            state: state, access: access, phase: phase, at: now, swapOriginalID: occurrenceID)
    }

    @discardableResult public static func undo(_ reviewed: DinnerApplyReceipt, ledger: inout ShoppingLedger,
                                                state: inout DinnerPlanningState, access: DinnerAccessContext,
                                                phase: BasketPhase, at now: Date) throws -> UUID {
        try access.validate(shopID: ledger.id, at: now, applying: true)
        guard case .local = access.scope, access.namespace == reviewed.proposal.namespace,
              reviewed.appliedBy == access.actorID, reviewed.proposal.shopID == ledger.id,
              let receipt = state.applyReceipts.first(where: { $0.id == reviewed.id }),
              receipt.proposal == reviewed.proposal, let effect = receipt.swapEffect, effect == reviewed.swapEffect,
              ledger.revisions.contains(where: { $0.id == receipt.revisionID })
        else { throw DinnerPlanningError.forbidden }
        if let revision = receipt.swapUndoRevisionID {
            guard ledger.revisions.contains(where: { $0.id == revision }) else { throw DinnerPlanningError.invalid("swapUndoRevision") }
            return revision
        }
        guard phase == .draft else { throw DinnerPlanningError.lockedBasket }
        guard receipt.proposal.preferenceRevision == state.preferences(for: access)?.revision else { throw DinnerPlanningError.stalePreview }
        try effect.validate(receipt.proposal)
        try effect.checkCurrent(ledger: ledger, state: state)
        var updated = ledger, planning = state
        try updated.restoreSwap(effect, operationID: receipt.id, at: now)
        try planning.finishSwapUndo(receipt.id, effect: effect, revision: updated.revisionID)
        try planning.validate()
        ledger = updated
        state = planning
        return updated.revisionID
    }
}
