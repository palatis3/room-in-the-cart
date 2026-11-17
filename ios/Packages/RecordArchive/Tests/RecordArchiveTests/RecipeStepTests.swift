import CoreDomain
import XCTest
@testable import RecordArchive

final class RecipeStepTests: XCTestCase {
    func testReviewedStepRoundTripsAsNewRevisionWhileLegacyRecipeKeepsItsIdentity() throws {
        let legacy = Data(#"{"ingredients":["2 onions","1 cup rice"],"notes":"Saved notes","steps":["Chop.","Simmer."],"title":"Supper","yieldText":"2–3 bowls"}"#.utf8)
        let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: legacy)
        XCTAssertNil(recipe.reviewedSteps)
        XCTAssertEqual(try ArchiveCodec.canonical(recipe), legacy)
        XCTAssertEqual(recipe.id, ArchiveCodec.digest(legacy))
        var edited = recipe
        edited.reviewedSteps = [RecipeStep("Chop.", ingredientIndices: [0]), RecipeStep("Simmer.", ingredientIndices: [1], suggestedTimerMinutes: 8)]
        let archived = try edited.archiveRecord(origin: "recipe-library-v1")
        let restored = try JSONDecoder().decode(ImportedRecipe.self, from: XCTUnwrap(archived.nativePayload)).validated()
        XCTAssertEqual(restored, edited)
        XCTAssertNotEqual(restored.id, recipe.id)
        XCTAssertEqual(restored.cookingSteps.last?.suggestedTimerMinutes, 8)
        edited.reviewedSteps?[0].ingredientIndices = [2]
        XCTAssertThrowsError(try edited.validated())
        var notes = recipe
        notes.steps = []
        XCTAssertTrue(notes.cookingSteps.isEmpty)
        XCTAssertEqual(try notes.validated().notes, "Saved notes")
    }

    func testLargeTypedRecipeRetainsOrderAndBindingsAcrossAReorder() throws {
        let ingredients = (0..<1000).map { "ingredient " + String($0) }
        let texts = (0..<1000).map { "step " + String($0) }
        var details = texts.map { RecipeStep($0) }
        details[999].ingredientIndices = [0, 999]
        let recipe = ImportedRecipe(title: "Batch", ingredients: ingredients, steps: texts, reviewedSteps: details)
        let saved = try recipe.archiveRecord(origin: "recipe-library-v1")
        let reopened = try JSONDecoder().decode(ImportedRecipe.self, from: XCTUnwrap(saved.nativePayload))
        XCTAssertEqual(reopened.cookingSteps, details)
        let swapped = Array(ingredients.reversed().dropFirst())
        let remapped = RecipeStep.rebinding(details, from: ingredients, to: swapped)
        XCTAssertEqual(remapped[999].ingredientIndices, [998])
        XCTAssertTrue(remapped[0].ingredientIndices.isEmpty)
        XCTAssertEqual(reopened.cookingSteps[999].ingredientIndices, [0, 999])
    }
}
