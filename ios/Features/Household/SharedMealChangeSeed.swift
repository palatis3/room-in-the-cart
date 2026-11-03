import Foundation
import CoreDomain
import HouseholdClient

/// Local evidence is mapped only after the adult explicitly chooses a shared occurrence.
struct SharedMealChangeSeed: Equatable {
    let localOccurrenceID: UUID
    let title: String
    let portions: Int
    let planning: SharedMealPlanning
    init(localOccurrenceID: UUID, title: String, portions: Int, planning: SharedMealPlanning) {
        self.localOccurrenceID = localOccurrenceID; self.title = title; self.portions = portions
        var evidence = planning; evidence.sourceOccurrenceId = localOccurrenceID; self.planning = evidence
    }
    /// Pass the reviewed resulting occurrence and its resulting active contributions, not current names guessed from a template.
    init(reviewed occurrence: MealOccurrence, contributions: [LedgerContribution], bindings: [DinnerPortionBinding] = []) throws {
        guard occurrence.carryover == nil, occurrence.removedAt == nil, occurrence.servings.denominator == 1,
              (1...1000).contains(occurrence.servings.numerator) else { throw ClientError.configuration }
        let groups = occurrence.servingGroups.map { SharedMealPlanning.Group(id: $0.id, name: $0.name,
            servings: .init(numerator: Int($0.servings.numerator), denominator: Int($0.servings.denominator)), protected: $0.isProtected) }
        let selected = contributions.filter { occurrence.ingredientContributionIDs.contains($0.id) && $0.removedAt == nil }
        guard selected.count == occurrence.ingredientContributionIDs.count,
              selected.allSatisfy({ $0.source == .meal(occurrenceID: occurrence.id) }) else { throw ClientError.configuration }
        let exactBindings = bindings.filter { $0.occurrenceID == occurrence.id }
        guard groups.filter(\.protected).allSatisfy({ group in selected.allSatisfy { ingredient in exactBindings.contains { $0.groupID == group.id && $0.contributionID == ingredient.id } } }) else { throw ClientError.configuration }
        let ingredients = selected.map { value in
            SharedMealPlanning.Ingredient(id: value.id, name: value.productName, quantity: value.quantity.map {
                .init(amount: .init(numerator: Int($0.amount.numerator), denominator: Int($0.amount.denominator)), unit: $0.unit.rawValue, originalLiteral: $0.originalLiteral)
            }, groupIds: exactBindings.filter { $0.contributionID == value.id }.map(\.groupID), exclusions: Array(Set(occurrence.exclusions + value.exclusions)).sorted())
        }
        let planning = SharedMealPlanning(groups: groups, ingredients: ingredients, sourceOccurrenceId: occurrence.id, bindings: exactBindings.map {
            .init(id: $0.id, groupId: $0.groupID, ingredientId: $0.contributionID, quantity: .init(amount: .init(numerator: Int($0.quantity.amount.numerator), denominator: Int($0.quantity.amount.denominator)), unit: $0.quantity.unit.rawValue, originalLiteral: $0.quantity.originalLiteral))
        })
        try planning.validate()
        self.init(localOccurrenceID: occurrence.id, title: occurrence.title, portions: Int(occurrence.servings.numerator), planning: planning)
    }
    init(preview: DinnerPreview, occurrenceID: UUID, state: DinnerPlanningState) throws {
        guard let occurrence = preview.projectedMeals.first(where: { $0.id == occurrenceID }),
              preview.changedOccurrenceIDs.contains(occurrenceID) || !Set(preview.changedContributionIDs).isDisjoint(with: occurrence.ingredientContributionIDs)
        else { throw ClientError.configuration }
        try self.init(reviewed: occurrence, contributions: preview.projectedContributions,
            bindings: preview.reviewedPortionBindings(from: state))
    }

}
