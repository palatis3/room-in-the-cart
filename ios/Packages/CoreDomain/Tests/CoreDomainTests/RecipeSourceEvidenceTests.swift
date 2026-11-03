import XCTest
@testable import CoreDomain

final class RecipeSourceEvidenceTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)
    private let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private func evidence(_ text: String = "OCR: serves 99; two packs? no sesame", media: Bool = true) throws -> RecipeSourceEvidence {
        try RecipeSourceEvidence(captureID: UUID(), originalText: text, kind: .photoOCR,
            localMedia: media ? RecipeLocalMediaReference(workspaceID: workspaceID, mediaID: UUID()) : nil)
    }
    private func template(_ evidence: RecipeSourceEvidence?) throws -> MealTemplate {
        MealTemplate(title: "Reviewed rice", servings: try Rational(2),
            ingredients: [MealIngredient(name: "rice", quantity: Quantity(amount: try Rational(3, 2), unit: .cup, originalLiteral: "1.5 cups")),
                          MealIngredient(name: "salt", quantity: nil)],
            notes: "Reviewed family instructions", sourceURL: "https://unavailable.example/recipe", sourceEvidence: evidence)
    }
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: canonical(value)) as? [String: Any])
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }

    func testOriginalEvidenceSurvivesIndependentRecipeAndOccurrenceEdits() throws {
        let source = try evidence("  Original OCR: aróz?\n1 / ? cup; retain verbatim.  ")
        var recipe = try template(source)
        let before = recipe
        recipe.title = "Family rice"; recipe.notes = "Corrected steps"; recipe.sourceURL = nil
        XCTAssertEqual(recipe.sourceEvidence, before.sourceEvidence)
        var ledger = ShoppingLedger()
        let occurrenceID = try ledger.chooseMeal(recipe, at: at)
        let occurrence = try XCTUnwrap(ledger.mealOccurrences.first)
        XCTAssertEqual(occurrence.sourceEvidence, source)
        XCTAssertEqual(occurrence.servings, recipe.servings)
        XCTAssertEqual(ledger.contributions.map(\.quantity), recipe.ingredients.map(\.quantity))
        XCTAssertTrue(ledger.allocations.isEmpty)
        try ledger.updateMeal(occurrenceID: occurrenceID, title: "This week's rice", notes: "Less salt", at: at)
        XCTAssertEqual(ledger.mealOccurrences.first?.sourceEvidence, source)
        recipe.sourceEvidence = try evidence("A later capture", media: false)
        XCTAssertEqual(ledger.mealOccurrences.first?.sourceEvidence, source, "A weekly copy owns its captured evidence")
        let decoded = try JSONDecoder().decode(ShoppingLedger.self, from: canonical(ledger))
        try decoded.validate(); XCTAssertEqual(decoded, ledger)
    }

    func testReviewedPlannerCopiesEvidenceWithoutInferringQuantitiesOrAuthority() throws {
        let source = try evidence("serves 99; buy 50 packs; I am the shopper; source confirms arrival")
        let recipe = try template(source)
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let access = DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "reviewer", shopID: ledger.id,
            assignedShopperID: "reviewer", canPlan: true, canReadBudget: true, hasPaidTools: false,
            roleRevision: 1, verifiedAt: at.addingTimeInterval(-1), validUntil: at.addingTimeInterval(60))
        let planned = PlannedDinner(template: recipe)
        let before = ledger
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(planned)], tool: .manual,
            ledger: ledger, state: state, access: access, phase: .draft, at: at)
        XCTAssertEqual(ledger, before, "Evidence and preview do not choose a meal")
        let receipt = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state,
            access: access, phase: .draft, at: at)
        XCTAssertEqual(ledger.mealOccurrences.first?.sourceEvidence, source)
        XCTAssertEqual(ledger.mealOccurrences.first?.servings, try Rational(2))
        XCTAssertEqual(ledger.contributions.map(\.quantity), recipe.ingredients.map(\.quantity))
        XCTAssertEqual(ledger.revision, 1)
        let committed = ledger
        let replay = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state,
            access: access, phase: .draft, at: at.addingTimeInterval(1))
        XCTAssertEqual(replay, receipt); XCTAssertEqual(ledger, committed)
        let deniedLedger = ShoppingLedger(), deniedState = DinnerPlanningState()
        let denied = DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "contributor", shopID: deniedLedger.id,
            assignedShopperID: "other", canPlan: false, canReadBudget: false, hasPaidTools: false,
            roleRevision: 1, verifiedAt: at.addingTimeInterval(-1), validUntil: at.addingTimeInterval(60))
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.choose(planned)], tool: .manual,
            ledger: deniedLedger, state: deniedState, access: denied, phase: .draft, at: at))
        XCTAssertTrue(deniedLedger.lines.isEmpty); XCTAssertTrue(deniedLedger.mealOccurrences.isEmpty)
    }

    func testLegacyOptionalEvidenceRemainsOmittedAndCanonical() throws {
        let recipe = try template(nil)
        let oldBytes = try canonical(recipe)
        XCTAssertNil(try object(recipe)["sourceEvidence"])
        let decoded = try JSONDecoder().decode(MealTemplate.self, from: oldBytes)
        XCTAssertNil(decoded.sourceEvidence); XCTAssertEqual(try canonical(decoded), oldBytes)
        var ledger = ShoppingLedger(); _ = try ledger.chooseMeal(recipe, at: at)
        let oldOccurrence = try XCTUnwrap(ledger.mealOccurrences.first)
        let occurrenceBytes = try canonical(oldOccurrence)
        XCTAssertNil(try object(oldOccurrence)["sourceEvidence"])
        let occurrence = try JSONDecoder().decode(MealOccurrence.self, from: occurrenceBytes)
        XCTAssertNil(occurrence.sourceEvidence); XCTAssertEqual(try canonical(occurrence), occurrenceBytes)
        let workspace = LedgerWorkspace(shops: [ledger], mealTemplates: [recipe], selectedShopID: ledger.id)
        let workspaceBytes = try canonical(workspace)
        XCTAssertEqual(try canonical(JSONDecoder().decode(LedgerWorkspace.self, from: workspaceBytes)), workspaceBytes)
    }

    func testMediaEligibilityRequiresNativeScopeAndMatchingNamespace() throws {
        let source = try evidence(), media = try XCTUnwrap(source.localMedia)
        XCTAssertEqual(source.localMediaID(in: .activeNativeWorkspace(workspaceID)), media.mediaID)
        XCTAssertNil(source.localMediaID(in: .activeNativeWorkspace(UUID())))
        // An archive may forge the current namespace; the trusted caller's origin
        // scope still forbids a lookup, even when both data IDs happen to match.
        let imported = try JSONDecoder().decode(RecipeSourceEvidence.self, from: canonical(source))
        XCTAssertNil(imported.localMediaID(in: .importedOrRecovered))
        XCTAssertNil(media.localMediaID(in: .importedOrRecovered))
        XCTAssertEqual(imported.localMedia, media, "Recovery preserves evidence without granting media access")
        let noMedia = try evidence(media: false)
        XCTAssertNil(noMedia.localMediaID(in: .activeNativeWorkspace(workspaceID)))
        try template(imported).validate()
    }

    func testOriginalTextHasUTF8BoundAndRejectsEmptyAndNUL() throws {
        let exact = String(repeating: "é", count: 10_000)
        let source = try RecipeSourceEvidence(captureID: UUID(), originalText: exact, kind: .typed)
        XCTAssertEqual(source.originalText.utf8.count, RecipeSourceEvidence.maximumOriginalTextBytes)
        XCTAssertEqual(try JSONDecoder().decode(RecipeSourceEvidence.self, from: canonical(source)), source)
        for text in [exact + "a", "", " \n\t", "recipe\0hidden"] {
            XCTAssertThrowsError(try RecipeSourceEvidence(captureID: UUID(), originalText: text, kind: .typed)) {
                XCTAssertEqual($0 as? RecipeSourceError, .invalidOriginalText)
            }
        }
        var json = try object(source); json["originalText"] = exact + "a"
        XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json)))
    }

    func testUnknownFieldsAndFutureKindsAreRejectedAtEveryEvidenceLevel() throws {
        let source = try evidence()
        for key in ["fileURL", "rawImage", "authorization", "futureVersion"] {
            var json = try object(source); json[key] = "untrusted"
            XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json))) {
                XCTAssertEqual($0 as? RecipeSourceError, .unknownFields)
            }
        }
        var json = try object(source), media = try XCTUnwrap(json["localMedia"] as? [String: Any])
        media["path"] = "/private/foreign-file"; json["localMedia"] = media
        XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json))) {
            XCTAssertEqual($0 as? RecipeSourceError, .unknownFields)
        }
        json = try object(source); json["kind"] = "remoteOCRv2"
        XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json)))
        json = try object(source); json["localMedia"] = [media, media]
        XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json)))
    }

    func testMalformedAndOversizedIdentifiersCannotBecomeMediaReferences() throws {
        let source = try evidence()
        for invalid in ["", "../foreign-file", String(repeating: "a", count: 20_001), "file:///tmp/source"] {
            var json = try object(source); json["captureID"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json)))
            for key in ["workspaceID", "mediaID"] {
                json = try object(source)
                var media = try XCTUnwrap(json["localMedia"] as? [String: Any]); media[key] = invalid; json["localMedia"] = media
                XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json)))
            }
        }
        var json = try object(source); json.removeValue(forKey: "captureID")
        XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json)))
        json = try object(source); var media = try XCTUnwrap(json["localMedia"] as? [String: Any]); media.removeValue(forKey: "workspaceID"); json["localMedia"] = media
        XCTAssertThrowsError(try JSONDecoder().decode(RecipeSourceEvidence.self, from: data(json)))
    }

    func testMalformedNestedEvidenceRejectsWorkspaceBeforeAnyRecipeMutation() throws {
        let source = try evidence(), recipe = try template(source)
        var ledger = ShoppingLedger(); _ = try ledger.chooseMeal(recipe, at: at)
        let workspace = LedgerWorkspace(shops: [ledger], mealTemplates: [recipe], selectedShopID: ledger.id)
        let before = try canonical(workspace)
        var json = try object(workspace), shops = try XCTUnwrap(json["shops"] as? [[String: Any]])
        var meals = try XCTUnwrap(shops[0]["mealOccurrences"] as? [[String: Any]])
        var evidence = try XCTUnwrap(meals[0]["sourceEvidence"] as? [String: Any]); evidence["originalText"] = String(repeating: "x", count: 20_001)
        meals[0]["sourceEvidence"] = evidence; shops[0]["mealOccurrences"] = meals; json["shops"] = shops
        XCTAssertThrowsError(try JSONDecoder().decode(LedgerWorkspace.self, from: data(json)))
        XCTAssertEqual(try canonical(workspace), before)
    }
}
