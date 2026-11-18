import Foundation
import CoreDomain

struct DinnerRepeatStockRow: Identifiable {
    let id: UUID
    let name: String
    let free: [Quantity]
    let reserved: [IdeaSupplyReservation]
    let unresolved: Bool
}

struct DinnerRepeatNeedRow: Identifiable {
    let id: UUID
    let name: String
    let needed: [Quantity]
    let free: [Quantity]
    /// Empty with unresolved=true is unknown, never a known zero purchase.
    let toObtain: [Quantity]
    let unresolved: Bool
}

struct DinnerRepeatProtectedLunch: Identifiable {
    let id: UUID
    let shopID: UUID
    let name: String
    let quantity: Quantity?
    let day: MealDay?
    let isPriorWeek: Bool
}

struct DinnerRepeatStapleCheck: Identifiable {
    enum Status: Equatable { case reviewNeeded, needed, alreadyHandled, skipped, stale }
    let id: StapleSource
    let name: String
    let status: Status
    let handledBy: String?
    /// A previous trip's handled line never settles this week's obligation.
    let priorHandledBy: String?
}

/// Presentation evidence, not purchase authority. The caller supplies one current,
/// authorized canonical read and rechecks it before applying the repeat preview.
/// Nil canonical evidence is explicitly unknown; copied journey stock is not used.
struct DinnerRepeatEvidence {
    let stock: [DinnerRepeatStockRow]
    let priceChecks: [String]
    let notes: [DinnerWeekNote]
    let priorNotes: [DinnerWeekNote]
    let protectedLunches: [DinnerRepeatProtectedLunch]
    let stapleChecks: [DinnerRepeatStapleCheck]
    private let ingredientFoods: [RepeatWeek.Source: [UUID: UUID]]

    private struct Food {
        let id: UUID
        let name: String
        let shopID: UUID
        let lineID: UUID?
    }
    private struct LineKey: Hashable { let shopID: UUID; let lineID: UUID }

    static func build(candidates: [RepeatWeek.Candidate], workspace: LedgerWorkspace, workspaceID: UUID,
                      authorizedShopIDs: Set<UUID>, targetShopID: UUID, sourceDays: [MealDay], targetDays: [MealDay],
                      staples: [ReviewedStaple] = [], recoveredMeals: [UUID: RepeatWeek.Recovery] = [:],
                      canonical: DinnerPantrySupply.Snapshot?, unknownFoodIDs: Set<UUID> = [], asOf now: Date) throws -> Self {
        guard now.timeIntervalSinceReferenceDate.isFinite, authorizedShopIDs.contains(targetShopID),
              let target = workspace.shops.first(where: { $0.id == targetShopID }),
              candidates.count <= 500, staples.count <= 500, sourceDays.count <= 7, targetDays.count <= 7,
              Set(candidates.map(\.id)).count == candidates.count,
              Set(staples.map(\.id)).count == staples.count else { throw DinnerPlanningError.forbidden }
        for day in sourceDays + targetDays { try day.validate() }
        let shops = Dictionary(grouping: workspace.shops, by: \.id)
        var foods: [Food] = []
        var ingredientFoods: [RepeatWeek.Source: [UUID: UUID]] = [:]
        for candidate in candidates {
            try candidate.template.validate()
            let source = candidate.source
            guard authorizedShopIDs.contains(source.shopID), let rows = shops[source.shopID], rows.count == 1,
                  let shop = rows.first, shop.revisionID == source.shopRevision,
                  includes(sourceDays, candidate.sourceDay), includes(targetDays, candidate.targetDay),
                  let occurrence = shop.mealOccurrences.first(where: { $0.id == source.occurrenceID }),
                  occurrence.removedAt == nil, !occurrence.isHidden, occurrence.carryover == nil
            else { throw DinnerPlanningError.stalePreview }
            if let revision = source.recoveryRevision {
                guard let recovery = recoveredMeals[occurrence.id], recovery.meal.id == occurrence.id,
                      recovery.meal.revisionID == revision,
                      recovery.meal.scheduledDay?.hasSameCivilDate(as: candidate.sourceDay) == true,
                      candidate.template.ingredients.map(\.id) == recovery.meal.ingredients.map(\.need.id)
                else { throw DinnerPlanningError.stalePreview }
                for (ingredient, recovered) in zip(candidate.template.ingredients, recovery.meal.ingredients) {
                    guard ingredient.name == recovered.foodName, ingredient.quantity == recovered.need.amount
                    else { throw DinnerPlanningError.stalePreview }
                    // Only this persisted replacement's explicit food identity is relevant.
                    let line = shop.lines.first { $0.id == recovered.need.foodID && !$0.isTrashed }
                    foods.append(.init(id: recovered.need.foodID, name: ingredient.name, shopID: shop.id, lineID: line?.id))
                    ingredientFoods[source, default: [:]][ingredient.id] = recovered.need.foodID
                }
            } else {
                guard recoveredMeals[occurrence.id] == nil,
                      occurrence.scheduledDay?.hasSameCivilDate(as: candidate.sourceDay) == true
                else { throw DinnerPlanningError.stalePreview }
                for ingredient in candidate.template.ingredients {
                    guard occurrence.ingredientContributionIDs.contains(ingredient.id),
                          let contribution = shop.contributions.first(where: { $0.id == ingredient.id }),
                          contribution.removedAt == nil, contribution.source == .meal(occurrenceID: occurrence.id),
                          contribution.productName == ingredient.name, contribution.quantity == ingredient.quantity,
                          let line = shop.lines.first(where: { $0.id == contribution.lineID && !$0.isTrashed })
                    else { throw DinnerPlanningError.stalePreview }
                    foods.append(.init(id: line.id, name: ingredient.name, shopID: shop.id, lineID: line.id))
                    ingredientFoods[source, default: [:]][ingredient.id] = line.id
                }
            }
        }
        var stapleChecks: [DinnerRepeatStapleCheck] = []
        for review in staples {
            guard authorizedShopIDs.contains(review.source.shopID), review.targetID == targetShopID,
                  let source = shops[review.source.shopID]?.first,
                  source.revisionID == review.sourceRevision, source.lines.contains(review.line),
                  review.source.lineID == review.line.id, !review.line.isTrashed,
                  review.line.stapleApproval == review.approval else { throw DinnerPlanningError.stalePreview }
            let receipts = (target.stapleReviews ?? []).filter { $0.source == review.source }
            guard receipts.count <= 1 else { throw DinnerPlanningError.stalePreview }
            let status: DinnerRepeatStapleCheck.Status
            var handledBy: String?
            if let receipt = receipts.first {
                switch receipt.choice {
                case .needed:
                    status = target.lines.contains { $0.id == receipt.newLineID && !$0.isTrashed && !$0.isHandled } ? .needed : .stale
                case .skip: status = .skipped
                case .alreadyHandled:
                    if let handled = receipt.handledLine {
                        let exact = target.lines.contains { $0.id == handled.lineID && !$0.isTrashed && $0.isHandled && $0.handledBy == handled.boughtBy }
                        status = exact ? .alreadyHandled : .stale
                        if exact { handledBy = handled.boughtBy }
                    } else { status = .alreadyHandled }
                }
            } else {
                status = review.targetRevision == target.revisionID ? .reviewNeeded : .stale
            }
            stapleChecks.append(.init(id: review.source, name: review.line.name, status: status,
                handledBy: handledBy, priorHandledBy: review.line.isHandled ? review.line.handledBy : nil))
            // Already-handled shopping is not physical stock, and cannot create a pantry credit.
            if status != .alreadyHandled && status != .skipped {
                foods.append(.init(id: review.line.id, name: review.line.name, shopID: source.id, lineID: review.line.id))
            }
        }
        var seen = Set<UUID>()
        let confirmedFoodIDs = Set(canonical?.foods.map(\.id) ?? [])
        let stock = foods.filter { seen.insert($0.id).inserted }.map { food in
            DinnerRepeatStockRow(id: food.id, name: food.name,
                free: canonical?.globallyFreeLots.filter { $0.foodID == food.id }.map(\.usable) ?? [],
                reserved: canonical?.reservations[food.id] ?? [],
                unresolved: canonical == nil || !confirmedFoodIDs.contains(food.id)
                    || canonical?.unresolvedFoodIDs.contains(food.id) == true || unknownFoodIDs.contains(food.id))
        }
        var checkedLines = Set<LineKey>()
        let prices = foods.compactMap { food -> String? in
            guard let lineID = food.lineID else { return format("%@: no price is linked to the confirmed food identity.", food.name) }
            guard checkedLines.insert(.init(shopID: food.shopID, lineID: lineID)).inserted,
                  let shop = shops[food.shopID]?.first else { return nil }
            // A settled/trashed shopping line is not a new purchase-price promise.
            guard shop.lines.contains(where: { $0.id == lineID && !$0.isTrashed && !$0.isHandled }) else { return nil }
            let saved = workspace.packSelections.filter { $0.sourceWorkspaceID == workspaceID && $0.shopID == shop.id && $0.lineID == lineID }
            let current = saved.filter { selection in
                guard selection.reviewedAt <= now, selection.shopRevisionID == shop.revisionID,
                      selection.basisRevision == shop.basisRevision,
                      (try? selection.validateReference(in: shop)) != nil,
                      let requirement = try? LedgerPackRequirement.review(shop: shop, lineID: lineID, bindings: workspace.dinnerPlanning.portionBindings)
                else { return false }
                return selection.request.itemName == requirement.name && selection.request.needed == requirement.quantity
                    && selection.request.protectedAmount == requirement.protectedQuantity
            }
            guard current.count == 1, let selection = current.first else {
                return format(saved.isEmpty ? "%@: package price needs review." : "%@: previous package evidence is stale or conflicting; review the price again.", food.name)
            }
            // The package observation may be disclosed; prior stock credit and total are never reused.
            let offer = selection.request.offerA.id == selection.selectedOfferID ? selection.request.offerA : selection.request.offerB
            guard let price = offer.price else { return format("%@: package price needs review.", food.name) }
            return format("%@: previous package price %@, %@, reviewed %@. Confirm the price for this pickup.", food.name,
                dinnerMoney(price), selection.source, selection.reviewedAt.formatted(date: .abbreviated, time: .omitted))
        }
        let sourceShopIDs = Set(candidates.map { $0.source.shopID }).union(staples.map { $0.source.shopID })
        let priorNotes = workspace.dinnerPlanning.weekNotes.filter {
            authorizedShopIDs.contains($0.shopID) && sourceShopIDs.contains($0.shopID) && includes(sourceDays, $0.day)
        }
        let notes = workspace.dinnerPlanning.weekNotes.filter { $0.shopID == targetShopID && includes(targetDays, $0.day) }
        var lunches: [DinnerRepeatProtectedLunch] = []
        for shop in workspace.shops where authorizedShopIDs.contains(shop.id) {
            let prior = sourceShopIDs.contains(shop.id)
            guard prior || shop.id == targetShopID else { continue }
            for contribution in shop.contributions where contribution.removedAt == nil && contribution.source.isProtected {
                guard shop.lines.contains(where: { $0.id == contribution.lineID && !$0.isTrashed }) else { continue }
                let day = workspace.dinnerPlanning.protectedDays.first { $0.shopID == shop.id && $0.contributionID == contribution.id }?.day
                let inPrior = prior && (day.map { includes(sourceDays, $0) } ?? true)
                let inTarget = shop.id == targetShopID && (day.map { includes(targetDays, $0) } ?? true)
                guard inPrior || inTarget else { continue }
                lunches.append(.init(id: contribution.id, shopID: shop.id, name: contribution.productName,
                    quantity: contribution.quantity, day: day, isPriorWeek: inPrior && !inTarget))
            }
        }
        return Self(stock: stock, priceChecks: prices, notes: notes, priorNotes: priorNotes,
                    protectedLunches: lunches, stapleChecks: stapleChecks, ingredientFoods: ingredientFoods)
    }

    /// A new-demand preview only. Current global holds are already reflected in
    /// `free`; source meals' old reservations are not released to fund the repeat.
    /// Group all selected ingredients before applying each food's free balance,
    /// so two meals cannot both receive the same available stock.
    func shoppingNeeds(for selections: [RepeatWeek.Selection], candidates: [RepeatWeek.Candidate]) throws -> [DinnerRepeatNeedRow] {
        guard selections.count <= 500, Set(selections.map(\.source)).count == selections.count else {
            throw DinnerPlanningError.stalePreview
        }
        let candidatesBySource = Dictionary(grouping: candidates, by: \.source)
        var amounts: [UUID: [Quantity]] = [:], unknown = Set<UUID>(), order: [UUID] = []
        var seen = Set<UUID>()
        for selection in selections {
            guard let rows = candidatesBySource[selection.source], rows.count == 1, let candidate = rows.first,
                  let matches = ingredientFoods[selection.source] else { throw DinnerPlanningError.stalePreview }
            let template = try RepeatWeekEngine.projectedTemplate(selection, candidate: candidate)
            for ingredient in template.ingredients {
                guard let foodID = matches[ingredient.id] else { throw DinnerPlanningError.stalePreview }
                if seen.insert(foodID).inserted { order.append(foodID) }
                if let quantity = ingredient.quantity { amounts[foodID, default: []].append(quantity) }
                else { unknown.insert(foodID) }
            }
        }
        let stockByFood = Dictionary(grouping: stock, by: \.id)
        return try order.map { foodID in
            guard let rows = stockByFood[foodID], rows.count == 1, let row = rows.first else { throw DinnerPlanningError.stalePreview }
            let quantities = amounts[foodID] ?? []
            guard let first = quantities.first else {
                return .init(id: foodID, name: row.name, needed: [], free: row.free, toObtain: [], unresolved: true)
            }
            var demand = Rational.zero
            for quantity in quantities {
                guard let value = try quantity.converted(to: first.unit, using: first.confirmedConversion) else {
                    return .init(id: foodID, name: row.name, needed: quantities, free: row.free, toObtain: [], unresolved: true)
                }
                demand = try demand.adding(value)
            }
            let needed = Quantity(amount: demand, unit: first.unit, originalLiteral: demand.description)
            guard !row.unresolved, !unknown.contains(foodID) else {
                return .init(id: foodID, name: row.name, needed: [needed], free: row.free, toObtain: [], unresolved: true)
            }
            var available = Rational.zero
            for quantity in row.free {
                guard let value = try quantity.converted(to: first.unit, using: first.confirmedConversion) else {
                    return .init(id: foodID, name: row.name, needed: [needed], free: row.free, toObtain: [], unresolved: true)
                }
                available = try available.adding(value)
            }
            // Rational is nonnegative: establish known coverage before subtraction.
            let remaining = try demand.subtractingClampedToZero(available)
            let obtain = Quantity(amount: remaining, unit: first.unit, originalLiteral: remaining.description)
            return .init(id: foodID, name: row.name, needed: [needed], free: row.free, toObtain: [obtain], unresolved: false)
        }
    }

    private static func includes(_ days: [MealDay], _ day: MealDay) -> Bool {
        days.contains { $0.hasSameCivilDate(as: day) }
    }

    private static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key), table: "DinnerRepeatEvidence"), locale: .current, arguments: arguments)
    }
}
