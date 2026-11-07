import XCTest
import CoreDomain
import HouseholdClient
@testable import RoomInTheCart

private actor MealChangeFixture: SharedMealChangesServing {
    let scope: SharedMealChangeScope
    var value: SharedMealChangePage
    var loseResponse = false
    var deny = false
    var blockRetryAuthorization = false
    var sent: [SharedMealChangeIntent] = []
    var onRead: (@Sendable () async -> Void)?
    init(scope: SharedMealChangeScope, page: SharedMealChangePage) { self.scope = scope; value = page }
    func setLost(_ flag: Bool) { loseResponse = flag }
    func setRetryBlocked(_ flag: Bool) { blockRetryAuthorization = flag }
    func setDenied(_ flag: Bool) { deny = flag }
    func setRead(_ callback: (@Sendable () async -> Void)?) { onRead = callback }
    func replace(_ page: SharedMealChangePage) { value = page }
    func sends() -> [SharedMealChangeIntent] { sent }
    func sharedMealChanges(shopID: UUID) async throws -> SharedMealChangePage {
        if let onRead { await onRead() }
        if deny { throw ClientError.service(status: 403, code: "membership_inactive", correlationID: nil, retryAfter: nil) }
        return value
    }
    func prepareSharedMealChange(page: SharedMealChangePage, occurrenceID: UUID, meal: SharedMeal, reason: String) async throws -> SharedMealChangeIntent {
        try await authorize()
        return try SharedMealChangeIntent(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, deviceID: "enrolled-device", shopID: scope.shopID,
            request: .init(occurrenceId: occurrenceID, baseMealRevision: 2, shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch, grantRevision: page.grantRevision, meal: meal, reason: reason))
    }
    private func authorize() async throws { _ = try await sharedMealChanges(shopID: scope.shopID) }
    func authorizeSharedMealChange(_ intent: SharedMealChangeIntent) async throws { try await authorize(); if blockRetryAuthorization { throw ClientError.cancelled } }
    func executeSharedMealChange(_ intent: SharedMealChangeIntent) async throws {
        try await authorize(); sent.append(intent)
        if loseResponse { throw URLError(.networkConnectionLost) }
    }
    func dismissSharedMealChange(_ proposal: SharedMealChangePage.Proposal, page: SharedMealChangePage) async throws { try await authorize() }
}
@MainActor final class SharedMealChangeTests: XCTestCase {
    private func scope() -> SharedMealChangeScope { .init(subject: "adult-native-subject", householdID: UUID().uuidString, memberID: UUID().uuidString, shopID: UUID(), authorityStamp: "contributor/meal_proposals") }
    private func page(_ scope: SharedMealChangeScope, shopper: Bool = false, revision: Int = 2, proposals: [Any] = []) throws -> SharedMealChangePage {
        let meal: [String: Any] = ["title":"Soup","day":"2026-11-05","kind":"dinner","portions":4,"protected":false]
        return try JSONDecoder().decode(SharedMealChangePage.self, from: JSONSerialization.data(withJSONObject: ["shopId":scope.shopID.uuidString,"shopRevision":revision,"authorityEpoch":1,"grantRevision":1,"phase":"draft","shopper":shopper,
            "meals":[["occurrenceId":"11111111-1111-4111-8111-111111111111","revision":2,"meal":meal]],"proposals":proposals]))
    }
    private func storeURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("meal-change-tests-" + UUID().uuidString).appendingPathComponent("pending.json") }
    func testOldMealEncodingRemainsCompatibleAndUnknownQuantityIsExplicitNull() throws {
        let meal = SharedMeal(title: "Soup", day: "2026-11-05", kind: "dinner", portions: 4, protected: false)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meal)) as? [String:Any])
        XCTAssertNil(raw["planning"])
        let ingredient = SharedMealPlanning.Ingredient(name: "Beans", quantity: nil, groupIds: [], exclusions: [])
        let ingredientRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ingredient)) as? [String:Any])
        XCTAssertTrue(ingredientRaw["quantity"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(SharedMeal.self, from: JSONEncoder().encode(meal)), meal)
    }
    func testProtectedRetrySurvivesRestartAndScopedPurgeRejectsLateWrites() async throws {
        let scope = scope(), page = try page(scope), url = storeURL(), store = HistoryPendingStore(url: url), epoch = await store.epoch()
        let service = MealChangeFixture(scope: scope, page: page)
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: page.meals[0].id, meal: page.meals[0].meal, reason: "Reviewed")
        try await store.stageMealChange(intent, expectedEpoch: epoch)
        let restored = try await HistoryPendingStore(url: url).read()
        XCTAssertEqual(restored.sharedMealChanges, [intent]); XCTAssertEqual(restored.sharedMealChanges?.first?.bytes, intent.bytes)
        try await store.purge(householdID: scope.householdID, subject: scope.subject)
        do { try await store.stageMealChange(intent, expectedEpoch: epoch); XCTFail("Pre-purge async write must fail") } catch ClientError.cancelled {}
        let cleared = try await store.read(); XCTAssertEqual(cleared.sharedMealChanges, [])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testLostResponseRestartsWithSameExactBytesAndNeverReprepares() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page), url = storeURL()
        await service.setLost(true)
        let first = SharedMealChangeModel(scope: scope, service: service, store: .init(url: url), runtime: { scope })
        await first.load(); var meal = page.meals[0].meal; meal.portions = 6
        await first.prepare(occurrenceID: page.meals[0].id, meal: meal, reason: "Guests")
        await first.sendReviewed(); let exact = try XCTUnwrap(first.pending)
        first.invalidate(); await service.setLost(false)
        let restarted = SharedMealChangeModel(scope: scope, service: service, store: .init(url: url), runtime: { scope })
        await restarted.load(); XCTAssertEqual(restarted.pending, exact)
        await restarted.retry(); XCTAssertNil(restarted.pending)
        let sends = await service.sends(); XCTAssertEqual(sends.count, 2); XCTAssertEqual(sends[0].bytes, sends[1].bytes); XCTAssertEqual(sends[0].id, sends[1].id)
    }
    func testChangedNativeIdentityOrRoleCannotPublishLateReadOrSendReview() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page)
        var runtime: SharedMealChangeScope? = scope
        let model = SharedMealChangeModel(scope: scope, service: service, store: .init(url: storeURL()), runtime: { runtime })
        await service.setRead { await MainActor.run { runtime = nil; model.invalidate() } }
        await model.load(); XCTAssertNil(model.page); XCTAssertNil(model.pending)
        await service.setRead(nil); runtime = scope; await model.load()
        var meal = page.meals[0].meal; meal.portions += 1
        await model.prepare(occurrenceID: page.meals[0].id, meal: meal, reason: "Guest")
        XCTAssertNotNil(model.review)
        runtime = .init(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, shopID: scope.shopID, authorityStamp: "contributor/no-grant")
        await model.sendReviewed(); let sends = await service.sends(); XCTAssertTrue(sends.isEmpty)
    }
    func testPaidLapseHidesPrivatePendingPayloadAndProposalProjection() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page), store = HistoryPendingStore(url: storeURL())
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: page.meals[0].id, meal: page.meals[0].meal, reason: "Private guests")
        try await store.stageMealChange(intent, expectedEpoch: await store.epoch()); await service.setDenied(true)
        let model = SharedMealChangeModel(scope: scope, service: service, store: store, runtime: { scope })
        await model.load(); XCTAssertTrue(model.hasPending); XCTAssertNil(model.pending); XCTAssertNil(model.page)
        let stored = try await store.read(); XCTAssertEqual(stored.sharedMealChanges, [intent])
    }
    func testExplicitLocalRetryClearDoesNotClaimUndoOrSendAnything() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page), store = HistoryPendingStore(url: storeURL())
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: page.meals[0].id, meal: page.meals[0].meal, reason: "Uncertain send")
        try await store.stageMealChange(intent, expectedEpoch: await store.epoch())
        let model = SharedMealChangeModel(scope: scope, service: service, store: store, runtime: { scope })
        await model.load(); await model.clearPendingAfterStatusReview()
        XCTAssertNil(model.pending); XCTAssertTrue(model.notice?.contains("does not withdraw or undo") == true)
        let sends = await service.sends(); XCTAssertTrue(sends.isEmpty)
    }
    func testStoredBytesCannotBeAlteredWithoutMatchingReviewedPayload() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page)
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: page.meals[0].id, meal: page.meals[0].meal, reason: "Exact")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String:Any])
        raw["bytes"] = Data("{}".utf8).base64EncodedString()
        let tampered = try JSONDecoder().decode(SharedMealChangeIntent.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try tampered.validate())
    }
    func testNativeSeedUsesExactContributionIDsAndDoesNotInferGroupBindings() throws {
        var ledger = ShoppingLedger()
        let template = MealTemplate(title: "Soup", servings: try Rational(4), ingredients: [.init(name: "Beans", quantity: .init(amount: try Rational(400), unit: .gram, originalLiteral: "400 g"))], exclusions: ["peanuts"], leadTimeMinutes: 120, completedSteps: ["Beans soaked"])
        let id = try ledger.chooseMeal(template), occurrence = try XCTUnwrap(ledger.mealOccurrences.first(where: { $0.id == id }))
        let seed = try SharedMealChangeSeed(reviewed: occurrence, contributions: ledger.contributions)
        XCTAssertEqual(seed.localOccurrenceID, id); XCTAssertEqual(seed.planning.sourceOccurrenceId, id)
        XCTAssertEqual(seed.planning.ingredients.map(\.id), occurrence.ingredientContributionIDs)
        XCTAssertEqual(seed.planning.exclusions, ["peanuts"])
        XCTAssertEqual(seed.planning.leadTimeMinutes, 120)
        XCTAssertEqual(seed.planning.completedSteps, ["Beans soaked"])
        XCTAssertTrue(seed.planning.ingredients.allSatisfy { $0.groupIds.isEmpty })
        XCTAssertThrowsError(try SharedMealChangeSeed(reviewed: occurrence, contributions: []))
    }
    func testGuestSeedUsesResultingBindingsAndNeverMutatesReviewedPlanningState() throws {
        let now = Date()
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let dinner = ServingGroup(name: "Dinner", servings: try Rational(3)), lunch = ServingGroup(name: "Lunch", servings: .one, isProtected: true)
        let occurrence = try ledger.chooseMeal(.init(title: "Wraps", servings: try Rational(4), ingredients: [.init(name: "Wraps", quantity: .init(amount: try Rational(8), unit: .count, originalLiteral: "8 wraps"))], servingGroups: [dinner,lunch]), at: now)
        let source = try XCTUnwrap(ledger.mealOccurrences.first?.ingredientContributionIDs.first)
        let access = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "Adult", shopID: ledger.id, assignedShopperID: "Adult", canPlan: true, canReadBudget: false, hasPaidTools: true, roleRevision: 1, verifiedAt: now.addingTimeInterval(-1), validUntil: now.addingTimeInterval(60))
        try state.setPortionBindings([
            .init(occurrenceID: occurrence, contributionID: source, groupID: dinner.id, quantity: .init(amount: try Rational(6), unit: .count, originalLiteral: "6 dinner wraps"), servings: try Rational(3)),
            .init(occurrenceID: occurrence, contributionID: source, groupID: lunch.id, quantity: .init(amount: try Rational(2), unit: .count, originalLiteral: "2 lunch wraps"), servings: .one)
        ], for: occurrence, ledger: ledger, access: access, at: now)
        let before = state
        let preview = try DinnerPlanningEngine.previewGuests(occurrenceID: occurrence, servingsByGroup: [dinner.id: try Rational(5)], ledger: ledger, state: state, access: access, phase: .draft, at: now)
        let seed = try SharedMealChangeSeed(preview: preview, occurrenceID: occurrence, state: state)
        XCTAssertEqual(seed.planning.bindings?.first(where: { $0.groupId == dinner.id })?.quantity.amount, .init(numerator: 10))
        XCTAssertEqual(seed.planning.bindings?.first(where: { $0.groupId == lunch.id })?.quantity.amount, .init(numerator: 2))
        XCTAssertEqual(seed.planning.ingredients.first?.quantity?.amount, .init(numerator: 12))
        XCTAssertEqual(state, before); XCTAssertEqual(ledger.contributions.first?.quantity?.amount, try Rational(8))
        XCTAssertThrowsError(try preview.reviewedPortionBindings(from: DinnerPlanningState()))
        let fractional = try DinnerPlanningEngine.previewGuests(occurrenceID: occurrence, servingsByGroup: [dinner.id: try Rational(7,2)], ledger: ledger, state: state, access: access, phase: .draft, at: now)
        XCTAssertThrowsError(try SharedMealChangeSeed(preview: fractional, occurrenceID: occurrence, state: state), "Never round fractional total portions into an integer shared meal")
    }
    func testSameActorReenrollmentStillInvalidatesReviewedProposal() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page)
        var runtime: SharedMealChangeScope? = scope
        let model = SharedMealChangeModel(scope: scope, service: service, store: .init(url: storeURL()), runtime: { runtime })
        await model.load(); var meal = page.meals[0].meal; meal.portions += 1
        await model.prepare(occurrenceID: page.meals[0].id, meal: meal, reason: "Same actor different enrollment")
        runtime = .init(subject: scope.subject, householdID: scope.householdID, memberID: scope.memberID, shopID: scope.shopID, authorityStamp: scope.authorityStamp, generation: scope.generation, enrollmentRevision: UUID())
        await model.sendReviewed(); let sends = await service.sends(); XCTAssertTrue(sends.isEmpty)
    }

    func testAssignedShopperSeedRequiresExactFreshSourceAndNeverSendsPlannerProposal() async throws {
        let scope = scope(), page = try page(scope, shopper: true), service = MealChangeFixture(scope: scope, page: page)
        let model = SharedMealChangeModel(scope: scope, service: service, store: .init(url: storeURL()), runtime: { scope })
        await model.load(); var meal = page.meals[0].meal; meal.portions += 2
        let edit = await model.reviewedShopperSeed(occurrenceID: page.meals[0].id, meal: meal)
        XCTAssertEqual(edit?.meal, meal); XCTAssertEqual(edit?.baseMealRevision, 2); XCTAssertNil(edit?.changeProposalID)
        let sends = await service.sends(); XCTAssertTrue(sends.isEmpty)
        await service.replace(try self.page(scope, shopper: true, revision: 3))
        let stale = await model.reviewedShopperSeed(occurrenceID: page.meals[0].id, meal: meal)
        XCTAssertNil(stale)
        var differentDay = meal; differentDay.day = "2026-11-06"
        let calendarEdit = await model.reviewedShopperSeed(occurrenceID: page.meals[0].id, meal: differentDay)
        XCTAssertNil(calendarEdit)
    }

    func testReenrolledActorCanExplicitlyClearHiddenOldDeviceRetryWithoutSendingOrExposingIt() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page), store = HistoryPendingStore(url: storeURL())
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: page.meals[0].id, meal: page.meals[0].meal, reason: "Original private draft")
        try await store.stageMealChange(intent, expectedEpoch: await store.epoch())
        await service.setRetryBlocked(true)
        let model = SharedMealChangeModel(scope: scope, service: service, store: store, runtime: { scope })
        await model.load(); XCTAssertTrue(model.hasPending); XCTAssertNil(model.pending)
        await model.clearPendingAfterStatusReview(); XCTAssertFalse(model.hasPending); XCTAssertNil(model.pending)
        let sends = await service.sends(); XCTAssertTrue(sends.isEmpty)
        let persisted = try await store.read(); XCTAssertEqual(persisted.sharedMealChanges, [])
    }

    func testFormerPlannerNowShopperCanClearOwnHiddenRetryButCannotTransmitIt() async throws {
        let initial = scope()
        let scope = SharedMealChangeScope(subject: initial.subject, householdID: initial.householdID, memberID: initial.memberID, shopID: initial.shopID, authorityStamp: "shopper/shopper_commands")
        let page = try page(scope, shopper: true), service = MealChangeFixture(scope: scope, page: page), store = HistoryPendingStore(url: storeURL())
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: page.meals[0].id, meal: page.meals[0].meal, reason: "Earlier planning role")
        try await store.stageMealChange(intent, expectedEpoch: await store.epoch()); await service.setRetryBlocked(true)
        let model = SharedMealChangeModel(scope: scope, service: service, store: store, runtime: { scope })
        await model.load(); XCTAssertNil(model.pending); XCTAssertTrue(model.hasPending)
        await model.retry(); let before = await service.sends(); XCTAssertTrue(before.isEmpty)
        await model.clearPendingAfterStatusReview(); XCTAssertFalse(model.hasPending)
        XCTAssertTrue(model.notice?.contains("does not withdraw or undo") == true)
    }
    func testScopeChangeDuringStatusReadCannotClearAnotherRuntimePending() async throws {
        let scope = scope(), page = try page(scope), service = MealChangeFixture(scope: scope, page: page), store = HistoryPendingStore(url: storeURL())
        let intent = try await service.prepareSharedMealChange(page: page, occurrenceID: page.meals[0].id, meal: page.meals[0].meal, reason: "Bound to original actor")
        try await store.stageMealChange(intent, expectedEpoch: await store.epoch())
        var runtime: SharedMealChangeScope? = scope
        let model = SharedMealChangeModel(scope: scope, service: service, store: store, runtime: { runtime })
        await model.load()
        await service.setRead { await MainActor.run { runtime = nil; model.invalidate() } }
        await model.clearPendingAfterStatusReview()
        let retained = try await store.read(); XCTAssertEqual(retained.sharedMealChanges, [intent]); XCTAssertNil(model.pending)
    }

}
