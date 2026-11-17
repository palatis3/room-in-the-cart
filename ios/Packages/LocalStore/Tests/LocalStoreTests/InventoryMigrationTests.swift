import XCTest
import Foundation
import CSQLite
@testable import LocalStore

final class InventoryMigrationTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("pickup.sqlite") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func lot() -> InventoryRecord { .init(key: .init(.lot, UUID()), revision: 1, payload: Data([1, 2, 3])) }
    private func chunks(_ records: [InventoryRecord]) -> [InventoryMigrationChunk] {
        stride(from: 0, to: records.count, by: 200).enumerated().map { index, start in
            .init(index: index, records: Array(records[start..<min(start + 200, records.count)]))
        }
    }
    private func plan(_ store: ComparisonStore, chunks: [InventoryMigrationChunk], id: UUID = UUID()) async throws -> InventoryMigrationPlan {
        var digest = InventoryMigrationManifest.initialDigest
        for chunk in chunks { digest = try InventoryMigrationManifest.appending(chunk, to: digest) }
        let state = try await store.inventoryState(), token = try await store.inventorySourceToken()
        return .init(migrationID: id, workspaceID: store.workspaceID, expectedRevision: state.revision, sourceToken: token,
            reviewContext: Data("reviewed ledger origin and migration mapping v1".utf8), expectedChunkCount: chunks.count,
            expectedRecordCount: chunks.reduce(0) { $0 + $1.records.count }, manifestDigest: digest)
    }

    func testMoreThan256RecordsStageAcrossRestartAndActivateOnceWithoutChangingSources() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let initiallyPending = try await store.inventoryPendingMigration(); XCTAssertNil(initiallyPending)
        let saved = try await store.save(id: UUID(), title: "Original source", payload: Data([7, 8, 9]), savedAt: Date())
        let lots = (0..<300).map { _ in lot() }
        // The linked observation arrives before its parent lot's later chunk; it must remain hidden until complete.
        let observation = InventoryRecord(key: .init(.observation, UUID()), revision: 1, payload: Data([4]), lotID: lots.last!.key.id)
        let values = chunks([observation] + lots), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        do { _ = try await store.inventoryRecords(kind: .lot); XCTFail("staged stock must not be physical") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryInactive) }
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0, request: Data([1]),
            writes: [.init(record: lot(), expectedRevision: 0)])); XCTFail("ordinary inventory mutation during staging") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        do { _ = try await store.finishInventoryMigration(id: reviewed.migrationID); XCTFail("missing chunk") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let progress = try await reopened.inventoryMigrationProgress(id: reviewed.migrationID)
        XCTAssertEqual(progress?.nextChunk, 1); XCTAssertEqual(progress?.stagedRecordCount, 200)
        XCTAssertEqual(progress?.plan, reviewed)
        let pending = try await reopened.inventoryPendingMigration(); XCTAssertEqual(pending, progress)
        _ = try await reopened.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        _ = try await reopened.stageInventoryMigration(id: reviewed.migrationID, chunk: values[1])
        let receipt = try await reopened.finishInventoryMigration(id: reviewed.migrationID, at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(receipt.migrationID, reviewed.migrationID)
        XCTAssertEqual(receipt.revision, 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 301)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_staged_records"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_migration_keys"), 301)
        let firstPage = try await reopened.inventoryRecords(kind: .lot, limit: 200)
        let secondPage = try await reopened.inventoryRecords(kind: .lot, after: firstPage.last?.key.id, limit: 200)
        XCTAssertEqual(firstPage.count + secondPage.count, 300)
        let source = try await reopened.load(id: saved.id); XCTAssertEqual(source, saved)
        try await reopened.close()
        let final = try ComparisonStore(url: url, inventoryEnabled: true)
        let finishedPending = try await final.inventoryPendingMigration(); XCTAssertNil(finishedPending)
        let retry = try await final.finishInventoryMigration(id: reviewed.migrationID, at: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(retry, receipt)
        let chunkRetry = try await final.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        XCTAssertEqual(chunkRetry.status, .active); XCTAssertEqual(chunkRetry.receipt, receipt)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_operations"), 1)
        try await final.close()
    }

    func testMidStageSourceMutationCancelAndNewIdentityReplacementPreserveOriginals() async throws {
        let writer = try ComparisonStore(url: url)
        let original = try await writer.save(id: UUID(), title: "Original", payload: Data([1]), savedAt: Date())
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let values = chunks((0..<280).map { _ in lot() }), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        let late = try await writer.save(id: UUID(), title: "Added then erased", payload: Data([2]), savedAt: Date())
        _ = try await writer.erase(id: late.id, expectedRevision: 1, operationID: UUID(), at: Date())
        do { _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[1]); XCTFail("source generation changed") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        do { _ = try await store.finishInventoryMigration(id: reviewed.migrationID); XCTFail("stale complete token") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        let stalePending = try await store.inventoryPendingMigration(); XCTAssertEqual(stalePending?.plan, reviewed)
        let cancelled = try await store.cancelInventoryMigration(id: reviewed.migrationID)
        XCTAssertEqual(cancelled.status, .cancelled); XCTAssertNil(cancelled.plan)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let cancelledPending = try await reopened.inventoryPendingMigration(); XCTAssertNil(cancelledPending)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_staged_records"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        let originalAfter = try await reopened.load(id: original.id); XCTAssertEqual(originalAfter, original)
        let oldBegin = try await reopened.beginInventoryMigration(reviewed); XCTAssertEqual(oldBegin.status, .cancelled)
        let replacement = try await plan(reopened, chunks: values)
        _ = try await reopened.beginInventoryMigration(replacement)
        let replacementPending = try await reopened.inventoryPendingMigration(); XCTAssertEqual(replacementPending?.plan, replacement)
        do { _ = try await reopened.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0]); XCTFail("retired migration cannot target replacement") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        for chunk in values { _ = try await reopened.stageInventoryMigration(id: replacement.migrationID, chunk: chunk) }
        _ = try await reopened.finishInventoryMigration(id: replacement.migrationID)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 280)
        let stillOriginal = try await reopened.load(id: original.id); XCTAssertEqual(stillOriginal, original)
        try await writer.close(); try await reopened.close()
    }

    func testChunkIdentityOrderAndDuplicateKeysCannotChangeReviewedManifest() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let values = chunks((0..<270).map { _ in lot() }), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        do { _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[1]); XCTFail("gap") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        let changed = InventoryMigrationChunk(index: 0, records: [lot()])
        do { _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: changed); XCTFail("changed-body replay") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
        let duplicate = InventoryMigrationChunk(index: 1, records: [values[0].records[0]])
        do { _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: duplicate); XCTFail("cross-chunk duplicate key") }
        catch ComparisonStoreError.database { }
        let progress = try await store.inventoryMigrationProgress(id: reviewed.migrationID)
        XCTAssertEqual(progress?.nextChunk, 1); XCTAssertEqual(progress?.stagedRecordCount, 200)
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[1])
        _ = try await store.finishInventoryMigration(id: reviewed.migrationID)
        try await store.close()
    }

    func testFinalWriteFailureRollsBackActivationAndRetainsChunksForExactRetry() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let values = chunks((0..<290).map { _ in lot() }), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        for chunk in values { _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: chunk) }
        try sql("CREATE TRIGGER fail_final_receipt BEFORE INSERT ON inventory_operations BEGIN SELECT RAISE(ABORT, 'receipt failure'); END")
        do { _ = try await store.finishInventoryMigration(id: reviewed.migrationID); XCTFail("failed receipt must rollback all") }
        catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_staged_records"), 290)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_migration_keys"), 0)
        let state = try await store.inventoryState(); XCTAssertFalse(state.active); XCTAssertEqual(state.revision, 0)
        try await store.close()
        try sql("DROP TRIGGER fail_final_receipt")
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        _ = try await reopened.finishInventoryMigration(id: reviewed.migrationID)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 290)
        try await reopened.close()
    }

    func testOrphanFinalGraphFailsAndCanBeReplacedWithoutPartialCanonicalStock() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let orphan = InventoryRecord(key: .init(.reservation, UUID()), revision: 1, payload: Data([5]), lotID: UUID())
        let values = chunks([lot(), orphan]), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        do { _ = try await store.finishInventoryMigration(id: reviewed.migrationID); XCTFail("orphan FK") }
        catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_staged_records"), 2)
        _ = try await store.cancelInventoryMigration(id: reviewed.migrationID)
        let fixed = chunks([values[0].records[0]]), replacement = try await plan(store, chunks: fixed)
        _ = try await store.beginInventoryMigration(replacement)
        _ = try await store.stageInventoryMigration(id: replacement.migrationID, chunk: fixed[0])
        _ = try await store.finishInventoryMigration(id: replacement.migrationID)
        try await store.close()
    }

    func testImportedRecordOrSourceErasurePreventsOldActivationReceiptDisclosure() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let source = try await store.save(id: UUID(), title: "Source", payload: Data([6]), savedAt: Date())
        let record = lot(), values = chunks([record]), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        _ = try await store.finishInventoryMigration(id: reviewed.migrationID)
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([8]),
            comparisons: [.init(action: .erase, id: source.id, expectedRevision: 1)]))
        do { _ = try await store.finishInventoryMigration(id: reviewed.migrationID); XCTFail("retired migration result") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        do { _ = try await store.inventoryMigrationProgress(id: reviewed.migrationID); XCTFail("retired progress receipt") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        try await store.close()
    }

    func testImportedKeyErasureAlonePreventsOldActivationReplay() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let record = lot(), values = chunks([record]), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        _ = try await store.finishInventoryMigration(id: reviewed.migrationID)
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([8]),
            erasures: [.init(key: record.key, expectedRevision: 1)]))
        do { _ = try await store.finishInventoryMigration(id: reviewed.migrationID); XCTFail("retired imported key") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        try await store.close()
    }

    func testChangedStagedPayloadCannotPassFinalManifestVerification() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let values = chunks([lot()]), reviewed = try await plan(store, chunks: values)
        _ = try await store.beginInventoryMigration(reviewed)
        _ = try await store.stageInventoryMigration(id: reviewed.migrationID, chunk: values[0])
        try sql("DROP TRIGGER inventory_staged_update; UPDATE inventory_staged_records SET record = CAST(json_set(CAST(record AS TEXT), '$.payload', 'CQ==') AS BLOB)")
        do { _ = try await store.finishInventoryMigration(id: reviewed.migrationID); XCTFail("valid JSON still has different reviewed bytes") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .corruptRecord) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_staged_records"), 1)
        let state = try await store.inventoryState(); XCTAssertFalse(state.active)
        try await store.close()
    }

    func testSourceTokenPagesRejectAChangedCompleteSourceSet() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        for _ in 0..<4 { _ = try await store.save(id: UUID(), title: "Source", payload: Data([1]), savedAt: Date()) }
        let token = try await store.inventorySourceToken()
        let first = try await store.inventorySourcePage(token: token, limit: 2)
        XCTAssertEqual(first.count, 2)
        _ = try await store.save(id: UUID(), title: "Inserted", payload: Data([1]), savedAt: Date())
        do { _ = try await store.inventorySourcePage(token: token, after: first.last?.id, limit: 2); XCTFail("stale source page") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        try await store.close()
    }

    func testPendingDiscoveryRequiresOptInAndRefusesMultipleStagingHeaders() async throws {
        let ordinary = try ComparisonStore(url: url)
        do { _ = try await ordinary.inventoryPendingMigration(); XCTFail("inventory opt-in required") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryDisabled) }
        try await ordinary.close()
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let reviewed = try await plan(store, chunks: chunks([lot()]))
        _ = try await store.beginInventoryMigration(reviewed)
        try sql("DROP INDEX inventory_one_staging; INSERT INTO inventory_migrations SELECT '\(UUID().uuidString)',digest,plan,status,next_chunk,record_count,chain_digest FROM inventory_migrations")
        do { _ = try await store.inventoryPendingMigration(); XCTFail("ambiguous pending migration") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .corruptRecord) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_migrations WHERE status = 'staging'"), 2)
        try await store.close()
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
