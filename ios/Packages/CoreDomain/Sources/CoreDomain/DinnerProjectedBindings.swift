import Foundation

extension DinnerPreview {
    /// Mirrors the binding changes that applying this exact preview would make, without applying it.
    /// Exposes only reviewed ingredient/group evidence, never the private projected ledger or budget.
    public func reviewedPortionBindings(from state: DinnerPlanningState) throws -> [DinnerPortionBinding] {
        guard proposal.planningRevisionID == state.revisionID else { throw DinnerPlanningError.reviewRequired("planningRevision") }
        var projected = state
        try projected.applied(.init(proposal: proposal, appliedBy: proposal.authorID,
            appliedAt: proposal.createdAt, revisionID: proposal.proposedRevisionID))
        return projected.portionBindings
    }
}
