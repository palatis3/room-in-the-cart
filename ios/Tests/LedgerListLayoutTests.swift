import XCTest
import PDFKit
import UIKit
import CoreDomain
@testable import RoomInTheCart

@MainActor final class LedgerListLayoutTests: XCTestCase {
    private func populated(_ branch: String) throws -> ShoppingLedger {
        var shop = ShoppingLedger(title: "Saturday list", basis: ShopBasis(branch: branch))
        for (name, aisle) in [("Apples", "Produce"), ("Milk", "Dairy"), ("Soap", "")] {
            let id = try shop.addManualLine(name: name, quantity: Quantity(amount: .one, unit: .count, originalLiteral: "1 item"), notes: "Private note")
            try shop.updateLine(lineID: id, name: name, notes: "Private note", aisle: aisle)
        }
        return shop
    }

    func testStoreOrderShopOverrideSearchAndOriginalIdentitySurviveRelaunch() throws {
        var a = try populated("Market A")
        let b = try populated("Market A"), other = try populated("Market B")
        var workspace = LedgerWorkspace(shops: [a,b,other], selectedShopID: a.id)
        workspace.listLayout.storeAisles["Market A"] = ["Dairy", "Produce"]
        for shop in workspace.shops {
            var layout = ShopListLayout(); layout.mode = .aisle; layout.branch = shop.basis.branch
            workspace.listLayout.shopLayouts[shop.id.uuidString.lowercased()] = layout
        }
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.aisleOverride = ["Produce","Dairy"]
        workspace.listLayout.storeAisles["Other private store"] = ["Private group"]
        workspace.listLayout.storeAisles["Market A"]?.append("Other shop aisle")
        let scoped = try RecordsNativeCodec.ledgerScope(workspace, shop:b)
        XCTAssertEqual(scoped.listLayout.storeAisles,["Market A":["Dairy","Produce"]])
        XCTAssertEqual(scoped.listLayout.shopLayouts.keys.sorted(),[b.id.uuidString.lowercased()])
        let before = a.lines.map(\.id)
        workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(workspace.listLayout.groups(shop:b).map(\.aisle),["Dairy","Produce",""])
        XCTAssertEqual(workspace.listLayout.groups(shop:a).map(\.aisle),["Produce","Dairy",""])
        XCTAssertEqual(workspace.listLayout.groups(shop:other).map(\.aisle),["Produce","Dairy",""])
        XCTAssertEqual(workspace.listLayout.groups(shop:b, search:"Milk").flatMap(\.lines).map(\.id),[b.lines[1].id])
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.mode = .manual
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.lineOrder = Array(before.reversed())
        XCTAssertEqual(workspace.listLayout.groups(shop:a).flatMap(\.lines).map(\.id),Array(before.reversed()))
        try a.handle(lineID:before[0],by:"Sam"); try a.trash(lineID:before[1])
        XCTAssertEqual(workspace.listLayout.groups(shop:a).flatMap(\.lines).map(\.id),[before[2]])
        XCTAssertEqual(a.lines.map(\.id),before)
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.mode = .entered
        XCTAssertEqual(workspace.listLayout.groups(shop:workspace.shops[0]).flatMap(\.lines).map(\.id),before)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(workspace)) as? [String:Any])
        legacy.removeValue(forKey:"listLayout")
        let decoded = try JSONDecoder().decode(LedgerWorkspace.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertEqual(decoded.listLayout,LedgerListLayout())
    }

    func testManualOrderPreservesHiddenPositionsThroughReorderAndReopen() throws {
        var shop = try populated("Corner Market")
        let ids = shop.lines.map(\.id)
        let checked = ids[0], handled = ids[1], trashed = ids[2]
        let first = try shop.addManualLine(name: "Wraps", quantity: nil)
        let second = try shop.addManualLine(name: "Wraps", quantity: nil)
        var layout = ShopListLayout()
        layout.mode = .manual
        // The trashed item and the second Wraps row have never been manually ranked.
        layout.lineOrder = [first, handled, checked]
        try shop.setChecked(lineID: checked, checked: true)
        try shop.handle(lineID: handled, by: "Shopper")
        try shop.trash(lineID: trashed)
        try layout.setActiveOrder([second, first], in: shop)
        XCTAssertEqual(layout.lineOrder, [second, handled, checked, trashed, first])
        XCTAssertThrowsError(try layout.setActiveOrder([first, first], in: shop))
        XCTAssertThrowsError(try layout.setActiveOrder([second], in: shop))
        try shop.reopen(lineID: checked)
        try shop.reopen(lineID: handled)
        try shop.restore(lineID: trashed)
        var saved = LedgerListLayout()
        saved.shopLayouts[shop.id.uuidString.lowercased()] = layout
        let restored = try JSONDecoder().decode(LedgerListLayout.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.groups(shop: shop).flatMap(\.lines).map(\.id), [second, handled, checked, trashed, first])
        XCTAssertEqual(shop.lines.map(\.id), ids + [first, second])
    }

    func testSystemPrintFormatterPaginatesAndOmitsPrivateNotesAndInactiveItems() throws {
        var shop = try populated("Corner Market")
        try shop.handle(lineID: shop.lines[1].id, by: "Private helper")
        for i in 1...35 { _ = try shop.addManualLine(name: "Package number \(i)", quantity: nil) }
        let listing = LargePrintList(shop: shop, layout: LedgerListLayout())
        let renderer = LetterPageRenderer(list: listing.printText())
        let data = UIGraphicsPDFRenderer(bounds:renderer.paperRect).pdfData { context in
            let count = renderer.numberOfPages
            renderer.prepare(forDrawingPages:NSRange(location:0,length:count))
            for i in 0..<count { context.beginPage(); renderer.drawPage(at:i,in:renderer.paperRect) }
        }
        let pdf = try XCTUnwrap(PDFDocument(data:data))
        XCTAssertGreaterThan(pdf.pageCount,1)
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
            let footers = lines.filter { $0.string == "Room in the Cart" }
            XCTAssertEqual(footers.count, 1, "Page \(index + 1)")
            let footer = try XCTUnwrap(footers.first).bounds(for: page)
            XCTAssertLessThan(footer.maxY, 70)
            let body = lines.filter { $0.string != "Room in the Cart" }
            XCTAssertFalse(body.isEmpty, "A footer must not create a blank page")
            XCTAssertTrue(body.allSatisfy { $0.bounds(for: page).minY > footer.maxY })
        }
        let text = try XCTUnwrap(pdf.string)
        for wanted in ["Corner Market","Apples","Soap","Package number 35"] { XCTAssertTrue(text.contains(wanted),wanted) }
        let numberedItems = text.components(separatedBy: .newlines).filter { $0.hasPrefix("Package number ") }
        XCTAssertEqual(numberedItems, (1...35).map { "Package number \($0)" })
        for hidden in ["Private note","Private helper","Milk"] { XCTAssertFalse(text.contains(hidden),hidden) }
    }
}

private final class LetterPageRenderer: ShoppingListPageRenderer {
    override var paperRect: CGRect { CGRect(x:0,y:0,width:612,height:792) }
    override var printableRect: CGRect { paperRect.insetBy(dx:36,dy:36) }
}
