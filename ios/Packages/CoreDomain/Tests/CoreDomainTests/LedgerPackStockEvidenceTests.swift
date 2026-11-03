import XCTest
@testable import CoreDomain

final class LedgerPackStockEvidenceTests: XCTestCase {
    func testTwelveNeedEightAllocatedEightPerPackBuysOneAndKeepsGrossDemand() throws {
        let (shop, line, evidence) = try fixture(stock: 8)
        let selection = try choose(shop: shop, line: line, evidence: evidence)
        XCTAssertEqual(selection.formatVersion, 2)
        XCTAssertEqual(selection.outcome, .purchase)
        XCTAssertEqual(selection.request.needed?.amount, try Rational(12))
        XCTAssertEqual(selection.request.confirmedAtHome?.amount, try Rational(8))
        XCTAssertEqual(selection.selectedResult.packsToBuy, 1)
        XCTAssertEqual(selection.purchasedQuantity?.amount, try Rational(8))
        XCTAssertEqual(selection.selectedResult.totalCost, Money(minorUnits: 300))
        XCTAssertEqual(try shop.quantity(forLineID: line)?.amount, try Rational(12))
    }

    func testFullyCoveredHasExplicitNoPurchaseWithNoPackPriceEvidence() throws {
        let (shop, line, evidence) = try fixture(stock: 12)
        let selection = try choose(shop: shop, line: line, evidence: evidence, unknownPack: true)
        XCTAssertTrue(selection.isNoPurchase)
        XCTAssertEqual(selection.selectedResult.packsToBuy, 0)
        XCTAssertNil(selection.purchasedQuantity)
        XCTAssertNil(selection.request.offerA.price)
        XCTAssertEqual(selection.request.needed?.amount, try Rational(12))
        let restored = try JSONDecoder().decode(LedgerPackSelection.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(restored, selection)
        XCTAssertNoThrow(try restored.validate())
    }

    func testProtectedFoodAndFixedReservationsElsewhereCannotBeCreditedTwice() throws {
        for priority in [AllocationPriority.protected, .required] {
            let (shop, line, original) = try fixture(stock: 8)
            let other = StockNeed(id: UUID(), foodID: line, name: "Already reserved", amount: q(8), priority: priority)
            let evidence = LedgerPackStockEvidence(sourceWorkspaceID: original.sourceWorkspaceID, journeyID: shop.id,
                journeyRevision: 4, basketRevisionID: original.basketRevisionID, shopRevisionID: shop.revisionID,
                lineID: line, listNeedIDs: original.listNeedIDs, lots: original.lots, needs: original.needs + [other],
                reservations: priority == .required ? [ConfirmedStockReservation(needID: other.id, lotID: original.lots[0].id)] : [])
            let selection = try choose(shop: shop, line: line, evidence: evidence)
            XCTAssertEqual(selection.request.confirmedAtHome?.amount, .zero)
            XCTAssertEqual(selection.selectedResult.packsToBuy, 2)
        }
    }

    func testEvidenceMustMatchLiveSourceAndRecoveredWorkspaceCannotAdoptIt() throws {
        let (shop, line, evidence) = try fixture(stock: 8)
        let workspaceID = UUID(), selection = try choose(shop: shop, line: line, evidence: evidence, workspaceID: workspaceID)
        XCTAssertFalse(try selection.isCurrent(in: shop, workspaceID: workspaceID), "A ledger-only read cannot grant stock authority")
        XCTAssertTrue(try selection.isCurrent(in: shop, workspaceID: workspaceID, currentStockEvidence: evidence))
        for changed in [copy(evidence, revision: 5), copy(evidence, journeyID: UUID()), copy(evidence, stock: 7)] {
            XCTAssertFalse(try selection.isCurrent(in: shop, workspaceID: workspaceID, currentStockEvidence: changed))
        }
        XCTAssertFalse(try selection.isCurrent(in: shop, workspaceID: UUID(), currentStockEvidence: evidence))
        var changedShop = shop
        try changedShop.updateLine(lineID: line, name: "Wraps", notes: "Recheck", aisle: "")
        XCTAssertFalse(try selection.isCurrent(in: changedShop, workspaceID: workspaceID, currentStockEvidence: evidence))
        var workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        XCTAssertThrowsError(try workspace.recordPackSelection(selection, workspaceID: workspaceID))
        XCTAssertTrue(try workspace.recordPackSelection(selection, workspaceID: workspaceID, currentStockEvidence: evidence))
    }

    func testFreeStandingStockTotalAndTamperedPartitionCannotAuthorizeSelection() throws {
        let (shop, line, evidence) = try fixture(stock: 8)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: line)
        let request = ComparisonRequest(itemName: "Wraps", needed: requirement.quantity, confirmedAtHome: q(8),
            protectedAmount: requirement.protectedQuantity, offerA: offer, offerB: otherOffer)
        XCTAssertThrowsError(try LedgerPackSelection(workspaceID: UUID(), shop: shop, lineID: line,
            request: request, selectedOfferID: "a", at: Date(), source: "Shelf"))
        let incomplete = LedgerPackStockEvidence(sourceWorkspaceID: evidence.sourceWorkspaceID, journeyID: shop.id,
            journeyRevision: 4, basketRevisionID: evidence.basketRevisionID, shopRevisionID: shop.revisionID,
            lineID: line, listNeedIDs: [UUID()], lots: evidence.lots, needs: evidence.needs, reservations: [])
        XCTAssertThrowsError(try incomplete.confirmedQuantity(for: requirement))
        let overlarge = LedgerPackStockEvidence(sourceWorkspaceID: evidence.sourceWorkspaceID, journeyID: shop.id,
            journeyRevision: 4, basketRevisionID: evidence.basketRevisionID, shopRevisionID: shop.revisionID,
            lineID: line, listNeedIDs: evidence.listNeedIDs, lots: evidence.lots,
            needs: Array(repeating: evidence.needs[0], count: 10_001), reservations: [])
        XCTAssertThrowsError(try overlarge.confirmedQuantity(for: requirement))
    }

    func testVersionOneArchiveAndNoStockBehaviorRemainUnchanged() throws {
        let (shop, line, _) = try fixture(stock: 8)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: line)
        let request = ComparisonRequest(itemName: "Wraps", needed: requirement.quantity,
            protectedAmount: requirement.protectedQuantity, offerA: offer, offerB: otherOffer)
        let selection = try LedgerPackSelection(workspaceID: UUID(), shop: shop, lineID: line,
            request: request, selectedOfferID: "a", at: Date(), source: "Shelf")
        XCTAssertEqual(selection.formatVersion, 1)
        XCTAssertEqual(selection.selectedResult.packsToBuy, 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any])
        object.removeValue(forKey: "stockEvidence"); object.removeValue(forKey: "outcome")
        let restored = try JSONDecoder().decode(LedgerPackSelection.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, selection)
        XCTAssertNoThrow(try restored.validate())
    }

    private func fixture(stock: Int64) throws -> (ShoppingLedger, UUID, LedgerPackStockEvidence) {
        var shop = ShoppingLedger()
        let line = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let need = StockNeed(id: line, foodID: line, name: "Wraps", amount: q(12), priority: .required)
        let lot = ConfirmedStockLot(id: UUID(), foodID: line, name: "Freezer wraps", usable: q(stock), confirmedAt: Date(), source: .freezer)
        return (shop, line, LedgerPackStockEvidence(sourceWorkspaceID: UUID(), journeyID: shop.id, journeyRevision: 4,
            basketRevisionID: UUID(), shopRevisionID: shop.revisionID, lineID: line, listNeedIDs: [need.id],
            lots: [lot], needs: [need], reservations: []))
    }
    private func choose(shop: ShoppingLedger, line: UUID, evidence: LedgerPackStockEvidence,
                        unknownPack: Bool = false, workspaceID: UUID = UUID()) throws -> LedgerPackSelection {
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: line)
        let request = ComparisonRequest(itemName: "Wraps", needed: requirement.quantity,
            confirmedAtHome: try evidence.confirmedQuantity(for: requirement), protectedAmount: requirement.protectedQuantity,
            offerA: unknownPack ? PackOffer(id: "a", label: "No purchase", usableQuantity: nil, price: nil) : offer, offerB: otherOffer)
        return try LedgerPackSelection(workspaceID: workspaceID, shop: shop, lineID: line, request: request,
            selectedOfferID: "a", at: Date(), source: "Reviewed shelf and allocation", stockEvidence: evidence)
    }
    private var offer: PackOffer { PackOffer(id: "a", label: "Eight pack", usableQuantity: q(8), price: Money(minorUnits: 300)) }
    private var otherOffer: PackOffer { PackOffer(id: "b", label: "Six pack", usableQuantity: q(6), price: Money(minorUnits: 250)) }
    private func q(_ n: Int64) -> Quantity { Quantity(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private func copy(_ e: LedgerPackStockEvidence, revision: Int64? = nil, journeyID: UUID? = nil, stock: Int64? = nil) -> LedgerPackStockEvidence {
        LedgerPackStockEvidence(sourceWorkspaceID: e.sourceWorkspaceID, journeyID: journeyID ?? e.journeyID,
            journeyRevision: revision ?? e.journeyRevision, basketRevisionID: e.basketRevisionID,
            shopRevisionID: e.shopRevisionID, lineID: e.lineID, listNeedIDs: e.listNeedIDs,
            lots: stock.map { [ConfirmedStockLot(id: e.lots[0].id, foodID: e.lineID, name: e.lots[0].name,
                usable: q($0), confirmedAt: e.lots[0].confirmedAt, source: .freezer)] } ?? e.lots,
            needs: e.needs, reservations: e.reservations)
    }
}
