#if DEBUG && STOCK_REVIEW_UI_FIXTURE
import SwiftUI
import CoreDomain

/// An isolated real SQLite journey. The fixture never contacts a household or retailer.
@MainActor final class StockReviewUIFixtureState: ObservableObject {
    static let batch = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    static let food = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    let pickup: PickupModel
    let access: WorkspaceAccess
    let household: HouseholdModel
    @Published private(set) var ready = false
    @Published private(set) var failure = false
    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockReviewUIFixture", isDirectory: true)
        let reset = ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--reset-stock-review-fixture")
        if reset { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "StockReviewUIFixture")!
        if reset { defaults.removePersistentDomain(forName: "StockReviewUIFixture") }
        access = WorkspaceAccess(defaults: defaults)
        household = HouseholdModel(outboxURL: directory.appendingPathComponent("unused-household.json"))
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
    }
    func open() async {
        guard !ready, !failure else { return }
        await pickup.load()
        do {
            guard pickup.ready else { throw PickupStockReviewError.invalid }
            if pickup.journeys.isEmpty {
                let now = Date()
                func quantity(_ n: Int64) throws -> Quantity { .init(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
                guard await pickup.addUrgent(.init(id: Self.food, food: "Wraps", meal: "Dinner", required: try quantity(4),
                    available: try quantity(0), due: nil, confirmedAt: now)), let shopID = pickup.journey?.id else { throw PickupStockReviewError.invalid }
                guard await pickup.change({
                    $0.stockNeeds.append(.init(id: UUID(), foodID: Self.food, name: "Protected lunch", amount: try quantity(2), priority: .protected))
                }), await pickup.saveStockLot(.init(id: Self.batch, foodID: Self.food, name: "Freezer wraps", usable: try quantity(5),
                    confirmedAt: now, source: .freezer), in: shopID) else { throw PickupStockReviewError.invalid }
            }
            ready = true
        } catch { failure = true }
    }
    func changeMealCommitments() async {
        _ = await pickup.change {
            $0.stockNeeds.append(.init(id: UUID(), foodID: Self.food, name: "New dinner commitment",
                amount: Quantity(amount: .one, unit: .count, originalLiteral: "1"), priority: .required))
        }
    }
}

struct StockReviewUIFixtureRoot: View {
    @StateObject private var fixture = StockReviewUIFixtureState()
    var body: some View {
        Group {
            if fixture.ready {
                StockReviewUIFixtureContent(pickup: fixture.pickup, changeMeals: { Task { await fixture.changeMealCommitments() } })
                    .environmentObject(fixture.access).environmentObject(fixture.household)
            } else if fixture.failure { Text("Stock fixture setup failed").accessibilityIdentifier("fixture.stock.failure") }
            else { ProgressView().task { await fixture.open() } }
        }
    }
}
private struct StockReviewUIFixtureContent: View {
    @ObservedObject var pickup: PickupModel
    let changeMeals: () -> Void
    var body: some View {
        VStack(spacing: 2) {
            Text("Saved batch units: \(pickup.journey?.stockLots.first { $0.id == StockReviewUIFixtureState.batch }?.usable.amount.description ?? "unknown")")
                .accessibilityIdentifier("fixture.stock.savedUnits")
            Text("Saved revision: \(pickup.journey?.revision ?? -1)").accessibilityIdentifier("fixture.stock.revision")
            Text("Dinner shortfall: \(pickup.allocation?.demands.first { $0.id == StockReviewUIFixtureState.food }?.shortfall?.description ?? "unknown")")
                .accessibilityIdentifier("fixture.stock.shortfall")
            Button("Change meal commitments", action: changeMeals).accessibilityIdentifier("fixture.stock.changeMeals")
            NavigationStack {
                Form {
                    if let journey = pickup.journey { PickupSavedStockSection(model: pickup, journey: journey) }
                    NavigationLink("Tell the cook") { PickupCookView(model: pickup) }.accessibilityIdentifier("fixture.stock.cook")
                }.navigationTitle("Stock review fixture")
            }
        }
    }
}
#endif
