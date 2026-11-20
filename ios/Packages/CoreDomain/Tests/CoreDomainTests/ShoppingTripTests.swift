import XCTest
@testable import CoreDomain

final class ShoppingTripTests: XCTestCase {
    func testTwoStoresShareOneDinnerNeedAndUndoSurvivesRestart() throws {
        var basis = ShopBasis(); basis.branch = "A"
        var shop = ShoppingLedger(basis: basis)
        let need = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2 tortilla packs")
        let mealID = try shop.chooseMeal(.init(title: "Tacos", ingredients: [.init(name: "Tortilla packs", quantity: need)]))
        let line = try XCTUnwrap(shop.lines.first?.id)
        try shop.setPreferredStores(["A", "B"], lineID: line, expectedRevision: shop.revisionID)
        let reviewed = shop.revisionID
        try shop.pickPart(lineID: line, amount: .one, expectedRevision: reviewed)
        XCTAssertThrowsError(try shop.pickPart(lineID: line, amount: .one, expectedRevision: reviewed))
        XCTAssertEqual(shop.inStorePickedLines.count, 1)
        XCTAssertEqual(shop.pickedCartSubtotal.priced, 0)
        try shop.recordPickedPrice(lineID: line, expectedRevision: shop.revisionID, total: Money(minorUnits: 225),
                                   membership: false, weighted: false, conditionsConfirmed: false)
        try shop.markUnavailable(lineID: line, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.outcomeAtCurrentStop(shop.lines[0]), .unavailable)
        XCTAssertEqual(shop.pickedCartSubtotal.total.minorUnits, 225)
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: line)?.amount, .one)
        let added = try shop.addInStoreFind(name: "Lime", quantity: nil, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.pickedCartSubtotal.picked, 2)
        XCTAssertTrue(shop.lines[0].eligibleForStop(named: "B"))
        try shop.startShoppingStop(named: "B", expectedRevision: shop.revisionID)
        shop = try reopen(shop)
        XCTAssertNil(shop.outcomeAtCurrentStop(shop.lines[0]))
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: line)?.amount, .one)
        try shop.setChecked(lineID: line, checked: true)
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: line)?.amount, .zero)
        XCTAssertNil(shop.priceForCurrentPick(lineID: line))
        shop = try reopen(shop)
        try shop.undoTripChange(lineID: line, expectedRevision: shop.revisionID)
        XCTAssertEqual(try shop.pickedQuantity(forLineID: line)?.amount, .one)
        XCTAssertEqual(shop.pickedCartSubtotal.total.minorUnits, 225)
        XCTAssertEqual(shop.contributions(forLineID: line).first?.source, .meal(occurrenceID: mealID))
        XCTAssertEqual(try shop.quantity(forLineID: line)?.amount, need.amount)
        try shop.undoTripChange(lineID: added, expectedRevision: shop.revisionID)
        XCTAssertTrue(try XCTUnwrap(shop.lines.first { $0.id == added }).isTrashed)
        XCTAssertEqual(try reopen(shop).pickedCartSubtotal.picked, 1)
    }

    func testLegacyCheckAndUnresolvedQuantityCanBeReopenedWithoutInventingStock() throws {
        var shop = ShoppingLedger()
        let id = try shop.addManualLine(name: "Cilantro", quantity: nil)
        try shop.setChecked(lineID: id, checked: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shop)) as? [String: Any])
        var lines = try XCTUnwrap(json["lines"] as? [[String: Any]])
        for key in ["tripPick", "tripUndo", "stopObservation", "preferredStores"] { lines[0].removeValue(forKey: key) }
        json["lines"] = lines
        shop = try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: json))
        try shop.validate()
        XCTAssertEqual(shop.inStorePickedLines.map(\.id), [id])
        XCTAssertNil(try shop.pickedQuantity(forLineID: id))
        try shop.setChecked(lineID: id, checked: false)
        XCTAssertThrowsError(try shop.pickPart(lineID: id, amount: .one, expectedRevision: shop.revisionID))
        try shop.markUnavailable(lineID: id, expectedRevision: shop.revisionID)
        XCTAssertNil(try shop.outstandingQuantity(forLineID: id))
        try shop.undoTripChange(lineID: id, expectedRevision: shop.revisionID)
        XCTAssertNil(shop.outcomeAtCurrentStop(shop.lines[0]))
        XCTAssertEqual(shop.pickedCartSubtotal.picked, 0)
    }

    func testPhysicalPickAndStandingTransferSurviveNeedEdits() throws {
        var basis = ShopBasis(); basis.branch = "First"
        let source = ShoppingLedger(basis: basis)
        let need = Quantity(amount: try Rational(2), unit: .kilogram, originalLiteral: "2 kg")
        var workspace = LedgerWorkspace(shops: [source], selectedShopID: source.id)
        let item = StandingListItem(row: .init(name: "Flour", quantity: need), stores: ["First", "Second"])
        try workspace.shoppingLists.saveStanding(item, replacing: nil)
        try workspace.transferStanding(item, shopID: source.id, revision: source.revisionID)
        let transferred = try XCTUnwrap(workspace.shoppingLists.standing.first)
        let line = try XCTUnwrap(transferred.transfer?.lineID)
        try workspace.shops[0].pickPart(lineID: line, amount: .one, expectedRevision: workspace.shops[0].revisionID)
        XCTAssertFalse(workspace.canReturnStanding(transferred, from: workspace.shops[0]))
        var shop = workspace.shops[0]
        XCTAssertEqual(shop.lines[0].preferredStores, ["First", "Second"])
        let contribution = try XCTUnwrap(shop.contributions.first)
        try shop.updateContribution(contributionID: contribution.id,
            quantity: .init(amount: try Rational(2500), unit: .gram, originalLiteral: "2500 g"), notes: "")
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: line)?.amount, try Rational(1500))
        XCTAssertNil(shop.lines[0].tripUndo)
        XCTAssertThrowsError(try shop.pickPart(lineID: line, amount: Rational(1501), expectedRevision: shop.revisionID))
        try shop.pickPart(lineID: line, amount: Rational(1500), expectedRevision: shop.revisionID)
        XCTAssertTrue(try reopen(shop).lines[0].isChecked)
    }

    func testUndoingAvailabilityPreservesANewerPriceForTheSamePhysicalAmount() throws {
        var shop = ShoppingLedger()
        let id = try shop.addManualLine(name: "Apples", quantity: Quantity(amount: Rational(4), unit: .count, originalLiteral: "4"))
        try shop.pickPart(lineID: id, amount: .one, expectedRevision: shop.revisionID)
        try shop.markUnavailable(lineID: id, expectedRevision: shop.revisionID)
        try shop.recordPickedPrice(lineID: id, expectedRevision: shop.revisionID, total: Money(minorUnits: 60),
                                   membership: false, weighted: false, conditionsConfirmed: false)
        try shop.undoTripChange(lineID: id, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.pickedCartSubtotal.total.minorUnits, 60)
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: id)?.amount, try Rational(3))
    }

    private func reopen(_ shop: ShoppingLedger) throws -> ShoppingLedger {
        let value = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        try value.validate()
        return value
    }
}
