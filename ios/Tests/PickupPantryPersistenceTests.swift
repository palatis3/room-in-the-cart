import XCTest
import CoreDomain
import LocalStore
import SQLite3
@testable import RoomInTheCart

@MainActor final class PickupPantryPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ value: Int64) throws -> Quantity { .init(amount: try Rational(value), unit: .count, originalLiteral: String(value)) }
    private final class CleanupFault { var fail = false }
    private struct Fixture {
        let directory: URL
        let inventoryURL: URL
        let cleanup: SQLiteFixtureDirectory
        let producer: PickupModel
        let inventory: ComparisonStore
        let ledger: LedgerStore
        let pendingStore: PantryPickupPendingStore
        let gate: PantryMutationGate
        let fault: CleanupFault
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        let inventoryURL = directory.appendingPathComponent("pickup.sqlite")
        let inventory = try ComparisonStore(url: inventoryURL, inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(producer, inventory, ledger)
        let food = UUID()
        let added = await producer.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: try q(6),
            available: try q(0), due: nil, confirmedAt: now)); XCTAssertTrue(added)
        let journeyID = try XCTUnwrap(producer.journey?.id)
        let stocked = await producer.saveStockLot(.init(id: UUID(), foodID: food, name: "Freezer wraps", usable: try q(8),
            confirmedAt: now, source: .freezer), in: journeyID); XCTAssertTrue(stocked)
        let original = try await producer.archiveSnapshot()
        for head in original.records {
            _ = try await inventory.save(id: head.id, title: head.title, payload: head.payload, savedAt: head.savedAt)
        }
        let snapshot = try await inventory.inventoryCutoverSnapshot()
        let mapped = try PantryLegacyMigration.map(originID: inventory.workspaceID,
            heads: snapshot.sources.map(PantryLegacyMigration.SourceHead.init),
            ledger: .available(originID: ledger.workspaceID, revision: 0, workspace: LedgerWorkspace()), at: now)
        let package = try PantryMigrationPackage.build(mapped, migrationID: UUID(), sourceToken: snapshot.token, inventoryRevision: 0, at: now)
        _ = try await inventory.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await inventory.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await inventory.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let fault = CleanupFault()
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledger.workspaceID, removeFile: { url in
                if fault.fail { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.removeItem(at: url)
            })
        return Fixture(directory: directory, inventoryURL: inventoryURL, cleanup: cleanup, producer: producer,
            inventory: inventory, ledger: ledger, pendingStore: pending, gate: PantryMutationGate(), fault: fault)
    }
    private func model(_ f: Fixture, store: ComparisonStore? = nil,
                       pending: PantryPickupPendingStore? = nil) async -> PickupModel {
        let instant = now
        let model = PickupModel(store: store ?? f.inventory, clock: { instant }, pantry: .init(ledger: f.ledger,
            pendingStore: pending ?? f.pendingStore, gate: f.gate, authorize: { true }))
        f.cleanup.track(model)
        await model.load(); XCTAssertTrue(model.ready, model.error ?? "")
        return model
    }
    private func reopen(_ f: Fixture) throws -> (ComparisonStore, PantryPickupPendingStore) {
        let store = try ComparisonStore(url: f.inventoryURL, inventoryEnabled: true)
        f.cleanup.track(store)
        let pending = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: store.workspaceID, ledgerWorkspaceID: f.ledger.workspaceID)
        return (store, pending)
    }
    private func note(_ text: String, id: UUID = UUID(), in model: PickupModel) async -> Bool {
        let instant = now
        return await model.change { value in
            value.notes.append(.init(id: id, text: text, language: "en", createdAt: instant, revision: value.revision))
        }
    }
    @discardableResult private func canonical(_ change: InventoryChange, in store: ComparisonStore) async throws -> PantryRepository.Snapshot {
        let repository = PantryRepository(store: store, authorize: { true })
        let current = try await repository.load(at: now), lot = try XCTUnwrap(current.lots.first)
        return try await repository.apply(.init(id: UUID(), originID: store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: change), reviewedInventoryRevision: current.state.revision, at: now).current
    }
    private func writerLock(_ url: URL) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let pointer else { throw CocoaError(.fileWriteUnknown) }
        guard sqlite3_exec(pointer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(pointer); throw CocoaError(.fileWriteUnknown)
        }
        return pointer
    }
    private func unlock(_ pointer: inout OpaquePointer?) {
        if let value = pointer {
            XCTAssertEqual(sqlite3_exec(value, "ROLLBACK", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_close(value), SQLITE_OK)
            pointer = nil
        }
    }
    private func candidate(_ model: PickupModel, id: UUID, text: String) throws -> PickupJourney {
        var value = try XCTUnwrap(model.journey)
        value.notes.append(.init(id: id, text: text, language: "en", createdAt: now, revision: value.revision))
        return value
    }

    func testRealModelNoteSavePreservesPreviouslyReviewedCanonicalCountAndStorage() async throws {
        let f = try await fixture()
        _ = try await canonical(.count(.someLeft, observationID: UUID()), in: f.inventory)
        let before = try await canonical(.move(.fridge), in: f.inventory)
        let model = await self.model(f)
        let saved = await note("Warm gently", in: model)
        XCTAssertTrue(saved, model.error ?? "")
        XCTAssertEqual(model.pantrySnapshot?.lots, before.lots)
        XCTAssertEqual(model.pantrySnapshot?.reservations, before.reservations)
        XCTAssertEqual(model.journey?.notes.last?.text, "Warm gently")
        XCTAssertFalse(model.hasPendingSave); XCTAssertNil(try f.pendingStore.read())
        let fresh = try await PantryRepository(store: f.inventory, authorize: { true }).load(at: now)
        XCTAssertEqual(fresh.lots, before.lots)
    }

    func testCommittedCleanupFailureReopensPendingAndAdoptsLaterCountAndSourceWithoutDuplicates() async throws {
        let f = try await fixture(), model = await self.model(f), firstNote = UUID()
        f.fault.fail = true
        let saved = await note("First note", id: firstNote, in: model)
        XCTAssertFalse(saved); XCTAssertTrue(model.hasPendingPantrySave)
        let entry = try XCTUnwrap(f.pendingStore.read()); XCTAssertNotNil(entry.acknowledgment)
        XCTAssertEqual(model.journey?.notes.last?.id, firstNote)
        _ = try await canonical(.count(.exact(try q(3)), observationID: UUID()), in: f.inventory)
        // An independent real legacy producer supplies a later source revision.
        // Replay must return that current source, not restore the first pending payload.
        let echoed = await note("First note", id: firstNote, in: f.producer); XCTAssertTrue(echoed)
        let laterNote = UUID(), laterSaved = await note("Later note", id: laterNote, in: f.producer); XCTAssertTrue(laterSaved)
        let produced = try await f.producer.archiveSnapshot(), laterHead = try XCTUnwrap(produced.records.first)
        let prior = try await f.inventory.load(id: laterHead.id)
        let changed = PantryLegacyMigration.SourceHead(id: laterHead.id, revision: try XCTUnwrap(prior).revision + 1,
            payload: laterHead.payload, savedAt: laterHead.savedAt)
        let instant = now
        let port = PantryPickupCommitPort(store: f.inventory, ledger: f.ledger, gate: f.gate,
            authorize: { _, _ in true }, clock: { instant })
        let review = try await port.prepare(operationID: UUID(), changedHeads: [changed], preparedAt: now)
        let latest = try await port.apply(review.submission)
        let observations = try await f.inventory.inventoryRecords(kind: .observation)
        try await f.inventory.close()
        let (reopened, journal) = try reopen(f)
        let restored = await self.model(f, store: reopened, pending: journal)
        XCTAssertTrue(restored.hasPendingPantrySave)
        XCTAssertEqual(try journal.read(), entry)
        let retried = await restored.retrySave(); XCTAssertTrue(retried, restored.error ?? "")
        XCTAssertFalse(restored.hasPendingSave); XCTAssertNil(try journal.read())
        XCTAssertEqual(restored.pantrySnapshot?.state, latest.current.state)
        XCTAssertEqual(restored.pantrySnapshot?.lots.first?.count.quantity, try q(3))
        XCTAssertEqual(restored.journey?.notes.map(\.id), [firstNote, laterNote])
        let after = try await reopened.inventoryRecords(kind: .observation)
        XCTAssertEqual(after, observations)
        let state = try await reopened.inventoryState(); XCTAssertEqual(state, latest.current.state)
    }

    func testUncommittedLockedSaveReopensAndDiscardPreventsCachedRetryFromRecreatingJournal() async throws {
        let f = try await fixture(), cached = await self.model(f)
        let before = try await f.inventory.inventoryState(), sourceBefore = try await f.inventory.list()
        var lock: OpaquePointer? = try writerLock(f.inventoryURL)
        defer { unlock(&lock) }
        let saved = await note("Uncommitted note", in: cached)
        XCTAssertFalse(saved); XCTAssertTrue(cached.hasPendingPantrySave)
        let entry = try XCTUnwrap(f.pendingStore.read()); XCTAssertNil(entry.acknowledgment)
        unlock(&lock)
        let (reopened, journal) = try reopen(f)
        let restored = await self.model(f, store: reopened, pending: journal)
        XCTAssertTrue(restored.hasPendingPantrySave)
        await restored.discardPendingSafely()
        XCTAssertFalse(restored.hasPendingSave); XCTAssertNil(try journal.read())
        let state = try await reopened.inventoryState(), sources = try await reopened.list()
        XCTAssertEqual(state, before); XCTAssertEqual(sources, sourceBefore)
        let staleRetry = await cached.retrySave(); XCTAssertFalse(staleRetry)
        XCTAssertNil(try journal.read(), "Cached retry may not recreate discarded intent bytes.")
        XCTAssertFalse(cached.hasPendingSave, "An independently discarded save must not permanently block the old model.")
        XCTAssertTrue(cached.ready)
        XCTAssertTrue(cached.journey?.notes.isEmpty == true)
        let finalState = try await reopened.inventoryState(); XCTAssertEqual(finalState, before)
        XCTAssertTrue(restored.journey?.notes.isEmpty == true)
        let freshSaved = await note("Fresh review", in: cached)
        XCTAssertTrue(freshSaved, cached.error ?? "")
        XCTAssertEqual(cached.journey?.notes.map(\.text), ["Fresh review"])
    }

    func testCachedCommittedSaveRecognizesAnotherModelCleanupWithoutReplayingOldSource() async throws {
        let f = try await fixture(), cached = await self.model(f)
        f.fault.fail = true
        let saved = await note("Committed once", in: cached)
        XCTAssertFalse(saved); XCTAssertTrue(cached.hasPendingPantrySave)
        let (reopened, journal) = try reopen(f)
        let other = await self.model(f, store: reopened, pending: journal)
        let recovered = await other.retrySave(); XCTAssertTrue(recovered)
        let later = await note("Later edit", in: other); XCTAssertTrue(later)
        let before = try await reopened.inventoryState()
        let retried = await cached.retrySave()
        XCTAssertTrue(retried, cached.error ?? "")
        XCTAssertFalse(cached.hasPendingSave); XCTAssertTrue(cached.ready)
        XCTAssertNil(try journal.read())
        XCTAssertEqual(cached.journey?.notes.map(\.text), ["Committed once", "Later edit"])
        let after = try await reopened.inventoryState(); XCTAssertEqual(after, before)
    }

    func testRestoredActionNeedsFreshScopedAuthorizationBeforeUncommittedRetry() async throws {
        let f = try await fixture(), original = await self.model(f), operation = UUID(), noteID = UUID()
        let reviewed = try candidate(original, id: noteID, text: "Reviewed action")
        var lock: OpaquePointer? = try writerLock(f.inventoryURL)
        defer { unlock(&lock) }
        let saved = await original.saveRecoveryCandidate(reviewed, operationID: operation,
            authorize: { [weak original] in original?.isValidatingRecoverySave(operation) == true })
        XCTAssertFalse(saved); XCTAssertTrue(original.hasPendingPantrySave)
        let entry = try XCTUnwrap(f.pendingStore.read())
        XCTAssertTrue(entry.requiresActionAuthorization); XCTAssertEqual(entry.recoveryOperationID, operation)
        unlock(&lock)
        try await f.inventory.close()
        let (reopened, journal) = try reopen(f), restored = await self.model(f, store: reopened, pending: journal)
        let before = try await reopened.inventoryState()
        let generic = await restored.retrySave(); XCTAssertFalse(generic)
        XCTAssertEqual(try journal.read(), entry)
        let stillBefore = try await reopened.inventoryState(); XCTAssertEqual(stillBefore, before)
        let renewed = await restored.retryRecoveryCandidate(operationID: operation,
            authorize: { [weak restored] in restored?.isValidatingRecoverySave(operation) == true }, matches: { $0.notes.last?.id == noteID })
        XCTAssertTrue(renewed, restored.error ?? "")
        XCTAssertEqual(restored.journey?.notes.last?.id, noteID)
        XCTAssertNil(try journal.read()); XCTAssertFalse(restored.hasPendingSave)
        let after = try await reopened.inventoryState(); XCTAssertEqual(after.revision, before.revision + 1)
    }

    func testCommittedActionReceiptRecoversAfterActionGrantExpires() async throws {
        let f = try await fixture(), original = await self.model(f), operation = UUID(), noteID = UUID()
        var actionAllowed = true
        f.fault.fail = true
        let reviewed = try candidate(original, id: noteID, text: "Committed reviewed action")
        let saved = await original.saveRecoveryCandidate(reviewed, operationID: operation,
            authorize: { [weak original] in actionAllowed && original?.isValidatingRecoverySave(operation) == true })
        XCTAssertFalse(saved)
        let entry = try XCTUnwrap(f.pendingStore.read()); XCTAssertNotNil(entry.acknowledgment)
        XCTAssertTrue(entry.requiresActionAuthorization)
        actionAllowed = false
        let committed = try await f.inventory.inventoryState()
        try await f.inventory.close()
        let (reopened, journal) = try reopen(f), restored = await self.model(f, store: reopened, pending: journal)
        let recovered = await restored.retrySave()
        XCTAssertTrue(recovered, restored.error ?? "")
        XCTAssertEqual(restored.journey?.notes.last?.id, noteID)
        XCTAssertNil(try journal.read()); XCTAssertFalse(restored.hasPendingSave)
        let after = try await reopened.inventoryState(); XCTAssertEqual(after, committed)
    }

    func testStaleIndependentCanonicalChangeRejectsNewModelSaveWithoutOverwritingEitherHead() async throws {
        let f = try await fixture(), model = await self.model(f)
        let updated = try await canonical(.count(.someLeft, observationID: UUID()), in: f.inventory)
        let sourcesBefore = try await f.inventory.list()
        let saved = await note("Stale screen note", in: model)
        XCTAssertFalse(saved); XCTAssertFalse(model.hasPendingSave)
        XCTAssertNil(try f.pendingStore.read())
        let current = try await PantryRepository(store: f.inventory, authorize: { true }).load(at: now)
        XCTAssertEqual(current.state, updated.state); XCTAssertEqual(current.lots, updated.lots)
        let sourcesAfter = try await f.inventory.list(); XCTAssertEqual(sourcesAfter, sourcesBefore)
        XCTAssertTrue(model.journey?.notes.isEmpty == true)
    }
}
