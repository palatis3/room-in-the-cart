import XCTest
import CoreDomain
@testable import RoomInTheCart

final class RecipeCaptureIntegrationTests: XCTestCase {
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
