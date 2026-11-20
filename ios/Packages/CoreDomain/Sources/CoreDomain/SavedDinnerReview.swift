import Foundation

/// A private recipe can be used for a whole meal or as a source for individual
/// shopping lines. Only choosing the whole meal creates meal demand.
public struct SavedDinnerReview: Identifiable, Sendable {
    public enum Action: Sendable {
        case planTonight
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
    private let day: MealDay?

    public init(recipe: MealTemplate, action: Action, workspace: LedgerWorkspace,
                access: DinnerAccessContext, phase: BasketPhase, at now: Date) throws {
        guard case .local = access.scope, let shop = workspace.shops.first(where: { $0.id == workspace.selectedShopID })
        else { throw DinnerPlanningError.forbidden }
        try access.validate(shopID: shop.id, at: now, applying: true)
        guard phase == .draft else { throw DinnerPlanningError.lockedBasket }
        let accepted = try Self.source(recipe, workspace: workspace, access: access)
        self.recipe = recipe
        shopID = shop.id
        destinationTitle = shop.title
        scope = access.scope
        actor = access.actorID
        originalRevision = shop.revisionID
        planningRevision = workspace.dinnerPlanning.revisionID
        id = UUID()
        switch action {
        case .planTonight:
            let tonight = try MealDay(date: now, timeZoneIdentifier: shop.basis.timeZoneIdentifier)
            let meal = PlannedDinner(acceptedDinnerID: accepted?.id, template: recipe, day: tonight)
            proposal = try DinnerPlanningEngine.preview(id: id, changes: [.choose(meal)], tool: accepted == nil ? .manual : .reusableDinner,
                ledger: shop, state: workspace.dinnerPlanning, access: access, phase: phase, at: now).proposal
            day = tonight
            ingredients = recipe.ingredients
            plansDinner = true
        case .groceries(let ids):
            ingredients = recipe.ingredients.filter { ids.contains($0.id) }
            guard !ids.isEmpty, ingredients.count == ids.count else { throw DinnerPlanningError.reviewRequired("ingredients") }
            proposal = nil
            day = nil
            plansDinner = false
        }
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
        _ = try Self.source(recipe, workspace: workspace, access: access)
        if let day, day != (try MealDay(date: now, timeZoneIdentifier: shop.basis.timeZoneIdentifier)) { throw DinnerPlanningError.stalePreview }
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
            try workspace.shops[index].addSavedDinnerGroceries(ingredients, exclusions: recipe.exclusions, revisionID: id, at: now)
        }
    }
}
