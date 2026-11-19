import XCTest
@testable import CoreDomain

final class StoreDepartmentTests: XCTestCase {
    private func list(_ branch: String, _ names: [String]) throws -> ShoppingLedger {
        var shop = ShoppingLedger(basis: ShopBasis(branch: branch))
        for name in names { _ = try shop.addManualLine(name: name, quantity: nil) }
        return shop
    }

    func testTwoBranchesRecallExactProductsAndSearchAndKeepHistoricalLists() throws {
        let north = try list("Market North", ["Oat milk", "Oat milk vanilla", "Paper"])
        let south = try list("Market South", ["Oat milk"])
        var memory = LedgerListLayout()
        try memory.setDepartment("Chilled", for: north.lines[0], in: north, remember: true)
        try memory.setDepartment("Household", for: north.lines[2], in: north, remember: true)
        try memory.setStoreOrder(["Household", "Chilled"], in: north)
        try memory.setDepartment("Shelf stable", for: south.lines[0], in: south, remember: true)
        let next = try list("Market North", ["OAT   MILK", "Oat milk vanilla", "Paper"])
        let other = try list("Market South", ["Oat milk"])
        memory.applyDepartmentMemory(to: [next, other], previous: [])
        XCTAssertEqual(memory.groups(shop: next).map(\.aisle), ["Household", "Chilled", ""])
        XCTAssertEqual(memory.groups(shop: next, search: "chill").flatMap(\.lines).map(\.id), [next.lines[0].id])
        XCTAssertEqual(memory.groups(shop: other).map(\.aisle), ["Shelf stable"])
        XCTAssertEqual(memory.department(for: next.lines[1], in: next), "")
        try memory.setDepartment("Drinks", for: north.lines[0], in: north, remember: true)
        XCTAssertEqual(memory.department(for: next.lines[0], in: next), "Chilled")
        var added = next
        _ = try added.addManualLine(name: "Oat milk", quantity: nil)
        memory.applyDepartmentMemory(to: [added], previous: [next])
        XCTAssertEqual(memory.department(for: added.lines[0], in: added), "Chilled")
        XCTAssertEqual(memory.department(for: added.lines[3], in: added), "Drinks")
        try memory.setDepartment("", for: added.lines[3], in: added, remember: false)
        XCTAssertEqual(memory.department(for: added.lines[3], in: added), "")
        XCTAssertEqual(memory.department(for: north.lines[0], in: north), "Drinks")
        try memory.validate(shops: [north, south, added, other])
    }

    func testRenameRequiresExplicitMatchAndScopedRestoreExcludesOtherProductsAndStores() throws {
        let original = try list("Original branch", ["Rice", "Secret snack"])
        let other = try list("Other branch", ["Rice"])
        let renamed = try list("Renamed branch", ["Rice"])
        var memory = LedgerListLayout()
        let store = try memory.matchStore(in: original, to: nil)
        try memory.setDepartment("Grains", for: original.lines[0], in: original, remember: true)
        try memory.setDepartment("Private aisle", for: original.lines[1], in: original, remember: true)
        try memory.setDepartment("West", for: other.lines[0], in: other, remember: true)
        memory.applyDepartmentMemory(to: [renamed], previous: [])
        XCTAssertNil(memory.matchedStore(in: renamed))
        XCTAssertEqual(memory.department(for: renamed.lines[0], in: renamed), GroceryDepartment.pantry.label(spanish: GroceryDepartment.usesSpanish))
        try memory.matchStore(in: renamed, to: store)
        XCTAssertEqual(memory.matchedStore(in: renamed), store)
        XCTAssertEqual(memory.department(for: renamed.lines[0], in: renamed), "Grains")
        var exported = LedgerWorkspace(shops: [renamed], selectedShopID: renamed.id)
        exported.listLayout = memory.scoped(to: renamed)
        let bytes = try JSONEncoder().encode(exported)
        let restored = try JSONDecoder().decode(LedgerWorkspace.self, from: bytes)
        XCTAssertEqual(restored.listLayout.scoped(to: renamed), exported.listLayout)
        XCTAssertEqual(restored.listLayout.departmentDirectory?.aliases, ["Renamed branch": store])
        XCTAssertEqual(restored.listLayout.departmentDirectory?.stores.count, 1)
        let text = String(decoding: bytes, as: UTF8.self)
        for hidden in ["Original branch", "Other branch", "West", "Secret snack", "Private aisle"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(hidden))
        }
        let future = try list("Renamed branch", ["Rice"])
        var restoredMemory = restored.listLayout
        restoredMemory.applyDepartmentMemory(to: [future], previous: [])
        XCTAssertEqual(restoredMemory.department(for: future.lines[0], in: future), "Grains")
        XCTAssertEqual(restored.shops.first, renamed)
    }

    func testCorrectingAnAliasPreservesPreviousShopAndFollowsTheNewBranchOnFutureLists() throws {
        let original = try list("Corner Market", ["Milk"])
        let reopenedName = try list("Corner Market", ["Milk"])
        var memory = LedgerListLayout()
        try memory.setDepartment("Chilled", for: original.lines[0], in: original, remember: true)
        let originalID = memory.matchedStore(in: original)
        memory.applyDepartmentMemory(to: [reopenedName], previous: [])
        let corrected = try memory.matchStore(in: reopenedName, to: nil, name: "Corner Market on Elm")
        try memory.setDepartment("End display", for: reopenedName.lines[0], in: reopenedName, remember: true)
        let next = try list("Corner Market", ["Milk"])
        memory.applyDepartmentMemory(to: [next], previous: [])
        XCTAssertEqual(memory.matchedStore(in: next), corrected)
        XCTAssertEqual(memory.department(for: next.lines[0], in: next), "End display")
        XCTAssertEqual(memory.matchedStore(in: original), originalID)
        XCTAssertEqual(memory.department(for: original.lines[0], in: original), "Chilled")
        var changed = next
        try changed.updateBasis(ShopBasis(branch: "Unmatched branch"))
        memory.applyDepartmentMemory(to: [changed], previous: [next])
        XCTAssertNil(memory.matchedStore(in: changed))
        XCTAssertEqual(memory.department(for: changed.lines[0], in: changed), GroceryDepartment.dairy.label(spanish: GroceryDepartment.usesSpanish))
        try memory.validate(shops: [original, reopenedName, changed])
    }

    func testLegacyLayoutReencodesWithoutNewFieldsAndRowOnlyEditsLeaveStoreUntouched() throws {
        let shop = try list("Old branch", ["Rice"])
        let bytes = Data(#"{"shopLayouts":{},"storeAisles":{"Old branch":["Grains"]}}"#.utf8)
        var memory = try JSONDecoder().decode(LedgerListLayout.self, from: bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(memory), bytes)
        XCTAssertNil(memory.matchedStore(in: shop))
        try memory.setDepartment("Grains", for: shop.lines[0], in: shop, remember: false)
        XCTAssertNil(memory.departmentDirectory)
        XCTAssertEqual(memory.groups(shop: shop, search: "grains").flatMap(\.lines).map(\.id), [shop.lines[0].id])
        XCTAssertEqual(shop.lines[0].aisle, "")
        try memory.validate(shops: [shop])
    }
}
