import Foundation
import CryptoKit
import CoreDomain

enum PickupMealRecoveryError: Error { case unavailable, invalid, stale, forbidden, sourceChanged, metadataChanged }

struct PickupRecoveryIngredientRule: Codable, Equatable {
    let needID: UUID
    let notes: String
    let exclusions: [String]
}

/// The complete displayed/sent replacement, not just a title attached to old needs.
struct PickupRecoveryMealDefinition: Codable, Equatable {
    let meal: RecoveryMeal
    let groups: [ServingGroup]
    let notes: String
    let sourceURL: String?
    let ingredientRules: [PickupRecoveryIngredientRule]
    let acceptedTemplate: MealTemplate?

    func withMeal(_ current: RecoveryMeal) -> Self {
        .init(meal: current, groups: groups, notes: notes, sourceURL: sourceURL,
              ingredientRules: ingredientRules, acceptedTemplate: acceptedTemplate)
    }
    func validate(replacing previous: Self? = nil) throws {
        guard Set(ingredientRules.map(\.needID)).count == ingredientRules.count,
              Set(ingredientRules.map(\.needID)) == Set(meal.needs.map(\.id)),
              Set(groups.map(\.id)).count == groups.count,
              meal.ingredients.allSatisfy({ item in item.groupID.map { group in groups.contains { $0.id == group } } ?? true }) else {
            throw PickupMealRecoveryError.invalid
        }
        let recipe = MealTemplate(id: meal.id, title: meal.title, servings: meal.servings,
            ingredients: try meal.ingredients.map { item in
                guard let rule = ingredientRules.first(where: { $0.needID == item.need.id }) else { throw PickupMealRecoveryError.invalid }
                return MealIngredient(id: item.need.id, name: item.foodName, quantity: item.need.amount,
                                      notes: rule.notes, exclusions: rule.exclusions)
            }, notes: notes, sourceURL: sourceURL, exclusions: meal.exclusions, servingGroups: groups)
        try recipe.validate()
        if let previous {
            guard groups == previous.groups else { throw PickupMealRecoveryError.metadataChanged }
            for item in meal.ingredients {
                guard let rule = ingredientRules.first(where: { $0.needID == item.need.id }) else { throw PickupMealRecoveryError.invalid }
                if item.need.priority == .protected {
                    guard previous.ingredientRules.first(where: { $0.needID == item.need.id }) == rule else {
                        throw PickupMealRecoveryError.metadataChanged
                    }
                } else {
                    let oldIDs = Set(previous.meal.ingredients.filter { $0.groupID == item.groupID && $0.need.priority != .protected }.map { $0.need.id })
                    let inherited = Set(previous.ingredientRules.filter { oldIDs.contains($0.needID) }.flatMap(\.exclusions))
                    guard inherited.isSubset(of: Set(rule.exclusions)) else { throw PickupMealRecoveryError.metadataChanged }
                }
            }
        }
        if let acceptedTemplate {
            try acceptedTemplate.validate()
            guard meal.templateID == acceptedTemplate.id, meal.templateVersion == acceptedTemplate.revision,
                  Set(acceptedTemplate.exclusions).isSubset(of: Set(meal.exclusions)) else { throw PickupMealRecoveryError.invalid }
            let protectedServings = try groups.filter(\.isProtected).reduce(Rational.zero) { try $0.adding($1.servings) }
            let dinnerServings = try meal.servings.subtracting(protectedServings)
            guard dinnerServings > .zero else { throw PickupMealRecoveryError.invalid }
            let ingredients = meal.ingredients.filter { $0.need.priority != .protected }
            guard Set(ingredients.map(\.ingredientID)) == Set(acceptedTemplate.ingredients.map(\.id)) else { throw PickupMealRecoveryError.invalid }
            let scale = try dinnerServings.divided(by: acceptedTemplate.servings)
            for ingredient in acceptedTemplate.ingredients {
                guard let quantity = ingredient.quantity else { throw PickupMealRecoveryError.invalid }
                let matches = ingredients.filter { $0.ingredientID == ingredient.id }
                let total = try matches.reduce(Rational.zero) { total, item in
                    guard let amount = try item.need.amount.converted(to: quantity.unit),
                          let rule = ingredientRules.first(where: { $0.needID == item.need.id }),
                          Set(ingredient.exclusions).isSubset(of: Set(rule.exclusions)) else { throw PickupMealRecoveryError.invalid }
                    return try total.adding(amount)
                }
                guard total == (try quantity.amount.multiplied(by: scale)) else { throw PickupMealRecoveryError.invalid }
            }
        } else if previous != nil, meal.templateID != nil || meal.templateVersion != nil {
            throw PickupMealRecoveryError.invalid
        }
    }
}

/// Immutable exact checkout provenance. It is private backup data, never a shared
/// authorization token or an automatically publishable cook/household document.
struct PickupCheckoutMealSource: Codable, Equatable {
    let ledgerWorkspaceID: UUID
    let shop: ShoppingLedger
    let needs: [AllocationNeed]
    let details: [PickupNeedDetail]
    let bindings: [DinnerPortionBinding]

    func validate() throws {
        try shop.validate()
        guard Set(needs.map(\.id)).count == needs.count, Set(details.map(\.id)).count == details.count else {
            throw PickupMealRecoveryError.invalid
        }
        var expectedNeeds: [AllocationNeed] = [], expectedDetails: [PickupNeedDetail] = []
        for line in shop.lines where !line.isTrashed && !line.isHandled {
            guard let quantity = try shop.quantity(forLineID: line.id) else { throw PickupMealRecoveryError.invalid }
            let named = try LedgerCheckoutAdapter.namedReservations(shop: shop, lineID: line.id, unit: quantity.unit, bindings: bindings)
            expectedNeeds += named.needs; expectedDetails += named.details
        }
        let expectedMealIDs = Set(expectedDetails.filter { $0.sourceOccurrenceID != nil }.map(\.id))
        let captured = details.filter { $0.sourceOccurrenceID != nil }
        guard Set(captured.map(\.id)) == expectedMealIDs else { throw PickupMealRecoveryError.invalid }
        for detail in captured {
            guard expectedDetails.first(where: { $0.id == detail.id }) == detail,
                  expectedNeeds.first(where: { $0.id == detail.id }) == needs.first(where: { $0.id == detail.id }) else {
                throw PickupMealRecoveryError.invalid
            }
        }
        for definition in try definitions() { try definition.validate() }
    }
    func definitions() throws -> [PickupRecoveryMealDefinition] {
        try shop.mealOccurrences.filter { $0.removedAt == nil && $0.carryover == nil }.compactMap { occurrence in
            let mealDetails = details.filter { $0.sourceOccurrenceID == occurrence.id }
            if mealDetails.isEmpty { return nil }
            let ingredients = try mealDetails.map { detail -> RecoveryIngredient in
                guard detail.sourceLedgerRevisionID == shop.revisionID,
                      let contributionID = detail.sourceContributionID,
                      occurrence.ingredientContributionIDs.contains(contributionID),
                      let contribution = shop.contributions.first(where: { $0.id == contributionID && $0.removedAt == nil }),
                      contribution.source == .meal(occurrenceID: occurrence.id),
                      let need = needs.first(where: { $0.id == detail.id }) else { throw PickupMealRecoveryError.invalid }
                return RecoveryIngredient(ingredientID: contribution.id, groupID: detail.sourceGroupID,
                    foodName: contribution.productName,
                    need: StockNeed(id: need.id, foodID: need.orderLineID, name: need.name, amount: need.amount, priority: need.priority))
            }
            let rules = try mealDetails.map { detail -> PickupRecoveryIngredientRule in
                guard let contribution = shop.contributions.first(where: { $0.id == detail.sourceContributionID }) else {
                    throw PickupMealRecoveryError.invalid
                }
                return .init(needID: detail.id, notes: contribution.notes, exclusions: detail.exclusions)
            }
            let meal = RecoveryMeal(id: occurrence.id,
                revisionID: Self.identity("source-meal", [shop.revisionID, occurrence.id]),
                templateID: occurrence.templateID, templateVersion: occurrence.templateRevision,
                title: occurrence.title, servings: occurrence.servings, ingredients: ingredients,
                scheduledDay: occurrence.scheduledDay, due: nil, timeZoneID: shop.basis.timeZoneIdentifier,
                exclusions: occurrence.exclusions, remainingElapsedMinutes: nil,
                requiredLeadMinutes: occurrence.leadTimeMinutes, advanceStepsCompleted: false)
            return PickupRecoveryMealDefinition(meal: meal, groups: occurrence.servingGroups, notes: occurrence.notes,
                sourceURL: occurrence.sourceURL, ingredientRules: rules, acceptedTemplate: nil)
        }
    }
    static func identity(_ namespace: String, _ ids: [UUID]) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((namespace + "/" + ids.map(\.uuidString).joined(separator: "/")).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

struct PickupRecoveryDefinitionRecord: Codable, Equatable {
    let operationID: UUID
    let definition: PickupRecoveryMealDefinition
    let localActorID: UUID
}
struct PickupRecoveryCalendarBasis: Codable, Equatable {
    let occurrenceID: UUID
    let day: MealDay?
}
struct PickupMealRecoveryHistory: Codable, Equatable {
    let source: PickupCheckoutMealSource
    var domain: MealRecoveryState
    var definitions: [PickupRecoveryDefinitionRecord]
    var ledgerCalendarBasis: [PickupRecoveryCalendarBasis]

    func definition(for occurrenceID: UUID) throws -> PickupRecoveryMealDefinition? {
        guard let current = try MealRecoveryEngine.project(domain).meals.first(where: { $0.id == occurrenceID }) else { return nil }
        let recorded = domain.events.last { $0.request.target.id == occurrenceID }.flatMap { event in definitions.first { $0.operationID == event.id }?.definition }
        return try (recorded ?? source.definitions().first { $0.meal.id == occurrenceID })?.withMeal(current)
    }
    func validate() throws {
        try source.validate()
        let originals = try source.definitions()
        guard domain.shopID == source.shop.id, domain.originalRevisionID == source.shop.revisionID,
              domain.originalMeals == originals.map(\.meal),
              Set(ledgerCalendarBasis.map(\.occurrenceID)) == Set(domain.originalMeals.map(\.id)),
              Set(ledgerCalendarBasis.map(\.occurrenceID)).count == ledgerCalendarBasis.count,
              Set(definitions.map(\.operationID)).count == definitions.count,
              Set(definitions.map(\.operationID)) == Set(domain.events.map(\.id)) else { throw PickupMealRecoveryError.invalid }
        _ = try MealRecoveryEngine.project(domain)
        var previous = Dictionary(uniqueKeysWithValues: originals.map { ($0.meal.id, $0) })
        for event in domain.events {
            guard let record = definitions.first(where: { $0.operationID == event.id }),
                  record.definition.meal == event.request.replacement,
                  let old = previous[event.request.target.id], old.meal.ingredients == event.request.target.ingredients else { throw PickupMealRecoveryError.invalid }
            try record.definition.validate(replacing: old)
            previous[event.request.target.id] = record.definition
        }
    }
}
