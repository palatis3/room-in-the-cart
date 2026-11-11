import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testMealIdeaReservationIdentityDoesNotChangeWireEvidenceOrDraftEquality() throws {
        let first = SharedMealIdeaDraft.Reservation(name: "Lunch", amount: .init(1, 2))
        let sameEvidence = SharedMealIdeaDraft.Reservation(name: "Lunch", amount: .init(1, 2))
        XCTAssertNotEqual(first.id, sameEvidence.id)
        XCTAssertEqual(first, sameEvidence)
        let draft = SharedMealIdeaDraft(title: "Rice", ingredients: [.init(name: "Rice", reservations: [first, sameEvidence], evidence: "Household checked")])
        try draft.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(draft)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let ingredient = try XCTUnwrap((body["ingredients"] as? [[String: Any]])?.first)
        let reservations = try XCTUnwrap(ingredient["reservations"] as? [[String: Any]])
        XCTAssertEqual(reservations.count, 2)
        for reservation in reservations {
            XCTAssertEqual(Set(reservation.keys), Set(["name", "amount"]))
            XCTAssertEqual(reservation["name"] as? String, "Lunch")
            XCTAssertEqual(reservation["amount"] as? [String: Int], ["numerator": 1, "denominator": 2])
        }
        let decoded = try JSONDecoder().decode(SharedMealIdeaDraft.self, from: bytes)
        XCTAssertEqual(decoded, draft, "Server reads must still match drafts for approval and lost-reply reconciliation")
        XCTAssertEqual(try encoder.encode(decoded), bytes)
        XCTAssertNotEqual(decoded.ingredients[0].reservations[0].id, first.id)
        XCTAssertNotEqual(decoded.ingredients[0].reservations[0].id, decoded.ingredients[0].reservations[1].id)
        XCTAssertEqual(draft.normalizedForSave().ingredients[0].reservations.map(\.id), [first.id, sameEvidence.id])
        var edited = decoded
        edited.ingredients[0].reservations[0].name = "Dinner"
        XCTAssertNotEqual(edited, draft)
        edited = decoded; edited.ingredients[0].reservations[0].amount = 1
        XCTAssertNotEqual(edited, draft)
        let legacy = try JSONDecoder().decode(SharedMealIdeaDraft.Reservation.self, from: Data(#"{"name":"Lunch","amount":2}"#.utf8))
        let legacyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
        XCTAssertEqual(Set(legacyBody.keys), Set(["name", "amount"]))
        XCTAssertEqual(legacyBody["amount"] as? Int, 2, "Existing integer amounts retain their wire representation")
    }

    func testUndatedSharedMealHTTPReadProposalAndLaterScheduleKeepNeedIdentity() async throws {
        let shop = UUID(), occurrence = UUID(), group = UUID(), ingredient = UUID(), allocation = UUID()
        let quantity: [String: Any] = ["amount": ["numerator": 2, "denominator": 1], "unit": "count", "originalLiteral": "2 wraps"]
        let planning: [String: Any] = [
            "groups": [["id": group.uuidString, "name": "Lunch", "servings": ["numerator": 2, "denominator": 1], "protected": true]],
            "ingredients": [["id": ingredient.uuidString, "name": "Wraps", "quantity": quantity, "groupIds": [group.uuidString], "exclusions": []]],
            "bindings": [["id": allocation.uuidString, "groupId": group.uuidString, "ingredientId": ingredient.uuidString, "quantity": quantity]]]
        var meal: [String: Any] = ["title": "Wrap lunch", "day": NSNull(), "kind": "lunch", "portions": 2, "protected": true, "planning": planning]
        var proposed = false, moved = false
        func response(_ value: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
            auth: auth, deviceVault: MemoryVault(), transport: transport())
        MockURLProtocol.handler = { request in
            if let result = self.authResponse(request) { return result }
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/devices") { return try response(["deviceId": "device", "deviceToken": "test"]) }
            if path.hasSuffix("/bootstrap") {
                return try response(["household": ["id": self.household, "label": "Home"], "memberId": self.member,
                    "role": "contributor", "shopId": shop.uuidString, "enrolled": true, "queueConsent": false, "capabilities": ["meal_proposals"]])
            }
            if request.httpMethod == "POST" {
                var bytes = request.httpBody ?? Data()
                if bytes.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; bytes.append(buffer, count: count)
                    }
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual((body["occurrenceId"] as? String)?.lowercased(), occurrence.uuidString.lowercased())
                if path.hasSuffix("/changes") {
                    let proposedMeal = try XCTUnwrap(body["meal"] as? [String: Any])
                    XCTAssertTrue(proposedMeal["day"] is NSNull, "An explicit unknown night must survive the actual HTTP body")
                    meal = proposedMeal; proposed = true
                    return try response(["saved": true, "proposalId": try XCTUnwrap(body["proposalId"])])
                }
                XCTAssertTrue(path.hasSuffix("/proposals"))
                XCTAssertEqual(body["day"] as? String, "2026-11-09")
                // Emulate the subsequent shopper-applied move in the next server read.
                meal["day"] = body["day"]; moved = true
                return try response(["saved": true])
            }
            let row: [String: Any] = ["occurrenceId": occurrence.uuidString, "revision": moved ? 3 : 2, "meal": meal]
            var page: [String: Any] = ["shopId": shop.uuidString, "shopRevision": moved ? 3 : 2, "authorityEpoch": 1,
                "grantRevision": 1, "shopper": false, "meals": [row], "proposals": []]
            if path.hasSuffix("/changes") { page["phase"] = "draft" }
            else { XCTAssertTrue(path.hasSuffix("/meal-plan")); page["adults"] = []; page["plannerId"] = self.member }
            return try response(page)
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let page = try await service.sharedMealChanges(shopID: shop)
        let before = try XCTUnwrap(page.meals.first)
        XCTAssertNil(before.meal.day)
        var changed = before.meal; changed.title = "Wrap lunch with guests"
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: before.id, meal: changed, reason: "Reviewed servings")
        try await service.executeSharedMealChange(intent)
        XCTAssertTrue(proposed)
        let plan = try await service.mealPlan(shopID: shop)
        try await service.proposeMealMove(id: UUID(), occurrenceID: before.id, day: "2026-11-09", plan: plan)
        let after = try await service.sharedMealChanges(shopID: shop)
        XCTAssertTrue(moved)
        XCTAssertEqual(after.meals.first?.id, before.id)
        XCTAssertEqual(after.meals.first?.meal.day, "2026-11-09")
        XCTAssertEqual(after.meals.first?.meal.planning, before.meal.planning)
        XCTAssertNil(after.meals.first?.meal.planning?.deadline)
    }

    func testUndatedMealRequiresExplicitNullAndRejectsDeadlineWithoutNight() throws {
        var row: [String: Any] = ["title": "Beans", "day": NSNull(), "kind": "dinner", "portions": 2, "protected": false]
        func decode(_ value: [String: Any]) throws -> SharedMeal {
            try JSONDecoder().decode(SharedMeal.self, from: JSONSerialization.data(withJSONObject: value))
        }
        var meal = try decode(row)
        try meal.validatePlanning()
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meal)) as? [String: Any])
        XCTAssertTrue(encoded["day"] is NSNull)
        XCTAssertThrowsError(try meal.setDeadline(.init(at: "2026-11-09T18:00:00Z", zone: "UTC")))
        row.removeValue(forKey: "day")
        XCTAssertThrowsError(try decode(row))
        row["day"] = NSNull()
        row["planning"] = ["groups": [], "ingredients": [], "deadline": ["at": "2026-11-09T18:00:00Z", "zone": "UTC"]] as [String: Any]
        XCTAssertThrowsError(try decode(row))
        meal.move(to: "2026-11-09")
        try meal.setDeadline(.init(at: "2026-11-09T18:00:00Z", zone: "UTC"))
        meal.move(to: nil)
        XCTAssertNil(meal.day); XCTAssertNil(meal.planning?.deadline)
        try meal.validatePlanning()
    }
}
