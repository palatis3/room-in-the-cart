import XCTest
import Foundation
import CSQLite
@testable import LocalStore

final class ComparisonStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("comparisons.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSaveCloseReopenPreservesPayloadAndWorkspace() async throws {
        let store = try ComparisonStore(url: url)
        let workspace = store.workspaceID
        let id = UUID()
        let payload = Data([0, 1, 2, 127, 255])
        let record = try await store.save(id: id, title: "Arroz — Rice", payload: payload,
                                          savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.close()
        let reopened = try ComparisonStore(url: url)
        XCTAssertEqual(reopened.workspaceID, workspace)
        let loaded = try await reopened.load(id: id)
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded?.revision, 1)
        try await reopened.close()
    }

    func testExactRetryPreservesOriginalTimeAndRevision() async throws {
        let store = try ComparisonStore(url: url)
        let id = UUID()
        let original = try await store.save(id: id, title: "Pack", payload: Data(), savedAt: Date(timeIntervalSince1970: 12))
        let retry = try await store.save(id: id, title: "Pack", payload: Data(), savedAt: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(original, retry)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 1)
        try await store.close()
    }

    func testSubsecondDateRoundTripsExactly() async throws {
        let store = try ComparisonStore(url: url)
        // Converting this reference-epoch Double to Unix epoch and back loses a bit.
        let time = Date(timeIntervalSinceReferenceDate: Double(815_000_000).nextUp)
        let saved = try await store.save(id: UUID(), title: "Timestamp", payload: Data([1]), savedAt: time)
        let loaded = try await store.load(id: saved.id)
        XCTAssertEqual(loaded?.savedAt, time)
        XCTAssertEqual(loaded, saved)
        try await store.close()
    }

    func testChangedPayloadAndTitleAppendImmutableRevisions() async throws {
        let store = try ComparisonStore(url: url)
        let id = UUID()
        let first = try await store.save(id: id, title: "A", payload: Data([1]), savedAt: Date())
        let second = try await store.save(id: id, title: "A", payload: Data([2]), savedAt: Date())
        let third = try await store.save(id: id, title: "B", payload: Data([2]), savedAt: Date())
        XCTAssertEqual([first.revision, second.revision, third.revision], [1, 2, 3])
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 3)
        XCTAssertThrowsError(try sql("UPDATE comparison_revisions SET title = 'changed'"))
        XCTAssertThrowsError(try sql("DELETE FROM comparison_revisions"))
        let loaded = try await store.load(id: id)
        XCTAssertEqual(loaded, third)
        try await store.close()
    }

    func testHeadWriteFailureRollsBackInsertedRevision() async throws {
        let store = try ComparisonStore(url: url)
        let id = UUID()
        let initial = try await store.save(id: id, title: "Before", payload: Data([1]), savedAt: Date())
        try sql("CREATE TRIGGER fail_head BEFORE UPDATE ON comparisons BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        do {
            try await store.save(id: id, title: "After", payload: Data([2]), savedAt: Date())
            XCTFail("Expected transaction failure")
        } catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 1)
        try await store.close()
        let reopened = try ComparisonStore(url: url)
        let loaded = try await reopened.load(id: id)
        XCTAssertEqual(loaded, initial)
        try sql("DROP TRIGGER fail_head")
        let updated = try await reopened.save(id: id, title: "After", payload: Data([2]), savedAt: Date())
        XCTAssertEqual(updated.revision, 2)
        try await reopened.close()
    }

    func testInitialHeadFailureLeavesNoOrphanRevision() async throws {
        let store = try ComparisonStore(url: url)
        try sql("CREATE TRIGGER fail_insert BEFORE INSERT ON comparisons BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        do {
            try await store.save(id: UUID(), title: "Pack", payload: Data([1]), savedAt: Date())
            XCTFail("Expected transaction failure")
        } catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparisons"), 0)
        try await store.close()
    }

    func testFreshMigrationAndIndependentWorkspace() async throws {
        // An existing empty SQLite v0 file is a supported migration input.
        try sql("PRAGMA user_version = 0")
        let first = try ComparisonStore(url: url)
        let second = try ComparisonStore(url: directory.appendingPathComponent("other.sqlite"))
        XCTAssertNotEqual(first.workspaceID, second.workspaceID)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM workspace"), 1)
        try await first.close()
        try await second.close()
    }

    func testFutureSchemaRejectedWithoutChangingFile() throws {
        try sql("CREATE TABLE future (value TEXT); INSERT INTO future VALUES ('preserve'); PRAGMA user_version = 42")
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url)) { error in
            XCTAssertEqual(error as? ComparisonStoreError, .unsupportedSchema(42))
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testUnknownUnversionedSchemaRejectedWithoutChangingFile() throws {
        try sql("CREATE TABLE legacy (value TEXT); INSERT INTO legacy VALUES ('preserve')")
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url)) { error in
            XCTAssertEqual(error as? ComparisonStoreError, .unrecognizedSchema)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testBoundedPayloadAndInvalidDateDoNotMutate() async throws {
        let store = try ComparisonStore(url: url)
        do {
            try await store.save(id: UUID(), title: "Too big", payload: Data(count: ComparisonStore.maximumPayloadBytes + 1), savedAt: Date())
            XCTFail("Expected size error")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .payloadTooLarge) }
        do {
            try await store.save(id: UUID(), title: "Invalid", payload: Data(), savedAt: Date(timeIntervalSince1970: .infinity))
            XCTFail("Expected input error")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .invalidInput) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 0)
        let maximum = Data(repeating: 1, count: ComparisonStore.maximumPayloadBytes)
        let saved = try await store.save(id: UUID(), title: "Maximum", payload: maximum, savedAt: Date())
        let loaded = try await store.load(id: saved.id)
        XCTAssertEqual(loaded?.payload, maximum)
        try await store.close()
    }

    func testCorruptPayloadIsSurfacedAndRetained() async throws {
        let store = try ComparisonStore(url: url)
        let id = UUID()
        try await store.save(id: id, title: "Pack", payload: Data([1]), savedAt: Date())
        try await store.close()
        try sql("DROP TRIGGER immutable_revision_update; UPDATE comparison_revisions SET envelope = x'7B' ")
        let before = try Data(contentsOf: url)
        let reopened = try ComparisonStore(url: url)
        do {
            _ = try await reopened.load(id: id)
            XCTFail("Expected corrupt record error")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .corruptRecord) }
        try await reopened.close()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMaximumSlashHeavyPayloadSavesReopensAndRetries() async throws {
        let store = try ComparisonStore(url: url)
        let payload = Data(repeating: 255, count: ComparisonStore.maximumPayloadBytes)
        let saved = try await store.save(id: UUID(), title: "Maximum slash-heavy Base64",
                                         payload: payload, savedAt: Date(timeIntervalSince1970: 12))
        try await store.close()
        let reopened = try ComparisonStore(url: url)
        let loaded = try await reopened.load(id: saved.id)
        XCTAssertEqual(loaded, saved)
        let retried = try await reopened.save(id: saved.id, title: saved.title,
                                              payload: payload, savedAt: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(retried, saved)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 1)
        try await reopened.close()
    }

    func testMalformedDatabaseIsNotRecreated() throws {
        let garbage = Data("This is not a SQLite database".utf8)
        try garbage.write(to: url)
        XCTAssertThrowsError(try ComparisonStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testListOrderMissingIDAndSQLCharacters() async throws {
        let store = try ComparisonStore(url: url)
        let old = try await store.save(id: UUID(), title: "'); DROP TABLE comparisons;--", payload: Data([0]), savedAt: Date(timeIntervalSince1970: 1))
        let recent = try await store.save(id: UUID(), title: "Recent", payload: Data([1]), savedAt: Date(timeIntervalSince1970: 2))
        let records = try await store.list()
        XCTAssertEqual(records, [recent, old])
        let missing = try await store.load(id: UUID())
        XCTAssertNil(missing)
        try await store.close()
        try await store.close()
        do {
            _ = try await store.list()
            XCTFail("Closed store must fail explicitly")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .closed) }
    }

    func testConcurrentRetriesCreateOnlyOneRevision() async throws {
        let first = try ComparisonStore(url: url)
        let second = try ComparisonStore(url: url)
        let id = UUID()
        try await withThrowingTaskGroup(of: Int64.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await store.save(id: id, title: "Same", payload: Data([1]), savedAt: Date()).revision
                }
            }
            for try await revision in group { XCTAssertEqual(revision, 1) }
        }
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 1)
        try await first.close()
        try await second.close()
    }

    func testVersionOneMigrationPreservesWorkspaceHistoryAndRetry() async throws {
        let fixture = try makeVersionOneFixture()
        let store = try ComparisonStore(url: url)
        XCTAssertEqual(store.workspaceID, fixture.workspace)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 2)
        let loaded = try await store.load(id: fixture.id)
        XCTAssertEqual(loaded?.payload, Data([2]))
        XCTAssertEqual(loaded?.title, "After")
        XCTAssertEqual(loaded?.revision, 2)
        let retried = try await store.save(id: fixture.id, title: "After", payload: Data([2]), savedAt: Date())
        XCTAssertEqual(loaded, retried)
        XCTAssertThrowsError(try sql("DELETE FROM comparison_revisions"))
        let erased = try await store.erase(id: fixture.id, expectedRevision: 2, operationID: UUID(), at: Date())
        XCTAssertEqual(erased.workspaceID, fixture.workspace)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 0)
        try await store.close()
    }

    func testConcurrentVersionOneOpenersMigrateOnce() async throws {
        let fixture = try makeVersionOneFixture()
        let location = url
        try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let store = try ComparisonStore(url: location)
                    let workspace = store.workspaceID
                    try await store.close()
                    return workspace
                }
            }
            for try await workspace in group { XCTAssertEqual(workspace, fixture.workspace) }
        }
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 2)
    }

    func testFailedVersionTwoMigrationLeavesVersionOneAndEvidenceIntact() throws {
        _ = try makeVersionOneFixture()
        // A name collision fails after the migration has begun creating its objects.
        try sql("CREATE TRIGGER immutable_tombstone_delete BEFORE UPDATE ON workspace BEGIN SELECT 1; END")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name = 'comparison_tombstones'"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 2)
        XCTAssertThrowsError(try sql("DELETE FROM comparison_revisions"))
    }

    func testCorruptVersionOnePayloadRejectsMigrationWithoutRewriting() throws {
        _ = try makeVersionOneFixture()
        try sql("DROP TRIGGER immutable_revision_update; UPDATE comparison_revisions SET envelope = x'7B' WHERE revision = 1")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url)) { error in
            XCTAssertEqual(error as? ComparisonStoreError, .corruptRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 1)
    }

    func testUnsupportedVersionOneEnvelopeRejectsMigrationWithoutRewriting() throws {
        _ = try makeVersionOneFixture()
        try sql("DROP TRIGGER immutable_revision_update; UPDATE comparison_revisions SET envelope = CAST('{\"version\":99,\"payload\":\"AQ==\"}' AS BLOB) WHERE revision = 1")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url)) { error in
            XCTAssertEqual(error as? ComparisonStoreError, .unsupportedEnvelope(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testErasurePurgesAllSourceBytesAndKeepsOtherSources() async throws {
        let store = try ComparisonStore(url: url)
        let id = UUID()
        let firstSecret = "ERASE-PRIVATE-TITLE-FIRST-\(UUID().uuidString)"
        let secondSecret = "ERASE-PRIVATE-TITLE-SECOND-\(UUID().uuidString)"
        try await store.save(id: id, title: firstSecret, payload: Data(repeating: 113, count: 9_000), savedAt: Date())
        let source = try await store.save(id: id, title: secondSecret, payload: Data(repeating: 225, count: 9_000), savedAt: Date())
        let keep = try await store.save(id: UUID(), title: "Keep this source", payload: Data([3]), savedAt: Date())
        let before = try Data(contentsOf: url)
        XCTAssertNotNil(before.range(of: Data(firstSecret.utf8)))
        XCTAssertNotNil(before.range(of: Data(secondSecret.utf8)))
        let operation = UUID()
        let date = Date(timeIntervalSinceReferenceDate: Double(815_000_000).nextUp)
        let tombstone = try await store.erase(id: id, expectedRevision: source.revision, operationID: operation, at: date)
        XCTAssertEqual(tombstone.id, id)
        XCTAssertEqual(tombstone.workspaceID, store.workspaceID)
        XCTAssertEqual(tombstone.erasedRevision, 2)
        XCTAssertEqual(tombstone.operationID, operation)
        XCTAssertEqual(tombstone.erasedAt, date)
        let records = try await store.list()
        let missing = try await store.load(id: id)
        let erased = try await store.isErased(id: id)
        XCTAssertEqual(records, [keep])
        XCTAssertNil(missing)
        XCTAssertTrue(erased)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions WHERE comparison_id = '\(id.uuidString)'"), 0)
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data(firstSecret.utf8)))
        XCTAssertNil(bytes.range(of: Data(secondSecret.utf8)))
        try await store.close()
        let reopened = try ComparisonStore(url: url)
        let receipts = try await reopened.tombstones()
        XCTAssertEqual(receipts, [tombstone])
        let remaining = try await reopened.list()
        XCTAssertEqual(remaining, [keep])
        try await reopened.close()
    }

    func testExactErasureRetryPreservesReceiptAndRejectsChangedIntent() async throws {
        let store = try ComparisonStore(url: url)
        let source = try await store.save(id: UUID(), title: "Erase", payload: Data([1]), savedAt: Date())
        let other = try await store.save(id: UUID(), title: "Keep", payload: Data([2]), savedAt: Date())
        let operation = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 123)
        let first = try await store.erase(id: source.id, expectedRevision: 1, operationID: operation, at: date)
        try await store.close()
        let reopened = try ComparisonStore(url: url)
        let retry = try await reopened.erase(id: source.id, expectedRevision: 1, operationID: operation, at: date.addingTimeInterval(99))
        XCTAssertEqual(retry, first)
        for (id, revision) in [(source.id, Int64(2)), (other.id, Int64(1))] {
            do {
                try await reopened.erase(id: id, expectedRevision: revision, operationID: operation, at: date)
                XCTFail("A deletion operation cannot be reused for changed intent")
            } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
        }
        do {
            try await reopened.erase(id: source.id, expectedRevision: 1, operationID: UUID(), at: date)
            XCTFail("A different operation must observe permanent erasure")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        let kept = try await reopened.load(id: other.id)
        XCTAssertEqual(kept, other)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_tombstones"), 1)
        try await reopened.close()
    }

    func testStaleDeletionCannotEraseNewerRevision() async throws {
        let store = try ComparisonStore(url: url)
        let id = UUID()
        try await store.save(id: id, title: "Before", payload: Data([1]), savedAt: Date())
        let current = try await store.save(id: id, title: "After", payload: Data([2]), savedAt: Date())
        let operation = UUID()
        do {
            try await store.erase(id: id, expectedRevision: 1, operationID: operation, at: Date())
            XCTFail("Stale confirmation cannot erase changed data")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .staleRevision(expected: 1, actual: 2)) }
        let loaded = try await store.load(id: id)
        XCTAssertEqual(loaded, current)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_tombstones"), 0)
        let erased = try await store.erase(id: id, expectedRevision: 2, operationID: operation, at: Date())
        XCTAssertEqual(erased.erasedRevision, 2)
        try await store.close()
    }

    func testErasureCannotBeUndoneBySaveOrRawSQL() async throws {
        let store = try ComparisonStore(url: url)
        let source = try await store.save(id: UUID(), title: "Erase", payload: Data([1]), savedAt: Date())
        try await store.erase(id: source.id, expectedRevision: 1, operationID: UUID(), at: Date())
        for payload in [source.payload, Data([2])] {
            do {
                try await store.save(id: source.id, title: source.title, payload: payload, savedAt: Date())
                XCTFail("An erased identity cannot be saved or restored")
            } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        }
        XCTAssertThrowsError(try sql("INSERT INTO comparisons (id, workspace_id, head_revision) VALUES ('\(source.id.uuidString)', '\(store.workspaceID.uuidString)', 1)"))
        XCTAssertThrowsError(try sql("INSERT INTO comparison_revisions VALUES ('\(source.id.uuidString)', 1, 'Resurrected', x'7B', 1)"))
        XCTAssertThrowsError(try sql("DELETE FROM comparison_tombstones"))
        XCTAssertThrowsError(try sql("UPDATE comparison_tombstones SET erased_revision = 2"))
        let newSource = try await store.save(id: UUID(), title: "New intentional source", payload: Data([3]), savedAt: Date())
        XCTAssertNotEqual(newSource.id, source.id)
        try await store.close()
    }

    func testErasureRollbackAtEveryMutationAndCommitKeepsOriginalEvidence() async throws {
        let store = try ComparisonStore(url: url)
        let source = try await store.save(id: UUID(), title: "First", payload: Data([1]), savedAt: Date())
        let current = try await store.save(id: source.id, title: "Second", payload: Data([2]), savedAt: Date())
        try sql("CREATE TABLE commit_guard (workspace_id TEXT REFERENCES workspace(id) DEFERRABLE INITIALLY DEFERRED)")
        let operation = UUID()
        let injections = [
            "BEFORE INSERT ON comparison_tombstones BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "BEFORE DELETE ON comparison_revisions BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "BEFORE DELETE ON comparisons BEGIN SELECT RAISE(ABORT, 'test failure'); END",
            "AFTER DELETE ON comparisons BEGIN INSERT INTO commit_guard VALUES ('missing-workspace'); END"
        ]
        for injection in injections {
            try sql("CREATE TRIGGER fail_erase \(injection)")
            do {
                try await store.erase(id: source.id, expectedRevision: 2, operationID: operation, at: Date())
                XCTFail("Injected mutation/COMMIT failure must not succeed")
            } catch ComparisonStoreError.database { }
            let loaded = try await store.load(id: source.id)
            XCTAssertEqual(loaded, current)
            XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 2)
            XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_tombstones"), 0)
            XCTAssertEqual(try scalar("SELECT count(*) FROM commit_guard"), 0)
            try sql("DROP TRIGGER fail_erase")
        }
        try await store.close()
        let reopened = try ComparisonStore(url: url)
        let intact = try await reopened.load(id: source.id)
        XCTAssertEqual(intact, current)
        let receipt = try await reopened.erase(id: source.id, expectedRevision: 2, operationID: operation, at: Date())
        XCTAssertEqual(receipt.erasedRevision, 2)
        try await reopened.close()
    }

    func testConcurrentExactErasureRetriesReturnOneReceipt() async throws {
        let first = try ComparisonStore(url: url)
        let source = try await first.save(id: UUID(), title: "Erase", payload: Data([1]), savedAt: Date())
        let second = try ComparisonStore(url: url)
        let operation = UUID()
        var receipts: [ComparisonTombstone] = []
        try await withThrowingTaskGroup(of: ComparisonTombstone.self) { group in
            for index in 0..<16 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await store.erase(id: source.id, expectedRevision: 1, operationID: operation,
                                          at: Date(timeIntervalSinceReferenceDate: Double(index)))
                }
            }
            for try await receipt in group { receipts.append(receipt) }
        }
        XCTAssertEqual(receipts.count, 16)
        XCTAssertTrue(receipts.allSatisfy { $0 == receipts.first })
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_tombstones"), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 0)
        try await first.close()
        try await second.close()
    }

    func testConcurrentSaveAndEraseCannotResurrectOrEraseUnconfirmedRevision() async throws {
        let first = try ComparisonStore(url: url)
        let source = try await first.save(id: UUID(), title: "Before", payload: Data([1]), savedAt: Date())
        let second = try ComparisonStore(url: url)
        try await withThrowingTaskGroup(of: ComparisonStoreError?.self) { group in
            group.addTask {
                do {
                    try await first.erase(id: source.id, expectedRevision: 1, operationID: UUID(), at: Date())
                    return nil
                } catch let error as ComparisonStoreError { return error }
            }
            group.addTask {
                do {
                    try await second.save(id: source.id, title: "After", payload: Data([2]), savedAt: Date())
                    return nil
                } catch let error as ComparisonStoreError { return error }
            }
            var results: [ComparisonStoreError?] = []
            for try await result in group { results.append(result) }
            XCTAssertEqual(results.filter { $0 == nil }.count, 1)
            let failure = results.compactMap { $0 }.first
            XCTAssertTrue(failure == .erased || failure == .staleRevision(expected: 1, actual: 2))
        }
        let loaded = try await first.load(id: source.id)
        let erased = try await first.isErased(id: source.id)
        if erased { XCTAssertNil(loaded) }
        else { XCTAssertEqual(loaded?.revision, 2) }
        try await first.close()
        try await second.close()
    }

    func testConfirmedErasureCanRemoveCorruptPayloadWithoutDecodingIt() async throws {
        let store = try ComparisonStore(url: url)
        let source = try await store.save(id: UUID(), title: "Corrupt source", payload: Data([1]), savedAt: Date())
        try await store.close()
        try sql("DROP TRIGGER immutable_revision_update; UPDATE comparison_revisions SET envelope = x'7B'")
        let reopened = try ComparisonStore(url: url)
        try await reopened.erase(id: source.id, expectedRevision: 1, operationID: UUID(), at: Date())
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 0)
        let erased = try await reopened.isErased(id: source.id)
        XCTAssertTrue(erased)
        try await reopened.close()
    }

    func testCorruptTombstoneIsRejectedWithoutRewriting() async throws {
        let store = try ComparisonStore(url: url)
        let source = try await store.save(id: UUID(), title: "Erase", payload: Data([1]), savedAt: Date())
        try await store.erase(id: source.id, expectedRevision: 1, operationID: UUID(), at: Date())
        try await store.close()
        try sql("DROP TRIGGER immutable_tombstone_update; UPDATE comparison_tombstones SET operation_id = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url)) { error in
            XCTAssertEqual(error as? ComparisonStoreError, .corruptRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testErasureCheckpointsManagedWALWhenNoReaderBlocksIt() async throws {
        let store = try ComparisonStore(url: url)
        try sql("PRAGMA journal_mode = WAL")
        let secret = "PRIVATE-WAL-TITLE-\(UUID().uuidString)"
        let source = try await store.save(id: UUID(), title: secret, payload: Data(repeating: 123, count: 12_000), savedAt: Date())
        try await store.erase(id: source.id, expectedRevision: 1, operationID: UUID(), at: Date())
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data(secret.utf8)))
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            XCTAssertNil(try Data(contentsOf: wal).range(of: Data(secret.utf8)))
        }
        try await store.close()
    }

    func testErasureInvalidInputAndMissingSourceDoNotCreateReceipts() async throws {
        let store = try ComparisonStore(url: url)
        for (revision, date) in [(Int64(0), Date()), (Int64(1), Date(timeIntervalSinceReferenceDate: .infinity))] {
            do {
                try await store.erase(id: UUID(), expectedRevision: revision, operationID: UUID(), at: date)
                XCTFail("Invalid erasure must fail")
            } catch { XCTAssertEqual(error as? ComparisonStoreError, .invalidInput) }
        }
        do {
            try await store.erase(id: UUID(), expectedRevision: 1, operationID: UUID(), at: Date())
            XCTFail("Missing sources must not acquire a fabricated receipt")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .notFound) }
        let receipts = try await store.tombstones()
        XCTAssertTrue(receipts.isEmpty)
        try await store.close()
    }

    private func makeVersionOneFixture() throws -> (workspace: UUID, id: UUID) {
        let workspace = UUID()
        let id = UUID()
        // The shipped v1 schema, independent of the current migration implementation.
        try sql("""
            CREATE TABLE workspace (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL UNIQUE);
            CREATE TABLE comparisons (
                id TEXT PRIMARY KEY NOT NULL,
                workspace_id TEXT NOT NULL REFERENCES workspace(id),
                head_revision INTEGER NOT NULL CHECK(head_revision > 0),
                FOREIGN KEY (id, head_revision) REFERENCES comparison_revisions(comparison_id, revision) DEFERRABLE INITIALLY DEFERRED
            );
            CREATE TABLE comparison_revisions (
                comparison_id TEXT NOT NULL REFERENCES comparisons(id) DEFERRABLE INITIALLY DEFERRED,
                revision INTEGER NOT NULL CHECK(revision > 0), title TEXT NOT NULL,
                envelope BLOB NOT NULL CHECK(length(envelope) <= 2097152), saved_at REAL NOT NULL,
                PRIMARY KEY (comparison_id, revision)
            );
            CREATE TRIGGER immutable_revision_update BEFORE UPDATE ON comparison_revisions
            BEGIN SELECT RAISE(ABORT, 'immutable revision'); END;
            CREATE TRIGGER immutable_revision_delete BEFORE DELETE ON comparison_revisions
            BEGIN SELECT RAISE(ABORT, 'immutable revision'); END;
            INSERT INTO workspace VALUES (1, '\(workspace.uuidString)');
            INSERT INTO comparisons VALUES ('\(id.uuidString)', '\(workspace.uuidString)', 2);
            INSERT INTO comparison_revisions VALUES ('\(id.uuidString)', 1, 'Before', CAST('{"version":1,"payload":"AQ=="}' AS BLOB), 12);
            INSERT INTO comparison_revisions VALUES ('\(id.uuidString)', 2, 'After', CAST('{"version":1,"payload":"Ag=="}' AS BLOB), 13);
            PRAGMA user_version = 1;
            """)
        return (workspace, id)
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
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TestError.sqlite }
        return sqlite3_column_int64(statement, 0)
    }

    private enum TestError: Error { case sqlite }
}
