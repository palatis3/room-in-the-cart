import XCTest
@testable import CoreDomain

final class CheckoutTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)
    private let commitments = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var context: CheckoutContext {
        CheckoutContext(storeID: "fictional-store", branchID: "north", mode: .pickup, slot: "Tuesday 5 PM",
                        commitmentsID: commitments, observedAt: time, source: "Shopper-entered quote")
    }

    private func weightResult(other: Int64 = 3400, capCents: Int64 = 3800, rate: Int64 = 200,
                              step: Rational = .one, rounding: WeightChargeRounding = .unknown,
                              fees: [CheckoutFee] = [], tax: CostEvidence = .exact(.zero), complete: Bool = true,
                              eligible: Bool = true, scope: CheckoutScope = .wholeCheckout, discount: Int64 = 0) throws -> CheckoutWeightLimit {
        let variable = CheckoutLine(id: UUID(), name: "Produce", cost: .unknown(reason: "Not weighed"), thresholdEligible: eligible)
        let quote = CheckoutQuote(scope: scope, context: context, pricing: .components(lines: [
            .init(id: UUID(), name: "Other items", cost: .exact(Money(minorUnits: other))), variable
        ], lineSetComplete: complete, fees: fees, discounts: [.init(id: "discount", amount: .exact(Money(minorUnits: discount)), reducesEligibleSubtotal: true)],
        tax: tax, deposits: .exact(.zero)))
        return try CheckoutEngine.maximumWeight(quote: quote, cap: .init(scope: .wholeCheckout, commitmentsID: commitments, amount: .init(minorUnits: capCents)),
            lineID: variable.id, rate: .init(minorUnits: rate), increment: step, rounding: rounding)
    }

    func testUnknownWeightHasMaximumAtRetailerBillingIncrementUnderWholeCap() throws {
        XCTAssertEqual(try weightResult(step: Rational(1,100)), .maximum(weight: try Rational(2), lineCost: .init(minorUnits: 400), checkout: .init(minorUnits: 3800)))
        XCTAssertEqual(try weightResult(other: 3801), .noPositiveIncrement)
        XCTAssertEqual(try weightResult(complete: false), .unresolved)
        XCTAssertEqual(try weightResult(tax: .unknown(reason: "tax")), .unresolved)
        XCTAssertEqual(try weightResult(scope: .item), .unresolved)
        XCTAssertEqual(try weightResult(rate: 0), .unresolved)
        XCTAssertEqual(try weightResult(step: .zero), .unresolved)
    }

    func testInclusiveUnrelatedAndMissingWeighedLineLeaveMaximumUnresolved() throws {
        let item = CheckoutLine(id: UUID(), name: "Produce", cost: .unknown(reason: "Scale"))
        let cap = CheckoutCap(scope: .wholeCheckout, commitmentsID: commitments, amount: .init(minorUnits: 3800))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .components(lines: [item], lineSetComplete: true,
            fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
        func check(_ quote: CheckoutQuote, cap: CheckoutCap?, id: UUID) throws -> CheckoutWeightLimit {
            try CheckoutEngine.maximumWeight(quote: quote, cap: cap, lineID: id, rate: .init(minorUnits: 200), increment: .one, rounding: .unknown)
        }
        XCTAssertEqual(try check(quote, cap: nil, id: item.id), .unresolved)
        XCTAssertEqual(try check(quote, cap: cap, id: UUID()), .unresolved)
        XCTAssertEqual(try check(quote, cap: .init(scope: .wholeCheckout, commitmentsID: UUID(), amount: cap.amount), id: item.id), .unresolved)
        XCTAssertEqual(try check(.init(scope: quote.scope, context: context, pricing: .inclusiveTotal(.exact(cap.amount))), cap: cap, id: item.id), .unresolved)
    }

    func testWeightCeilingRechecksFeeAtActualBilledIncrementAndRetainsDiscount() throws {
        let fee = CheckoutFee(id: "small-order", rule: .waivedAt(threshold: .init(minorUnits: 3500),
            belowThreshold: .exact(.init(minorUnits: 495)), basis: .eligibleItemsAfterEligibleDiscounts))
        // Removing the weighed item incurs the fee and exceeds the cap, yet a larger item weighs in under the waived fee.
        XCTAssertEqual(try weightResult(other: 3400, capCents: 3600, rate: 100, fees: [fee]), .maximum(weight: try Rational(2), lineCost: .init(minorUnits: 200), checkout: .init(minorUnits: 3600)))
        XCTAssertEqual(try weightResult(other: 3400, capCents: 3500, rate: 200, fees: [fee]), .noPositiveIncrement)
        XCTAssertEqual(try weightResult(other: 3400, capCents: 3800, rate: 100, fees: [fee], eligible: false), .noPositiveIncrement)
        XCTAssertEqual(try weightResult(other: 3400, capCents: 3800, rate: 100, fees: [fee], discount: 200), .maximum(weight: try Rational(6), lineCost: .init(minorUnits: 600), checkout: .init(minorUnits: 3800)))
        let first = CheckoutFee(id: "base", rule: .fixed(.exact(.init(minorUnits: 100))))
        let second = CheckoutFee(id: "threshold", rule: .waivedAt(threshold: .init(minorUnits: 950),
            belowThreshold: .exact(.init(minorUnits: 200)), basis: .eligibleItemsBeforeDiscounts))
        // Ten units exceed the cap with the first charge. Nine activates the second charge. Seven fits both.
        XCTAssertEqual(try weightResult(other: 0, capCents: 1000, rate: 100, fees: [first, second]),
            .maximum(weight: try Rational(7), lineCost: .init(minorUnits: 700), checkout: .init(minorUnits: 1000)))
        let unknown = CheckoutFee(id: "?", rule: .fixed(.unknown(reason: "service charge")))
        XCTAssertEqual(try weightResult(fees: [unknown]), .unresolved)
    }

    func testFractionalCentRoundingAndUnknownIncrementRemainExplicit() throws {
        // At 13 cents per unit, a quarter costs 3.25 cents. Six cents covers two quarters only if the line rounds 6.5 down; half-up charges 7.
        let step = try Rational(1,4)
        XCTAssertEqual(try weightResult(other: 0, capCents: 3, rate: 13, step: step, rounding: .nearestCent),
            .maximum(weight: step, lineCost: .init(minorUnits: 3), checkout: .init(minorUnits: 3)))
        XCTAssertEqual(try weightResult(other: 0, capCents: 3, rate: 13, step: step, rounding: .up), .noPositiveIncrement)
        XCTAssertEqual(try weightResult(other: 0, capCents: 6, rate: 13, step: step, rounding: .nearestCent),
            .maximum(weight: step, lineCost: .init(minorUnits: 3), checkout: .init(minorUnits: 3)))
        XCTAssertEqual(try weightResult(other: 0, capCents: 3, rate: 13, step: step), .unresolved)
    }

    func testSharedCheckoutVectors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let fixture = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/checkout.json")))
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(fixture.currency, "USD")
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10)
        for vector in fixture.cases {
            let scope = try XCTUnwrap(CheckoutScope(rawValue: vector.scope))
            let capScope = try XCTUnwrap(CheckoutScope(rawValue: vector.capScope))
            let cap = CheckoutCap(scope: capScope, commitmentsID: commitments, amount: Money(minorUnits: vector.capCents))
            let comparison = try CheckoutEngine.compare(before: quote(vector.before, scope: scope), after: quote(vector.after, scope: scope), cap: cap)
            XCTAssertEqual(comparison.before.total.exact?.minorUnits, vector.expected.beforeCents, vector.id)
            XCTAssertEqual(comparison.after.total.exact?.minorUnits, vector.expected.afterCents, vector.id)
            XCTAssertEqual(comparison.change?.minorUnits, vector.expected.changeCents, vector.id)
            XCTAssertEqual(comparison.after.total.lowerBound.minorUnits, vector.expected.afterLowerCents, vector.id)
            XCTAssertEqual(comparison.after.total.upperBound?.minorUnits, vector.expected.afterUpperCents, vector.id)
            XCTAssertEqual(comparison.after.isWholeCheckoutWithinCap, vector.expected.wholeCheckoutWithinCap, vector.id)
            let status: String, over: Int64?
            switch comparison.after.cap {
            case let .over(_, amount): status = "over"; over = amount.minorUnits
            case .within: status = "within"; over = 0
            case .unresolved: status = "unresolved"; over = nil
            case .scopeMismatch: status = "scopeMismatch"; over = nil
            case .notProvided: status = "notProvided"; over = nil
            }
            XCTAssertEqual(status, vector.expected.capStatus, vector.id)
            XCTAssertEqual(over, vector.expected.overCents, vector.id)
        }
    }

    func testBoundedFeesRequireUpperBoundWithinCap() throws {
        let fee = CheckoutFee(id: "pickup", rule: .fixed(.bounded(lower: Money(minorUnits: 100), upper: Money(minorUnits: 300), reason: "Window quoted")))
        let quote = componentQuote(cents: 3500, fees: [fee])
        let fit = try CheckoutEngine.evaluate(quote, cap: cap(3800))
        XCTAssertEqual(fit.total.lowerBound.minorUnits, 3600)
        XCTAssertEqual(fit.total.upperBound?.minorUnits, 3800)
        XCTAssertNil(fit.total.exact)
        XCTAssertTrue(fit.isWholeCheckoutWithinCap)
        let uncertain = try CheckoutEngine.evaluate(quote, cap: cap(3700))
        XCTAssertEqual(uncertain.cap, .unresolved)
        let over = try CheckoutEngine.evaluate(quote, cap: cap(3599))
        XCTAssertEqual(over.cap, .over(minimumCheckout: Money(minorUnits: 3600), minimumOverage: Money(minorUnits: 1)))
    }

    func testUnknownTaxAndDepositAreNotZero() throws {
        for unknownTax in [true, false] {
            let quote = CheckoutQuote(scope: .wholeCheckout, context: context,
                pricing: .components(lines: [line(1000)], lineSetComplete: true, fees: [], discounts: [],
                                     tax: unknownTax ? .unknown(reason: "Need tax") : .exact(.zero),
                                     deposits: unknownTax ? .exact(.zero) : .unknown(reason: "Need deposit")))
            let result = try CheckoutEngine.evaluate(quote, cap: cap(2000))
            XCTAssertNil(result.total.exact)
            XCTAssertEqual(result.cap, .unresolved)
            XCTAssertFalse(result.uncertainties.isEmpty)
        }
    }

    func testInclusiveTotalUsesItsCompleteBasisOnce() throws {
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 3975))))
        let result = try CheckoutEngine.evaluate(quote, cap: cap(3800))
        XCTAssertEqual(result.total.exact?.minorUnits, 3975)
        XCTAssertEqual(result.cap, .over(minimumCheckout: Money(minorUnits: 3975), minimumOverage: Money(minorUnits: 175)))
    }

    func testThresholdCanUseNetEligibleSubtotalAfterDiscount() throws {
        let discount = CheckoutDiscount(id: "eligible-coupon", amount: .exact(Money(minorUnits: 200)), reducesEligibleSubtotal: true)
        func priced(_ basis: FeeThresholdBasis) -> CheckoutQuote {
            CheckoutQuote(scope: .wholeCheckout, context: context,
                pricing: .components(lines: [line(3600)], lineSetComplete: true,
                    fees: [.init(id: "pickup", rule: .waivedAt(threshold: Money(minorUnits: 3500), belowThreshold: .exact(Money(minorUnits: 495)), basis: basis))],
                    discounts: [discount], tax: .exact(.zero), deposits: .exact(.zero)))
        }
        XCTAssertEqual(try CheckoutEngine.evaluate(priced(.eligibleItemsBeforeDiscounts)).total.exact?.minorUnits, 3400)
        XCTAssertEqual(try CheckoutEngine.evaluate(priced(.eligibleItemsAfterEligibleDiscounts)).total.exact?.minorUnits, 3895)
    }

    func testThresholdUncertaintyPropagatesAndWaiverCanResolveUnknownFee() throws {
        let threshold = CheckoutFee(id: "pickup", rule: .waivedAt(threshold: Money(minorUnits: 3500), belowThreshold: .exact(Money(minorUnits: 495)), basis: .eligibleItemsBeforeDiscounts))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context,
            pricing: .components(lines: [.init(id: UUID(), name: "Weight-priced goods", cost: .bounded(lower: Money(minorUnits: 3400), upper: Money(minorUnits: 3600), reason: "Weight range"))],
                                 lineSetComplete: true, fees: [threshold], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
        let result = try CheckoutEngine.evaluate(quote, cap: cap(3800))
        XCTAssertEqual(result.total.lowerBound.minorUnits, 3400)
        XCTAssertEqual(result.total.upperBound?.minorUnits, 4095)
        XCTAssertEqual(result.cap, .unresolved)
        XCTAssertEqual(result.uncertainties.count, 2)
        let waived = componentQuote(cents: 3500, fees: [.init(id: "pickup", rule: .waivedAt(threshold: Money(minorUnits: 3500), belowThreshold: .unknown(reason: "Fee unknown below threshold"), basis: .eligibleItemsBeforeDiscounts))])
        XCTAssertEqual(try CheckoutEngine.evaluate(waived).total.exact?.minorUnits, 3500)
    }

    func testUnknownDiscountCannotRaiseTheKnownMaximum() throws {
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context,
            pricing: .components(lines: [line(3700)], lineSetComplete: true, fees: [],
                                 discounts: [.init(id: "coupon", amount: .unknown(reason: "Eligibility unconfirmed"), reducesEligibleSubtotal: true)],
                                 tax: .exact(.zero), deposits: .exact(.zero)))
        let result = try CheckoutEngine.evaluate(quote, cap: cap(3800))
        XCTAssertEqual(result.total.lowerBound, .zero)
        XCTAssertEqual(result.total.upperBound?.minorUnits, 3700)
        XCTAssertTrue(result.isWholeCheckoutWithinCap)
        XCTAssertFalse(result.uncertainties.isEmpty)
    }

    func testQuoteComparisonsRequireMatchedStoreSlotAndCommitments() throws {
        let other = CheckoutContext(storeID: "fictional-store", branchID: "south", mode: .pickup, slot: "Tuesday 5 PM",
                                    commitmentsID: commitments, observedAt: time, source: "Manual")
        let second = CheckoutQuote(scope: .wholeCheckout, context: other, pricing: .inclusiveTotal(.exact(Money(minorUnits: 100))))
        XCTAssertThrowsError(try CheckoutEngine.compare(before: componentQuote(cents: 100), after: second))
        let foreignCap = CheckoutCap(scope: .wholeCheckout, commitmentsID: UUID(), amount: Money(minorUnits: 3800))
        XCTAssertEqual(try CheckoutEngine.evaluate(componentQuote(cents: 100), cap: foreignCap).cap, .scopeMismatch)
    }

    func testDuplicateLinesNegativeEvidenceAndOverflowFail() throws {
        let repeated = line(100)
        let duplicates = CheckoutQuote(scope: .wholeCheckout, context: context,
            pricing: .components(lines: [repeated, repeated], lineSetComplete: true, fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
        XCTAssertThrowsError(try CheckoutEngine.evaluate(duplicates))
        XCTAssertThrowsError(try CheckoutEngine.evaluate(componentQuote(cents: -1)))
        let overflow = componentQuote(cents: Int64.max, fees: [.init(id: "one", rule: .fixed(.exact(Money(minorUnits: 1))))])
        XCTAssertThrowsError(try CheckoutEngine.evaluate(overflow))
    }

    func testRetainedOriginalConsumesLineCeilingAndJointOffersCanExceedCap() throws {
        XCTAssertEqual(try CheckoutEngine.replacementCeiling(lineAllowance: Money(minorUnits: 101), retainedOriginalCharge: Money(minorUnits: 40), wholeCheckoutRemaining: Money(minorUnits: 500))?.minorUnits, 61)
        XCTAssertEqual(try CheckoutEngine.replacementCeiling(lineAllowance: Money(minorUnits: 101), retainedOriginalCharge: Money(minorUnits: 40), wholeCheckoutRemaining: Money(minorUnits: 50))?.minorUnits, 50)
        XCTAssertNil(try CheckoutEngine.replacementCeiling(lineAllowance: Money(minorUnits: 101), retainedOriginalCharge: .zero, wholeCheckoutRemaining: nil))
        // Each offer fits the 100-cent headroom alone; together they exceed it by 65.
        let first = componentQuote(cents: 3780), second = componentQuote(cents: 3785)
        XCTAssertTrue(try CheckoutEngine.evaluate(first, cap: cap(3800)).isWholeCheckoutWithinCap)
        XCTAssertTrue(try CheckoutEngine.evaluate(second, cap: cap(3800)).isWholeCheckoutWithinCap)
        let joint = componentQuote(cents: 3865)
        XCTAssertEqual(try CheckoutEngine.evaluate(joint, cap: cap(3800)).cap,
                       .over(minimumCheckout: Money(minorUnits: 3865), minimumOverage: Money(minorUnits: 65)))
    }

    func testApplyRetryStaleProposalAndChangedReplayDoNotDuplicateOrMutate() throws {
        let original = try basketLine("Wraps", quantity: 8)
        var plan = try BasketPlan(id: UUID(), revisionID: UUID(), lines: [original], createdAt: time)
        let changed = BasketLine(id: original.id, name: original.name, quantity: try quantity(16), expectedCost: .exact(Money(minorUnits: 698)))
        let proposal = BasketProposal(id: UUID(), baseRevisionID: plan.current.id, revisionID: UUID(), changes: [.upsert(changed)])
        let applied = try plan.apply(proposal, at: time)
        XCTAssertEqual(try plan.apply(proposal, at: time.addingTimeInterval(30)), applied)
        XCTAssertEqual(plan.revisions.count, 2)
        let before = plan
        let stale = BasketProposal(id: UUID(), baseRevisionID: proposal.baseRevisionID, revisionID: UUID(), changes: [.remove(original.id)])
        XCTAssertThrowsError(try plan.apply(stale, at: time))
        let mismatch = BasketProposal(id: proposal.id, baseRevisionID: proposal.baseRevisionID, revisionID: proposal.revisionID, changes: [.remove(original.id)])
        XCTAssertThrowsError(try plan.apply(mismatch, at: time))
        XCTAssertEqual(plan, before)
    }

    func testUndoRestoresOnlyAffectedLinesAndIsCompensatingRevision() throws {
        let tortillas = try basketLine("Wraps", quantity: 8), staple = try basketLine("Coffee", quantity: 1)
        var plan = try BasketPlan(id: UUID(), revisionID: UUID(), lines: [tortillas, staple], createdAt: time)
        let remove = BasketProposal(id: UUID(), baseRevisionID: plan.current.id, revisionID: UUID(), changes: [.remove(tortillas.id)])
        try plan.apply(remove, at: time)
        let changedStaple = BasketLine(id: staple.id, name: staple.name, quantity: try quantity(2), expectedCost: .exact(Money(minorUnits: 800)))
        try plan.apply(.init(id: UUID(), baseRevisionID: plan.current.id, revisionID: UUID(), changes: [.upsert(changedStaple)]), at: time)
        let base = plan.current.id, operation = UUID(), revision = UUID()
        let undone = try plan.undo(operationID: operation, proposalID: remove.id, expectedRevision: base, revisionID: revision, at: time)
        XCTAssertEqual(undone.lines, [tortillas, changedStaple])
        XCTAssertEqual(undone.number, 4)
        XCTAssertEqual(try plan.undo(operationID: operation, proposalID: remove.id, expectedRevision: base, revisionID: revision, at: time), undone)
        XCTAssertEqual(plan.revisions.count, 4)
        XCTAssertThrowsError(try plan.undo(operationID: UUID(), proposalID: remove.id, expectedRevision: plan.current.id, revisionID: UUID(), at: time))
        XCTAssertEqual(try JSONDecoder().decode(BasketPlan.self, from: JSONEncoder().encode(plan)), plan)
    }

    func testUndoRejectsInterveningChangeToAffectedLine() throws {
        let original = try basketLine("Wraps", quantity: 8)
        var plan = try BasketPlan(id: UUID(), revisionID: UUID(), lines: [original], createdAt: time)
        let first = BasketProposal(id: UUID(), baseRevisionID: plan.current.id, revisionID: UUID(), changes: [.remove(original.id)])
        try plan.apply(first, at: time)
        try plan.apply(.init(id: UUID(), baseRevisionID: plan.current.id, revisionID: UUID(), changes: [.upsert(original)]), at: time)
        let before = plan
        XCTAssertThrowsError(try plan.undo(operationID: UUID(), proposalID: first.id, expectedRevision: plan.current.id, revisionID: UUID(), at: time))
        XCTAssertEqual(plan, before)
    }

    func testCopyCancelOpenAndIntentionalSendDoNotReportPlacement() throws {
        var plan = try BasketPlan(id: UUID(), revisionID: UUID(), lines: [basketLine("Wraps", quantity: 8)], createdAt: time)
        let snapshot = try plan.freeze(snapshotID: UUID(), expectedRevision: plan.current.id, at: time)
        for kind in [HandoffActionKind.prepared, .copyAttempted, .copied, .shareOpened, .shareCancelled, .retailerOpened, .intentionallySent] {
            let action = HandoffAction(id: UUID(), snapshotID: snapshot.id, kind: kind, occurredAt: time)
            XCTAssertTrue(try plan.recordHandoff(action))
            XCTAssertFalse(try plan.recordHandoff(action))
        }
        XCTAssertEqual(plan.phase, .frozen)
        XCTAssertTrue(plan.placements.isEmpty)
        XCTAssertNil(plan.reportedOrderLines)
        XCTAssertEqual(plan.snapshots, [snapshot])
        XCTAssertEqual(try JSONDecoder().decode(BasketPlan.self, from: JSONEncoder().encode(plan)), plan)
    }

    func testPlacementSealsOriginalAndConfirmedAmendmentIsSeparate() throws {
        let original = try basketLine("Wraps", quantity: 8)
        var plan = try BasketPlan(id: UUID(), revisionID: UUID(), lines: [original], createdAt: time)
        let snapshot = try plan.freeze(snapshotID: UUID(), expectedRevision: plan.current.id, at: time)
        let placement = ReportedPlacement(id: UUID(), intentID: UUID(), snapshotID: snapshot.id, reportedAt: time)
        XCTAssertTrue(try plan.reportPlaced(placement))
        XCTAssertFalse(try plan.reportPlaced(placement))
        XCTAssertEqual(plan.phase, .reportedPlaced)
        XCTAssertThrowsError(try plan.reportPlaced(.init(id: UUID(), intentID: placement.intentID, snapshotID: snapshot.id, reportedAt: time)))
        XCTAssertThrowsError(try plan.apply(.init(id: UUID(), baseRevisionID: plan.current.id, revisionID: UUID(), changes: [.remove(original.id)]), at: time))
        let substitute = try basketLine("Confirmed substitute", quantity: 6)
        let amendment = ConfirmedAmendment(id: UUID(), placementID: placement.id, previousAmendmentID: nil,
                                           lines: [substitute], confirmedAt: time, retailerReference: "Retailer message 123")
        XCTAssertTrue(try plan.confirmAmendment(amendment))
        XCTAssertFalse(try plan.confirmAmendment(amendment))
        XCTAssertEqual(plan.reportedOrderLines, [original])
        XCTAssertEqual(plan.effectiveOrderLines, [substitute])
        XCTAssertEqual(plan.snapshots.first, snapshot)
        XCTAssertEqual(plan.revisions.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(BasketPlan.self, from: JSONEncoder().encode(plan)), plan)
    }

    func testOldSnapshotCannotPlaceEditedBasket() throws {
        let original = try basketLine("Wraps", quantity: 8)
        var plan = try BasketPlan(id: UUID(), revisionID: UUID(), lines: [original], createdAt: time)
        let old = try plan.freeze(snapshotID: UUID(), expectedRevision: plan.current.id, at: time)
        try plan.apply(.init(id: UUID(), baseRevisionID: plan.current.id, revisionID: UUID(), changes: [.remove(original.id)]), at: time)
        XCTAssertEqual(plan.phase, .draft)
        XCTAssertThrowsError(try plan.reportPlaced(.init(id: UUID(), intentID: UUID(), snapshotID: old.id, reportedAt: time)))
        XCTAssertEqual(plan.snapshots.first?.revision.lines, [original])
        XCTAssertTrue(plan.placements.isEmpty)
    }

    func testMalformedBasketArchiveRejectsEmptyHistoryAndFabricatedRevision() throws {
        let plan = try BasketPlan(id: UUID(), revisionID: UUID(), lines: [basketLine("Wraps", quantity: 8)], createdAt: time)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        object["revisions"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(BasketPlan.self, from: JSONSerialization.data(withJSONObject: object)))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var revisions = try XCTUnwrap(object["revisions"] as? [[String: Any]])
        revisions[0]["number"] = 99
        object["revisions"] = revisions
        XCTAssertThrowsError(try JSONDecoder().decode(BasketPlan.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    private func line(_ cents: Int64) -> CheckoutLine { .init(id: UUID(), name: "Goods", cost: .exact(Money(minorUnits: cents))) }
    private func cap(_ cents: Int64) -> CheckoutCap { .init(scope: .wholeCheckout, commitmentsID: commitments, amount: Money(minorUnits: cents)) }
    private func componentQuote(cents: Int64, fees: [CheckoutFee] = []) -> CheckoutQuote {
        .init(scope: .wholeCheckout, context: context, pricing: .components(lines: [line(cents)], lineSetComplete: true,
                                                                          fees: fees, discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
    }
    private func quantity(_ amount: Int64) throws -> Quantity { Quantity(amount: try Rational(amount), unit: .count, originalLiteral: "\(amount)") }
    private func basketLine(_ name: String, quantity amount: Int64) throws -> BasketLine {
        BasketLine(id: UUID(), name: name, quantity: try quantity(amount), expectedCost: .exact(Money(minorUnits: 349)))
    }
    private func quote(_ input: VectorQuote, scope: CheckoutScope) -> CheckoutQuote {
        func cost(_ cents: Int64?) -> CostEvidence { cents.map { .exact(Money(minorUnits: $0)) } ?? .unknown(reason: "Missing fixture evidence") }
        let fee: CheckoutFeeRule = input.fee.kind == "threshold"
            ? .waivedAt(threshold: Money(minorUnits: input.fee.thresholdCents!), belowThreshold: cost(input.fee.belowThresholdCents), basis: .eligibleItemsBeforeDiscounts)
            : .fixed(cost(input.fee.cents))
        return .init(scope: scope, context: context,
            pricing: .components(lines: input.lines.map { .init(id: UUID(), name: $0.id, cost: cost($0.cents), thresholdEligible: $0.eligible) },
                                 lineSetComplete: input.complete, fees: [.init(id: "fee", rule: fee)],
                                 discounts: [.init(id: "discount", amount: cost(input.discountCents), reducesEligibleSubtotal: true)],
                                 tax: cost(input.taxCents), deposits: cost(input.depositCents)))
    }
    private struct Contract: Decodable { let version: Int; let currency: String; let cases: [Vector] }
    private struct Vector: Decodable {
        let id: String; let scope: String; let capScope: String; let capCents: Int64
        let before: VectorQuote; let after: VectorQuote; let expected: Expected
    }
    private struct VectorQuote: Decodable {
        struct Line: Decodable { let id: String; let cents: Int64?; let eligible: Bool }
        struct Fee: Decodable { let kind: String; let cents: Int64?; let thresholdCents: Int64?; let belowThresholdCents: Int64? }
        let lines: [Line]; let complete: Bool; let fee: Fee
        let discountCents: Int64?; let taxCents: Int64?; let depositCents: Int64?
    }
    private struct Expected: Decodable {
        let beforeCents: Int64?; let afterCents: Int64?; let changeCents: Int64?
        let afterLowerCents: Int64; let afterUpperCents: Int64?; let capStatus: String
        let overCents: Int64?; let wholeCheckoutWithinCap: Bool
    }
}
