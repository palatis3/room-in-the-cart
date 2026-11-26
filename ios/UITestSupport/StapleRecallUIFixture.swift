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
                        if ProcessInfo.processInfo.arguments.contains("--long-current-stop-fixture") {
                            current = ShoppingLedger(title: "This trip", basis: .init(branch: "North market", mode: .inStore, currency: .mxn))
                            for index in 1...40 {
                                try current.addManualLine(name: String(format: "Pasillo %02d", index), quantity: nil)
                            }
                            let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
                            try current.addManualLine(name: "Café", quantity: one, notes: "Molido")
                            try current.addManualLine(name: "Café", quantity: one, notes: "En grano")
                            let other = try current.addManualLine(name: "Café para otra tienda", quantity: one)
                            try current.setPreferredStores(["West store"], lineID: other, expectedRevision: current.revisionID)
                        } else if ProcessInfo.processInfo.arguments.contains("--package-row-photo-fixture") {
                            try current.addManualLine(name: "Coffee", quantity: nil)
                        } else if ProcessInfo.processInfo.arguments.contains("--trip-reminders-fixture") {
                            try current.addManualLine(name: "Agua", quantity: nil)
                        } else if ProcessInfo.processInfo.arguments.contains("--shelf-budget-fixture") {
                            current = ShoppingLedger(title: "This trip", basis: .init(branch: "North market", mode: .inStore))
                            for (label, count) in [("Apples", 4), ("Coffee", 1), ("Bread", 1)] {
                                let unit = Quantity(amount: try Rational(Int64(count)), unit: .count, originalLiteral: String(count))
                                try current.addManualLine(name: label, quantity: unit)
                            }
                        } else {
                            try current.addManualLine(name: "Coffee", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"), notes: "Office")
                            try current.addManualLine(name: "Coffee", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"), notes: "School lunches")
                        }
                        workspace.shops = [market,west,current]
                        workspace.selectedShopID = current.id
                    }
                    guard saved else { failed = true; return }
                }
                if ProcessInfo.processInfo.arguments.contains("--package-row-photo-fixture"),
                   let workspace = ledger.sourceWorkspaceID, let shop = ledger.shop,
                   let line = shop.lines.first(where: { $0.name == "Coffee" }) {
                    let target = CaptureTarget(workspaceID: workspace, containerID: shop.id, objectID: line.id,
                                               revision: Int64(shop.revision), kind: .packageReference)
                    let bytes = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 100)).jpegData(withCompressionQuality: 0.8) {
                        UIColor.systemBlue.setFill()
                        $0.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
                    }
                    let source = SourceMediaRecord(id: UUID(), target: target, originalText: "COFFEE", reviewedLabel: "Coffee tin",
                                                   imageJPEG: bytes, barcode: nil, receiptLines: [], capturedAt: Date())
                    _ = try await CaptureMediaStore.shared.save(source, authorize: { ledger.sourceWorkspaceID == workspace })
                }
                membership.bind(to: shopper)
                household = shopper
            } catch { failed = true }
        }
    }
}
#endif
