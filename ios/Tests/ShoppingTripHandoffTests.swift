import CoreDomain
import SQLite3
import XCTest
@testable import RoomInTheCart

@MainActor final class ShoppingTripHandoffTests: XCTestCase {
    func testHandoffUsesOnlySelectedOutstandingPackAndOptionalNumericPackNote() throws {
        var shop = ShoppingLedger(basis: ShopBasis(branch: "Private retailer"))
        let source = CaptureImportLine(originalText: "Private receipt wording", name: "Tortillas", packCount: 2,
            amountPerPack: .init(amount: try Rational(8), unit: .count, originalLiteral: "secret label"),
            purpose: "Private dinner", exclusions: ["private household note"])
        try shop.commitImport(shop.stageCaptureImport(id: UUID(), originalText: "Private capture", source: .typed, lines: [source]))
        let id = try XCTUnwrap(shop.lines.first?.id)
        try shop.pickPart(lineID: id, amount: Rational(8), expectedRevision: shop.revisionID)
        try shop.recordPickedPrice(lineID: id, expectedRevision: shop.revisionID, total: .init(minorUnits: 725),
                                   membership: false, weighted: false, conditionsConfirmed: false)
        try shop.markUnavailable(lineID: id, expectedRevision: shop.revisionID)
        let other = try shop.addManualLine(name: "Beans", quantity: .init(amount: .one, unit: .count, originalLiteral: "1"), notes: "private")
        try shop.setChecked(lineID: other, checked: true)
        let rows = TripHandoffRow.outstanding(in: shop)
        XCTAssertEqual(rows.map(\.id), [id])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.text(includePack: false), "Tortillas · " + tripFormat("%@ pack", "1"))
        XCTAssertEqual(row.text(includePack: true), row.text(includePack: false) + " · " + tripFormat("%@ %@ per pack", "8", UnitOfMeasure.count.displayName))
        let copy = row.text(includePack: true).lowercased()
        for excluded in ["private", "secret", "7.25", "beans"] { XCTAssertFalse(copy.contains(excluded)) }
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.lines.first(where: { $0.id == id })?.quantity.amount, try Rational(8))
        XCTAssertEqual(review.lines.first(where: { $0.id == id })?.packages?.first?.count, 1)
        XCTAssertEqual(review.needs.first(where: { $0.orderLineID == id })?.amount.amount, try Rational(16))
    }

    func testCheckoutOmitsUnfoundAndDeferredUnitsButPreservesSourceNeeds() throws {
        var shop = ShoppingLedger(basis: ShopBasis(branch: "North"))
        let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        _ = try shop.chooseMeal(.init(title: "Omelet", ingredients: [.init(name: "Eggs", quantity: one)]))
        let missing = try XCTUnwrap(shop.lines.first?.id)
        try shop.markUnavailable(lineID: missing, expectedRevision: shop.revisionID)
        let flexible = try shop.addManualLine(name: "Jam", quantity: one)
        try shop.setChecked(lineID: flexible, checked: true)
        try shop.setBudgetFlexible(lineID: flexible, expectedRevision: shop.revisionID, flexible: true)
        try shop.leaveForNextTrip(lineID: flexible, expectedRevision: shop.revisionID)
        let otherStop = try shop.addManualLine(name: "Cilantro", quantity: nil)
        try shop.setPreferredStores(["South"], lineID: otherStop, expectedRevision: shop.revisionID)
        let picked = try shop.addInStoreFind(name: "Bread", quantity: one, expectedRevision: shop.revisionID)
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.lines.map(\.id), [picked])
        XCTAssertEqual(review.needs.map(\.orderLineID), [picked])
        XCTAssertEqual(Set(review.sourceNeeds.map(\.orderLineID)), [missing, flexible, picked])
        let recovery = PickupCheckoutMealSource(ledgerWorkspaceID: UUID(), shop: shop, needs: review.sourceNeeds,
                                                details: review.details, bindings: [])
        try recovery.validate()
        XCTAssertEqual(try recovery.definitions().first?.meal.title, "Omelet")
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: missing)?.amount, .one)
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: flexible)?.amount, .one)
    }

    func testFailedPartialPickRetriesOnceAndReopensFromPrivateLedger() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let url = directory.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: url)
        cleanup.track(model)
        await model.open()
        var shop = ShoppingLedger()
        let id = try shop.addManualLine(name: "Peppers", quantity: .init(amount: Rational(2), unit: .count, originalLiteral: "2"))
        let saved = await model.change(key: "initial") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(saved)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TRIGGER fail_trip BEFORE INSERT ON ledger_revisions BEGIN SELECT RAISE(ABORT, 'trip interrupted'); END", nil, nil, nil), SQLITE_OK)
        let denied = await model.editShop(key: "pick", shopID: shop.id, authorize: { false }) { try $0.pickPart(lineID: id, amount: .one, expectedRevision: shop.revisionID) }
        XCTAssertFalse(denied)
        let failed = await model.editShop(key: "pick", shopID: shop.id, authorize: { true }) { try $0.pickPart(lineID: id, amount: .one, expectedRevision: shop.revisionID) }
        XCTAssertFalse(failed); XCTAssertTrue(model.hasPendingSave)
        XCTAssertNil(try model.shop?.pickedQuantity(forLineID: id))
        XCTAssertEqual(sqlite3_exec(handle, "DROP TRIGGER fail_trip", nil, nil, nil), SQLITE_OK)
        let retried = await model.retrySave()
        XCTAssertTrue(retried)
        let again = await model.retrySave()
        XCTAssertFalse(again)
        let reopened = LedgerModel(databaseURL: url)
        cleanup.track(reopened)
        await reopened.open()
        XCTAssertEqual(reopened.shop?.id, shop.id)
        XCTAssertEqual(try reopened.shop?.outstandingQuantity(forLineID: id)?.amount, .one)
        XCTAssertEqual(try reopened.shop?.pickedQuantity(forLineID: id)?.amount, .one)
    }
}
