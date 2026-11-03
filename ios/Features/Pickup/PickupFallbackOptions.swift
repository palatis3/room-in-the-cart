import Foundation
import CoreDomain

struct FallbackIngredientReview: Equatable {
    var foodID: UUID?
    var packLabel = ""
    var packYield = ""
    var packUnit = UnitOfMeasure.count
    var packPrice = ""
    var availablePacks = ""
}

struct FallbackRecipeReview: Equatable {
    var ingredients: [UUID: FallbackIngredientReview] = [:]
    var elapsedMinutes = ""
    var completedLeadReviewed = false
    var reviewedIdentityYieldAndExclusions = false
}

struct PickupFallbackDraft: Equatable {
    var target: UUID?
    var portions = ""
    var deadline: Date?
    var permitsRepeat = false
    var permitsTrip = false
    var tripMinutes = ""
    var topUpBudget = ""
    var topUpCharges = ""
    var usualMinutes = ""
    var reviews: [UUID: FallbackRecipeReview] = [:]
}

struct PickupFallbackOption: Identifiable {
    let id: UUID
    let title: String
    let buys: [(label: String, count: Int64, cost: Money)]
    let portions: Rational
    let ingredients: [(name: String, required: Quantity, allocated: Quantity)]
    let exclusions: [String]
    let minutes: Int
    let packCount: Int64
    let merchandise: Money
    let extraCash: Money
    let repeatRequired: Bool
    var requiresTrip: Bool { packCount > 0 }
    var instruction: String {
        var lines = [title,dinnerFormat("Servings: %@",portions.description)]
        for ingredient in ingredients {
            lines.append(dinnerFormat("%@ · required %@ · confirmed on hand %@",ingredient.name,dinnerQuantity(ingredient.required),dinnerQuantity(ingredient.allocated)))
        }
        if !exclusions.isEmpty { lines.append(dinnerFormat("Keep these exclusions: %@",exclusions.joined(separator: ", "))) }
        lines += buys.map { dinnerFormat("Top up: %@ × %lld",$0.label,$0.count) }
        return lines.joined(separator: "\n")
    }
}

enum PickupFallbackOptions {
    static func needs(_ journey: PickupJourney) -> [StockNeed] {
        journey.needs.map { .init(id: $0.id, foodID: $0.orderLineID, name: $0.name, amount: $0.amount, priority: $0.priority) } + journey.stockNeeds
    }

    static func lots(_ journey: PickupJourney, at now: Date) -> [ConfirmedStockLot] {
        var lots = journey.stockLots.filter { $0.confirmedAt <= now }
        for receipt in journey.pickup?.receipts ?? [] {
            guard receipt.receivedAt <= now, receipt.disposition != .wrongItem, receipt.disposition != .noFill,
                  let observation = journey.pickup?.usableObservations.last(where: { $0.receipt == receipt.key }),
                  observation.confirmedAt <= now, observation.confirmedMatchToOrderLine else { continue }
            lots.append(.init(id: observation.id, foodID: receipt.key.orderLineID, name: receipt.itemName, usable: observation.usable, confirmedAt: observation.confirmedAt))
        }
        return lots
    }

    static func ranked(journey: PickupJourney, library: [AcceptedDinner], chosenTemplates: Set<UUID>, draft: PickupFallbackDraft,
                       at now: Date, paid: Bool) throws -> [PickupFallbackOption] {
        guard paid else { throw DinnerPlanningError.paidAccessRequired }
        let commitments = needs(journey)
        guard let target = commitments.first(where: { $0.id == draft.target && $0.priority != .protected }),
              !journey.urgent.contains(where: { $0.id == target.id && $0.resolved }),
              let enteredDeadline = draft.deadline else { return [] }
        let savedDeadline = journey.urgent.first { $0.id == target.id }?.due
        let deadline = min(enteredDeadline, savedDeadline ?? enteredDeadline)
        guard deadline >= now else { return [] }
        let portions = try DinnerEntry.positive(draft.portions)
        let outside = commitments.filter { $0.id != target.id }.map {
            StockNeed(id: $0.id, foodID: $0.foodID, name: $0.name, amount: $0.amount, priority: .protected)
        }
        let stock = lots(journey, at: now)
        let available = Int(min(525_600, deadline.timeIntervalSince(now)/60))
        let rules = journey.needDetails.first { $0.id == target.id }?.exclusions ?? []
        var results: [PickupFallbackOption] = []
        for dinner in library where dinner.acceptedFallback {
            guard let review = draft.reviews[dinner.id], review.reviewedIdentityYieldAndExclusions,
                  let elapsed = try? DinnerEntry.minutes(review.elapsedMinutes), elapsed <= available,
                  elapsed >= (dinner.template.leadTimeMinutes ?? 0) || review.completedLeadReviewed,
                  !dinner.template.ingredients.isEmpty else { continue }
            let repeatRequired = chosenTemplates.contains(dinner.template.id)
            guard !repeatRequired || draft.permitsRepeat else { continue }
            guard !dinner.template.servingGroups.contains(where: { $0.isProtected }) || dinner.template.servings == portions else { continue }
            let ratio = try portions.divided(by: dinner.template.servings)
            var demands: [StockNeed] = [], offers: [UUID: FallbackIngredientReview] = [:]
            var valid = true
            for ingredient in dinner.template.ingredients {
                guard let match = review.ingredients[ingredient.id], let food = match.foodID, let original = ingredient.quantity,
                      original.amount > .zero else { valid = false; break }
                let labels = [ingredient.name, match.packLabel] + stock.filter { $0.foodID == food }.map(\.name)
                for name in labels where !name.isEmpty {
                    let check = MealTemplate(title: dinner.template.title, ingredients: [.init(name: name, quantity: nil)],
                                             exclusions: rules + dinner.template.exclusions + ingredient.exclusions)
                    if (try? check.validate()) == nil { valid = false; break }
                }
                let needed = Quantity(amount: try original.amount.multiplied(by: ratio), unit: original.unit,
                                      originalLiteral: original.originalLiteral, confirmedConversion: original.confirmedConversion)
                demands.append(.init(id: ingredient.id, foodID: food, name: ingredient.name, amount: needed, priority: .required))
                if !match.packLabel.isEmpty {
                    if let old = offers[food], old != match { valid = false; break }
                    offers[food] = match
                }
            }
            guard valid else { continue }
            let allocation = try ConfirmedStockAllocator.allocate(lots: stock, needs: outside + demands)
            var buys: [(String,Int64,Money)] = [], count: Int64 = 0, cost: Int64 = 0
            for (food, group) in Dictionary(grouping: demands, by: \.foodID) {
                guard let exemplar = group.first else { continue }
                // An unconvertible protected claim makes the shared supply uncertain for every competing need.
                let competing = Set((outside + demands).filter { $0.foodID == food }.map(\.id))
                guard allocation.demands.filter({ competing.contains($0.id) }).allSatisfy({ $0.issues.isEmpty && $0.shortfall != nil }) else { valid = false; break }
                var short = Rational.zero
                // A top-up cannot spend the share still owed to another reserved meal.
                for demand in group + outside.filter({ $0.foodID == food }) {
                    guard let gap = allocation.demands.first(where: { $0.id == demand.id })?.shortfall,
                          let converted = try Quantity(amount: gap, unit: demand.amount.unit, originalLiteral: "").converted(to: exemplar.amount.unit) else { valid = false; break }
                    short = try short.adding(converted)
                }
                guard valid else { break }
                if short == .zero { continue }
                guard let offer = offers[food], let limit = Int64(offer.availablePacks), limit > 0,
                      let yield = try? DinnerEntry.quantity(offer.packYield, unit: offer.packUnit),
                      let usable = try yield.converted(to: exemplar.amount.unit), usable > .zero,
                      let price = try? DinnerEntry.money(offer.packPrice), price.minorUnits >= 0 else { valid = false; break }
                let packs = try short.divided(by: usable).roundedUp()
                guard packs <= limit else { valid = false; break }
                let subtotal = try price.multiplied(by: packs)
                let totalCount = count.addingReportingOverflow(packs), totalCost = cost.addingReportingOverflow(subtotal.minorUnits)
                guard !totalCount.overflow, !totalCost.overflow else { throw DomainError.overflow }
                count = totalCount.partialValue; cost = totalCost.partialValue
                buys.append((offer.packLabel,packs,subtotal))
            }
            guard valid else { continue }
            var extraCash = Money(minorUnits: cost)
            if count > 0 {
                // The original pickup cap is not evidence of money left for a second checkout.
                guard let budget = try? DinnerEntry.money(draft.topUpBudget), let charges = try? DinnerEntry.money(draft.topUpCharges),
                      budget.minorUnits >= 0, charges.minorUnits >= 0 else { continue }
                let total = cost.addingReportingOverflow(charges.minorUnits)
                guard !total.overflow, total.partialValue <= budget.minorUnits else { continue }
                extraCash = Money(minorUnits: total.partialValue)
            }
            let travel = count > 0 ? try? DinnerEntry.minutes(draft.tripMinutes) : 0
            guard let travel, elapsed + travel <= available else { continue }
            let ingredients = demands.compactMap { demand -> (String,Quantity,Quantity)? in
                guard let coverage = allocation.demands.first(where: { $0.id == demand.id }), let amount = coverage.allocated else { return nil }
                return (demand.name, demand.amount, Quantity(amount: amount,unit: coverage.unit,originalLiteral: ""))
            }
            guard ingredients.count == demands.count else { continue }
            let exclusions = Set(rules + dinner.template.exclusions + dinner.template.ingredients.flatMap(\.exclusions)).sorted()
            results.append(.init(id: dinner.id,title: dinner.template.title,buys: buys.sorted { $0.0 < $1.0 },
                                 portions: portions,ingredients: ingredients,exclusions: exclusions,minutes: elapsed + travel,packCount: count,merchandise: .init(minorUnits: cost),extraCash: extraCash,repeatRequired: repeatRequired))
        }
        return results.sorted {
            if $0.packCount != $1.packCount { return $0.packCount < $1.packCount }
            if $0.merchandise != $1.merchandise { return $0.merchandise.minorUnits < $1.merchandise.minorUnits }
            if $0.minutes != $1.minutes { return $0.minutes < $1.minutes }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
