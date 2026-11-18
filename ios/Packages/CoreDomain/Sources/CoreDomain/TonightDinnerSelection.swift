import Foundation

/// The destination for a new pickup exists only in this preview until the meal and
/// its ledger receipt can be committed together.
public struct TonightDinnerSelection: Equatable, Sendable {
    public let preview: DinnerPreview
    public let recipe: MealTemplate
    public let destinationTitle: String
    public var createsPickup: Bool { newPickup != nil }
    private let newPickup: ShoppingLedger?
    private let originalSelection: UUID?
    private let day: MealDay

    public static func prepare(match: PantryMealMatcher.Review, destination: ShoppingLedger, createsPickup: Bool,
                               workspace: LedgerWorkspace, access: DinnerAccessContext,
                               phase: BasketPhase, now: Date) throws -> Self {
        guard case .local = access.scope else { throw DinnerPlanningError.forbidden }
        guard match.eligibility.eligible, match.hasConfirmedPantryFood else { throw DinnerPlanningError.reviewRequired("tonightSupply") }
        try access.validate(shopID: destination.id, at: now, applying: true)
        guard phase == .draft else { throw DinnerPlanningError.lockedBasket }
        let stored = workspace.shops.first { $0.id == destination.id }
        guard createsPickup ? (stored == nil && destination.revisions.isEmpty && workspace.shops.count < 100)
                            : stored == destination else { throw DinnerPlanningError.stalePreview }
        guard match.preferenceRevision == workspace.dinnerPlanning.privateMealPreferences?.revision,
              contains(match.recipe, in: workspace) else { throw DinnerPlanningError.stalePreview }
        let day = try MealDay(date: now, timeZoneIdentifier: destination.basis.timeZoneIdentifier)
        let meal = PlannedDinner(template: match.recipe, day: day)
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(meal)], tool: .manual, ledger: destination,
            state: workspace.dinnerPlanning, access: access, phase: phase, at: now)
        return Self(preview: preview, recipe: match.recipe, destinationTitle: destination.title,
                    newPickup: createsPickup ? destination : nil, originalSelection: workspace.selectedShopID, day: day)
    }

    private static func contains(_ recipe: MealTemplate, in workspace: LedgerWorkspace) -> Bool {
        workspace.mealTemplates.contains(recipe) || workspace.dinnerPlanning.acceptedDinners.contains { $0.template == recipe }
    }

    public func apply(to workspace: inout LedgerWorkspace, access: DinnerAccessContext,
                      phase: BasketPhase, now: Date) throws {
        let proposal = preview.proposal
        guard case .local = access.scope, proposal.authorID == access.actorID else { throw DinnerPlanningError.forbidden }
        try access.validate(shopID: proposal.shopID, at: now, applying: true)
        let index = workspace.shops.firstIndex { $0.id == proposal.shopID }
        let replay = workspace.dinnerPlanning.applyReceipts.contains { $0.id == proposal.id }
        if !replay {
            guard workspace.selectedShopID == originalSelection,
                  Self.contains(recipe, in: workspace),
                  (newPickup != nil ? index == nil : index != nil),
                  day == (try MealDay(date: now, timeZoneIdentifier: day.timeZoneIdentifier))
            else { throw DinnerPlanningError.stalePreview }
        }
        guard var destination = index.map({ workspace.shops[$0] }) ?? newPickup else { throw DinnerPlanningError.stalePreview }
        var state = workspace.dinnerPlanning
        _ = try DinnerPlanningEngine.apply(proposal, ledger: &destination, state: &state, access: access, phase: phase, at: now)
        if replay { return }
        if let index { workspace.shops[index] = destination }
        else {
            guard workspace.shops.count < 100 else { throw DinnerPlanningError.invalid("workspaceSize") }
            workspace.shops.append(destination)
        }
        workspace.selectedShopID = destination.id
        workspace.dinnerPlanning = state
    }
}
