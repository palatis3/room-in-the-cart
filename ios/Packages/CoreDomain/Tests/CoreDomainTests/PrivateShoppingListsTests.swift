import XCTest
@testable import CoreDomain

final class PrivateShoppingListsTests: XCTestCase {
    private let unit = Quantity(amount: .one, unit: .count, originalLiteral: "1")
    private func shop(_ branch: String) -> ShoppingLedger {
        var basis = ShopBasis()
        basis.branch = branch
        return ShoppingLedger(title: "Trip \(branch)", basis: basis)
    }

    func testPickedSubtotalCoverageConditionsUndoAndStaleEntries() throws {
        var shop = shop("Main")
        let a = try shop.addManualLine(name: "Coffee", quantity: unit)
        let b = try shop.addManualLine(name: "Apples", quantity: nil)
        let c = try shop.addManualLine(name: "Milk", quantity: unit)
        let d = try shop.addManualLine(name: "Sample", quantity: unit)
        for id in [a,b,c,d] { try shop.setChecked(lineID: id, checked: true) }
        try shop.recordPickedPrice(lineID: a, expectedRevision: shop.revisionID, total: Money(minorUnits: 753),
                                   membership: false, weighted: false, conditionsConfirmed: false)
        try shop.recordPickedPrice(lineID: b, expectedRevision: shop.revisionID, total: Money(minorUnits: 301),
                                   membership: true, weighted: true, conditionsConfirmed: false)
        try shop.recordPickedPrice(lineID: d, expectedRevision: shop.revisionID, total: .zero,
                                   membership: false, weighted: false, conditionsConfirmed: false)
        XCTAssertEqual(shop.pickedCartSubtotal, PickedCartSubtotal(total: Money(minorUnits: 753), priced: 2, picked: 4))
        try shop.recordPickedPrice(lineID: b, expectedRevision: shop.revisionID, total: Money(minorUnits: 301),
                                   membership: true, weighted: true, conditionsConfirmed: true)
        XCTAssertEqual(shop.pickedCartSubtotal.total.minorUnits, 1054)
        try shop.setChecked(lineID: a, checked: false)
        XCTAssertEqual(shop.pickedCartSubtotal, PickedCartSubtotal(total: Money(minorUnits: 301), priced: 2, picked: 3))
        try shop.setChecked(lineID: a, checked: true)
        XCTAssertEqual(shop.pickedCartSubtotal.priced, 2)
        let source = try XCTUnwrap(shop.contributions(forLineID: b).first)
        try shop.updateContribution(contributionID: source.id, quantity: unit, notes: "")
        XCTAssertEqual(shop.pickedCartSubtotal.priced, 1)
        try shop.handle(lineID: d, by: "A")
        XCTAssertEqual(shop.pickedCartSubtotal, PickedCartSubtotal(total: .zero, priced: 0, picked: 3))
        var changed = shop.basis
        changed.branch = "Other"
        try shop.updateBasis(changed)
        XCTAssertEqual(try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop)), shop)
    }

    func testVariantEditsPermanentlyClearOnlyTheAffectedEnteredPrice() throws {
        var shop = shop("West")
        let milk = try shop.addManualLine(name: "Milk", quantity: unit, notes: "Regular")
        let bread = try shop.addManualLine(name: "Bread", quantity: unit)
        for id in [milk, bread] {
            try shop.setChecked(lineID: id, checked: true)
            try shop.recordPickedPrice(lineID: id, expectedRevision: shop.revisionID, total: Money(minorUnits: 200),
                                       membership: false, weighted: false, conditionsConfirmed: false)
        }
        try shop.updateLine(lineID: milk, name: "Milk", notes: "Lactose-free", aisle: "")
        try shop.updateLine(lineID: milk, name: "Milk", notes: "Regular", aisle: "")
        XCTAssertNil(shop.priceForCurrentPick(lineID: milk))
        XCTAssertEqual(shop.pickedCartSubtotal, PickedCartSubtotal(total: Money(minorUnits: 200), priced: 1, picked: 2))
        try shop.recordPickedPrice(lineID: milk, expectedRevision: shop.revisionID, total: Money(minorUnits: 250),
                                   membership: false, weighted: false, conditionsConfirmed: false)
        let source = try XCTUnwrap(shop.contributions(forLineID: milk).first)
        try shop.updateContribution(contributionID: source.id, quantity: unit, notes: "Different brand")
        try shop.updateContribution(contributionID: source.id, quantity: unit, notes: "Regular")
        XCTAssertNil(shop.priceForCurrentPick(lineID: milk))
        XCTAssertEqual(shop.priceForCurrentPick(lineID: bread)?.includedTotal?.minorUnits, 200)
        let encoded = try JSONEncoder().encode(LedgerWorkspace(shops: [shop]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["shoppingLists"])
    }

    func testKitCarriesReviewedIntentOnlyAndAppliesOnce() throws {
        var first = shop("Main")
        let milk = try first.addManualLine(name: "Acme Milk", quantity: unit, notes: "Blue carton", exclusions: ["almond"])
        let fruit = try first.addManualLine(name: "Fruit", quantity: nil)
        try first.setChecked(lineID: milk, checked: true)
        try first.recordPickedPrice(lineID: milk, expectedRevision: first.revisionID, total: Money(minorUnits: 500),
                                    membership: false, weighted: false, conditionsConfirmed: false)
        let rows = try first.shoppingKitRows()
        var kit = ShoppingKit(name: "School", rows: rows)
        kit.rows[1].optional = true
        var next = shop("Main")
        _ = try next.addManualLine(name: "Fruit", quantity: nil)
        var workspace = LedgerWorkspace(shops: [first,next], selectedShopID: next.id)
        try workspace.shoppingLists.saveKit(kit, replacing: nil)
        XCTAssertEqual(kit.rows[1].overlaps(in: next).count, 1)
        try workspace.applyKit(kit, selected: [milk], shopID: next.id, revision: next.revisionID)
        XCTAssertThrowsError(try workspace.applyKit(kit, selected: [milk], shopID: next.id, revision: next.revisionID))
        let line = try XCTUnwrap(workspace.shops[1].lines.last)
        XCTAssertNotEqual(line.id, milk)
        XCTAssertEqual(line.name, "Acme Milk")
        XCTAssertEqual(line.notes, "Blue carton")
        XCTAssertEqual(workspace.shops[1].itemExclusions[line.id], ["almond"])
        XCTAssertNil(line.pickedPrice)
        XCTAssertFalse(line.isChecked)
        XCTAssertEqual(workspace.shops[1].lines.count, 2)
        XCTAssertEqual(kit.rows[1].id, fruit)
        XCTAssertEqual(try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace)), workspace)
    }

    func testSelectFromAnotherTripIsOneRevisionWithOnlyNamesAndExclusions() throws {
        var prior = shop("West")
        let rice = try prior.addManualLine(name: "Rice", quantity: unit, notes: "Paid $4", exclusions: ["mix"])
        let other = try prior.addManualLine(name: "Bread", quantity: nil)
        try prior.setChecked(lineID: rice, checked: true)
        try prior.recordPickedPrice(lineID: rice, expectedRevision: prior.revisionID, total: Money(minorUnits: 400),
                                   membership: false, weighted: false, conditionsConfirmed: false)
        var current = shop("East")
        _ = try current.addManualLine(name: "Rice", quantity: nil)
        var state = LedgerWorkspace(shops: [prior, current], selectedShopID: current.id)
        XCTAssertEqual(prior.previousGroceryRows.first?.overlaps(in: current).count, 1)
        func apply(_ ids: Set<UUID>, from source: ShoppingLedger, to state: inout LedgerWorkspace) throws {
            try state.addPreviousGroceries(from: source.id, sourceRevision: source.revisionID,
                                          selected: ids, to: current.id, destinationRevision: current.revisionID)
        }
        XCTAssertThrowsError(try apply([rice, UUID()], from: prior, to: &state))
        XCTAssertThrowsError(try apply([rice], from: current, to: &state))
        var changed = prior
        try changed.updateLine(lineID: other, name: "Rolls", notes: "", aisle: "")
        XCTAssertThrowsError(try apply([rice], from: changed, to: &state))
        XCTAssertEqual(state.shops[1], current)
        try apply([rice], from: prior, to: &state)
        XCTAssertThrowsError(try apply([rice], from: prior, to: &state))
        let result = try XCTUnwrap(state.shops[1].lines.last)
        XCTAssertEqual(state.shops[0], prior)
        XCTAssertEqual(state.shops[1].lines.count, 2)
        XCTAssertEqual(state.shops[1].revision, current.revision + 1)
        XCTAssertNotEqual(result.id, rice)
        XCTAssertEqual(result.name, "Rice")
        XCTAssertEqual(result.notes, "")
        XCTAssertNil(result.pickedPrice)
        XCTAssertFalse(result.isChecked)
        XCTAssertNil(try state.shops[1].quantity(forLineID: result.id))
        XCTAssertEqual(state.shops[1].itemExclusions[result.id], ["mix"])
        XCTAssertEqual(try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(state)), state)
    }

    func testStandingTransferOfflineReplayCorrectionAndShopBinding() throws {
        let a = shop("West"), b = shop("East"), c = shop("North")
        var workspace = LedgerWorkspace(shops: [a,b,c], selectedShopID: c.id)
        let item = StandingListItem(row: .init(name: "Milk", quantity: unit), stores: ["West","East"])
        try workspace.shoppingLists.saveStanding(item, replacing: nil)
        XCTAssertThrowsError(try workspace.transferStanding(item, shopID: c.id, revision: c.revisionID))
        XCTAssertThrowsError(try workspace.transferStanding(item, shopID: a.id, revision: a.revisionID))
        workspace.selectedShopID = a.id
        try workspace.transferStanding(item, shopID: a.id, revision: a.revisionID)
        workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        workspace.selectedShopID = b.id
        XCTAssertThrowsError(try workspace.transferStanding(item, shopID: b.id, revision: b.revisionID))
        XCTAssertEqual(workspace.shops[1].lines.count, 0)
        workspace.selectedShopID = a.id
        let moved = try XCTUnwrap(workspace.shoppingLists.standing.first)
        let line = try XCTUnwrap(moved.transfer?.lineID)
        try workspace.shops[0].setChecked(lineID: line, checked: true)
        XCTAssertThrowsError(try workspace.returnStanding(moved, shopID: a.id, revision: workspace.shops[0].revisionID))
        try workspace.shops[0].setChecked(lineID: line, checked: false)
        try workspace.returnStanding(moved, shopID: a.id, revision: workspace.shops[0].revisionID)
        XCTAssertTrue(workspace.shops[0].lines[0].isTrashed)
        XCTAssertEqual(workspace.shoppingLists.standing, [item])
        workspace.selectedShopID = b.id
        try workspace.transferStanding(item, shopID: b.id, revision: b.revisionID)
        XCTAssertEqual(workspace.shops[1].lines.count, 1)
        try workspace.validate()
    }

    func testStandingPickAndUndoKeepOneIntentAcrossBothStoresWithoutAPickupChange() throws {
        let store = shop("West")
        var workspace = LedgerWorkspace(shops: [store], selectedShopID: store.id)
        let item = StandingListItem(row: .init(name: "Tea"), stores: ["West","East"])
        try workspace.shoppingLists.saveStanding(item, replacing: nil)
        try workspace.shoppingLists.setStandingChecked(item, checked: true)
        workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        let picked = try XCTUnwrap(workspace.shoppingLists.standing.first)
        XCTAssertNotNil(picked.checkedAt)
        XCTAssertTrue(picked.eligible(at: "East"))
        XCTAssertThrowsError(try workspace.transferStanding(picked, shopID: store.id, revision: store.revisionID))
        XCTAssertEqual(workspace.shops, [store])
        try workspace.shoppingLists.setStandingChecked(picked, checked: false)
        XCTAssertEqual(workspace.shoppingLists.standing, [item])
    }

    func testStandingTransferRejectsOverlapsAndReturnPreservesLinkedNeeds() throws {
        var a = shop("Main")
        _ = try a.addManualLine(name: "Tea", quantity: nil)
        var workspace = LedgerWorkspace(shops: [a], selectedShopID: a.id)
        let tea = StandingListItem(row: .init(name: "TEA"), stores: ["Main"])
        try workspace.shoppingLists.saveStanding(tea, replacing: nil)
        XCTAssertThrowsError(try workspace.transferStanding(tea, shopID: a.id, revision: a.revisionID))
        XCTAssertNil(workspace.shoppingLists.standing.first?.transfer)
        let milk = StandingListItem(row: .init(name: "Milk", quantity: unit), stores: ["Main"])
        try workspace.shoppingLists.saveStanding(milk, replacing: nil)
        try workspace.transferStanding(milk, shopID: a.id, revision: a.revisionID)
        let transferred = try XCTUnwrap(workspace.shoppingLists.standing.last)
        let source = try XCTUnwrap(transferred.transfer?.contributionID)
        _ = try workspace.shops[0].addProtectedNeed(name: "Milk", quantity: unit, purpose: "Lunch", within: source)
        let before = workspace
        XCTAssertThrowsError(try workspace.returnStanding(transferred, shopID: a.id, revision: workspace.shops[0].revisionID))
        XCTAssertEqual(workspace, before)
    }
}
