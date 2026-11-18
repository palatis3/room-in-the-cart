import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testHouseholdTonightOmitsPrivateAndShopContextWhileSavingExactReviewedLots() async throws {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
            auth: auth, deviceVault: MemoryVault(), transport: transport())
        let device = UUID(), lot = UUID(), ingredient = UUID()
        var writes = [Data](), reads = 0
        let lock = MockURLProtocol.installHandlerWithStateLock { request in
            if let auth = self.authResponse(request) { return auth }
            func reply(_ body: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: body)) }
            let path = request.url!.lastPathComponent
            if path == "devices" { return try reply(["deviceId": device.uuidString, "deviceToken": "tested-device"]) }
            if path == "bootstrap" {
                return try reply(["household": ["id": self.household, "label": "Home"], "memberId": self.member,
                    "role": "organizer", "enrolled": true, "queueConsent": false,
                    "shopId": request.value(forHTTPHeaderField: "X-Shop-ID") as Any, "capabilities": ["household_pantry"]])
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Shop-ID"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-View-Grant-ID"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "tested-device")
            switch path {
            case "tonight":
                reads += 1
                return try reply(["v": 1, "householdId": self.household, "grantEpoch": 4, "pantryRevision": 5,
                    "asOf": "2026-11-18T12:00:00Z", "canReviewRecipes": true, "recipes": [], "excludedCount": 0])
            case "replay-windows": return try reply(["id": UUID().uuidString, "expiresAt": "2099-01-01T00:00:00Z"])
            case "recipes":
                let bytes = mockRequestBody(request)
                writes.append(bytes)
                if writes.count == 1 { throw URLError(.networkConnectionLost) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let recipe = try XCTUnwrap(body["recipe"] as? [String: Any])
                let row = try XCTUnwrap((recipe["ingredients"] as? [[String: Any]])?.first)
                XCTAssertEqual(row["reviewedLotIds"] as? [String], [lot.uuidString.lowercased()])
                XCTAssertEqual(Set(row.keys), ["id", "name", "quantity", "reviewedLotIds"])
                XCTAssertTrue(row["quantity"] is NSNull)
                XCTAssertEqual(body["grantEpoch"] as? Int, 4)
                XCTAssertTrue(body["baseRevision"] is NSNull)
                return try reply(["recipeId": try XCTUnwrap(body["recipeId"] as? String), "recipeRevision": 1])
            default: XCTFail("Unexpected route: " + path); return (404, Data())
            }
        }
        _ = try await auth.verifyEmailCode(email: "x", code: "123456")
        let bootstrap = try await service.enroll(householdID: household)
        let actor = try await service.householdPantrySession(for: bootstrap)
        _ = try await service.selectShop(UUID())
        let page = try await service.householdTonight(for: actor)
        XCTAssertTrue(page.recipes.isEmpty)
        let meal = SharedMeal(title: "Reviewed stew", day: nil, kind: "dinner", portions: 2, protected: false,
            planning: .init(groups: [], ingredients: [.init(id: ingredient, name: "Beans", quantity: nil, groupIds: [], exclusions: [])]))
        let saved = try await service.prepareTonightRecipe(meal, evidence: nil, reviewedLots: [ingredient: [lot]], page: page, session: actor)
        do { try await service.saveTonightRecipe(saved); XCTFail("Lost result must be retryable") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        try await service.saveTonightRecipe(saved)
        let result = lock.withLock { (reads, writes) }
        XCTAssertEqual(result.0, 1)
        XCTAssertEqual(result.1.count, 2)
        XCTAssertEqual(result.1.first, result.1.last)
    }

    func testHouseholdTonightRejectsUnsafeCoverageAndBuildsChoiceOnlyForReviewedEligibleRecipe() throws {
        let session = HouseholdPantrySession(householdID: UUID(), memberID: UUID(), deviceID: UUID())
        let recipeID = UUID(), occurrence = UUID()
        let row: [String: Any] = ["id": UUID().uuidString, "name": "Beans", "status": "unknown", "useSoon": false]
        var recipe: [String: Any] = ["recipeId": recipeID.uuidString, "recipeRevision": 2, "title": "Beans",
            "portions": 2, "minutes": 15, "ingredients": [row], "status": "eligible", "reviewToken": String(repeating: "b", count: 64),
            "checkoutEstimate": "incomplete"]
        func read(_ r: [String: Any]) throws -> HouseholdTonightPage {
            let p: HouseholdTonightPage = try TrackingWriteFixture.decode(["v": 1, "householdId": session.householdID.uuidString,
                "grantEpoch": 3, "pantryRevision": 12, "canReviewRecipes": false, "asOf": "2026-11-18T12:00:00Z", "excludedCount": 1, "recipes": [r]])
            try p.validate(session: session)
            return p
        }
        let p = try read(recipe)
        let r = try XCTUnwrap(p.recipes.first)
        let body = try p.choiceBody(for: r, day: "2026-11-18", occurrence: occurrence)
        XCTAssertEqual(Set(body.keys), ["v","recipeId","recipeRevision","grantEpoch","reviewToken","day","occurrenceId"])
        XCTAssertEqual(body["occurrenceId"], .string(occurrence.uuidString.lowercased()))
        XCTAssertThrowsError(try p.choiceBody(for: r, day: "2026-02-31", occurrence: occurrence))
        recipe["checkoutEstimate"] = "noPurchaseNeeded"
        XCTAssertThrowsError(try read(recipe))
        recipe["checkoutEstimate"] = "incomplete"
        recipe["status"] = "unresolved"
        XCTAssertThrowsError(try read(recipe))
        recipe.removeValue(forKey: "reviewToken")
        let unresolved = try read(recipe)
        XCTAssertThrowsError(try unresolved.choiceBody(for: unresolved.recipes[0], day: nil, occurrence: occurrence))
    }
}
