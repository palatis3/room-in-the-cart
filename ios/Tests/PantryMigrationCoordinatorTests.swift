import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryMigrationCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) throws -> Quantity { .init(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let store: ComparisonStore
        let ledgerStore: LedgerStore
        let pickup: PickupModel
        let ledger: LedgerModel
        let gate: PantryMutationGate
        let stockID: UUID
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let gate = PantryMutationGate()
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), mutationGate: gate)
        await ledger.open()
        let ledgerStore = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let pickup = PickupModel(store: store, clock: { instant }, mutationGate: gate)
        cleanup.track(ledger, ledgerStore, store, pickup)
        let food = UUID()
        let added = await pickup.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: try q(6),
            available: try q(0), due: nil, confirmedAt: now))
        XCTAssertTrue(added)
        let journey = try XCTUnwrap(pickup.journey?.id)
        let stockID = UUID()
        let stocked = await pickup.saveStockLot(.init(id: stockID, foodID: food, name: "Freezer wraps",
            usable: try q(4), confirmedAt: now, source: .freezer), in: journey)
        XCTAssertTrue(stocked)
        return Fixture(directory: directory, cleanup: cleanup, store: store, ledgerStore: ledgerStore,
            pickup: pickup, ledger: ledger, gate: gate, stockID: stockID)
    }
    private func coordinator(_ f: Fixture) -> PantryMigrationCoordinator {
        let instant = now
        return PantryMigrationCoordinator(store: f.store, ledger: f.ledgerStore, gate: f.gate,
            authorize: { true }, clock: { instant })
    }
    private func stage(_ review: PantryMigrationCoordinator.Review, store: ComparisonStore) async throws {
        _ = try await store.beginInventoryMigration(review.package.plan)
        if let first = review.package.chunks.first {
            _ = try await store.stageInventoryMigration(id: review.package.plan.migrationID, chunk: first)
        }
    }

    func testFreshWorkspaceActivatesWithoutInventingAPickupOrLedgerPlan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(store, ledger)
        let flow = PantryMigrationCoordinator(store: store, ledger: ledger, gate: PantryMutationGate(),
            authorize: { true }, clock: { instant })
        let review = try await flow.prepare()
        XCTAssertEqual(review.sourceCount, 0); XCTAssertEqual(review.lotCount, 0)
        let applied = try await flow.apply(review)
        XCTAssertTrue(applied.state.active)
        let current = try await PantryRepository(store: store, authorize: { true }).load(at: now)
        XCTAssertTrue(current.lots.isEmpty); XCTAssertTrue(current.reservations.isEmpty)
        let pickups = try await store.list(), plans = try await ledger.load()
        XCTAssertTrue(pickups.isEmpty); XCTAssertNil(plans)
    }

    func testReviewedMigrationPreservesSourcesAndReplayDoesNotRestoreOlderState() async throws {
        let f = try await fixture()
        var instant = now
        let flow = PantryMigrationCoordinator(store: f.store, ledger: f.ledgerStore, gate: f.gate,
            authorize: { true }, clock: { instant })
        let original = try await f.store.list()
        let review = try await flow.prepare()
        XCTAssertEqual(review.sourceCount, 1)
        XCTAssertEqual(review.lotCount, 2, "The urgent need's explicit zero count and the freezer batch remain separate sources.")
        XCTAssertEqual(review.reservationCount, 1)
        let first = try await flow.apply(review)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(first.state.active)
        let repository = PantryRepository(store: f.store, authorize: { true })
        let current = try await repository.load(at: now)
        let lot = try XCTUnwrap(current.lots.first { $0.source == .manual(originID: f.store.workspaceID, sourceID: f.stockID) })
        XCTAssertEqual(lot.count, .exact(try q(4)))
        XCTAssertEqual(current.reservations.first?.amount, try q(6))
        let command = InventoryCommand(id: UUID(), originID: f.store.workspaceID, lotID: lot.id,
            eventID: UUID(), expectedRevision: lot.revision, occurredAt: now, change: .count(.someLeft, observationID: UUID()))
        let changed = try await repository.apply(command, reviewedInventoryRevision: current.state.revision, at: now)
        let laterLedger = await f.ledger.change(key: "later-ledger") { $0.shops.append(ShoppingLedger(title: "Later week")) }
        XCTAssertTrue(laterLedger)
        instant = now.addingTimeInterval(-60) // A committed retry is independent of wall-clock freshness.
        let replay = try await flow.apply(review)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.receipt, first.receipt)
        XCTAssertEqual(replay.state, changed.current.state)
        let after = try await repository.load(at: now)
        XCTAssertEqual(after.lots.first { $0.id == lot.id }?.count, .someLeft)
        let retained = try await f.store.list()
        XCTAssertEqual(retained, original)
    }

    func testInterruptedStagingResumesFromDurableOriginalContextAfterReopen() async throws {
        let f = try await fixture()
        let journeyID = try XCTUnwrap(f.pickup.journey?.id)
        for index in 0..<45 {
            let id = UUID()
            let saved = await f.pickup.saveStockLot(.init(id: id, foodID: id, name: "Other batch \(index)",
                usable: try q(1), confirmedAt: now, source: .pantry), in: journeyID)
            XCTAssertTrue(saved)
        }
        let review = try await coordinator(f).prepare()
        XCTAssertGreaterThan(review.package.chunks.count, 1)
        try await stage(review, store: f.store)
        let partial = try await f.store.inventoryPendingMigration()
        XCTAssertEqual(partial?.nextChunk, 1)
        XCTAssertLessThan(try XCTUnwrap(partial?.stagedRecordCount), review.package.plan.expectedRecordCount)
        let inactive = try await f.store.inventoryState()
        XCTAssertFalse(inactive.active)
        try await f.store.close(); try await f.ledgerStore.close()
        let store = try ComparisonStore(url: f.directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(store, ledger)
        let later = now.addingTimeInterval(3_600)
        let resumed = try await PantryMigrationCoordinator(store: store, ledger: ledger, gate: PantryMutationGate(),
            authorize: { true }, clock: { later }).resume()
        XCTAssertTrue(resumed.state.active)
        XCTAssertEqual(resumed.receipt.operationID, review.package.plan.migrationID)
        let loaded = try await PantryRepository(store: store, authorize: { true }).load(at: later)
        XCTAssertEqual(loaded.lots.first { $0.source == .manual(originID: store.workspaceID, sourceID: f.stockID) }?.count, .exact(try q(4)))
        XCTAssertEqual(loaded.reservations.count, 1)
        let pending = try await store.inventoryPendingMigration()
        XCTAssertNil(pending)
    }

    func testSourceChangeAfterReviewCannotBeCoveredByANewToken() async throws {
        let f = try await fixture(), flow = coordinator(f), review = try await flow.prepare()
        let changed = await f.pickup.addUrgent(.init(id: UUID(), food: "Milk", meal: "Breakfast",
            required: try q(1), available: try q(0), due: nil, confirmedAt: now))
        XCTAssertTrue(changed)
        do { _ = try await flow.apply(review); XCTFail("old mapping must not use a newly fetched token") }
        catch { XCTAssertEqual(error as? PantryMigrationCoordinator.Failure, .sourceChanged) }
        let state = try await f.store.inventoryState(), pending = try await f.store.inventoryPendingMigration()
        XCTAssertFalse(state.active); XCTAssertNil(pending)
        let fresh = try await flow.prepare()
        XCTAssertEqual(fresh.reservationCount, 2)
        let applied = try await flow.apply(fresh)
        XCTAssertTrue(applied.state.active)
    }

    func testChangedLedgerBlocksResumeButStagingCanBeCancelledWithoutChangingSources() async throws {
        let f = try await fixture(), flow = coordinator(f), review = try await flow.prepare()
        let before = try await f.store.list()
        try await stage(review, store: f.store)
        let changed = await f.ledger.change(key: "new-plans") { $0.shops.append(ShoppingLedger(title: "New plan")) }
        XCTAssertTrue(changed)
        do { _ = try await flow.resume(); XCTFail("companion ledger changed since original review") }
        catch { XCTAssertEqual(error as? PantryMigrationCoordinator.Failure, .staleLedger) }
        let state = try await f.store.inventoryState()
        XCTAssertFalse(state.active)
        let pending = try await f.store.inventoryPendingMigration()
        XCTAssertEqual(pending?.migrationID, review.package.plan.migrationID)
        try await flow.cancelPending()
        let retained = try await f.store.list(), cancelled = try await f.store.inventoryPendingMigration()
        XCTAssertEqual(retained, before); XCTAssertNil(cancelled)
        let fresh = try await flow.prepare()
        let result = try await flow.apply(fresh)
        XCTAssertTrue(result.state.active)
    }

    func testMutationGateAndRevokedAccessPreventStartingMigrationAndReleaseCleanly() async throws {
        let f = try await fixture(), instant = now
        var allowed = true
        let flow = PantryMigrationCoordinator(store: f.store, ledger: f.ledgerStore, gate: f.gate,
            authorize: { allowed }, clock: { instant })
        let write = try f.gate.beginWrite()
        do { _ = try await flow.prepare(); XCTFail("ordinary writer is active") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        f.gate.endWrite(write)
        let review = try await flow.prepare()
        allowed = false
        do { _ = try await flow.apply(review); XCTFail("revoked workspace") }
        catch { XCTAssertEqual(error as? PantryMigrationCoordinator.Failure, .unauthorized) }
        let state = try await f.store.inventoryState(), pending = try await f.store.inventoryPendingMigration()
        XCTAssertFalse(state.active); XCTAssertNil(pending)
        allowed = true
        let lease = try f.gate.beginMigration()
        XCTAssertThrowsError(try f.gate.beginWrite()) { XCTAssertEqual($0 as? PantryMutationGate.Failure, .busy) }
        f.gate.endMigration(lease)
        let result = try await flow.apply(review)
        XCTAssertTrue(result.state.active)
    }

    func testActualPickupAndPantryWritersRespectSharedMigrationLease() async throws {
        let f = try await fixture()
        let before = try await f.store.list()
        let lease = try f.gate.beginMigration()
        let added = await f.pickup.addUrgent(.init(id: UUID(), food: "Milk", meal: "Breakfast",
            required: try q(1), available: try q(0), due: nil, confirmedAt: now))
        XCTAssertFalse(added)
        XCTAssertTrue(f.pickup.hasPendingSave)
        let blocked = try await f.store.list()
        XCTAssertEqual(blocked, before)
        f.gate.endMigration(lease)
        let retried = await f.pickup.retrySave()
        XCTAssertTrue(retried)
        XCTAssertFalse(f.pickup.hasPendingSave)
        let after = try await f.store.list()
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.first?.revision, (before.first?.revision ?? 0) + 1)
        let deletionLease = try f.gate.beginMigration()
        let row = try XCTUnwrap(after.first)
        do {
            try await f.pickup.deleteArchived(id: row.id, expectedRevision: row.revision, operationID: UUID())
            XCTFail("source retirement must wait for migration")
        } catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        f.gate.endMigration(deletionLease)

        let flow = coordinator(f)
        let review = try await flow.prepare()
        _ = try await flow.apply(review)
        let repository = PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true })
        let snapshot = try await repository.load(at: now)
        let lot = try XCTUnwrap(snapshot.lots.first)
        let command = InventoryCommand(id: UUID(), originID: f.store.workspaceID, lotID: lot.id,
            eventID: UUID(), expectedRevision: lot.revision, occurredAt: now, change: .move(.fridge))
        let pantryLease = try f.gate.beginMigration()
        do {
            _ = try await repository.apply(command, reviewedInventoryRevision: snapshot.state.revision, at: now)
            XCTFail("pantry writer must use the same gate")
        } catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        let unchanged = try await f.store.inventoryState()
        XCTAssertEqual(unchanged, snapshot.state)
        f.gate.endMigration(pantryLease)
        let saved = try await repository.apply(command, reviewedInventoryRevision: snapshot.state.revision, at: now)
        XCTAssertEqual(saved.current.state.revision, snapshot.state.revision + 1)
        XCTAssertEqual(saved.current.lots.first { $0.id == lot.id }?.location, .fridge)
    }
}
