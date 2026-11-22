import CSQLite
import Foundation
import XCTest
@testable import LocalStore

final class PrivateDeliveryPurchaseTests: XCTestCase {
    private func openEmptyInventory(at url: URL) async throws -> ComparisonStore {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let token = try await store.inventorySourceToken()
        let plan = InventoryMigrationPlan(migrationID: UUID(), workspaceID: store.workspaceID, expectedRevision: 0, sourceToken: token,
            reviewContext: Data([1]), expectedChunkCount: 0, expectedRecordCount: 0, manifestDigest: InventoryMigrationManifest.initialDigest)
        _ = try await store.beginInventoryMigration(plan)
        _ = try await store.finishInventoryMigration(id: plan.migrationID)
        return store
    }

    func testDeliveryOnlyDaySurvivesStoreReopenAndFileRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delivery.sqlite")
        let store = try await openEmptyInventory(at: url)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let delivered = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        let imported = delivered.addingTimeInterval(80_123)
        let person = UUID()
        let record = PrivateDeliveryRevision(digest: Data(repeating: 9, count: 32), layoutID: UUID(),
            order: "Delivery-123", merchant: "Market", kind: .finalReceipt, purchaseDate: nil, deliveryDate: delivered,
            importedAt: imported, finalCents: 200, lines: [], deliveryTimeZoneIdentifier: calendar.timeZone.identifier)
        _ = try await store.savePrivateDelivery(record, persona: person, expectedRevision: 0)
        try await store.close()

        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let result = try await reopened.privateDeliveryWithFile(persona: person, digest: record.digest)
        let entry = try XCTUnwrap(result)
        XCTAssertEqual(entry.latest, record)
        XCTAssertNil(entry.latest.purchaseDate)
        XCTAssertNil(entry.latest.purchaseDay)
        XCTAssertEqual(entry.latest.deliveryTimeZoneIdentifier, "America/New_York")
        XCTAssertEqual(entry.latest.deliveryDay, "2026-11-20")
        XCTAssertEqual(entry.latest.deliveryDate, delivered)
        XCTAssertEqual(entry.latest.importedAt, imported)
        let replay = try await reopened.savePrivateDelivery(record, persona: person, expectedRevision: 0)
        XCTAssertEqual(replay, entry)
        let history = try await reopened.privateDeliveryHistory(persona: person, orderKey: record.orderKey)
        XCTAssertEqual(history, [entry])
        try await reopened.close()
    }

    func testLegacyDeliveryDateDoesNotBorrowPurchaseZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let purchased = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17)))
        let delivered = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        let record = PrivateDeliveryRevision(digest: Data(repeating: 9, count: 32), layoutID: UUID(),
            order: "Delivery-123", merchant: "Market", kind: .finalReceipt, purchaseDate: purchased, deliveryDate: delivered,
            importedAt: delivered.addingTimeInterval(50_000), finalCents: 200, lines: [],
            purchaseTimeZoneIdentifier: calendar.timeZone.identifier, deliveryTimeZoneIdentifier: calendar.timeZone.identifier)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        func decoded() throws -> PrivateDeliveryRevision {
            try JSONDecoder().decode(PrivateDeliveryRevision.self, from: JSONSerialization.data(withJSONObject: json))
        }
        json["deliveryDay"] = "2026-11-19"
        XCTAssertThrowsError(try decoded().validate())
        json.removeValue(forKey: "deliveryTimeZoneIdentifier")
        json.removeValue(forKey: "deliveryDay")
        let legacy = try decoded()
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertEqual(legacy.purchaseDay, "2026-11-17")
        XCTAssertEqual(legacy.deliveryDate, delivered)
        XCTAssertNil(legacy.deliveryDay)
        XCTAssertNil(legacy.deliveryTimeZoneIdentifier)
        json.removeValue(forKey: "purchaseDay")
        json.removeValue(forKey: "purchaseTimeZoneIdentifier")
        let old = try decoded()
        XCTAssertNoThrow(try old.validate())
        XCTAssertNil(old.purchaseDay)
        XCTAssertNil(old.deliveryDay)
        XCTAssertEqual(old.deliveryDate, delivered)
    }

    func testPrivateRevisionsRefundReplayAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("private.sqlite")
        let store = try await openEmptyInventory(at: url)
        let person = UUID(), other = UUID()
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let purchased = try XCTUnwrap(eastern.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        let before = try await store.inventoryState()
        func record(_ byte: UInt8, _ kind: PrivateDeliveryRevision.Kind, total: Int?, order: String = "AB-090") -> PrivateDeliveryRevision {
            .init(digest: Data(repeating: byte, count: 32), layoutID: UUID(), order: order, merchant: "Market",
                  kind: kind, purchaseDate: kind == .finalReceipt ? purchased : nil, deliveryDate: nil, importedAt: Date(), finalCents: total, lines: kind == .refund
                  ? [.init(page: 1, line: 1, scanned: false, uncertain: false, wording: "Partial refund -$2.00", disposition: .refund, cents: -200)] : [],
                  purchaseTimeZoneIdentifier: kind == .finalReceipt ? eastern.timeZone.identifier : nil)
        }
        let original = record(1, .finalReceipt, total: 2400)
        let first = try await store.savePrivateDelivery(original, persona: person, expectedRevision: 0)
        XCTAssertTrue(first.latest.lines.isEmpty)
        let refund = record(2, .refund, total: nil)
        let second = try await store.savePrivateDelivery(refund, persona: person, expectedRevision: 1)
        XCTAssertNil(second.latest.finalCents)
        let replay = try await store.savePrivateDelivery(original, persona: person, expectedRevision: 0)
        XCTAssertEqual(replay, second)
        do {
            _ = try await store.savePrivateDelivery(record(3, .adjustment, total: 2100), persona: person, expectedRevision: 1)
            XCTFail("A stale review must not overwrite a newer receipt.")
        } catch ComparisonStoreError.staleInventory {}
        do {
            _ = try await store.savePrivateDelivery(record(1, .finalReceipt, total: 2400, order: "another"), persona: person, expectedRevision: 0)
            XCTFail("The same PDF cannot become a new order.")
        } catch ComparisonStoreError.operationConflict {}
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let revisions = try await reopened.privateDeliveryHistory(persona: person, orderKey: original.orderKey)
        let otherHistory = try await reopened.privateDeliveryPurchases(persona: other)
        let heads = try await reopened.privateDeliveryPurchases(persona: person)
        let state = try await reopened.inventoryState()
        XCTAssertEqual(revisions.map(\.revision), [2, 1])
        XCTAssertEqual(revisions.last?.latest.purchaseDay, "2026-11-20")
        XCTAssertEqual(revisions.last?.latest.purchaseTimeZoneIdentifier, eastern.timeZone.identifier)
        XCTAssertNil(revisions.first?.latest.purchaseDay)
        XCTAssertTrue(otherHistory.isEmpty)
        XCTAssertEqual(heads.map(\.revision), [2])
        XCTAssertEqual(before, state)
        _ = try await reopened.savePrivateDelivery(original, persona: other, expectedRevision: 0)
        try await reopened.deletePrivateDelivery(persona: person, orderKey: original.orderKey, expectedRevision: 2)
        let erased = try await reopened.privateDeliveryWithFile(persona: person, digest: original.digest)
        XCTAssertNil(erased)
        let otherCopy = try await reopened.privateDeliveryPurchases(persona: other)
        XCTAssertEqual(otherCopy.count, 1)
        let ambiguous = PrivateDeliveryRevision(digest: Data(repeating: 8, count: 32), layoutID: UUID(), order: "unknown-food",
            merchant: "Market", kind: .finalReceipt, purchaseDate: nil, deliveryDate: nil, importedAt: Date(), finalCents: 800,
            lines: [.init(page: 1, line: 1, scanned: true, uncertain: true, wording: "BURGER $8.00", disposition: .unresolved, cents: 800)])
        _ = try await reopened.savePrivateDelivery(ambiguous, persona: other, expectedRevision: 0)
        try await reopened.reviewPrivateDeliveryLine(persona: other, orderKey: ambiguous.orderKey, digest: ambiguous.digest, ordinal: 0, from: .unresolved, to: .readyToEat)
        let choices = try await reopened.privateDeliveryHistory(persona: other, orderKey: ambiguous.orderKey)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices.first?.latest.lines.first?.disposition, .readyToEat)
        let source = try await reopened.privateDeliveryWithFile(persona: other, digest: ambiguous.digest)
        XCTAssertEqual(source?.latest.lines.first?.disposition, .unresolved)
        do {
            try await reopened.reviewPrivateDeliveryLine(persona: other, orderKey: ambiguous.orderKey, digest: ambiguous.digest, ordinal: 0, from: .unresolved, to: .freezer)
            XCTFail("A stale decision cannot overwrite a newer review.")
        } catch ComparisonStoreError.staleInventory {}
        let currentToken = try await reopened.inventorySourceToken()
        _ = try await reopened.eraseInventoryOrigin(expectedRevision: state.revision, sourceToken: currentToken, operationID: UUID())
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var query: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT (SELECT COUNT(*) FROM private_delivery_revisions) + (SELECT COUNT(*) FROM private_delivery_choices)", -1, &query, nil), SQLITE_OK)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(query, 0), 0)
    }
}
