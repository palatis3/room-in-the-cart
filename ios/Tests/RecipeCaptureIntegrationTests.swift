import XCTest
import CoreDomain
import RecordArchive
@testable import RoomInTheCart

final class RecipeCaptureIntegrationTests: XCTestCase {
    func testPastedFamilyNotesProposeOnlySupportedAmountsAndKeepOtherWording() throws {
        let note = "Sweet potato pita pockets\nServes 4\nPrep time: 25 minutes\n2 sweet potatoes\n4 pitas\nRoast the potatoes, then fill the pitas."
        let result = try RecipeOCRParser.draft(note, familyNote: true)
        XCTAssertEqual(result.title, "Sweet potato pita pockets")
        XCTAssertEqual(result.servings, "4")
        XCTAssertEqual(result.prepMinutes, 25)
        XCTAssertEqual(result.ingredientLines, ["2 sweet potatoes", "4 pitas"])
        let rows = result.ingredientLines.map(ImportedRecipe.ingredientDraft)
        XCTAssertEqual(rows.map(\.name), ["sweet potatoes", "pitas"])
        XCTAssertEqual(rows.map { $0.quantity?.amount }, [try Rational(2), try Rational(4)])
        XCTAssertEqual(result.instructionLines, ["Roast the potatoes, then fill the pitas."])
        XCTAssertTrue(result.unclassifiedText.isEmpty)
        XCTAssertFalse(result.confirmed)

        let spanish = try RecipeOCRParser.draft("Sopa\nPorciones: 4\nTiempo de preparación: 15 min\n2 camotes\n2–3 tazas de caldo\nHierve los camotes.", familyNote: true)
        XCTAssertEqual(spanish.prepMinutes, 15)
        XCTAssertEqual(spanish.ingredientLines, ["2 camotes"])
        XCTAssertEqual(spanish.unclassifiedText, "2–3 tazas de caldo")
        XCTAssertEqual(spanish.instructionLines, ["Hierve los camotes."])
    }

    func testEditingRecipePreservesOriginalEvidenceAndRevisionRules() throws {
        let evidence = try RecipeSourceEvidence(captureID: UUID(), originalText: "Original recipe\nServes 2", kind: .pasted)
        let original = MealTemplate(title: "Reviewed recipe", servings: try Rational(2),
            ingredients: [MealIngredient(name: "Rice", quantity: nil)], notes: "Reviewed instructions", sourceEvidence: evidence)
        var draft = DinnerTemplateDraft(original)
        XCTAssertEqual(try draft.template(), original)
        draft.title = "Our variation"; draft.notes = "Our revised instructions"; draft.source = "https://example.com/moved"
        let edited = try draft.template()
        XCTAssertEqual(edited.sourceEvidence, evidence)
        XCTAssertEqual(edited.revision, original.revision + 1)
        XCTAssertEqual(edited.ingredients, original.ingredients)
    }
}
