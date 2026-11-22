import CSQLite
import Foundation
import XCTest
@testable import LocalStore

final class ReviewedPutawayReceiptTests: XCTestCase {
    func testExistingDatabaseUpgradesAndInterruptedMixedReceiptRetriesAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pantry.sqlite")
        let initial = try ComparisonStore(url: url, inventoryEnabled: true)
        let workspace = initial.workspaceID, owner = UUID()
        let existing = InventoryRecordKey(.lot, UUID())
        let token = try await initial.inventorySourceToken()
        try await initial.commitInventory(.init(workspaceID: workspace, operationID: UUID(), expectedRevision: 0,
            request: Data([0]), mode: .activate, sourceToken: token, writes: [.init(record: .init(key: existing, revision: 1, payload: Data([0])), expectedRevision: 0)]))
        try await initial.close()
        // Match the old schema. Upgrading installs the new evidence tables without rewriting inventory.
        try execute("DROP TRIGGER retire_putaway_receipts; DROP TABLE putaway_receipt_coordinates; DROP TABLE putaway_receipt_lines; DROP TABLE putaway_receipts;", at: url)
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let lot = InventoryRecordKey(.lot, UUID())
        let header = ReviewedReceiptHeader(id: UUID(), owner: owner, merchant: "Store", date: Date(timeIntervalSince1970: 150), totalMinor: 1200, purchaseDay: "1969-12-31")
        let physical = ReviewedReceiptDecision(id: UUID(), ordinal: 0, original: "2 pears", name: "Pears", kind: .stored, lotID: lot.id, paidMinor: nil)
        let eaten = ReviewedReceiptDecision(id: UUID(), ordinal: 1, original: "Lunch", name: "Lunch", kind: .eaten, lotID: nil, paidMinor: nil)
        let identity = UUID(), layout = UUID()
        let batch = InventoryBatch(workspaceID: workspace, operationID: UUID(), expectedRevision: 1, request: Data([1]),
            writes: [.init(record: .init(key: lot, revision: 1, payload: Data([1])), expectedRevision: 0)],
            acquisitions: [.init(id: UUID(), receiptID: header.id, lineID: physical.id, lotID: lot.id, revision: 1, supersedesID: nil, payload: Data([2]))],
            reviewedReceipt: .init(header: header, decisions: [physical, eaten], identities: [identity], layout: layout, ordinals: [3, 5]))
        try execute("CREATE TRIGGER simulate_interruption BEFORE INSERT ON putaway_receipt_lines WHEN NEW.lot IS NULL BEGIN SELECT RAISE(ABORT,'interrupted'); END;", at: url)
        do { try await store.commitInventory(batch); XCTFail("Receipt must roll back") } catch ComparisonStoreError.database {}
        let afterFailure = try await store.inventoryRecords(kind: .lot)
        let failureHeader = try await store.reviewedReceiptHeader(header.id, owner: owner)
        let acquisitions = try await store.acquisitionRows(receiptID: header.id)
        XCTAssertEqual(afterFailure.map(\.key), [existing])
        XCTAssertNil(failureHeader)
        XCTAssertTrue(acquisitions.isEmpty)
        try await store.close()
        try execute("DROP TRIGGER simulate_interruption", at: url)
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let result = try await reopened.commitInventory(batch)
        let replay = try await reopened.commitInventory(batch)
        XCTAssertEqual(result, replay)
        let headers = try await reopened.reviewedReceiptHeaders(owner: owner, after: nil)
        let decisions = try await reopened.reviewedReceiptDecisions(receipt: header.id, owner: owner)
        let origin = try await reopened.acquisitionReceiptID(for: identity)
        XCTAssertEqual(headers, [header])
        XCTAssertEqual(decisions.sorted { $0.ordinal < $1.ordinal }, [physical, eaten])
        XCTAssertEqual(origin, header.id)
        let savedFile = try await reopened.reviewedReceiptHeader(imageIdentity: identity, owner: owner)
        let unrelatedFileOwner = try await reopened.reviewedReceiptHeader(imageIdentity: identity, owner: UUID())
        let onlyReceiptID = try await reopened.reviewedReceiptHeader(imageIdentity: header.id, owner: owner)
        XCTAssertEqual(savedFile, header)
        XCTAssertNil(unrelatedFileOwner)
        XCTAssertNil(onlyReceiptID)
        let coordinates = try await reopened.reviewedReceiptCoordinates(receipt: header.id, owner: owner, layout: layout, ordinals: [3,5])
        XCTAssertEqual(coordinates, [3: physical.id, 5: eaten.id])

        try await reopened.commitInventory(.init(workspaceID: workspace, operationID: UUID(), expectedRevision: result.revision, request: Data([2]),
            erasures: [.init(key: lot, expectedRevision: 1)]))
        let surviving = try await reopened.reviewedReceiptDecisions(receipt: header.id, owner: owner)
        XCTAssertEqual(surviving, [eaten])
        let otherOwner = try await reopened.reviewedReceiptHeaders(owner: UUID(), after: nil)
        XCTAssertTrue(otherOwner.isEmpty)
        do { _ = try await reopened.commitInventory(batch); XCTFail("An erased lot must stay erased on replay") } catch ComparisonStoreError.erased {}
        try await reopened.close()
    }

    func testLegacyReceiptsDecodeWithoutInventingAPurchaseDay() throws {
        let header = ReviewedReceiptHeader(id: UUID(), owner: UUID(), merchant: "Market", date: Date(), totalMinor: nil)
        let bytes = try JSONEncoder().encode(header)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("purchaseDay"))
        XCTAssertNil(try JSONDecoder().decode(ReviewedReceiptHeader.self, from: bytes).purchaseDay)
        XCTAssertTrue(ReviewedReceiptHeader.validDay("2024-02-29"))
        XCTAssertFalse(ReviewedReceiptHeader.validDay("2026-02-29"))
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ComparisonStoreError.corruptRecord }
        defer { sqlite3_close(db) }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw ComparisonStoreError.database(rc) }
    }
}
