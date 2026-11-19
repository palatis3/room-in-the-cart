import Foundation

/// One reviewed identity per grocery, including the demand already on the list.
/// Unlinked ingredients retain their own row and an unknown price.
public enum ThreeDinnerBasket {
    public struct Member: Hashable, Sendable {
        public let recipe: UUID
        public let ingredient: UUID
        public init(_ recipe: UUID, _ ingredient: UUID) { self.recipe = recipe; self.ingredient = ingredient }
    }
    public struct Food: Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let existingLine: UUID?
        public let existingQuantity: Quantity?
        public let members: Set<Member>
        public var offer: PackOffer?
        public var source: String?
        public var observedAt: Date?
        public init(id: UUID = UUID(), name: String, existingLine: UUID? = nil, existingQuantity: Quantity? = nil,
                    members: Set<Member>, offer: PackOffer? = nil, source: String? = nil, observedAt: Date? = nil) {
            self.id = id; self.name = name; self.existingLine = existingLine; self.existingQuantity = existingQuantity
            self.members = members; self.offer = offer; self.source = source; self.observedAt = observedAt
        }
    }
    public struct Line: Identifiable, Sendable {
        public var id: UUID { food.id }
        public let food: Food
        public let recipes: [String]
        public let packs: Int64?
        public let cost: Money?
    }
    public struct Plan: Sendable {
        public let meals: [AcceptedDinner]
        public let lines: [Line]
        public let subtotal: Money
        public var missing: Int { lines.filter { $0.cost == nil }.count }
    }

    public static func changes(for plan: Plan, days: [MealDay], lunch: Rational, lunchName: String) throws -> [DinnerLedgerChange] {
        guard days.count == 3, plan.meals.count == 3 else { throw DinnerPlanningError.invalid("basketNights") }
        var destinations = Dictionary(uniqueKeysWithValues: plan.lines.compactMap { line in line.food.existingLine.map { (line.id, $0) } })
        let identities = Dictionary(uniqueKeysWithValues: plan.lines.flatMap { line in line.food.members.map { ($0, line.id) } })
        return try zip(plan.meals, days).map { meal, day in
            var choice = PlannedDinner(acceptedDinnerID: meal.id, template: meal.template, day: day)
            if lunch > .zero { choice.lunchHold = ServingGroup(name: lunchName, servings: lunch, isProtected: true) }
            var links: [Int: UUID] = [:]
            for (index, ingredient) in meal.template.ingredients.enumerated() {
                guard let food = identities[Member(meal.id, ingredient.id)] else { throw DinnerPlanningError.reviewRequired("groceryMatch") }
                if let destination = destinations[food] { links[index] = destination }
                else { destinations[food] = choice.lineIDs[index] }
            }
            if !links.isEmpty { choice.reviewedGroceryLines = links }
            try choice.validate()
            return .choose(choice)
        }
    }

    public static func search(recipes: [AcceptedDinner], days: [MealDay], minutes: [Int?], lunch: Rational,
                              budget: Money?, foods: [Food], shop: ShoppingLedger, state: DinnerPlanningState,
                              access: DinnerAccessContext, now: Date, pins: [Int: UUID] = [:], exclude: Set<UUID> = []) throws -> [Plan] {
        try access.validate(shopID: shop.id, at: now, budget: true)
        guard case .local = access.scope else { throw DinnerPlanningError.forbidden }
        guard access.hasPaidTools else { throw DinnerPlanningError.paidAccessRequired }
        guard days.count == 3, Set(days.map(\.iso8601)).count == 3, days.allSatisfy({ $0.timeZoneIdentifier == shop.basis.timeZoneIdentifier }),
              minutes.count == 3, minutes.allSatisfy({ $0.map { (0...1440).contains($0) } ?? true }),
              budget?.minorUnits ?? 0 >= 0, recipes.count <= 12, Set(recipes.map(\.id)).count == recipes.count
        else { throw DinnerPlanningError.invalid("basketNights") }
        for day in days {
            try day.validate()
            guard !shop.mealOccurrences.contains(where: { $0.removedAt == nil && $0.scheduledDay?.hasSameCivilDate(as: day) == true }),
                  !state.weekNotes.contains(where: { $0.shopID == shop.id && $0.kind == .away && $0.day.hasSameCivilDate(as: day) })
            else { throw DinnerPlanningError.reviewRequired("openNights") }
        }
        let members = foods.flatMap(\.members)
        let requirements = recipes.flatMap { meal in meal.template.ingredients.map { Member(meal.id, $0.id) } }
        let existing = foods.compactMap(\.existingLine)
        guard Set(foods.map(\.id)).count == foods.count, Set(members).count == members.count, Set(members) == Set(requirements),
              Set(existing).count == existing.count, Set(existing) == Set(shop.lines.filter { !$0.isTrashed && !$0.isHandled }.map(\.id)),
              recipes.allSatisfy(state.acceptedDinners.contains) else { throw DinnerPlanningError.reviewRequired("basketInputs") }
        for food in foods {
            if let lineID = food.existingLine {
                guard let line = shop.lines.first(where: { $0.id == lineID }), line.name == food.name,
                      food.members.isEmpty || !line.isChecked,
                      food.existingQuantity == (try shop.quantity(forLineID: lineID))
                else { throw DinnerPlanningError.stalePreview }
            }
            if food.offer != nil {
                guard let date = food.observedAt, date.timeIntervalSinceReferenceDate.isFinite, date <= now,
                      food.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else { throw DinnerPlanningError.reviewRequired("packEvidence") }
            }
        }
        let available = try recipes.filter { meal in
            let t = meal.template
            guard !t.ingredients.isEmpty, !exclude.contains(meal.id), MealEligibilityPolicy.evaluate(profile: state.preferences(for: access), template: t).eligible else { return false }
            guard lunch > .zero else { return true }
            let assigned = try t.servingGroups.reduce(Rational.zero) { try $0.adding($1.servings) }
            return try lunch < t.servings && assigned.adding(lunch) <= t.servings && t.servingGroups.count < 100
        }
        let pools = minutes.enumerated().map { index, limit in
            available.filter { meal in (pins[index] == nil || pins[index] == meal.id) &&
                (limit.map { maxMinutes in meal.template.leadTimeMinutes.map { $0 <= maxMinutes } ?? false } ?? true) }
        }
        let identity = Dictionary(uniqueKeysWithValues: foods.flatMap { food in food.members.map { ($0, food.id) } })
        var visited = Set<Set<UUID>>()
        var top: [Plan] = []
        for first in pools[0] {
            for second in pools[1] where first.template.id != second.template.id {
                for third in pools[2] where first.template.id != third.template.id && second.template.id != third.template.id {
                    let meals = [first, second, third]
                    guard visited.insert(Set(meals.map(\.id))).inserted else { continue }
                    let plan = try price(meals, foods: foods, identity: identity)
                    if let budget, plan.subtotal > budget { continue }
                    top.append(plan)
                    top.sort { a, b in
                        if a.missing != b.missing { return a.missing < b.missing }
                        if a.subtotal != b.subtotal { return a.subtotal < b.subtotal }
                        if a.lines.count != b.lines.count { return a.lines.count < b.lines.count }
                        return a.meals.map(\.id.uuidString).lexicographicallyPrecedes(b.meals.map(\.id.uuidString))
                    }
                    if top.count > 2 { top.removeLast() }
                }
            }
        }
        return top
    }

    private static func price(_ meals: [AcceptedDinner], foods: [Food], identity: [Member: UUID]) throws -> Plan {
        var recipeQuantities: [UUID: [Quantity?]] = [:]
        var recipeNames: [UUID: [String]] = [:]
        for meal in meals {
            var used = Set<UUID>()
            for ingredient in meal.template.ingredients {
                guard let id = identity[Member(meal.id, ingredient.id)] else { throw DinnerPlanningError.reviewRequired("groceryMatch") }
                recipeQuantities[id, default: []].append(ingredient.quantity)
                if used.insert(id).inserted { recipeNames[id, default: []].append(meal.template.title) }
            }
        }
        var lines: [Line] = []
        var subtotal: Int64 = 0
        for food in foods {
            guard food.existingLine != nil || recipeQuantities[food.id] != nil else { continue }
            let quantities = (food.existingLine != nil ? [food.existingQuantity] : []) + (recipeQuantities[food.id] ?? [])
            var count: Int64?, cost: Money?
            if let offer = food.offer, let unit = offer.usableQuantity, unit.amount > .zero,
               food.observedAt != nil, food.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                let amounts = try quantities.compactMap { try $0?.converted(to: unit.unit, using: offer.confirmedConversion) }
                if amounts.count == quantities.count {
                    let amount = try amounts.reduce(Rational.zero) { try $0.adding($1) }
                    let packs = try amount.divided(by: unit.amount).roundedUp()
                    count = packs
                    if let price = offer.price, price.minorUnits >= 0 {
                        let priced = try price.multiplied(by: packs)
                        cost = priced
                        subtotal = try checkedAdd(subtotal, priced.minorUnits)
                    }
                }
            }
            lines.append(.init(food: food, recipes: recipeNames[food.id] ?? [], packs: count, cost: cost))
        }
        return Plan(meals: meals, lines: lines, subtotal: Money(minorUnits: subtotal))
    }
}
