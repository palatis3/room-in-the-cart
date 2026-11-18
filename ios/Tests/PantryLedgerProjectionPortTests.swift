import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryLedgerProjectionPortTests: XCTestCase {
    private struct Document: Codable { let formatVersion: Int; let workspace: LedgerWorkspace }
    private struct Request: Codable, Equatable { let title: String }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let inventory: ComparisonStore
        let ledger: LedgerStore
        let gate: PantryMutationGate
        let source: PantryLedgerProjectionPort.Source
        let payload: Data
    }
    private func payload(_ workspace: LedgerWorkspace) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(formatVersion: 1, workspace: workspace))
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(inventory, ledger)
        let token = try await inventory.inventorySourceToken()
        _ = try await inventory.commitInventory(.init(workspaceID: inventory.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([0]), mode: .activate, sourceToken: token))
        let operationID = UUID(), intentID = UUID(), targetID = UUID()
        var workspace = LedgerWorkspace(); workspace.shops = [ShoppingLedger(id: targetID, title: "Projected")]
        workspace.selectedShopID = targetID
        let bytes = try payload(workspace)
        let request = try JSONEncoder().encode(Request(title: "Projected"))
        let binding = LedgerInventoryProjectionBinding(ledgerWorkspaceID: ledger.workspaceID, projectionID: UUID(),
            inventoryWorkspaceID: inventory.workspaceID, inventoryOperationID: operationID, kind: "test.shop", targetID: targetID)
        let intent = try PantryLedgerProjectionPort.intentRecord(id: intentID, binding: binding,
            canonicalRequest: request, payload: bytes, expectedRevision: 0, savedAt: now)
        let lotID = UUID()
        let command = InventoryCommand(id: operationID, originID: inventory.workspaceID, lotID: lotID, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(InventoryLotSeed(foodID: UUID(), name: "Wraps",
                source: .manual(originID: inventory.workspaceID, sourceID: lotID), location: .cupboard,
                unit: .count, count: .exact(.init(amount: try Rational(8), unit: .count, originalLiteral: "8"))), observationID: UUID()))
        let prepared = try InventoryEngine.prepare(command, current: nil, at: now)
        let foodWrites = try PantryPersistenceCodec.writes(prepared)
        let originalRequest = try PantryPersistenceCodec.request(command, inventoryRevision: 1)
        _ = try await inventory.commitInventory(.init(workspaceID: inventory.workspaceID, operationID: operationID, expectedRevision: 1,
            request: originalRequest, writes: foodWrites + [.init(record: intent, expectedRevision: 0)]), at: now)
        let food = try await PantryRepository(store: inventory, authorize: { true }).load(at: now)
        XCTAssertEqual(food.lots.map(\.id), [lotID])
        return Fixture(directory: directory, cleanup: cleanup, inventory: inventory, ledger: ledger, gate: PantryMutationGate(),
            source: .init(inventoryWorkspaceID: inventory.workspaceID, inventoryOperationID: operationID,
                inventoryRequest: originalRequest, sourceIntentID: intentID), payload: bytes)
    }
    private func validate(_ intent: PantryLedgerProjectionPort.IntentBinding, _ current: LedgerWorkspace, _ candidate: LedgerWorkspace) throws {
        let request = try JSONDecoder().decode(Request.self, from: intent.canonicalRequest)
        guard current.shops.isEmpty, candidate.shops.count == 1, candidate.shops[0].id == intent.binding.targetID,
              candidate.shops[0].title == request.title else { throw PantryLedgerProjectionPort.Failure.invalidBinding }
    }
    private func port(_ f: Fixture, authorize: @escaping (UUID, UUID) -> Bool = { _, _ in true }) -> PantryLedgerProjectionPort {
        PantryLedgerProjectionPort(ledger: f.ledger, inventory: f.inventory, gate: f.gate,
            authorize: authorize, validateNewProjection: validate)
    }

    func testRestartRecoveryRecognizesReceiptBeforeDeletedTargetAndReloadsCurrentHead() async throws {
        let f = try await fixture(), adapter = port(f)
        let absent = try await adapter.recover(f.source); XCTAssertNil(absent)
        let applied = try await adapter.apply(f.source, payload: f.payload); XCTAssertFalse(applied.replayed)
        let later = try payload(LedgerWorkspace())
        _ = try await f.ledger.save(payload: later, expectedRevision: 1, operationID: UUID(), savedAt: now)
        let reopened = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(reopened)
        let replay = PantryLedgerProjectionPort(ledger: reopened, inventory: f.inventory, gate: f.gate, authorize: { _, _ in true },
            validateNewProjection: { _, _, _ in XCTFail("replay must not validate a deleted target") })
        let recovery = try await replay.recover(f.source)
        let recovered = try XCTUnwrap(recovery)
        XCTAssertTrue(recovered.replayed); XCTAssertEqual(recovered.current.revision, 2)
        XCTAssertEqual(recovered.current.payload, later); XCTAssertTrue(recovered.workspace.shops.isEmpty)
        do { _ = try await replay.apply(f.source, payload: Data()); XCTFail("changed apply payload even after commit") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        let appliedAgain = try await replay.apply(f.source, payload: f.payload)
        XCTAssertEqual(appliedAgain.current.payload, later)
    }

    func testUnboundReceiptAndChangedBindingRecordCannotAuthorizeProjection() async throws {
        let f = try await fixture(), adapter = port(f)
        let unbound = PantryLedgerProjectionPort.Source(inventoryWorkspaceID: f.inventory.workspaceID,
            inventoryOperationID: f.source.inventoryOperationID, inventoryRequest: f.source.inventoryRequest, sourceIntentID: UUID())
        do { _ = try await adapter.apply(unbound, payload: f.payload); XCTFail("receipt without this binding") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .invalidBinding) }
        let storedIntent = try await f.inventory.inventoryRecord(.init(.intent, f.source.sourceIntentID))
        let row = try XCTUnwrap(storedIntent)
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(), expectedRevision: 2,
            request: Data([2]), writes: [.init(record: .init(key: row.key, revision: 2, payload: row.payload), expectedRevision: 1)]))
        do { _ = try await adapter.recover(f.source); XCTFail("binding revision was replaced") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .invalidBinding) }
        let current = try await f.ledger.load(); XCTAssertNil(current)
    }

    func testChangedPayloadAndStaleBaseNeverOverwriteLedger() async throws {
        let f = try await fixture(), adapter = port(f)
        do { _ = try await adapter.apply(f.source, payload: payload(LedgerWorkspace())); XCTFail("changed body") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        let refusing = PantryLedgerProjectionPort(ledger: f.ledger, inventory: f.inventory, gate: f.gate,
            authorize: { _, _ in true }, validateNewProjection: { _, _, _ in throw PantryLedgerProjectionPort.Failure.invalidBinding })
        do { _ = try await refusing.apply(f.source, payload: f.payload); XCTFail("request/target validator must authorize new projection") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .invalidBinding) }
        let unchanged = try await f.ledger.load(); XCTAssertNil(unchanged)
        let later = try payload(LedgerWorkspace())
        _ = try await f.ledger.save(payload: later, expectedRevision: 0, operationID: UUID(), savedAt: now)
        do { _ = try await adapter.apply(f.source, payload: f.payload); XCTFail("stale original base") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .staleRevision(expected: 0, actual: 1)) }
        let current = try await f.ledger.load(); XCTAssertEqual(current?.payload, later)
    }

    func testRevocationAndInventoryErasureWinOverCommittedReceipt() async throws {
        let f = try await fixture()
        var authorized = true
        let adapter = port(f, authorize: { inventory, ledger in
            authorized && inventory == f.inventory.workspaceID && ledger == f.ledger.workspaceID
        })
        _ = try await adapter.apply(f.source, payload: f.payload)
        authorized = false
        do { _ = try await adapter.recover(f.source); XCTFail("revoked receipt disclosure") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .unauthorized) }
        authorized = true
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(), expectedRevision: 2,
            request: Data([3]), erasures: [.init(key: .init(.intent, f.source.sourceIntentID), expectedRevision: 1)]))
        do { _ = try await adapter.recover(f.source); XCTFail("retired source receipt") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    }

    func testLedgerErasureRejectsOldProjectionOnBothOldAndReplacementActors() async throws {
        let f = try await fixture(), adapter = port(f)
        _ = try await adapter.apply(f.source, payload: f.payload)
        _ = try await f.ledger.eraseWorkspace(workspaceID: f.ledger.workspaceID, expectedRevision: 1, operationID: UUID(), at: now)
        do { _ = try await adapter.recover(f.source); XCTFail("retired ledger") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        let replacement = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(replacement)
        let newPort = PantryLedgerProjectionPort(ledger: replacement, inventory: f.inventory, gate: f.gate,
            authorize: { _, _ in true }, validateNewProjection: validate)
        do { _ = try await newPort.recover(f.source); XCTFail("old binding on replacement") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .wrongOrigin) }
    }

    func testModelRetainsUnrecognizedProjectionAndBlocksConflictingOrdinaryChanges() async throws {
        let f = try await fixture(), adapter = port(f)
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(model); await model.open()
        let absent = try await model.recoverPreparedProjection(f.source, using: adapter); XCTAssertNil(absent)
        XCTAssertTrue(model.hasPendingPantryProjection)
        let blocked = await model.startShop(title: "Conflicting"); XCTAssertFalse(blocked)
        do { _ = try await model.reviewWholeLedgerDeletion(); XCTFail("pending projection") }
        catch LedgerDeletionError.pendingSave { }
        _ = try await model.applyPreparedProjection(f.source, payload: f.payload, using: adapter)
        XCTAssertFalse(model.hasPendingPantryProjection); XCTAssertEqual(model.revision, 1)
        XCTAssertEqual(model.workspace.shops.first?.title, "Projected")
    }

    func testMigrationLeaseBlocksModelWritesAndDeletionBeforeCreatingJournal() async throws {
        let f = try await fixture()
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(model); await model.open()
        let review = try await model.reviewWholeLedgerDeletion()
        let lease = try f.gate.beginMigration()
        let blocked = await model.startShop(title: "Blocked"); XCTAssertFalse(blocked)
        do { _ = try await model.eraseWholeLedger(review); XCTFail("migration lease") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        XCTAssertFalse(model.hasPendingLedgerDeletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("ledger.sqlite.erase-intent.json").path))
        f.gate.endMigration(lease)
        _ = try await model.eraseWholeLedger(review)
        try await model.finishWholeLedgerDeletion()
        XCTAssertTrue(model.ready)
        let saved = await model.startShop(title: "Replacement"); XCTAssertTrue(saved)
        let reopened = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(reopened); await reopened.open()
        XCTAssertTrue(reopened.ready); XCTAssertEqual(reopened.shop?.title, "Replacement")
    }

    func testDefaultLegacyModelRetainsOrdinaryPendingRetryWhileMigrationHoldsLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), gate = PantryMutationGate()
        let url = directory.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: url, mutationGate: gate)
        await model.open()
        let ordinary = try LedgerStore(url: url)
        cleanup.track(model, ordinary)
        _ = try await ordinary.save(payload: payload(LedgerWorkspace()), expectedRevision: 0, operationID: UUID(), savedAt: now)
        let stale = await model.startShop(title: "Pending"); XCTAssertFalse(stale); XCTAssertTrue(model.hasPendingSave)
        let lease = try gate.beginMigration()
        let retry = await model.retrySave(); XCTAssertFalse(retry); XCTAssertTrue(model.hasPendingSave)
        gate.endMigration(lease)
        await model.discardPendingSave()
        XCTAssertFalse(model.hasPendingSave); XCTAssertEqual(model.revision, 1)
        let saved = await model.startShop(title: "Reviewed"); XCTAssertTrue(saved)
        let head = try await ordinary.load(); XCTAssertEqual(head?.revision, 2)
    }

    func testCompetingReceiptBetweenLookupAndApplyMustStillMatchImmutableBindingTime() async throws {
        let f = try await fixture()
        let ledger = f.ledger, bytes = f.payload
        let adapter = PantryLedgerProjectionPort(ledger: ledger, inventory: f.inventory, gate: f.gate,
            authorize: { _, _ in true }, validateNewProjection: { intent, _, _ in
                // The callback runs after the initial receipt lookup. Await the independent
                // actor's commit before continuing, without blocking the main thread.
                _ = try await ledger.applyInventoryProjection(binding: intent.binding, request: intent.canonicalRequest,
                    payload: bytes, expectedRevision: intent.expectedRevision, savedAt: intent.savedAt.addingTimeInterval(1))
            })
        do { _ = try await adapter.apply(f.source, payload: bytes); XCTFail("racing receipt has a different bound time") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        let current = try await ledger.load()
        XCTAssertEqual(current?.revision, 1); XCTAssertEqual(current?.savedAt, now.addingTimeInterval(1))
        do { _ = try await adapter.recover(f.source); XCTFail("the mismatched receipt remains unresolved") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
    }

    func testInvalidUnauthorizedAndMissingPreflightsDoNotLatchUnrelatedLedger() async throws {
        let f = try await fixture()
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(model); await model.open()
        let denied = port(f, authorize: { _, _ in false })
        do { _ = try await model.recoverPreparedProjection(f.source, using: denied); XCTFail("unauthorized") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .unauthorized) }
        XCTAssertFalse(model.hasPendingPantryProjection)
        let adapter = port(f)
        let wrong = PantryLedgerProjectionPort.Source(inventoryWorkspaceID: UUID(), inventoryOperationID: f.source.inventoryOperationID,
            inventoryRequest: f.source.inventoryRequest, sourceIntentID: f.source.sourceIntentID)
        do { _ = try await model.recoverPreparedProjection(wrong, using: adapter); XCTFail("wrong origin") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .wrongOrigin) }
        XCTAssertFalse(model.hasPendingPantryProjection)
        let missing = PantryLedgerProjectionPort.Source(inventoryWorkspaceID: f.inventory.workspaceID, inventoryOperationID: UUID(),
            inventoryRequest: f.source.inventoryRequest, sourceIntentID: f.source.sourceIntentID)
        do { _ = try await model.recoverPreparedProjection(missing, using: adapter); XCTFail("missing operation") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .missingInventoryOperation) }
        XCTAssertFalse(model.hasPendingPantryProjection)
        let saved = await model.startShop(title: "Ordinary work remains available"); XCTAssertTrue(saved)
    }

    func testExplicitNeedsReviewReleasesStaleProjectionAndDurablyPreventsSilentReapply() async throws {
        let f = try await fixture(), adapter = port(f)
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(model); await model.open()
        _ = try await model.recoverPreparedProjection(f.source, using: adapter)
        let later = try payload(LedgerWorkspace())
        _ = try await f.ledger.save(payload: later, expectedRevision: 0, operationID: UUID(), savedAt: now)
        do { _ = try await model.applyPreparedProjection(f.source, payload: f.payload, using: adapter); XCTFail("stale") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .staleRevision(expected: 0, actual: 1)) }
        let disposition = try await model.reconcilePreparedProjection(using: adapter)
        guard case .needsReview = disposition else { return XCTFail("explicit needs-review disposition") }
        XCTAssertFalse(model.hasPendingPantryProjection); XCTAssertEqual(model.revision, 1)
        let saved = await model.startShop(title: "Later ordinary work"); XCTAssertTrue(saved)
        let restarted = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(restarted); await restarted.open()
        do { _ = try await restarted.recoverPreparedProjection(f.source, using: adapter); XCTFail("durable disposition") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .needsReview) }
        XCTAssertFalse(restarted.hasPendingPantryProjection)
        do { _ = try await adapter.apply(f.source, payload: f.payload); XCTFail("no silent delayed application") }
        catch { XCTAssertEqual(error as? PantryLedgerProjectionPort.Failure, .needsReview) }
        let food = try await PantryRepository(store: f.inventory, authorize: { true }).load(at: now)
        XCTAssertEqual(food.lots.count, 1)
    }

    func testReconciliationKeepsAmbiguousIOPendingAndRecognizesCommittedEffectBeforeSourceRetirement() async throws {
        let f = try await fixture(), adapter = port(f)
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(model); await model.open()
        _ = try await model.recoverPreparedProjection(f.source, using: adapter)
        try await f.ledger.close()
        do { _ = try await model.reconcilePreparedProjection(using: adapter); XCTFail("closed store is not absence") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .closed) }
        XCTAssertTrue(model.hasPendingPantryProjection)
        let reopened = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(reopened)
        let recoveredPort = PantryLedgerProjectionPort(ledger: reopened, inventory: f.inventory, gate: f.gate,
            authorize: { _, _ in true }, validateNewProjection: validate)
        _ = try await recoveredPort.apply(f.source, payload: f.payload)
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(), expectedRevision: 2,
            request: Data([4]), erasures: [.init(key: .init(.intent, f.source.sourceIntentID), expectedRevision: 1)]))
        let disposition = try await model.reconcilePreparedProjection(using: recoveredPort)
        guard case .applied = disposition else { return XCTFail("committed receipt precedes source erasure") }
        XCTAssertFalse(model.hasPendingPantryProjection); XCTAssertEqual(model.revision, 1)
    }

    func testUnappliedRetiredSourceAndRetiredLedgerHaveExplicitRecoveryPaths() async throws {
        let f = try await fixture(), adapter = port(f)
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(model); await model.open()
        _ = try await model.recoverPreparedProjection(f.source, using: adapter)
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(), expectedRevision: 2,
            request: Data([5]), erasures: [.init(key: .init(.intent, f.source.sourceIntentID), expectedRevision: 1)]))
        let sourceResult = try await model.reconcilePreparedProjection(using: adapter)
        guard case .sourceRetired = sourceResult else { return XCTFail("retirement proof") }
        XCTAssertFalse(model.hasPendingPantryProjection)
        let saved = await model.startShop(title: "After source retirement"); XCTAssertTrue(saved)

        let g = try await fixture(), otherPort = port(g)
        let other = LedgerModel(databaseURL: g.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: g.gate)
        g.cleanup.track(other); await other.open()
        _ = try await other.recoverPreparedProjection(g.source, using: otherPort)
        _ = try await g.ledger.eraseWorkspace(workspaceID: g.ledger.workspaceID, expectedRevision: 0, operationID: UUID(), at: now)
        let ledgerResult = try await other.reconcilePreparedProjection(using: otherPort)
        guard case .ledgerRetired = ledgerResult else { return XCTFail("ledger retirement proof") }
        XCTAssertTrue(other.ready); XCTAssertFalse(other.hasPendingPantryProjection)
        XCTAssertNotEqual(other.sourceWorkspaceID, g.ledger.workspaceID)
        let replacementSaved = await other.startShop(title: "Replacement"); XCTAssertTrue(replacementSaved)
    }

    func testExclusiveProjectionLeaseExcludesAppOwnedWritesErasureAndMigration() async throws {
        let f = try await fixture()
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(model); await model.open()
        let review = try await model.reviewWholeLedgerDeletion()
        let lease = try f.gate.beginExclusiveWrite()
        let blocked = await model.startShop(title: "Blocked"); XCTAssertFalse(blocked)
        do { _ = try await model.eraseWholeLedger(review); XCTFail("exclusive projection") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        do { _ = try f.gate.beginMigration(); XCTFail("exclusive projection") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        f.gate.endExclusiveWrite(lease)
        let adapter = PantryLedgerProjectionPort(ledger: f.ledger, inventory: f.inventory, gate: f.gate,
            authorize: { _, _ in true }, validateNewProjection: { _, _, _ in
                do { _ = try f.gate.beginWrite(); XCTFail("port must hold exclusive lease through target validation") }
                catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
            })
        _ = try await adapter.apply(f.source, payload: f.payload)
        let ordinary = try f.gate.beginWrite()
        do { _ = try f.gate.beginExclusiveWrite(); XCTFail("existing writer excludes projection") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        f.gate.endWrite(ordinary)
    }

    func testExactCommittedReceiptWinsOverExistingNeedsReviewMarker() async throws {
        let f = try await fixture(), adapter = port(f)
        let validated = try await adapter.preflight(f.source)
        let disposition = try await adapter.reconcile(validated)
        guard case .needsReview = disposition else { return XCTFail("unapplied reviewed disposition") }
        let row = try await f.inventory.inventoryRecord(.init(.intent, f.source.sourceIntentID))
        let intent = try JSONDecoder().decode(PantryLedgerProjectionPort.IntentBinding.self, from: XCTUnwrap(row).payload)
        // Raw store access deliberately models an external writer outside the app's gate.
        _ = try await f.ledger.applyInventoryProjection(binding: intent.binding, request: intent.canonicalRequest,
            payload: f.payload, expectedRevision: intent.expectedRevision, savedAt: intent.savedAt)
        _ = try await adapter.preflight(f.source)
        let recovered = try await adapter.recover(f.source)
        XCTAssertEqual(recovered?.current.revision, 1)
        let reconciled = try await adapter.reconcile(validated)
        guard case .applied = reconciled else { return XCTFail("durable receipt must not be hidden by disposition") }
    }
}
