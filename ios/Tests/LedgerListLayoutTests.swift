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

    func testSystemPrintFormatterPaginatesAndOmitsPrivateNotesAndInactiveItems() throws {
        var shop = try populated("Corner Market")
        try shop.handle(lineID: shop.lines[1].id, by: "Private helper")
        for i in 1...35 { _ = try shop.addManualLine(name: "Package number \(i)", quantity: nil) }
        let listing = LargePrintList(shop: shop, layout: LedgerListLayout())
        let formatter = UISimpleTextPrintFormatter(attributedText: listing.printText())
        let renderer = LetterPageRenderer()
        renderer.addPrintFormatter(formatter,startingAtPageAt:0)
        let data = UIGraphicsPDFRenderer(bounds:renderer.paperRect).pdfData { context in
            let count = renderer.numberOfPages
            renderer.prepare(forDrawingPages:NSRange(location:0,length:count))
            for i in 0..<count { context.beginPage(); renderer.drawPage(at:i,in:renderer.paperRect) }
        }
        let pdf = try XCTUnwrap(PDFDocument(data:data))
        XCTAssertGreaterThan(pdf.pageCount,1)
        let text = try XCTUnwrap(pdf.string)
        for wanted in ["Corner Market","Apples","Soap","Package number 35"] { XCTAssertTrue(text.contains(wanted),wanted) }
        for hidden in ["Private note","Private helper","Milk"] { XCTAssertFalse(text.contains(hidden),hidden) }
    }
}

private final class LetterPageRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x:0,y:0,width:612,height:792) }
    override var printableRect: CGRect { paperRect.insetBy(dx:36,dy:36) }
}
