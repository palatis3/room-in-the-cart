import Foundation
import XCTest
@testable import CoreDomain

final class QuickGroceryTests: XCTestCase {
    func testPlainGroceryCanReplayThenUndoOnlyItsSource() throws {
        var shop = ShoppingLedger()
        _ = try shop.addManualLine(name: "Milk", quantity: nil)
        let preview = try XCTUnwrap(QuickGrocery.stage("  huevos  ", in: shop))
        XCTAssertEqual(preview.lines.first?.name, "huevos")
        XCTAssertNil(preview.lines.first?.quantity)
        XCTAssertNil(preview.lines.first?.unresolvedReason)
        try shop.commitImport(preview)
        let saved = try JSONEncoder().encode(shop)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: saved)
        try reopened.commitImport(preview)
        XCTAssertEqual(reopened.search("").map(\.name), ["Milk", "huevos"])
        XCTAssertNil(try QuickGrocery.stage("HUEVOS", in: reopened))
        try reopened.setChecked(lineID: preview.lines[0].proposedLineID, checked: true)
        XCTAssertNil(try QuickGrocery.stage("huevos", in: reopened))
        try reopened.undoImport(batchID: preview.id)
        XCTAssertEqual(reopened.search("").map(\.name), ["Milk"])
        XCTAssertThrowsError(try reopened.commitImport(preview))
        XCTAssertNotNil(try QuickGrocery.stage("huevos", in: reopened))
    }

    func testQuantitiesRequestsAndListsGoToReviewWithOriginalWording() throws {
        let shop = ShoppingLedger()
        for text in ["2 kg rice", "3½ cups flour", "six bananas", "seis plátanos", "puñado de nueces",
                     "one or two boxes", "leche sin lactosa", "milk for Alex", "eggs, milk", "milk\neggs", "1–2 apples",
                     "0 lemons", "-1 lemon", "1 kg lemons", "1 box lemons", "1 lemon or lime", "1 ½ lemons"] {
            XCTAssertNil(try QuickGrocery.stage(text, in: shop), text)
        }
        for text in ["Oats", "Arroz blanco", "Bananas", "arroz integral", "Greek yogurt", "plátanos", "limo\u{301}n", "rigatoni"] {
            XCTAssertEqual(try QuickGrocery.stage(text, in: shop)?.lines.first?.name, text)
        }
        var pickup = ShoppingLedger()
        for (text, name, count) in [("1 lemon", "lemon", 1), ("2 limones", "limones", 2), ("3 plátanos", "plátanos", 3)] {
            let row = try XCTUnwrap(QuickGrocery.stage(text, in: pickup))
            let proposed = try XCTUnwrap(row.lines.first)
            XCTAssertEqual(proposed.name, name)
            XCTAssertEqual(proposed.quantity?.amount, try Rational(Int64(count)))
            XCTAssertEqual(proposed.quantity?.unit, .count)
            XCTAssertEqual(proposed.quantity?.originalLiteral, text)
            try pickup.commitImport(row)
            try pickup.commitImport(row)
            XCTAssertNil(try QuickGrocery.stage(text, in: pickup))
        }
        XCTAssertEqual(pickup.lines.count, 3)
    }

    func testOnlyExactProductOrConfirmedAliasCanShowStockWithoutAChoice() {
        let whole = UUID(), rye = UUID(), absent = UUID()
        let products = [(whole, "Whole wheat bread"), (rye, "Rye bread"), (whole, "Whole wheat bread")]
        let choice = GroceryPantryCandidates(name: "bread", products: products, confirmedAliases: [])
        XCTAssertNil(choice.unambiguous)
        XCTAssertEqual(choice.possible, [whole, rye])
        let exact = GroceryPantryCandidates(name: "  RYE bread ", products: products, confirmedAliases: [absent])
        XCTAssertEqual(exact.unambiguous, rye)
        let alias = GroceryPantryCandidates(name: "WW BRD", products: products, confirmedAliases: [whole])
        XCTAssertEqual(alias.unambiguous, whole)
        let ambiguous = GroceryPantryCandidates(name: "Rye bread", products: products, confirmedAliases: [whole])
        XCTAssertNil(ambiguous.unambiguous)
        XCTAssertEqual(ambiguous.possible, [whole, rye])
        XCTAssertTrue(GroceryPantryCandidates(name: "wheat flour", products: products, confirmedAliases: []).possible.isEmpty)
    }

    func testDepartmentChoicesIncludeOnlyThisShopsCustomDepartmentsAndLocalizedDefaults() throws {
        var shop = ShoppingLedger(basis: ShopBasis(branch: "North"))
        try shop.addManualLine(name: "Hummus", quantity: nil)
        try shop.addManualLine(name: "Pita", quantity: nil)
        let other = ShoppingLedger(basis: ShopBasis(branch: "South"))
        var layout = LedgerListLayout()
        try layout.setDepartment("Deli", for: shop.lines[0], in: shop, remember: false)
        try layout.setStoreOrder(["Deli", "International foods", "Dairy"], in: shop)
        try layout.setStoreOrder(["Back counter"], in: other)
        let english = layout.departmentChoices(in: shop, spanish: false)
        let spanish = layout.departmentChoices(in: shop, spanish: true)
        XCTAssertEqual(english.filter { $0 == "Deli" }.count, 1)
        XCTAssertEqual(english.filter { $0 == "Dairy" }.count, 1)
        XCTAssertTrue(english.contains("International foods"))
        XCTAssertTrue(spanish.contains("Deli"))
        XCTAssertTrue(spanish.contains("Lácteos"))
        XCTAssertFalse(english.contains("Back counter"))
        XCTAssertFalse(spanish.contains(""))
    }

    func testNewRowInOlderListUsesLatestConfirmedBranchCorrection() throws {
        var taught = ShoppingLedger(basis: ShopBasis(branch: "North"))
        try taught.addManualLine(name: "Milk", quantity: nil)
        var old = ShoppingLedger(basis: taught.basis)
        try old.addManualLine(name: "Milk", quantity: nil)
        var layout = LedgerListLayout()
        try layout.setDepartment("Cold cases", for: taught.lines[0], in: taught, remember: true)
        var updated = old
        try updated.addManualLine(name: "Milk", quantity: nil)
        layout.applyDepartmentMemory(to: [updated], previous: [old])
        XCTAssertEqual(layout.department(for: updated.lines[0], in: updated), GroceryDepartment.dairy.label(spanish: GroceryDepartment.usesSpanish))
        XCTAssertEqual(layout.department(for: updated.lines[1], in: updated), "Cold cases")
    }

    func testBilingualDepartmentSuggestionsYieldToBranchAndCanBeCleared() throws {
        XCTAssertEqual(GroceryDepartment.suggested(for: "LECHE ENTERA")?.label(spanish: true), "Lácteos")
        XCTAssertEqual(GroceryDepartment.suggested(for: "milk")?.label(spanish: false), "Dairy")
        XCTAssertEqual(GroceryDepartment.suggested(for: "papel de aluminio"), .household)
        XCTAssertNil(GroceryDepartment.suggested(for: "milk chocolate"))
        var original = ShoppingLedger(basis: ShopBasis(branch: "North"))
        try original.addManualLine(name: "Milk", quantity: nil)
        var next = ShoppingLedger(basis: original.basis)
        try next.addManualLine(name: "Milk", quantity: nil)
        var other = ShoppingLedger(basis: ShopBasis(branch: "South"))
        try other.addManualLine(name: "Milk", quantity: nil)
        var layout = LedgerListLayout()
        try layout.setDepartment("", for: original.lines[0], in: original, remember: true)
        layout.applyDepartmentMemory(to: [next, other], previous: [])
        XCTAssertEqual(layout.department(for: next.lines[0], in: next), "")
        XCTAssertEqual(layout.department(for: other.lines[0], in: other), GroceryDepartment.dairy.label(spanish: GroceryDepartment.usesSpanish))
        var workspace = LedgerWorkspace(shops: [original, next, other], selectedShopID: next.id)
        workspace.listLayout = layout
        XCTAssertEqual(try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace)), workspace)
    }
}
