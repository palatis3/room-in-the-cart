import XCTest
@testable import CoreDomain

final class CurrencyMathTests: XCTestCase {
    private func pesos(_ minorUnits: Int64) -> Money { Money(minorUnits: minorUnits, currency: .mxn) }

    func testRegionSelectsCurrencyIndependentlyOfLanguageAndLegacyUSDDecodes() throws {
        XCTAssertEqual(Currency.groceryDefault(for: Locale(identifier: "en_MX")), .mxn)
        XCTAssertEqual(Currency.groceryDefault(for: Locale(identifier: "es_US")), .usd)
        XCTAssertEqual(Currency.groceryDefault(for: Locale(identifier: "es_ES")), .usd)
        let saved = Data(#"{"minorUnits":125,"currency":"USD"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Money.self, from: saved), try Money(decimal: "1.25"))
        XCTAssertEqual(try JSONDecoder().decode(Money.self, from: JSONEncoder().encode(pesos(125))), pesos(125))
    }

    func testArithmeticAndPackRankingPreserveCurrencyAndRejectMixedEvidence() throws {
        let pack = try Money(decimal: "12.50", currency: .mxn)
        XCTAssertEqual(try pack.multiplied(by: 2), pesos(2500))
        XCTAssertEqual(try pack.subtracting(pesos(1300)), pesos(-50))
        XCTAssertThrowsError(try pack.adding(.zero))
        XCTAssertThrowsError(try pack.subtracting(.zero))
        XCTAssertFalse(pack > .zero)
        XCTAssertFalse(pack <= .zero)
        let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        func request(_ a: Money?, _ b: Money?, _ cap: Money?, stock: Quantity? = nil) -> ComparisonRequest {
            ComparisonRequest(itemName: "Beans", needed: one, confirmedAtHome: stock,
                offerA: .init(id: "a", label: "A", usableQuantity: one, price: a),
                offerB: .init(id: "b", label: "B", usableQuantity: one, price: b), itemCap: cap, currency: .mxn)
        }
        let result = try PackComparison.evaluate(request(pack, pesos(1400), pesos(1500)))
        XCTAssertEqual(result.preferredOfferID, "a")
        XCTAssertEqual(result.offerA.totalCost, pack)
        XCTAssertEqual(result.offerA.itemHeadroom, pesos(250))
        XCTAssertEqual(result.offerA.unitCeiling, pesos(1500))
        XCTAssertEqual(try PackComparison.evaluate(request(nil, nil, nil, stock: one)).offerA.totalCost, pesos(0))
        let mixed = request(pack, .init(minorUnits: 500), nil)
        XCTAssertNil(mixed.comparableUnitPrices)
        XCTAssertThrowsError(try PackComparison.evaluate(mixed))
        XCTAssertThrowsError(try PackComparison.evaluate(request(pack, pack, .zero)))
    }

    func testCheckoutUsesOneCurrencyForThresholdsCapsAndUnknownBounds() throws {
        let context = CheckoutContext(storeID: "store", branchID: "branch", mode: .pickup, slot: "today",
                                      commitmentsID: UUID(), observedAt: Date(), source: "retailer", currency: .mxn)
        let line = try CheckoutLine(id: UUID(), name: "Beans", packages: 3, packagePrice: pesos(825))
        let cap = CheckoutCap(scope: .wholeCheckout, commitmentsID: context.commitmentsID, amount: pesos(3000))
        func quote(threshold: Money, fee: Money) -> CheckoutQuote {
            let rule = CheckoutFeeRule.waivedAt(threshold: threshold, belowThreshold: .exact(fee), basis: .eligibleItemsBeforeDiscounts)
            return .init(scope: .wholeCheckout, context: context, pricing: .components(lines: [line], lineSetComplete: true,
                fees: [.init(id: "pickup", rule: rule)], discounts: [], tax: .exact(pesos(0)), deposits: .exact(pesos(0))))
        }
        let result = try CheckoutEngine.evaluate(quote(threshold: pesos(2500), fee: pesos(200)), cap: cap)
        XCTAssertEqual(result.total.exact, pesos(2675))
        XCTAssertEqual(result.cap, .within(maximumCheckout: pesos(2675), minimumHeadroom: pesos(325)))
        XCTAssertThrowsError(try CheckoutEngine.evaluate(quote(threshold: .zero, fee: pesos(200))))
        XCTAssertThrowsError(try CheckoutEngine.evaluate(quote(threshold: pesos(0), fee: .zero)))
        let unknown = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.unknown(reason: "pending")))
        XCTAssertEqual(try CheckoutEngine.evaluate(unknown).total.lowerBound, pesos(0))
        XCTAssertThrowsError(try CheckoutEngine.evaluate(unknown, cap: .init(scope: cap.scope, commitmentsID: context.commitmentsID, amount: .zero)))
        let bounded = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.bounded(lower: pesos(100), upper: .init(minorUnits: 200), reason: "range")))
        XCTAssertThrowsError(try CheckoutEngine.evaluate(bounded))
        XCTAssertEqual(try CheckoutEngine.replacementCeiling(lineAllowance: pesos(500), retainedOriginalCharge: pesos(100), wholeCheckoutRemaining: pesos(300)), pesos(300))
        XCTAssertThrowsError(try CheckoutEngine.replacementCeiling(lineAllowance: pesos(500), retainedOriginalCharge: pesos(100), wholeCheckoutRemaining: .zero))
    }

    func testBeforeAndAfterRequireMatchingCurrenciesEvenWhenEstimated() throws {
        let context = CheckoutContext(storeID: "s", branchID: "b", mode: .pickup, slot: "1",
                                      commitmentsID: UUID(), observedAt: Date(), source: "shelf")
        func quote(_ evidence: CostEvidence) -> CheckoutQuote {
            .init(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(evidence))
        }
        let estimate = quote(.bounded(lower: pesos(100), upper: pesos(200), reason: "weight"))
        XCTAssertThrowsError(try CheckoutEngine.compare(before: estimate, after: quote(.exact(.zero))))
        let pair = try CheckoutEngine.compare(before: estimate, after: quote(.unknown(reason: "unavailable")))
        XCTAssertEqual(pair.after.total.lowerBound, pesos(0))
        XCTAssertNil(pair.change)
        XCTAssertThrowsError(try StoreOrderMinimum(.required, minimum: pesos(100), eligibleSubtotal: .zero).status())
    }

    func testWeightLimitPreservesPesosAcrossDiscountAndFee() throws {
        let context = CheckoutContext(storeID: "s", branchID: "b", mode: .pickup, slot: "1",
                                      commitmentsID: UUID(), observedAt: Date(), source: "scale")
        let line = CheckoutLine(id: UUID(), name: "Produce", cost: .unknown(reason: "weight"))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .components(lines: [line],
            lineSetComplete: true, fees: [.init(id: "service", rule: .fixed(.exact(pesos(100))))],
            discounts: [.init(id: "coupon", amount: .exact(pesos(50)), reducesEligibleSubtotal: true)],
            tax: .exact(pesos(0)), deposits: .exact(pesos(0))))
        let cap = CheckoutCap(scope: .wholeCheckout, commitmentsID: context.commitmentsID, amount: pesos(1050))
        let maximum = try CheckoutEngine.maximumWeight(quote: quote, cap: cap, lineID: line.id,
                                                       rate: pesos(250), increment: .one, rounding: .up)
        XCTAssertEqual(maximum, .maximum(weight: try Rational(4), lineCost: pesos(1000), checkout: pesos(1050)))
        XCTAssertThrowsError(try CheckoutEngine.maximumWeight(quote: quote, cap: cap, lineID: line.id,
                                                               rate: .init(minorUnits: 250), increment: .one, rounding: .up))
    }

    func testDinnerIngredientValueAndAdditionalCashKeepTheShopCurrency() throws {
        let quantity = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        let ingredient = MealIngredient(name: "Lime", quantity: quantity)
        let recipe = MealTemplate(title: "Lime wedges", servings: .one, ingredients: [ingredient])
        let dinner = AcceptedDinner(id: UUID(), template: recipe, acceptedAt: Date())
        let meal = DinnerCommitment(name: "Dinner", kind: .dinner, portions: .one)
        let commitments = DinnerCommitmentSet(commitments: [meal])
        let food = UUID()
        let demand = DinnerDemand(commitmentID: meal.id, foodID: food, name: ingredient.name, quantity: quantity,
                                  acceptedDinnerID: dinner.id, ingredientID: ingredient.id)
        let offer = PackOffer(id: "lime", label: "Lime", usableQuantity: quantity, price: pesos(799))
        let pack = DinnerPackSelection(foodID: food, offer: offer, availability: .confirmed(maximumPacks: nil))
        let context = CheckoutContext(storeID: "s", branchID: "b", mode: .pickup, slot: "today",
                                      commitmentsID: commitments.id, observedAt: Date(), source: "label", currency: .mxn)
        let scenario = DinnerScenario(commitments: commitments, acceptedDinnerIDs: [dinner.id], demands: [demand],
            packs: [pack], baselineComplete: true, fees: [], tax: .exact(pesos(0)), deposits: .exact(pesos(0)),
            context: context, preparation: .init(handsOnMinutes: 5, remainingLeadMinutes: 5, availableMinutes: 15))
        let result = try DinnerScenarioEngine.evaluate(scenario, acceptedDinners: [dinner])
        XCTAssertEqual(result.checkout.total.exact, pesos(799))
        XCTAssertEqual(result.ingredientValues[meal.id]?.perServing, pesos(799))
        let estimate = TonightPurchaseEstimate(packages: [.init(id: food, package: "Lime", count: 1, cost: pesos(799),
                                                               source: "label", observedAt: Date())], subtotal: pesos(799), complete: true, currency: .mxn)
        XCTAssertEqual(try estimate.additionalCash(addedCharges: pesos(100), chargesComplete: true).known, pesos(899))
        XCTAssertThrowsError(try estimate.additionalCash(addedCharges: .zero, chargesComplete: true))
    }

    func testSettlementKeepsEmptyAndAsOfSummariesInCurrencyAndRejectsMixedEntries() throws {
        var ledger = SettlementLedger()
        let now = Date()
        let charge = SettlementEntry(id: UUID(), evidenceKey: "order", kind: .postedCharge, amount: pesos(2900), occurredAt: now)
        XCTAssertEqual(try ledger.summary(currency: .mxn).paidSoFar, pesos(0))
        try ledger.append(charge)
        XCTAssertEqual(try ledger.summary(asOf: now.addingTimeInterval(-1)).paymentHolds, pesos(0))
        XCTAssertThrowsError(try ledger.append(.init(id: UUID(), evidenceKey: "topup", kind: .postedTopUp, amount: .init(minorUnits: 100), occurredAt: now)))
        XCTAssertEqual(try ledger.summary().paidSoFar, pesos(2900))
    }
}
