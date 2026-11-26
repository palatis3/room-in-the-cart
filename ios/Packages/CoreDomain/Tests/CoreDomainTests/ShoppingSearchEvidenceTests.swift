import XCTest
@testable import CoreDomain

final class ShoppingSearchEvidenceTests: XCTestCase {
    func testSoldOutSubstituteAndNameMatchKeepSeparateLiteralSourcesInSavedOrder() throws {
        var shop = ShoppingLedger()
        let note = "La versión libre de azúcar se agotó. Compré la endulzada."
        let substitute = try shop.addManualLine(name: "Bebida endulzada", quantity: nil, notes: note)
        let desired = try shop.addManualLine(name: "Bebida libre de azúcar", quantity: nil)
        let results = shop.searchResults("LIBRE de AZUCAR")
        XCTAssertEqual(results.map(\.line.id), [substitute, desired])
        XCTAssertEqual(results[0].evidence, [.init(.lineNote, note)])
        XCTAssertEqual(results[1].evidence, [.init(.name, "Bebida libre de azúcar")])
        XCTAssertEqual(shop.search("LIBRE de AZUCAR").map(\.id), results.map(\.line.id))
        XCTAssertEqual(shop.searchResults("").map(\.evidence), [[], []])
    }

    func testEditedNameAndNoteRetainOnlyActiveOriginalWordingWithItsOwnAttribution() throws {
        var shop = ShoppingLedger()
        let preview = try shop.stageImport(text: "2 Café descafeinado", source: .paste)
        try shop.commitImport(preview)
        let lineID = try XCTUnwrap(shop.lines.first?.id)
        let source = try XCTUnwrap(shop.contributions(forLineID: lineID).first)
        let sourceNote = "The decaf pack sold out; bought the regular pack."
        try shop.updateContribution(contributionID: source.id, quantity: source.quantity, notes: sourceNote)
        try shop.updateLine(lineID: lineID, name: "Coffee", notes: "Bring a bag.", aisle: "Drinks")
        let loaded = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        XCTAssertEqual(loaded.searchResults("descafeinado").first?.evidence, [.init(.originalEntry, source.originalText)])
        XCTAssertEqual(loaded.searchResults("decaf pack").first?.evidence, [.init(.contributionNote, sourceNote)])
        XCTAssertEqual(loaded.searchResults("bring a bag").first?.evidence, [.init(.lineNote, "Bring a bag.")])
        try shop.trash(lineID: lineID)
        XCTAssertTrue(shop.searchResults("decaf").isEmpty)
        try shop.restore(lineID: lineID)
        try shop.removeContribution(contributionID: source.id)
        XCTAssertTrue(shop.searchResults("decaf").isEmpty)
    }

    func testPhraseAcrossFieldsKeepsEachParticipatingLiteralAndEffectiveDepartment() throws {
        var shop = ShoppingLedger()
        let id = try shop.addManualLine(name: "Café", quantity: nil, notes: "Molido fino")
        let results = shop.searchResults("fino    bebidas", department: { _ in "Bebidas frías" })
        XCTAssertEqual(results.map(\.line.id), [id])
        XCTAssertEqual(results[0].evidence, [.init(.lineNote, "Molido fino"), .init(.department, "Bebidas frías")])
        XCTAssertEqual(results[0].line.aisle, "Bebidas frías")
        XCTAssertTrue(shop.searchResults("bebidas").isEmpty)
    }
}
