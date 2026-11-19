import Foundation
import XCTest
@testable import RecordArchive

final class PaprikaCollectionTests: XCTestCase {
    private func collection() throws -> Data {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "fictional-paprika", withExtension: "paprikarecipes", subdirectory: "Fixtures"))
        return try Data(contentsOf: file)
    }

    func testCollectionPreservesSourceTextAndReportsDuplicatesAndSkippedRows() throws {
        let report = try PaprikaCollection.stage(collection())
        XCTAssertEqual(report.recipes.map(\.title), ["Sopa de calabaza", "Bread"])
        let soup = try XCTUnwrap(report.recipes.first)
        XCTAssertEqual(soup.yieldText, "4 platos")
        XCTAssertEqual(soup.ingredients, ["2 calabazas", "Agua"])
        XCTAssertEqual(soup.steps, ["Cortar.", "Cocer."])
        XCTAssertEqual(soup.sourceURL, "https://example.org/sopa")
        XCTAssertEqual(soup.notes, "Family cookbook\n\nAl gusto.")
        XCTAssertEqual(report.duplicateCount, 1)
        XCTAssertEqual(report.skippedRows, 1)
        XCTAssertEqual(report.unsupportedFields, ["categories"])
    }

    func testRepeatImportPreservesEditedSourceAndSkipsExistingLibrary() throws {
        let data = try collection()
        let recipes = try PaprikaCollection.stage(data).recipes
        let repeated = try PaprikaCollection.stage(data, existing: [recipes[1]], existingSourceIDs: [recipes[0].id])
        XCTAssertTrue(repeated.recipes.isEmpty)
        XCTAssertEqual(repeated.duplicateCount, 3)
    }

    func testRejectsIncompleteAndDamagedCollectionBeforeAnyRecipeIsSaved() throws {
        var data = try collection()
        XCTAssertThrowsError(try PaprikaCollection.stage(data.dropLast(1)))
        let header = try XCTUnwrap(data.range(of: Data([0x1f, 0x8b, 0x08])))
        data[header.lowerBound + 10] ^= 1
        XCTAssertThrowsError(try PaprikaCollection.stage(data))
    }
}
