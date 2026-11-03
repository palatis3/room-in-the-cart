import XCTest
@testable import CoreDomain

final class LedgerIndexSafetyTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testLargeImportKeepsExactReceiptAfterChecksAndRoundTrip() throws {
        var ledger = ShoppingLedger()
        let text = (0..<500).map { "1 Arroz item \($0)" }.joined(separator: "\n")
        let preview = ledger.stageImport(text: text, source: .paste)
        try ledger.commitImport(preview, at: at)
        let ids = ledger.lines.map(\.id)
        for id in ids.prefix(20) { try ledger.setChecked(lineID: id, checked: true, at: at) }
        let before = ledger
        XCTAssertEqual(try ledger.commitImport(preview, at: at.addingTimeInterval(200)), preview.id)
        XCTAssertEqual(ledger, before)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(ledger))
        try reopened.validate()
        XCTAssertEqual(reopened, ledger)
        XCTAssertEqual(reopened.search("ARROZ ítém 499").map(\.id), [ids[499]])
        var changed = preview; changed.lines[499].name = "Changed"
        XCTAssertThrowsError(try reopened.commitImport(changed))
        XCTAssertEqual(reopened, before)
    }

    func testSkippedDuplicateDoesNotBecomeAnExistingLineAndSearchKeepsSourceHistory() throws {
        var ledger = ShoppingLedger()
        let preview = ledger.stageImport(text: "1 café\n2 CAFE", source: .paste)
        XCTAssertEqual(preview.lines[1].duplicateLineIDs, [preview.lines[0].proposedLineID])
        try ledger.commitImport(preview, decisions: [preview.lines[0].id: .skip], at: at)
        let id = try XCTUnwrap(ledger.lines.first?.id)
        XCTAssertEqual(ledger.lines.count, 1)
        try ledger.updateLine(lineID: id, name: "Coffee", notes: "top shelf", aisle: "Drinks", at: at)
        XCTAssertEqual(ledger.search("cafe").map(\.id), [id], "Original source wording remains searchable")
        XCTAssertEqual(ledger.search("top shelf").map(\.id), [id])
        XCTAssertEqual(ledger.search("drinks").map(\.id), [id])
        try ledger.trash(lineID: id, at: at)
        XCTAssertTrue(ledger.search("cafe").isEmpty)
        try ledger.restore(lineID: id, at: at)
        try ledger.undoImport(batchID: preview.id, at: at)
        XCTAssertTrue(ledger.search("cafe").isEmpty)
    }

    func testGroupedQuantityValidationStillRejectsLateOverflowAtomically() throws {
        var ledger = ShoppingLedger()
        let preview = ledger.stageImport(text: (0..<500).map { "1 item \($0)" }.joined(separator: "\n"))
        try ledger.commitImport(preview, at: at)
        let line = ledger.lines[499]
        let source = try XCTUnwrap(ledger.contributions(forLineID: line.id).first)
        try ledger.updateContribution(contributionID: source.id,
            quantity: Quantity(amount: try Rational(Int64.max), unit: .count, originalLiteral: "maximum"), notes: "", at: at)
        let overflow = ledger.stageImport(text: "1 new item\n1 item 499")
        let before = ledger
        XCTAssertThrowsError(try ledger.commitImport(overflow, decisions: [overflow.lines[1].id: .addToLine(line.id)], at: at)) {
            XCTAssertEqual($0 as? DomainError, .overflow)
        }
        XCTAssertEqual(ledger, before, "The earlier valid row must also roll back")
        XCTAssertEqual(try ledger.quantity(forLineID: line.id)?.amount, try Rational(Int64.max))
    }

    func testReceiptMembershipAndOriginalOrderRemainValidatedAfterDecode() throws {
        var ledger = ShoppingLedger()
        let preview = ledger.stageImport(text: (0..<100).map { "1 item \($0)" }.joined(separator: "\n"))
        try ledger.commitImport(preview, at: at)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var batches = try XCTUnwrap(json["importBatches"] as? [[String: Any]])
        var ids = try XCTUnwrap(batches[0]["contributionIDs"] as? [String])
        ids.removeLast(); batches[0]["contributionIDs"] = ids; json["importBatches"] = batches
        let invalid = try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try invalid.validate())
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        json["lines"] = Array(try XCTUnwrap(json["lines"] as? [[String: Any]]).reversed())
        var reordered = try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: json))
        try reordered.validate()
        let newID = try reordered.addManualLine(name: "Last", quantity: nil, at: at)
        XCTAssertEqual(reordered.search("").last?.id, newID)
        XCTAssertEqual(reordered.search("").map(\.originalOrder), Array(0...100))
    }
}
