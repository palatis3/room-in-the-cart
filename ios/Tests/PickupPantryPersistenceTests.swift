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
        let current = try await repository.load(at: now)
        let lot = try XCTUnwrap(current.lots.first { $0.name == "Freezer wraps" })
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
        let coverage = try XCTUnwrap(model.allocation?.demands.first)
        XCTAssertNil(coverage.allocated, "A qualitative pantry count must not reuse the old eight-wrap snapshot.")
        XCTAssertFalse(coverage.issues.isEmpty)
        XCTAssertFalse(model.allocation?.confirmedCoverageComplete ?? true)
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
        XCTAssertEqual(restored.pantrySnapshot?.lots.first(where: { $0.name == "Freezer wraps" })?.count.quantity, try q(3))
        XCTAssertEqual(restored.allocation?.demands.first?.allocated, try Rational(3))
        XCTAssertEqual(restored.allocation?.demands.first?.shortfall, try Rational(3))
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

    func testPantryEditorSaveRefreshesAlreadyReadyPickupCoverageWithoutRewritingLegacyCount() async throws {
        let f = try await fixture(), pickup = await model(f)
        let pantry = try XCTUnwrap(pickup.makePantryModel())
        await pantry.load()
        let lot = try XCTUnwrap(pantry.snapshot?.lots.first { $0.name == "Freezer wraps" })
        await pantry.prepare(lotID: lot.id, action: .recount("3", .count))
        XCTAssertNotNil(pantry.review)
        await pantry.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(pantry.notice, .saved)
        XCTAssertTrue(pickup.ready); XCTAssertTrue(pickup.pantryReadIsCurrent)
        XCTAssertEqual(pickup.allocation?.demands.first?.allocated, try Rational(3))
        XCTAssertEqual(pickup.allocation?.demands.first?.shortfall, try Rational(3))
        XCTAssertEqual(pickup.journey?.stockLots.first(where: { $0.name == "Freezer wraps" })?.usable, try q(8))
        XCTAssertEqual(pickup.pantrySnapshot?.state, pantry.snapshot?.state)
    }

    func testPantryFactoryReopensOriginalFoodEditAndRefreshesPickupAfterRetry() async throws {
        let f = try await fixture(), pickup = await model(f)
        let editor = try XCTUnwrap(pickup.makePantryModel())
        await editor.load()
        let lot = try XCTUnwrap(editor.snapshot?.lots.first { $0.name == "Freezer wraps" })
        await editor.prepare(lotID: lot.id, action: .recount("3", .count))
        let review = try XCTUnwrap(editor.review)
        let journal = try f.pendingStore.makeFoodPendingStore()
        let original = try journal.save(command: review.command, reviewedInventoryRevision: review.before.state.revision)
        XCTAssertNil(try f.pendingStore.read(), "A food command must not occupy the pickup journal.")
        let reopened = try XCTUnwrap(pickup.makePantryModel())
        await reopened.load()
        XCTAssertEqual(reopened.pending, original)
        XCTAssertFalse(reopened.canEdit)
        await reopened.retryPending()
        XCTAssertNil(reopened.pending); XCTAssertNil(try journal.read())
        XCTAssertEqual(reopened.notice, .saved)
        XCTAssertEqual(pickup.pantrySnapshot?.state, reopened.snapshot?.state)
        XCTAssertEqual(pickup.allocation?.demands.first?.allocated, try Rational(3))
        let after = try await f.inventory.inventoryState()
        await reopened.retryPending()
        let repeated = try await f.inventory.inventoryState()
        XCTAssertEqual(repeated, after, "Retry after cleanup must not record the count twice.")
    }

    func testFoodCleanupFailureRefreshesCommittedCoverageWhileKeepingRecoveryBlocked() async throws {
        let f = try await fixture(), instant = now
        var failRemoval = true
        let foodPending = try PantryPendingStore(directory: f.directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: f.inventory.workspaceID, removeFile: { url in
                if failRemoval { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.removeItem(at: url)
            })
        let pickup = PickupModel(store: f.inventory, clock: { instant }, pantry: .init(ledger: f.ledger,
            pendingStore: f.pendingStore, gate: f.gate, authorize: { true }, foodPendingStore: foodPending))
        f.cleanup.track(pickup)
        await pickup.load()
        let editor = try XCTUnwrap(pickup.makePantryModel())
        await editor.load()
        let lot = try XCTUnwrap(editor.snapshot?.lots.first { $0.name == "Freezer wraps" })
        await editor.prepare(lotID: lot.id, action: .recount("3", .count))
        await editor.confirmReview(acknowledgingReservations: true)
        XCTAssertNotNil(editor.pending); XCTAssertFalse(editor.canEdit)
        XCTAssertNotNil(try foodPending.read()?.acknowledgment)
        XCTAssertEqual(editor.notice, .saveFailed)
        XCTAssertTrue(pickup.pantryReadIsCurrent)
        XCTAssertEqual(pickup.allocation?.demands.first?.allocated, try Rational(3), "Cleanup failure cannot leave the old six units visible as current.")
        let committed = try await f.inventory.inventoryState()
        failRemoval = false
        await editor.retryPending()
        XCTAssertNil(editor.pending); XCTAssertNil(try foodPending.read())
        let recovered = try await f.inventory.inventoryState()
        XCTAssertEqual(recovered, committed)
    }

    func testCanonicalRefreshPreservesExactUncommittedJournalUntilExplicitDiscard() async throws {
        let f = try await fixture(), pickup = await model(f)
        let pantry = try XCTUnwrap(pickup.makePantryModel())
        await pantry.load()
        var lock: OpaquePointer? = try writerLock(f.inventoryURL)
        defer { unlock(&lock) }
        let saved = await note("Pending original", in: pickup); XCTAssertFalse(saved)
        let original = try XCTUnwrap(f.pendingStore.read())
        unlock(&lock)
        XCTAssertNil(pickup.makePantryModel(), "Resolve pending work before opening another editor.")
        let lot = try XCTUnwrap(pantry.snapshot?.lots.first { $0.name == "Freezer wraps" })
        await pantry.prepare(lotID: lot.id, action: .recount("3", .count))
        await pantry.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(pantry.notice, .saved)
        XCTAssertTrue(pickup.hasPendingSave); XCTAssertTrue(pickup.pantryReadIsCurrent)
        XCTAssertEqual(try f.pendingStore.read(), original)
        XCTAssertEqual(pickup.allocation?.demands.first?.allocated, try Rational(3))
        let retried = await pickup.retrySave(); XCTAssertFalse(retried)
        XCTAssertEqual(try f.pendingStore.read(), original, "Refresh cannot rebase the original reviewed submission.")
        await pickup.discardPendingSafely()
        XCTAssertFalse(pickup.hasPendingSave); XCTAssertNil(try f.pendingStore.read())
        XCTAssertTrue(pickup.journey?.notes.isEmpty == true)
        XCTAssertEqual(pickup.allocation?.demands.first?.allocated, try Rational(3))
    }

    func testCheckoutSaveCannotAdoptAnIndependentNewLedgerAsItsReviewedBase() async throws {
        let f = try await fixture(), pickup = await model(f), instant = now
        let originalLedger = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"), clock: { instant },
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        let otherLedger = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"), clock: { instant },
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(originalLedger, otherLedger)
        await originalLedger.open(); await otherLedger.open()
        let originalBasis = try PickupModel.CheckoutLedgerBasis(ledger: originalLedger)
        let changed = await otherLedger.change(key: "independent ledger") { $0.shops.append(ShoppingLedger(title: "New plan")) }
        XCTAssertTrue(changed)
        let before = try await f.inventory.inventoryState()
        let sources = try await f.inventory.list()
        let saved = await pickup.change(reviewedLedger: originalBasis) { value in
            value.notes.append(.init(id: UUID(), text: "Stale checkout", language: "en", createdAt: instant, revision: value.revision))
        }
        XCTAssertFalse(saved); XCTAssertFalse(pickup.hasPendingSave)
        XCTAssertNil(try f.pendingStore.read(), "The stale ledger review must fail before staging a submission.")
        let after = try await f.inventory.inventoryState(), afterSources = try await f.inventory.list()
        XCTAssertEqual(after, before); XCTAssertEqual(afterSources, sources)
        XCTAssertEqual(originalLedger.revision, originalBasis.revision, "The independent writer did not refresh this cached model.")
        let freshBasis = try PickupModel.CheckoutLedgerBasis(ledger: otherLedger)
        let current = await pickup.change(reviewedLedger: freshBasis) { value in
            value.notes.append(.init(id: UUID(), text: "Current checkout", language: "en", createdAt: instant, revision: value.revision))
        }
        XCTAssertTrue(current, pickup.error ?? "")
        XCTAssertEqual(pickup.journey?.notes.last?.text, "Current checkout")
    }

    func testTonightPreferenceRefreshWaitsForShelfAndPublishesOnlyTheNewReview() async throws {
        let f = try await fixture(), pickup = await model(f), meals = TonightMealModel()
        let recipe = MealTemplate(title: "Tortilla bowls", ingredients: [MealIngredient(name: "Wraps", quantity: try q(2))])
        let before = LedgerWorkspace(mealTemplates: [recipe])
        var after = before
        var preferences = MealPreferenceSettings()
        preferences.availableAppliances = []
        try after.dinnerPlanning.updateMealPreferences(preferences, expectedRevision: nil)
        func reload(_ workspace: LedgerWorkspace, revision: Int64) async {
            await meals.refresh(authorize: { true }) {
                guard await pickup.refreshPantryStock(waitForShelf: true), let context = try pickup.pantryReviewContext() else {
                    throw TonightMealModel.Failure.unavailable
                }
                return try TonightMealModel.input(workspace: workspace, ledgerRevision: revision, context: context, sources: [])
            }
        }

        let shelf = try f.gate.beginExclusiveWrite()
        let first = Task { await reload(before, revision: 1) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !pickup.saving && !meals.failed && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(pickup.saving)
        meals.invalidate()
        let replacement = Task { await reload(after, revision: 2) }
        while !meals.busy && !meals.failed && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(meals.busy)
        XCTAssertNil(meals.input)
        f.gate.endExclusiveWrite(shelf)

        await first.value
        await replacement.value
        XCTAssertFalse(meals.failed)
        XCTAssertEqual(meals.input?.ledgerRevision, 2)
        XCTAssertEqual(meals.input?.workspace.dinnerPlanning.privateMealPreferences, after.dinnerPlanning.privateMealPreferences)
        XCTAssertEqual(meals.reviews.map(\.recipe.id), [recipe.id])
    }

    func testBusyRefreshWithholdsOldCoverageUntilFreshSnapshotCanBeRead() async throws {
        let f = try await fixture(), pickup = await model(f)
        XCTAssertNotNil(pickup.allocation)
        let lease = try f.gate.beginMigration()
        let blocked = await pickup.refreshPantryStock()
        XCTAssertFalse(blocked); XCTAssertFalse(pickup.pantryReadIsCurrent)
        XCTAssertNil(pickup.allocation, "A failed refresh must not silently display old confirmed coverage.")
        f.gate.endMigration(lease)
        let refreshed = await pickup.refreshPantryStock()
        XCTAssertTrue(refreshed); XCTAssertTrue(pickup.pantryReadIsCurrent)
        XCTAssertEqual(pickup.allocation?.demands.first?.allocated, try Rational(6))
    }

    func testCanonicalRefreshAfterPrivateAccessLossClearsVisibleFood() async throws {
        let f = try await fixture(), instant = now
        var allowed = true
        let pickup = PickupModel(store: f.inventory, clock: { instant }, pantry: .init(ledger: f.ledger,
            pendingStore: f.pendingStore, gate: f.gate, authorize: { allowed }))
        f.cleanup.track(pickup)
        await pickup.load(); XCTAssertNotNil(pickup.allocation)
        allowed = false
        let refreshed = await pickup.refreshPantryStock()
        XCTAssertFalse(refreshed); XCTAssertFalse(pickup.ready); XCTAssertFalse(pickup.pantryReadIsCurrent)
        XCTAssertTrue(pickup.pantryIsActive, "Private access loss must not select legacy stock readers after cutover.")
        XCTAssertTrue(pickup.journeys.isEmpty); XCTAssertNil(pickup.pantrySnapshot)
        XCTAssertNil(pickup.allocation); XCTAssertNil(pickup.makePantryModel())
    }
}
