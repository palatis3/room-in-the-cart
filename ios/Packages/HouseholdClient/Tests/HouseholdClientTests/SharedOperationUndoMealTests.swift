import XCTest
@testable import HouseholdClient

final class SharedOperationUndoMealTests: XCTestCase {
    func testMixedLetterMealUndoCodableRoundtripPreservesWordsAndExistingOutboxBytes() async throws {
        let facts = try mixedLetterMealFixture(), review = try OperationUndoFixture.review(facts)
        func roundtrip<T: Codable & Equatable>(_ raw: Any, as type: T.Type) throws {
            let value: T = try OperationUndoFixture.decode(raw)
            let bytes = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(T.self, from: bytes), value)
            // Compare with independently supplied server JSON, including wording,
            // integer quantities, nulls, list order and canonical nested IDs.
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: bytes),
                try OperationUndoFixture.decode(raw, as: JSONValue.self))
        }
        try roundtrip(facts["candidate"]!, as: SharedOperationUndoCandidate.self)
        // Preview is intentionally Decodable-only; do not invent a new
        // persistence API just for the fixture. Its Codable members roundtrip.
        let previewResponse: SharedOperationUndoPreview = try OperationUndoFixture.decode(facts["response"]!)
        XCTAssertEqual(previewResponse.mealUndo, review.candidate.mealUndo)
        XCTAssertEqual(previewResponse.action, review.candidate.action)
        let rawCandidate = facts["candidate"] as! [String: Any]
        try roundtrip(rawCandidate["action"]!, as: SharedOperationUndoAction.self)
        try roundtrip(rawCandidate["mealUndo"]!, as: SharedOperationUndoMeal.self)
        let supplied = try XCTUnwrap(review.candidate.mealUndo)
        XCTAssertEqual(supplied.restoredMeal?.planning?.groups.first?.name, "00000000-0000-4000-8000-00000000A043")
        XCTAssertEqual(supplied.restoredMeal?.planning?.ingredients.first?.quantity?.originalLiteral, "ABCDEF six original wraps")
        // Canonical encoding is not a relaxation of response decoding.
        var upper = rawCandidate, meal = upper["mealUndo"] as! [String: Any], restored = meal["restoredMeal"] as! [String: Any]
        var planning = restored["planning"] as! [String: Any], groups = planning["groups"] as! [[String: Any]]
        groups[0]["id"] = "00000000-0000-4000-8000-00000000A043"; planning["groups"] = groups
        restored["planning"] = planning; meal["restoredMeal"] = restored; upper["mealUndo"] = meal
        XCTAssertThrowsError(try OperationUndoFixture.decode(upper, as: SharedOperationUndoCandidate.self))

        // Production pending work persists SharedDemandAction, not UndoAction.
        // Its existing bytes and canonical typed identity must survive restart.
        let preview = review.response.preview
        let binding = SharedDemandOperationBinding(context: review.context, shopID: review.page.shopId,
            reservedOperationID: preview.receipt.operationId, previewID: preview.previewId, previewDigest: preview.previewDigest,
            action: review.response.action.commandAction, base: .init(shopRevision: preview.shopRevision, authorityEpoch: preview.authorityEpoch), graphRevision: preview.after.revision)
        var body = try binding.action.bodyValues()
        body["demandReview"] = .object(["previewId": .string(preview.previewId.string), "previewDigest": .string(preview.previewDigest)])
        let envelope = CommandEnvelope(replayWindow: UUID().uuidString.lowercased(), shopId: review.page.shopId.string, kind: "shop.patch", base: binding.base, body: body)
        let pending = try PendingOperation(envelope: envelope, householdID: review.context.householdID, memberID: review.context.memberID, deviceID: review.context.deviceID, sharedDemandBinding: binding)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("outbox.json")
        try await OperationOutbox(url: url).append(pending)
        let saved = try await OperationOutbox(url: url).operations(), restoredOperation = try XCTUnwrap(saved.first)
        XCTAssertEqual(saved, [pending]); XCTAssertEqual(restoredOperation.bytes, pending.bytes)
        let restoredBinding = try XCTUnwrap(restoredOperation.sharedDemandBinding)
        XCTAssertEqual(try restoredBinding.validate(restoredOperation), envelope)
        if case .patch(let action) = restoredBinding.action { XCTAssertEqual(action.mealEdit?.meal, supplied.restoredMeal) }
        else { XCTFail("Meal restoration lost its original patch action") }
    }
    func testSkippedDinnerRestoresExactIdentityAndPreservesLunchAndLaterStaple() throws {
        let review = try OperationUndoFixture.review(OperationUndoFixture.mealObject())
        let meal = try XCTUnwrap(review.candidate.mealUndo), edit = try XCTUnwrap(review.response.action.body.mealEdit)
        XCTAssertEqual(meal.touchedFields, [.membership]); XCTAssertNil(meal.current.meal)
        XCTAssertEqual(meal.current.revision, 5); XCTAssertEqual(meal.targetAfter.revision, 5)
        XCTAssertEqual(meal.restoredMeal, meal.targetBefore.meal); XCTAssertEqual(edit.meal, meal.restoredMeal)
        XCTAssertEqual(edit.occurrenceId, meal.occurrenceId); XCTAssertNil(edit.baseMealRevision)
        XCTAssertNil(edit.proposalId); XCTAssertNil(edit.changeProposalId)
        for suffix in ["000000000022", "000000000012"] {
            let old = try XCTUnwrap(review.candidate.before.contributions.first { $0.id.string.hasSuffix(suffix) })
            XCTAssertEqual(review.candidate.after.contributions.first { $0.id == old.id }, old)
        }
        XCTAssertEqual(review.candidate.beforeTotals[0].quantity?.numerator, 4)
        XCTAssertEqual(review.candidate.afterTotals[0].quantity?.numerator, 10)
        XCTAssertEqual(review.candidate.after.contributions.first { $0.id.string.hasSuffix("000000000021") }?.quantity?.originalLiteral, "Six original taco wraps")
        XCTAssertEqual(review.candidate.action.body.lines.last, review.shop.lines.last)
    }
    func testMealEvidenceRequiredNullsAndNonmealOmissionAreStrict() throws {
        let fixture = try OperationUndoFixture.mealObject()
        let original = fixture["candidate"] as! [String: Any]
        for key in ["mealUndo", "proposal", "current.meal", "targetAfter.meal", "baseMealRevision"] {
            var candidate = original
            if key == "mealUndo" { candidate.removeValue(forKey: key) }
            else if key == "baseMealRevision" {
                var action = candidate["action"] as! [String: Any], body = action["body"] as! [String: Any], edit = body["mealEdit"] as! [String: Any]
                edit.removeValue(forKey: key); body["mealEdit"] = edit; action["body"] = body; candidate["action"] = action
            } else {
                var meal = candidate["mealUndo"] as! [String: Any]
                if key == "proposal" { meal.removeValue(forKey: key) }
                else { let part = String(key.split(separator: ".")[0]); var fact = meal[part] as! [String: Any]; fact.removeValue(forKey: "meal"); meal[part] = fact }
                candidate["mealUndo"] = meal
            }
            XCTAssertThrowsError(try OperationUndoFixture.decode(candidate, as: SharedOperationUndoCandidate.self), key)
        }
        for path in ["mealUndo", "targetBefore", "restoredMeal", "mealEdit"] {
            var candidate = original
            if path == "mealUndo" { candidate[path] = NSNull() }
            else if path == "mealEdit" { var a = candidate["action"] as! [String: Any], b = a["body"] as! [String: Any]; b[path] = NSNull(); a["body"] = b; candidate["action"] = a }
            else { var m = candidate["mealUndo"] as! [String: Any]; if path == "targetBefore" { m[path] = ["revision": 4, "meal": NSNull()] } else { m[path] = NSNull() }; candidate["mealUndo"] = m }
            XCTAssertThrowsError(try OperationUndoFixture.decode(candidate, as: SharedOperationUndoCandidate.self), path)
        }
        var nonmeal = try OperationUndoFixture.object()["candidate"] as! [String: Any]
        let typed: SharedOperationUndoCandidate = try OperationUndoFixture.decode(nonmeal)
        let roundtrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as! NSDictionary
        XCTAssertEqual(roundtrip, nonmeal as NSDictionary)
        nonmeal["mealUndo"] = NSNull()
        XCTAssertThrowsError(try OperationUndoFixture.decode(nonmeal, as: SharedOperationUndoCandidate.self))
    }
    func testLaterRemovalTombstoneAndMissingActiveMealListCannotMasqueradeAsOriginalSkip() throws {
        for mode in ["laterTombstone", "futureRevision", "missingMeals", "activeOccurrence"] {
            var f = try OperationUndoFixture.mealObject(), candidate = f["candidate"] as! [String: Any]
            var meal = candidate["mealUndo"] as! [String: Any], current = meal["current"] as! [String: Any], shop = f["shop"] as! [String: Any]
            switch mode {
            case "laterTombstone": current["revision"] = 6
            case "futureRevision": current["revision"] = 8
            case "missingMeals": shop.removeValue(forKey: "meals")
            default: var meals = shop["meals"] as! [[String: Any]]; meals.append(["occurrenceId": meal["occurrenceId"]!, "revision": 5, "meal": meal["restoredMeal"]!]); shop["meals"] = meals
            }
            meal["current"] = current; candidate["mealUndo"] = meal; f["candidate"] = candidate; f["shop"] = shop
            XCTAssertThrowsError(try validateMealCandidate(f), mode)
        }
    }
    func testMealOnlyDayUndoKeepsLaterTitleAndUsesLatestActiveRevision() throws {
        let review = try OperationUndoFixture.review(editedMealFixture())
        let meal = try XCTUnwrap(review.candidate.mealUndo)
        XCTAssertEqual(meal.touchedFields, [.day]); XCTAssertEqual(meal.current.revision, 6)
        XCTAssertEqual(meal.restoredMeal?.title, "Later taco title"); XCTAssertEqual(meal.restoredMeal?.day, "2026-11-10")
        XCTAssertEqual(review.response.action.body.mealEdit?.baseMealRevision, 6)
        XCTAssertTrue(review.candidate.scope.touchedLines.isEmpty); XCTAssertEqual(review.candidate.scope.graphRows, 0)
        XCTAssertFalse(review.candidate.scope.quoteChanged); XCTAssertEqual(review.candidate.action.body.lines, review.shop.lines)
        XCTAssertEqual(review.candidate.before.contributions, review.candidate.after.contributions)
        XCTAssertEqual(review.response.preview.receipt.contributions, [])
        XCTAssertThrowsError(try SharedOperationUndoPreviewRequest(candidate: review.candidate, packs: []))
    }
    func testChangedTouchedFieldsOrUntouchedTitleAndAtomicPlanningAreRejected() throws {
        for mode in ["changedDay", "lostTitle", "duplicateField", "atomicPlanning", "wrongCurrentRevision"] {
            var f = try editedMealFixture(), c = f["candidate"] as! [String: Any], m = c["mealUndo"] as! [String: Any]
            var current = m["current"] as! [String: Any], currentMeal = current["meal"] as! [String: Any], restored = m["restoredMeal"] as! [String: Any]
            switch mode {
            case "changedDay": currentMeal["day"] = "2026-11-12"
            case "lostTitle": restored["title"] = "Original taco dinner"
            case "duplicateField": m["touchedFields"] = ["day", "day"]
            case "wrongCurrentRevision": current["revision"] = 7
            default:
                var accepted = m["targetAfter"] as! [String: Any], acceptedMeal = accepted["meal"] as! [String: Any], plan = acceptedMeal["planning"] as! [String: Any]
                plan["leadTimeMinutes"] = 30; acceptedMeal["planning"] = plan; accepted["meal"] = acceptedMeal; m["targetAfter"] = accepted
                plan["completedSteps"] = ["Later preparation"]; currentMeal["planning"] = plan; m["touchedFields"] = ["day", "planning"]
            }
            current["meal"] = currentMeal; m["current"] = current; m["restoredMeal"] = restored; c["mealUndo"] = m
            // Bind the mutated current facts/action too, so the touched-field
            // check cannot pass merely because another comparison rejects first.
            var shop = f["shop"] as! [String: Any], meals = shop["meals"] as! [[String: Any]]
            meals[1]["meal"] = currentMeal; shop["meals"] = meals; f["shop"] = shop
            var action = c["action"] as! [String: Any], body = action["body"] as! [String: Any], edit = body["mealEdit"] as! [String: Any]
            edit["meal"] = restored; body["mealEdit"] = edit; action["body"] = body; c["action"] = action
            f["candidate"] = c; XCTAssertThrowsError(try validateMealCandidate(f), mode)
        }
    }
    func testMealShapePreservesWordsAndRejectsUnknownFieldsMissingQuantityAndForgedProposalAction() throws {
        for mode in ["unknown", "missingQuantity", "uppercaseID", "proposalInAction", "previewDrift"] {
            var f = try OperationUndoFixture.mealObject(), c = f["candidate"] as! [String: Any], m = c["mealUndo"] as! [String: Any]
            if mode == "proposalInAction" {
                var a = c["action"] as! [String: Any], b = a["body"] as! [String: Any], edit = b["mealEdit"] as! [String: Any]
                edit["proposalId"] = "00000000-0000-4000-8000-000000000099"; b["mealEdit"] = edit; a["body"] = b; c["action"] = a
            } else if mode == "previewDrift" {
                var response = f["response"] as! [String: Any], responseMeal = response["mealUndo"] as! [String: Any]
                responseMeal["proposal"] = ["kind": "move", "proposalId": "00000000-0000-4000-8000-000000000099"]
                response["mealUndo"] = responseMeal; f["response"] = response
            } else {
                var restored = m["restoredMeal"] as! [String: Any], planning = restored["planning"] as! [String: Any]
                if mode == "unknown" { restored["silentlyIgnored"] = "private fact" }
                else { var ingredients = planning["ingredients"] as! [[String: Any]]; if mode == "missingQuantity" { ingredients[0].removeValue(forKey: "quantity") } else { ingredients[0]["id"] = "00000000-0000-4000-8000-0000000000AB" }; planning["ingredients"] = ingredients; restored["planning"] = planning }
                m["restoredMeal"] = restored; c["mealUndo"] = m
            }
            f["candidate"] = c
            if mode == "previewDrift" { XCTAssertThrowsError(try OperationUndoFixture.review(f), mode) }
            else { XCTAssertThrowsError(try OperationUndoFixture.decode(c, as: SharedOperationUndoCandidate.self), mode) }
        }
    }
    func testMealUndoCannotReduceProtectedPortions() throws {
        var f = try editedMealFixture(), c = f["candidate"] as! [String: Any], m = c["mealUndo"] as! [String: Any]
        var before = m["targetBefore"] as! [String: Any], meal = before["meal"] as! [String: Any]
        meal["protected"] = true; meal["portions"] = 1; before["meal"] = meal; m["targetBefore"] = before; m["restoredMeal"] = meal
        meal["portions"] = 2; m["targetAfter"] = ["revision": 5, "meal": meal]; m["current"] = ["revision": 6, "meal": meal]; m["touchedFields"] = ["portions"]
        var shop = f["shop"] as! [String: Any], meals = shop["meals"] as! [[String: Any]]; meals[1]["meal"] = meal; shop["meals"] = meals; f["shop"] = shop
        var action = c["action"] as! [String: Any], body = action["body"] as! [String: Any], edit = body["mealEdit"] as! [String: Any]
        edit["meal"] = m["restoredMeal"]; body["mealEdit"] = edit; action["body"] = body; c["action"] = action; c["mealUndo"] = m; f["candidate"] = c
        XCTAssertThrowsError(try validateMealCandidate(f))
    }
}

/// Fixed second response: day-only target, followed by an unrelated title edit.
private func editedMealFixture() throws -> [String: Any] {
    var f = try OperationUndoFixture.mealObject(), c = f["candidate"] as! [String: Any], response = f["response"] as! [String: Any]
    var m = c["mealUndo"] as! [String: Any], before = m["restoredMeal"] as! [String: Any], accepted = before
    accepted["day"] = "2026-11-11"; var current = accepted; current["title"] = "Later taco title"
    before["title"] = "Later taco title"
    m["targetAfter"] = ["revision": 5, "meal": accepted]; m["current"] = ["revision": 6, "meal": current]
    m["restoredMeal"] = before; m["touchedFields"] = ["day"]
    var action = c["action"] as! [String: Any], body = action["body"] as! [String: Any], edit = body["mealEdit"] as! [String: Any]
    edit["baseMealRevision"] = 6; edit["meal"] = before; body["mealEdit"] = edit; action["body"] = body
    var shop = f["shop"] as! [String: Any], meals = shop["meals"] as! [[String: Any]]
    meals.append(["occurrenceId": m["occurrenceId"]!, "revision": 6, "meal": current]); shop["meals"] = meals; shop["lines"] = body["lines"]; f["shop"] = shop
    var graph = c["after"] as! [String: Any]; graph["revision"] = 3
    var page = f["page"] as! [String: Any]; page["graph"] = graph; page["totals"] = c["afterTotals"]; f["page"] = page
    var scope = c["scope"] as! [String: Any]; scope["touchedLines"] = []; scope["graphRows"] = 0
    c["before"] = graph; c["beforeTotals"] = c["afterTotals"]; c["beforeCheckout"] = c["afterCheckout"]
    c["scope"] = scope; c["action"] = action; c["mealUndo"] = m
    for key in ["before", "beforeTotals", "beforeCheckout", "action", "mealUndo"] { response[key] = c[key] }
    var metadata = response["operationUndo"] as! [String: Any]; metadata["scope"] = scope; response["operationUndo"] = metadata
    var receipt = response["receipt"] as! [String: Any]; receipt["contributions"] = []; response["receipt"] = receipt
    f["candidate"] = c; f["response"] = response; return f
}

private func validateMealCandidate(_ f: [String: Any]) throws {
    let candidate: SharedOperationUndoCandidate = try OperationUndoFixture.decode(f["candidate"]!)
    try candidate.validate(page: OperationUndoFixture.decode(f["page"]!), shop: OperationUndoFixture.decode(f["shop"]!), target: OperationUndoFixture.decode(f["target"]!))
}

/// Fixed mixed-letter server facts. UUID-looking user wording deliberately stays
/// uppercase; only explicit identifier fields may receive canonical encoding.
private func mixedLetterMealFixture() throws -> [String: Any] {
    let occurrence = "00000000-0000-4000-8000-00000000a041", ingredient = "00000000-0000-4000-8000-00000000a042"
    let group = "00000000-0000-4000-8000-00000000a043", binding = "00000000-0000-4000-8000-00000000a044"
    func transform(_ value: Any) -> Any {
        if let text = value as? String {
            if text == "00000000-0000-4000-8000-000000000041" { return occurrence }
            if text == "00000000-0000-4000-8000-000000000042" { return ingredient }
            return text
        }
        if let array = value as? [Any] { return array.map(transform) }
        guard let object = value as? [String: Any] else { return value }
        var result = object.mapValues(transform)
        if result["originalLiteral"] as? String == "Six original taco wraps" { result["originalLiteral"] = "ABCDEF six original wraps" }
        if result["title"] as? String == "Original taco dinner" {
            var planning = result["planning"] as! [String: Any], ingredients = planning["ingredients"] as! [[String: Any]]
            var quantity = ingredients[0]["quantity"] as! [String: Any]
            quantity["originalLiteral"] = "ABCDEF six original wraps"
            ingredients[0]["quantity"] = quantity; ingredients[0]["groupIds"] = [group]
            planning["sourceOccurrenceId"] = occurrence
            planning["groups"] = [["id": group, "name": group.uppercased(), "servings": ["numerator": 3, "denominator": 1], "protected": false]]
            planning["ingredients"] = ingredients
            planning["bindings"] = [["id": binding, "groupId": group, "ingredientId": ingredient, "quantity": quantity]]
            result["planning"] = planning
        }
        if result["kind"] as? String == "meal", result["occurrenceId"] as? String == occurrence {
            result["groupId"] = group; result["bindingId"] = binding
        }
        return result
    }
    return transform(try OperationUndoFixture.mealObject()) as! [String: Any]
}
