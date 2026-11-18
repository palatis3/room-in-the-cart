import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryPickupPendingStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let directory: URL
        let pendingDirectory: URL
        let cleanup: SQLiteFixtureDirectory
        let inventory: ComparisonStore
        let ledger: LedgerStore
        let port: PantryPickupCommitPort
        let submission: PantryPickupCommitPort.Submission
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(producer, inventory, ledger)
        let token = try await inventory.inventorySourceToken()
        _ = try await inventory.commitInventory(.init(workspaceID: inventory.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data("reviewed empty inventory".utf8), mode: .activate, sourceToken: token), at: now)
        let added = await producer.addUrgent(.init(id: UUID(), food: "Wraps", meal: "Dinner",
            required: .init(amount: try Rational(6), unit: .count, originalLiteral: "6"),
            available: .init(amount: try Rational(0), unit: .count, originalLiteral: "0"), due: nil, confirmedAt: now))
        XCTAssertTrue(added)
        let snapshot = try await producer.archiveSnapshot(), saved = try XCTUnwrap(snapshot.records.first)
        let head = PantryLegacyMigration.SourceHead(id: saved.id, revision: 1, payload: saved.payload, savedAt: now)
        let port = PantryPickupCommitPort(store: inventory, ledger: ledger, gate: PantryMutationGate(),
            authorize: { _, _ in true }, clock: { instant })
        let review = try await port.prepare(operationID: UUID(), changedHeads: [head], preparedAt: now)
        return Fixture(directory: directory, pendingDirectory: directory.appendingPathComponent("pending", isDirectory: true),
            cleanup: cleanup, inventory: inventory, ledger: ledger, port: port, submission: review.submission)
    }
    private func store(_ f: Fixture) throws -> PantryPickupPendingStore {
        try .init(directory: f.pendingDirectory, inventoryWorkspaceID: f.inventory.workspaceID, ledgerWorkspaceID: f.ledger.workspaceID)
    }
    private func save(_ f: Fixture, in pending: PantryPickupPendingStore) throws -> PantryPickupPendingStore.Entry {
        try pending.save(submission: f.submission, selection: .select(f.submission.changedHeads[0].id),
            recoveryOperationID: f.submission.request.operationID, requiresActionAuthorization: true)
    }

    func testExactProtectedSubmissionAndActionMetadataSurviveReopen() async throws {
        let f = try await fixture(), pending = try store(f)
        XCTAssertNil(try pending.read())
        let original = try save(f, in: pending), reopened = try store(f)
        XCTAssertEqual(try reopened.read(), original)
        XCTAssertEqual(try save(f, in: reopened), original)
        XCTAssertTrue(original.requiresActionAuthorization)
        XCTAssertEqual(original.recoveryOperationID, f.submission.request.operationID)
        let attributes = try FileManager.default.attributesOfItem(atPath: pending.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // The tested simulator returns no protection attribute even after the
        // Foundation protection APIs succeed. This assertion is a physical-device
        // gate; simulator results establish permissions/backup policy and replay,
        // not hardware-backed protection or behavior while the phone is locked.
        #if os(iOS) && !targetEnvironment(simulator)
        let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? (attributes[.protectionKey] as? String)
        XCTAssertEqual(protection, FileProtectionType.complete.rawValue)
        #endif
        XCTAssertEqual(try pending.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let applied = try await f.port.apply(original.submission)
        XCTAssertEqual(applied.sources.first?.payload, original.submission.changedHeads.first?.payload)
    }

    func testSameOperationSubstitutionMetadataChangeAndAnotherOperationCannotReplacePending() async throws {
        let f = try await fixture(), pending = try store(f), original = try save(f, in: pending)
        let oldHead = f.submission.changedHeads[0]
        let changed = PantryPickupCommitPort.Submission(version: 1, request: f.submission.request,
            changedHeads: [.init(id: oldHead.id, revision: oldHead.revision, payload: oldHead.payload + Data(" ".utf8), savedAt: oldHead.savedAt)],
            preparedAt: f.submission.preparedAt)
        do { _ = try pending.save(submission: changed, selection: original.selection, recoveryOperationID: original.recoveryOperationID,
            requiresActionAuthorization: true); XCTFail("changed original bytes") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .operationConflict) }
        do { _ = try pending.save(submission: f.submission, selection: original.selection, recoveryOperationID: original.recoveryOperationID,
            requiresActionAuthorization: false); XCTFail("cannot drop current action authorization") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .operationConflict) }
        let other = try await f.port.prepare(operationID: UUID(), changedHeads: f.submission.changedHeads, preparedAt: now)
        do { _ = try pending.save(submission: other.submission, selection: .preserve, recoveryOperationID: nil,
            requiresActionAuthorization: false); XCTFail("one pending operation") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .occupied) }
        XCTAssertEqual(try pending.read(), original)
    }

    func testCorruptionOversizeAndForeignScopeFailClosedWithoutReplacingBytes() async throws {
        let f = try await fixture(), pending = try store(f)
        _ = try save(f, in: pending)
        let original = try Data(contentsOf: pending.fileURL)
        let foreign = try PantryPickupPendingStore(directory: f.pendingDirectory, inventoryWorkspaceID: f.inventory.workspaceID, ledgerWorkspaceID: UUID())
        do { _ = try foreign.read(); XCTFail("foreign ledger") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .foreignOrigin) }
        XCTAssertEqual(try Data(contentsOf: pending.fileURL), original)
        let foreignInventory = try PantryPickupPendingStore(directory: f.pendingDirectory, inventoryWorkspaceID: UUID(), ledgerWorkspaceID: f.ledger.workspaceID)
        try original.write(to: foreignInventory.fileURL, options: .atomic)
        do { _ = try foreignInventory.read(); XCTFail("copied foreign inventory origin") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .foreignOrigin) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entry = try XCTUnwrap(object["entry"] as? [String: Any]); entry["requiresActionAuthorization"] = false; object["entry"] = entry
        let tampered = try JSONSerialization.data(withJSONObject: object)
        try tampered.write(to: pending.fileURL, options: .atomic)
        do { _ = try save(f, in: pending); XCTFail("valid JSON with changed metadata") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .corrupt) }
        XCTAssertEqual(try Data(contentsOf: pending.fileURL), tampered)
        let oversized = Data(repeating: 32, count: PantryPickupPendingStore.maximumFileBytes + 1)
        try oversized.write(to: pending.fileURL, options: .atomic)
        do { _ = try pending.read(); XCTFail("bounded read") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .corrupt) }
        XCTAssertEqual(try Data(contentsOf: pending.fileURL).count, oversized.count)
    }

    func testAdoptionAcknowledgmentSurvivesFailedCleanupAndExactRetry() async throws {
        let f = try await fixture(), pending = try store(f), original = try save(f, in: pending)
        let applied = try await f.port.apply(original.submission)
        do { _ = try pending.acknowledgeAdoption(expected: original, receipt: applied.receipt,
            currentInventoryRevision: applied.receipt.revision - 1); XCTFail("current state not adopted") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .operationConflict) }
        XCTAssertEqual(try pending.read(), original)
        let adopted = try pending.acknowledgeAdoption(expected: original, receipt: applied.receipt,
            currentInventoryRevision: applied.current.state.revision)
        XCTAssertNotNil(adopted.acknowledgment)
        enum Interruption: Error { case cleanup }
        let failing = try PantryPickupPendingStore(directory: f.pendingDirectory,
            inventoryWorkspaceID: f.inventory.workspaceID, ledgerWorkspaceID: f.ledger.workspaceID,
            removeFile: { _ in throw Interruption.cleanup })
        do { try failing.clearAcknowledged(expected: adopted); XCTFail("cleanup interruption") }
        catch Interruption.cleanup { }
        let reopened = try store(f)
        XCTAssertEqual(try reopened.read(), adopted)
        XCTAssertEqual(try save(f, in: reopened), adopted)
        let replay = try await f.port.apply(original.submission)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(try reopened.acknowledgeAdoption(expected: original, receipt: replay.receipt,
            currentInventoryRevision: replay.current.state.revision), adopted)
        try reopened.clearAcknowledged(expected: adopted)
        XCTAssertNil(try reopened.read())
        try reopened.clearAcknowledged(expected: adopted)
    }

    func testDiscardAndClearRequireExactExpectedBodyAndCorrectPhase() async throws {
        let f = try await fixture(), pending = try store(f), original = try save(f, in: pending)
        let wrong = PantryPickupPendingStore.Entry(submission: original.submission, selection: .preserve,
            recoveryOperationID: original.recoveryOperationID, requiresActionAuthorization: true, acknowledgment: nil)
        do { try pending.discardUnapplied(expected: wrong); XCTFail("changed expected selection") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .operationConflict) }
        do { try pending.clearAcknowledged(expected: original); XCTFail("unacknowledged cleanup") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .missingAcknowledgment) }
        try pending.discardUnapplied(expected: original)
        XCTAssertNil(try pending.read())
        XCTAssertThrowsError(try pending.ensureProtected(expected: original)) {
            XCTAssertEqual($0 as? PantryPickupPendingStore.Failure, .operationConflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.fileURL.path))
        _ = try save(f, in: pending)
        let applied = try await f.port.apply(original.submission)
        let adopted = try pending.acknowledgeAdoption(expected: original, receipt: applied.receipt,
            currentInventoryRevision: applied.current.state.revision)
        do { try pending.discardUnapplied(expected: adopted); XCTFail("cannot call committed work unapplied") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .operationConflict) }
        do { try pending.discardUnapplied(expected: original); XCTFail("stale pending-only expectation") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .operationConflict) }
        XCTAssertEqual(try pending.read(), adopted)
    }
}
