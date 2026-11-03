import Foundation
import CryptoKit
import CoreDomain

struct LibraryPairingCandidate: Identifiable {
    let id: UUID
    let title: String
    var hands = ""
    var lead = ""
    var advanceStepsReviewed = false
}

struct DinnerLibraryPairings {
    let target: UUID
    let shopID: UUID
    let shopRevision: UUID
    let planningRevision: UUID
    let commitments: [DinnerScenarioMealDraftSnapshot]
    let pageOffset: Int
    let excludedByLimit: Int
    var candidates: [LibraryPairingCandidate]

    static func chosen(in shop: ShoppingLedger, state: DinnerPlanningState) -> Set<UUID> {
        let chosenTemplates = Set(shop.mealOccurrences.filter { $0.removedAt == nil }.compactMap(\.templateID))
        return Set(state.acceptedDinners.filter { chosenTemplates.contains($0.template.id) }.map(\.id))
    }

    /// The baseline uses the current occurrence and exact accepted recipe version. A week edit
    /// with different ingredient quantities needs a separately reviewed scenario.
    static func scheduledMeals(shop: ShoppingLedger, state: DinnerPlanningState) throws -> [DinnerScenarioMealDraft] {
        var meals: [DinnerScenarioMealDraft] = []
        for meal in shop.mealOccurrences where meal.removedAt == nil {
            guard let accepted = state.acceptedDinners.first(where: { $0.template.id == meal.templateID && $0.template.revision == meal.templateRevision }),
                  accepted.template.ingredients.count == meal.ingredientContributionIDs.count else { throw DinnerPlanningError.reviewRequired("currentRecipe") }
            let ratio = try meal.servings.divided(by: accepted.template.servings)
            for (ingredient, contributionID) in zip(accepted.template.ingredients,meal.ingredientContributionIDs) {
                guard let row = shop.contributions.first(where: { $0.id == contributionID && $0.removedAt == nil }),
                      row.productName == ingredient.name, let actual = row.quantity, let original = ingredient.quantity,
                      try actual.converted(to: original.unit) == original.amount.multiplied(by: ratio),
                      Set(row.exclusions) == Set(meal.exclusions + ingredient.exclusions) else { throw DinnerPlanningError.reviewRequired("currentRecipe") }
                for binding in state.portionBindings where binding.occurrenceID == meal.id && binding.contributionID == contributionID {
                    guard let group = meal.servingGroups.first(where: { $0.id == binding.groupID }),
                          try binding.quantity.converted(to: actual.unit) == actual.amount.multiplied(by: group.servings.divided(by: meal.servings))
                    else { throw DinnerPlanningError.reviewRequired("portionBindings") }
                }
            }
            func row(_ id: UUID, _ name: String, _ portions: Rational, protected: Bool) -> DinnerScenarioMealDraft {
                var row = DinnerScenarioMealDraft()
                row.id = id; row.name = name; row.portions = portions.description; row.protected = protected
                row.currentDinnerID = accepted.id; row.candidateDinnerID = accepted.id
                row.isReviewedServingGroup = !meal.servingGroups.isEmpty; row.savedExclusions = meal.exclusions
                if let day = meal.scheduledDay?.date { row.scheduled = true; row.date = day }
                return row
            }
            var remainder = meal.servings
            for group in meal.servingGroups {
                remainder = try remainder.subtracting(group.servings)
                // Template group IDs may recur in different chosen occurrences.
                let bytes = Array(SHA256.hash(data: Data("\(meal.id)/\(group.id)".utf8)).prefix(16))
                let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
                meals.append(row(id,"\(meal.title) · \(group.name)",group.servings,protected: group.isProtected))
            }
            guard remainder >= .zero else { throw DinnerPlanningError.reviewRequired("portions") }
            if remainder > .zero { meals.append(row(meal.id,meal.title,remainder,protected: false)) }
        }
        return meals
    }

    static func prepare(_ draft: inout DinnerScenarioDraft, target: UUID, shop: ShoppingLedger,
                        state: DinnerPlanningState, offset: Int = 0) throws -> Self {
        guard draft.shopID == shop.id, draft.baseRevision == shop.revisionID, draft.planningRevision == state.revisionID,
              draft.meals.contains(where: { $0.id == target && !$0.protected }) else { throw DinnerPlanningError.stalePreview }
        let commitments = try draft.meals.map { try DinnerScenarioMealDraftSnapshot($0, zone: draft.zone) }
        let scheduled = try scheduledMeals(shop: shop, state: state)
        for source in scheduled {
            let expected = try DinnerScenarioMealDraftSnapshot(source, zone: draft.zone)
            guard commitments.contains(where: { $0.id == expected.id && $0.portions == expected.portions && $0.day == expected.day &&
                $0.protected == expected.protected && $0.currentDinnerID == expected.currentDinnerID && $0.savedExclusions == expected.savedExclusions })
            else { throw DinnerPlanningError.reviewRequired("currentSchedule") }
        }
        let excluded = chosen(in: shop, state: state).union(commitments.compactMap(\.currentDinnerID))
        let targetPortions = commitments.first { $0.id == target }?.portions
        let available = state.acceptedDinners.filter { !excluded.contains($0.id) &&
            (!$0.template.servingGroups.contains(where: \.isProtected) || $0.template.servings == targetPortions) }
        guard offset >= 0, offset == 0 || offset < available.count else { throw DinnerPlanningError.stalePreview }
        let batch = Array(available.dropFirst(offset).prefix(32))
        let library = Self(target: target, shopID: shop.id, shopRevision: shop.revisionID, planningRevision: state.revisionID,
                           commitments: commitments, pageOffset: offset, excludedByLimit: available.count - offset - batch.count,
                           candidates: batch.map { .init(id: $0.id, title: $0.template.title) })
        var matches = [DinnerRecipeMatchDraft]()
        var seen = Set<[UUID]>()
        for dinner in batch {
            let version = try library.draftFor(dinner.id, from: draft, state: state)
            for match in version.matches where seen.insert([match.commitmentID,match.acceptedDinnerID,match.ingredientID]).inserted {
                guard matches.count < 2_000 else { throw DinnerPlanningError.reviewRequired("comparisonSize") }
                matches.append(match)
            }
        }
        draft.matches = matches
        draft.recipeYieldsReviewed = false
        return library
    }

    private func draftFor(_ id: UUID, from source: DinnerScenarioDraft, state: DinnerPlanningState) throws -> DinnerScenarioDraft {
        var version = source
        for index in version.meals.indices {
            version.meals[index].candidateDinnerID = version.meals[index].id == target ? id : version.meals[index].currentDinnerID
        }
        try version.prepareMatches(accepted: state.acceptedDinners)
        return version
    }

    func build(_ draft: DinnerScenarioDraft, shop: ShoppingLedger, state: DinnerPlanningState) throws -> (DinnerScenario,[DinnerScenario],CheckoutCap?,[String]) {
        guard shop.id == shopID, shop.revisionID == shopRevision, state.revisionID == planningRevision,
              try draft.meals.map({ try DinnerScenarioMealDraftSnapshot($0, zone: draft.zone) }) == commitments else { throw DinnerPlanningError.stalePreview }
        guard draft.recipeYieldsReviewed else { throw DinnerPlanningError.reviewRequired("recipeMatches") }
        var current: DinnerScenario?, alternatives: [DinnerScenario] = [], cap: CheckoutCap?
        var conflicts: [String] = []
        for candidate in candidates {
            var version = try draftFor(candidate.id, from: draft, state: state)
            // Unmatched candidate ingredients remain distinct unknown foods with no offer or usable stock.
            for index in version.matches.indices where version.matches[index].foodID == nil {
                let missing = DinnerFoodEvidenceDraft(name: version.matches[index].ingredientName)
                version.foods.append(missing); version.matches[index].foodID = missing.id
            }
            version.recipeYieldsReviewed = true
            version.candidateHands = candidate.hands; version.candidateLead = candidate.lead
            let selected = Set(version.meals.compactMap(\.candidateDinnerID))
            let savedLead = state.acceptedDinners.filter { selected.contains($0.id) }.compactMap(\.template.leadTimeMinutes).max()
            if let savedLead, let remaining = try DinnerEntry.minutes(candidate.lead), remaining < savedLead, !candidate.advanceStepsReviewed {
                version.candidateLead = ""
            }
            do {
                let reviewed = try version.build(shop: shop, state: state, candidateScenarioID: candidate.id)
                _ = try DinnerScenarioEngine.evaluate(reviewed.candidate, acceptedDinners: state.acceptedDinners, cap: reviewed.cap)
                current = reviewed.current; cap = reviewed.cap; alternatives.append(reviewed.candidate)
            } catch LedgerError.excludedIngredient { conflicts.append(candidate.title) }
        }
        guard let current else { throw DinnerPlanningError.reviewRequired("recipes") }
        return (current,alternatives,cap,conflicts)
    }
}

extension DinnerLibraryPairings {
    /// Keep the real lot's identity and label. Only the currently unallocated balance can be reviewed.
    static func unreservedLots(_ journey: PickupJourney, at now: Date) throws -> [ConfirmedStockLot] {
        let stock = PickupFallbackOptions.lots(journey, at: now)
        let reserved = try ConfirmedStockAllocator.allocate(lots: stock, needs: PickupFallbackOptions.needs(journey))
        return stock.compactMap { lot in
            guard let balance = reserved.remainingLots.first(where: { $0.lotID == lot.id }), balance.issues.isEmpty,
                  reserved.demands.filter({ $0.foodID == lot.foodID }).allSatisfy({ $0.issues.isEmpty }),
                  balance.remainingUnallocated > .zero else { return nil }
            return .init(id: lot.id, foodID: lot.foodID, name: lot.name,
                         usable: .init(amount: balance.remainingUnallocated, unit: balance.unit, originalLiteral: lot.usable.originalLiteral),
                         confirmedAt: lot.confirmedAt, source: lot.source)
        }
    }
}

extension DinnerLibraryPairings {
    /// A scenario row is safe to commit only if it names one complete current occurrence.
    /// Group slices and priced stock/pack assumptions stay in the comparison.
    func replacement(for scenario: DinnerScenario, shop: ShoppingLedger, state: DinnerPlanningState) throws -> [DinnerLedgerChange] {
        guard shop.id == shopID, shop.revisionID == shopRevision, state.revisionID == planningRevision else { throw DinnerPlanningError.stalePreview }
        guard candidates.contains(where: { $0.id == scenario.id }),
              let candidate = state.acceptedDinners.first(where: { $0.id == scenario.id }),
              let original = shop.mealOccurrences.first(where: { $0.id == target && $0.removedAt == nil }),
              let slot = scenario.commitments.commitments.first(where: { $0.id == target }),
              !slot.protected, slot.portions == original.servings, slot.day == original.scheduledDay,
              slot.portions == candidate.template.servings, original.servingGroups.isEmpty, candidate.template.servingGroups.isEmpty,
              Set(original.exclusions).isSubset(of: Set(candidate.template.exclusions)),
              !chosenTemplateIDs(shop).contains(candidate.template.id),
              !state.portionBindings.contains(where: { $0.occurrenceID == original.id }),
              !shop.allocations.contains(where: { original.ingredientContributionIDs.contains($0.demandContributionID) || original.ingredientContributionIDs.contains($0.supplyContributionID) })
        else { throw DinnerPlanningError.reviewRequired("replaceWholeOccurrence") }
        let replacements = scenario.demands.filter { $0.commitmentID == slot.id }
        guard replacements.count == candidate.template.ingredients.count,
              candidate.template.ingredients.allSatisfy({ ingredient in
                  replacements.contains { $0.acceptedDinnerID == candidate.id && $0.ingredientID == ingredient.id && $0.quantity == ingredient.quantity }
              }) else { throw DinnerPlanningError.reviewRequired("replaceExactIngredients") }
        return [.remove(occurrenceID: original.id), .choose(.init(acceptedDinnerID: candidate.id, template: candidate.template, day: slot.day))]
    }

    private func chosenTemplateIDs(_ shop: ShoppingLedger) -> Set<UUID> {
        Set(shop.mealOccurrences.filter { $0.removedAt == nil }.compactMap(\.templateID))
    }
}
