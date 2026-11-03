import Foundation
import CoreDomain

struct DinnerScenarioMealDraft: Identifiable {
    var id = UUID()
    var name = ""
    var portions = ""
    var currentDinnerID: UUID?
    var candidateDinnerID: UUID?
    var protected = false
    var isReviewedServingGroup = false
    var savedExclusions: [String] = []
    var scheduled = false
    var date = Date()
}
struct DinnerFoodEvidenceDraft: Identifiable {
    let id = UUID()
    let stockID = UUID()
    let reservationID = UUID()
    let packID = UUID()
    var name = ""
    var stockAmount = ""
    var stockUnit = UnitOfMeasure.count
    var stockSource = ConfirmedStockSource.manual
    var stockConfirmed = false
    var stockDate = Date()
    var outsideAmount = ""
    var outsideUnit = UnitOfMeasure.count
    var outsideReservationsReviewed = false
    var packLabel = ""
    var packAmount = ""
    var packUnit = UnitOfMeasure.count
    var packPrice = ""
    var availability = 0
    var maximumPacks = ""
    var yieldReviewed = false
    var feeEligible = true
}
struct DinnerRecipeMatchDraft: Identifiable {
    let id: UUID
    let commitmentID: UUID
    let acceptedDinnerID: UUID
    let ingredientID: UUID
    let recipeName: String
    let ingredientName: String
    let quantity: Quantity?
    let exclusions: [String]
    var foodID: UUID?
}
struct DinnerBaselineCostDraft: Identifiable {
    let id: UUID
    let name: String
    var cost = ""
    var feeEligible = true
}
struct DinnerReviewedScenarios {
    let shopID: UUID
    let baseRevision: UUID
    let planningRevision: UUID
    let current: DinnerScenario
    let candidate: DinnerScenario
    let cap: CheckoutCap?
}
struct DinnerScenarioDraft {
    let id = UUID()
    let commitmentSetID = UUID()
    let currentID = UUID()
    let candidateID = UUID()
    let shopID: UUID
    let baseRevision: UUID
    let planningRevision: UUID
    let zone: String
    var meals = [DinnerScenarioMealDraft()]
    var foods: [DinnerFoodEvidenceDraft] = []
    var matches: [DinnerRecipeMatchDraft] = []
    var reviewedLeftovers: [ConfirmedStockLot] = []
    var leftoverRevision: Int64?
    private(set) var matchedMeals: [DinnerScenarioMealDraftSnapshot] = []
    var baseline: [DinnerBaselineCostDraft]
    var baselineComplete = false
    var baselineExcludesComparedRecipes = false
    var store = ""
    var branch: String
    var mode: ShoppingMode
    var slot: Date
    var source = ""
    var observedAt = Date()
    var fee = ""
    var feeThreshold = ""
    var tax = ""
    var deposits = ""
    var currentHands = ""
    var currentLead = ""
    var candidateHands = ""
    var candidateLead = ""
    var availableMinutes = ""
    var recipeYieldsReviewed = false
    init(shop: ShoppingLedger, state: DinnerPlanningState) {
        shopID = shop.id; baseRevision = shop.revisionID; planningRevision = state.revisionID; zone = shop.basis.timeZoneIdentifier
        branch = shop.basis.branch; mode = ShoppingMode(rawValue: shop.basis.mode.rawValue) ?? .pickup; slot = shop.basis.slot ?? Date()
        baseline = shop.lines.filter { $0.trashedAt == nil }.map { DinnerBaselineCostDraft(id: $0.id, name: $0.name) }
    }
    mutating func prepareMatches(accepted: [AcceptedDinner]) throws {
        let snapshots = try meals.map { try DinnerScenarioMealDraftSnapshot($0, zone: zone) }
        var next: [DinnerRecipeMatchDraft] = []
        for meal in snapshots {
            for dinnerID in Set([meal.currentDinnerID, meal.candidateDinnerID].compactMap { $0 }).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let dinner = accepted.first(where: { $0.id == dinnerID }) else { throw DinnerPlanningError.notFound(dinnerID) }
                let ratio = try meal.portions.divided(by: dinner.template.servings)
                if dinner.template.servingGroups.contains(where: \.isProtected), ratio != .one, !meal.isReviewedServingGroup || dinnerID != meal.currentDinnerID {
                    throw DinnerPlanningError.reviewRequired("protectedRecipeVersion")
                }
                for ingredient in dinner.template.ingredients {
                    let quantity = try ingredient.quantity.map { value in
                        Quantity(amount: try value.amount.multiplied(by: ratio), unit: value.unit,
                            originalLiteral: value.originalLiteral, confirmedConversion: value.confirmedConversion)
                    }
                    let previous = matches.first { $0.commitmentID == meal.id && $0.acceptedDinnerID == dinnerID && $0.ingredientID == ingredient.id && $0.quantity == quantity }
                    next.append(DinnerRecipeMatchDraft(id: previous?.id ?? UUID(), commitmentID: meal.id, acceptedDinnerID: dinnerID,
                        ingredientID: ingredient.id, recipeName: dinner.template.title, ingredientName: ingredient.name,
                        quantity: quantity, exclusions: ingredient.exclusions + meal.savedExclusions, foodID: previous?.foodID))
                }
            }
        }
        guard !next.isEmpty else { throw DinnerPlanningError.reviewRequired("recipes") }
        matches = next; matchedMeals = snapshots; recipeYieldsReviewed = false
    }
    func build(shop: ShoppingLedger, state: DinnerPlanningState, candidateScenarioID: UUID? = nil) throws -> DinnerReviewedScenarios {
        guard shop.id == shopID, shop.revisionID == baseRevision, state.revisionID == planningRevision else { throw DinnerPlanningError.stalePreview }
        let snapshots = try meals.map { try DinnerScenarioMealDraftSnapshot($0, zone: zone) }
        guard snapshots == matchedMeals, !matches.isEmpty, recipeYieldsReviewed else { throw DinnerPlanningError.reviewRequired("recipeMatches") }
        let commitments = DinnerCommitmentSet(id: commitmentSetID, commitments: snapshots.map {
            DinnerCommitment(id: $0.id, name: $0.name, kind: .dinner, portions: $0.portions, protected: $0.protected, day: $0.day)
        })
        try commitments.validate()
        let foodIDs = Set(foods.map(\.id))
        guard matches.allSatisfy({ $0.foodID.map(foodIDs.contains) == true }) else { throw DinnerPlanningError.reviewRequired("foodIdentity") }
        for match in matches {
            guard let food = foods.first(where: { $0.id == match.foodID }),
                  let dinner = state.acceptedDinners.first(where: { $0.id == match.acceptedDinnerID }) else { throw DinnerPlanningError.reviewRequired("foodIdentity") }
            let exclusions = dinner.template.exclusions + match.exclusions
            try MealTemplate(title: "Reviewed food", ingredients: [MealIngredient(name: food.name, quantity: match.quantity)], exclusions: exclusions).validate()
            if !food.packLabel.isEmpty {
                try MealTemplate(title: "Reviewed pack", ingredients: [MealIngredient(name: food.packLabel, quantity: nil)], exclusions: exclusions).validate()
            }
        }
        var stock = reviewedLeftovers, outside: [StockNeed] = [], packs: [DinnerPackSelection] = []
        for food in foods {
            guard !food.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DinnerPlanningError.invalid("foodName") }
            if food.stockConfirmed {
                guard !reviewedLeftovers.contains(where: { $0.foodID == food.id }) else { throw DinnerPlanningError.reviewRequired("duplicateStock") }
                guard food.outsideReservationsReviewed, let quantity = try DinnerEntry.quantity(food.stockAmount, unit: food.stockUnit) else { throw DinnerPlanningError.reviewRequired("stockReservations") }
                stock.append(ConfirmedStockLot(id: food.stockID, foodID: food.id, name: food.name, usable: quantity, confirmedAt: food.stockDate, source: food.stockSource))
            }
            if let amount = try DinnerEntry.quantity(food.outsideAmount, unit: food.outsideUnit) {
                guard food.outsideReservationsReviewed else { throw DinnerPlanningError.reviewRequired("outsideReservations") }
                outside.append(StockNeed(id: food.reservationID, foodID: food.id, name: food.name, amount: amount, priority: .protected))
            }
            let available: DinnerAvailability
            switch food.availability {
            case 1:
                let limit: Int64?
                if food.maximumPacks.isEmpty { limit = nil }
                else { guard let count = Int64(food.maximumPacks), count >= 0 else { throw DomainError.invalidNumber }; limit = count }
                available = .confirmed(maximumPacks: limit)
            case 2: available = .unavailable
            default: available = .unknown
            }
            if !food.packLabel.isEmpty || !food.packAmount.isEmpty || !food.packPrice.isEmpty || food.availability != 0 {
                packs.append(DinnerPackSelection(id: food.packID, foodID: food.id,
                    offer: PackOffer(id: food.packID.uuidString, label: food.packLabel,
                        usableQuantity: food.yieldReviewed ? try DinnerEntry.quantity(food.packAmount, unit: food.packUnit) : nil,
                        price: try DinnerEntry.money(food.packPrice)), availability: available, thresholdEligible: food.feeEligible))
            }
        }
        let lines = try baseline.map { CheckoutLine(id: $0.id, name: $0.name, cost: try evidence($0.cost, missing: "Unchanged basket line cost is unknown"), thresholdEligible: $0.feeEligible) }
        let context = CheckoutContext(storeID: store, branchID: branch, mode: mode,
            slot: ISO8601DateFormatter().string(from: slot), commitmentsID: commitmentSetID, observedAt: observedAt, source: source)
        let enteredFee = try evidence(fee, missing: "Fees are unknown")
        let rule = try DinnerEntry.money(feeThreshold).map {
            CheckoutFeeRule.waivedAt(threshold: $0, belowThreshold: enteredFee, basis: .eligibleItemsBeforeDiscounts)
        } ?? .fixed(enteredFee)
        let fees = [CheckoutFee(id: "reviewed-fees", rule: rule)]
        let cap = shop.basis.cap.map { CheckoutCap(scope: shop.basis.capScope == .wholeShop ? .wholeCheckout : shop.basis.capScope == .dinnersOnly ? .dinner : .item,
            commitmentsID: commitmentSetID, amount: $0) }
        func scenario(candidate: Bool) throws -> DinnerScenario {
            var demands: [DinnerDemand] = []
            var selected: [UUID] = []
            for meal in snapshots {
                guard let acceptedID = candidate ? meal.candidateDinnerID : meal.currentDinnerID else { continue }
                if !selected.contains(acceptedID) { selected.append(acceptedID) }
                for match in matches where match.commitmentID == meal.id && match.acceptedDinnerID == acceptedID {
                    guard let foodID = match.foodID else { throw DinnerPlanningError.reviewRequired("foodIdentity") }
                    demands.append(DinnerDemand(id: match.id, commitmentID: meal.id, foodID: foodID, name: match.ingredientName,
                        quantity: match.quantity, exclusions: match.exclusions, acceptedDinnerID: acceptedID, ingredientID: match.ingredientID))
                }
            }
            return DinnerScenario(id: candidate ? (candidateScenarioID ?? candidateID) : currentID, commitments: commitments, acceptedDinnerIDs: selected,
                demands: demands, stock: stock, otherReservations: outside, packs: packs, baselineLines: lines,
                baselineComplete: baselineComplete && baselineExcludesComparedRecipes, fees: fees,
                tax: try evidence(tax, missing: "Tax is unknown"), deposits: try evidence(deposits, missing: "Deposits are unknown"),
                context: context, preparation: DinnerPreparation(handsOnMinutes: try DinnerEntry.minutes(candidate ? candidateHands : currentHands),
                    remainingLeadMinutes: try DinnerEntry.minutes(candidate ? candidateLead : currentLead), availableMinutes: try DinnerEntry.minutes(availableMinutes)),
                acceptedChanges: candidate ? snapshots.filter { $0.currentDinnerID != $0.candidateDinnerID }.count : 0)
        }
        return DinnerReviewedScenarios(shopID: shopID, baseRevision: baseRevision, planningRevision: planningRevision,
            current: try scenario(candidate: false), candidate: try scenario(candidate: true), cap: cap)
    }
    private func evidence(_ text: String, missing: String) throws -> CostEvidence {
        try DinnerEntry.money(text).map(CostEvidence.exact) ?? .unknown(reason: missing)
    }
}
struct DinnerScenarioMealDraftSnapshot: Equatable {
    let id: UUID
    let name: String
    let portions: Rational
    let currentDinnerID: UUID?
    let candidateDinnerID: UUID?
    let protected: Bool
    let day: MealDay?
    let isReviewedServingGroup: Bool
    let savedExclusions: [String]
    init(_ draft: DinnerScenarioMealDraft, zone: String) throws {
        id = draft.id; name = draft.name; portions = try DinnerEntry.positive(draft.portions)
        isReviewedServingGroup = draft.isReviewedServingGroup; savedExclusions = draft.savedExclusions
        currentDinnerID = draft.currentDinnerID; candidateDinnerID = draft.candidateDinnerID; protected = draft.protected
        day = try DinnerEntry.date(draft.date, zone: zone, scheduled: draft.scheduled)
    }
}
