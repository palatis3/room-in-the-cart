import XCTest
@testable import CoreDomain

final class StagedImportIdentityTests: XCTestCase {
    func testExternalIdentitySurvivesRestartAndExactReplay() throws {
        var shop = ShoppingLedger()
        let operation = UUID()
        let preview = shop.stageImport(text: "2 wraps", source: .selectedText, importID: operation)
        XCTAssertEqual(preview.id, operation)
        let durablePreview = try JSONEncoder().encode(preview)
        XCTAssertEqual(try shop.commitImport(preview), operation)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        let receipt = try JSONDecoder().decode(StagedListImport.self, from: durablePreview)
        let before = reopened
        XCTAssertEqual(try reopened.commitImport(receipt), operation)
        XCTAssertEqual(reopened, before)
        let restaged = reopened.stageImport(text: "2 wraps", source: .selectedText, importID: operation)
        XCTAssertThrowsError(try reopened.commitImport(restaged))
        XCTAssertEqual(reopened, before)
    }

    func testSameTextDifferentExplicitOperationRemainsSeparateReviewedIntent() throws {
        var shop = ShoppingLedger()
        let first = shop.stageImport(text: "2 wraps", source: .selectedText, importID: UUID())
        try shop.commitImport(first)
        let second = shop.stageImport(text: "2 wraps", source: .selectedText, importID: UUID())
        XCTAssertNotEqual(first.id, second.id)
        try shop.commitImport(second, decisions: [second.lines[0].id: .addNew])
        XCTAssertEqual(shop.importBatches.count, 2)
        XCTAssertEqual(shop.lines.count, 2)
    }
}
