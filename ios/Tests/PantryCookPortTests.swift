import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryCookPortTests: XCTestCase {
    func testCookingCommitsMealAndPantryOnceAcrossReopenAndRejectsASecondCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let url = directory.appendingPathComponent("pickup.sqlite"), ledgerURL = directory.appendingPathComponent("ledger.sqlite")
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let ledger = try LedgerStore(url: ledgerURL, inventoryProjectionsEnabled: true)
        cleanup.track(store, ledger)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let count = Quantity(amount: try Rational(4), unit: .count, originalLiteral: "4")
        let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        let recipe = MealTemplate(title: "Tacos", servings: try Rational(4),
            ingredients: [.init(name: "Wraps", quantity: count), .init(name: "Salt", quantity: nil)])
        var shop = ShoppingLedger(title: "Pickup")
        let mealID = try shop.chooseMeal(recipe, at: now)
        let workspace = LedgerWorkspace(shops: [shop], mealTemplates: [recipe], selectedShopID: shop.id)
        _ = try await ledger.save(payload: JSONEncoder().encode(workspace), expectedRevision: 0, operationID: UUID(), savedAt: now)
        let lot = UUID(), operation = UUID()
        let seed = InventoryLotSeed(foodID: UUID(), name: "Wraps", source: .manual(originID: store.workspaceID, sourceID: lot),
                                    location: .cupboard, unit: .count, count: .exact(count))
        let command = InventoryCommand(id: operation, originID: store.workspaceID, lotID: lot, eventID: UUID(), expectedRevision: nil,
            occurredAt: now, change: .create(seed, observationID: UUID()))
        let writes = try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: operation, expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: store.inventorySourceToken(), writes: writes), at: now)
        let gate = PantryMutationGate()
        var allowed = true
        let port = PantryCookPort(store: store, ledger: ledger, gate: gate, authorize: { allowed }, clock: { now })
        let original = try await port.load(shopID: shop.id, mealID: mealID)
        let ids = original.meal.ingredientContributionIDs
        let unresolved = CookCompletionDraft.Part(contributionID: ids[1], use: .untracked)
        let output = CookCompletionDraft.Leftovers(name: "Taco portions", portions: try Rational(2), location: .fridge)
        let draft = CookCompletionDraft(inventoryID: store.workspaceID, inventoryRevision: original.inventory.state.revision,
            ledgerID: ledger.workspaceID, shop: shop, meal: original.meal, cookedAt: now, servingsMade: try Rational(3), parts: [
                .init(contributionID: ids[0], use: .lot(id: lot, revision: 1, amount: one)), unresolved
            ], leftovers: [output])
        let review = try await port.review(draft)
        let before = try await store.load(id: shop.id)
        XCTAssertNil(before, "Reviewing a ledger-only dinner cannot create a pickup source")
        allowed = false
        do { try await port.apply(review); XCTFail("Revoked confirmation") } catch PantryCookPort.Failure.unavailable {}
        allowed = true
        try await port.apply(review)
        // Simulate losing the first response and reopening the two actual databases.
        let reopenedStore = try ComparisonStore(url: url, inventoryEnabled: true)
        let reopenedLedger = try LedgerStore(url: ledgerURL, inventoryProjectionsEnabled: true)
        cleanup.track(reopenedStore, reopenedLedger)
        let reopened = PantryCookPort(store: reopenedStore, ledger: reopenedLedger, gate: gate, authorize: { true }, clock: { now })
        try await reopened.apply(review)
        let after = try await reopened.load(shopID: shop.id, mealID: mealID)
        XCTAssertEqual(after.completed, draft)
        XCTAssertEqual(after.completed?.unresolvedUseIDs, [unresolved.id])
        XCTAssertEqual(after.inventory.state.revision, original.inventory.state.revision + 1)
        XCTAssertEqual(after.inventory.lots.first { $0.id == lot }?.count.quantity?.amount, try Rational(3))
        XCTAssertEqual(after.inventory.lots.first { $0.id == output.id }?.count.quantity?.amount, try Rational(2))
        let saved = try await reopenedStore.load(id: shop.id)
        XCTAssertEqual(saved?.revision, 1)
        do { _ = try await reopened.review(draft); XCTFail("A cooked occurrence cannot create another output") }
        catch PantryCookPort.Failure.alreadyCompleted {}
        var altered = draft; altered.servingsMade = .one
        do { _ = try await reopened.review(altered); XCTFail("Changed replay") } catch {}
    }
}
