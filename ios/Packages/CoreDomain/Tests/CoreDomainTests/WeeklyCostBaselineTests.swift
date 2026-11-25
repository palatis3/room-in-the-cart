import XCTest
@testable import CoreDomain

final class WeeklyCostBaselineTests: XCTestCase {
    func testPairedQuoteCoverageNeedsTheSameQuantifiedItemAtBothStores() throws {
        let beans = UUID(), rice = UUID(), setID = UUID()
        func option(_ name: String, item: UUID, product: String, required: Int64) -> StoreQuoteOption {
            let set = DinnerCommitmentSet(id: setID, commitments: [.init(id: item, name: product, kind: .staple, portions: .one)])
            let context = CheckoutContext(storeID: name, branchID: name, mode: .pickup, slot: "AM", commitmentsID: setID,
                                          observedAt: Date(), source: "Entered", currency: .usd)
            let pricing = CheckoutPricing.components(lines: [.init(id: item, name: product, cost: .exact(.init(minorUnits: 300)))],
                lineSetComplete: true, fees: [], discounts: [], tax: .exact(.zero), deposits: .exact(.zero))
            return .init(label: name, commitments: set, quote: .init(scope: .wholeCheckout, context: context, pricing: pricing),
                         available: true, quantitiesMatched: true, trip: .init(incrementalCash: .exact(.zero), extraMinutes: 0, tripAlreadyPlanned: true),
                         supplies: [.init(commitmentID: item, unit: .gram, requiredUnits: required, usableUnitsPerPackage: 500, packages: 2)])
        }
        let first = option("A", item: beans, product: "Beans", required: 750)
        func compare(_ other: StoreQuoteOption) throws -> (matched: Int, total: Int?) {
            let pair = TwoStoreQuotePair(shopID: UUID(), baseRevisionID: UUID(), basisRevision: 0, first: first, second: other)
            try pair.validate()
            return try XCTUnwrap(pair.pairedItemCoverage)
        }
        let disjoint = try compare(option("B", item: rice, product: "Rice", required: 750))
        XCTAssertEqual(disjoint.matched, 0)
        XCTAssertEqual(disjoint.total, 2)
        XCTAssertEqual(try compare(option("B", item: beans, product: "Beans", required: 1000)).matched, 0)
        XCTAssertEqual(try compare(option("B", item: beans, product: "Beans", required: 750)).matched, 1)
    }

    func testExplicitOrderMatchSurvivesCorrectionAndSplitHasNoAllocatedLinePrice() throws {
        let amount = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        var shop = ShoppingLedger()
        let a = try shop.addManualLine(name: "Peppers", quantity: amount)
        let b = try shop.addManualLine(name: "Lunch peppers", quantity: one)
        let snapshot = try WeeklyCostBaseline(accepted: shop, previous: shop, selections: [], workspaceID: UUID(), bindings: [], at: Date())
        let origin = ReceiptAcquisition.SavedPickup(originID: UUID(), id: shop.id)
        func paid(_ parts: [ReceiptAcquisition.OrderMatch.Portion]) -> ReceiptAcquisition {
            .init(receiptID: UUID(), ordinal: 0, lotID: UUID(), foodID: UUID(), merchant: "M", purchaseDate: Date(),
                  transactionReference: nil, imageDigest: nil, originalLine: "PPR", name: "Peppers", received: amount, usable: one,
                  paidLineTotal: .init(minorUnits: 275), stock: .added(location: .fridge), savedPickup: origin,
                  orderMatch: .init(revisionID: UUID(), portions: parts))
        }
        let direct = paid([.init(lineID: a, quantity: amount)])
        let corrected = try direct.correctingPaidTotal(.init(minorUnits: 250))
        XCTAssertEqual(corrected.orderMatch, direct.orderMatch)
        let split = paid([.init(lineID: a, quantity: one), .init(lineID: b, quantity: one)])
        let review = try WeeklyPurchaseReview(baseline: snapshot, pickup: origin, fragments: [], receipts: [direct, corrected, split], adjustments: [])
        XCTAssertEqual(review.purchases.first { $0.acquisition.id == split.id }?.plannedLineID, nil)
        XCTAssertEqual(review.purchases.first { $0.acquisition.id == corrected.id }?.plannedLineID, a)
        XCTAssertThrowsError(try paid([.init(lineID: a, quantity: one)]).validate())
    }

    func testVersionsKeepOriginalEstimateAndOnlyCountLinkedCurrentPrivatePurchases() throws {
        for currency in [Currency.usd, .mxn] {
            let now = Date(), pickupOrigin = UUID()
            let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
            func money(_ amount: Int64) -> Money { .init(minorUnits: amount, currency: currency) }
            var shop = ShoppingLedger(basis: .init(branch: "Market", mode: .inStore, currency: currency))
            let beans = try shop.addManualLine(name: "Beans", quantity: one)
            _ = try shop.addManualLine(name: "Unpriced", quantity: one)
            try shop.setChecked(lineID: beans, checked: true, at: now)
            try shop.recordPickedPrice(lineID: beans, expectedRevision: shop.revisionID, total: money(275),
                membership: false, weighted: false, conditionsConfirmed: false)
            let baseline = try WeeklyCostBaseline(accepted: shop, previous: shop, selections: [], workspaceID: UUID(), bindings: [], at: now)
            try shop.recordPickedPrice(lineID: beans, expectedRevision: shop.revisionID, total: money(900),
                membership: false, weighted: false, conditionsConfirmed: false)
            XCTAssertEqual(try JSONDecoder().decode(WeeklyCostBaseline.self, from: JSONEncoder().encode(baseline)), baseline)
            let target = ReceiptAcquisition.SavedPickup(originID: pickupOrigin, id: shop.id)
            let fragment = ReceiptKey(sourceEventID: "delivered", orderLineID: beans, branchID: "Market", segmentID: "one")
            func purchase(_ target: ReceiptAcquisition.SavedPickup, _ cents: Int64) -> ReceiptAcquisition {
                .init(receiptID: UUID(), ordinal: 0, lotID: UUID(), foodID: UUID(), merchant: "Market",
                    purchaseDate: now, transactionReference: nil, imageDigest: nil, originalLine: "Beans", name: "Beans",
                    received: one, usable: one, paidLineTotal: money(cents), stock: .linked(fragment: fragment),
                    savedPickup: target, currency: currency)
            }
            let first = purchase(target, 350)
            let corrected = try first.correctingPaidTotal(money(330))
            let discount = PrivatePriceEvidence(id: UUID(), source: .adjustment(target: first.lineID, revision: 2, kind: .refund),
                foodID: first.foodID, linkedLotID: first.lotID, name: "Beans", store: "Market", date: now,
                currencyCode: currency.rawValue, amountMinor: 30, pack: nil, sourceText: "refund")
            let foreign = purchase(.init(originID: UUID(), id: shop.id), 1000)
            let review = try WeeklyPurchaseReview(baseline: baseline, pickup: target, fragments: [fragment],
                receipts: [first, corrected, foreign], adjustments: [discount])
            XCTAssertEqual(review.knownEstimate, money(275))
            XCTAssertEqual(review.knownActual, money(300))
            XCTAssertEqual(review.unpricedEstimates, 1)
            XCTAssertEqual(review.unmatchedPlanLines, 1)
            XCTAssertEqual(review.purchases.map(\.plannedLineID), [beans])
            XCTAssertEqual(review.purchases.first?.earlierRevisions, [first])
            XCTAssertEqual(review.purchases.first?.credit, money(30))
            let erased = try WeeklyPurchaseReview(baseline: baseline, pickup: target, fragments: [], receipts: [foreign], adjustments: [])
            XCTAssertNil(erased.knownActual)
            XCTAssertEqual(erased.knownEstimate, money(275))
            XCTAssertEqual(erased.unmatchedPlanLines, 2)
        }
    }
}
