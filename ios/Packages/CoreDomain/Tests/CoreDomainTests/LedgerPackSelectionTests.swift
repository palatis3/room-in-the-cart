import XCTest
@testable import CoreDomain

final class LedgerPackSelectionTests: XCTestCase {
    func testWholePacksRetainProtectedPartitionAndItemOnlyCost() throws {
        let (shop, line) = try fixture()
        let required = try LedgerPackRequirement.review(shop: shop, lineID: line)
        XCTAssertEqual(required.quantity.amount, try Rational(10))
        XCTAssertEqual(required.protectedQuantity.amount, try Rational(2))
        let selection = try choose(shop: shop, line: line)
        XCTAssertEqual(selection.selectedResult.packsToBuy, 2)
        XCTAssertEqual(selection.purchasedQuantity?.amount, try Rational(12))
        XCTAssertEqual(selection.selectedResult.leftover, try Rational(2))
        XCTAssertEqual(selection.selectedResult.totalCost, Money(minorUnits: 400))
        XCTAssertEqual(try PackComparison.evaluate(selection.request).scope, .itemOnly)
        XCTAssertEqual(try shop.quantity(forLineID: line)?.amount, try Rational(10))
    }
    func testServingGroupProtectionUsesItsPartitionInsideMealAmount() throws {
        var shop = ShoppingLedger()
        try shop.chooseMeal(MealTemplate(title: "Soup", servings: try Rational(6),
            ingredients: [MealIngredient(name: "Soup", quantity: q(12))],
            servingGroups: [ServingGroup(name: "Lunch", servings: try Rational(2), isProtected: true)]))
        let required = try LedgerPackRequirement.review(shop: shop, lineID: XCTUnwrap(shop.lines.first?.id))
        XCTAssertEqual(required.quantity.amount, try Rational(12))
        XCTAssertEqual(required.protectedQuantity.amount, try Rational(4))
    }
    func testReviewRetryIsIdempotentButDifferentBodyReusingOperationConflicts() throws {
        let (shop, line) = try fixture(); let workspaceID = UUID()
        let selection = try choose(shop: shop, line: line, workspaceID: workspaceID)
        var workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        XCTAssertTrue(try workspace.recordPackSelection(selection, workspaceID: workspaceID))
        let before = workspace
        XCTAssertFalse(try workspace.recordPackSelection(selection, workspaceID: workspaceID))
        XCTAssertEqual(workspace, before)
        let conflict = try choose(shop: shop, line: line, workspaceID: workspaceID, id: selection.id, price: 300)
        XCTAssertThrowsError(try workspace.recordPackSelection(conflict, workspaceID: workspaceID)) { XCTAssertEqual($0 as? LedgerPackError, .operationConflict) }
        XCTAssertEqual(workspace, before)
        XCTAssertEqual(workspace.shops.first?.revisionID, shop.revisionID, "Saving evidence does not change its reviewed shopping source")
    }
    func testChangedSourceKeepsHistoricalEvidenceButCannotDriveCheckout() throws {
        let (shop, line) = try fixture(); let workspaceID = UUID()
        let selection = try choose(shop: shop, line: line, workspaceID: workspaceID)
        var workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id, packSelections: [selection])
        XCTAssertEqual(try workspace.currentPackSelection(shopID: shop.id, lineID: line, workspaceID: workspaceID), selection)
        try workspace.shops[0].updateLine(lineID: line, name: "Reviewed wraps", notes: "New exclusions", aisle: "")
        try workspace.validate()
        XCTAssertNil(try workspace.currentPackSelection(shopID: shop.id, lineID: line, workspaceID: workspaceID))
        XCTAssertEqual(workspace.packSelections, [selection])
        XCTAssertThrowsError(try workspace.recordPackSelection(choose(shop: shop, line: line, workspaceID: workspaceID), workspaceID: workspaceID))
        let decoded = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded.packSelections, [selection])
        XCTAssertNil(try decoded.currentPackSelection(shopID: shop.id, lineID: line, workspaceID: workspaceID))
    }
    func testRecoveredWorkspaceCannotTreatOriginalWorkspaceEvidenceAsCurrent() throws {
        let (shop, line) = try fixture(); let workspaceID = UUID()
        let selection = try choose(shop: shop, line: line, workspaceID: workspaceID)
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id, packSelections: [selection])
        XCTAssertNil(try workspace.currentPackSelection(shopID: shop.id, lineID: line, workspaceID: UUID()))
        XCTAssertEqual(workspace.packSelections, [selection])
    }
    func testDecodedTamperedTotalUnknownEngineAndInvalidSourceReferencesFailClosed() throws {
        let (shop, line) = try fixture(); let selection = try choose(shop: shop, line: line)
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id, packSelections: [selection])
        let encoded = try JSONEncoder().encode(workspace)
        for mutation in ["engine", "total", "revision", "basis", "line"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var selections = try XCTUnwrap(object["packSelections"] as? [[String: Any]])
            switch mutation {
            case "engine": selections[0]["engineVersion"] = "future-engine-v99"
            case "total":
                var result = try XCTUnwrap(selections[0]["selectedResult"] as? [String: Any])
                var money = try XCTUnwrap(result["totalCost"] as? [String: Any]); money["minorUnits"] = 1
                result["totalCost"] = money; selections[0]["selectedResult"] = result
            case "revision": selections[0]["shopRevisionID"] = UUID().uuidString
            case "basis": selections[0]["basisRevision"] = 999
            default: selections[0]["lineID"] = UUID().uuidString
            }
            object["packSelections"] = selections
            XCTAssertThrowsError(try JSONDecoder().decode(LedgerWorkspace.self, from: JSONSerialization.data(withJSONObject: object)), mutation)
        }
    }
    func testEarlierWorkspaceDefaultsEmptyAndUnknownYieldCannotBeSelected() throws {
        let (shop, line) = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LedgerWorkspace(shops: [shop]))) as? [String: Any])
        object.removeValue(forKey: "packSelections")
        XCTAssertTrue(try JSONDecoder().decode(LedgerWorkspace.self, from: JSONSerialization.data(withJSONObject: object)).packSelections.isEmpty)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: line)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity, protectedAmount: requirement.protectedQuantity,
            offerA: PackOffer(id: "a", label: "Unknown", usableQuantity: nil, price: Money(minorUnits: 200)),
            offerB: PackOffer(id: "b", label: "Six", usableQuantity: q(6), price: Money(minorUnits: 200)))
        XCTAssertThrowsError(try LedgerPackSelection(workspaceID: UUID(), shop: shop, lineID: line, request: request, selectedOfferID: "a", at: Date(), source: "Reviewed label"))
    }
    private func fixture() throws -> (ShoppingLedger, UUID) {
        var shop = ShoppingLedger()
        let line = try shop.addManualLine(name: "Wraps", quantity: q(10))
        let source = try XCTUnwrap(shop.contributions(forLineID: line).first?.id)
        try shop.addProtectedNeed(name: "Wraps", quantity: q(2), purpose: "Lunch", within: source)
        return (shop, line)
    }
    private func choose(shop: ShoppingLedger, line: UUID, workspaceID: UUID = UUID(), id: UUID = UUID(), price: Int64 = 200) throws -> LedgerPackSelection {
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: line)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity, protectedAmount: requirement.protectedQuantity,
            offerA: PackOffer(id: "a", label: "Eight", usableQuantity: q(8), price: Money(minorUnits: 300)),
            offerB: PackOffer(id: "b", label: "Six", usableQuantity: q(6), price: Money(minorUnits: price)))
        return try LedgerPackSelection(id: id, workspaceID: workspaceID, shop: shop, lineID: line, request: request, selectedOfferID: "b", at: Date(timeIntervalSince1970: 1_800_000_000), source: "Reviewed pack labels")
    }
    private func q(_ amount: Int64) -> Quantity { Quantity(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }
}
