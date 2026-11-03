import Foundation
import CoreDomain

struct IdeaSupplyFood: Identifiable {
    let id: UUID
    let name: String
    let detail: String
}

struct IdeaSupplyReservation: Identifiable {
    let id: UUID
    let name: String
    let quantity: Quantity
    let protected: Bool
}

struct IdeaSupplyRow: Identifiable {
    let id: UUID
    let ingredients: [MealIngredient]
    let matchedName: String?
    let excludedMatch: Bool
    let demand: Quantity?
    let credited: Quantity?
    let uncovered: Quantity?
    let reservations: [IdeaSupplyReservation]
    let pack: PackOffer?
    let source: String?
    let observedAt: Date?
    let packs: Int64?
    let cost: Money?
    let conflictingPacks: Bool
}

/// One calculation per explicitly matched food. Repeat ingredients share its remaining
/// stock and package rounding. Equal labels alone never establish identity.
enum DinnerIdeaSupplyReview {
    private enum GroupID: Hashable { case food(UUID), ingredient(UUID) }
    private struct Observation {
        let pack: PackOffer
        let source: String
        let date: Date
    }

    static func foods(shop: ShoppingLedger, journey: PickupJourney?, at now: Date) -> [IdeaSupplyFood] {
        var seen = Set<UUID>()
        let lines = shop.lines.filter { !$0.isTrashed && !$0.isHandled }
        var choices = lines.enumerated().map { index, line in
            IdeaSupplyFood(id: line.id, name: line.name, detail: dinnerFormat("Shopping list item %@", String(index + 1)))
        }
        let lots = journey.flatMap { $0.id == shop.id ? $0 : nil }.map { PickupFallbackOptions.lots($0, at: now) } ?? []
        for lot in lots {
            let origin: String
            switch lot.source {
            case .pantry: origin = dinnerText("Pantry")
            case .freezer: origin = dinnerText("Freezer")
            case .manual: origin = dinnerText("Confirmed stock")
            }
            let detail = [origin, dinnerQuantity(lot.usable), lot.confirmedAt.formatted(date: .abbreviated, time: .shortened)].joined(separator: " · ")
            choices.append(IdeaSupplyFood(id: lot.foodID, name: lot.name, detail: detail))
        }
        return choices.filter { seen.insert($0.id).inserted }
    }

    static func rows(idea: DinnerIdeaDraft, shop: ShoppingLedger, workspace: LedgerWorkspace,
                     workspaceID: UUID, journey: PickupJourney?, at now: Date) throws -> [IdeaSupplyRow] {
        let current = journey.flatMap { $0.id == shop.id && $0.closedAt == nil ? $0 : nil }
        let lots = current.map { PickupFallbackOptions.lots($0, at: now) } ?? []
        var needs = current?.stockNeeds ?? []
        var unresolvedFoods = Set<UUID>()
        let placed = current?.basket?.phase == .reportedPlaced
        var named: [AllocationNeed] = []
        if let current, current.pickup != nil || placed {
            named = current.pickup == nil ? current.plannedNeeds : current.needs
        } else {
            for line in shop.lines where !line.isTrashed && !line.isHandled {
                let sources = shop.contributions(forLineID: line.id)
                guard sources.contains(where: { $0.source.isMeal || $0.source.isProtected }) else { continue }
                guard let unit = sources.first(where: { $0.quantity != nil })?.quantity?.unit,
                      let reservations = try? LedgerCheckoutAdapter.namedReservations(shop: shop, lineID: line.id, unit: unit,
                                                                                      bindings: workspace.dinnerPlanning.portionBindings) else {
                    unresolvedFoods.insert(line.id)
                    continue
                }
                named += reservations.needs
            }
        }
        let separateNeedIDs = Set(needs.map(\.id))
        needs += named.filter { !separateNeedIDs.contains($0.id) }.map {
            StockNeed(id: $0.id, foodID: $0.orderLineID, name: $0.name, amount: $0.amount, priority: $0.priority)
        }
        let allocation = try ConfirmedStockAllocator.allocate(lots: lots, needs: needs)
        let availableFoods = foods(shop: shop, journey: current, at: now)
        let foodIDs = Set(availableFoods.map(\.id))
        let scoped = (idea.supplyEvidence ?? []).filter { $0.workspaceID == workspaceID && $0.shopID == shop.id }
        var groups: [GroupID: [MealIngredient]] = [:]
        var order: [GroupID] = []
        for ingredient in idea.template.ingredients {
            let match = scoped.first { $0.id == ingredient.id && $0.ingredientName == ingredient.name }?.foodID
            let key = match.flatMap { foodIDs.contains($0) ? GroupID.food($0) : nil } ?? .ingredient(ingredient.id)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(ingredient)
        }
        return try order.compactMap { key in
            guard let ingredients = groups[key], let first = ingredients.first else { return nil }
            let foodID: UUID?
            switch key { case .food(let id): foodID = id; case .ingredient: foodID = nil }
            let unit = first.quantity?.unit
            let demand = try total(ingredients.map(\.quantity), unit: unit)
            let coverage = allocation.demands.filter { $0.foodID == foodID }
            let reservations = coverage.compactMap { entry -> IdeaSupplyReservation? in
                guard let amount = entry.allocated, amount > .zero, let need = needs.first(where: { $0.id == entry.id }) else { return nil }
                return IdeaSupplyReservation(id: need.id, name: need.name, quantity: quantity(amount, entry.unit), protected: need.priority == .protected)
            }
            let balances = allocation.remainingLots.filter { $0.foodID == foodID }
            let matched = availableFoods.first { $0.id == foodID }
            let labels = ([matched?.name].compactMap { $0 } + lots.filter { $0.foodID == foodID }.map(\.name))
            let excludedMatch = !allows(labels, for: ingredients, in: idea)
            let valid = foodID.map { !unresolvedFoods.contains($0) } ?? true
            let resolvedBalances = valid && !excludedMatch && balances.allSatisfy { $0.issues.isEmpty } && coverage.allSatisfy { $0.issues.isEmpty }
            let free = try resolvedBalances ? total(balances.map { quantity($0.remainingUnallocated, $0.unit) }, unit: unit) : nil
            let uncovered = try demand.flatMap { demand in try free.map { quantity(max(.zero, try demand.amount.subtracting($0.amount)), demand.unit) } }
            var observations = ingredients.compactMap { ingredient -> Observation? in
                guard let evidence = scoped.first(where: { $0.id == ingredient.id && $0.ingredientName == ingredient.name }),
                      evidence.basisRevision == shop.basisRevision, let pack = evidence.pack,
                      let source = evidence.source, let date = evidence.observedAt, date <= now else { return nil }
                return Observation(pack: pack, source: source, date: date)
            }
            if observations.isEmpty, let foodID, let selected = try workspace.currentPackSelection(shopID: shop.id, lineID: foodID, workspaceID: workspaceID),
               selected.reviewedAt <= now {
                let pack = selected.request.offerA.id == selected.selectedOfferID ? selected.request.offerA : selected.request.offerB
                observations.append(Observation(pack: pack, source: selected.source, date: selected.reviewedAt))
            }
            let observation = observations.first.flatMap { first in
                observations.allSatisfy { $0.pack.usableQuantity == first.pack.usableQuantity && $0.pack.price == first.pack.price &&
                    $0.pack.confirmedConversion == first.pack.confirmedConversion && $0.source == first.source && $0.date == first.date } ? first : nil
            }
            let excludedPack = observation.map { !allows([$0.pack.label], for: ingredients, in: idea) } ?? false
            let count: Int64?
            if excludedPack { count = nil }
            else if uncovered?.amount == .zero { count = 0 }
            else if let uncovered, let usable = observation?.pack.usableQuantity,
                    let yield = try usable.converted(to: uncovered.unit, using: observation?.pack.confirmedConversion), yield > .zero {
                count = try uncovered.amount.divided(by: yield).roundedUp()
            } else { count = nil }
            let cost = try count.flatMap { $0 == 0 ? Money.zero : try observation?.pack.price?.multiplied(by: $0) }
            return IdeaSupplyRow(id: first.id, ingredients: ingredients, matchedName: matched?.name, excludedMatch: excludedMatch || excludedPack, demand: demand, credited: free, uncovered: uncovered,
                                 reservations: reservations, pack: observation?.pack, source: observation?.source, observedAt: observation?.date,
                                 packs: count, cost: cost, conflictingPacks: !observations.isEmpty && observation == nil)
        }
    }

    private static func allows(_ labels: [String], for ingredients: [MealIngredient], in idea: DinnerIdeaDraft) -> Bool {
        let exclusions = Array(Set(idea.hardExclusions + idea.template.exclusions + ingredients.flatMap(\.exclusions)))
        guard !exclusions.isEmpty else { return true }
        let items = Set(labels).map { MealIngredient(name: $0, quantity: nil) }
        let review = MealTemplate(title: idea.template.title, ingredients: items, exclusions: exclusions)
        return (try? review.validate()) != nil
    }

    private static func total(_ values: [Quantity?], unit: UnitOfMeasure?) throws -> Quantity? {
        guard let unit else { return nil }
        var sum = Rational.zero
        for value in values {
            guard let converted = try value?.converted(to: unit) else { return nil }
            sum = try sum.adding(converted)
        }
        return quantity(sum, unit)
    }

    private static func quantity(_ amount: Rational, _ unit: UnitOfMeasure) -> Quantity {
        Quantity(amount: amount, unit: unit, originalLiteral: amount.description)
    }
}
