import XCTest
@testable import CoreDomain

final class PantryOrganizationFieldTests: XCTestCase {
    private let origin = UUID(), id = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
    private func apply(_ change: InventoryChange, after prior: InventoryLot? = nil) throws -> InventoryPreparedChange {
        let command = InventoryCommand(id: UUID(), originID: origin, lotID: id, eventID: UUID(),
            expectedRevision: prior?.revision, occurredAt: now, change: change)
        return try InventoryEngine.prepare(command, current: prior, at: now)
    }

    func testOldHeadDecodesAndOnlyLabelEditsKeepOriginalDateGuidanceValid() throws {
        let amount = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        let seed = InventoryLotSeed(foodID: UUID(), name: "Peas", source: .manual(originID: origin, sourceID: id),
            location: .freezer, unit: .count, count: .exact(amount), openedAt: now)
        let old = try apply(.create(seed, observationID: UUID())).lot
        let json = try JSONEncoder().encode(old)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNil(object["namedPlace"])
        XCTAssertNil(object["spreadsheetRow"])
        XCTAssertNil(object["physicalBasis"])
        XCTAssertEqual(try JSONDecoder().decode(InventoryLot.self, from: json), old)
        let place = InventoryNamedPlace(storage: " Garage ", drawer: " Top drawer ")
        let first = try apply(.revise(.init(placeEdit: .assign(place))), after: old)
        XCTAssertNil(first.observation)
        XCTAssertEqual(first.lot.namedPlace?.storage, "Garage")
        XCTAssertEqual(first.lot.openedAt, now)
        XCTAssertEqual(first.lot.observationID, old.observationID)
        let second = try apply(.revise(.init(placeEdit: .clear)), after: first.lot).lot
        XCTAssertTrue(second.retainsPhysicalState(at: old.revision))
        XCTAssertTrue(second.retainsPhysicalState(at: first.lot.revision))
        XCTAssertFalse(second.retainsPhysicalState(at: second.revision + 1))
        let moved = try apply(.move(.fridge), after: first.lot).lot
        XCTAssertNil(moved.namedPlace)
        XCTAssertFalse(moved.retainsPhysicalState(at: old.revision))
        XCTAssertThrowsError(try apply(.revise(.init(location: .fridge, placeEdit: .assign(place))), after: old))
        XCTAssertThrowsError(try apply(.revise(.init(placeEdit: .assign(.init(storage: "", drawer: "A")))), after: old))
    }

    func testSpreadsheetCorrectionCannotRewriteObservedFoodOrSwitchSourceIdentity() throws {
        func row(source: String = "Cocina", amount: String) -> InventorySpreadsheetRow {
            InventorySpreadsheetRow(sourceName: source, rowKey: "lot-007", label: "Chícharos", quantity: amount,
                unit: "kg", barcode: "001", date: "02/03/26", location: "Congelador", category: "", note: "")
        }
        let seed = InventoryLotSeed(foodID: UUID(), name: "Chícharos", source: .manual(originID: origin, sourceID: id),
            location: .freezer, unit: .count, count: .unknown, spreadsheetRow: row(amount: "1,5"))
        let imported = try apply(.create(seed, observationID: UUID())).lot
        let revised = try apply(.revise(.init(spreadsheetRow: row(amount: "2,5"))), after: imported)
        XCTAssertEqual(revised.lot.count, .unknown)
        XCTAssertEqual(revised.lot.confirmedAt, imported.confirmedAt)
        XCTAssertNil(revised.observation)
        XCTAssertEqual(revised.lot.spreadsheetRow?.quantity, "2,5")
        XCTAssertThrowsError(try apply(.revise(.init(spreadsheetRow: row(source: "Other", amount: "3"))), after: revised.lot))
    }
}
