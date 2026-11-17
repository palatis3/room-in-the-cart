#if DEBUG && STOCK_REVIEW_UI_FIXTURE
import SwiftUI
import CoreDomain
import SQLite3

/// Holds only the fixture database; releasing this owner also releases any active transaction.
private final class StockReviewFixtureDatabaseLock {
    private var connection: OpaquePointer?
    func acquire(at url: URL) -> Bool {
        guard connection == nil else { return true }
        var opened: OpaquePointer?
        guard sqlite3_open(url.path, &opened) == SQLITE_OK else {
            if let opened { sqlite3_close(opened) }
            return false
        }
        guard sqlite3_exec(opened, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(opened)
            return false
        }
        connection = opened
        return true
    }
    func release() {
        guard let connection else { return }
        sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
        sqlite3_close(connection)
        self.connection = nil
    }
    deinit { release() }
}

/// An isolated real SQLite journey. The fixture never contacts a household or retailer.
@MainActor final class StockReviewUIFixtureState: ObservableObject {
    static let batch = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    static let food = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    let pickup: PickupModel
    let access: WorkspaceAccess
    let household: HouseholdModel
    @Published private(set) var ready = false
    @Published private(set) var failure = false
    @Published private(set) var databaseLocked = false
    @Published private(set) var lockFailed = false
    let retryControls = ProcessInfo.processInfo.arguments.contains("--stock-entry-retry-controls")
    private let databaseURL: URL
    private let databaseLock = StockReviewFixtureDatabaseLock()
    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockReviewUIFixture", isDirectory: true)
        let reset = ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--reset-stock-review-fixture")
        if reset { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "StockReviewUIFixture")!
        if reset { defaults.removePersistentDomain(forName: "StockReviewUIFixture") }
        access = WorkspaceAccess(defaults: defaults)
        household = HouseholdModel(outboxURL: directory.appendingPathComponent("unused-household.json"))
        databaseURL = directory.appendingPathComponent("pickup.sqlite")
        pickup = PickupModel(databaseURL: databaseURL)
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
    func lockDatabase() {
        guard retryControls, ready, !pickup.saving, !databaseLocked else { return }
        databaseLocked = databaseLock.acquire(at: databaseURL)
        lockFailed = !databaseLocked
    }
    func releaseDatabase() {
        databaseLock.release()
        databaseLocked = false
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
                StockReviewUIFixtureContent(pickup: fixture.pickup,
                    changeMeals: { Task { await fixture.changeMealCommitments() } },
                    retryControls: fixture.retryControls, databaseLocked: fixture.databaseLocked, lockFailed: fixture.lockFailed,
                    lockDatabase: fixture.lockDatabase, releaseDatabase: fixture.releaseDatabase)
                    .environmentObject(fixture.access).environmentObject(fixture.household)
            } else if fixture.failure { Text("Stock fixture setup failed").accessibilityIdentifier("fixture.stock.failure") }
            else { ProgressView().task { await fixture.open() } }
        }
    }
}
private struct StockReviewUIFixtureContent: View {
    @ObservedObject var pickup: PickupModel
    let changeMeals: () -> Void
    let retryControls: Bool
    let databaseLocked: Bool
    let lockFailed: Bool
    let lockDatabase: () -> Void
    let releaseDatabase: () -> Void
    @State private var completedBlockedSaves = 0
    private var lotRecords: String {
        let records = (pickup.journey?.stockLots ?? []).filter { $0.source != .manual }.map {
            ["id": $0.id.uuidString, "name": $0.name, "amount": $0.usable.amount.description, "unit": $0.usable.unit.rawValue]
        }.sorted { $0["id", default: ""] < $1["id", default: ""] }
        guard let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "invalid" }
        return text
    }
    var body: some View {
        VStack(spacing: 2) {
            Text("Saved batch units: \(pickup.journey?.stockLots.first { $0.id == StockReviewUIFixtureState.batch }?.usable.amount.description ?? "unknown")")
                .accessibilityIdentifier("fixture.stock.savedUnits")
            Text("Saved revision: \(pickup.journey?.revision ?? -1)").accessibilityIdentifier("fixture.stock.revision")
            Text("Dinner shortfall: \(pickup.allocation?.demands.first { $0.id == StockReviewUIFixtureState.food }?.shortfall?.description ?? "unknown")")
                .accessibilityIdentifier("fixture.stock.shortfall")
            Button("Change meal commitments", action: changeMeals).accessibilityIdentifier("fixture.stock.changeMeals")
            if retryControls {
                HStack {
                    Button("Lock fixture database", action: lockDatabase)
                        .disabled(databaseLocked || pickup.saving).accessibilityIdentifier("fixture.stock.lock")
                    Button("Release fixture database", action: releaseDatabase)
                        .disabled(!databaseLocked).accessibilityIdentifier("fixture.stock.release")
                }
                Text("Database lock: \(databaseLocked ? "held" : "released") · Pending: \(pickup.hasPendingSave ? "yes" : "no") · Saving: \(pickup.saving ? "yes" : "no")")
                    .font(.caption).accessibilityIdentifier("fixture.stock.writeState")
                Text("Blocked saves completed: \(completedBlockedSaves)").font(.caption)
                    .accessibilityIdentifier("fixture.stock.blockedSaveCount")
                Text(lotRecords).font(.caption2).lineLimit(1).accessibilityLabel(lotRecords)
                    .accessibilityIdentifier("fixture.stock.lotRecords")
                if lockFailed { Text("Fixture database lock failed").accessibilityIdentifier("fixture.stock.lockFailure") }
            }
            NavigationStack {
                Form {
                    if retryControls {
                        NavigationLink("Enter a separate stock batch") {
                            PickupStockEntryView(model: pickup, title: "Confirm pantry or freezer food")
                        }.accessibilityIdentifier("fixture.stock.newBatch")
                    }
                    if let journey = pickup.journey { PickupSavedStockSection(model: pickup, journey: journey) }
                    NavigationLink("Tell the cook") { PickupCookView(model: pickup) }.accessibilityIdentifier("fixture.stock.cook")
                }.navigationTitle("Stock review fixture")
            }
        }
        .onChange(of: pickup.saving) { wasSaving, isSaving in
            // The real SQLite busy timeout spans render passes. Count completion,
            // not a button tap or a pending state left over from an earlier attempt.
            if retryControls, databaseLocked, wasSaving, !isSaving, pickup.hasPendingSave {
                completedBlockedSaves += 1
            }
        }
    }
}
#endif
