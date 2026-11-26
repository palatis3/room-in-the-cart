import Foundation

/// A private recipe can be used for a whole meal or as a source for individual
/// shopping lines. Only choosing the whole meal creates meal demand.
public struct SavedDinnerReview: Identifiable, Sendable {
    public enum Action: Sendable {
        case planTonight
        case plan(day: MealDay, servings: Rational)
        case groceries(Set<UUID>)
    }

    public let id: UUID
    public let recipe: MealTemplate
    public let shopID: UUID
    public let destinationTitle: String
    public let ingredients: [MealIngredient]
    public let plansDinner: Bool
    private let scope: DinnerAccessContext.Scope
    private let actor: String
    private let originalRevision: UUID
    private let planningRevision: UUID
    private let proposal: DinnerProposal?
    public let plannedDay: MealDay?
    public let plannedServings: Rational?
    public let pantryProducts: DinnerPantryProducts?
    private let reservedFoods: Set<UUID>
    private let preparationDay: MealDay?
    private let matched: [UUID: UUID]
    public let receipt: DinnerGroceryReceipt
    public var occurrenceID: UUID? {
        guard let proposal, case let .choose(meal) = proposal.changes.first else { return nil }
        return meal.occurrenceID
    }

    public init(recipe: MealTemplate, action: Action, workspace: LedgerWorkspace,
                access: DinnerAccessContext, phase: BasketPhase, at now: Date, pantryReview: (match: PantryMealMatcher.Review, originID: UUID)? = nil, reservedFoods: Set<UUID> = [],
                omittedIngredientIDs: Set<UUID>? = nil, rememberChoices: Bool = false) throws {
        guard case let .local(localID) = access.scope, let shop = workspace.shops.first(where: { $0.id == workspace.selectedShopID })
        else { throw DinnerPlanningError.forbidden }
        try access.validate(shopID: shop.id, at: now, applying: true)
        guard phase == .draft else { throw DinnerPlanningError.lockedBasket }
        let accepted = try Self.source(recipe, workspace: workspace, access: access)
        self.recipe = recipe
        self.reservedFoods = reservedFoods
        shopID = shop.id
        destinationTitle = shop.title
        scope = access.scope
        actor = access.actorID
        originalRevision = shop.revisionID
        planningRevision = workspace.dinnerPlanning.revisionID
        id = UUID()
        if let pantryReview {
            guard case .local = access.scope, pantryReview.match.recipe == recipe else { throw DinnerPlanningError.forbidden }
            pantryProducts = try DinnerPantryProducts(review: pantryReview.match, workspace: workspace, originID: pantryReview.originID,
                destinationShopID: shop.id, reservedFoods: reservedFoods)
        } else { pantryProducts = nil }
        let omitted = omittedIngredientIDs ?? Set(recipe.ingredients.filter(\.suggestedShoppingExtra).map(\.id))
        guard omitted.isSubset(of: Set(recipe.ingredients.map(\.id))) else { throw DinnerPlanningError.invalid("optionalIngredients") }
        let chosen: [MealIngredient]
        if case let .groceries(ids) = action { chosen = recipe.ingredients.filter { ids.contains($0.id) } }
        else { chosen = recipe.ingredients.filter { !omitted.contains($0.id) } }
        matched = pantryProducts == nil ? Self.matches(chosen, in: shop, exclusions: recipe.exclusions) : [:]
        let changes = try Self.amounts(chosen, in: shop, matched: matched)
        switch action {
        case .planTonight, .plan:
            let tonight = try MealDay(date: now, timeZoneIdentifier: shop.basis.timeZoneIdentifier)
            let chosenDay: MealDay, servings: Rational
            if case let .plan(day, count) = action {
                guard day.timeZoneIdentifier == shop.basis.timeZoneIdentifier else { throw DinnerPlanningError.stalePreview }
                chosenDay = day; servings = count
            } else {
                chosenDay = tonight; servings = recipe.servings
            }
            var meal = PlannedDinner(acceptedDinnerID: accepted?.id, template: recipe, lineIDs: pantryProducts?.lineIDs(for: recipe), day: chosenDay)
            meal.pantryProducts = pantryProducts
            if !omitted.isEmpty { meal.omittedIngredientIDs = omitted.sorted { $0.uuidString < $1.uuidString } }
            if !matched.isEmpty {
                let matchesForPlan = matched
                meal.reviewedGroceryLines = Dictionary(uniqueKeysWithValues: recipe.ingredients.indices.compactMap { index in
                    matchesForPlan[recipe.ingredients[index].id].map { (index, $0) }
                })
            }
            if servings != recipe.servings { meal.plannedServings = servings }
            proposal = try DinnerPlanningEngine.preview(id: id, changes: [.choose(meal)], tool: accepted == nil ? .manual : .reusableDinner,
                ledger: shop, state: workspace.dinnerPlanning, access: access, phase: phase, at: now).proposal
            plannedDay = chosenDay; plannedServings = servings; preparationDay = tonight
            ingredients = chosen
            plansDinner = true
        case .groceries(let ids):
            guard pantryProducts == nil else { throw DinnerPlanningError.stalePreview }
            ingredients = recipe.ingredients.filter { ids.contains($0.id) }
            guard !ids.isEmpty, ingredients.count == ids.count else { throw DinnerPlanningError.reviewRequired("ingredients") }
            proposal = nil
            plannedDay = nil; plannedServings = nil; preparationDay = nil
            plansDinner = false
        }
        receipt = DinnerGroceryReceipt(id: id, recipeID: recipe.id, recipeRevision: recipe.revision, actor: actor,
            workspaceID: localID, plannedDay: plannedDay, occurrenceID: proposal?.changes.compactMap { change in
                if case .choose(let meal) = change { return meal.occurrenceID }; return nil
            }.first, rememberedOmissions: rememberChoices && plansDinner ? omitted.sorted { $0.uuidString < $1.uuidString } : nil,
            changes: changes)
    }

    private static func source(_ recipe: MealTemplate, workspace: LedgerWorkspace, access: DinnerAccessContext) throws -> AcceptedDinner? {
        let state = workspace.dinnerPlanning
        let matches = state.acceptedDinners.filter { $0.template == recipe }
        if let free = matches.first(where: { $0.id == state.freeReusableDinnerID }) { return free }
        if let accepted = matches.first {
            guard access.hasPaidTools else { throw DinnerPlanningError.paidAccessRequired }
            return accepted
        }
        guard workspace.mealTemplates.contains(recipe) else { throw DinnerPlanningError.stalePreview }
        guard workspace.mealTemplates.first == recipe || access.hasPaidTools else { throw DinnerPlanningError.paidAccessRequired }
        return nil
    }

    public func isApplied(in workspace: LedgerWorkspace) -> Bool {
        if plansDinner { return workspace.dinnerPlanning.applyReceipts.contains { $0.id == id && $0.proposal == proposal } }
        return workspace.shops.first(where: { $0.id == shopID })?.revisions.contains {
            $0.id == id && $0.operation == "savedDinnerGroceries"
        } == true
    }

    public func validateDestination(in workspace: LedgerWorkspace, access: DinnerAccessContext, phase: BasketPhase, at now: Date) throws {
        guard access.scope == scope, access.actorID == actor else { throw DinnerPlanningError.forbidden }
        try access.validate(shopID: shopID, at: now, applying: true)
        guard phase == .draft else { throw DinnerPlanningError.lockedBasket }
        guard let shop = workspace.shops.first(where: { $0.id == shopID }), workspace.selectedShopID == shopID,
              shop.revisionID == originalRevision, shop.title == destinationTitle,
              workspace.dinnerPlanning.revisionID == planningRevision else { throw DinnerPlanningError.stalePreview }
        try pantryProducts?.verifyNewLines(in: workspace, destinationShopID: shopID, reservedFoods: reservedFoods)
        _ = try Self.source(recipe, workspace: workspace, access: access)
        if let preparationDay, preparationDay != (try MealDay(date: now, timeZoneIdentifier: shop.basis.timeZoneIdentifier)) { throw DinnerPlanningError.stalePreview }
    }

    public func apply(to workspace: inout LedgerWorkspace, access: DinnerAccessContext, phase: BasketPhase, at now: Date) throws {
        guard access.scope == scope, access.actorID == actor else { throw DinnerPlanningError.forbidden }
        try access.validate(shopID: shopID, at: now, applying: true)
        if isApplied(in: workspace) { return }
        try validateDestination(in: workspace, access: access, phase: phase, at: now)
        guard let index = workspace.shops.firstIndex(where: { $0.id == shopID }) else { throw DinnerPlanningError.stalePreview }
        if let proposal {
            _ = try DinnerPlanningEngine.apply(proposal, ledger: &workspace.shops[index], state: &workspace.dinnerPlanning,
                access: access, phase: phase, at: now)
        } else {
            try workspace.shops[index].addSavedDinnerGroceries(ingredients, exclusions: recipe.exclusions, revisionID: id, at: now, matched: matched)
        }
        workspace.shops[index].attachDinnerReceipt(receipt)
    }
}

extension MealIngredient {
    /// Explicit source labels, never food-name guesses (wine can be a required ingredient).
    public var suggestedShoppingExtra: Bool {
        let labels = ["optional", "opcional", "optional garnish", "suggested pairing", "wine pairing", "maridaje sugerido", "guarnición opcional"]
        return [name, notes, originalWording ?? ""].contains { text in
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return labels.contains { label in
                clean == label || clean.hasPrefix(label + ":") || clean.hasPrefix(label + " –") ||
                clean.hasSuffix("(" + label + ")") || clean.hasSuffix(", " + label)
            }
        }
    }
}

public struct DinnerGroceryReceipt: Codable, Equatable, Sendable, Identifiable {
    public struct Change: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let before: Quantity?
        public let added: Quantity?
        public let after: Quantity?
    }
    public let id: UUID
    public let recipeID: UUID
    public let recipeRevision: Int
    public let actor: String
    public let workspaceID: UUID
    public let plannedDay: MealDay?
    public let occurrenceID: UUID?
    public let rememberedOmissions: [UUID]?
    public let changes: [Change]

    func validate(revision: LedgerRevision) throws {
        try plannedDay?.validate()
        let expected = occurrenceID == nil ? "savedDinnerGroceries" : "dinner:" + id.uuidString
        guard revision.operation == expected, occurrenceID != nil || id == revision.id,
              recipeRevision >= 0, !actor.isEmpty, actor.utf8.count <= 512, changes.count <= 200,
              Set(changes.map(\.id)).count == changes.count else { throw LedgerError.invalid("dinnerReceipt") }
        if let rememberedOmissions {
            guard rememberedOmissions.count <= 200, Set(rememberedOmissions).count == rememberedOmissions.count else {
                throw LedgerError.invalid("dinnerReceipt")
            }
        }
        for row in changes {
            guard !row.name.isEmpty, row.name.utf8.count <= 2048 else { throw LedgerError.invalid("dinnerReceipt") }
            if let before = row.before, let added = row.added, let after = row.after {
                try before.validate(); try added.validate(); try after.validate()
                guard before.unit == added.unit, added.unit == after.unit,
                      try before.amount.adding(added.amount) == after.amount else { throw LedgerError.invalid("dinnerReceipt") }
            } else if row.before != nil || row.added != nil || row.after != nil { throw LedgerError.invalid("dinnerReceipt") }
        }
    }
}

extension SavedDinnerReview {
    /// An explicit preview combines only a unique, open exact match. Imported packs,
    /// allocated stock, differing exclusions, and ambiguous duplicates stay separate.
    static func matches(_ ingredients: [MealIngredient], in shop: ShoppingLedger, exclusions: [String]) -> [UUID: UUID] {
        let open = Dictionary(grouping: shop.lines.filter { !$0.isChecked && !$0.isHandled && !$0.isTrashed && $0.tripPick == nil && $0.packagePick == nil }, by: \.name)
        let sources = Dictionary(grouping: shop.contributions.filter { $0.removedAt == nil }, by: \.lineID)
        let allocated = Set(shop.allocations.flatMap { [$0.demandContributionID, $0.supplyContributionID] })
        var matches: [UUID: UUID] = [:]
        for ingredient in ingredients {
            guard let quantity = ingredient.quantity else { continue }
            let candidates = (open[ingredient.name] ?? []).filter { line in
                guard line.notes == ingredient.notes, let rows = sources[line.id], !rows.isEmpty else { return false }
                return rows.allSatisfy { row in
                    switch row.source { case .manual, .meal: break; default: return false }
                    guard let existing = row.quantity, existing.unit == quantity.unit,
                          existing.confirmedConversion == quantity.confirmedConversion else { return false }
                    if quantity.unit == .count, countWording(existing, name: ingredient.name) != countWording(quantity, name: ingredient.name) {
                        return false
                    }
                    return !allocated.contains(row.id) && row.productName == ingredient.name && row.notes == ingredient.notes &&
                        row.originalPack == nil && row.capture == nil &&
                        Set(row.exclusions) == Set(exclusions + ingredient.exclusions)
                }
            }
            if candidates.count == 1 { matches[ingredient.id] = candidates[0].id }
        }
        return matches
    }
    /// A count can refer to a bunch or a box. Only group when the original measure agrees.
    private static func countWording(_ quantity: Quantity, name: String) -> String {
        let words = quantity.originalLiteral.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
        return words == name.lowercased() ? "" : words
    }

    static func amounts(_ ingredients: [MealIngredient], in shop: ShoppingLedger,
                        matched: [UUID: UUID]) throws -> [DinnerGroceryReceipt.Change] {
        var running: [UUID: Quantity] = [:]
        return try ingredients.map { item in
            guard let amount = item.quantity else {
                return .init(id: item.id, name: item.name, before: nil, added: nil, after: nil)
            }
            let line = matched[item.id]
            let before: Quantity
            if let line, let previous = running[line] { before = previous }
            else if let line, let current = try shop.quantity(forLineID: line) { before = current }
            else { before = Quantity(amount: .zero, unit: amount.unit, originalLiteral: "0") }
            let total = try before.amount.adding(amount.amount)
            let after = Quantity(amount: total, unit: amount.unit, originalLiteral: total.description)
            if let line { running[line] = after }
            return .init(id: item.id, name: item.name, before: before, added: amount, after: after)
        }
    }
}
