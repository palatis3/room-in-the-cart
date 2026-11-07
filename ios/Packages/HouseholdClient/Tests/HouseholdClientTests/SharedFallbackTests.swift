import XCTest
@testable import HouseholdClient

private typealias FallbackJSON = [String: Any]
private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoded(value), options: .fragmentsAllowed) }
private func decode<T: Decodable>(_ row: FallbackJSON, as: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: row))
}

extension HouseholdClientTests {
    func testFallbackFreeCatalogWithdrawAndPaidNamedSeatGateAcrossRelaunch() async throws {
        let identity = try auth(), vault = MemoryVault(), device = UUID(), shop = UUID(), candidate = UUID()
        let id = shop.uuidString.lowercased()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: identity,
                                       deviceVault: vault, transport: transport())
        let recipe = SharedFallbackRecipe(title: "Rice", portions: 1, notes: "", sourceURL: nil, exclusions: [],
            requiredLeadMinutes: nil, elapsedMinutes: 0, ingredients: [.init(id: UUID(), name: "Rice", quantity: nil, exclusions: [])])
        let candidateJSON: FallbackJSON = ["candidateId": candidate.uuidString, "revision": 1, "usual": false, "recipe": try object(recipe)]
        var role = "shopper", hasSeat = false, writes = 0
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let row: FallbackJSON
            switch request.url!.lastPathComponent {
            case "devices": row = ["deviceId": device.uuidString, "deviceToken": "device-token"]
            case "bootstrap":
                row = ["household": ["id": self.household, "label":"Home"], "memberId": self.member, "role":role, "shopId":id,
                       "enrolled":true,"queueConsent":false,"capabilities":["shopper_inbox","request_preview","shopper_commands","accepted_fallbacks"]]
            case "entitlements":
                row = ["householdID": self.household, "status":"active","validUntil":"2099-01-01T00:00:00Z",
                       "seats":[["userID": hasSeat ? self.member : UUID().uuidString, "isAdult":true]]]
            case "accepted-fallbacks" where request.httpMethod == "GET":
                row = ["shopId":id,"shopRevision":3,"authorityEpoch":1,"registryRevision":1,"candidates":[candidateJSON],"nextCursor":NSNull()]
            case "accepted-fallbacks":
                writes += 1
                row = ["shopId":id,"shopRevision":3,"authorityEpoch":1,"registryRevision":2,"candidateId":candidate.uuidString,"revision":2,"accepted":false]
            default: XCTFail("Unexpected route"); return (500,Data())
            }
            return (200,try JSONSerialization.data(withJSONObject: row))
        }
        _ = try await identity.verifyEmailCode(email: "adult@example.test", code: "123456")
        _ = try await service.enroll(householdID: household)
        let library = try await service.acceptedFallbacks(shopID: id)
        let free = try await service.assistanceValidUntil(shopID: id)
        XCTAssertNil(free)
        do {
            _ = try await service.prepareFallback(.accept(candidateId: UUID(), baseRevision: nil, source: .disclosed, recipe: recipe, usual: false),
                                                  reviewed: library, clientKey: UUID())
            XCTFail("Another adult's named seat authorized new disclosure")
        } catch ClientError.service(status: 403, code: "membership_inactive", correlationID: _, retryAfter: _) {}
        let pending = try await service.prepareFallback(.revoke(candidateId: candidate, baseRevision: 1), reviewed: library, clientKey: UUID())
        let restored = try JSONDecoder().decode(PendingFallbackWrite.self, from: encoded(pending))
        try restored.validate()
        let fresh = HouseholdService(configuration: try .init(baseURL: URL(string:"https://service.test")!),auth:identity,deviceVault:vault,transport:transport())
        _ = try await fresh.enroll(householdID: household)
        XCTAssertTrue(library.belongsToSameDevice(as: restored))
        let first = try await fresh.executeFallback(restored)
        let again = try await fresh.executeFallback(restored)
        XCTAssertEqual(first,again)
        var stored = try XCTUnwrap(object(pending) as? FallbackJSON)
        stored["clientKey"] = UUID().uuidString
        XCTAssertThrowsError(try decode(stored, as: PendingFallbackWrite.self).validate())
        stored = try XCTUnwrap(object(pending) as? FallbackJSON); stored["deviceID"] = UUID().uuidString
        let other = try decode(stored, as: PendingFallbackWrite.self)
        XCTAssertFalse(library.belongsToSameDevice(as: other))
        do { _ = try await fresh.executeFallback(other); XCTFail("Wrong device replay") } catch ClientError.accessEnded {}
        hasSeat = true
        let until = try await fresh.assistanceValidUntil(shopID: id)
        XCTAssertNotNil(until)
        role = "contributor"
        do { _ = try await fresh.executeFallback(restored); XCTFail("Withdrawn shopper kept write access") } catch ClientError.accessEnded {}
        XCTAssertEqual(writes, 2)
    }

    func testFallbackOptionsBindReviewedTargetSourceQuantityAndWholePackTerms() throws {
        let occurrence = UUID(), source = UUID(), candidate = UUID(), ingredient = UUID(), shop = UUID()
        let asOf = "2026-11-07T09:00:00Z", due = "2026-11-07T10:00:00Z"
        func quantity(_ n: Int) -> SharedMealQuantity { .init(amount: .init(numerator: n), unit: "count", originalLiteral: String(n)) }
        func fraction(_ n: Int) -> FallbackJSON { ["numerator": String(n),"denominator":"1"] }
        let need = SharedRecoveryNeed(id: UUID(), foodId: nil, matchedSourceIds: [source], ingredientId: UUID(), groupId: nil, groupIds: nil,
                                      name: "Wraps", notes: "", quantity: quantity(6), priority: "required", due: due, exclusions: [])
        let meal = SharedRecoveryMeal(occurrenceId: occurrence, revisionId: UUID(), sourceMealRevision: 2, portions: 1, title: "Supper", notes: "", day: "2026-11-07",
                                      sourceURL: nil, zone: "UTC", due: due, exclusions: [], template: nil, groups: [], needs: [need],
                                      remainingElapsedMinutes: 10, requiredLeadMinutes: nil, advanceStepsCompleted: false)
        let base = SharedRecoveryBase(shopRevision: 3, authorityEpoch: 1, recoveryRevision: 0, supplyRevision: 1, pantryRevision: 0, contextRevision: 0)
        let digest = try meal.targetDigest()
        let sourceRow: FallbackJSON = ["sourceId":source.uuidString,"kind":"delivery","name":"Warm wraps","quantity":try object(quantity(3)),"exclusionTags":[]]
        let page = try decode(["shopId":shop.uuidString,"placedRevision":2,"asOf":asOf,"base":try object(base),"meals":try object([meal]),
            "targetDigests":[["occurrenceId":occurrence.uuidString,"digest":digest]],"sourceOptions":[sourceRow],"mealSources":[],"unplannedOccurrenceIds":[],
            "commitmentInventoryComplete":true], as: SharedRecoveryPage.self)
        let recipe = SharedFallbackRecipe(title:"Wrap supper",portions:1,notes:"Warm",sourceURL:nil,exclusions:["no peanuts"],requiredLeadMinutes:nil,
            elapsedMinutes:10,ingredients:[.init(id:ingredient,name:"Wraps",quantity:quantity(6),exclusions:[])])
        let library = try decode(["shopId":shop.uuidString,"shopRevision":3,"authorityEpoch":1,"registryRevision":1,"nextCursor":NSNull(),
                                  "candidates":[["candidateId":candidate.uuidString,"revision":1,"usual":true,"recipe":try object(recipe)] as FallbackJSON]],as: SharedFallbackLibrary.self)
        let offer = SharedFallbackOffer(label:"Wrap pouch",exclusionTags:[],usablePerPack:quantity(2),priceMinor:200,availablePacks:2)
        let review = SharedFallbackReview(candidateId:candidate,revision:1,remainingElapsedMinutes:nil,advanceStepsCompleted:false,
                                           ingredients:[.init(ingredientId:ingredient,sourceIds:[source],offer:offer)])
        let trip = SharedFallbackTrip(minutes:8,budgetMinor:450,chargesMinor:50,currency:"USD")
        var replacement = meal
        replacement.title = recipe.title; replacement.notes = recipe.notes; replacement.revisionId = UUID()
        replacement.needs[0].id = UUID(); replacement.needs[0].ingredientId = ingredient
        replacement.exclusions = recipe.exclusions; replacement.needs[0].exclusions = recipe.exclusions
        let intent = SharedRecoveryIntent(occurrenceId: occurrence,targetDigest:digest,replacement:replacement,reviewedAt:asOf,repeatOfOccurrenceId:nil,
                                          agreesToRepeat:false,proposesExtraTrip:true,agreesToExtraTrip:false,acceptsUnresolved:false,
                                          fallback:.init(review: review,trip: trip))
        let n = replacement.needs[0].id.uuidString
        let demand: FallbackJSON = ["needId":n,"due":due,"deadlineStatus":"notPastDue","allocated":fraction(3),"shortfall":fraction(3),"unit":"count",
                                    "issues":[],"sourceIssues":[],"reservations":[]]
        let allocation: FallbackJSON = ["needId":n,"sourceId":source.uuidString,"amount":fraction(3),"unit":"count"]
        let buy: FallbackJSON = ["ingredientId":ingredient.uuidString,"label":"Wrap pouch","packs":2,"subtotalMinor":400]
        let option: FallbackJSON = ["candidateId":candidate.uuidString,"revision":1,"title":recipe.title,"kind":"topUp","minutes":18,"packCount":2,
                                   "merchandiseMinor":400,"extraCashMinor":450,"currency":"USD","buys":[buy],"repeatRequired":false,"intent":try object(intent),
                                   "after":["demands":[demand],"allocations":[allocation]]]
        @discardableResult func validate(_ option: FallbackJSON, target: SharedRecoveryMeal = meal) throws -> SharedFallbackOptions {
            let result = try decode(["shopId":shop.uuidString,"base":object(base),"asOf":asOf,"target":object(target),"options":[option],"conditional":[],
                                     "nextReviewIndex":NSNull(),"registryRevision":1,"usualMinutes":18],as: SharedFallbackOptions.self)
            try result.validate(page:page,library:library,occurrence:occurrence,reviews:[review],trip:trip)
            return result
        }
        try validate(option)
        var previousVersion = option
        previousVersion["repeatRequired"] = true
        let bound = try XCTUnwrap(validate(previousVersion).options.first?.intent)
        XCTAssertEqual(bound.withFallbackAgreements(repeatMeal: true, extraTrip: false, unresolved: false).witnessedRepeatRequired, true)
        XCTAssertNil((try object(bound) as? FallbackJSON)?["witnessedRepeatRequired"])
        for (field,value) in [("candidateId",UUID().uuidString),("revision",2),("kind","onHand"),("currency","EUR"),("minutes",10),
                              ("extraCashMinor",400),("merchandiseMinor",200),("packCount",1),("intent",try object(intent.withFallbackAgreements(repeatMeal:true,extraTrip:true,unresolved:true)))] as [(String,Any)] {
            var bad = option; bad[field] = value; XCTAssertThrowsError(try validate(bad),field)
        }
        var wrong = meal; wrong.notes = "Unreviewed"; XCTAssertThrowsError(try validate(option,target:wrong))
        var bad = option, changedBuy = buy; changedBuy["packs"] = 1; changedBuy["subtotalMinor"] = 200
        bad["buys"] = [changedBuy]; bad["packCount"] = 1; bad["extraCashMinor"] = 250; bad["merchandiseMinor"] = 200
        XCTAssertThrowsError(try validate(bad))
        var wrongSource = allocation; wrongSource["sourceId"] = UUID().uuidString
        bad = option; bad["after"] = ["demands":[demand],"allocations":[wrongSource]]
        XCTAssertThrowsError(try validate(bad))
        let agreed = intent.withFallbackAgreements(repeatMeal:true,extraTrip:true,unresolved:true)
        XCTAssertEqual(agreed.fallback,intent.fallback); XCTAssertEqual(agreed.replacement,intent.replacement)
        XCTAssertEqual(try JSONDecoder().decode(SharedRecoveryIntent.self,from:encoded(agreed)),agreed)
    }
}
