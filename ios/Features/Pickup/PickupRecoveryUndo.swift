import CoreDomain
import CryptoKit
import Foundation

enum PickupRecoveryUndoError: Error {
    case actor, laterMeal, stock, cooked, repair, constraints
}

extension PickupRecoveryAuthority {
    var recoveryAuthorDigest: String? {
        guard let scope else { return nil }
        let fields = [Optional(scope.workspaceID.uuidString), scope.localActorID.uuidString,
                      scope.accountSubject, scope.householdID, scope.memberID]
        guard let data = try? JSONEncoder().encode(fields) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension PickupMealRecoveryHistory {
    static func undoOperation(_ forward: UUID) -> UUID { PickupCheckoutMealSource.identity("undo-placed-swap", [forward]) }

    func inverseDefinition(_ forward: UUID) throws -> PickupRecoveryMealDefinition {
        guard let index = domain.events.firstIndex(where: { $0.id == forward }) else { throw PickupRecoveryUndoError.laterMeal }
        let original = domain.events[index].request.target
        let earlier = domain.events[..<index].last { $0.request.target.id == original.id }
        let stored: PickupRecoveryMealDefinition?
        if let earlier { stored = definitions.first { $0.operationID == earlier.id }?.definition }
        else { stored = try source.definitions().first { $0.meal.id == original.id } }
        guard let stored, stored.meal.ingredients == original.ingredients else { throw PickupRecoveryUndoError.laterMeal }
        let operation = Self.undoOperation(forward)
        // Old demand IDs are historical ledger evidence. The compensating event gets its own stable claims.
        let ingredients = original.ingredients.map { item -> RecoveryIngredient in
            guard item.need.priority != .protected else { return item }
            let need = item.need
            let id = PickupCheckoutMealSource.identity("undo-restored-need", [operation, need.id])
            return .init(ingredientID: item.ingredientID, groupID: item.groupID, foodName: item.foodName,
                need: .init(id: id, foodID: need.foodID, name: need.name, amount: need.amount, priority: need.priority))
        }
        let ids = Dictionary(uniqueKeysWithValues: zip(original.needs.map(\.id), ingredients.map(\.need.id)))
        let meal = RecoveryMeal(id: original.id, revisionID: PickupCheckoutMealSource.identity("undo-restored-meal", [operation]),
            templateID: original.templateID, templateVersion: original.templateVersion, title: original.title,
            servings: original.servings, ingredients: ingredients, scheduledDay: original.scheduledDay, due: original.due,
            timeZoneID: original.timeZoneID, exclusions: original.exclusions, remainingElapsedMinutes: original.remainingElapsedMinutes,
            requiredLeadMinutes: original.requiredLeadMinutes, advanceStepsCompleted: original.advanceStepsCompleted)
        return .init(meal: meal, groups: stored.groups, notes: stored.notes, sourceURL: stored.sourceURL,
            ingredientRules: try stored.ingredientRules.map { rule in
                guard let id = ids[rule.needID] else { throw PickupRecoveryUndoError.laterMeal }
                return .init(needID: id, notes: rule.notes, exclusions: rule.exclusions)
            }, acceptedTemplate: stored.acceptedTemplate)
    }

    func checkUndo(_ forward: UUID, restoring definition: PickupRecoveryMealDefinition,
                   current: PickupJourney, authority: PickupRecoveryAuthority, profile: MealPreferenceProfile?,
                   proof: CanonicalRecoveryAllocation?) throws {
        guard let event = domain.events.first(where: { $0.id == forward }),
              let record = definitions.first(where: { $0.operationID == forward }), record.undoOf == nil,
              let scope = authority.scope, record.localActorID == scope.localActorID,
              record.authorScopeDigest.map({ $0 == authority.recoveryAuthorDigest }) ??
                  (scope.accountSubject == nil && scope.householdID == nil && scope.memberID == nil)
        else { throw PickupRecoveryUndoError.actor }
        let currentProjection = try MealRecoveryEngine.project(domain)
        guard currentProjection.meals.first(where: { $0.id == definition.meal.id }) == event.request.replacement,
              !definitions.contains(where: { $0.undoOf == forward }), definition == (try inverseDefinition(forward))
        else { throw PickupRecoveryUndoError.laterMeal }
        guard !(current.cookedMeals ?? []).contains(where: { $0.draft.meal.id == definition.meal.id && $0.isActive })
        else { throw PickupRecoveryUndoError.cooked }

        let swappedNeeds = event.request.target.needs + event.request.replacement.needs
        let replacedIDs = Set(swappedNeeds.filter { $0.priority != .protected }.map(\.id))
        // A compensating instruction uses fresh demand IDs. A repair on either dinner
        // would otherwise disappear from the cook's current instructions.
        guard !current.repairs.contains(where: { replacedIDs.contains($0.needID) }) else {
            throw PickupRecoveryUndoError.repair
        }
        let foods = Set(swappedNeeds.map(\.foodID))
        let (previous, afterClaims) = try MealRecoveryEngine.recordedResult(forward, in: domain)
        guard previous.demands.filter({ foods.contains($0.foodID) }) == currentProjection.demands.filter({ foods.contains($0.foodID) })
        else { throw PickupRecoveryUndoError.stock }

        let restoredFoods = Set(definition.meal.needs.map(\.foodID))
        let labels: [String]
        switch (event.canonicalAllocation, proof) {
        case let (.some(old), .some(live)):
            let lots = old.lots.filter { foods.contains($0.foodID) }
            let lotIDs = Set(lots.map(\.id))
            guard old.basis.originID == live.basis.originID, let afterClaims,
                  lots == live.lots.filter({ foods.contains($0.foodID) }),
                  afterClaims.filter({ foods.contains($0.foodID) }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) ==
                    live.claims.filter({ foods.contains($0.foodID) }),
                  old.eligibility.filter({ lotIDs.contains($0.lotID) }) == live.eligibility.filter({ lotIDs.contains($0.lotID) })
            else { throw PickupRecoveryUndoError.stock }
            labels = lots.filter { restoredFoods.contains($0.foodID) }.map(\.name)
        case (nil, nil):
            let lots = event.stockEvidence.filter { foods.contains($0.lot.foodID) }
            let lotIDs = Set(lots.map(\.lot.id)), needIDs = Set(previous.demands.filter { foods.contains($0.foodID) }.map(\.id))
            guard lots == current.recoveryStockEvidence.filter({ foods.contains($0.lot.foodID) }),
                  event.reservations.filter({ lotIDs.contains($0.lotID) || needIDs.contains($0.needID) }) ==
                    current.carryoverStockReservations.filter({ lotIDs.contains($0.lotID) || needIDs.contains($0.needID) })
            else { throw PickupRecoveryUndoError.stock }
            labels = lots.filter { restoredFoods.contains($0.lot.foodID) }.map(\.lot.name)
        default: throw PickupRecoveryUndoError.stock
        }

        let meal = definition.meal
        var recipe = MealTemplate(id: meal.templateID ?? meal.id, title: meal.title, servings: meal.servings,
            ingredients: meal.ingredients.map { .init(id: $0.need.id, name: $0.foodName, quantity: $0.need.amount) },
            exclusions: meal.exclusions, leadTimeMinutes: meal.requiredLeadMinutes)
        recipe.eligibilityEvidence = definition.acceptedTemplate?.eligibilityEvidence
        guard MealEligibilityPolicy.evaluate(profile: profile, template: recipe).eligible,
              MealEligibilityPolicy.evaluateFood(profile: profile, labels: labels, evidence: nil).eligible
        else { throw PickupRecoveryUndoError.constraints }
    }
}
