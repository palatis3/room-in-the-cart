import CoreDomain
import LocalStore
import XCTest
@testable import RoomInTheCart

@MainActor final class PantryCookResolutionTests: XCTestCase {
    @MainActor private final class Fixture {
        let pickupURL: URL
        let ledgerURL: URL
        let store: ComparisonStore
        let ledger: LedgerStore
        let cleanup: SQLiteFixtureDirectory
        let gate = PantryMutationGate()
        let lotID = UUID()
        var allowed = true
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var shop = ShoppingLedger(title: "Dinner shop")
        var mealID = UUID()
        var port: PantryCookPort {
            PantryCookPort(store: store, ledger: ledger, gate: gate, authorize: { self.allowed }, clock: { self.now })
        }

        @MainActor init(test: XCTestCase, tracked: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cleanup = SQLiteFixtureDirectory(directory, test: test)
            pickupURL = directory.appendingPathComponent("pickup.sqlite")
            ledgerURL = directory.appendingPathComponent("ledger.sqlite")
            store = try ComparisonStore(url: pickupURL, inventoryEnabled: true)
            ledger = try LedgerStore(url: ledgerURL, inventoryProjectionsEnabled: true)
            cleanup.track(store, ledger)
            let template = MealTemplate(title: "Bean supper", servings: .one,
                ingredients: [.init(name: "Beans", quantity: nil), .init(name: "Peas", quantity: nil), .init(name: "Oil", quantity: nil)])
            mealID = try shop.chooseMeal(template, at: now)
            let workspace = LedgerWorkspace(shops: [shop], mealTemplates: [template], selectedShopID: shop.id)
            struct Document: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
            _ = try await ledger.save(payload: JSONEncoder().encode(Document(workspace: workspace)), expectedRevision: 0, operationID: UUID(), savedAt: now)
            let amount = try quantity(10)
            let operation = UUID()
            let seed = InventoryLotSeed(foodID: UUID(), name: "Beans", source: .manual(originID: store.workspaceID, sourceID: lotID),
                location: .cupboard, unit: .count, count: .exact(amount))
            let command = InventoryCommand(id: operation, originID: store.workspaceID, lotID: lotID, eventID: UUID(), expectedRevision: nil,
                occurredAt: now, change: .create(seed, observationID: UUID()))
            _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: operation, expectedRevision: 0,
                request: Data([1]), mode: .activate, sourceToken: store.inventorySourceToken(),
                writes: PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))), at: now)
            now.addTimeInterval(30)
            let ctx = try await port.load(shopID: shop.id, mealID: mealID)
            let ids = ctx.meal.ingredientContributionIDs
            let use: CookCompletionDraft.Part.Use = tracked ? .lot(id: lotID, revision: 1, amount: nil) : .untracked
            let draft = CookCompletionDraft(inventoryID: store.workspaceID, inventoryRevision: ctx.inventory.state.revision,
                ledgerID: ledger.workspaceID, shop: shop, meal: ctx.meal, cookedAt: now, servingsMade: .one,
                parts: [.init(contributionID: ids[0], use: use), .init(contributionID: ids[1], use: use),
                        .init(contributionID: ids[2], use: .untracked)], leftovers: [])
            let reviewed = try await port.review(draft)
            try await port.apply(reviewed)
            now.addTimeInterval(60)
        }

        @MainActor func context() async throws -> PantryCookResolution.Context {
            try await port.loadResolutions(shopID: shop.id, mealID: mealID)
        }

        @MainActor func physicalCount(_ value: Int64) async throws {
            let inventory = try await port.load(shopID: shop.id, mealID: mealID).inventory
            let lot = try XCTUnwrap(inventory.lots.first { $0.id == lotID })
            let operation = UUID()
            let command = InventoryCommand(id: operation, originID: store.workspaceID, lotID: lotID, eventID: UUID(),
                expectedRevision: lot.revision, occurredAt: now, change: .count(.exact(try quantity(value)), observationID: UUID()))
            let change = try InventoryEngine.prepare(command, current: lot, at: now)
            _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: operation, expectedRevision: inventory.state.revision,
                request: Data([3]), writes: PantryPersistenceCodec.writes(change)), at: now)
            now.addTimeInterval(10)
        }
    }

    func testUntrackedUseDeductsOnceAcrossRestartAndNewPhysicalCountPreventsSecondDeduction() async throws {
        let f = try await Fixture(test: self, tracked: false)
        let initial = try await f.context()
        let ids = initial.remainingEventIDs
        let first = try await f.port.reviewResolution(initial, eventID: ids[0], decision: .deduct(lotID: f.lotID, used: quantity(2)))
        XCTAssertEqual(first.before?.quantity?.amount, try Rational(10))
        XCTAssertEqual(first.after?.quantity?.amount, try Rational(8))
        let alternate = try await f.port.reviewResolution(initial, eventID: ids[0], decision: .outsidePantry)
        f.allowed = false
        do { try await f.port.applyResolution(first); XCTFail("Revoked confirmation") } catch PantryCookPort.Failure.unavailable {}
        f.allowed = true
        try await f.port.applyResolution(first)
        let copy = try ComparisonStore(url: f.pickupURL, inventoryEnabled: true)
        let ledgerCopy = try LedgerStore(url: f.ledgerURL, inventoryProjectionsEnabled: true)
        f.cleanup.track(copy, ledgerCopy)
        let reopened = PantryCookPort(store: copy, ledger: ledgerCopy, gate: f.gate, authorize: { true }, clock: { f.now })
        try await reopened.applyResolution(first)
        do { try await reopened.applyResolution(alternate); XCTFail("Changed decision reused event identity") } catch {}
        let post = try await f.context()
        XCTAssertEqual(post.record.draft, initial.record.draft)
        XCTAssertEqual(post.remainingEventIDs, Array(ids.dropFirst()))
        XCTAssertEqual(post.inventoryRevision, initial.inventoryRevision + 1)
        XCTAssertTrue(post.actions(eventID: ids[1], lotID: f.lotID).contains(.deduct))
        let stale = try await f.port.reviewResolution(post, eventID: ids[1], decision: .deduct(lotID: f.lotID, used: quantity(1)))
        try await f.physicalCount(4)
        do { try await reopened.applyResolution(stale); XCTFail("Reviewed before newer count") } catch PantryCookPort.Failure.changed {}
        let recent = try await f.context()
        let actions = recent.actions(eventID: ids[1], lotID: f.lotID)
        XCTAssertFalse(actions.contains(.deduct))
        XCTAssertTrue(actions.contains(.alreadyIncluded))
        let included = try await f.port.reviewResolution(recent, eventID: ids[1], decision: .alreadyIncluded(lotID: f.lotID, used: quantity(1)))
        try await f.port.applyResolution(included)
        let next = try await f.context()
        XCTAssertEqual(next.lots, recent.lots)
        let outside = try await f.port.reviewResolution(next, eventID: ids[2], decision: .outsidePantry)
        try await f.port.applyResolution(outside)
        let done = try await f.context()
        XCTAssertEqual(done.remainingEventIDs, [])
        let home = try await f.port.load(shopID: f.shop.id, mealID: f.mealID)
        XCTAssertEqual(home.remainingUnresolvedUseIDs, [])
        XCTAssertEqual(home.completed?.unresolvedUseIDs, ids)
        XCTAssertEqual(done.record.resolutions?.map(\.eventID), ids)
        XCTAssertEqual(done.record.draft.unresolvedUseIDs, ids)
        do { _ = try await f.port.reviewUndo(shopID: f.shop.id, mealID: f.mealID); XCTFail("Later amendments protect history") }
        catch PantryCookPort.Failure.changed {}
    }

    func testPhysicalRecountIncludesSiblingUnknownUsesWithoutAutomaticallyClosingOrDeductingThem() async throws {
        let f = try await Fixture(test: self, tracked: true)
        let original = try await f.context()
        let ids = original.remainingEventIDs
        XCTAssertEqual(original.lots.first?.count, .unknown)
        XCTAssertEqual(original.actions(eventID: ids[0], lotID: f.lotID), [.recount])
        XCTAssertEqual(original.actions(eventID: ids[0], lotID: UUID()), [])
        let review = try await f.port.reviewResolution(original, eventID: ids[0],
            decision: .recount(lotID: f.lotID, remaining: quantity(6), used: nil))
        XCTAssertEqual(review.otherUnresolvedEventsForLot, [ids[1]])
        XCTAssertEqual(review.before, .unknown)
        XCTAssertEqual(review.after?.quantity?.amount, try Rational(6))
        try await f.port.applyResolution(review)
        let counted = try await f.context()
        XCTAssertEqual(counted.remainingEventIDs, Array(ids.dropFirst()))
        XCTAssertEqual(counted.actions(eventID: ids[1], lotID: f.lotID), [.recount, .alreadyIncluded])
        do {
            _ = try await f.port.reviewResolution(counted, eventID: ids[1], decision: .deduct(lotID: f.lotID, used: quantity(1)))
            XCTFail("A counted remainder already covers this other unknown use")
        } catch PantryCookPort.Failure.changed {}
        let second = try await f.port.reviewResolution(counted, eventID: ids[1], decision: .alreadyIncluded(lotID: f.lotID, used: nil))
        try await f.port.applyResolution(second)
        try await f.port.applyResolution(review)
        let final = try await f.context()
        XCTAssertEqual(final.lots, counted.lots)
        XCTAssertEqual(final.remainingEventIDs, [ids[2]])
        XCTAssertEqual(final.record.resolutions?.map(\.resultObservationID), [review.receipt.resultObservationID, nil])
        XCTAssertEqual(final.record.resolutions?.first?.basis?.observationID, original.lots.first?.observationID)
        let observations = try await f.store.inventoryRecords(kind: .observation)
        XCTAssertEqual(observations.count, 3, "Original count, unknown cook use and physical recount remain intact")
    }
}

private func quantity(_ value: Int64) throws -> Quantity {
    Quantity(amount: try Rational(value), unit: .count, originalLiteral: String(value))
}
