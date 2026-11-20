import CoreDomain
import XCTest
@testable import RecordArchive

final class RecipeStepTests: XCTestCase {
    func testImportedReviewPrefillsBilingualQuantitiesAndKeepsRangesAndPacksForReview() throws {
        for yield in ["serves four", "4 servings", "para cuatro personas", "4 porciones"] {
            XCTAssertEqual(ImportedRecipe(title: "Soup", yieldText: yield).suggestedServings, try Rational(4))
        }
        for yield in ["", "4 bowls", "3–4 servings", "serves 4 or 6", "4 jars"] {
            XCTAssertNil(ImportedRecipe(title: "Soup", yieldText: yield).suggestedServings)
        }
        for (text, name, amount, unit) in [
            ("1 ½ cups dry lentils", "dry lentils", try Rational(3, 2), UnitOfMeasure.cup),
            ("una taza y media de arroz", "arroz", try Rational(3, 2), .cup),
            ("0,5 kg de lentejas", "lentejas", try Rational(1, 2), .kilogram),
            ("2 eggs", "eggs", try Rational(2), .count)
        ] {
            let row = ImportedRecipe.ingredientDraft(text)
            XCTAssertEqual(row.name, name)
            XCTAssertEqual(row.quantity?.unit, unit)
            XCTAssertEqual(row.quantity?.amount, amount)
            XCTAssertEqual(row.originalWording, text)
            XCTAssertNil(row.checkedWithoutAmount)
        }
        for text in ["cilantro al gusto", "salt to taste", "1–2 cups rice", "entre 1 y 2 tazas de arroz",
                     "2 cans beans", "2 paquetes de tortillas", "2 jars pesto", "1,000 g harina"] {
            let row = ImportedRecipe.ingredientDraft(text)
            XCTAssertNil(row.quantity, text)
            XCTAssertNil(row.checkedWithoutAmount, text)
            XCTAssertEqual(row.originalWording, text)
        }
    }

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

    func testOfflineDraftAcceptsOnlyReviewedRecipeRecordsAndPreservesBatchIdentity() throws {
        let zero = Date(timeIntervalSince1970: 0)
        let a = ImportedRecipe(title: "Rice", ingredients: ["1 cup rice"], steps: ["Boil."],
            reviewedSteps: [RecipeStep("Boil.", ingredientIndices: [0], suggestedTimerMinutes: 8)])
        var first = try a.archiveRecord(origin: "recipe-library-v1", savedAt: zero)
        first.id = "original-file-revision"
        first.parentRevision = first.id
        let second = try ImportedRecipe(title: "Soup", notes: "Choose vegetables later").archiveRecord(origin: "recipe-library-v1", savedAt: zero)
        let (report, records) = try XCTUnwrap(RecipeDraftFile.readIfPresent(RecipeDraftFile.encode([second, first])))
        XCTAssertEqual(Set(records.map(\.id)), [first.id, second.id])
        XCTAssertEqual(report.recipes.first { $0.title == "Rice" }?.cookingSteps, a.cookingSteps)
        XCTAssertEqual(report.recipes.first { $0.title == "Soup" }?.missingFields, [.servings, .ingredients, .instructions])
        var unrelated = first
        unrelated.kind = .ledger
        XCTAssertThrowsError(try RecipeDraftFile.encode([unrelated]))
        XCTAssertNil(try RecipeDraftFile.readIfPresent(Data(#"{"@type":"Recipe","name":"Soup"}"#.utf8)))
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
