import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

final class PickupCheckoutDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let shopID = UUID(), lineID = UUID()
    private func money(_ cents: Int64) -> Money { Money(minorUnits: cents) }
    private func context() -> CheckoutContext {
        CheckoutContext(storeID: "Market", branchID: "Main", mode: .pickup, slot: "Tuesday 5 PM",
                        commitmentsID: shopID, observedAt: now, source: "Reviewed retailer preview")
    }
    private func line() -> BasketLine {
        BasketLine(id: lineID, name: "Wraps", quantity: Quantity(amount: try! Rational(2), unit: .count, originalLiteral: "2"),
                   expectedCost: .exact(money(999)))
    }
    private func journey(_ pricing: CheckoutPricing, scope: CheckoutScope = .wholeCheckout,
                         cap: CheckoutCap? = nil) throws -> PickupJourney {
        var value = PickupJourney(id: shopID, savedAt: now)
        value.basket = try BasketPlan(id: shopID, revisionID: UUID(), lines: [line()], createdAt: now)
        value.context = context(); value.cap = cap
        value.quote = CheckoutQuote(scope: scope, context: context(), pricing: pricing)
        value.quotedRevisionID = value.basket?.current.id
        return value
    }

    func testInclusiveHydrationKeepsQuoteAndCapScopesAndCommitmentsIndependent() throws {
        let cap = CheckoutCap(scope: .item, commitmentsID: UUID(), amount: money(5000))
        let value = try journey(.inclusiveTotal(.exact(money(300))), scope: .dinner, cap: cap)
        let draft = PickupCheckoutDraft(journey: value)
        XCTAssertTrue(draft.inclusive)
        XCTAssertEqual(draft.total, "3")
        XCTAssertEqual(draft.scope, .dinner)
        XCTAssertEqual(draft.capScope, .item)
        let saved = try draft.submission(for: value)
        XCTAssertEqual(saved.quote, value.quote)
        XCTAssertEqual(saved.cap, cap)
        let noCap = try journey(.inclusiveTotal(.exact(.zero)), scope: .item)
        XCTAssertEqual(try PickupCheckoutDraft(journey: noCap).submission(for: noCap).quote, noCap.quote)
    }

    func testComponentHydrationUsesSavedQuoteCostsAndEveryEditableCharge() throws {
        let pricing = CheckoutPricing.components(
            lines: [CheckoutLine(id: lineID, name: "Wraps", cost: .exact(money(3480)))], lineSetComplete: false,
            fees: [CheckoutFee(id: "saved-delivery-fee", rule: .waivedAt(threshold: money(3500), belowThreshold: .exact(money(495)), basis: .eligibleItemsAfterEligibleDiscounts))],
            discounts: [CheckoutDiscount(id: "saved-coupon", amount: .exact(money(125)), reducesEligibleSubtotal: true)],
            tax: .exact(money(28)), deposits: .exact(money(10)))
        let value = try journey(pricing)
        let draft = PickupCheckoutDraft(journey: value)
        XCTAssertFalse(draft.inclusive); XCTAssertFalse(draft.complete)
        XCTAssertEqual(draft.prices[lineID], "34.8") // The basket still says $9.99.
        XCTAssertEqual(draft.fee, "4.95"); XCTAssertEqual(draft.threshold, "35")
        XCTAssertEqual(draft.discount, "1.25"); XCTAssertEqual(draft.tax, "0.28"); XCTAssertEqual(draft.deposits, "0.1")
        XCTAssertEqual(try draft.submission(for: value).quote, value.quote)
    }

    func testEditingOnePricePreservesOtherUnknownReasonsAndRuleIdentities() throws {
        let fees = [CheckoutFee(id: "branch-fee", rule: .waivedAt(threshold: money(3500), belowThreshold: .unknown(reason: "Await branch fee"), basis: .eligibleItemsAfterEligibleDiscounts))]
        let discounts = [CheckoutDiscount(id: "coupon-source", amount: .unknown(reason: "Check coupon terms"), reducesEligibleSubtotal: true)]
        let value = try journey(.components(lines: [CheckoutLine(id: lineID, name: "Wraps", cost: .unknown(reason: "Need shelf photo"))],
            lineSetComplete: false, fees: fees, discounts: discounts, tax: .unknown(reason: "Tax not supplied"), deposits: .exact(.zero)))
        var draft = PickupCheckoutDraft(journey: value)
        XCTAssertFalse(draft.pricingNeedsReplacement)
        draft.prices[lineID] = "6.25"
        let saved = try draft.submission(for: value)
        guard case let .components(lines, complete, actualFees, actualDiscounts, tax, deposits) = saved.quote.pricing else { return XCTFail("Expected components") }
        XCTAssertEqual(lines, [CheckoutLine(id: lineID, name: "Wraps", cost: .exact(money(625)))])
        XCTAssertFalse(complete); XCTAssertEqual(actualFees, fees); XCTAssertEqual(actualDiscounts, discounts)
        XCTAssertEqual(tax, .unknown(reason: "Tax not supplied")); XCTAssertEqual(deposits, .exact(.zero))
    }

    func testEditingPriceDoesNotInventMissingFeesOrDiscounts() throws {
        let value = try journey(.components(lines: [CheckoutLine(id: lineID, name: "Wraps", cost: .exact(money(200)))],
            lineSetComplete: true, fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
        var draft = PickupCheckoutDraft(journey: value)
        XCTAssertEqual(draft.fee, "0"); XCTAssertEqual(draft.discount, "0")
        draft.prices[lineID] = "3"
        guard case let .components(_, _, fees, discounts, _, _) = try draft.submission(for: value).quote.pricing else { return XCTFail("Expected components") }
        XCTAssertTrue(fees.isEmpty); XCTAssertTrue(discounts.isEmpty)
    }

    func testRichPricingRoundTripsAndRequiresExplicitReplacementBeforeScalarEdits() throws {
        let rich = CheckoutPricing.components(
            lines: [CheckoutLine(id: lineID, name: "Imported wraps", cost: .bounded(lower: money(300), upper: money(500), reason: "Weight varies"), thresholdEligible: false)],
            lineSetComplete: false,
            fees: [CheckoutFee(id: "delivery", rule: .waivedAt(threshold: money(3500), belowThreshold: .exact(money(495)), basis: .eligibleItemsBeforeDiscounts)),
                   CheckoutFee(id: "service", rule: .fixed(.unknown(reason: "Service rate pending")))],
            discounts: [CheckoutDiscount(id: "coupon", amount: .exact(money(100)), reducesEligibleSubtotal: false),
                        CheckoutDiscount(id: "loyalty", amount: .bounded(lower: .zero, upper: money(200), reason: "Eligibility pending"), reducesEligibleSubtotal: true)],
            tax: .unknown(reason: "Tax pending"), deposits: .exact(.zero))
        for pricing in [rich, .inclusiveTotal(.bounded(lower: money(300), upper: money(450), reason: "Retailer range"))] {
            let value = try journey(pricing)
            var draft = PickupCheckoutDraft(journey: value)
            XCTAssertTrue(draft.pricingNeedsReplacement)
            XCTAssertEqual(try draft.submission(for: value).quote, value.quote)
            draft.total = "7"
            XCTAssertThrowsError(try draft.submission(for: value)) { error in
                XCTAssertEqual(error as? PickupCheckoutDraftError, .reviewReplacement)
            }
            draft.beginPricingReplacement()
            XCTAssertFalse(draft.pricingNeedsReplacement)
            XCTAssertEqual(draft.originalPricing, pricing)
            XCTAssertTrue(draft.prices.isEmpty); XCTAssertFalse(draft.complete)
            draft.inclusive = true; draft.total = "7"
            XCTAssertEqual(try draft.submission(for: value).quote.pricing, .inclusiveTotal(.exact(money(700))))
            XCTAssertEqual(value.quote?.pricing, pricing)
        }
    }

    func testUnknownInclusiveReasonAndObservedZeroRemainDistinct() throws {
        let cases: [CostEvidence] = [.unknown(reason: "Retailer has not confirmed charges"), .exact(.zero)]
        for evidence in cases {
            let value = try journey(.inclusiveTotal(evidence))
            let draft = PickupCheckoutDraft(journey: value)
            XCTAssertEqual(draft.total, evidence == .exact(.zero) ? "0" : "")
            XCTAssertEqual(try draft.submission(for: value).quote, value.quote)
        }
    }

    func testEachUnsupportedComponentShapeRequiresReviewBeforeReplacement() throws {
        let normal = CheckoutLine(id: lineID, name: "Wraps", cost: .exact(money(300)))
        let fee = CheckoutFee(id: "delivery", rule: .fixed(.exact(money(100))))
        let discount = CheckoutDiscount(id: "coupon", amount: .exact(.zero), reducesEligibleSubtotal: true)
        let cases: [CheckoutPricing] = [
            .components(lines: [CheckoutLine(id: lineID, name: "Wraps", cost: normal.cost, thresholdEligible: false)], lineSetComplete: true, fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)),
            .components(lines: [normal], lineSetComplete: true, fees: [CheckoutFee(id: "delivery", rule: .waivedAt(threshold: money(3500), belowThreshold: .exact(money(100)), basis: .eligibleItemsBeforeDiscounts))], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)),
            .components(lines: [normal], lineSetComplete: true, fees: [fee, CheckoutFee(id: "service", rule: .fixed(.exact(.zero)))], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)),
            .components(lines: [normal], lineSetComplete: true, fees: [], discounts: [discount, CheckoutDiscount(id: "loyalty", amount: .exact(.zero), reducesEligibleSubtotal: true)], tax: .exact(.zero), deposits: .exact(.zero)),
            .components(lines: [normal], lineSetComplete: true, fees: [], discounts: [CheckoutDiscount(id: "coupon", amount: .exact(.zero), reducesEligibleSubtotal: false)], tax: .exact(.zero), deposits: .exact(.zero)),
            .components(lines: [normal], lineSetComplete: true, fees: [], discounts: [], tax: .bounded(lower: .zero, upper: money(100), reason: "Tax estimate"), deposits: .exact(.zero)),
            .components(lines: [], lineSetComplete: false, fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)),
        ]
        for pricing in cases {
            let value = try journey(pricing)
            var draft = PickupCheckoutDraft(journey: value)
            XCTAssertTrue(draft.pricingNeedsReplacement)
            XCTAssertEqual(try draft.submission(for: value).quote.pricing, pricing)
            draft.prices[lineID] = "4"
            XCTAssertThrowsError(try draft.submission(for: value))
        }
    }

    func testUnchangedLargeMoneyDoesNotRequireReparsingThroughTheEntryParser() throws {
        let maximum = money(Int64.max)
        let value = try journey(.components(lines: [CheckoutLine(id: lineID, name: "Wraps", cost: .exact(money(300)))],
            lineSetComplete: true, fees: [CheckoutFee(id: "delivery", rule: .waivedAt(threshold: maximum, belowThreshold: .exact(.zero), basis: .eligibleItemsAfterEligibleDiscounts))],
            discounts: [], tax: .exact(.zero), deposits: .exact(.zero)),
            cap: CheckoutCap(scope: .wholeCheckout, commitmentsID: shopID, amount: maximum))
        var draft = PickupCheckoutDraft(journey: value)
        XCTAssertEqual(try draft.submission(for: value).cap, value.cap)
        draft.prices[lineID] = "4"
        let saved = try draft.submission(for: value)
        XCTAssertEqual(saved.cap, value.cap)
        guard case let .components(_, _, fees, _, _, _) = saved.quote.pricing else { return XCTFail("Expected components") }
        XCTAssertEqual(fees, [CheckoutFee(id: "delivery", rule: .waivedAt(threshold: maximum, belowThreshold: .exact(.zero), basis: .eligibleItemsAfterEligibleDiscounts))])
    }

    func testStaleQuoteDoesNotHydrateAndChangedSourceCannotBeOverwritten() throws {
        var value = try journey(.inclusiveTotal(.exact(money(300))))
        value.quotedRevisionID = UUID()
        let stale = PickupCheckoutDraft(journey: value)
        XCTAssertFalse(stale.hasSavedPricing); XCTAssertFalse(stale.inclusive)
        XCTAssertEqual(stale.prices[lineID], "9.99")
        let current = try journey(.inclusiveTotal(.exact(money(400))))
        let draft = PickupCheckoutDraft(journey: current)
        var changed = current
        changed.basket = try BasketPlan(id: shopID, revisionID: UUID(), lines: [line()], createdAt: now)
        XCTAssertThrowsError(try draft.submission(for: changed))
        changed = current
        changed.quote = CheckoutQuote(scope: .wholeCheckout, context: context(), pricing: .inclusiveTotal(.exact(money(500))))
        XCTAssertThrowsError(try draft.submission(for: changed))
    }

    func testDirtyDraftKeepsEditsAndOriginalDisplayLinesWhenBasketRevisionChanges() throws {
        let value = try journey(.components(lines: [CheckoutLine(id: lineID, name: "Wraps", cost: .exact(money(300)))],
            lineSetComplete: true, fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
        var draft = PickupCheckoutDraft(journey: value)
        draft.store = "Unsaved market"; draft.source = "Unsaved source"
        draft.prices[lineID] = "4"; draft.cap = "9"; draft.capScope = .dinner
        var changed = value
        let newLine = BasketLine(id: UUID(), name: "New basket milk", quantity: line().quantity, expectedCost: .exact(money(500)))
        changed.basket = try BasketPlan(id: shopID, revisionID: UUID(), lines: [newLine], createdAt: now)
        changed.quote = nil; changed.quotedRevisionID = nil
        XCTAssertTrue(draft.hasUnsavedChanges)
        XCTAssertFalse(draft.refreshIfPristine(from: changed))
        XCTAssertEqual(draft.basketRevisionID, value.basket?.current.id)
        XCTAssertEqual(draft.displayLines, [line()])
        XCTAssertEqual(draft.store, "Unsaved market"); XCTAssertEqual(draft.source, "Unsaved source")
        XCTAssertEqual(draft.prices[lineID], "4"); XCTAssertEqual(draft.cap, "9"); XCTAssertEqual(draft.capScope, .dinner)
        XCTAssertThrowsError(try draft.submission(for: changed)) { error in
            XCTAssertEqual(error as? PickupCheckoutDraftError, .staleSource)
        }
    }

    func testDirtyDraftCannotFollowAnotherSelectedPickupAndCanReturnToItsOriginalSource() throws {
        let value = try journey(.inclusiveTotal(.exact(money(300))))
        var draft = PickupCheckoutDraft(journey: value); draft.total = "4"
        let other = PickupJourney(id: UUID(), savedAt: now)
        XCTAssertFalse(draft.refreshIfPristine(from: other))
        XCTAssertEqual(draft.journeyID, value.id); XCTAssertEqual(draft.total, "4")
        XCTAssertFalse(draft.matchesSource(other))
        XCTAssertThrowsError(try draft.submission(for: other))
        XCTAssertTrue(draft.matchesSource(value))
        XCTAssertFalse(draft.refreshIfPristine(from: value))
        XCTAssertEqual(try draft.submission(for: value).quote.pricing, .inclusiveTotal(.exact(money(400))))
    }

    func testPristineDraftRefreshesForRevisionSelectionAndSavedSourceChanges() throws {
        let value = try journey(.inclusiveTotal(.exact(money(300))))
        var revised = value
        revised.basket = try BasketPlan(id: shopID, revisionID: UUID(), lines: [line()], createdAt: now)
        revised.quote = nil; revised.quotedRevisionID = nil
        var selected = PickupJourney(id: UUID(), savedAt: now)
        selected.basket = try BasketPlan(id: selected.id, revisionID: UUID(), lines: [line()], createdAt: now)
        var sourceChanged = value
        sourceChanged.context = CheckoutContext(storeID: "Updated market", branchID: "New branch", mode: .delivery,
            slot: "Wednesday", commitmentsID: shopID, observedAt: now, source: "Updated source")
        sourceChanged.quote = CheckoutQuote(scope: .item, context: try XCTUnwrap(sourceChanged.context), pricing: .inclusiveTotal(.exact(money(500))))
        sourceChanged.cap = CheckoutCap(scope: .dinner, commitmentsID: shopID, amount: money(900))
        for changed in [revised, selected, sourceChanged] {
            var draft = PickupCheckoutDraft(journey: value)
            XCTAssertFalse(draft.hasUnsavedChanges)
            XCTAssertTrue(draft.refreshIfPristine(from: changed))
            XCTAssertTrue(draft.matchesSource(changed)); XCTAssertFalse(draft.hasUnsavedChanges)
            XCTAssertEqual(draft.journeyID, changed.id); XCTAssertEqual(draft.basketRevisionID, changed.basket?.current.id)
            XCTAssertEqual(draft.displayLines, changed.basket?.current.lines)
        }
    }

    func testEverySourcePricingAndCapEditPreventsAutomaticRefresh() throws {
        let value = try journey(.inclusiveTotal(.exact(money(300))))
        let changed = try journey(.inclusiveTotal(.exact(money(500))))
        let edits: [(inout PickupCheckoutDraft) -> Void] = [
            { $0.store += " edit" }, { $0.branch += " edit" }, { $0.slot += " edit" }, { $0.source += " edit" },
            { $0.observed = $0.observed.addingTimeInterval(60) }, { $0.mode = .delivery },
            { $0.scope = .item }, { $0.capScope = .dinner }, { $0.cap = "9" },
            { $0.inclusive = false }, { $0.total = "4" }, { $0.prices[self.lineID] = "5" },
            { $0.fee = "1" }, { $0.threshold = "35" }, { $0.discount = "1" },
            { $0.tax = "1" }, { $0.deposits = "1" }, { $0.complete = false }, { $0.beginPricingReplacement() },
        ]
        for edit in edits {
            var draft = PickupCheckoutDraft(journey: value)
            edit(&draft)
            XCTAssertTrue(draft.hasUnsavedChanges)
            XCTAssertFalse(draft.refreshIfPristine(from: changed))
            XCTAssertFalse(draft.matchesSource(changed))
        }
    }

    func testScreenPrivateReviewBlocksRefreshUntilExplicitDiscard() throws {
        let value = try journey(.inclusiveTotal(.exact(money(300))))
        let changed = try journey(.inclusiveTotal(.exact(money(500))))
        var draft = PickupCheckoutDraft(journey: value)
        // The view supplies this flag for selected deferrals, their preview, or
        // any hold/funds entry; none of these fields becomes persisted evidence.
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertFalse(draft.refreshIfPristine(from: changed, hasLocalReview: true))
        XCTAssertTrue(draft.matchesSource(value)); XCTAssertFalse(draft.matchesSource(changed))
        XCTAssertThrowsError(try draft.submission(for: changed))
        XCTAssertTrue(draft.refreshIfPristine(from: changed, hasLocalReview: false))
        XCTAssertTrue(draft.matchesSource(changed))
    }

    @MainActor func testUnchangedEditorSavePreservesInclusiveAndComponentQuotesThroughTwoRestarts() async throws {
        let component = CheckoutPricing.components(lines: [CheckoutLine(id: lineID, name: "Wraps", cost: .exact(money(3480)))],
            lineSetComplete: true, fees: [CheckoutFee(id: "retailer-fee", rule: .fixed(.exact(money(495))))],
            discounts: [CheckoutDiscount(id: "eligible-discount", amount: .exact(.zero), reducesEligibleSubtotal: true)],
            tax: .exact(.zero), deposits: .exact(.zero))
        for pricing in [CheckoutPricing.inclusiveTotal(.exact(money(300))), component] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("pickup.sqlite")
            let store = try ComparisonStore(url: url), first = PickupModel(store: store, clock: { self.now })
            let started = await first.start(from: [line()], shopID: shopID, context: context())
            XCTAssertTrue(started)
            let quote = CheckoutQuote(scope: .dinner, context: context(), pricing: pricing)
            let cap = CheckoutCap(scope: .item, commitmentsID: UUID(), amount: money(5000))
            let saved = await first.setQuote(quote, cap: cap); XCTAssertTrue(saved)
            let result = first.result
            try await store.close()
            let secondStore = try ComparisonStore(url: url), second = PickupModel(store: secondStore, clock: { self.now })
            await second.load()
            let reopened = try XCTUnwrap(second.journey)
            let edit = try PickupCheckoutDraft(journey: reopened).submission(for: reopened)
            let savedAgain = await second.setQuote(edit.quote, cap: edit.cap); XCTAssertTrue(savedAgain)
            try await secondStore.close()
            let thirdStore = try ComparisonStore(url: url), third = PickupModel(store: thirdStore)
            await third.load()
            XCTAssertEqual(third.journey?.quote, quote); XCTAssertEqual(third.journey?.cap, cap)
            XCTAssertEqual(third.result, result)
            try await thirdStore.close()
        }
    }
}
