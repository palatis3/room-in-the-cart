#if DEBUG && AWAY_CARRYOVER_UI_FIXTURE
import SwiftUI
import CoreDomain

/// Dedicated offline build only. Normal binaries have no fixture bootstrap.
@MainActor final class AwayCarryoverUIFixtureState: ObservableObject {
    let ledger: LedgerModel
    let pickup: PickupModel
    @Published private(set) var dinner: DinnerFeatureModel?
    @Published private(set) var sourceMealID: UUID?
    @Published private(set) var failure = false
    private let directory: URL
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhysicalCarryoverUIFixture", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--reset-away-carryover-fixture") {
            try? FileManager.default.removeItem(at: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
    }
    func open() async {
        guard dinner == nil, !failure else { return }
        await ledger.open(); await pickup.load()
        do {
            guard ledger.ready, pickup.ready else { throw AwayCarryoverError.invalid }
            if ledger.workspace.shops.isEmpty {
                let now = Date()
                func q(_ n: Int64) throws -> Quantity { Quantity(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
                var shop = ShoppingLedger(title: "Away-night pickup", basis: ShopBasis(branch: "Fixture branch", timeZoneIdentifier: "America/New_York"))
                let template = MealTemplate(title: "Away-night wraps", servings: try Rational(2), ingredients: [MealIngredient(name: "Wraps", quantity: try q(4))])
                let mealID = try shop.chooseMeal(template, on: now.addingTimeInterval(-86400), at: now.addingTimeInterval(-86400))
                let meal = shop.mealOccurrences[0], sourceID = meal.ingredientContributionIDs[0]
                guard let contribution = shop.contributions.first(where: { $0.id == sourceID }) else { throw AwayCarryoverError.invalid }
                let lunchID = try shop.addProtectedNeed(name: "Wraps", quantity: q(2), purpose: "Protected lunch", at: now)
                guard await ledger.change(key: "away-fixture-initial", { $0 = LedgerWorkspace(shops: [shop], selectedShopID: shop.id) }) else { throw AwayCarryoverError.invalid }
                let context = CheckoutContext(storeID: "Fixture", branchID: "Fixture branch", mode: .pickup, slot: "Evening", commitmentsID: shop.id, observedAt: now, source: "Reviewed fixture checkout")
                let needs = [AllocationNeed(id: sourceID, orderLineID: contribution.lineID, name: "Dinner wraps", amount: try q(4), priority: .required),
                             AllocationNeed(id: lunchID, orderLineID: contribution.lineID, name: "Protected lunch", amount: try q(2), priority: .protected)]
                let details = [PickupNeedDetail(id: sourceID, mealName: meal.title, exclusions: [], scheduledDay: meal.scheduledDay, leadTimeMinutes: nil, completedSteps: [], sourceContributionID: sourceID),
                               PickupNeedDetail(id: lunchID, mealName: "Protected lunch", exclusions: [], scheduledDay: meal.scheduledDay, leadTimeMinutes: nil, completedSteps: [])]
                guard await pickup.start(from: [BasketLine(id: contribution.lineID, name: "Wraps", quantity: try q(6), expectedCost: .exact(Money(minorUnits: 700)))], shopID: shop.id, context: context,
                    plannedNeeds: needs, ledgerBasis: shop.basis, ledgerSourceRevisionID: shop.revisionID, needDetails: details) else { throw AwayCarryoverError.invalid }
                guard await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 700)))), cap: nil),
                      await pickup.freeze(), await pickup.reportPlaced() else { throw AwayCarryoverError.invalid }
                let key = ReceiptKey(sourceEventID: "actual-bag", orderLineID: contribution.lineID, branchID: "Fixture branch", segmentID: "one")
                guard await pickup.receive(ReceiptFragment(key: key, itemName: "Wraps", received: try q(6), disposition: .received, receivedAt: now), usable: nil),
                      await pickup.settle(SettlementEntry(id: UUID(), evidenceKey: "actual-charge", kind: .postedCharge, amount: Money(minorUnits: 700), occurredAt: now)),
                      await pickup.saveStockLot(ConfirmedStockLot(id: UUID(), foodID: contribution.lineID, name: "Counted freezer wraps", usable: try q(6), confirmedAt: now, source: .freezer), in: shop.id)
                else { throw AwayCarryoverError.invalid }
                sourceMealID = mealID
            } else {
                guard let shop = ledger.shop, pickup.journeys.contains(where: { $0.id == shop.id && $0.pickup != nil }),
                      let meal = shop.mealOccurrences.first(where: { $0.carryover == nil }) else { throw AwayCarryoverError.invalid }
                sourceMealID = meal.id; pickup.selectedID = shop.id
            }
            let localLedger = ledger
            let feature = DinnerFeatureModel(store: ledger, access: { id in
                guard let workspaceID = localLedger.sourceWorkspaceID else { return nil }
                let now = Date()
                return DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "fixture-local", shopID: id,
                    assignedShopperID: "fixture-local", canPlan: true, canReadBudget: true, hasPaidTools: false,
                    roleRevision: 0, verifiedAt: now.addingTimeInterval(-1), validUntil: now.addingTimeInterval(60))
            }, phase: { _ in .reportedPlaced })
            feature.observe(ledger.objectWillChange); dinner = feature
        } catch { failure = true }
    }
}

struct AwayCarryoverUIFixtureRoot: View {
    @StateObject private var fixture = AwayCarryoverUIFixtureState()
    var body: some View {
        Group {
            if let dinner = fixture.dinner, let mealID = fixture.sourceMealID {
                AwayCarryoverUIFixtureContent(dinner: dinner, ledger: fixture.ledger, pickup: fixture.pickup, mealID: mealID)
                    .environmentObject(fixture.pickup)
            } else if fixture.failure { Text("Carryover fixture setup failed").accessibilityIdentifier("fixture.away.failure") }
            else { ProgressView().task { await fixture.open() } }
        }
    }
}
private struct AwayCarryoverUIFixtureContent: View {
    @ObservedObject var dinner: DinnerFeatureModel
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    let mealID: UUID
    var body: some View {
        VStack(spacing: 0) {
            Text("Carryover targets: \(ledger.shop?.mealOccurrences.filter { $0.carryover != nil }.count ?? 0)").accessibilityIdentifier("fixture.away.targets")
            Text("Physical lots: \(pickup.journey?.stockLots.count ?? 0)").accessibilityIdentifier("fixture.away.lots")
            Text("Original receipts: \(pickup.journey?.pickup?.receipts.count ?? 0)").accessibilityIdentifier("fixture.away.receipts")
            Text("Posted charge cents: \(pickup.journey?.settlement.entries.filter { $0.kind == .postedCharge }.reduce(Int64(0)) { $0 + $1.amount.minorUnits } ?? 0)").accessibilityIdentifier("fixture.away.charge")
            NavigationStack {
                DinnerAwayCarryoverView(dinner: dinner, pickup: pickup, occurrenceID: mealID)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink("Actual meal week") {
                                DinnerWorkspaceView(model: dinner, startPickup: {}) { LedgerSaveStatus(model: ledger) }
                            }.accessibilityIdentifier("fixture.away.week")
                        }
                    }
            }
        }
    }
}
#endif
