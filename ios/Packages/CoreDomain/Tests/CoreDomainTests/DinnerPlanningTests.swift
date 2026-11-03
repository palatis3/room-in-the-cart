import XCTest
@testable import CoreDomain

final class DinnerPlanningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_664_000)
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private func q(_ n: Int64, _ d: Int64 = 1) throws -> Quantity { Quantity(amount: try Rational(n, d), unit: .count, originalLiteral: "\(n)/\(d)") }
    private func access(_ ledger: ShoppingLedger, actor: String = "Mia", shopper: String = "Mia", paid: Bool = true,
                        budget: Bool = true, canPlan: Bool = true, shared: Bool = false, authorized: Bool = false) -> DinnerAccessContext {
        DinnerAccessContext(scope: shared ? .household(id: "family") : .local(workspaceID: workspaceID), actorID: actor,
            shopID: ledger.id, assignedShopperID: shopper, canPlan: canPlan, canReadBudget: budget, hasPaidTools: paid,
            roleRevision: 1, verifiedAt: now.addingTimeInterval(-10), validUntil: now.addingTimeInterval(300), sharedCommitAuthorized: authorized)
    }
    private func meal(_ name: String = "Tacos", quantity: Int64 = 6) throws -> MealTemplate {
        MealTemplate(title: name, servings: try Rational(3), ingredients: [MealIngredient(name: "wraps", quantity: try q(quantity))])
    }
    private func accept(_ template: MealTemplate, ledger: ShoppingLedger, state: inout DinnerPlanningState, fallback: Bool = false) throws -> AcceptedDinner {
        let dinner = AcceptedDinner(id: UUID(), template: template, acceptedAt: now, acceptedFallback: fallback)
        try state.accept(dinner, access: access(ledger), at: now); return dinner
    }
    private func roundTrip<T: Codable>(_ value: T) throws -> T { try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) }

    func testPreviewCancelHasZeroMutationAndAtomicApplyUsesReviewedIDs() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        _ = try ledger.addManualLine(name: "soap", quantity: q(1), at: now)
        let before = ledger, oldState = state
        let dinner = PlannedDinner(template: try meal())
        let lunch = DinnerReservation(name: "wraps", quantity: try q(2), purpose: "Friday lunch", day: nil)
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(dinner), .reserve(lunch)], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(ledger, before); XCTAssertEqual(state, oldState)
        let receipt = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state,
            access: access(before), phase: .draft, at: now)
        XCTAssertEqual(ledger, preview.projectedLedger); XCTAssertEqual(ledger.revision, before.revision + 1)
        XCTAssertEqual(ledger.mealOccurrences.first?.id, dinner.occurrenceID)
        XCTAssertEqual(receipt.revisionID, ledger.revisionID); XCTAssertEqual(state.protectedDays.first?.contributionID, lunch.contributionID)
        XCTAssertEqual(ledger.search("soap").count, 1)
        try LedgerWorkspace(shops: [ledger], dinnerPlanning: state).validate()
    }
    func testReservationWithinTypedTotalDoesNotAddQuantityAndPreviewIDsMatch() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let line = try ledger.addManualLine(name: "wraps", quantity: q(12), at: now)
        let source = try XCTUnwrap(ledger.contributions.first?.id)
        let reservation = DinnerReservation(name: "wraps", quantity: try q(2), purpose: "Lunch", day: nil, withinContributionID: source)
        let preview = try DinnerPlanningEngine.preview(changes: [.reserve(reservation)], tool: .manual, ledger: ledger,
            state: state, access: access(ledger), phase: .draft, at: now)
        try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(12)); XCTAssertEqual(ledger, preview.projectedLedger)
    }
    func testExactReplayAfterNewerEditReturnsReceiptWithoutRevertingAndChangedIntentFails() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal()))], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        let receipt = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now)
        _ = try ledger.addManualLine(name: "coffee", quantity: q(1), at: now)
        let saved = ledger
        XCTAssertEqual(try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state,
            access: access(ledger), phase: .draft, at: now), receipt)
        XCTAssertEqual(ledger, saved); XCTAssertEqual(state.applyReceipts.count, 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview.proposal)) as? [String: Any])
        json["createdAt"] = 0
        let changed = try JSONDecoder().decode(DinnerProposal.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(changed, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now))
        XCTAssertEqual(ledger, saved)
    }
    func testStalePreviewAndChangedPlanningVersionRejectWithoutMutation() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal()))], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        _ = try accept(meal("Soup"), ledger: ledger, state: &state)
        let before = ledger
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now))
        XCTAssertEqual(before, ledger)
        let next = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal()))], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        _ = try ledger.addManualLine(name: "rice", quantity: q(1), at: now)
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(next.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now))
    }
    func testSecondAdultProposesButOnlyCurrentShopperAppliesAndOfflineSharedCannotCommit() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let second = access(ledger, actor: "Alex", shared: true)
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal()))], tool: .manual,
            ledger: ledger, state: state, access: second, phase: .draft, at: now)
        try state.saveProposal(preview.proposal, access: second, at: now)
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: second, phase: .draft, at: now))
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state,
            access: access(ledger, shared: true), phase: .draft, at: now))
        try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state,
            access: access(ledger, shared: true, authorized: true), phase: .draft, at: now)
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state,
            access: access(ledger, shopper: "Alex", shared: true, authorized: true), phase: .draft, at: now))
    }
    func testContributorExpiredAndBudgetlessAccessAreDeniedAtBoundary() throws {
        let ledger = ShoppingLedger(), state = DinnerPlanningState()
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal()))], tool: .manual,
            ledger: ledger, state: state, access: access(ledger, canPlan: false), phase: .draft, at: now))
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal()))], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now.addingTimeInterval(301)))
        let pair = try quotes(ledger)
        XCTAssertThrowsError(try TwoStoreQuoteEngine.compare(pair, access: access(ledger, budget: false), at: now))
    }
    func testFreeReuseAndLapseKeepManualWorkAndAllSavedMeals() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let first = try accept(meal(), ledger: ledger, state: &state), second = try accept(meal("Soup"), ledger: ledger, state: &state)
        let free = access(ledger, paid: false)
        _ = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(acceptedDinnerID: first.id, template: first.template))], tool: .reusableDinner,
            ledger: ledger, state: state, access: free, phase: .draft, at: now)
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(acceptedDinnerID: second.id, template: second.template))], tool: .reusableDinner,
            ledger: ledger, state: state, access: free, phase: .draft, at: now))
        _ = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal("Manual")))], tool: .manual,
            ledger: ledger, state: state, access: free, phase: .draft, at: now)
        try state.selectFreeReusableDinner(second.id, access: free, at: now)
        XCTAssertEqual(state.acceptedDinners.count, 2)
        XCTAssertThrowsError(try state.saveRotation(DinnerRotation(title: "Week", entries: [.init(acceptedDinnerID: first.id, dayOffset: 0)]), access: free, at: now))
    }
    func testRotationSelectedNightCopiesVersionAndWeeklyEditsPreserveTemplate() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let first = try accept(meal(), ledger: ledger, state: &state), second = try accept(meal("Soup"), ledger: ledger, state: &state)
        let a = DinnerRotationEntry(acceptedDinnerID: first.id, dayOffset: 2, pinned: true)
        let b = DinnerRotationEntry(acceptedDinnerID: second.id, dayOffset: 4)
        let rotation = DinnerRotation(title: "Usual week", entries: [a,b]); try state.saveRotation(rotation, access: access(ledger), at: now)
        let original = state.acceptedDinners
        let start = try MealDay(year: 2026, month: 11, day: 2, timeZoneIdentifier: "America/New_York")
        let preview = try DinnerPlanningEngine.previewRotation(rotationID: rotation.id, selectedEntryIDs: [a.id], weekStart: start,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(ledger.mealOccurrences.count, 1); XCTAssertEqual(ledger.mealOccurrences[0].scheduledDay?.iso8601, "2026-11-04")
        try ledger.updateMeal(occurrenceID: ledger.mealOccurrences[0].id, title: "Wednesday override", notes: "", at: now)
        XCTAssertEqual(state.acceptedDinners, original); XCTAssertEqual(state.rotations.first, rotation)
    }
    func testCivilWeekMoveKeepsFridayLunchAndSameNeedsAcrossDST() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let thursday = try MealDay(year: 2026, month: 10, day: 29, timeZoneIdentifier: "America/New_York")
        let friday = try dinnerDay(thursday, adding: 1), sunday = try dinnerDay(thursday, adding: 3)
        let chosen = PlannedDinner(template: try meal(), day: thursday)
        let reservation = DinnerReservation(name: "wraps", quantity: try q(2), purpose: "Lunch", day: friday)
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(chosen), .reserve(reservation)], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now)
        let sources = ledger.contributions
        let move = try DinnerPlanningEngine.preview(changes: [.move(occurrenceID: chosen.occurrenceID, day: sunday)], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        try DinnerPlanningEngine.apply(move.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now)
        let week = try DinnerPlanningEngine.week(start: thursday, ledger: ledger, state: state, access: access(ledger), at: now)
        XCTAssertEqual(ledger.contributions, sources); XCTAssertEqual(week.days[3].meals.first?.id, chosen.occurrenceID)
        XCTAssertEqual(week.days[1].protectedContributionIDs, [reservation.contributionID]); XCTAssertEqual(week.days[3].day.iso8601, "2026-11-01")
    }
    func testPairingRetainsProtectedBindingIdentityAndQuantityAfterReplacingNamedGroup() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let supper = ServingGroup(name: "Supper", servings: try Rational(2))
        let lunch = ServingGroup(name: "Lunch", servings: .one, isProtected: true)
        let template = MealTemplate(title: "Rice", servings: try Rational(3),
            ingredients: [.init(name: "Rice", quantity: try q(8))], servingGroups: [supper,lunch])
        let occurrence = try ledger.chooseMeal(template, at: now)
        let id = try XCTUnwrap(ledger.mealOccurrences.first?.ingredientContributionIDs.first)
        let protected = DinnerPortionBinding(occurrenceID: occurrence, contributionID: id, groupID: lunch.id, quantity: try q(5), servings: .one)
        let mutable = DinnerPortionBinding(occurrenceID: occurrence, contributionID: id, groupID: supper.id, quantity: try q(3), servings: supper.servings)
        XCTAssertThrowsError(try DinnerPlanningEngine.removingServingGroup(supper.id, from: occurrence, ledger: ledger, state: state))
        try state.setPortionBindings([protected,mutable], for: occurrence, ledger: ledger, access: access(ledger), at: now)
        XCTAssertNil(try DinnerPlanningEngine.removingServingGroup(lunch.id, from: occurrence, ledger: ledger, state: state))
        let keep = try XCTUnwrap(DinnerPlanningEngine.removingServingGroup(supper.id, from: occurrence, ledger: ledger, state: state))
        let candidate = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Soup", servings: supper.servings,
            ingredients: [.init(name: "Peas", quantity: try q(2))]), acceptedAt: now)
        try state.accept(candidate, access: access(ledger), at: now)
        let changes: [DinnerLedgerChange] = [.adjust(keep), .choose(.init(acceptedDinnerID: candidate.id, template: candidate.template))]
        let preview = try DinnerPlanningEngine.preview(changes: changes, tool: .pairing, ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(ledger.contributions.first?.quantity?.amount, try Rational(8))
        let original = ledger
        let receipt = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(original), phase: .draft, at: now)
        XCTAssertEqual(ledger.mealOccurrences.map(\.servings), [.one,supper.servings])
        XCTAssertEqual(ledger.mealOccurrences.first?.servingGroups,[lunch])
        XCTAssertEqual(ledger.contributions.first?.id,id)
        XCTAssertEqual(ledger.contributions.first?.quantity?.amount,try Rational(5))
        XCTAssertEqual(state.portionBindings,[protected])
        let retry = try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(original), phase: .draft, at: now)
        XCTAssertEqual(receipt,retry)
        try state.validate(shops: [ledger])
    }

    func testGuestBindingPreservesProtectedPortionsAndCrossesWholePackBoundary() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let dinnerGroup = ServingGroup(name: "Dinner", servings: try Rational(3))
        let lunchGroup = ServingGroup(name: "Lunch", servings: .one, isProtected: true)
        let template = MealTemplate(title: "Wraps", servings: try Rational(4), ingredients: [.init(name: "wraps", quantity: try q(8))], servingGroups: [dinnerGroup,lunchGroup])
        let occurrence = try ledger.chooseMeal(template, at: now)
        let source = try XCTUnwrap(ledger.mealOccurrences.first?.ingredientContributionIDs.first)
        try state.setPortionBindings([
            .init(occurrenceID: occurrence, contributionID: source, groupID: dinnerGroup.id, quantity: try q(6), servings: try Rational(3)),
            .init(occurrenceID: occurrence, contributionID: source, groupID: lunchGroup.id, quantity: try q(2), servings: .one)
        ], for: occurrence, ledger: ledger, access: access(ledger), at: now)
        let preview = try DinnerPlanningEngine.previewGuests(occurrenceID: occurrence, servingsByGroup: [dinnerGroup.id: try Rational(7,2)],
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        let quantity = try XCTUnwrap(preview.projectedLedger.contributions.first?.quantity)
        XCTAssertEqual(quantity.amount, try Rational(9)); XCTAssertEqual(preview.projectedLedger.mealOccurrences.first?.servingGroups.last, lunchGroup)
        let packA = PackOffer(id: "a", label: "Eight", usableQuantity: try q(8), price: Money(minorUnits: 240))
        let packB = PackOffer(id: "b", label: "Eight", usableQuantity: try q(8), price: Money(minorUnits: 240))
        var workspace = LedgerWorkspace(shops: [ledger], selectedShopID: ledger.id, dinnerPlanning: state)
        let line = try XCTUnwrap(ledger.lines.first)
        let requirement = try LedgerPackRequirement.review(shop: ledger, lineID: line.id)
        let selection = try LedgerPackSelection(workspaceID: workspaceID, shop: ledger, lineID: line.id,
            request: .init(itemName: line.name, needed: requirement.quantity, protectedAmount: requirement.protectedQuantity, offerA: packA, offerB: packB),
            selectedOfferID: packA.id, at: now, source: "Package quote")
        try workspace.recordPackSelection(selection, workspaceID: workspaceID)
        let context = CheckoutContext(storeID: "Store", branchID: "Main", mode: .pickup, slot: "Friday", commitmentsID: ledger.id, observedAt: now, source: "Quote")
        let zero = CostEvidence.exact(Money(minorUnits: 0))
        let fee = CheckoutFee(id: "small-order", rule: .waivedAt(threshold: Money(minorUnits: 400), belowThreshold: .exact(Money(minorUnits: 150)), basis: .eligibleItemsAfterEligibleDiscounts))
        func impact(tax: CostEvidence, oldCost: Int64 = 240, complete: Bool = true, fees: [CheckoutFee]? = nil) throws -> DinnerGuestImpact {
            let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .components(
                lines: [.init(id: line.id, name: line.name, cost: .exact(Money(minorUnits: oldCost)))], lineSetComplete: complete,
                fees: fees ?? [fee], discounts: [], tax: tax, deposits: zero))
            return try preview.guestImpact(workspace: workspace, workspaceID: workspaceID, quote: quote)
        }
        let result = try impact(tax: zero)
        XCTAssertEqual(result.lines.first?.before, 1); XCTAssertEqual(result.lines.first?.after, 2)
        XCTAssertEqual(result.beforeFees?.exact?.minorUnits, 150); XCTAssertEqual(result.afterFees?.exact?.minorUnits, 0)
        XCTAssertEqual(result.beforeCheckout?.total.exact?.minorUnits, 390); XCTAssertEqual(result.afterCheckout?.total.exact?.minorUnits, 480)
        XCTAssertNil(try impact(tax: .unknown(reason: "retailer tax")).afterCheckout?.total.exact)
        XCTAssertNil(try impact(tax: zero, oldCost: 275).afterCheckout?.total.exact)
        XCTAssertNil(try impact(tax: zero, complete: false).afterCheckout?.total.exact)
        let unknownFees = try impact(tax: zero, fees: [.init(id: "fee", rule: .fixed(.unknown(reason: "retailer fee")))])
        XCTAssertNil(unknownFees.afterFees?.exact); XCTAssertNil(unknownFees.afterCheckout?.total.exact)
        let inclusive = try preview.guestImpact(workspace: workspace, workspaceID: workspaceID,
            quote: .init(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 390)))))
        XCTAssertEqual(inclusive.beforeCheckout?.total.exact?.minorUnits, 390); XCTAssertNil(inclusive.afterCheckout)
        XCTAssertThrowsError(try preview.guestImpact(workspace: workspace, workspaceID: UUID(), quote: nil))
        XCTAssertEqual(workspace.shops, [ledger]); XCTAssertEqual(workspace.dinnerPlanning.portionBindings, state.portionBindings)
        var missing = workspace; missing.packSelections = []
        let unresolved = try preview.guestImpact(workspace: missing, workspaceID: workspaceID, quote: nil)
        XCTAssertNil(unresolved.lines.first?.after); XCTAssertNil(unresolved.afterCheckout)
        try missing.shops[0].addManualLine(name: "New item", quantity: q(1))
        XCTAssertThrowsError(try preview.guestImpact(workspace: missing, workspaceID: workspaceID, quote: nil))
        XCTAssertThrowsError(try DinnerPlanningEngine.previewGuests(occurrenceID: occurrence, servingsByGroup: [lunchGroup.id: try Rational(2)],
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now))
        XCTAssertEqual(ledger.contributions.first?.quantity?.amount, try Rational(8))
    }
    func testFreeManualReductionFromTwelveToFourKeepsOnePackAndPrivateBudgetHidden() throws {
        var ledger = ShoppingLedger()
        let occurrenceID = try ledger.chooseMeal(meal(quantity: 12), at: now)
        let source = try XCTUnwrap(ledger.contributions.first)
        var workspace = LedgerWorkspace(shops: [ledger], selectedShopID: ledger.id)
        let need = try LedgerPackRequirement.review(shop: ledger, lineID: source.lineID)
        let pack = PackOffer(id: "dozen", label: "Dozen", usableQuantity: try q(12), price: Money(minorUnits: 399))
        let other = PackOffer(id: "single", label: "Single", usableQuantity: try q(1), price: Money(minorUnits: 100))
        let selected = try LedgerPackSelection(workspaceID: workspaceID, shop: ledger, lineID: source.lineID,
            request: .init(itemName: need.name, needed: need.quantity, protectedAmount: need.protectedQuantity, offerA: pack, offerB: other),
            selectedOfferID: pack.id, at: now, source: "Entered package")
        try workspace.recordPackSelection(selected, workspaceID: workspaceID)
        let change = DinnerLedgerChange.adjust(.init(occurrenceID: occurrenceID, servings: .one, groups: [], quantities: [.init(contributionID: source.id, quantity: try q(4))]))
        let preview = try DinnerPlanningEngine.preview(changes: [change], tool: .manual, ledger: ledger, state: workspace.dinnerPlanning,
            access: access(ledger, paid: false, budget: false), phase: .draft, at: now)
        let review = try preview.guestImpact(workspace: workspace, workspaceID: workspaceID, quote: nil)
        XCTAssertEqual(review.lines.first?.before, 1); XCTAssertEqual(review.lines.first?.after, 1)
        XCTAssertNil(review.lines.first?.beforeCost); XCTAssertNil(review.lines.first?.afterCost); XCTAssertNil(review.beforeCheckout)
    }

    func testUnboundNamedPortionsRequireReviewAndIsolatedPreviewCannotApply() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let occurrence = try ledger.chooseMeal(meal(), at: now)
        XCTAssertThrowsError(try DinnerPlanningEngine.previewGuests(occurrenceID: occurrence, servingsByGroup: [UUID(): .one],
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now))
        let dinner = try accept(meal(), ledger: ledger, state: &state)
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(acceptedDinnerID: dinner.id, template: dinner.template))], tool: .pairing,
            ledger: ledger, state: state, access: access(ledger, paid: false), phase: .draft, at: now, isolated: true)
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now))
    }
    func testPlacedBasketAllowsCalendarButRequiresAmendmentForDemandChange() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let occurrence = try ledger.chooseMeal(meal(), at: now)
        let day = try MealDay(year: 2026, month: 11, day: 8, timeZoneIdentifier: "America/New_York")
        let move = try DinnerPlanningEngine.preview(changes: [.move(occurrenceID: occurrence, day: day)], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .reportedPlaced, at: now)
        try DinnerPlanningEngine.apply(move.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .reportedPlaced, at: now)
        let removal = try DinnerPlanningEngine.preview(changes: [.remove(occurrenceID: occurrence)], tool: .manual,
            ledger: ledger, state: state, access: access(ledger), phase: .reportedPlaced, at: now)
        XCTAssertTrue(removal.needsPurchaseAmendment)
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(removal.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .reportedPlaced, at: now))
        XCTAssertNil(ledger.mealOccurrences.first?.removedAt)
    }
    func testIdeaGenerationReviewCorrectionAcceptanceAndRetryStayOutsideBasket() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let pattern = MealTemplate(title: "Soup", ingredients: [.init(name: "soy beans", quantity: try q(1))])
        let requestID = UUID(), draftID = UUID()
        var draft = try DinnerIdeaEngine.draft(requestID: requestID, draftID: draftID, catalogVersion: "v1", catalog: [pattern], seed: 7,
            householdExclusions: ["soy"], at: now)
        XCTAssertEqual(draft, try DinnerIdeaEngine.draft(requestID: requestID, draftID: draftID, catalogVersion: "v1", catalog: [pattern], seed: 7, householdExclusions: ["soy"], at: now))
        try state.saveIdea(draft, access: access(ledger), at: now)
        XCTAssertFalse(DinnerIdeaEngine.review(draft).canAccept)
        let acceptedID = UUID()
        XCTAssertThrowsError(try state.acceptIdea(draft, acceptedID: acceptedID, access: access(ledger), at: now))
        draft.template.ingredients[0].name = "pinto beans"
        XCTAssertTrue(DinnerIdeaEngine.review(draft).canAccept); XCTAssertFalse(DinnerIdeaEngine.review(draft).canClaimCoverage)
        let accepted = try state.acceptIdea(draft, acceptedID: acceptedID, access: access(ledger, paid: false), at: now)
        XCTAssertEqual(try state.acceptIdea(draft, acceptedID: acceptedID, access: access(ledger), at: now), accepted)
        XCTAssertEqual(state.acceptedDinners.count, 1); XCTAssertTrue(ledger.mealOccurrences.isEmpty); XCTAssertTrue(ledger.contributions.isEmpty)
    }
    func testWorkspaceRoundtripOldDocumentDefaultsEmptyAndBadReferenceRejected() throws {
        var ledger = ShoppingLedger(); _ = try ledger.chooseMeal(meal(), at: now)
        let workspace = LedgerWorkspace(shops: [ledger], selectedShopID: ledger.id)
        XCTAssertEqual(try roundTrip(workspace), workspace)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any]); json.removeValue(forKey: "dinnerPlanning")
        let old = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.dinnerPlanning, DinnerPlanningState()); XCTAssertEqual(old.shops, [ledger])
        var state = DinnerPlanningState()
        let otherLedger = ShoppingLedger()
        try state.recordWeekNote(.init(shopID: otherLedger.id, day: MealDay(year: 2026, month: 11, day: 3, timeZoneIdentifier: "UTC"), kind: .away, text: "Away"), access: access(otherLedger), at: now)
        // A valid note for another shop cannot be attached to this workspace.
        XCTAssertThrowsError(try LedgerWorkspace(shops: [ledger], dinnerPlanning: state).validate())
    }

    private func commitments() throws -> DinnerCommitmentSet {
        DinnerCommitmentSet(commitments: [DinnerCommitment(name: "Wednesday dinner", kind: .dinner, portions: try Rational(4)),
            DinnerCommitment(name: "Two lunches", kind: .lunch, portions: try Rational(2), protected: true)])
    }
    private func scenarioMeal(_ name: String = "Tacos", quantity: Int64 = 6) throws -> MealTemplate {
        MealTemplate(title: name, servings: try Rational(4), ingredients: [MealIngredient(name: "wraps", quantity: try q(quantity))])
    }
    private func scenario(_ ledger: ShoppingLedger, _ commitments: DinnerCommitmentSet, dinner: AcceptedDinner,
        baseline: Int64 = 3340, wraps: Int64 = 8, price: Int64? = 240, stockQuantity: Int64 = 0,
        fee: CostEvidence = .exact(Money(minorUnits: 495)), available: DinnerAvailability = .confirmed(maximumPacks: nil),
        prep: DinnerPreparation = DinnerPreparation(handsOnMinutes: 15, remainingLeadMinutes: 20, availableMinutes: 45)) throws -> DinnerScenario {
        let food = UUID()
        let demands = [DinnerDemand(commitmentID: commitments.commitments[0].id, foodID: food, name: "wraps", quantity: try q(wraps - 2), acceptedDinnerID: dinner.id, ingredientID: dinner.template.ingredients[0].id),
            DinnerDemand(commitmentID: commitments.commitments[1].id, foodID: food, name: "wraps", quantity: try q(2))]
        return DinnerScenario(commitments: commitments, acceptedDinnerIDs: [dinner.id], demands: demands,
            stock: stockQuantity > 0 ? [.init(id: UUID(), foodID: food, name: "Confirmed food", usable: try q(stockQuantity), confirmedAt: now)] : [],
            packs: [.init(foodID: food, offer: .init(id: "wrap-pack", label: "Eight wraps", usableQuantity: try q(8), price: price.map { Money(minorUnits: $0) }), availability: available)],
            baselineLines: [.init(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "All other original goods", cost: .exact(Money(minorUnits: baseline)))], baselineComplete: true,
            fees: [.init(id: "pickup", rule: .waivedAt(threshold: Money(minorUnits: 3500), belowThreshold: fee, basis: .eligibleItemsBeforeDiscounts))],
            tax: .exact(.zero), deposits: .exact(.zero),
            context: .init(storeID: "A", branchID: "A1", mode: .pickup, slot: "Tuesday", commitmentsID: commitments.id, observedAt: now, source: "Shopper"), preparation: prep)
    }
    func testG12PairingAndGuestWholeCheckoutUseActualThresholdEngine() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let fallback = try accept(scenarioMeal("Freezer dinner"), ledger: ledger, state: &state, fallback: true)
        let fajitas = try accept(scenarioMeal("Fajitas"), ledger: ledger, state: &state)
        let needs = try commitments()
        let a = try scenario(ledger, needs, dinner: fallback, stockQuantity: 8)
        let b = try scenario(ledger, needs, dinner: fajitas)
        let cap = CheckoutCap(scope: .wholeCheckout, commitmentsID: needs.id, amount: Money(minorUnits: 3800))
        let result = try DinnerScenarioEngine.pair(current: a, alternatives: [b], selectedAcceptedDinnerIDs: [fallback.id],
            state: state, cap: cap, access: access(ledger), at: now)
        XCTAssertEqual(result.baseline.checkout.total.exact?.minorUnits, 3835)
        XCTAssertEqual(result.alternatives.first?.checkout.total.exact?.minorUnits, 3580)
        XCTAssertEqual(result.preferredScenarioIDs, [b.id])
        XCTAssertEqual(try CheckoutEngine.compare(before: result.baseline.quote, after: result.alternatives[0].quote).change?.minorUnits, -255)
        let c = try DinnerScenarioEngine.evaluate(scenario(ledger, needs, dinner: fajitas, wraps: 10), acceptedDinners: state.acceptedDinners, cap: cap)
        XCTAssertEqual(c.checkout.total.exact?.minorUnits, 3820); XCTAssertEqual(c.packs.first?.result?.packsToBuy, 2)
        XCTAssertEqual(c.packs.first?.result?.leftover, try Rational(6))
        let d = try DinnerScenarioEngine.evaluate(scenario(ledger, needs, dinner: fajitas, baseline: 3240, wraps: 10), acceptedDinners: state.acceptedDinners, cap: cap)
        XCTAssertEqual(d.checkout.total.exact?.minorUnits, 3720)
        XCTAssertEqual(try DinnerScenarioEngine.pair(current: b, alternatives: [b], selectedAcceptedDinnerIDs: [fajitas.id], state: state, cap: cap,
            access: access(ledger), at: now).status, .noNewPairing)
    }
    func testPairingUnknownPriceAvailabilityAndDifferentCommitmentsNeverWin() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let a = try accept(scenarioMeal("Original"), ledger: ledger, state: &state), b = try accept(scenarioMeal("Alternate"), ledger: ledger, state: &state)
        let needs = try commitments(); let original = try scenario(ledger, needs, dinner: a, stockQuantity: 8)
        let unknown = try scenario(ledger, needs, dinner: b, price: nil)
        let result = try DinnerScenarioEngine.pair(current: original, alternatives: [unknown], selectedAcceptedDinnerIDs: [a.id], state: state, cap: nil, access: access(ledger), at: now)
        XCTAssertTrue(result.preferredScenarioIDs.isEmpty); XCTAssertNil(result.alternatives.first?.checkout.total.exact)
        XCTAssertFalse(try DinnerScenarioEngine.evaluate(scenario(ledger, needs, dinner: b, available: .unavailable), acceptedDinners: state.acceptedDinners).foodCoverageComplete)
        XCTAssertThrowsError(try DinnerScenarioEngine.pair(current: original, alternatives: [scenario(ledger, commitments(), dinner: b)],
            selectedAcceptedDinnerIDs: [a.id], state: state, cap: nil, access: access(ledger), at: now))
    }
    func testConfirmedStockProtectsLunchAndFallbackRequiresTimeAndTripConsent() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let fallback = try accept(scenarioMeal(quantity: 4), ledger: ledger, state: &state, fallback: true), unaccepted = try accept(scenarioMeal("Other"), ledger: ledger, state: &state)
        let needs = try commitments(); let topup = try scenario(ledger, needs, dinner: fallback, wraps: 6, stockQuantity: 5)
        let result = try DinnerScenarioEngine.recover(alternatives: [topup, scenario(ledger, needs, dinner: unaccepted)], state: state, cap: nil, access: access(ledger), at: now)
        XCTAssertEqual(result.alternatives.count, 1); XCTAssertTrue(result.needsExtraTripConfirmation)
        let allocation = result.alternatives[0].stockAllocation
        XCTAssertEqual(allocation.demands.first(where: { $0.id == topup.demands[1].id })?.allocated, try Rational(2))
        XCTAssertEqual(allocation.demands.first(where: { $0.id == topup.demands[0].id })?.shortfall, .one)
        let slow = try scenario(ledger, needs, dinner: fallback, prep: .init(handsOnMinutes: 15, remainingLeadMinutes: 120, availableMinutes: 45))
        XCTAssertTrue(try DinnerScenarioEngine.recover(alternatives: [slow], state: state, cap: nil, access: access(ledger), at: now).unresolved)
    }
    private func quotes(_ ledger: ShoppingLedger, bFee: CostEvidence = .exact(Money(minorUnits: 100)), bTrip: CostEvidence = .exact(Money(minorUnits: 400)), bAvailable: Bool? = true) throws -> TwoStoreQuotePair {
        let needs = try commitments()
        func option(_ store: String, goods: Int64, fee: CostEvidence, trip: CostEvidence, minutes: Int, available: Bool?) -> StoreQuoteOption {
            StoreQuoteOption(label: store, commitments: needs,
                quote: CheckoutQuote(scope: .wholeCheckout, context: .init(storeID: store, branchID: store + "1", mode: .pickup, slot: "Tuesday", commitmentsID: needs.id, observedAt: now, source: "Shopper entered"),
                    pricing: .components(lines: [.init(id: UUID(), name: "All goods", cost: .exact(Money(minorUnits: goods)))], lineSetComplete: true,
                        fees: [.init(id: "pickup", rule: .fixed(fee))], discounts: [], tax: .exact(.zero), deposits: .exact(.zero))),
                available: available, quantitiesMatched: true, trip: .init(incrementalCash: trip, extraMinutes: minutes, tripAlreadyPlanned: store == "A"), adoptionBasis: ShopBasis(branch: store + "1", mode: .pickup, timeZoneIdentifier: "UTC"))
        }
        return .init(shopID: ledger.id, baseRevisionID: ledger.revisionID, basisRevision: ledger.basisRevision,
            first: option("A", goods: 3600, fee: .exact(Money(minorUnits: 200)), trip: .exact(.zero), minutes: 0, available: true),
            second: option("B", goods: 3400, fee: bFee, trip: bTrip, minutes: 18, available: bAvailable))
    }
    func testTwoStoreCheckoutVersusTravelCashAndTimeVector() throws {
        let ledger = ShoppingLedger(); let pair = try quotes(ledger)
        let result = try TwoStoreQuoteEngine.compare(pair, access: access(ledger, paid: false), at: now)
        XCTAssertEqual(result.first.checkout.total.exact?.minorUnits, 3800); XCTAssertEqual(result.second.checkout.total.exact?.minorUnits, 3500)
        XCTAssertEqual(result.first.tripInclusive.total.exact?.minorUnits, 3800); XCTAssertEqual(result.second.tripInclusive.total.exact?.minorUnits, 3900)
        XCTAssertEqual(result.itemSubtotalChange?.minorUnits, -200)
        XCTAssertEqual(result.checkoutChange?.minorUnits, -300); XCTAssertEqual(result.tripCashChange?.minorUnits, 100)
        XCTAssertEqual(result.extraMinutesChange, 18); XCTAssertEqual(result.preferredByTotalCash, pair.first.id)
        XCTAssertThrowsError(try CheckoutEngine.compare(before: pair.first.quote, after: pair.second.quote))
    }
    func testUnknownFeeTripOrAvailabilityDoesNotCrownWinnerAndBreakEvenIsCashOnly() throws {
        let ledger = ShoppingLedger()
        let fee = try TwoStoreQuoteEngine.compare(quotes(ledger, bFee: .unknown(reason: "Fee unknown")), access: access(ledger), at: now)
        XCTAssertNil(fee.preferredByTotalCash); XCTAssertNil(fee.checkoutChange)
        XCTAssertEqual(fee.second.checkout.total.lowerBound.minorUnits, 3400)
        let trip = try TwoStoreQuoteEngine.compare(quotes(ledger, bTrip: .unknown(reason: "Travel cost unknown")), access: access(ledger), at: now)
        XCTAssertNil(trip.preferredByTotalCash); XCTAssertEqual(trip.secondTripCashBreakEven?.minorUnits, 300); XCTAssertEqual(trip.checkoutChange?.minorUnits, -300)
        XCTAssertNil(try TwoStoreQuoteEngine.compare(quotes(ledger, bAvailable: nil), access: access(ledger), at: now).preferredByTotalCash)
    }
    func testQuoteAdoptionRequiresCurrentDraftAndClearsOldStoreEvidence() throws {
        var ledger = ShoppingLedger(); var state = DinnerPlanningState(); let pair = try quotes(ledger)
        try state.saveQuotePair(pair, access: access(ledger), at: now)
        let basis = ShopBasis(branch: "B1", mode: .pickup, timeZoneIdentifier: "UTC")
        let preview = try TwoStoreQuoteEngine.previewAdoption(pair, optionID: pair.second.id, basis: basis,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(ledger.basis.branch, "")
        XCTAssertThrowsError(try TwoStoreQuoteEngine.previewAdoption(pair, optionID: pair.second.id, basis: basis,
            ledger: ledger, state: state, access: access(ledger), phase: .frozen, at: now))
        try DinnerPlanningEngine.apply(preview.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(ledger.basis.branch, "B1"); XCTAssertNil(ledger.quoteReference); XCTAssertEqual(state.quotePairs.first, pair)
        XCTAssertThrowsError(try TwoStoreQuoteEngine.previewAdoption(pair, optionID: pair.second.id, basis: basis,
            ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now))
    }
    func testGuestApplyRefreshesBindingsForTheNextPreview() throws {
        var ledger = ShoppingLedger(), state = DinnerPlanningState()
        let group = ServingGroup(name: "Dinner", servings: try Rational(4))
        let template = MealTemplate(title: "Wraps", servings: try Rational(4), ingredients: [.init(name: "wraps", quantity: try q(8))], servingGroups: [group])
        let occurrence = try ledger.chooseMeal(template, at: now)
        let source = try XCTUnwrap(ledger.mealOccurrences.first?.ingredientContributionIDs.first)
        try state.setPortionBindings([.init(occurrenceID: occurrence, contributionID: source, groupID: group.id, quantity: try q(8), servings: try Rational(4))],
            for: occurrence, ledger: ledger, access: access(ledger), at: now)
        let first = try DinnerPlanningEngine.previewGuests(occurrenceID: occurrence, servingsByGroup: [group.id: try Rational(5)], ledger: ledger,
            state: state, access: access(ledger), phase: .draft, at: now)
        try DinnerPlanningEngine.apply(first.proposal, ledger: &ledger, state: &state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(state.portionBindings[0].quantity.amount, try Rational(10)); XCTAssertEqual(state.portionBindings[0].servings, try Rational(5))
        let second = try DinnerPlanningEngine.previewGuests(occurrenceID: occurrence, servingsByGroup: [group.id: try Rational(6)], ledger: ledger,
            state: state, access: access(ledger), phase: .draft, at: now)
        XCTAssertEqual(second.proposal.baseRevisionID, ledger.revisionID); XCTAssertEqual(second.projectedContributions.first?.quantity?.amount, try Rational(12))
    }
    func testManualQuantityEditCannotEraseProtectedFoodOrRemoveItsMeal() throws {
        var ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let group = ServingGroup(name: "Protected lunches", servings: try Rational(2), isProtected: true)
        let template = MealTemplate(title: "Lunch batch", servings: try Rational(2), ingredients: [.init(name: "wraps", quantity: try q(2))], servingGroups: [group])
        let occurrence = try ledger.chooseMeal(template, at: now), source = try XCTUnwrap(ledger.contributions.first?.id)
        try state.setPortionBindings([.init(occurrenceID: occurrence, contributionID: source, groupID: group.id, quantity: try q(2), servings: try Rational(2))],
            for: occurrence, ledger: ledger, access: access(ledger), at: now)
        let adjustment = DinnerAdjustment(occurrenceID: occurrence, servings: try Rational(2), groups: [group], quantities: [.init(contributionID: source, quantity: try q(1))])
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.adjust(adjustment)], tool: .manual, ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now))
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.remove(occurrenceID: occurrence)], tool: .manual, ledger: ledger, state: state, access: access(ledger), phase: .draft, at: now))
        XCTAssertEqual(ledger.contributions.first?.quantity?.amount, try Rational(2))
    }
    func testPrivateBudgetIsAbsentFromPlannerPreviewProjection() throws {
        let ledger = ShoppingLedger(basis: ShopBasis(cap: Money(minorUnits: 3800)))
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(template: meal()))], tool: .manual, ledger: ledger,
            state: DinnerPlanningState(), access: access(ledger, budget: false), phase: .draft, at: now)
        XCTAssertNil(preview.budgetBasis); XCTAssertEqual(preview.projectedMeals.count, 1)
    }
    func testIdeaEditingCannotRemoveHouseholdHardExclusion() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let pattern = MealTemplate(title: "Soup", ingredients: [.init(name: "soy beans", quantity: try q(1))])
        var draft = try DinnerIdeaEngine.draft(requestID: UUID(), draftID: UUID(), catalogVersion: "v1", catalog: [pattern], seed: 0, householdExclusions: ["soy"], at: now)
        draft.template.exclusions = []
        XCTAssertFalse(DinnerIdeaEngine.review(draft).canAccept)
        XCTAssertThrowsError(try state.acceptIdea(draft, acceptedID: UUID(), access: access(ledger), at: now))
        draft.template.ingredients[0].name = "pinto beans"
        let accepted = try state.acceptIdea(draft, acceptedID: UUID(), access: access(ledger), at: now)
        XCTAssertEqual(accepted.template.exclusions, ["soy"])
    }
    func testImportedPaidFieldsCannotAuthorizeSharedApply() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let accepted = try accept(meal(), ledger: ledger, state: &state)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["hasPaidTools"] = true; json["assignedShopperID"] = "Alex"; json["sharedCommitAuthorized"] = true
        let restored = try JSONDecoder().decode(DinnerPlanningState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, state)
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(acceptedDinnerID: accepted.id, template: accepted.template))], tool: .rotation,
            ledger: ledger, state: restored, access: access(ledger, paid: false, shared: true), phase: .draft, at: now))
    }
    func testTwelveToFourStillBuysOneWholePack() throws {
        let packA = PackOffer(id: "a", label: "Twelve", usableQuantity: try q(12), price: Money(minorUnits: 300))
        let packB = PackOffer(id: "b", label: "Twelve", usableQuantity: try q(12), price: Money(minorUnits: 300))
        for amount: Int64 in [12,4] {
            let result = try PackComparison.evaluate(.init(itemName: "wraps", needed: q(amount), offerA: packA, offerB: packB))
            XCTAssertEqual(result.offerA.packsToBuy, 1); XCTAssertEqual(result.offerA.totalCost?.minorUnits, 300)
        }
    }
    func testLimitedSearchReportsUntestedAndDoesNotClaimNoPairing() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState()
        let first = try accept(meal(), ledger: ledger, state: &state), second = try accept(meal("Soup"), ledger: ledger, state: &state)
        let needs = try commitments(); let current = try scenario(ledger, needs, dinner: first)
        let result = try DinnerScenarioEngine.pair(current: current, alternatives: [current, scenario(ledger, needs, dinner: second)], selectedAcceptedDinnerIDs: [first.id],
            state: state, cap: nil, access: access(ledger), at: now, searchLimit: 1)
        XCTAssertEqual(result.status, .searchIncomplete); XCTAssertEqual(result.untestedCount, 1)
    }
    func testFallbackOverCapRemainsUnresolved() throws {
        let ledger = ShoppingLedger(); var state = DinnerPlanningState(); let accepted = try accept(meal(), ledger: ledger, state: &state, fallback: true)
        let needs = try commitments()
        let result = try DinnerScenarioEngine.recover(alternatives: [scenario(ledger, needs, dinner: accepted)], state: state,
            cap: CheckoutCap(scope: .wholeCheckout, commitmentsID: needs.id, amount: Money(minorUnits: 100)), access: access(ledger), at: now)
        XCTAssertTrue(result.unresolved); XCTAssertTrue(result.preferredScenarioIDs.isEmpty); XCTAssertEqual(result.alternatives.count, 1)
    }
    func testQuoteCannotAdoptUnreviewedBasisOrUnsavedProof() throws {
        let ledger = ShoppingLedger(); let pair = try quotes(ledger); var state = DinnerPlanningState()
        let basis = ShopBasis(branch: "B1", mode: .pickup, timeZoneIdentifier: "UTC")
        XCTAssertThrowsError(try TwoStoreQuoteEngine.previewAdoption(pair, optionID: pair.second.id, basis: basis, ledger: ledger,
            state: state, access: access(ledger), phase: .draft, at: now))
        try state.saveQuotePair(pair, access: access(ledger), at: now)
        var altered = basis; altered.cap = Money(minorUnits: 1)
        XCTAssertThrowsError(try TwoStoreQuoteEngine.previewAdoption(pair, optionID: pair.second.id, basis: altered, ledger: ledger,
            state: state, access: access(ledger), phase: .draft, at: now))
        XCTAssertThrowsError(try DinnerPlanningEngine.preview(changes: [.adoptBasis(basis)], tool: .manual, ledger: ledger,
            state: state, access: access(ledger, budget: false), phase: .draft, at: now))
    }
    func testInvalidDateAndOverflowLeaveLedgerUnchanged() throws {
        XCTAssertThrowsError(try MealDay(year: 2026, month: 2, day: 30, timeZoneIdentifier: "UTC"))
        let ledger = ShoppingLedger(); var state = DinnerPlanningState(); let accepted = try accept(meal(), ledger: ledger, state: &state)
        let needs = try commitments(); let expensive = try scenario(ledger, needs, dinner: accepted, wraps: 10, price: Int64.max)
        XCTAssertThrowsError(try DinnerScenarioEngine.evaluate(expensive, acceptedDinners: state.acceptedDinners))
        XCTAssertEqual(ledger.revision, 0)
        let original = LedgerWorkspace(shops: [ledger], dinnerPlanning: state)
        XCTAssertEqual(try roundTrip(original), original)
    }
}
