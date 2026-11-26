import Foundation
import XCTest
@testable import CoreDomain

final class ShoppingCSVTests: XCTestCase {
    private func table(_ text: String) throws -> GroceryCSVTable { try GroceryCSVTable(data: Data(text.utf8)) }

    func testQuotedExportPreservesRawCellsAndFlagsMalformedInput() throws {
        let parsed = try table("\u{feff}producto;notas;cantidad;upc\r\nTé;\"frío; con \"\"hielo\"\"\r\nmañana\";\"1,5\";00027\r\nTé;;;\r\nTé;;;\r\n")
        XCTAssertEqual(parsed.headers, ["producto","notas","cantidad","upc"])
        XCTAssertEqual(parsed.rows, [["Té","frío; con \"hielo\"\r\nmañana","1,5","00027"],["Té","","",""],["Té","","",""]])
        XCTAssertEqual(try table("item,note\nA,\"x,y\"").rows, [["A","x,y"]])
        XCTAssertEqual(try table("item\tnote\nA\t").rows, [["A",""]])
        XCTAssertThrowsError(try table("item,qty\nA,\"2"))
        XCTAssertThrowsError(try table("a,b;c\n1,2;3"))
        XCTAssertThrowsError(try GroceryCSVTable(data: Data([0xff])))
        XCTAssertThrowsError(try GroceryCSVTable(data: Data(repeating: 65, count: GroceryCSVTable.maximumBytes + 1)))
    }

    func testMapReviewReplayChangedSourceAndUndoAfterRelaunch() throws {
        let source = "Producto;Categoría;Nota;Cantidad;Unidad;Código de barras\nCafé;Bebidas;Sin azúcar;1,5;kg;000178\nAvena;Granos;;2;piezas;0009\nAvena;Granos;;2;piezas;0009\nMal;; ;1,500;g;\nArroz;; ;3;mystery;\nShort;x"
        var shop = ShoppingLedger()
        let first = try table(source)
        let mapping = ShoppingCSVColumn.suggestedMapping(first.headers)
        XCTAssertEqual(mapping.count, 6)
        let review = try ShoppingCSVReview(table: first, mapping: mapping, shop: shop)
        XCTAssertEqual(review.rows.map(\.status), [.ready,.ready,.matchingName,.invalidQuantity,.invalidQuantity,.wrongColumnCount])
        let batch = try review.apply(selected: [1,2,3], to: &shop)
        XCTAssertEqual(shop.lines.map(\.name), ["Café","Avena","Avena"])
        XCTAssertEqual(shop.lines[0].aisle, "Bebidas")
        XCTAssertEqual(shop.lines[0].notes, "Sin azúcar")
        XCTAssertEqual(try shop.quantity(forLineID: shop.lines[0].id)?.amount, try Rational(3,2))
        XCTAssertEqual(shop.importBatches.first?.preview.lines.first?.csvRecord?.barcode, "000178")
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        let revision = reopened.revision
        XCTAssertEqual(try review.apply(selected: [1,2,3], to: &reopened), batch)
        XCTAssertEqual(reopened.revision, revision)
        let changed = try table(source.replacingOccurrences(of: "Sin azúcar", with: "Molido"))
        let second = try ShoppingCSVReview(table: changed, mapping: mapping, shop: reopened)
        XCTAssertEqual(second.rows.prefix(3).map(\.status), [.matchingName,.previouslyImported,.previouslyImported])
        XCTAssertThrowsError(try second.apply(selected: [2], to: &reopened))
        XCTAssertEqual(reopened, shop)
        try reopened.undoImport(batchID: batch)
        let afterUndo = try ShoppingCSVReview(table: first, mapping: mapping, shop: reopened)
        XCTAssertEqual(afterUndo.rows.first?.status, .ready)
    }

    func testReviewRequiresDistinctMappingAndCurrentShopRevision() throws {
        let file = try table("Name,Name,Notes\nCorn,Brand,")
        var shop = ShoppingLedger()
        XCTAssertNil(ShoppingCSVColumn.suggestedMapping(file.headers)[.item])
        XCTAssertThrowsError(try ShoppingCSVReview(table: file, mapping: [.item:0,.note:0], shop: shop))
        let review = try ShoppingCSVReview(table: file, mapping: [.item:0,.note:2], shop: shop)
        _ = try shop.addManualLine(name: "Corn", quantity: nil)
        XCTAssertThrowsError(try review.apply(selected: [1], to: &shop))
        XCTAssertEqual(shop.lines.count, 1)
    }
}
