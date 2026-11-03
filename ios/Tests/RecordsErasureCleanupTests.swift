import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

final class RecordsErasureCleanupTests: XCTestCase {
    @MainActor func testFailedPrivateProjectionCleanupKeepsExactRetirementPendingAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let first = LedgerModel(databaseURL: url)
        await first.open()
        let started = await first.startShop(title: "Private shopping list"); XCTAssertTrue(started)
        let review = try await first.reviewWholeLedgerDeletion()
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("recovery.json"))
        let record = ArchiveRecord(id: try XCTUnwrap(first.shop?.id).uuidString, origin: "ledger/" + review.workspaceID.uuidString,
            revision: "old", kind: .ledger, title: "Private shopping list", savedAtMilliseconds: 100, helperLines: [HelperLine(label: "Original private item")])
        let envelope = try ArchiveCodec.make(records: [record], kind: .helperShop, origin: record.origin, revision: "old")
        _ = try await registry.apply(registry.review(envelope))
        var eraseCalls: [UUID] = []
        var failDerivedCopy = true
        var failRecoveredPurge = true
        var purges = 0
        let cleanup = RecordsErasureCleanup(eraseLedgerWorkspace: { id in
            eraseCalls.append(id)
            if failDerivedCopy { throw CocoaError(.fileWriteNoPermission) }
        }, erasePickupRecord: { _, _ in XCTFail("Ledger cleanup must not silently delete a pickup") })
        do {
            try await RecordsLedgerErasure.complete(review, ledger: first, registry: registry, cleanup: cleanup) { purges += 1 }
            XCTFail("Failed raw-copy cleanup must keep deletion pending")
        } catch {}
        XCTAssertTrue(first.hasPendingLedgerDeletion)
        XCTAssertFalse(first.ready)
        XCTAssertEqual(purges, 0)
        let blocked = try await registry.review(envelope)
        XCTAssertEqual(blocked.rows.first?.disposition, .erased, "Recovery is blocked even while another private-copy cleanup is retrying")
        let retiredStore = try LedgerStore(url: url)
        let initialReceipts = try await retiredStore.tombstones()
        let receipt = try XCTUnwrap(initialReceipts.first)
        let restarted = LedgerModel(databaseURL: url)
        await restarted.open()
        XCTAssertTrue(restarted.hasPendingLedgerDeletion)
        XCTAssertEqual(restarted.pendingLedgerDeletionReview, review)
        let edit = await restarted.startShop(title: "Must not bypass pending deletion")
        XCTAssertFalse(edit)
        failDerivedCopy = false
        do {
            try await RecordsLedgerErasure.complete(review, ledger: restarted, registry: registry, cleanup: cleanup) {
                purges += 1
                if failRecoveredPurge { throw CocoaError(.fileWriteNoPermission) }
            }
            XCTFail("Failed recovery-directory purge must also keep deletion pending")
        } catch {}
        XCTAssertTrue(restarted.hasPendingLedgerDeletion)
        failRecoveredPurge = false
        try await RecordsLedgerErasure.complete(review, ledger: restarted, registry: registry, cleanup: cleanup) { purges += 1 }
        XCTAssertTrue(restarted.ready)
        XCTAssertFalse(restarted.hasPendingLedgerDeletion)
        XCTAssertEqual(restarted.sourceWorkspaceID, receipt.replacementWorkspaceID)
        XCTAssertEqual(eraseCalls, [review.workspaceID, review.workspaceID, review.workspaceID])
        XCTAssertEqual(purges, 2)
        let after = try await retiredStore.tombstones()
        XCTAssertEqual(after, [receipt], "Retries preserve the exact original retirement operation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("erase-intent.json").path))
    }
}
