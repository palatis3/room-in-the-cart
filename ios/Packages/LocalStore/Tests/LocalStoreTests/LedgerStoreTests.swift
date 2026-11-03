import XCTest
import Foundation
import CryptoKit
import CSQLite
@testable import LocalStore

final class LedgerStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("ledger.sqlite") }
    private let originalDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testEmptyMigrationAndIndependentWorkspace() async throws {
        try sql("PRAGMA user_version = 0")
        let store = try LedgerStore(url: url)
        let other = try LedgerStore(url: directory.appendingPathComponent("other.sqlite"))
        let empty = try await store.load()
        XCTAssertNil(empty)
        XCTAssertNotEqual(store.workspaceID, other.workspaceID)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_workspace"), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        try await store.close()
        try await other.close()
    }

    func testSaveCloseReopenPreservesExactBytesWorkspaceOperationAndTime() async throws {
        let store = try LedgerStore(url: url)
        let operation = UUID()
        let time = Date(timeIntervalSinceReferenceDate: Double(815_000_000).nextUp)
        let payload = Data([0, 1, 2, 127, 255])
        let saved = try await store.save(payload: payload, expectedRevision: 0, operationID: operation, savedAt: time)
        XCTAssertEqual(saved.workspaceID, store.workspaceID)
        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(saved.operationID, operation)
        XCTAssertEqual(saved.savedAt, time)
        try await store.close()
        let reopened = try LedgerStore(url: url)
        let loaded = try await reopened.load()
        XCTAssertEqual(reopened.workspaceID, store.workspaceID)
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(try scalar("SELECT length(payload) FROM ledger_revisions"), Int64(payload.count))
        try await reopened.close()
    }

    func testConcurrentInitialOpenersShareOneMigratedWorkspace() async throws {
        let location = url
        let barrier = LedgerOpenBarrier(count: 20)
        var identities: Set<UUID> = []
        try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await barrier.wait()
                    let store = try LedgerStore(url: location)
                    let identity = store.workspaceID
                    try await store.close()
                    return identity
                }
            }
            for try await identity in group { identities.insert(identity) }
        }
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_workspace"), 1)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
    }

    func testOpeningWhileAnotherConnectionSavesUsesConsistentValidationSnapshot() async throws {
        let store = try LedgerStore(url: url)
        try await store.save(payload: Data([0]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let location = url
        let date = originalDate
        let barrier = LedgerOpenBarrier(count: 13)
        try await withThrowingTaskGroup(of: UUID.self) { group in
            group.addTask {
                await barrier.wait()
                for base in Int64(1)...40 {
                    try await store.save(payload: Data([UInt8(base)]), expectedRevision: base, operationID: UUID(), savedAt: date)
                }
                return store.workspaceID
            }
            for _ in 0..<12 {
                group.addTask {
                    await barrier.wait()
                    for _ in 0..<5 {
                        let reader = try LedgerStore(url: location)
                        let record = try await reader.load()
                        XCTAssertNotNil(record)
                        XCTAssertEqual(reader.workspaceID, store.workspaceID)
                        try await reader.close()
                    }
                    return store.workspaceID
                }
            }
            for try await identity in group { XCTAssertEqual(identity, store.workspaceID) }
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.revision, 41)
        try await store.close()
    }

    func testExactOperationRetryAfterRestartAndNewerSaveReturnsOriginalResult() async throws {
        let store = try LedgerStore(url: url)
        let operation = UUID()
        let first = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: operation, savedAt: originalDate)
        let second = try await store.save(payload: Data([2]), expectedRevision: 1, operationID: UUID(), savedAt: originalDate.addingTimeInterval(1))
        try await store.close()
        let reopened = try LedgerStore(url: url)
        let retry = try await reopened.save(payload: Data([1]), expectedRevision: 0, operationID: operation, savedAt: originalDate.addingTimeInterval(999))
        let loaded = try await reopened.load()
        XCTAssertEqual(retry, first)
        XCTAssertEqual(loaded, second)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 2)
        try await reopened.close()
    }

    func testReusedOperationWithChangedPayloadOrBaseFailsWithoutMutation() async throws {
        let store = try LedgerStore(url: url)
        let operation = UUID()
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: operation, savedAt: originalDate)
        for (payload, base) in [(Data([2]), Int64(0)), (Data([1]), Int64(1))] {
            do {
                try await store.save(payload: payload, expectedRevision: base, operationID: operation, savedAt: originalDate)
                XCTFail("Reusing an operation with changed intent must fail")
            } catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await store.close()
    }

    func testDistinctOperationWithSamePayloadNeedsCurrentBaseAndAppendsReceipt() async throws {
        let store = try LedgerStore(url: url)
        let first = try await store.save(payload: Data(), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        do {
            try await store.save(payload: Data(), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
            XCTFail("Equal payload must not bypass compare-and-swap")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .staleRevision(expected: 0, actual: 1)) }
        let second = try await store.save(payload: Data(), expectedRevision: 1, operationID: UUID(), savedAt: originalDate)
        XCTAssertEqual(second.revision, 2)
        XCTAssertNotEqual(first.operationID, second.operationID)
        XCTAssertEqual(second.payload, Data())
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions WHERE typeof(payload) = 'blob' AND length(payload) = 0"), 2)
        try await store.close()
    }

    func testTwoConnectionsCannotCommitTheSameBaseTwice() async throws {
        let first = try LedgerStore(url: url)
        let second = try LedgerStore(url: url)
        let date = originalDate
        var successes = 0
        var stale = 0
        try await withThrowingTaskGroup(of: LedgerStoreError?.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    do {
                        try await store.save(payload: Data([UInt8(index)]), expectedRevision: 0, operationID: UUID(), savedAt: date)
                        return nil
                    } catch let error as LedgerStoreError { return error }
                }
            }
            for try await error in group {
                if let error {
                    XCTAssertEqual(error, .staleRevision(expected: 0, actual: 1))
                    stale += 1
                } else { successes += 1 }
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(stale, 19)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await first.close()
        try await second.close()
    }

    func testConcurrentExactRetriesHaveOneDurableResult() async throws {
        let first = try LedgerStore(url: url)
        let second = try LedgerStore(url: url)
        let operation = UUID()
        let date = originalDate
        var records: [LedgerRecord] = []
        try await withThrowingTaskGroup(of: LedgerRecord.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await store.save(payload: Data([255]), expectedRevision: 0, operationID: operation,
                                         savedAt: date.addingTimeInterval(Double(index)))
                }
            }
            for try await record in group { records.append(record) }
        }
        let loaded = try await first.load()
        XCTAssertEqual(records.count, 20)
        XCTAssertTrue(records.allSatisfy { $0 == loaded })
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await first.close()
        try await second.close()
    }

    func testSQLiteProtectsSnapshotAndWorkspaceIdentity() async throws {
        let store = try LedgerStore(url: url)
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        XCTAssertThrowsError(try sql("UPDATE ledger_revisions SET payload = x'02'"))
        XCTAssertThrowsError(try sql("UPDATE ledger_revisions SET operation_id = '\(UUID().uuidString)'"))
        XCTAssertThrowsError(try sql("DELETE FROM ledger_revisions"))
        XCTAssertThrowsError(try sql("UPDATE ledger_workspace SET id = '\(UUID().uuidString)'"))
        XCTAssertThrowsError(try sql("DELETE FROM ledger_workspace"))
        let loaded = try await store.load()
        XCTAssertEqual(loaded, saved)
        try await store.close()
    }

    func testRevisionInsertFailureDoesNotAdvanceHead() async throws {
        let store = try LedgerStore(url: url)
        try sql("CREATE TRIGGER fail_revision BEFORE INSERT ON ledger_revisions BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        do {
            try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
            XCTFail("Expected injected failure")
        } catch LedgerStoreError.database { }
        let loaded = try await store.load()
        XCTAssertNil(loaded)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        try await store.close()
    }

    func testInitialHeadFailureRollsBackSnapshotAndCanRetrySameOperation() async throws {
        let store = try LedgerStore(url: url)
        let operation = UUID()
        try sql("CREATE TRIGGER fail_head BEFORE UPDATE ON ledger_workspace BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        do {
            try await store.save(payload: Data([1]), expectedRevision: 0, operationID: operation, savedAt: originalDate)
            XCTFail("Expected injected failure")
        } catch LedgerStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        try await store.close()
        let reopened = try LedgerStore(url: url)
        let loaded = try await reopened.load()
        XCTAssertNil(loaded)
        try sql("DROP TRIGGER fail_head")
        let saved = try await reopened.save(payload: Data([1]), expectedRevision: 0, operationID: operation, savedAt: originalDate)
        XCTAssertEqual(saved.revision, 1)
        try await reopened.close()
    }

    func testLaterHeadFailurePreservesPriorSnapshotAfterRestart() async throws {
        let store = try LedgerStore(url: url)
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        try sql("CREATE TRIGGER fail_head BEFORE UPDATE ON ledger_workspace BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        do {
            try await store.save(payload: Data([2]), expectedRevision: 1, operationID: UUID(), savedAt: originalDate)
            XCTFail("Expected injected failure")
        } catch LedgerStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await store.close()
        let reopened = try LedgerStore(url: url)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded, saved)
        try await reopened.close()
    }

    func testCommitFailureRollsBackBothMutationsBeforeReportingError() async throws {
        let store = try LedgerStore(url: url)
        let operation = UUID()
        // The statement succeeds; its deferred foreign key makes COMMIT itself fail.
        try sql("""
            CREATE TABLE commit_guard (id TEXT REFERENCES ledger_workspace(id) DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER fail_commit AFTER UPDATE ON ledger_workspace
            BEGIN INSERT INTO commit_guard VALUES ('missing-workspace'); END;
            """)
        do {
            try await store.save(payload: Data([1]), expectedRevision: 0, operationID: operation, savedAt: originalDate)
            XCTFail("A failed COMMIT must never report a save")
        } catch LedgerStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM commit_guard"), 0)
        let loaded = try await store.load()
        XCTAssertNil(loaded)
        try sql("DROP TRIGGER fail_commit")
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: operation, savedAt: originalDate)
        XCTAssertEqual(saved.revision, 1)
        try await store.close()
    }

    func testMaximumRawPayloadReopensAndRetriesWithoutBase64Expansion() async throws {
        let store = try LedgerStore(url: url)
        let payload = Data(repeating: 255, count: LedgerStore.maximumPayloadBytes)
        let operation = UUID()
        let saved = try await store.save(payload: payload, expectedRevision: 0, operationID: operation, savedAt: originalDate)
        XCTAssertEqual(try scalar("SELECT length(payload) FROM ledger_revisions"), Int64(LedgerStore.maximumPayloadBytes))
        try await store.close()
        let reopened = try LedgerStore(url: url)
        let loaded = try await reopened.load()
        let retry = try await reopened.save(payload: payload, expectedRevision: 0, operationID: operation, savedAt: originalDate.addingTimeInterval(1))
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(retry, saved)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await reopened.close()
    }

    func testOversizedPayloadAndInvalidInputsLeaveExistingStateUnchanged() async throws {
        let store = try LedgerStore(url: url)
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        do {
            try await store.save(payload: Data(count: LedgerStore.maximumPayloadBytes + 1), expectedRevision: 1, operationID: UUID(), savedAt: originalDate)
            XCTFail("Expected payload limit")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .payloadTooLarge) }
        for (base, date) in [(Int64(-1), originalDate), (Int64(1), Date(timeIntervalSinceReferenceDate: .infinity))] {
            do {
                try await store.save(payload: Data(), expectedRevision: base, operationID: UUID(), savedAt: date)
                XCTFail("Expected invalid input")
            } catch { XCTAssertEqual(error as? LedgerStoreError, .invalidInput) }
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 1)
        try await store.close()
    }

    func testFutureSchemaIsByteForByteUnchanged() throws {
        try sql("CREATE TABLE future (value TEXT); INSERT INTO future VALUES ('preserve'); PRAGMA user_version = 42")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .unsupportedSchema(42))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testUnknownUnversionedSchemaIsByteForByteUnchanged() throws {
        try sql("CREATE TABLE legacy (value TEXT); INSERT INTO legacy VALUES ('preserve')")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .unrecognizedSchema)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testComparisonDatabaseCannotBeOpenedAsLedgerOrModified() async throws {
        let comparison = try ComparisonStore(url: url)
        try await comparison.save(id: UUID(), title: "Preserve", payload: Data([1]), savedAt: originalDate)
        try await comparison.close()
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .unrecognizedSchema)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMalformedFileIsNotRecreated() throws {
        let before = Data("Not a SQLite database".utf8)
        try before.write(to: url)
        XCTAssertThrowsError(try LedgerStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCorruptEmptyVersionZeroIsNotMigratedOrRewritten() throws {
        try sql("PRAGMA user_version = 0")
        var before = try Data(contentsOf: url)
        // Corrupt the freelist without adding any application schema: page 2 does
        // not exist in this otherwise empty one-page SQLite database.
        before.replaceSubrange(32..<36, with: [0, 0, 0, 2])
        before.replaceSubrange(36..<40, with: [0, 0, 0, 1])
        try before.write(to: url)
        XCTAssertThrowsError(try LedgerStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testDamagedHistoricalPayloadIsRejectedWithoutRewriting() async throws {
        let store = try LedgerStore(url: url)
        try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        try await store.save(payload: Data([2]), expectedRevision: 1, operationID: UUID(), savedAt: originalDate)
        try await store.close()
        try sql("DROP TRIGGER ledger_revision_immutable_update; UPDATE ledger_revisions SET payload = x'03' WHERE revision = 1")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .corruptRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testOversizedStoredPayloadIsRejectedWithoutRewriting() async throws {
        let store = try LedgerStore(url: url)
        try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        try await store.close()
        try sql("""
            DROP TRIGGER ledger_revision_immutable_update;
            PRAGMA ignore_check_constraints = ON;
            UPDATE ledger_revisions SET payload = zeroblob(\(LedgerStore.maximumPayloadBytes + 1));
            """)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testBrokenHeadIsRejectedWithoutRewriting() async throws {
        let store = try LedgerStore(url: url)
        try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        try await store.close()
        try sql("UPDATE ledger_workspace SET head_revision = 99")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .corruptRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testClosedStoreFailsExplicitlyAndDoubleCloseIsSafe() async throws {
        let store = try LedgerStore(url: url)
        try await store.close()
        try await store.close()
        do {
            _ = try await store.load()
            XCTFail("Expected closed store error")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .closed) }
        do {
            try await store.save(payload: Data(), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
            XCTFail("Expected closed store error")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .closed) }
    }

    func testVersionOneMigrationPreservesSnapshotsAndOperationRetries() async throws {
        let fixture = try makeVersionOneFixture()
        let store = try LedgerStore(url: url)
        XCTAssertEqual(store.workspaceID, fixture.workspace)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.revision, 2)
        XCTAssertEqual(loaded?.payload, Data([2]))
        let retry = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: fixture.firstOperation, savedAt: Date())
        XCTAssertEqual(retry.revision, 1)
        XCTAssertEqual(retry.savedAt, Date(timeIntervalSinceReferenceDate: 12))
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 2)
        try await store.close()
    }

    func testFailedVersionTwoMigrationRestoresOriginalVersionAndGuards() throws {
        _ = try makeVersionOneFixture()
        // Collides after the migration has replaced its original deletion guards.
        try sql("CREATE TRIGGER ledger_retired_workspace_insert AFTER UPDATE ON ledger_workspace BEGIN SELECT 1; END")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name = 'ledger_workspace_tombstones'"), 0)
        XCTAssertThrowsError(try sql("DELETE FROM ledger_revisions"))
        XCTAssertThrowsError(try sql("DELETE FROM ledger_workspace"))
    }

    func testCorruptVersionOneSnapshotDoesNotMigrateOrRewrite() throws {
        _ = try makeVersionOneFixture()
        try sql("DROP TRIGGER ledger_revision_immutable_update; UPDATE ledger_revisions SET payload = x'03' WHERE revision = 1")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .corruptRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 1)
    }

    func testWholeWorkspaceErasurePurgesHistoryAndRotatesEmptyIdentity() async throws {
        let store = try LedgerStore(url: url)
        let oldID = store.workspaceID
        let firstBytes = Data(("PRIVATE-OLD-WORKSPACE-" + UUID().uuidString).utf8)
        let secondBytes = Data(("PRIVATE-CURRENT-WORKSPACE-" + UUID().uuidString).utf8)
        try await store.save(payload: firstBytes, expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        try await store.save(payload: secondBytes, expectedRevision: 1, operationID: UUID(), savedAt: originalDate)
        let before = try Data(contentsOf: url)
        XCTAssertNotNil(before.range(of: firstBytes))
        XCTAssertNotNil(before.range(of: secondBytes))
        let date = Date(timeIntervalSinceReferenceDate: Double(815_000_000).nextUp)
        let operation = UUID()
        let receipt = try await store.eraseWorkspace(workspaceID: oldID, expectedRevision: 2, operationID: operation, at: date)
        XCTAssertEqual(receipt.workspaceID, oldID)
        XCTAssertEqual(receipt.erasedRevision, 2)
        XCTAssertEqual(receipt.operationID, operation)
        XCTAssertEqual(receipt.erasedAt, date)
        XCTAssertNotEqual(receipt.replacementWorkspaceID, oldID)
        XCTAssertEqual(store.workspaceID, oldID)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_retired_operations"), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_workspace"), 1)
        let after = try Data(contentsOf: url)
        XCTAssertNil(after.range(of: firstBytes))
        XCTAssertNil(after.range(of: secondBytes))
        do { _ = try await store.load(); XCTFail("Retired actors cannot read the replacement") }
        catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        try await store.close()
        let reopened = try LedgerStore(url: url)
        XCTAssertEqual(reopened.workspaceID, receipt.replacementWorkspaceID)
        let empty = try await reopened.load()
        XCTAssertNil(empty)
        let retired = try await reopened.retiredWorkspaceIDs()
        XCTAssertEqual(retired, [oldID])
        let saved = try await reopened.save(payload: Data([3]), expectedRevision: 0, operationID: UUID(), savedAt: date)
        XCTAssertEqual(saved.workspaceID, receipt.replacementWorkspaceID)
        XCTAssertEqual(saved.revision, 1)
        try await reopened.close()
    }

    func testOldSaveRetriesAreErasedOnOldAndReopenedActors() async throws {
        let store = try LedgerStore(url: url)
        let saveOperation = UUID(), eraseOperation = UUID()
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: saveOperation, savedAt: originalDate)
        try await store.eraseWorkspace(workspaceID: store.workspaceID, expectedRevision: 1, operationID: eraseOperation, at: originalDate)
        let reopened = try LedgerStore(url: url)
        for actor in [store, reopened] {
            do {
                try await actor.save(payload: saved.payload, expectedRevision: 0, operationID: saveOperation, savedAt: originalDate)
                XCTFail("An old operation must not resurrect erased bytes, even on a new actor")
            } catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        }
        do {
            try await store.save(payload: Data([2]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
            XCTFail("An old actor cannot mutate the replacement workspace")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        do {
            try await reopened.save(payload: Data([2]), expectedRevision: 0, operationID: eraseOperation, savedAt: originalDate)
            XCTFail("An erasure operation cannot become a save operation")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 0)
        try await store.close()
        try await reopened.close()
    }

    func testErasureRetryAfterRestartAndFurtherRotationPreservesOriginalReceipt() async throws {
        let first = try LedgerStore(url: url)
        let firstID = first.workspaceID, operation = UUID()
        try await first.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let receipt = try await first.eraseWorkspace(workspaceID: firstID, expectedRevision: 1, operationID: operation, at: originalDate)
        try await first.close()
        let second = try LedgerStore(url: url)
        let secondReceipt = try await second.eraseWorkspace(workspaceID: second.workspaceID, expectedRevision: 0, operationID: UUID(), at: originalDate.addingTimeInterval(1))
        try await second.close()
        let third = try LedgerStore(url: url)
        let retry = try await third.eraseWorkspace(workspaceID: firstID, expectedRevision: 1, operationID: operation, at: originalDate.addingTimeInterval(999))
        XCTAssertEqual(retry, receipt)
        XCTAssertEqual(third.workspaceID, secondReceipt.replacementWorkspaceID)
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_workspace_tombstones"), 2)
        let ids = try await third.retiredWorkspaceIDs()
        XCTAssertEqual(Set(ids), Set([firstID, receipt.replacementWorkspaceID]))
        let empty = try await third.load()
        XCTAssertNil(empty)
        try await third.close()
    }

    func testChangedErasureIntentAndStaleRevisionLeaveWorkspaceIntact() async throws {
        let store = try LedgerStore(url: url)
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let operation = UUID(), oldID = store.workspaceID
        do {
            try await store.eraseWorkspace(workspaceID: oldID, expectedRevision: 0, operationID: operation, at: originalDate)
            XCTFail("An empty-workspace confirmation must not delete a newer save")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .staleRevision(expected: 0, actual: 1)) }
        let loaded = try await store.load()
        XCTAssertEqual(loaded, saved)
        do {
            try await store.eraseWorkspace(workspaceID: oldID, expectedRevision: 1, operationID: saved.operationID, at: originalDate)
            XCTFail("A save operation cannot be reused as erasure")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        try await store.eraseWorkspace(workspaceID: oldID, expectedRevision: 1, operationID: operation, at: originalDate)
        let reopened = try LedgerStore(url: url)
        for (id, revision) in [(oldID, Int64(2)), (reopened.workspaceID, Int64(1))] {
            do {
                try await reopened.eraseWorkspace(workspaceID: id, expectedRevision: revision, operationID: operation, at: originalDate)
                XCTFail("Changed erasure intent must fail")
            } catch { XCTAssertEqual(error as? LedgerStoreError, .operationConflict) }
        }
        do {
            try await reopened.eraseWorkspace(workspaceID: oldID, expectedRevision: 1, operationID: UUID(), at: originalDate)
            XCTFail("A new operation cannot erase an already retired identity")
        } catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_workspace_tombstones"), 1)
        try await store.close()
        try await reopened.close()
    }

    func testErasureRollbackAtEveryMutationAndCommitRestoresHistoryAndIdentity() async throws {
        let store = try LedgerStore(url: url)
        let first = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let current = try await store.save(payload: Data([2]), expectedRevision: 1, operationID: UUID(), savedAt: originalDate)
        let operation = UUID()
        try sql("CREATE TABLE erasure_commit_guard (id TEXT REFERENCES ledger_workspace(id) DEFERRABLE INITIALLY DEFERRED)")
        let injections = [
            "BEFORE INSERT ON ledger_workspace_tombstones BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "BEFORE INSERT ON ledger_retired_operations BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "BEFORE DELETE ON ledger_revisions BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "BEFORE DELETE ON ledger_workspace BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "BEFORE INSERT ON ledger_workspace BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "AFTER INSERT ON ledger_workspace BEGIN INSERT INTO erasure_commit_guard VALUES ('missing'); END"
        ]
        for injection in injections {
            try sql("CREATE TRIGGER fail_erasure \(injection)")
            do {
                try await store.eraseWorkspace(workspaceID: store.workspaceID, expectedRevision: 2, operationID: operation, at: originalDate)
                XCTFail("A failed purge/rotation/COMMIT must never report success")
            } catch LedgerStoreError.database { }
            let loaded = try await store.load()
            XCTAssertEqual(loaded, current)
            XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_revisions"), 2)
            XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_workspace_tombstones"), 0)
            XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_retired_operations"), 0)
            XCTAssertEqual(try scalar("SELECT count(*) FROM erasure_commit_guard"), 0)
            try sql("DROP TRIGGER fail_erasure")
        }
        try await store.close()
        let reopened = try LedgerStore(url: url)
        XCTAssertEqual(reopened.workspaceID, current.workspaceID)
        let retriedSave = try await reopened.save(payload: first.payload, expectedRevision: 0, operationID: first.operationID, savedAt: Date())
        XCTAssertEqual(retriedSave, first)
        let receipt = try await reopened.eraseWorkspace(workspaceID: reopened.workspaceID, expectedRevision: 2, operationID: operation, at: originalDate)
        XCTAssertEqual(receipt.erasedRevision, 2)
        try await reopened.close()
    }

    func testConcurrentExactWorkspaceErasureHasOneReplacement() async throws {
        let first = try LedgerStore(url: url)
        try await first.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let second = try LedgerStore(url: url)
        let oldID = first.workspaceID, operation = UUID()
        var receipts: [LedgerWorkspaceTombstone] = []
        try await withThrowingTaskGroup(of: LedgerWorkspaceTombstone.self) { group in
            for index in 0..<16 {
                let actor = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await actor.eraseWorkspace(workspaceID: oldID, expectedRevision: 1, operationID: operation,
                                                   at: Date(timeIntervalSinceReferenceDate: Double(index)))
                }
            }
            for try await receipt in group { receipts.append(receipt) }
        }
        XCTAssertEqual(receipts.count, 16)
        XCTAssertTrue(receipts.allSatisfy { $0 == receipts.first })
        XCTAssertEqual(try scalar("SELECT count(*) FROM ledger_workspace_tombstones"), 1)
        try await first.close()
        try await second.close()
        let reopened = try LedgerStore(url: url)
        XCTAssertEqual(reopened.workspaceID, receipts.first?.replacementWorkspaceID)
        try await reopened.close()
    }

    func testConcurrentSaveAndWorkspaceErasureCannotDeleteUnconfirmedWorkOrResurrect() async throws {
        let first = try LedgerStore(url: url)
        try await first.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let second = try LedgerStore(url: url)
        let oldID = first.workspaceID, date = originalDate
        var results: [LedgerStoreError?] = []
        try await withThrowingTaskGroup(of: LedgerStoreError?.self) { group in
            group.addTask {
                do {
                    try await first.eraseWorkspace(workspaceID: oldID, expectedRevision: 1, operationID: UUID(), at: date)
                    return nil
                } catch let error as LedgerStoreError { return error }
            }
            group.addTask {
                do {
                    try await second.save(payload: Data([2]), expectedRevision: 1, operationID: UUID(), savedAt: date)
                    return nil
                } catch let error as LedgerStoreError { return error }
            }
            for try await result in group { results.append(result) }
        }
        XCTAssertEqual(results.filter { $0 == nil }.count, 1)
        let failure = results.compactMap { $0 }.first
        XCTAssertTrue(failure == .erased || failure == .staleRevision(expected: 1, actual: 2))
        try await first.close()
        try await second.close()
        let reopened = try LedgerStore(url: url)
        let record = try await reopened.load()
        if reopened.workspaceID == oldID { XCTAssertEqual(record?.revision, 2) }
        else { XCTAssertNil(record) }
        try await reopened.close()
    }

    func testOpeningWhileWorkspaceRotatesSeesValidOldOrNewWorkspace() async throws {
        let store = try LedgerStore(url: url)
        try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let oldID = store.workspaceID, location = url, date = originalDate
        let barrier = LedgerOpenBarrier(count: 13)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await barrier.wait()
                try await store.eraseWorkspace(workspaceID: oldID, expectedRevision: 1, operationID: UUID(), at: date)
            }
            for _ in 0..<12 {
                group.addTask {
                    await barrier.wait()
                    let reader = try LedgerStore(url: location)
                    do {
                        let loaded = try await reader.load()
                        if reader.workspaceID == oldID { XCTAssertEqual(loaded?.revision, 1) }
                        else { XCTAssertNil(loaded) }
                    } catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
                    try await reader.close()
                }
            }
            for try await _ in group { }
        }
        try await store.close()
    }

    func testRetirementMetadataAndOperationGuardsRejectSQLResurrection() async throws {
        let store = try LedgerStore(url: url)
        let saved = try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        let receipt = try await store.eraseWorkspace(workspaceID: store.workspaceID, expectedRevision: 1, operationID: UUID(), at: originalDate)
        XCTAssertThrowsError(try sql("DELETE FROM ledger_workspace_tombstones"))
        XCTAssertThrowsError(try sql("UPDATE ledger_workspace_tombstones SET erased_revision = 0"))
        XCTAssertThrowsError(try sql("DELETE FROM ledger_retired_operations"))
        XCTAssertThrowsError(try sql("UPDATE ledger_retired_operations SET operation_id = '\(UUID().uuidString)'"))
        XCTAssertThrowsError(try sql("INSERT INTO ledger_workspace (singleton, id) VALUES (1, '\(saved.workspaceID.uuidString)')"))
        let digest = SHA256.hash(data: Data([1])).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try sql("INSERT INTO ledger_revisions VALUES ('\(receipt.replacementWorkspaceID.uuidString)', 1, 0, '\(saved.operationID.uuidString)', x'01', x'\(digest)', 1)"))
        try await store.close()
    }

    func testCorruptRetiredOperationMetadataIsRejectedWithoutRewriting() async throws {
        let store = try LedgerStore(url: url)
        try await store.save(payload: Data([1]), expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        try await store.eraseWorkspace(workspaceID: store.workspaceID, expectedRevision: 1, operationID: UUID(), at: originalDate)
        try await store.close()
        try sql("DROP TRIGGER ledger_retired_operation_immutable_delete; DELETE FROM ledger_retired_operations")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .corruptRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCorruptRetirementChainIsRejectedWithoutRewriting() async throws {
        let store = try LedgerStore(url: url)
        try await store.eraseWorkspace(workspaceID: store.workspaceID, expectedRevision: 0, operationID: UUID(), at: originalDate)
        try await store.close()
        try sql("DROP TRIGGER ledger_tombstone_immutable_update; UPDATE ledger_workspace_tombstones SET replacement_workspace_id = '\(UUID().uuidString)'")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LedgerStore(url: url)) { error in
            XCTAssertEqual(error as? LedgerStoreError, .corruptRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testWorkspaceErasureCheckpointsWALWhenNoReaderBlocksIt() async throws {
        let store = try LedgerStore(url: url)
        try sql("PRAGMA journal_mode = WAL")
        let bytes = Data(("PRIVATE-WAL-WORKSPACE-" + UUID().uuidString).utf8)
        try await store.save(payload: bytes, expectedRevision: 0, operationID: UUID(), savedAt: originalDate)
        try await store.eraseWorkspace(workspaceID: store.workspaceID, expectedRevision: 1, operationID: UUID(), at: originalDate)
        XCTAssertNil(try Data(contentsOf: url).range(of: bytes))
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) { XCTAssertNil(try Data(contentsOf: wal).range(of: bytes)) }
        try await store.close()
    }

    private func makeVersionOneFixture() throws -> (workspace: UUID, firstOperation: UUID) {
        let workspace = UUID(), first = UUID(), second = UUID()
        let firstDigest = SHA256.hash(data: Data([1])).map { String(format: "%02x", $0) }.joined()
        let secondDigest = SHA256.hash(data: Data([2])).map { String(format: "%02x", $0) }.joined()
        // Frozen v1 schema, independent of the current migration implementation.
        try sql("""
            CREATE TABLE ledger_workspace (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                id TEXT NOT NULL UNIQUE CHECK(typeof(id) = 'text' AND length(id) = 36),
                head_revision INTEGER CHECK(head_revision IS NULL OR (typeof(head_revision) = 'integer' AND head_revision > 0)),
                FOREIGN KEY (id, head_revision) REFERENCES ledger_revisions(workspace_id, revision) DEFERRABLE INITIALLY DEFERRED
            );
            CREATE TABLE ledger_revisions (
                workspace_id TEXT NOT NULL REFERENCES ledger_workspace(id),
                revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0),
                base_revision INTEGER NOT NULL CHECK(typeof(base_revision) = 'integer' AND base_revision >= 0 AND base_revision = revision - 1),
                operation_id TEXT NOT NULL UNIQUE CHECK(typeof(operation_id) = 'text' AND length(operation_id) = 36),
                payload BLOB NOT NULL CHECK(typeof(payload) = 'blob' AND length(payload) <= 4194304),
                payload_sha256 BLOB NOT NULL CHECK(typeof(payload_sha256) = 'blob' AND length(payload_sha256) = 32),
                saved_at REAL NOT NULL CHECK(typeof(saved_at) IN ('real', 'integer')),
                PRIMARY KEY (workspace_id, revision)
            );
            CREATE TRIGGER ledger_revision_immutable_update BEFORE UPDATE ON ledger_revisions BEGIN SELECT RAISE(ABORT, 'immutable ledger revision'); END;
            CREATE TRIGGER ledger_revision_immutable_delete BEFORE DELETE ON ledger_revisions BEGIN SELECT RAISE(ABORT, 'immutable ledger revision'); END;
            CREATE TRIGGER ledger_workspace_immutable_identity BEFORE UPDATE OF id, singleton ON ledger_workspace BEGIN SELECT RAISE(ABORT, 'immutable ledger identity'); END;
            CREATE TRIGGER ledger_workspace_immutable_delete BEFORE DELETE ON ledger_workspace BEGIN SELECT RAISE(ABORT, 'immutable ledger identity'); END;
            INSERT INTO ledger_workspace VALUES (1, '\(workspace.uuidString)', 2);
            INSERT INTO ledger_revisions VALUES ('\(workspace.uuidString)', 1, 0, '\(first.uuidString)', x'01', x'\(firstDigest)', 12);
            INSERT INTO ledger_revisions VALUES ('\(workspace.uuidString)', 2, 1, '\(second.uuidString)', x'02', x'\(secondDigest)', 13);
            PRAGMA application_id = 1380537420;
            PRAGMA user_version = 1;
            """)
        return (workspace, first)
    }

    private func sql(_ query: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
    }

    private func scalar(_ query: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &row, nil) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw TestError.sqlite }
        return sqlite3_column_int64(row, 0)
    }

    private enum TestError: Error { case sqlite }
}

private actor LedgerOpenBarrier {
    private var remaining: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { remaining = count }

    func wait() async {
        remaining -= 1
        if remaining == 0 {
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}
