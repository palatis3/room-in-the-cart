import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

final class PantryPersistenceCodecTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func created() throws -> InventoryPreparedChange {
        let origin = UUID(), lotID = UUID()
        let seed = InventoryLotSeed(foodID: UUID(), name: "Wraps", source: .manual(originID: origin, sourceID: lotID),
            location: .cupboard, unit: .count,
            count: .exact(Quantity(amount: try Rational(8), unit: .count, originalLiteral: "8")))
        return try InventoryEngine.prepare(InventoryCommand(id: UUID(), originID: origin, lotID: lotID,
            eventID: UUID(), expectedRevision: nil, occurredAt: now, change: .create(seed, observationID: UUID())),
            current: nil, at: now)
    }

    func testQualitativeRecountKeepsIndependentObservationIdentityAndNoNumericCredit() throws {
        let initial = try created()
        let command = InventoryCommand(id: UUID(), originID: initial.command.originID, lotID: initial.lot.id,
            eventID: UUID(), expectedRevision: 1, occurredAt: now, change: .count(.someLeft, observationID: UUID()))
        let changed = try InventoryEngine.prepare(command, current: initial.lot, at: now)
        let writes = try PantryPersistenceCodec.writes(changed)
        let lotRow = try XCTUnwrap(writes.first { $0.record.key.kind == .lot })
        let observationRow = try XCTUnwrap(writes.first { $0.record.key.kind == .observation })
        let lot = try PantryPersistenceCodec.lot(lotRow.record)
        let observation = try PantryPersistenceCodec.observation(observationRow.record)
        XCTAssertEqual(lotRow.expectedRevision, 1)
        XCTAssertEqual(lot.revision, 2)
        XCTAssertEqual(observationRow.expectedRevision, 0)
        XCTAssertEqual(observationRow.record.revision, 1)
        XCTAssertEqual(observation.revision, 2)
        XCTAssertEqual(observation.supersedesID, initial.lot.observationID)
        XCTAssertEqual(lot.observationID, observation.id)
        XCTAssertEqual(lot.count, .someLeft)
        XCTAssertNil(lot.count.quantity)
        XCTAssertFalse(writes.contains { $0.record.key.kind == .sourceLink })
    }

    func testStorageEnvelopeCannotRedirectValidFoodToAnotherLotOrRevision() throws {
        let initial = try created()
        let writes = try PantryPersistenceCodec.writes(initial)
        let row = try XCTUnwrap(writes.first { $0.record.key.kind == .lot }).record
        XCTAssertEqual(try PantryPersistenceCodec.lot(row), initial.lot)
        let redirected = InventoryRecord(key: .init(.lot, UUID()), revision: row.revision, payload: row.payload)
        XCTAssertThrowsError(try PantryPersistenceCodec.lot(redirected))
        let wrongHead = InventoryRecord(key: row.key, revision: 2, payload: row.payload)
        XCTAssertThrowsError(try PantryPersistenceCodec.lot(wrongHead))
        let future = InventoryRecord(key: row.key, revision: row.revision, payloadVersion: 2, payload: row.payload)
        XCTAssertThrowsError(try PantryPersistenceCodec.lot(future))
        let source = try XCTUnwrap(writes.first { $0.record.key.kind == .sourceLink }).record
        XCTAssertEqual(try PantryPersistenceCodec.sourceLink(source).source, initial.lot.source)
        let swapped = InventoryRecord(key: source.key, revision: 1, payload: source.payload, lotID: UUID(), source: source.source)
        XCTAssertThrowsError(try PantryPersistenceCodec.sourceLink(swapped))
    }

    func testReceiptSegmentsAndReviewedReplayBasisRemainDistinct() throws {
        let initial = try created(), origin = initial.command.originID, line = UUID()
        let first = InventorySource.receipt(originID: origin,
            key: ReceiptKey(sourceEventID: "order", orderLineID: line, branchID: "store", segmentID: "one"))
        let second = InventorySource.receipt(originID: origin,
            key: ReceiptKey(sourceEventID: "order", orderLineID: line, branchID: "store", segmentID: "two"))
        XCTAssertEqual(try PantryPersistenceCodec.sourceIdentity(first), try PantryPersistenceCodec.sourceIdentity(first))
        XCTAssertNotEqual(try PantryPersistenceCodec.sourceIdentity(first), try PantryPersistenceCodec.sourceIdentity(second))
        let request = try PantryPersistenceCodec.request(initial.command, inventoryRevision: 1)
        XCTAssertEqual(request, try PantryPersistenceCodec.request(initial.command, inventoryRevision: 1))
        XCTAssertNotEqual(request, try PantryPersistenceCodec.request(initial.command, inventoryRevision: 2))
    }
}
