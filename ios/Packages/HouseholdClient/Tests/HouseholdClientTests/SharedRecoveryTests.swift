import XCTest
@testable import HouseholdClient

private typealias RecoveryRow = [String: Any]
private func decodeRecovery<T: Decodable>(_ type: T.Type, _ row: RecoveryRow) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: row))
}

private struct RecoveryFixture {
    let shop = UUID().uuidString
    let now = "2026-11-07T09:00:00.000Z"
    let base = ["shopRevision": 4, "authorityEpoch": 1, "recoveryRevision": 0, "contextRevision": 0, "supplyRevision": 2, "pantryRevision": 3]
    let target: RecoveryRow, donor: RecoveryRow

    init() {
        func meal(_ title: String) -> RecoveryRow {
            let nilValue = NSNull()
            let need: RecoveryRow = ["id": UUID().uuidString, "foodId": nilValue, "matchedSourceIds": [], "ingredientId": UUID().uuidString,
                "groupId": nilValue, "groupIds": [], "name": "beans", "notes": "", "quantity": nilValue, "priority": "required",
                "due": nilValue, "exclusions": ["peanuts"]]
            return ["occurrenceId": UUID().uuidString, "revisionId": UUID().uuidString, "sourceMealRevision": 2, "title": title,
                "notes": "", "sourceURL": nilValue, "portions": 2, "day": "2026-11-07", "zone": nilValue, "due": nilValue,
                "exclusions": ["peanuts"], "template": nilValue, "groups": [], "needs": [need], "remainingElapsedMinutes": nilValue,
                "requiredLeadMinutes": nilValue, "advanceStepsCompleted": false]
        }
        target = meal("Frijoles / beans"); donor = meal("Bean soup")
    }

    var scope: RecoveryRow {
        ["shopId": shop, "placedRevision": 3, "asOf": now, "shopRevision": 4, "authorityEpoch": 1, "recoveryRevision": 0,
         "supplyRevision": 2, "contextRevision": 0, "pantryRevision": 3]
    }
    func desk() throws -> RecoveryRow {
        let rows = [target, donor]
        let meals = try rows.map { try decodeRecovery(SharedRecoveryMeal.self, $0) }
        let digests: [RecoveryRow] = try meals.map { ["occurrenceId": $0.id.uuidString, "digest": try $0.targetDigest()] }
        return ["shopId": shop, "placedRevision": 3, "asOf": now, "base": base, "meals": rows, "targetDigests": digests,
                "sourceOptions": [], "unplannedOccurrenceIds": [], "commitmentInventoryComplete": true,
                "mealSources": meals.map { ["occurrenceId": $0.id.uuidString, "sourceMealRevision": 2, "sealedRevisionId": $0.revisionId.uuidString,
                                           "completedSteps": [], "approvedIdea": NSNull(), "sourceOccurrenceId": NSNull()] as RecoveryRow }]
    }
    func intent(_ page: SharedRecoveryPage, agrees: Bool) throws -> SharedRecoveryIntent {
        let prior = page.meals[0]
        var next = prior; next.revisionId = UUID(); next.needs[0].id = UUID(); next.needs[0].ingredientId = UUID()
        next.title = "bean    SOUP"; next.notes = "  café\n🥣"
        return .init(occurrenceId: prior.id, targetDigest: try prior.targetDigest(), replacement: next, reviewedAt: now,
                     repeatOfOccurrenceId: nil, agreesToRepeat: agrees, proposesExtraTrip: false, agreesToExtraTrip: false, acceptsUnresolved: true)
    }
    func preview(_ page: SharedRecoveryPage, _ intent: SharedRecoveryIntent) throws -> RecoveryRow {
        func projection(_ meals: [SharedRecoveryMeal]) throws -> RecoveryRow {
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meals))
            let demands: [RecoveryRow] = meals.flatMap(\.needs).map { ["needId": $0.id.uuidString, "due": NSNull(), "deadlineStatus": "unknown",
                "allocated": NSNull(), "shortfall": NSNull(), "unit": NSNull(), "issues": ["unknown_quantity", "unknown_food"],
                "sourceIssues": [], "reservations": []] }
            return ["meals": wire, "demands": demands, "allocations": []]
        }
        return ["shopId": shop, "placedRevision": 3, "base": base, "asOf": now, "expiresAt": "2026-11-07T09:10:00.000Z",
            "previewId": UUID().uuidString, "previewDigest": String(repeating: "a", count: 64), "before": try projection(page.meals),
            "after": try projection([intent.replacement, page.meals[1]]), "foodConfirmed": false, "timingConfirmed": false,
            "repeatRequired": true, "feasible": false, "consentSatisfied": intent.agreesToRepeat]
    }
}

extension HouseholdClientTests {
    func testMealRecoveryDeskRejectsForeignSourcesProvenanceAndAlteredText() throws {
        let f = RecoveryFixture(), row = try f.desk(), page = try decodeRecovery(SharedRecoveryPage.self, row)
        var evidence = f.scope
        evidence["sources"] = []; evidence["lines"] = []
        evidence["meals"] = page.meals.map { ["occurrenceId": $0.id.uuidString, "revision": 2, "meal":
            ["title": $0.title, "day": $0.day, "kind": "dinner", "portions": 2, "protected": false]] as RecoveryRow }
        let delivery = try decodeRecovery(SharedDeliveryPage.self, evidence)
        var stock = f.scope; stock["lots"] = []; stock["nextCursor"] = NSNull()
        let pantry = try decodeRecovery(SharedPantryPage.self, stock)
        try page.validate(delivery: delivery, pantry: pantry)
        for (field, value): (String, Any) in [("shopId", UUID().uuidString), ("targetDigests", []), ("mealSources", []),
            ("sourceOptions", [["sourceId": UUID().uuidString, "name": "Foreign lot", "kind": "freezer", "quantity": NSNull(), "exclusionTags": []]]),
            ("meals", [f.target.merging(["notes": "changed"]) { $1 }, f.donor])] {
            var bad = row; bad[field] = value
            XCTAssertThrowsError(try decodeRecovery(SharedRecoveryPage.self, bad).validate(delivery: delivery, pantry: pantry), field)
        }
        var absent = f.target; absent.removeValue(forKey: "due")
        XCTAssertThrowsError(try decodeRecovery(SharedRecoveryMeal.self, absent))
        var changed = page.meals[0]; changed.notes = "é"
        let hash = try changed.targetDigest()
        changed.notes = "e\u{301}"
        XCTAssertNotEqual(try changed.targetDigest(), hash)
    }

    func testMealRecoveryPreviewPreservesUnknownsAndRequiresRepeatConsent() throws {
        let f = RecoveryFixture(), page = try decodeRecovery(SharedRecoveryPage.self, f.desk())
        for agrees in [false, true] {
            let intent = try f.intent(page, agrees: agrees), row = try f.preview(page, intent)
            let preview = try decodeRecovery(SharedRecoveryPreview.self, row)
            try preview.validate(page: page, intent: intent)
            if agrees {
                let fields = try intent.commandBody(reviewed: page, preview: preview)
                XCTAssertEqual(fields["previewId"], .string(preview.previewId.uuidString.lowercased()))
            } else { XCTAssertThrowsError(try intent.commandBody(reviewed: page, preview: preview)) }
            for (key, value): (String, Any) in [("shopId", UUID().uuidString), ("repeatRequired", false), ("consentSatisfied", !agrees),
                                                 ("foodConfirmed", true), ("previewDigest", "unreviewed"), ("after", try XCTUnwrap(row["before"]))] {
                var bad = row; bad[key] = value
                XCTAssertThrowsError(try decodeRecovery(SharedRecoveryPreview.self, bad).validate(page: page, intent: intent), key)
            }
        }
        let rows: [RecoveryRow] = page.meals.map { meal in
            let need = meal.needs[0]
            return ["needId": need.id.uuidString, "occurrenceId": meal.id.uuidString, "mealRevision": 2, "ingredientId": need.ingredientId.uuidString,
                "groupIds": [], "protected": false, "required": NSNull(), "covered": NSNull(), "missing": NSNull(), "delivered": NSNull(),
                "pantry": NSNull(), "freezer": NSNull(), "allocations": [], "reservations": [], "issues": ["unknownQuantity", "noMatch"]]
        }
        var coverage = f.scope; coverage["unplannedOccurrenceIds"] = []; coverage["needs"] = rows
        try decodeRecovery(SharedRecoveryCoverage.self, coverage).validate(reviewed: page)
        for (key, value): (String, Any) in [("needId", UUID().uuidString), ("freezer", ["numerator": "0", "denominator": "1"]),
                                            ("ingredientId", UUID().uuidString), ("groupIds", [UUID().uuidString])] {
            var bad = coverage; bad["needs"] = [rows[0].merging([key: value]) { $1 }, rows[1]]
            XCTAssertThrowsError(try decodeRecovery(SharedRecoveryCoverage.self, bad).validate(reviewed: page), key)
        }
    }

    func testMealRecoveryReceiptAndPendingBytesBindReviewedTarget() throws {
        let f = RecoveryFixture(), page = try decodeRecovery(SharedRecoveryPage.self, f.desk())
        let intent = try f.intent(page, agrees: true), preview = try decodeRecovery(SharedRecoveryPreview.self, f.preview(page, intent))
        let envelope = CommandEnvelope(replayWindow: UUID().uuidString, shopId: f.shop, kind: "mealRecovery.apply",
            base: .init(shopRevision: 4, authorityEpoch: 1), body: try intent.commandBody(reviewed: page, preview: preview))
        let pending = try PendingOperation(envelope: envelope, householdID: household, memberID: member, deviceID: "device")
        XCTAssertEqual(try JSONDecoder().decode(CommandEnvelope.self, from: pending.bytes), envelope)
        XCTAssertFalse(pending.targetsShop(nil, includeCreation: true)); XCTAssertFalse(pending.targetsShop(UUID().uuidString))
        XCTAssertTrue(pending.targetsShop(f.shop))
        let receipt: RecoveryRow = ["operationId": UUID().uuidString, "kind": envelope.kind, "shopId": f.shop, "shopRevision": 4,
            "authorityEpoch": 1, "disposition": "recorded", "recoveryRevision": 1, "occurrenceId": intent.occurrenceId.uuidString,
            "revisionId": intent.replacement.revisionId.uuidString]
        try decodeRecovery(ShopperReceipt.self, receipt).validateRecovery(envelope)
        for (key, value): (String, Any) in [("operationId", "invalid"), ("occurrenceId", UUID().uuidString), ("revisionId", UUID().uuidString),
                                            ("recoveryRevision", 9), ("authorityEpoch", 2), ("disposition", "waiting")] {
            let bad = receipt.merging([key: value]) { $1 }
            XCTAssertThrowsError(try decodeRecovery(ShopperReceipt.self, bad).validateRecovery(envelope), key)
        }
    }
}
