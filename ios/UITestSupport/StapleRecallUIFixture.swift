#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE && targetEnvironment(simulator)
import CoreDomain
import SwiftUI

struct StapleRecallUIFixture: View {
    @StateObject private var ledger = LedgerModel()
    @StateObject private var pickup = PickupModel()
    @StateObject private var access = WorkspaceAccess()
    @StateObject private var membership = S17FixtureState.recoveryMembership()
    @State private var household: HouseholdModel?
    @State private var failed = false

    var body: some View {
        Group {
            if failed { Text(verbatim: "Staple fixture unavailable") }
            else if let household, membership.model?.hasPaidAccess == true {
                NavigationStack { LedgerHomeView(model: ledger) }
                    .environmentObject(household).environmentObject(membership)
                    .environmentObject(pickup).environmentObject(access)
            } else { ProgressView() }
        }.task {
            guard household == nil else { return }
            do {
                let shopper = try await S17FixtureState.recoveryShopper()
                await ledger.open(); await pickup.load()
                if ledger.workspace.shops.isEmpty {
                    let saved = await ledger.change(key: "prior-staples") { workspace in
                        let past = Date().addingTimeInterval(-32 * 86400)
                        var market = ShoppingLedger(title: "Previous market", basis: .init(branch: "North market"))
                        let coffee = try market.addManualLine(name: "Coffee", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"), at: past)
                        try market.approveStaple(lineID: coffee, purpose: "School lunches", at: past)
                        try market.setChecked(lineID: coffee, checked: true, at: past)
                        let soap = try market.addManualLine(name: "Soap", quantity: nil, at: past)
                        try market.approveStaple(lineID: soap, purpose: "Cleaning", at: past)
                        var west = ShoppingLedger(title: "Previous west store", basis: .init(branch: "West store"))
                        let tea = try west.addManualLine(name: "Tea", quantity: nil, at: past)
                        try west.approveStaple(lineID: tea, purpose: "School lunches", at: past)
                        var current = ShoppingLedger(title: "This trip", basis: .init(branch: "North market"))
                        try current.addManualLine(name: "Coffee", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"), notes: "Office")
                        try current.addManualLine(name: "Coffee", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"), notes: "School lunches")
                        workspace.shops = [market,west,current]
                        workspace.selectedShopID = current.id
                    }
                    guard saved else { failed = true; return }
                }
                membership.bind(to: shopper)
                household = shopper
            } catch { failed = true }
        }
    }
}
#endif
