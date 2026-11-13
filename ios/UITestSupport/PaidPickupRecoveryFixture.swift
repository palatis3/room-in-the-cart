#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE && targetEnvironment(simulator)
import CoreDomain
import SwiftUI

/// The household and entitlement HTTP traffic use one enrolled fixture shopper.
struct PaidPickupRecoveryFixtureRoot: View {
    @StateObject private var membership = S17FixtureState.recoveryMembership()
    @StateObject private var source = PrivatePickupRecoveryFixture()
    @StateObject private var ledger = LedgerModel()
    @StateObject private var pickup = PickupModel()
    @StateObject private var access = WorkspaceAccess()
    @State private var household: HouseholdModel?
    @State private var ready = false
    @State private var failed = false

    var body: some View {
        Group {
            if failed || membership.failure { Text(verbatim: "Paid recovery fixture setup failed") }
            else if ready, let household, let shop = ledger.shop {
                NavigationStack {
                    List {
                        NavigationLink(pTr("Repair a meal")) {
                            PickupMealRecoveryEntry(model: pickup, ledger: ledger, pickupID: shop.id)
                        }
                        NavigationLink(pTr("Tell the cook")) { PickupCookView(model: pickup) }
                    }
                }
                .environmentObject(household).environmentObject(access).environmentObject(membership)
            } else { ProgressView() }
        }
        .task {
            guard household == nil else { return }
            do {
                let shopper = try await S17FixtureState.recoveryShopper()
                guard shopper.membershipSession != nil else { throw MembershipFailure.signInRequired }
                await ledger.open()
                await pickup.load()
                pickup.bindCookLedger(ledger)
                await source.prepare(ledger: ledger, pickup: pickup)
                household = shopper
                membership.bind(to: shopper)
            } catch { failed = true }
        }
        .task(id: membership.model?.state.snapshot) {
            guard !ready, let snapshot = membership.model?.state.snapshot, let session = household?.membershipSession,
                  let shop = ledger.shop, let workspace = ledger.sourceWorkspaceID else { return }
            if source.requested {
                guard source.phase == .ready, membership.model?.hasPaidAccess == true else { failed = true; return }
                let now = Date()
                let authority = DinnerAccessContext(scope: .local(workspaceID: workspace), actorID: session.memberID,
                    shopID: shop.id, assignedShopperID: session.memberID, canPlan: true, canReadBudget: true,
                    hasPaidTools: true, roleRevision: snapshot.revision, verifiedAt: snapshot.verifiedAt, validUntil: snapshot.validUntil)
                let recipe = MealTemplate(title: "Accepted bean stew", servings: .one,
                    ingredients: [.init(name: "Beans", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"),
                        notes: "Rinse the beans", exclusions: ["sesame"])], notes: "Simmer in a covered pot",
                    exclusions: ["peanut"], leadTimeMinutes: 20)
                guard await ledger.change(key: "fixture-accept-bean-stew", { value in
                    try value.dinnerPlanning.accept(.init(id: UUID(), template: recipe, acceptedAt: now, acceptedFallback: true),
                        access: authority, at: now)
                }) else { failed = true; return }
            }
            ready = true
        }
    }
}
#endif
