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

        @MainActor init(test: XCTestCase, tracked: Bool, measuredThird: Bool = false, leftover: Bool = false) async throws {
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
            let outputs: [CookCompletionDraft.Leftovers] = leftover ? [.init(name: "Bean lunch", portions: .one, location: .fridge)] : []
            let draft = CookCompletionDraft(inventoryID: store.workspaceID, inventoryRevision: ctx.inventory.state.revision,
                ledgerID: ledger.workspaceID, shop: shop, meal: ctx.meal, cookedAt: now, servingsMade: .one,
                parts: [.init(contributionID: ids[0], use: use), .init(contributionID: ids[1], use: use),
                        .init(contributionID: ids[2], use: measuredThird ? .lot(id: lotID, revision: 1, amount: try quantity(1)) : .untracked)], leftovers: outputs)
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
        catch PantryCookUndoFailure.independentPhysicalCount(let name) { XCTAssertEqual(name, "Beans") }
    }

    func testTwoMeasuredAmendmentsRestoreOriginalCountOnlyAfterLastUnknownAndKeepOriginalMeasuredUse() async throws {
        let f = try await Fixture(test: self, tracked: true, measuredThird: true)
        let original = try await f.context()
        let ids = original.remainingEventIDs
        let first = try await f.port.reviewResolution(original, eventID: ids[0], decision: .deduct(lotID: f.lotID, used: quantity(2)))
        XCTAssertEqual(first.reconstructionBasis?.amount, try Rational(10))
        XCTAssertEqual(first.reconstruction?.previouslyAccounted, .one)
        XCTAssertEqual(first.after, .unknown)
        XCTAssertEqual(first.otherUnresolvedEventsForLot, [ids[1]])
        try await f.port.applyResolution(first)
        try await f.port.applyResolution(first)
        let partial = try await f.context()
        XCTAssertEqual(partial.lots.first?.observationID, original.lots.first?.observationID)
        XCTAssertEqual(partial.remainingEventIDs, [ids[1]])
        do {
            _ = try await f.port.reviewResolution(partial, eventID: ids[1], decision: .deduct(lotID: f.lotID, used: quantity(8)))
            XCTFail("Ten minus the original one and the previously measured two cannot cover eight")
        } catch InventoryError.invalid {}
        let last = try await f.port.reviewResolution(partial, eventID: ids[1], decision: .deduct(lotID: f.lotID, used: quantity(3)))
        XCTAssertEqual(last.reconstruction?.previouslyAccounted, try Rational(3))
        XCTAssertEqual(last.after?.quantity?.amount, try Rational(4))
        try await f.port.applyResolution(last)
        try await f.port.applyResolution(first)
        try await f.port.applyResolution(last)
        let done = try await f.context()
        XCTAssertEqual(done.remainingEventIDs, [])
        XCTAssertEqual(done.lots.first?.count.quantity?.amount, try Rational(4))
        XCTAssertEqual(done.record.draft, original.record.draft)
        XCTAssertNil(done.record.resolutions?.first?.resultObservationID)
        let observations = try await f.store.inventoryRecords(kind: .observation)
        XCTAssertEqual(observations.count, 3)
    }

    func testUndoOutsideAndAlreadyIncludedKeepsLatestPhysicalCountAndAmendmentHistoryAcrossReopen() async throws {
        let f = try await Fixture(test: self, tracked: false)
        let initial = try await f.context()
        let ids = initial.remainingEventIDs
        let outside = try await f.port.reviewResolution(initial, eventID: ids[0], decision: .outsidePantry)
        try await f.port.applyResolution(outside)
        try await f.physicalCount(7)
        let recent = try await f.context()
        let included = try await f.port.reviewResolution(recent, eventID: ids[1], decision: .alreadyIncluded(lotID: f.lotID, used: quantity(1)))
        try await f.port.applyResolution(included)
        try await f.physicalCount(5)
        let before = try await f.context()
        let undo = try await f.port.reviewUndo(shopID: f.shop.id, mealID: f.mealID)
        XCTAssertEqual(undo.resolvedUseCount, 2)
        XCTAssertEqual(undo.preservedCountNames, ["Beans"])
        XCTAssertTrue(undo.restoredInputs.isEmpty)
        try await f.port.applyUndo(undo)
        let copy = try ComparisonStore(url: f.pickupURL, inventoryEnabled: true)
        let ledger = try LedgerStore(url: f.ledgerURL, inventoryProjectionsEnabled: true)
        f.cleanup.track(copy, ledger)
        let reopened = PantryCookPort(store: copy, ledger: ledger, gate: f.gate, authorize: { true }, clock: { f.now })
        try await reopened.applyUndo(undo)
        try await reopened.applyResolution(outside)
        let after = try await reopened.load(shopID: f.shop.id, mealID: f.mealID)
        XCTAssertNil(after.completed)
        XCTAssertEqual(after.inventory.lots, before.lots)
        XCTAssertEqual(after.inventory.state.revision, before.inventoryRevision + 1)
        let stored = try await copy.load(id: f.shop.id)
        let audit = try JSONDecoder().decode(PickupJourney.self, from: XCTUnwrap(stored?.payload))
        let record = try XCTUnwrap(audit.cookedMeals?.first)
        XCTAssertEqual(record.draft, initial.record.draft)
        XCTAssertEqual(record.resolutions, before.record.resolutions)
        XCTAssertEqual(record.undo?.resolvedEventIDs, Array(ids.prefix(2)))
        try record.validate(shopID: f.shop.id)
    }

    func testUndoReconstructedAndNewlyIdentifiedDrawsRestoresOnlyTheirExactStockLineage() async throws {
        for tracked in [false, true] {
            let f = try await Fixture(test: self, tracked: tracked, measuredThird: tracked)
            let initial = try await f.context()
            let ids = initial.remainingEventIDs
            let first = try await f.port.reviewResolution(initial, eventID: ids[0], decision: .deduct(lotID: f.lotID, used: quantity(2)))
            try await f.port.applyResolution(first)
            let partial = try await f.context()
            let next = try await f.port.reviewResolution(partial, eventID: ids[1], decision: .deduct(lotID: f.lotID, used: quantity(3)))
            try await f.port.applyResolution(next)
            let undo = try await f.port.reviewUndo(shopID: f.shop.id, mealID: f.mealID)
            XCTAssertEqual(undo.restoredInputs.map(\.lotID), [f.lotID])
            XCTAssertEqual(undo.restoredInputs.first?.count.quantity?.amount, try Rational(10))
            XCTAssertEqual(undo.resolvedUseCount, 2)
            if tracked {
                try await f.port.applyUndo(undo)
                try await f.port.applyUndo(undo)
                let done = try await f.port.load(shopID: f.shop.id, mealID: f.mealID)
                XCTAssertNil(done.completed)
                XCTAssertEqual(done.inventory.lots.first?.count.quantity?.amount, try Rational(10))
            } else {
                try await f.physicalCount(4)
                do { try await f.port.applyUndo(undo); XCTFail("The pre-count Undo cannot overwrite a newer balance") }
                catch PantryCookUndoFailure.amendedInputChanged(let lot) { XCTAssertEqual(lot, "Beans") }
                let current = try await f.context()
                XCTAssertEqual(current.lots.first?.count.quantity?.amount, try Rational(4))
                XCTAssertTrue(current.record.isActive)
            }
        }
    }

    func testResolvedOutsideUseCannotUndoCountedLeftoversHeldForLunch() async throws {
        let f = try await Fixture(test: self, tracked: false, leftover: true)
        let original = try await f.context()
        let outside = try await f.port.reviewResolution(original, eventID: original.remainingEventIDs[0], decision: .outsidePantry)
        try await f.port.applyResolution(outside)
        let undo = try await f.port.reviewUndo(shopID: f.shop.id, mealID: f.mealID)
        let output = try XCTUnwrap(original.record.draft.leftovers.first)
        let hold = InventoryReservation(id: UUID(), originID: f.store.workspaceID, revision: 1, foodID: output.foodID, lotID: output.id,
            name: "Lunch", amount: try quantity(1), priority: .protected, state: .active)
        let state = try await f.store.inventoryState()
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(), expectedRevision: state.revision,
            request: Data([9]), writes: [PantryPersistenceCodec.write(hold, expectedRevision: 0)]), at: f.now)
        do { try await f.port.applyUndo(undo); XCTFail("A reserved lunch cannot be removed by an old Undo") }
        catch PantryCookPort.Failure.changed {}
        let after = try await f.port.load(shopID: f.shop.id, mealID: f.mealID)
        XCTAssertEqual(after.inventory.reservations, [hold])
        XCTAssertEqual(after.inventory.lots.first { $0.id == output.id }?.count.quantity?.amount, .one)
        XCTAssertEqual(after.completed?.id, original.record.draft.id)
    }

    func testPhysicalRecountIncludesSiblingUnknownUsesWithoutAutomaticallyClosingOrDeductingThem() async throws {
        let f = try await Fixture(test: self, tracked: true)
        let original = try await f.context()
        let ids = original.remainingEventIDs
        XCTAssertEqual(original.lots.first?.count, .unknown)
        XCTAssertEqual(original.actions(eventID: ids[0], lotID: f.lotID), [.recount, .deduct])
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
        do { _ = try await f.port.reviewUndo(shopID: f.shop.id, mealID: f.mealID); XCTFail("Physical count is independent evidence") }
        catch PantryCookUndoFailure.independentPhysicalCount(let lot) { XCTAssertEqual(lot, "Beans") }
    }
}

private func quantity(_ value: Int64) throws -> Quantity {
    Quantity(amount: try Rational(value), unit: .count, originalLiteral: String(value))
}
