import XCTest
@testable import CoreDomain

final class StagedImportIdentityTests: XCTestCase {
    func testEditedSelectionSurvivesReloadAndRequiresSameSourceOnReplay() throws {
        var shop = ShoppingLedger()
        let preview = try shop.stageImport(text: "3 pears", source: .selectedText)
        let original = "2 pears"
        try shop.commitImport(preview, originalSelection: original)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        try reopened.validate()
        XCTAssertEqual(reopened.importBatches.first?.originalText, original)
        XCTAssertEqual(reopened.importBatches.first?.preview.originalText, "3 pears")
        XCTAssertEqual(try reopened.commitImport(preview, originalSelection: original), preview.id)
        XCTAssertThrowsError(try reopened.commitImport(preview, originalSelection: "4 pears"))
        XCTAssertThrowsError(try reopened.commitImport(preview))
        XCTAssertEqual(reopened, shop)
        let typed = try reopened.stageImport(text: "beans")
        XCTAssertThrowsError(try reopened.commitImport(typed, originalSelection: original))
        XCTAssertEqual(reopened, shop)
    }

    func testStagingRejectsTooManyDuplicateRowsBeforeReview() {
        let shop = ShoppingLedger()
        let source = Array(repeating: "2 wraps", count: 1_001).joined(separator: "\n")
        XCTAssertThrowsError(try shop.stageImport(text: source, source: .paste)) {
            XCTAssertEqual($0 as? ImportTextLimit, .nonblankLines(maximum: 1_000))
        }
    }

    func testSourceLimitsAcceptExactBoundariesAndPreserveOriginalWording() throws {
        var shop = ShoppingLedger()
        let last = " \tCafe\u{301}  "
        let source = Array(repeating: "beans", count: 999).joined(separator: "\r\n") + "\u{2028}    \u{85}" + last + "\n"
        let full = try shop.stageImport(text: source)
        XCTAssertEqual(full.lines.count, 1_000)
        XCTAssertEqual(Array(full.originalText.utf8), Array(source.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(full.lines.last).originalText.utf8), Array(last.utf8))
        XCTAssertEqual(try XCTUnwrap(full.lines.last).duplicateLineIDs, [])

        let sourceAtLimit = String(repeating: " ", count: StagedListImport.maximumTextBytes - 3) + "\n" + "é"
        let byteLimit = try shop.stageImport(text: sourceAtLimit)
        XCTAssertEqual(byteLimit.originalText.utf8.count, StagedListImport.maximumTextBytes)
        XCTAssertEqual(byteLimit.lines.map(\.originalText), ["é"])
        XCTAssertThrowsError(try shop.stageImport(text: sourceAtLimit + "x")) {
            XCTAssertEqual($0 as? ImportTextLimit, .totalBytes)
        }

        let longLine = String(repeating: " ", count: StagedListImport.maximumOriginalLineBytes - 4) + "rice"
        try shop.commitImport(shop.stageImport(text: longLine))
        XCTAssertThrowsError(try shop.stageImport(text: "salt\n \n" + longLine + "s")) {
            XCTAssertEqual($0 as? ImportTextLimit, .originalLineBytes(item: 2))
        }
        // Names remain editable in review; a legal original line need not be a legal final item name.
        let longName = String(repeating: "r", count: 513)
        var reviewed = try shop.stageImport(text: longName)
        reviewed.lines[0].name = "radishes"
        try shop.commitImport(reviewed)
        XCTAssertEqual(shop.importBatches.last?.originalText, longName)

        // A previously reviewed draft can have fewer rows than its source (e.g. after capture).
        let compact = try shop.stageImport(text: "lentils")
        let legacy = StagedListImport(id: compact.id, shopID: shop.id, baseRevision: shop.revision,
            source: .selectedText, originalText: Array(repeating: "lentils", count: 1_001).joined(separator: "\n"), lines: compact.lines)
        try shop.commitImport(legacy)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        let before = reopened
        XCTAssertEqual(try reopened.commitImport(legacy), legacy.id)
        XCTAssertEqual(reopened, before)
    }

    func testExternalIdentitySurvivesRestartAndExactReplay() throws {
        var shop = ShoppingLedger()
        let operation = UUID()
        let preview = try shop.stageImport(text: "2 wraps", source: .selectedText, importID: operation)
        XCTAssertEqual(preview.id, operation)
        let durablePreview = try JSONEncoder().encode(preview)
        XCTAssertEqual(try shop.commitImport(preview), operation)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        let receipt = try JSONDecoder().decode(StagedListImport.self, from: durablePreview)
        let before = reopened
        XCTAssertEqual(try reopened.commitImport(receipt), operation)
        XCTAssertEqual(reopened, before)
        let restaged = try reopened.stageImport(text: "2 wraps", source: .selectedText, importID: operation)
        XCTAssertThrowsError(try reopened.commitImport(restaged))
        XCTAssertEqual(reopened, before)
    }

    func testSameTextDifferentExplicitOperationRemainsSeparateReviewedIntent() throws {
        var shop = ShoppingLedger()
        let first = try shop.stageImport(text: "2 wraps", source: .selectedText, importID: UUID())
        try shop.commitImport(first)
        let second = try shop.stageImport(text: "2 wraps", source: .selectedText, importID: UUID())
        XCTAssertNotEqual(first.id, second.id)
        try shop.commitImport(second, decisions: [second.lines[0].id: .addNew])
        XCTAssertEqual(shop.importBatches.count, 2)
        XCTAssertEqual(shop.lines.count, 2)
    }
}
