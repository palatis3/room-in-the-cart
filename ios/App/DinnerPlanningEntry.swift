import SwiftUI
import CoreDomain
import Combine

/// The local ledger remains private even while an account is signed in. Restored
/// planning documents never supply the installation actor, permission or paid seat.
struct DinnerPlanningEntry: View {
    let destination: ContextualDinnerDestination?
    @State private var expectedShopID: UUID?
    init(destination: ContextualDinnerDestination? = nil, expectedShopID: UUID? = nil) {
        self.destination = destination; _expectedShopID = State(initialValue: expectedShopID)
    }
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var membership: MembershipCoordinator

    var body: some View {
        Group {
            if let expectedShopID, ledger.shop?.id != expectedShopID {
                ContentUnavailableView(dinnerText("Pickup selection changed"), systemImage: "arrow.triangle.2.circlepath",
                    description: Text(dinnerText("Return to the original pickup before reviewing these dinner choices or store quotes.")))
            } else if destination == nil, household.canOpenSharedDinnerPlanning,
                      household.projection?.role != "shopper" {
                DinnerSharedPlanningEntry(household: household)
            } else if let destination {
                ContextualDinnerFeature(ledger: ledger, destination: destination, access: localAccess, phase: phase,
                    runtimeChanges: runtimeChanges)
            } else {
                DinnerPlanningHome(ledger: ledger, access: localAccess, phase: phase, ideaCatalog: DinnerPatternCatalog.patterns,
                    runtimeChanges: runtimeChanges)
            }
        }
        .environment(\.dinnerHousehold, household)
        .toolbar {
            if household.canOpenSharedDinnerPlanning {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(ht("Shared meal plan")) { DinnerSharedPlanningEntry(household: household) }
                        .accessibilityIdentifier("dinner.sharedPlan")
                }
            }
        }
        .task { await pickup.load() }
    }
    private var runtimeChanges: AnyPublisher<Void, Never> {
        Publishers.Merge4(access.objectWillChange, pickup.objectWillChange,
            household.objectWillChange, membership.objectWillChange).eraseToAnyPublisher()
    }

    private func localAccess(for shopID: UUID) -> DinnerAccessContext? {
        guard expectedShopID == nil || expectedShopID == shopID,
              access.unlocked, !household.locked, ledger.ready, pickup.ready,
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
