import XCTest
@testable import CoreDomain

final class TripReminderTests: XCTestCase {
    func testPackingOneOfTwoIdenticalWaterLinesPersistsWithoutEvidenceOfPurchase() throws {
        var shop = ShoppingLedger()
        let first = try shop.addManualLine(name: "Agua", quantity: nil)
        let other = try shop.addManualLine(name: "Agua", quantity: nil)
        XCTAssertNil(shop.lines.first?.emptyJug)
        try shop.setEmptyJug(.toPack, replacing: nil, for: first, expectedRevision: shop.revisionID)
        let previous = shop.revisionID
        try shop.setEmptyJug(.packed, replacing: .toPack, for: first, expectedRevision: previous)
        let packedRevision = shop.revisionID
        try shop.setEmptyJug(.packed, replacing: .packed, for: first, expectedRevision: packedRevision)
        XCTAssertEqual(shop.revisionID, packedRevision)
        XCTAssertThrowsError(try shop.setEmptyJug(.toPack, replacing: nil, for: first, expectedRevision: previous))
        shop = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        XCTAssertEqual(shop.departureReminderLines.map(\.id), [first])
        XCTAssertEqual(shop.departureReminderLines.first?.emptyJug, .packed)
        XCTAssertNil(shop.lines.first(where: { $0.id == other })?.emptyJug)
        XCTAssertTrue(shop.inStorePickedLines.isEmpty)
        XCTAssertEqual(shop.pickedCartSubtotal.picked, 0)
        XCTAssertNil(try shop.quantity(forLineID: first))
        XCTAssertTrue(shop.allocations.isEmpty)
        try shop.setEmptyJug(.toPack, replacing: .packed, for: first, expectedRevision: shop.revisionID)
        try shop.setEmptyJug(nil, replacing: .toPack, for: first, expectedRevision: shop.revisionID)
        XCTAssertTrue(shop.departureReminderLines.isEmpty)
    }

    func testLegacyListAndRecordedPickPriceRemainIndependentOfJug() throws {
        var shop = ShoppingLedger()
        let water = try shop.addManualLine(name: "Water", quantity: nil)
        let oldPayload = try JSONEncoder().encode(LedgerWorkspace(shops: [shop], selectedShopID: shop.id))
        XCTAssertFalse(String(decoding: oldPayload, as: UTF8.self).contains("emptyJug"))
        XCTAssertFalse(String(decoding: oldPayload, as: UTF8.self).contains("mainTripReasonID"))
        let oldWorkspace = try JSONDecoder().decode(LedgerWorkspace.self, from: oldPayload)
        XCTAssertEqual(oldWorkspace.ledgerDocumentVersion, 1)
        shop = try XCTUnwrap(oldWorkspace.shops.first)
        try shop.setEmptyJug(.toPack, replacing: nil, for: water, expectedRevision: shop.revisionID)
        try shop.setChecked(lineID: water, checked: true)
        let price = Money(minorUnits: 450, currency: shop.basis.currency)
        try shop.recordPickedPrice(lineID: water, expectedRevision: shop.revisionID, total: price,
                                   membership: false, weighted: false, conditionsConfirmed: true)
        let quote = LedgerQuoteReference(id: UUID(), basisRevision: shop.basisRevision, ledgerRevision: shop.revision,
                                         createdAt: Date(), source: "Reviewed checkout")
        try shop.attachQuote(quote)
        try shop.setEmptyJug(.packed, replacing: .toPack, for: water, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.priceForCurrentPick(lineID: water)?.total, price)
        try shop.setEmptyJug(nil, replacing: .packed, for: water, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.quoteReference, quote)
        XCTAssertEqual(shop.pickedCartSubtotal.total, price)
        XCTAssertTrue(try XCTUnwrap(shop.lines.first).isChecked)
    }

    func testOneMainReasonSurvivesRestartAndCanBeLeftUnpurchased() throws {
        var shop = ShoppingLedger()
        let milk = try shop.addManualLine(name: "Milk", quantity: nil)
        let bread = try shop.addManualLine(name: "Bread", quantity: nil)
        try shop.setMainTripReason(milk, replacing: nil, expectedRevision: shop.revisionID)
        let previous = shop.revisionID
        try shop.setMainTripReason(bread, replacing: milk, expectedRevision: previous)
        var workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        XCTAssertEqual(workspace.ledgerDocumentVersion, 2)
        workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        shop = try XCTUnwrap(workspace.shops.first)
        XCTAssertEqual(shop.outstandingMainTripReason?.id, bread)
        XCTAssertThrowsError(try shop.setMainTripReason(nil, replacing: milk, expectedRevision: previous))
        try shop.setChecked(lineID: bread, checked: true)
        XCTAssertNil(shop.outstandingMainTripReason)
        try shop.setChecked(lineID: bread, checked: false)
        XCTAssertEqual(shop.outstandingMainTripReason?.id, bread)
        try shop.markUnavailable(lineID: bread, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.outstandingMainTripReason?.id, bread)
        try shop.setMainTripReason(nil, replacing: bread, expectedRevision: shop.revisionID)
        XCTAssertNil(shop.outstandingMainTripReason)
        XCTAssertFalse(try XCTUnwrap(shop.lines.first(where: { $0.id == bread })).isChecked)
        XCTAssertEqual(shop.lines.filter { !$0.isTrashed }.count, 2)
    }
}
