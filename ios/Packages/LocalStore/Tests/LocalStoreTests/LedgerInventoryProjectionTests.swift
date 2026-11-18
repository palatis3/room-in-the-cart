import XCTest
import Foundation
import CSQLite
@testable import LocalStore

final class LedgerInventoryProjectionTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("ledger.sqlite") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func binding(_ store: LedgerStore, id: UUID = UUID()) -> LedgerInventoryProjectionBinding {
        .init(ledgerWorkspaceID: store.workspaceID, projectionID: id, inventoryWorkspaceID: UUID(),
              inventoryOperationID: UUID(), kind: "pantry-reservation:v1", targetID: UUID())
    }
    private func apply(_ store: LedgerStore, binding: LedgerInventoryProjectionBinding, payload: Data = Data([1]),
                       request: Data = Data([7]), base: Int64 = 0) async throws -> LedgerInventoryProjectionReceipt {
        try await store.applyInventoryProjection(binding: binding, request: request, payload: payload,
            expectedRevision: base, savedAt: Date(timeIntervalSince1970: 100))
    }

    func testOptInMigrationPreservesOrdinarySnapshotsAndDefaultRemainsVersionTwo() async throws {
        let plain = try LedgerStore(url: url), operation = UUID()
        let original = try await plain.save(payload: Data([3, 8]), expectedRevision: 0, operationID: operation, savedAt: Date())
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
        do { _ = try await plain.inventoryProjectionReceipt(binding: binding(plain), request: Data([1])); XCTFail("not opted in") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .inventoryProjectionDisabled) }
        try await plain.close()
        let enabled = try LedgerStore(url: url, inventoryProjectionsEnabled: true)
        XCTAssertEqual(enabled.workspaceID, original.workspaceID)
        let loaded = try await enabled.load(); XCTAssertEqual(loaded, original)
        let replay = try await enabled.save(payload: original.payload, expectedRevision: 0, operationID: operation, savedAt: Date())
        XCTAssertEqual(replay, original)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 3)
        try await enabled.close()
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { XCTAssertEqual($0 as? LedgerStoreError, .unsupportedSchema(3)) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLostCompletionLookupAndRetryAfterLaterEditsNeverRestoreOldSnapshot() async throws {
        let store = try LedgerStore(url: url, inventoryProjectionsEnabled: true), key = binding(store)
        let receipt = try await apply(store, binding: key)
        _ = try await store.save(payload: Data([2]), expectedRevision: 1, operationID: UUID(), savedAt: Date())
        let later = try await store.save(payload: Data([3]), expectedRevision: 2, operationID: UUID(), savedAt: Date())
        try await store.close()
        let reopened = try LedgerStore(url: url, inventoryProjectionsEnabled: true)
        let found = try await reopened.inventoryProjectionReceipt(binding: key, request: Data([7]))
        XCTAssertEqual(found, receipt)
        let replay = try await reopened.applyInventoryProjection(binding: key, request: Data([7]), payload: Data([1]),
            expectedRevision: 0, savedAt: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(replay, receipt)
        let current = try await reopened.load(); XCTAssertEqual(current, later)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_inventory_projections"), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 3)
        try await reopened.close()
    }

    func testChangedScopeRequestPayloadAndBaseConflictRatherThanReapply() async throws {
        let store = try LedgerStore(url: url, inventoryProjectionsEnabled: true), key = binding(store)
        _ = try await apply(store, binding: key)
        let changedBindings = [
            LedgerInventoryProjectionBinding(ledgerWorkspaceID: key.ledgerWorkspaceID, projectionID: key.projectionID,
                inventoryWorkspaceID: UUID(), inventoryOperationID: key.inventoryOperationID, kind: key.kind, targetID: key.targetID),
            LedgerInventoryProjectionBinding(ledgerWorkspaceID: key.ledgerWorkspaceID, projectionID: key.projectionID,
                inventoryWorkspaceID: key.inventoryWorkspaceID, inventoryOperationID: UUID(), kind: key.kind, targetID: key.targetID),
            LedgerInventoryProjectionBinding(ledgerWorkspaceID: key.ledgerWorkspaceID, projectionID: key.projectionID,
                inventoryWorkspaceID: key.inventoryWorkspaceID, inventoryOperationID: key.inventoryOperationID, kind: "cooking:v1", targetID: key.targetID),
            LedgerInventoryProjectionBinding(ledgerWorkspaceID: key.ledgerWorkspaceID, projectionID: key.projectionID,
                inventoryWorkspaceID: key.inventoryWorkspaceID, inventoryOperationID: key.inventoryOperationID, kind: key.kind, targetID: UUID())]
        for changed in changedBindings {
            do { _ = try await store.inventoryProjectionReceipt(binding: changed, request: Data([7])); XCTFail("changed binding") }
            catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        }
        do { _ = try await store.inventoryProjectionReceipt(binding: key, request: Data([9])); XCTFail("changed request") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        for (payload, base) in [(Data([2]), Int64(0)), (Data([1]), Int64(1))] {
            do { _ = try await apply(store, binding: key, payload: payload, base: base); XCTFail("changed prepared write") }
            catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        }
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await store.close()
    }

    func testAlternateProjectionIDCannotDuplicateTheSameInventoryEffect() async throws {
        let store = try LedgerStore(url: url, inventoryProjectionsEnabled: true), key = binding(store)
        _ = try await apply(store, binding: key)
        let alternate = LedgerInventoryProjectionBinding(ledgerWorkspaceID: key.ledgerWorkspaceID, projectionID: UUID(),
            inventoryWorkspaceID: key.inventoryWorkspaceID, inventoryOperationID: key.inventoryOperationID, kind: key.kind, targetID: key.targetID)
        do { _ = try await apply(store, binding: alternate, base: 1); XCTFail("alternate ID duplicate") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        do { _ = try await store.inventoryProjectionReceipt(binding: alternate, request: Data([7])); XCTFail("cannot silently adopt another receipt") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await store.close()
    }

    func testBindingWriteFailureRollsBackSnapshotAndCanRetryAfterRestart() async throws {
        let store = try LedgerStore(url: url, inventoryProjectionsEnabled: true), key = binding(store)
        try sql("CREATE TRIGGER fail_projection_binding BEFORE INSERT ON ledger_inventory_projections BEGIN SELECT RAISE(ABORT, 'binding failure'); END")
        do { _ = try await apply(store, binding: key); XCTFail("binding failure must rollback ledger") }
        catch LedgerStoreError.database { }
        let current = try await store.load(); XCTAssertNil(current)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        try await store.close()
        try sql("DROP TRIGGER fail_projection_binding")
        let reopened = try LedgerStore(url: url, inventoryProjectionsEnabled: true)
        let missing = try await reopened.inventoryProjectionReceipt(binding: key, request: Data([7])); XCTAssertNil(missing)
        let receipt = try await apply(reopened, binding: key); XCTAssertEqual(receipt.revision, 1)
        try await reopened.close()
    }

    func testNoReceiptWithStaleBaseDoesNotWriteAndOrdinarySaveCannotAdoptProjectionID() async throws {
        let ordinary = try LedgerStore(url: url)
        let store = try LedgerStore(url: url, inventoryProjectionsEnabled: true), key = binding(store)
        let receipt = try await apply(store, binding: key)
        do { _ = try await ordinary.save(payload: Data([1]), expectedRevision: 0, operationID: key.projectionID, savedAt: Date()); XCTFail("stale actor must respect binding") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        let another = binding(store)
        do { _ = try await apply(store, binding: another); XCTFail("new stale base") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .staleRevision(expected: 0, actual: receipt.revision)) }
        let missing = try await store.inventoryProjectionReceipt(binding: another, request: Data([7])); XCTAssertNil(missing)
        let ordinaryID = UUID()
        _ = try await ordinary.save(payload: Data([4]), expectedRevision: 1, operationID: ordinaryID, savedAt: Date())
        do { _ = try await apply(store, binding: binding(store, id: ordinaryID), base: 2); XCTFail("ordinary save is not a projection receipt") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        try await ordinary.close(); try await store.close()
    }

    func testWholeLedgerErasurePurgesBindingsAndRejectsOldOriginAndRetiredID() async throws {
        let staleOrdinary = try LedgerStore(url: url)
        let store = try LedgerStore(url: url, inventoryProjectionsEnabled: true), key = binding(store)
        _ = try await apply(store, binding: key)
        let erased = try await staleOrdinary.eraseWorkspace(workspaceID: store.workspaceID, expectedRevision: 1, operationID: UUID(), at: Date())
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_inventory_projections"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_retired_operations"), 1)
        do { _ = try await store.inventoryProjectionReceipt(binding: key, request: Data([7])); XCTFail("old actor origin") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        try await staleOrdinary.close(); try await store.close()
        let reopened = try LedgerStore(url: url, inventoryProjectionsEnabled: true)
        XCTAssertEqual(reopened.workspaceID, erased.replacementWorkspaceID)
        do { _ = try await reopened.inventoryProjectionReceipt(binding: key, request: Data([7])); XCTFail("old binding on new origin") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        let rebound = LedgerInventoryProjectionBinding(ledgerWorkspaceID: reopened.workspaceID, projectionID: key.projectionID,
            inventoryWorkspaceID: key.inventoryWorkspaceID, inventoryOperationID: key.inventoryOperationID, kind: key.kind, targetID: key.targetID)
        do { _ = try await apply(reopened, binding: rebound); XCTFail("retired operation rebound") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        let newCurrent = try await reopened.load(); XCTAssertNil(newCurrent)
        try await reopened.close()
    }

    func testBindingImmutableAndCorruptOrFutureSchemaRefusesWithoutRewriting() async throws {
        let store = try LedgerStore(url: url, inventoryProjectionsEnabled: true), key = binding(store)
        _ = try await apply(store, binding: key)
        XCTAssertThrowsError(try sql("UPDATE ledger_inventory_projections SET kind = 'other'"))
        XCTAssertThrowsError(try sql("DELETE FROM ledger_inventory_projections"))
        try await store.close()
        try sql("DROP TRIGGER ledger_projection_immutable_update")
        let corrupted = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url, inventoryProjectionsEnabled: true))
        XCTAssertEqual(try Data(contentsOf: url), corrupted)
        try sql("PRAGMA user_version = 50")
        let future = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url, inventoryProjectionsEnabled: true)) { XCTAssertEqual($0 as? LedgerStoreError, .unsupportedSchema(50)) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testProjectionMigrationFailureRetainsVersionTwoSchemaAndOriginalSnapshot() async throws {
        let store = try LedgerStore(url: url)
        let original = try await store.save(payload: Data([8, 3]), expectedRevision: 0, operationID: UUID(), savedAt: Date())
        try await store.close()
        // Fail after the new table and first trigger were created, exercising migration rollback.
        try sql("CREATE TRIGGER ledger_projection_immutable_update BEFORE UPDATE ON ledger_workspace BEGIN SELECT 1; END")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url, inventoryProjectionsEnabled: true))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name = 'ledger_inventory_projections'"), 0)
        let unchanged = try LedgerStore(url: url)
        let loaded = try await unchanged.load(); XCTAssertEqual(loaded, original)
        try await unchanged.close()
        try sql("DROP TRIGGER ledger_projection_immutable_update")
        let upgraded = try LedgerStore(url: url, inventoryProjectionsEnabled: true)
        let retained = try await upgraded.load(); XCTAssertEqual(retained, original)
        try await upgraded.close()
    }

    private enum Failure: Error { case sqlite }
    private func sql(_ query: String) throws {
        var db: OpaquePointer?; guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure.sqlite }; defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
    }
    private func scalar(_ query: String) throws -> Int64 {
        var db: OpaquePointer?; guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure.sqlite }; defer { sqlite3_close(db) }
        var row: OpaquePointer?; guard sqlite3_prepare_v2(db, query, -1, &row, nil) == SQLITE_OK else { throw Failure.sqlite }; defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw Failure.sqlite }; return sqlite3_column_int64(row, 0)
    }
}
