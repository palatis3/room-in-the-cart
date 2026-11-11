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
    private func page(_ scope: SharedMealChangeScope, shopper: Bool = false, revision: Int = 2, proposals: [Any] = [], meal: SharedMeal? = nil) throws -> SharedMealChangePage {
        let mealJSON: Any = try meal.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
            ?? ["title":"Soup","day":"2026-11-05","kind":"dinner","portions":4,"protected":false]
        return try JSONDecoder().decode(SharedMealChangePage.self, from: JSONSerialization.data(withJSONObject: ["shopId":scope.shopID.uuidString,"shopRevision":revision,"authorityEpoch":1,"grantRevision":1,"phase":"draft","shopper":shopper,
            "meals":[["occurrenceId":"11111111-1111-4111-8111-111111111111","revision":2,"meal":mealJSON]],"proposals":proposals]))
    }
    private func storeURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("meal-change-tests-" + UUID().uuidString).appendingPathComponent("pending.json") }
    private func mealWithBoundSide() -> SharedMeal {
        let dinner = SharedMealPlanning.Group(name: "Dinner", servings: .init(numerator: 6), protected: false)
        let lunch = SharedMealPlanning.Group(name: "Lunch", servings: .init(numerator: 2), protected: true)
        func quantity(_ n: Int, _ literal: String) -> SharedMealQuantity {
            .init(amount: .init(numerator: n), unit: "count", originalLiteral: literal)
        }
        let wraps = SharedMealPlanning.Ingredient(name: "Wraps", quantity: quantity(8, "Eight original wraps"), groupIds: [dinner.id, lunch.id], exclusions: ["No sesame"])
        let side = SharedMealPlanning.Ingredient(name: "Tomato side", quantity: quantity(1, "One tomato"), groupIds: [dinner.id], exclusions: [])
        return SharedMeal(title: "Wrap dinner", day: "2026-11-05", kind: "dinner", portions: 8, protected: false,
            planning: .init(groups: [dinner, lunch], ingredients: [wraps, side], sourceOccurrenceId: UUID(), bindings: [
                .init(id: UUID(), groupId: dinner.id, ingredientId: wraps.id, quantity: quantity(6, "Six dinner wraps")),
                .init(id: UUID(), groupId: lunch.id, ingredientId: wraps.id, quantity: quantity(2, "Two protected lunch wraps")),
                .init(id: UUID(), groupId: dinner.id, ingredientId: side.id, quantity: quantity(1, "One dinner tomato"))]))
    }
    func testRemovingBoundSideAllowsReviewAndCancelPreservesProtectedLunchWithoutWrites() async throws {
        let scope = scope(), original = mealWithBoundSide()
        let planning = try XCTUnwrap(original.planning), side = planning.ingredients[1]
        var orphaned = original
        orphaned.planning?.ingredients.removeAll { $0.id == side.id }
        XCTAssertThrowsError(try SharedMealGroupAmounts.validate(orphaned))

        var edited = original
        edited.planning?.removeProposedIngredient(side.id)
        XCTAssertNoThrow(try SharedMealGroupAmounts.validate(edited))
        XCTAssertEqual(edited.planning?.ingredients, [planning.ingredients[0]])
        XCTAssertEqual(edited.planning?.bindings, Array((planning.bindings ?? []).prefix(2)))
        XCTAssertEqual(edited.planning?.groups, planning.groups)
        XCTAssertEqual(edited.planning?.sourceOccurrenceId, planning.sourceOccurrenceId)
        let current = try page(scope, meal: original), service = MealChangeFixture(scope: scope, page: current)
        let store = HistoryPendingStore(url: storeURL())
        let model = SharedMealChangeModel(scope: scope, service: service, store: store, runtime: { scope })
        await model.load()
        await model.prepare(occurrenceID: current.meals[0].id, meal: edited, reason: "Remove only the tomato side")
        XCTAssertEqual(try XCTUnwrap(model.review).request.meal, edited)
        model.cancelReview()
        XCTAssertNil(model.review)
        XCTAssertEqual(model.page?.meals[0].meal, original)
        let saved = try await store.read(), sent = await service.sends()
        XCTAssertTrue((saved.sharedMealChanges ?? []).isEmpty)
        XCTAssertTrue(sent.isEmpty)

        let shopperPage = try page(scope, shopper: true, meal: original)
        await service.replace(shopperPage); await model.load()
        let shopperEdit = await model.reviewedShopperSeed(occurrenceID: shopperPage.meals[0].id, meal: edited)
        XCTAssertEqual(try XCTUnwrap(shopperEdit).meal, edited)
        XCTAssertEqual(model.page?.meals[0].meal, original)
    }
    func testUnassigningOneGroupPreservesOtherAllocationsAndRequiresExplicitRebalance() throws {
        let original = mealWithBoundSide(), planning = try XCTUnwrap(original.planning)
        let wraps = planning.ingredients[0], dinner = planning.groups[0]
        var edited = original
        edited.planning?.setProposedGroup(dinner.id, for: wraps.id, included: false)
        XCTAssertEqual(edited.planning?.ingredients[0].groupIds, [planning.groups[1].id])
        XCTAssertEqual(edited.planning?.ingredients[0].quantity, wraps.quantity)
        XCTAssertEqual(edited.planning?.ingredients[1], planning.ingredients[1])
        XCTAssertEqual(edited.planning?.bindings, Array((planning.bindings ?? []).dropFirst()))
        XCTAssertEqual(edited.planning?.groups, planning.groups)
        XCTAssertThrowsError(try SharedMealGroupAmounts.validate(edited))

        edited.planning?.ingredients[0].quantity = .init(amount: .init(numerator: 2), unit: "count", originalLiteral: "Only the two protected lunch wraps remain")
        XCTAssertNoThrow(try SharedMealGroupAmounts.validate(edited))
        let retained = edited.planning?.bindings
        edited.planning?.setProposedGroup(dinner.id, for: wraps.id, included: true)
        edited.planning?.setProposedGroup(dinner.id, for: wraps.id, included: true)
        XCTAssertEqual(edited.planning?.ingredients[0].groupIds, [planning.groups[1].id, dinner.id])
        XCTAssertEqual(edited.planning?.bindings, retained, "Adding membership never invents an allocation amount")

        var unallocated = SharedMealPlanning(groups: planning.groups, ingredients: [planning.ingredients[1]])
        unallocated.setProposedGroup(dinner.id, for: planning.ingredients[1].id, included: false)
        unallocated.removeProposedIngredient(planning.ingredients[1].id)
        XCTAssertNil(unallocated.bindings)
        XCTAssertTrue(unallocated.ingredients.isEmpty)
    }
    func testGroupAmountEditNineWrapsPreservesLunchAndCancelRejectsMismatchedTotals() async throws {
        let scope = scope(), initialPage = try page(scope)
        let dinnerID = UUID(), lunchID = UUID(), ingredientID = UUID(), dinnerBindingID = UUID(), lunchBindingID = UUID()
        func quantity(_ n: Int, _ literal: String) -> SharedMealQuantity {
            .init(amount: .init(numerator: n), unit: "count", originalLiteral: literal)
        }
        let original = SharedMeal(title: "Wrap dinner", day: "2026-11-05", kind: "dinner", portions: 8, protected: false,
            planning: .init(groups: [.init(id: dinnerID, name: "Dinner", servings: .init(numerator: 6), protected: false),
                                     .init(id: lunchID, name: "Lunch", servings: .init(numerator: 2), protected: true)],
                ingredients: [.init(id: ingredientID, name: "Wraps", quantity: quantity(8, "Eight original wraps"), groupIds: [dinnerID, lunchID], exclusions: ["No sesame"]),
                              .init(name: "Optional garnish", quantity: nil, groupIds: [], exclusions: [])],
                bindings: [.init(id: dinnerBindingID, groupId: dinnerID, ingredientId: ingredientID, quantity: quantity(6, "Six dinner wraps")),
                           .init(id: lunchBindingID, groupId: lunchID, ingredientId: ingredientID, quantity: quantity(2, "Two reserved lunch wraps"))]))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(initialPage)) as? [String: Any])
        raw["meals"] = [["occurrenceId": initialPage.meals[0].id.uuidString, "revision": 2,
                          "meal": try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))]]
        let current = try JSONDecoder().decode(SharedMealChangePage.self, from: JSONSerialization.data(withJSONObject: raw))
        let service = MealChangeFixture(scope: scope, page: current), store = HistoryPendingStore(url: storeURL())
        let model = SharedMealChangeModel(scope: scope, service: service, store: store, runtime: { scope })
        await model.load()
        var edited = original
        edited.portions = 9; edited.planning?.groups[0].servings.numerator = 7
        edited.planning?.ingredients[0].quantity = quantity(9, "Nine wraps for dinner and lunch")
        await model.prepare(occurrenceID: current.meals[0].id, meal: edited, reason: "One guest")
        XCTAssertNil(model.review); XCTAssertNotNil(model.notice)
        edited.planning?.bindings?[0].quantity = quantity(7, "Seven dinner wraps")
        await model.prepare(occurrenceID: current.meals[0].id, meal: edited, reason: "One guest")
        let reviewed = try XCTUnwrap(model.review)
        XCTAssertEqual(reviewed.request.meal, edited)
        XCTAssertEqual(reviewed.request.meal.planning?.bindings?.map(\.id), [dinnerBindingID, lunchBindingID])
        XCTAssertEqual(reviewed.request.meal.planning?.bindings?[1], original.planning?.bindings?[1])
        XCTAssertEqual(reviewed.request.meal.planning?.groups[1], original.planning?.groups[1])
        XCTAssertEqual(reviewed.request.meal.planning?.ingredients[0].exclusions, ["No sesame"])
        XCTAssertNil(reviewed.request.meal.planning?.ingredients[1].quantity)
        model.cancelReview(); XCTAssertNil(model.review); XCTAssertEqual(model.page?.meals[0].meal, original)
        let cancelled = try await store.read(), beforeSend = await service.sends()
        XCTAssertTrue((cancelled.sharedMealChanges ?? []).isEmpty); XCTAssertTrue(beforeSend.isEmpty)
        var wrongUnit = edited; wrongUnit.planning?.bindings?[0].quantity.unit = "gram"
        XCTAssertThrowsError(try SharedMealGroupAmounts.validate(wrongUnit))
        var unknownTotal = edited; unknownTotal.planning?.ingredients[0].quantity = nil
        XCTAssertThrowsError(try SharedMealGroupAmounts.validate(unknownTotal))
        var exactFraction = edited; exactFraction.planning?.bindings?[0].quantity.amount = .init(numerator: 14, denominator: 2)
        try SharedMealGroupAmounts.validate(exactFraction)
        XCTAssertEqual(exactFraction.planning?.bindings?[0].quantity.amount, .init(numerator: 14, denominator: 2))
        await model.prepare(occurrenceID: current.meals[0].id, meal: edited, reason: "One guest")
        await model.sendReviewed()
        let sent = await service.sends(); XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent[0].request.meal, edited)
        XCTAssertEqual(model.page?.meals[0].meal, original, "Sending a proposal never applies the shared meal")
    }
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
