import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

final class PickupOfferEvaluationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64, _ unit: UnitOfMeasure = .count) -> Quantity {
        Quantity(amount: try! Rational(amount), unit: unit, originalLiteral: String(amount))
    }
    private func money(_ cents: Int64) -> Money { Money(minorUnits: cents) }
    private func fixture() throws -> (PickupJourney, PickupOffer) {
        let id = UUID(), line = UUID(), protected = UUID(), dinner = UUID()
        let context = CheckoutContext(storeID: "Market", branchID: "Main", mode: .pickup, slot: "Evening", commitmentsID: id, observedAt: now, source: "Frozen checkout")
        var journey = PickupJourney(id: id, savedAt: now)
        journey.context = context
        journey.quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(money(1_000))))
        journey.pickup = try PickupLedger(orderID: UUID(), orderLines: [PickupOrderLine(id: line, branchID: "Main", name: "Wraps", ordered: q(8))])
        journey.needs = [AllocationNeed(id: protected, orderLineID: line, name: "Lunch", amount: q(2), priority: .protected),
                         AllocationNeed(id: dinner, orderLineID: line, name: "Dinner", amount: q(6), priority: .required)]
        let offer = PickupOffer(id: UUID(), lineID: line, replacement: "Replacement wraps", required: q(6), remainingOriginal: q(2),
            price: .exact(money(300)), ceiling: money(450), deadline: try RetailerDeadline(cutoff: now.addingTimeInterval(60), timeZoneID: "America/New_York"),
            fallback: "Ask me", householdPreference: "", retailerResponse: "")
        return (journey, offer)
    }
    private func inputs(offer: PickupOffer, journey: PickupJourney) -> PickupOfferEvaluationInputs {
        PickupOfferEvaluationInputs(offeredUsable: q(6), retainedOriginalCharge: .exact(money(100)), lineAllowance: money(500),
            dishRules: journey.needs.filter { $0.orderLineID == offer.lineID }.map { PickupOfferDishRule(needID: $0.id, decision: .accepted, exclusionsConfirmed: false) },
            includedOfferIDs: [offer.id], otherCheckoutCost: .exact(money(600)), wholeCheckoutCap: money(1_000),
            checkoutSource: "Retailer amended preview: unaffected lines plus original retained fee, tax and discounts", checkoutObservedAt: now)
    }
    private func reviewed(_ offer: PickupOffer, _ inputs: PickupOfferEvaluationInputs, _ journey: PickupJourney) throws -> PickupOffer {
        var result = offer
        result.evaluation = try PickupOfferEvaluation.review(offer: offer, inputs: inputs, journey: journey, at: now)
        return result
    }

    func testRetainedOriginalAndExplicitFixedFeesConsumeJointAndLineHeadroom() throws {
        let (journey, raw) = try fixture()
        var input = inputs(offer: raw, journey: journey)
        let offer = try reviewed(raw, input, journey)
        let result = try PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: now)
        XCTAssertEqual(result.combinedCost, .exact(money(1_000))) // 600 includes retained fees; no new fee added.
        XCTAssertEqual(result.checkoutAssessment, .within)
        XCTAssertEqual(result.replacementMaximum, money(300))
        XCTAssertEqual(offer.evaluation?.effectiveNoteCeiling, money(300))
        XCTAssertEqual(offer.ceiling, money(450))
        input.lineAllowance = money(250)
        let tighter = try reviewed(raw, input, journey)
        XCTAssertEqual(try PickupOfferEvaluation.evaluate(offer: tighter, journey: journey, at: now).replacementMaximum, money(150))
        XCTAssertEqual(tighter.evaluation?.effectiveNoteCeiling, money(150))
        // Frozen quote is deliberately irrelevant to arithmetic: never subtract an unknown old line from it.
        var changed = journey; changed.quote = CheckoutQuote(scope: .wholeCheckout, context: journey.context!, pricing: .inclusiveTotal(.unknown(reason: "Old inclusive quote only")))
        let fresh = try reviewed(raw, input, changed)
        XCTAssertEqual(try PickupOfferEvaluation.evaluate(offer: fresh, journey: changed, at: now).combinedCost, .exact(money(1_000)))
    }

    func testSimultaneousOffersShareAllowanceAndCannotDuplicateOneOriginalLine() throws {
        var (journey, first) = try fixture()
        let secondLine = UUID(), secondNeed = UUID()
        journey.pickup = try PickupLedger(orderID: journey.pickup!.orderID, orderLines: journey.pickup!.orderLines + [PickupOrderLine(id: secondLine, branchID: "Main", name: "Beans", ordered: q(2))])
        journey.needs.append(AllocationNeed(id: secondNeed, orderLineID: secondLine, name: "Beans dinner", amount: q(2), priority: .required))
        let second = PickupOffer(id: UUID(), lineID: secondLine, replacement: "Beans", required: q(2), remainingOriginal: q(1), price: .exact(money(400)), ceiling: nil, deadline: first.deadline, fallback: "Ask", householdPreference: "", retailerResponse: "")
        var secondInput = inputs(offer: second, journey: journey); secondInput.retainedOriginalCharge = .exact(money(200)); secondInput.wholeCheckoutCap = money(1_400)
        journey.offers = [try reviewed(second, secondInput, journey)]
        var input = inputs(offer: first, journey: journey); input.includedOfferIDs.append(second.id); input.wholeCheckoutCap = money(1_400)
        first = try reviewed(first, input, journey)
        let result = try PickupOfferEvaluation.evaluate(offer: first, journey: journey, at: now)
        XCTAssertEqual(result.combinedCost, .exact(money(1_600))); XCTAssertEqual(result.checkoutAssessment, .over)
        XCTAssertEqual(result.replacementMaximum, money(100)); XCTAssertEqual(result.dishes.count, 3)
        var generous = input; generous.wholeCheckoutCap = money(5_000)
        let jointFits = try reviewed(first, generous, journey)
        let independent = try PickupOfferEvaluation.evaluate(offer: jointFits, journey: journey, at: now)
        XCTAssertEqual(independent.checkoutAssessment, .within)
        let selectedOther = try XCTUnwrap(independent.selectedOffers.first { $0.id == second.id })
        XCTAssertEqual(selectedOther.offerAssessment, .noCeiling)
        XCTAssertEqual(selectedOther.lineMaximum, money(300))
        XCTAssertEqual(selectedOther.lineAssessment, .over) // 400 replacement +200 retained exceeds its500 line allowance.
        // Other offer's saved scenario selected itself only, but its component is counted exactly once.
        XCTAssertEqual(journey.offers[0].evaluation?.inputs.includedOfferIDs, [second.id])
        var changedSecond = journey.offers[0]
        var changedInput = changedSecond.evaluation!.inputs; changedInput.offeredUsable = q(1)
        changedSecond = try reviewed(changedSecond, changedInput, journey)
        journey.offers[0] = changedSecond
        XCTAssertFalse(try PickupOfferEvaluation.isCurrent(offer: first, journey: journey))
        journey.needDetails = [PickupNeedDetail(id: secondNeed, mealName: "Beans dinner", exclusions: ["Soy"], scheduledDay: nil, leadTimeMinutes: nil, completedSteps: [])]
        let newlyReviewed = try reviewed(first, input, journey)
        let newlyEvaluated = try PickupOfferEvaluation.evaluate(offer: newlyReviewed, journey: journey, at: now)
        let otherDish = try XCTUnwrap(newlyEvaluated.dishes.first { $0.needID == secondNeed })
        XCTAssertEqual(otherDish.decision, .unreviewed) // An old concurrent approval cannot accept a new exclusion.
        XCTAssertEqual(otherDish.replacementAllocated, .zero)
        XCTAssertTrue(newlyEvaluated.issues.contains(.dishUnreviewed))
        let alternative = PickupOffer(id: UUID(), lineID: first.lineID, replacement: "Alternative", required: first.required, remainingOriginal: first.remainingOriginal, price: first.price, ceiling: nil, deadline: first.deadline, fallback: "Ask", householdPreference: "", retailerResponse: "")
        journey.offers.append(alternative); input.includedOfferIDs.append(alternative.id)
        XCTAssertThrowsError(try reviewed(first, input, journey))
    }

    func testProtectedReservationsDeclinedAndExcludedDishesDoNotReuseSupply() throws {
        var (journey, raw) = try fixture()
        var input = inputs(offer: raw, journey: journey)
        input.offeredUsable = q(4)
        input.dishRules[0].decision = .declined
        let offer = try reviewed(raw, input, journey)
        let result = try PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: now)
        XCTAssertEqual(result.dishes[0].originalAllocated, try Rational(2))
        XCTAssertEqual(result.dishes[0].replacementAllocated, .zero)
        XCTAssertEqual(result.dishes[1].originalAllocated, .zero)
        XCTAssertEqual(result.dishes[1].replacementAllocated, try Rational(4))
        XCTAssertEqual(result.dishes[1].shortfall, try Rational(2))
        journey.needDetails = [PickupNeedDetail(id: journey.needs[1].id, mealName: "Dinner", exclusions: ["Wheat"], scheduledDay: nil, leadTimeMinutes: nil, completedSteps: [])]
        let excluded = try reviewed(raw, input, journey)
        let denied = try PickupOfferEvaluation.evaluate(offer: excluded, journey: journey, at: now)
        XCTAssertEqual(denied.dishes[1].replacementAllocated, .zero)
        XCTAssertEqual(denied.dishes[1].shortfall, try Rational(6))
        XCTAssertTrue(denied.dishes[1].issues.contains(.exclusionsUnreviewed))
        input.dishRules[1].exclusionsConfirmed = true
        let accepted = try reviewed(raw, input, journey)
        XCTAssertEqual(try PickupOfferEvaluation.evaluate(offer: accepted, journey: journey, at: now).dishes[1].replacementAllocated, try Rational(4))
    }

    func testUnknownYieldConversionAndDishApprovalRemainConditional() throws {
        let (journey, raw) = try fixture()
        for usable in [nil, q(200, .gram)] as [Quantity?] {
            var input = inputs(offer: raw, journey: journey); input.offeredUsable = usable
            let offer = try reviewed(raw, input, journey)
            let result = try PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: now)
            XCTAssertNil(result.dishes[1].shortfall)
            XCTAssertTrue(result.issues.contains(usable == nil ? .unknownUsable : .conversionUnknown))
        }
        var input = inputs(offer: raw, journey: journey); input.dishRules = []
        let unreviewed = try reviewed(raw, input, journey)
        let result = try PickupOfferEvaluation.evaluate(offer: unreviewed, journey: journey, at: now)
        XCTAssertEqual(result.dishes[1].replacementAllocated, .zero); XCTAssertNil(result.dishes[1].shortfall)
        XCTAssertTrue(result.issues.contains(.dishUnreviewed))
    }

    func testUnknownChargesNeverInventZeroAndBoundedCrossingStaysConditional() throws {
        let (journey, raw) = try fixture()
        var input = inputs(offer: raw, journey: journey)
        input.otherCheckoutCost = .unknown(reason: "Retained fees and unaffected lines not known")
        let unknown = try reviewed(raw, input, journey)
        let result = try PickupOfferEvaluation.evaluate(offer: unknown, journey: journey, at: now)
        XCTAssertEqual(result.checkoutAssessment, .unknown); XCTAssertNil(result.replacementMaximum)
        XCTAssertEqual(unknown.evaluation?.effectiveNoteCeiling, money(400)) // Known inherited line still constrains the note.
        var noLine = input; noLine.lineAllowance = nil
        XCTAssertEqual(try reviewed(raw, noLine, journey).evaluation?.effectiveNoteCeiling, raw.ceiling)
        input.wholeCheckoutCap = money(200)
        let knownOver = try reviewed(raw, input, journey)
        XCTAssertEqual(try PickupOfferEvaluation.evaluate(offer: knownOver, journey: journey, at: now).checkoutAssessment, .over)
        input.wholeCheckoutCap = money(1_000); input.otherCheckoutCost = .bounded(lower: money(500), upper: money(700), reason: "Tax unsettled")
        let range = try reviewed(raw, input, journey)
        XCTAssertEqual(try PickupOfferEvaluation.evaluate(offer: range, journey: journey, at: now).checkoutAssessment, .conditional)
        XCTAssertEqual(range.evaluation?.effectiveNoteCeiling, money(200))
    }

    func testKnownLineMaximumConstrainsRetailerNoteWithoutWholeCheckoutCap() throws {
        let (journey, raw) = try fixture()
        var input = inputs(offer: raw, journey: journey)
        input.wholeCheckoutCap = nil; input.lineAllowance = money(250)
        input.otherCheckoutCost = .unknown(reason: "Remaining checkout not yet known")
        let offer = try reviewed(raw, input, journey)
        let result = try PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: now)
        XCTAssertEqual(result.lineMaximum, money(150)); XCTAssertNil(result.replacementMaximum)
        XCTAssertEqual(result.checkoutAssessment, .noCeiling)
        XCTAssertEqual(offer.evaluation?.effectiveNoteCeiling, money(150))
        XCTAssertEqual(result.minimumCost, money(400)); XCTAssertNil(result.maximumCost)
        input.wholeCheckoutCap = money(200)
        let over = try reviewed(raw, input, journey)
        let overResult = try PickupOfferEvaluation.evaluate(offer: over, journey: journey, at: now)
        XCTAssertEqual(overResult.minimumOverage, money(200)); XCTAssertEqual(overResult.checkoutAssessment, .over)
        XCTAssertNil(overResult.maximumCost)
    }

    func testBasketWithinCapDoesNotOverrideManualOfferCeilingAndMissingProvenanceFails() throws {
        let (journey, existing) = try fixture()
        let raw = PickupOffer(id: existing.id, lineID: existing.lineID, replacement: existing.replacement,
            required: existing.required, remainingOriginal: existing.remainingOriginal, price: existing.price,
            ceiling: money(200), deadline: existing.deadline, fallback: existing.fallback, householdPreference: "", retailerResponse: "")
        var input = inputs(offer: raw, journey: journey)
        let offer = try reviewed(raw, input, journey)
        let result = try PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: now)
        XCTAssertEqual(result.checkoutAssessment, .within); XCTAssertEqual(result.offerAssessment, .over)
        XCTAssertEqual(offer.evaluation?.effectiveNoteCeiling, money(200))
        input.checkoutSource = " "
        XCTAssertThrowsError(try reviewed(raw, input, journey))
        input.checkoutSource = "Reviewed"; input.checkoutObservedAt = now.addingTimeInterval(301)
        XCTAssertThrowsError(try reviewed(raw, input, journey))
    }

    func testSourceChangesInvalidateButCopyEventsAndSavingDoNot() throws {
        var (journey, raw) = try fixture()
        let offer = try reviewed(raw, inputs(offer: raw, journey: journey), journey)
        journey.offers = [offer]
        XCTAssertTrue(try PickupOfferEvaluation.isCurrent(offer: offer, journey: journey))
        journey.offerActions.append(PickupOfferAction(id: UUID(), offerID: offer.id, kind: .copyAttempted, occurredAt: now))
        XCTAssertTrue(try PickupOfferEvaluation.isCurrent(offer: offer, journey: journey))
        journey.needDetails = [PickupNeedDetail(id: journey.needs[0].id, mealName: "Lunch", exclusions: ["Sesame"], scheduledDay: nil, leadTimeMinutes: nil, completedSteps: [])]
        XCTAssertFalse(try PickupOfferEvaluation.isCurrent(offer: offer, journey: journey))
        let stale = try PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: now)
        XCTAssertFalse(stale.isCurrent); XCTAssertNil(stale.replacementMaximum); XCTAssertTrue(stale.issues.contains(.staleSource))
    }

    func testCutoffExpiryDoesNotConfirmFillResponseOrMoneyAndOldOfferDecodes() throws {
        let (journey, raw) = try fixture()
        let offer = try reviewed(raw, inputs(offer: raw, journey: journey), journey)
        let result = try PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: now.addingTimeInterval(60))
        XCTAssertEqual(result.cutoff, .awaitPickup); XCTAssertEqual(offer.retailerResponse, "")
        XCTAssertTrue(journey.pickup!.receipts.isEmpty); XCTAssertTrue(journey.settlement.entries.isEmpty)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any]); object.removeValue(forKey: "evaluation")
        let legacy = try JSONDecoder().decode(PickupOffer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.evaluation); XCTAssertEqual(legacy.id, raw.id)
    }

    @MainActor func testSavedForecastAndEffectiveNoteCeilingSurviveSQLiteAndRejectStaleSaveAndCopy() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ComparisonStore(url: url), model = PickupModel(store: store, clock: { self.now })
        let (template, raw) = try fixture(), line = template.pickup!.orderLines[0]
        let started = await model.start(from: [BasketLine(id: line.id, name: line.name, quantity: line.ordered, expectedCost: .exact(money(1_000)))], shopID: template.id, context: template.context!, plannedNeeds: template.needs)
        XCTAssertTrue(started)
        _ = await model.setQuote(template.quote!, cap: nil); _ = await model.freeze(); _ = await model.reportPlaced()
        let current = try XCTUnwrap(model.journey), offer = try reviewed(raw, inputs(offer: raw, journey: current), current)
        let saved = await model.saveReviewedOffer(offer, journeyID: current.id, original: nil); XCTAssertTrue(saved)
        let action = PickupOfferAction(id: UUID(), offerID: offer.id, kind: .copyAttempted, occurredAt: now)
        let copied = await model.recordReviewedOfferAction(action, offer: offer, journeyID: current.id); XCTAssertTrue(copied)
        try await store.close()
        let reopened = PickupModel(databaseURL: url); await reopened.load()
        let after = try XCTUnwrap(reopened.journey), savedOffer = try XCTUnwrap(after.offers.first)
        XCTAssertEqual(savedOffer, offer); XCTAssertTrue(try PickupOfferEvaluation.isCurrent(offer: savedOffer, journey: after))
        XCTAssertEqual(savedOffer.evaluation?.effectiveNoteCeiling, money(300))
        var edit = savedOffer; edit.householdPreference = "Updated preference"
        edit.evaluation = try PickupOfferEvaluation.review(offer: edit, inputs: edit.evaluation!.inputs, journey: after, at: now)
        _ = await reopened.change { $0.needs.append(AllocationNeed(id: UUID(), orderLineID: line.id, name: "New protected dinner", amount: self.q(1), priority: .protected)) }
        let staleSave = await reopened.saveReviewedOffer(edit, journeyID: current.id, original: savedOffer)
        let staleCopy = await reopened.recordReviewedOfferAction(PickupOfferAction(id: UUID(), offerID: savedOffer.id, kind: .copied, occurredAt: now), offer: savedOffer, journeyID: current.id)
        XCTAssertFalse(staleSave); XCTAssertFalse(staleCopy)
        XCTAssertEqual(reopened.journey?.offers, [savedOffer]); XCTAssertEqual(reopened.journey?.offerActions, [action])
        XCTAssertTrue(reopened.journey!.pickup!.receipts.isEmpty); XCTAssertTrue(reopened.journey!.settlement.entries.isEmpty)
    }
}
