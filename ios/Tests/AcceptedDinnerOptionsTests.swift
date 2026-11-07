import XCTest
import CoreDomain
@testable import RoomInTheCart

final class AcceptedDinnerOptionsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func q(_ units: Int64) -> Quantity { .init(amount: try! Rational(units),unit: .count,originalLiteral: String(units)) }
    func access(_ shop: UUID, paid: Bool) -> DinnerAccessContext {
        .init(scope: .local(workspaceID: UUID()),actorID:"owner",shopID:shop,assignedShopperID:"owner",canPlan:true,canReadBudget:true,
              hasPaidTools:paid,roleRevision:0,verifiedAt:now,validUntil:now.addingTimeInterval(60))
    }
    func dinner(_ title: String, count: Int64, fallback: Bool = true) -> AcceptedDinner {
        .init(id: UUID(),template: .init(title:title,servings:.one,ingredients:[.init(name:"Peppers",quantity:q(count))]),acceptedAt: now,acceptedFallback: fallback)
    }

    func testActualScheduleEnumeratesAcceptedUnchosenDinnersAndPricesThreePepperPacksWithLunchInBoth() throws {
        var shop = ShoppingLedger(title:"Current list",basis:.init(branch:"Main")), state = DinnerPlanningState()
        var recipe = MealTemplate(title:"Rice",servings:try Rational(3),ingredients:[.init(name:"Peppers",quantity:q(3))])
        recipe.servingGroups = [.init(name:"Lunch",servings:.one,isProtected:true)]
        let selected = AcceptedDinner(id:UUID(),template:recipe,acceptedAt:now), b = dinner("Pasta",count:1)
        let fajitas = MealTemplate(title:"Fajitas",servings:try Rational(2),ingredients:[.init(name:"Peppers",quantity:q(4))])
        let a = AcceptedDinner(id:UUID(),template:fajitas,acceptedAt:now)
        _ = try shop.chooseMeal(recipe,at:now)
        for option in [selected,a,b] { try state.accept(option,access:access(shop.id,paid:true),at:now) }
        var draft = DinnerScenarioDraft(shop:shop,state:state)
        draft.meals = try DinnerLibraryPairings.scheduledMeals(shop:shop,state:state)
        XCTAssertEqual(draft.meals.map(\.portions),["1","2"]); XCTAssertEqual(draft.meals.map(\.protected),[true,false])
        let target = try XCTUnwrap(draft.meals.last?.id)
        var library = try DinnerLibraryPairings.prepare(&draft,target:target,shop:shop,state:state)
        XCTAssertEqual(library.candidates.map(\.id),[a.id,b.id])
        var pepper = DinnerFoodEvidenceDraft(); pepper.name = "Peppers"; pepper.packLabel = "Three peppers"
        pepper.packAmount = "3"; pepper.packPrice = "3"; pepper.availability = 1; pepper.yieldReviewed = true
        draft.foods = [pepper]
        for index in draft.matches.indices { draft.matches[index].foodID = pepper.id }
        for index in library.candidates.indices { library.candidates[index].hands = "10"; library.candidates[index].lead = "15" }
        for index in draft.baseline.indices { draft.baseline[index].cost = "2" }
        draft.fee = "1"; draft.feeThreshold = "7"; draft.tax = "0"; draft.deposits = "0"; draft.availableMinutes = "30"
        draft.currentHands = "10"; draft.currentLead = "10"; draft.store = "Fictional market"; draft.source = "Reviewed"
        draft.recipeYieldsReviewed = true; draft.baselineComplete = true; draft.baselineExcludesComparedRecipes = true
        let (base, alternatives, cap, conflicts) = try library.build(draft,shop:shop,state:state)
        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertEqual(a.template.servings,try Rational(2))
        XCTAssertThrowsError(try library.replacement(for: alternatives[0], shop: shop, state: state), "A protected lunch slice must survive")
        let paired = try DinnerScenarioEngine.pair(current:base,alternatives:alternatives,selectedAcceptedDinnerIDs:[selected.id],state:state,cap:cap,access:access(shop.id,paid:false),at:now,isolated:true)
        XCTAssertEqual(paired.baseline.packs.first?.result?.packsToBuy,1)
        XCTAssertEqual(paired.alternatives.map { $0.packs.first?.result?.packsToBuy },[2,1])
        XCTAssertEqual(paired.alternatives.map { $0.checkout.total.exact?.minorUnits },[800,600])
        XCTAssertTrue(paired.alternatives.allSatisfy(\.feasible))
        XCTAssertThrowsError(try DinnerScenarioEngine.pair(current:base,alternatives:alternatives,selectedAcceptedDinnerIDs:[],state:state,cap:nil,access:access(shop.id,paid:false),at:now))
        draft.meals[0].portions = "2"
        XCTAssertThrowsError(try library.build(draft,shop:shop,state:state))
    }

    struct RecoveryFixture {
        var journey: PickupJourney
        let line: UUID
        let key: ReceiptKey
        let firstObservation: UUID
        let dish: AcceptedDinner
        var draft: PickupFallbackDraft
    }
    func recovery() throws -> RecoveryFixture {
        let food = UUID(), meal = UUID(), lunch = UUID(), branch = "Main"
        var pickup = try PickupLedger(orderID:UUID(),orderLines:[.init(id:food,branchID:branch,name:"Peppers",ordered:q(8))])
        let key = ReceiptKey(sourceEventID:"arrived",orderLineID:food,branchID:branch,segmentID:"one")
        _ = try pickup.receive(.init(key:key,itemName:"Red peppers",received:q(8),disposition:.partial,receivedAt:now))
        let obs = UUID()
        _ = try pickup.confirmUsable(.init(id:obs,receipt:key,usable:q(6),confirmedAt:now,supersedesID:nil,confirmedMatchToOrderLine:true))
        var journey = PickupJourney(id:UUID(),savedAt:now)
        journey.pickup = pickup
        journey.needs = [.init(id:meal,orderLineID:food,name:"Wednesday dinner",amount:q(6),priority:.required),
                         .init(id:lunch,orderLineID:food,name:"Lunch",amount:q(2),priority:.protected)]
        var dish = dinner("Confirmed pepper dish",count:1).template
        dish.leadTimeMinutes = 120
        let accepted = AcceptedDinner(id:UUID(),template:dish,acceptedAt:now,acceptedFallback:true)
        var draft = PickupFallbackDraft()
        draft.target = meal; draft.portions = "5"; draft.deadline = now.addingTimeInterval(45*60)
        var review = FallbackRecipeReview(); review.elapsedMinutes = "20"; review.reviewedIdentityYieldAndExclusions = true
        review.completedLeadReviewed = true
        review.ingredients[dish.ingredients[0].id] = .init(foodID:food,packLabel:"One pepper",packYield:"1",packUnit:.count,packPrice:"2.50",availablePacks:"1")
        draft.reviews[accepted.id] = review; draft.tripMinutes = "10"; draft.topUpBudget = "3"; draft.topUpCharges = "0.25"
        return .init(journey:journey,line:food,key:key,firstObservation:obs,dish:accepted,draft:draft)
    }
    func ranked(_ f: RecoveryFixture, chosen: Set<UUID> = []) throws -> [PickupFallbackOption] {
        try PickupFallbackOptions.ranked(journey:f.journey,library:[f.dish],chosenTemplates:chosen,draft:f.draft,at:now,paid:true)
    }
    func testLatestUsableCorrectionChangesSmallestTopupWhilePreservingProtectedLunch() throws {
        var f = try recovery()
        let topup = try XCTUnwrap(ranked(f).first)
        XCTAssertEqual(topup.packCount,1); XCTAssertEqual(topup.merchandise.minorUnits,250); XCTAssertEqual(topup.minutes,30)
        XCTAssertEqual(topup.extraCash.minorUnits,275)
        f.draft.topUpBudget = "2.74"; XCTAssertTrue(try ranked(f).isEmpty)
        f.draft.topUpBudget = "3"
        let correction = UsableObservation(id:UUID(),receipt:f.key,usable:q(7),confirmedAt:now,supersedesID:f.firstObservation,confirmedMatchToOrderLine:true)
        _ = try f.journey.pickup?.confirmUsable(correction)
        let onHand = try XCTUnwrap(ranked(f).first)
        XCTAssertFalse(onHand.requiresTrip); XCTAssertEqual(onHand.minutes,20)
        f.draft.reviews[f.dish.id]?.completedLeadReviewed = false
        XCTAssertTrue(try ranked(f).isEmpty)
        f.draft.reviews[f.dish.id]?.completedLeadReviewed = true; f.draft.deadline = nil
        XCTAssertTrue(try ranked(f).isEmpty)
    }
    func testTripConsentOnlyAuthorizesReviewedDraftAndExactRepairAtSelection() throws {
        var f = try recovery()
        let ingredient = f.dish.template.ingredients[0].id
        f.draft.portions = "6"
        f.draft.topUpBudget = "6"
        f.draft.reviews[f.dish.id]?.ingredients[ingredient]?.availablePacks = "2"
        f.journey.stockLots = [.init(id: UUID(), foodID: f.line, name: "Peppers", usable: q(1),
                                     confirmedAt: now.addingTimeInterval(1), source: .freezer)]

        let shown = try XCTUnwrap(ranked(f).first)
        var review = PickupFallbackReview()
        review.draft = f.draft
        review.reviewDraft()
        XCTAssertEqual(shown.packCount, 2)
        XCTAssertFalse(review.canUse(shown, fresh: shown))
        review.agreedTrip = shown
        XCTAssertTrue(review.canUse(shown, fresh: try ranked(f).first))
        XCTAssertFalse(review.canUse(shown, fresh: nil))

        // A confirmed lot becomes available after display, while the same dinner still needs a trip.
        let updated = try XCTUnwrap(PickupFallbackOptions.ranked(journey: f.journey, library: [f.dish], chosenTemplates: [],
                                                                  draft: f.draft, at: now.addingTimeInterval(1), paid: true).first)
        XCTAssertEqual(updated.id, shown.id)
        XCTAssertEqual(updated.packCount, 1)
        XCTAssertFalse(review.canUse(shown, fresh: updated))
        XCTAssertFalse(review.canUse(updated, fresh: updated))
        review.rankedOfferChanged(to: updated)
        XCTAssertNil(review.agreedTrip)
        review.rankedOfferChanged(to: shown)
        XCTAssertFalse(review.canUse(shown, fresh: shown))
        review.agreedTrip = updated
        XCTAssertTrue(review.canUse(updated, fresh: updated))

        // Editing an offer requires review even when the same packages would be purchased.
        f.draft.reviews[f.dish.id]?.ingredients[ingredient]?.availablePacks = "3"
        XCTAssertEqual(try ranked(f).first, shown)
        review.draft = f.draft
        XCTAssertFalse(review.isReviewed)
        XCTAssertNil(review.agreedTrip)
        review.draft.reviews[f.dish.id]?.ingredients[ingredient]?.availablePacks = "2"
        XCTAssertFalse(review.canUse(shown, fresh: shown))
        review.reviewDraft()
        XCTAssertFalse(review.canUse(shown, fresh: shown))

        f.draft.portions = "4"
        let onHand = try XCTUnwrap(ranked(f).first)
        XCTAssertFalse(onHand.requiresTrip)
        review.draft = f.draft
        review.reviewDraft()
        XCTAssertTrue(review.canUse(onHand, fresh: onHand))
    }

    func testTimeLimitChangesBestTopUpAndRequiresAgreementForTheNewDinner() throws {
        var f = try recovery()
        let faster = dinner("Quick pepper dish", count: 1)
        var quickReview = try XCTUnwrap(f.draft.reviews[f.dish.id])
        var offer = try XCTUnwrap(quickReview.ingredients[f.dish.template.ingredients[0].id])
        offer.packPrice = "2.75"
        quickReview.ingredients = [faster.template.ingredients[0].id: offer]
        quickReview.elapsedMinutes = "5"
        f.draft.reviews[faster.id] = quickReview
        let library = [f.dish, faster]
        func best(at date: Date) throws -> PickupFallbackOption {
            try XCTUnwrap(PickupFallbackOptions.ranked(journey: f.journey, library: library, chosenTemplates: [],
                                                        draft: f.draft, at: date, paid: true).first)
        }
        var review = PickupFallbackReview()
        review.draft = f.draft
        review.reviewDraft()
        let initial = try best(at: now)
        XCTAssertEqual(initial.id, f.dish.id)
        review.agreedTrip = initial
        let later = try best(at: now.addingTimeInterval(16 * 60))
        XCTAssertEqual(later.id, faster.id)
        XCTAssertFalse(review.canUse(initial, fresh: later))
        review.rankedOfferChanged(to: later)
        XCTAssertFalse(review.canUse(later, fresh: later))
        review.agreedTrip = later
        XCTAssertTrue(review.canUse(later, fresh: later))
    }

    func testUncheckedWrongLateUnconfirmedAndExcludedFoodStayUnusableAndRepeatAndSeatAreIndependent() throws {
        var f = try recovery()
        XCTAssertTrue(try ranked(f,chosen:[f.dish.template.id]).isEmpty)
        f.draft.permitsRepeat = true; XCTAssertTrue(try XCTUnwrap(ranked(f,chosen:[f.dish.template.id]).first).repeatRequired)
        XCTAssertThrowsError(try PickupFallbackOptions.ranked(journey:f.journey,library:[f.dish],chosenTemplates:[],draft:f.draft,at:now,paid:false))
        XCTAssertTrue(try PickupFallbackOptions.ranked(journey:f.journey,library:[dinner("Idea only",count:1,fallback:false)],chosenTemplates:[],draft:f.draft,at:now,paid:true).isEmpty)
        f.journey.needDetails = [.init(id:try XCTUnwrap(f.draft.target),mealName:"Wednesday",exclusions:["peppers"],scheduledDay:nil,leadTimeMinutes:nil,completedSteps:[])]
        XCTAssertTrue(try ranked(f).isEmpty); f.journey.needDetails = []
        let correction = UsableObservation(id:UUID(),receipt:f.key,usable:q(6),confirmedAt:now,supersedesID:f.firstObservation,confirmedMatchToOrderLine:false)
        _ = try f.journey.pickup?.confirmUsable(correction)
        let late = ReceiptKey(sourceEventID:"later",orderLineID:f.line,branchID:"Main",segmentID:"two")
        _ = try f.journey.pickup?.receive(.init(key:late,itemName:"Pepper",received:q(8),disposition:.late,receivedAt:now.addingTimeInterval(7200)))
        XCTAssertTrue(PickupFallbackOptions.lots(f.journey,at:now).isEmpty)
        XCTAssertTrue(try ranked(f).isEmpty)
    }
    func testPairingLinksOnlyConfirmedUnreservedRemainderAndReplacesSupersededYield() throws {
        var f = try recovery()
        // Six usable peppers are already committed to dinner and lunch.
        XCTAssertTrue(try DinnerLibraryPairings.unreservedLots(f.journey, at: now).isEmpty)
        f.journey.needs.removeFirst()
        let leftover = try XCTUnwrap(DinnerLibraryPairings.unreservedLots(f.journey, at: now).first)
        XCTAssertEqual(leftover.usable.amount, try Rational(4))
        let correction = UsableObservation(id:UUID(),receipt:f.key,usable:q(7),confirmedAt:now,supersedesID:f.firstObservation,confirmedMatchToOrderLine:true)
        _ = try f.journey.pickup?.confirmUsable(correction)
        let corrected = try DinnerLibraryPairings.unreservedLots(f.journey,at:now)
        XCTAssertEqual(corrected.count,1); XCTAssertEqual(corrected[0].usable.amount, try Rational(5))
    }

    func testRepairRanksOnHandBeforeTopupAndPreservesCompetingUnfilledReservation() throws {
        var f = try recovery()
        let cheaper = dinner("Home meal",count:1)
        var review = FallbackRecipeReview()
        review.reviewedIdentityYieldAndExclusions = true; review.elapsedMinutes = "5"
        let batchID = UUID()
        f.journey.stockLots = [.init(id:UUID(),foodID:batchID,name:"Red peppers",usable:q(5),confirmedAt:now,source:.freezer)]
        review.ingredients[cheaper.template.ingredients[0].id] = .init(foodID:batchID)
        f.draft.reviews[cheaper.id] = review
        let options = try PickupFallbackOptions.ranked(journey:f.journey,library:[f.dish,cheaper],chosenTemplates:[],draft:f.draft,at:now,paid:true)
        XCTAssertEqual(options.map(\.id),[cheaper.id,f.dish.id])
        let correction = UsableObservation(id:UUID(),receipt:f.key,usable:q(1),confirmedAt:now,supersedesID:f.firstObservation,confirmedMatchToOrderLine:true)
        _ = try f.journey.pickup?.confirmUsable(correction)
        let ingredient = f.dish.template.ingredients[0].id
        f.draft.reviews[f.dish.id]?.ingredients[ingredient]?.availablePacks = "5"
        XCTAssertTrue(try ranked(f).isEmpty, "Five fallback peppers cannot complete a sixth pepper owed to lunch")
    }

    func testReviewedUnequalGroupsPriceTheSameProtectedFiveUnitsThatApplyRetains() throws {
        var shop = ShoppingLedger(title:"Pickup",basis:.init(branch:"Main")), state = DinnerPlanningState()
        let family = ServingGroup(name:"Dinner",servings:try Rational(2)), lunch = ServingGroup(name:"Lunch",servings:.one,isProtected:true)
        let rice = MealTemplate(title:"Rice",servings:try Rational(3),ingredients:[.init(name:"Peppers",quantity:q(6))],servingGroups:[family,lunch])
        let tacos = MealTemplate(title:"Tacos",servings:family.servings,ingredients:[.init(name:"Peppers",quantity:q(4))])
        let original = AcceptedDinner(id:UUID(),template:rice,acceptedAt:now), candidate = AcceptedDinner(id:UUID(),template:tacos,acceptedAt:now)
        for item in [original,candidate] { try state.accept(item,access:access(shop.id,paid:true),at:now) }
        let meal = try shop.chooseMeal(rice,at:now), source = try XCTUnwrap(shop.mealOccurrences.first?.ingredientContributionIDs.first)
        let protected = DinnerPortionBinding(occurrenceID:meal,contributionID:source,groupID:lunch.id,quantity:q(5),servings:.one)
        try state.setPortionBindings([protected,.init(occurrenceID:meal,contributionID:source,groupID:family.id,quantity:q(1),servings:family.servings)],for:meal,ledger:shop,access:access(shop.id,paid:true),at:now)
        var draft = DinnerScenarioDraft(shop:shop,state:state)
        draft.meals = try DinnerLibraryPairings.scheduledMeals(shop:shop,state:state)
        let slot = try XCTUnwrap(draft.meals.first(where:{ !$0.protected })?.id)
        var library = try DinnerLibraryPairings.prepare(&draft,target:slot,shop:shop,state:state)
        var food = DinnerFoodEvidenceDraft(name:"Peppers"); food.packLabel = "Three"; food.packAmount = "3"; food.packPrice = "3"; food.availability = 1; food.yieldReviewed = true
        draft.foods = [food]; for index in draft.matches.indices { draft.matches[index].foodID = food.id }
        library.candidates[0].hands = "10"; library.candidates[0].lead = "10"
        draft.currentHands = "10"; draft.currentLead = "10"; draft.availableMinutes = "30"; draft.recipeYieldsReviewed = true
        draft.store = "Market"; draft.source = "Reviewed"; draft.fee = "0"; draft.tax = "0"; draft.deposits = "0"
        draft.baseline[0].cost = "0"; draft.baselineComplete = true; draft.baselineExcludesComparedRecipes = true
        let (current,options,cap,_) = try library.build(draft,shop:shop,state:state)
        XCTAssertThrowsError(try DinnerScenarioEngine.evaluate(current,acceptedDinners:state.acceptedDinners,cap:cap))
        let result = try DinnerScenarioEngine.pair(current:current,alternatives:options,selectedAcceptedDinnerIDs:[original.id],state:state,cap:cap,access:access(shop.id,paid:true),at:now,ledger:shop)
        XCTAssertTrue(try XCTUnwrap(result.alternatives.first).feasible)
        XCTAssertEqual(result.baseline.packs.first?.result?.packsToBuy,2)
        XCTAssertEqual(result.alternatives.first?.packs.first?.result?.packsToBuy,3)
        let replacement = try library.replacement(for:XCTUnwrap(options.first),shop:shop,state:state)
        let buyer = access(shop.id,paid:true)
        let preview = try DinnerPlanningEngine.preview(changes:replacement,tool:.pairing,ledger:shop,state:state,access:buyer,phase:.draft,at:now)
        _ = try DinnerPlanningEngine.apply(preview.proposal,ledger:&shop,state:&state,access:buyer,phase:.draft,at:now)
        XCTAssertEqual(state.portionBindings,[protected])
        XCTAssertEqual(shop.contributions.first?.quantity?.amount,try Rational(5))
        XCTAssertEqual(try DinnerLibraryPairings.scheduledMeals(shop:shop,state:state).first?.reviewedAmounts[rice.ingredients[0].id],q(5))
    }

    func testExactReplacementRequiresUnchangedWholeOccurrenceAndAppliesOnceWithoutAnExtraDinner() throws {
        var shop = ShoppingLedger(title:"Two dinners"), state = DinnerPlanningState()
        let old = dinner("Old dinner",count:1), new = dinner("New dinner",count:2), other = dinner("Other dinner",count:1)
        for option in [old,new,other] { try state.accept(option,access:access(shop.id,paid:true),at:now) }
        let target = try shop.chooseMeal(old.template,at:now), preserved = try shop.chooseMeal(other.template,at:now)
        var draft = DinnerScenarioDraft(shop:shop,state:state)
        draft.meals = try DinnerLibraryPairings.scheduledMeals(shop:shop,state:state)
        let library = try DinnerLibraryPairings.prepare(&draft,target:target,shop:shop,state:state)
        let food = DinnerFoodEvidenceDraft(name:"Peppers",stockAmount:"5",stockConfirmed:true,outsideReservationsReviewed:true)
        draft.foods = [food]; for i in draft.matches.indices { draft.matches[i].foodID = food.id }
        draft.recipeYieldsReviewed = true; draft.store = "Store"; draft.branch = "Main"; draft.source = "Reviewed"
        let (_,alternatives,_,_) = try library.build(draft,shop:shop,state:state)
        let scenario = try XCTUnwrap(alternatives.first)
        let changes = try library.replacement(for:scenario,shop:shop,state:state)
        let grant = access(shop.id,paid:true)
        let preview = try DinnerPlanningEngine.preview(changes:changes,tool:.pairing,ledger:shop,state:state,access:grant,phase:.draft,at:now)
        XCTAssertEqual(shop.mealOccurrences.filter { $0.removedAt == nil }.count,2)
        _ = try DinnerPlanningEngine.apply(preview.proposal,ledger:&shop,state:&state,access:grant,phase:.draft,at:now)
        _ = try DinnerPlanningEngine.apply(preview.proposal,ledger:&shop,state:&state,access:grant,phase:.draft,at:now)
        XCTAssertEqual(Set(shop.mealOccurrences.filter { $0.removedAt == nil }.map(\.title)),["New dinner","Other dinner"])
        XCTAssertNil(shop.mealOccurrences.first { $0.id == preserved }?.removedAt)
        XCTAssertThrowsError(try library.replacement(for:scenario,shop:shop,state:state))
    }

    @MainActor func testAllAcceptedRecoveryOptionsFailWithoutChangingOriginalOpenNeedOrDeadline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let tuesday = UrgentMealNeed(id: UUID(), food: "Wraps", meal: "Tuesday tacos", required: q(6),
                                    available: q(2), due: now.addingTimeInterval(30 * 60), confirmedAt: now)
        let wednesday = UrgentMealNeed(id: UUID(), food: "Peppers", meal: "Wednesday dinner", required: q(5),
                                      available: q(4), due: now.addingTimeInterval(45 * 60), confirmedAt: now)
        let firstSaved = await model.addUrgent(tuesday)
        let secondSaved = await model.addUrgent(wednesday)
        XCTAssertTrue(firstSaved && secondSaved)
        let before = try XCTUnwrap(model.journey)
        let coverageBefore = try XCTUnwrap(model.allocation)
        XCTAssertEqual(before.urgent, [tuesday, wednesday])
        XCTAssertFalse(wednesday.resolved)
        XCTAssertEqual(coverageBefore.demands.first { $0.id == wednesday.id }?.shortfall, try Rational(1))
        XCTAssertEqual(coverageBefore.demands.first { $0.id == tuesday.id }?.shortfall, try Rational(4))

        var slowTemplate = dinner("Marinated peppers", count: 1).template
        slowTemplate.leadTimeMinutes = 120
        let slow = AcceptedDinner(id: UUID(), template: slowTemplate, acceptedAt: now, acceptedFallback: true)
        let quick = dinner("Quick peppers", count: 1)
        let library = [slow, quick]
        var draft = PickupFallbackDraft()
        draft.target = wednesday.id; draft.portions = "5"
        // Extending the review date must not replace the saved 45-minute deadline.
        draft.deadline = now.addingTimeInterval(180 * 60)
        draft.tripMinutes = "10"; draft.topUpBudget = "3"; draft.topUpCharges = "0.25"
        for option in library {
            var review = FallbackRecipeReview()
            review.elapsedMinutes = "20"; review.completedLeadReviewed = true
            review.reviewedIdentityYieldAndExclusions = true
            review.ingredients[option.template.ingredients[0].id] = .init(foodID: wednesday.id,
                packLabel: "One pepper", packYield: "1", packUnit: .count, packPrice: "2.50", availablePacks: "1")
            draft.reviews[option.id] = review
        }
        func ranked(_ value: PickupFallbackDraft) throws -> [PickupFallbackOption] {
            try PickupFallbackOptions.ranked(journey: XCTUnwrap(model.journey), library: library,
                chosenTemplates: [], draft: value, at: now, paid: true)
        }
        // Positive control: these exact accepted identities are usable with reviewed
        // completed preparation and one genuinely available top-up package.
        let feasible = try ranked(draft)
        XCTAssertEqual(Set(feasible.map(\.id)), Set(library.map(\.id)))
        XCTAssertTrue(feasible.allSatisfy { $0.packCount == 1 && $0.minutes == 30 })
        XCTAssertEqual(model.journey, before)

        draft.reviews[slow.id]?.elapsedMinutes = "120"
        draft.reviews[slow.id]?.completedLeadReviewed = false
        draft.reviews[quick.id]?.ingredients[quick.template.ingredients[0].id]?.availablePacks = "0"
        // Each option fails a distinct real requirement, not missing setup/access.
        var timingOnly = draft
        timingOnly.reviews[quick.id] = nil
        XCTAssertTrue(try ranked(timingOnly).isEmpty)
        var quantityOnly = draft
        quantityOnly.reviews[slow.id] = nil
        XCTAssertTrue(try ranked(quantityOnly).isEmpty)
        let rejected = try ranked(draft)
        XCTAssertTrue(rejected.isEmpty)
        var review = PickupFallbackReview()
        review.draft = draft; review.reviewDraft()
        let priorOption = try XCTUnwrap(feasible.first)
        review.agreedTrip = priorOption
        XCTAssertFalse(review.canUse(priorOption, fresh: rejected.first))
        review.rankedOfferChanged(to: rejected.first)
        XCTAssertNil(review.agreedTrip)
        XCTAssertEqual(model.journey, before, "No rejected option may save a repair or settle either need")
        XCTAssertEqual(model.allocation, coverageBefore)
        XCTAssertEqual(model.selectedID, before.id)
        XCTAssertEqual(model.journey?.urgent.first { $0.id == wednesday.id }, wednesday)
        XCTAssertEqual(model.journey?.urgent.first { $0.id == tuesday.id }, tuesday)
        let reopened = PickupModel(databaseURL: url, clock: { self.now })
        await reopened.load()
        XCTAssertEqual(reopened.journey, before)
        XCTAssertEqual(reopened.allocation, coverageBefore)
    }

}
