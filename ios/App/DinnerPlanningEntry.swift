import SwiftUI
import CoreDomain
import Combine

/// The local ledger remains private even while an account is signed in. Restored
/// planning documents never supply the installation actor, permission or paid seat.
struct DinnerPlanningEntry: View {
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var membership: MembershipCoordinator

    var body: some View {
        DinnerPlanningHome(ledger: ledger, access: localAccess, phase: phase, ideaCatalog: DinnerPatternCatalog.patterns,
            runtimeChanges: Publishers.Merge4(access.objectWillChange, pickup.objectWillChange,
                household.objectWillChange, membership.objectWillChange).eraseToAnyPublisher())
            .task { await pickup.load() }
    }

    private func localAccess(for shopID: UUID) -> DinnerAccessContext? {
        guard access.unlocked, !household.locked, ledger.ready, pickup.ready,
              !pickup.saving, !pickup.hasPendingSave,
              let workspaceID = ledger.sourceWorkspaceID,
              ledger.workspace.shops.contains(where: { $0.id == shopID }) else { return nil }
        if let role = household.projection?.role, !["shopper", "organizer"].contains(role) { return nil }
        let actorID = access.localActorID.uuidString
        let now = Date()
        return DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: actorID,
            shopID: shopID, assignedShopperID: actorID, canPlan: true, canReadBudget: true,
            hasPaidTools: membership.model?.hasPaidAccess == true,
            roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(30),
            sharedCommitAuthorized: false)
    }

    private func phase(for shopID: UUID) -> BasketPhase {
        guard pickup.ready, !pickup.saving, !pickup.hasPendingSave else { return .frozen }
        return pickup.journeys.first(where: { $0.id == shopID })?.basket?.phase ?? .draft
    }
}
