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
        struct LedgerDocument: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
        let payload = try JSONEncoder().encode(LedgerDocument(workspace: workspace))
        _ = try await ledger.save(payload: payload, expectedRevision: 0, operationID: UUID(), savedAt: now)
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
        let committedSource = try await store.load(id: shop.id)
        let source = try JSONDecoder().decode(PickupJourney.self, from: XCTUnwrap(committedSource?.payload))
        XCTAssertEqual(source.cookedMeals?.map(\.draft), [draft], "The physical changes and their cooking receipt must survive the same save")
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

        let undo = try await reopened.reviewUndo(shopID: shop.id, mealID: mealID)
        XCTAssertEqual(undo.restoredInputs.map(\.count), [.exact(count)])
        XCTAssertEqual(undo.removedLeftovers, [output.name])
        let lunchID = UUID()
        func changeLunch(revision: Int64, state: InventoryReservationState) async throws {
            let lunch = InventoryReservation(id: lunchID, originID: reopenedStore.workspaceID, revision: revision,
                foodID: output.foodID, lotID: output.id, name: "Tomorrow’s lunch", amount: one, priority: .protected, state: state)
            let snapshot = try await reopenedStore.inventoryState()
            let write = try PantryPersistenceCodec.write(lunch, expectedRevision: revision - 1)
            _ = try await reopenedStore.commitInventory(.init(workspaceID: reopenedStore.workspaceID, operationID: UUID(),
                expectedRevision: snapshot.revision, request: Data([UInt8(revision)]), writes: [write]), at: now)
        }
        try await changeLunch(revision: 1, state: .active)
        do { try await reopened.applyUndo(undo); XCTFail("Lunch was reserved after the preview") }
        catch PantryCookPort.Failure.changed {}
        do { _ = try await reopened.reviewUndo(shopID: shop.id, mealID: mealID); XCTFail("A new preview must protect lunch too") }
        catch PantryCookPort.Failure.changed {}
        try await changeLunch(revision: 2, state: .released)
        let released = try await reopened.reviewUndo(shopID: shop.id, mealID: mealID)
        allowed = false
        do { try await port.applyUndo(released); XCTFail("Revoked Undo") } catch PantryCookPort.Failure.unavailable {}
        allowed = true
        try await reopened.applyUndo(released)
        try await port.applyUndo(released)
        try await reopened.apply(review) // Redelivery of the original cook cannot resurrect its effects.
        let undone = try await port.load(shopID: shop.id, mealID: mealID)
        XCTAssertNil(undone.completed)
        XCTAssertEqual(undone.inventory.state.revision, released.inventoryRevision + 1)
        XCTAssertEqual(undone.inventory.lots.first { $0.id == lot }?.count, .exact(count))
        XCTAssertEqual(undone.inventory.lots.first { $0.id == output.id }?.count.quantity?.amount, .zero)
        let savedUndo = try await store.load(id: shop.id)
        let storedJourney = try JSONDecoder().decode(PickupJourney.self, from: XCTUnwrap(savedUndo?.payload))
        XCTAssertEqual(storedJourney.cookedMeals?.first?.undo?.id, released.id)

        let newOutput = CookCompletionDraft.Leftovers(name: "Fresh portions", portions: .one, location: .fridge)
        let corrected = CookCompletionDraft(inventoryID: store.workspaceID, inventoryRevision: undone.inventory.state.revision,
            ledgerID: ledger.workspaceID, shop: shop, meal: undone.meal, cookedAt: now, servingsMade: .one,
            parts: ids.map { .init(contributionID: $0, use: .notUsed) }, leftovers: [newOutput])
        try await port.apply(port.review(corrected))
        let fresh = try await port.load(shopID: shop.id, mealID: mealID)
        XCTAssertEqual(fresh.completed, corrected)
        let consume = InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: newOutput.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: now, change: .usedUp(observationID: UUID()))
        let consumed = try InventoryEngine.prepare(consume, current: fresh.inventory.lots.first { $0.id == newOutput.id }, at: now)
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: consume.id,
            expectedRevision: fresh.inventory.state.revision, request: Data([9]), writes: PantryPersistenceCodec.writes(consumed)), at: now)
        do { _ = try await port.reviewUndo(shopID: shop.id, mealID: mealID); XCTFail("A later use of the output must survive") }
        catch PantryCookPort.Failure.changed {}
    }
}
