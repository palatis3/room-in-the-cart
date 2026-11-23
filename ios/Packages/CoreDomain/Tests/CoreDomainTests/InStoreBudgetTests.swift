import XCTest
@testable import CoreDomain

final class InStoreBudgetTests: XCTestCase {
    private let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
    private let zone = "America/New_York"

    func testPesoTripRetainsPricesAndRejectsForeignAmounts() throws {
        let price = Money(minorUnits: 4250, currency: .mxn)
        var shop = ShoppingLedger(basis: ShopBasis(currency: .mxn))
        let id = try shop.addManualLine(name: "Limones", quantity: one)
        try shop.setChecked(lineID: id, checked: true)
        try shop.setBudgetFlexible(lineID: id, expectedRevision: shop.revisionID, flexible: true)

        let zero = Money(minorUnits: 0, currency: .mxn)
        XCTAssertEqual(shop.pickedCartSubtotal.total, zero)
        XCTAssertEqual(try shop.previewBudgetDeferral(lineID: id).after.total, zero)
        let weighed = PickedShelfPrice(rate: price, unit: .kilogram,
            measured: Quantity(amount: try Rational(1, 2), unit: .kilogram, originalLiteral: "0.5"))
        let halfKilo = Money(minorUnits: 2125, currency: .mxn)
        XCTAssertEqual(try weighed.lineTotal(), halfKilo)
        try shop.recordPickedPrice(lineID: id, expectedRevision: shop.revisionID, total: halfKilo,
            membership: false, weighted: true, conditionsConfirmed: true, shelf: weighed)
        XCTAssertEqual(try shop.previewBudgetDeferral(lineID: id).after.total, zero)

        let saved = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        try saved.validate()
        XCTAssertEqual(saved.basis.currency, .mxn)
        XCTAssertEqual(saved.pickedCartSubtotal.total, halfKilo)
        XCTAssertThrowsError(try shop.recordPickedPrice(lineID: id, expectedRevision: shop.revisionID, total: .zero,
            membership: false, weighted: false, conditionsConfirmed: true))
        let unknownForeignWeight = PickedShelfPrice(rate: .zero, unit: .kilogram, measured: nil)
        XCTAssertThrowsError(try shop.recordPickedPrice(lineID: id, expectedRevision: shop.revisionID, total: nil,
            membership: false, weighted: true, conditionsConfirmed: false, shelf: unknownForeignWeight))
        XCTAssertThrowsError(try shop.updateBasis(ShopBasis(currency: .usd)))
        XCTAssertThrowsError(try shop.applyDinnerChanges([.adoptBasis(ShopBasis(currency: .usd))],
            expectedRevisionID: shop.revisionID, revisionID: UUID(), operationID: UUID(), at: Date()))
        XCTAssertEqual(shop, saved)

        let day = try MealDay(year: 2026, month: 11, day: 22, timeZoneIdentifier: "America/Mexico_City")
        let terms = ShopCouponTerms(qualifyingSize: "", minimumPacks: 1, validThrough: day)
        try shop.pinCoupon(lineID: id, expectedRevision: shop.revisionID, terms: terms, clipped: true)
        func evidence(_ wording: String, _ amount: Money) -> CouponReceiptEvidence {
            CouponReceiptEvidence(receiptID: UUID(), itemLineID: UUID(), itemWording: "Limones",
                day: day, check: CouponPackCheck(packCount: 1, size: .matches),
                discount: .printed(lineID: UUID(), wording: wording, amount: amount))
        }
        XCTAssertThrowsError(try shop.reviewCouponReceipt(lineID: id, expectedRevision: shop.revisionID,
            evidence: evidence("Descuento USD 42.50", price)))
        XCTAssertThrowsError(try shop.reviewCouponReceipt(lineID: id, expectedRevision: shop.revisionID,
            evidence: evidence("Descuento $42.50", Money(minorUnits: 4250))))
        try shop.reviewCouponReceipt(lineID: id, expectedRevision: shop.revisionID,
            evidence: evidence("Descuento MXN 42.50", price))
        XCTAssertEqual(shop.lines.first?.pinnedCoupon?.receipt?.savings, price)
    }

    func testLegacyTripWithoutCurrencyReopensInUSD() throws {
        let original = ShoppingLedger(basis: ShopBasis(cap: Money(minorUnits: 2500), currency: .usd))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var basis = try XCTUnwrap(json["basis"] as? [String: Any])
        basis.removeValue(forKey: "currency")
        json["basis"] = basis
        let reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(reopened, original)
        try reopened.validate()
        XCTAssertEqual(reopened.pickedCartSubtotal.total.currency, .usd)
    }

    func testShelfBudgetAtTheStorePreservesRequestedMeasuredAndProtectedNeeds() throws {
        var shop = ShoppingLedger(basis: ShopBasis(branch: "Corner market", mode: .inStore))
        let four = Quantity(amount: try Rational(4), unit: .count, originalLiteral: "4")
        let apples = try shop.addManualLine(name: "Apples", quantity: four)
        let bread = try shop.addManualLine(name: "Bread", quantity: one)
        _ = try shop.chooseMeal(MealTemplate(title: "Protected soup", ingredients: [.init(name: "Lentils", quantity: one)],
            servingGroups: [.init(name: "For tomorrow", servings: .one, isProtected: true)]))
        let lentils = try XCTUnwrap(shop.lines.last?.id)
        _ = try shop.chooseMeal(MealTemplate(title: "Bread and cheese", ingredients: [.init(name: "Bread", quantity: one)]))
        let contributor = try XCTUnwrap(shop.mealOccurrences.last?.ingredientContributionIDs.first)
        let supply = try XCTUnwrap(shop.contributions(forLineID: bread).first)
        try shop.linkContribution(contributionID: contributor, within: supply.id, quantity: one)
        for id in [apples, bread, lentils] { try shop.setChecked(lineID: id, checked: true) }

        let unweighed = PickedShelfPrice(rate: Money(minorUnits: 275), unit: .pound, measured: nil)
        try shop.recordPickedPrice(lineID: apples, expectedRevision: shop.revisionID, total: nil,
            membership: false, weighted: true, conditionsConfirmed: true, shelf: unweighed)
        XCTAssertEqual(shop.pickedCartSubtotal.priced, 0)
        let measured = Quantity(amount: try Rational(3, 2), unit: .pound, originalLiteral: "1.5")
        let weighed = PickedShelfPrice(rate: Money(minorUnits: 275), unit: .pound, measured: measured)
        let total = try XCTUnwrap(weighed.lineTotal())
        XCTAssertEqual(total.minorUnits, 413)
        try shop.recordPickedPrice(lineID: apples, expectedRevision: shop.revisionID, total: total,
            membership: false, weighted: true, conditionsConfirmed: true, shelf: weighed)
        try shop.recordPickedPrice(lineID: bread, expectedRevision: shop.revisionID, total: Money(minorUnits: 450),
            membership: false, weighted: false, conditionsConfirmed: false)
        XCTAssertEqual(try shop.quantity(forLineID: apples)?.amount, four.amount)
        XCTAssertEqual(shop.priceForCurrentPick(lineID: apples)?.shelf?.measured, measured)
        XCTAssertThrowsError(try shop.setBudgetFlexible(lineID: lentils, expectedRevision: shop.revisionID, flexible: true))
        try shop.setBudgetFlexible(lineID: bread, expectedRevision: shop.revisionID, flexible: true)
        let preview = try shop.previewBudgetDeferral(lineID: bread)
        XCTAssertEqual(preview.before, .init(total: Money(minorUnits: 863), priced: 2, picked: 3))
        XCTAssertEqual(preview.after, .init(total: Money(minorUnits: 413), priced: 1, picked: 2))
        XCTAssertEqual(preview.affectedDinners, ["Bread and cheese"])
        let protectedMeals = shop.mealOccurrences
        let sources = shop.contributions
        try shop.leaveForNextTrip(lineID: bread, expectedRevision: shop.revisionID)
        shop = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        XCTAssertEqual(shop.pickedCartSubtotal, preview.after)
        XCTAssertEqual(shop.mealOccurrences, protectedMeals)
        XCTAssertEqual(shop.contributions, sources)
        XCTAssertEqual(try shop.outstandingQuantity(forLineID: bread)?.amount, .one)
        let left = try XCTUnwrap(shop.lines.first { $0.id == bread })
        XCTAssertEqual(shop.outcomeAtCurrentStop(left), .deferred)
        try shop.startShoppingStop(named: "Second store", expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.outcomeAtCurrentStop(left), .deferred)
        XCTAssertFalse(shop.belongsInCurrentBasket(left))
        try shop.undoTripChange(lineID: bread, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.pickedCartSubtotal, preview.before)
    }

    func testShelfPricesValidatePackAndWeightAndInvalidateChangedPartialPick() throws {
        var shop = ShoppingLedger()
        let qty = Quantity(amount: try Rational(6), unit: .count, originalLiteral: "6")
        let id = try shop.addManualLine(name: "Yogurt packs", quantity: qty)
        try shop.pickPart(lineID: id, amount: try Rational(2), expectedRevision: shop.revisionID)
        let count = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let rate = PickedShelfPrice(rate: Money(minorUnits: 225), unit: .count, measured: count)
        let old = shop.revisionID
        try shop.recordPickedPrice(lineID: id, expectedRevision: old, total: rate.lineTotal(),
            membership: false, weighted: false, conditionsConfirmed: false, shelf: rate)
        XCTAssertEqual(shop.pickedCartSubtotal.total.minorUnits, 450)
        XCTAssertThrowsError(try shop.recordPickedPrice(lineID: id, expectedRevision: shop.revisionID, total: Money(minorUnits: 225),
            membership: false, weighted: false, conditionsConfirmed: false, shelf: rate))
        XCTAssertThrowsError(try shop.recordPickedPrice(lineID: id, expectedRevision: old, total: nil,
            membership: false, weighted: false, conditionsConfirmed: false))
        try shop.pickPart(lineID: id, amount: .one, expectedRevision: shop.revisionID)
        XCTAssertEqual(shop.pickedCartSubtotal.priced, 0)
        XCTAssertThrowsError(try PickedShelfPrice(rate: .zero, unit: .pound, measured: count).lineTotal())
        XCTAssertThrowsError(try PickedShelfPrice(rate: .zero, unit: .count,
            measured: .init(amount: Rational(3, 2), unit: .count, originalLiteral: "1.5")).lineTotal())
    }

    func testTwoPackCouponKeepsConditionsClippingAndReceiptEvidenceDistinct() throws {
        var shop = ShoppingLedger()
        let id = try shop.addManualLine(name: "Beans", quantity: one)
        let day = try MealDay(year: 2026, month: 11, day: 19, timeZoneIdentifier: zone)
        let terms = ShopCouponTerms(qualifyingSize: "15 oz", minimumPacks: 2, validThrough: day,
            retailerURL: URL(string: "https://example.com/coupons/beans"))
        let two = CouponPackCheck(packCount: 2, size: .matches)
        try shop.pinCoupon(lineID: id, expectedRevision: shop.revisionID, terms: terms, clipped: false)
        XCTAssertEqual(shop.lines[0].pinnedCoupon?.clipped, false)
        XCTAssertNil(shop.lines[0].pinnedCoupon?.receipt)
        XCTAssertEqual(terms.qualification(on: day, check: nil), .uncertain)
        XCTAssertEqual(terms.qualification(on: day, check: .init(packCount: 1, size: .matches)), .wrongSizeOrCount)
        XCTAssertEqual(terms.qualification(on: day, check: .init(packCount: 2, size: .different)), .wrongSizeOrCount)
        XCTAssertEqual(terms.qualification(on: try MealDay(year: 2026, month: 11, day: 20, timeZoneIdentifier: zone), check: two), .expired)
        XCTAssertEqual(terms.qualification(on: day, check: two), .qualifies)
        try shop.setChecked(lineID: id, checked: true)
        try shop.pinCoupon(lineID: id, expectedRevision: shop.revisionID, terms: terms, clipped: true, pickCheck: two)
        let receipt = UUID(), item = UUID()
        func evidence(_ discount: CouponReceiptEvidence.Discount) -> CouponReceiptEvidence {
            CouponReceiptEvidence(receiptID: receipt, itemLineID: item, itemWording: "2 BEANS 15 OZ",
                day: day, check: two, discount: discount)
        }
        try shop.reviewCouponReceipt(lineID: id, expectedRevision: shop.revisionID, evidence: evidence(.unverified))
        XCTAssertEqual(shop.lines[0].pinnedCoupon?.missingQualifyingDiscount, false)
        try shop.reviewCouponReceipt(lineID: id, expectedRevision: shop.revisionID, evidence: evidence(.absent))
        let missing = try XCTUnwrap(shop.lines[0].pinnedCoupon)
        XCTAssertTrue(missing.missingQualifyingDiscount)
        XCTAssertNil(missing.receipt?.savings)
        XCTAssertEqual(shop.pickedCartSubtotal.priced, 0)
        let adjustment = UUID()
        let printed = evidence(.printed(lineID: adjustment, wording: "CUPÓN -$1,25", amount: Money(minorUnits: 125)))
        try shop.reviewCouponReceipt(lineID: id, expectedRevision: shop.revisionID, evidence: printed)
        XCTAssertEqual(shop.lines[0].pinnedCoupon?.receipt?.savings?.minorUnits, 125)
        XCTAssertEqual(shop.lines[0].pinnedCoupon?.missingQualifyingDiscount, false)
        let second = try shop.addManualLine(name: "Other beans", quantity: one)
        try shop.pinCoupon(lineID: second, expectedRevision: shop.revisionID, terms: terms, clipped: true)
        XCTAssertThrowsError(try shop.reviewCouponReceipt(lineID: second, expectedRevision: shop.revisionID, evidence: printed))
        var another = ShoppingLedger()
        let other = try another.addManualLine(name: "Beans", quantity: one)
        try another.pinCoupon(lineID: other, expectedRevision: another.revisionID, terms: terms, clipped: true)
        try another.reviewCouponReceipt(lineID: other, expectedRevision: another.revisionID, evidence: printed)
        XCTAssertThrowsError(try LedgerWorkspace(shops: [shop, another]).validate())
        XCTAssertFalse(CouponReceiptEvidence.shows(amount: Money(minorUnits: 125), in: "Coupon $11.25"))
        XCTAssertFalse(CouponReceiptEvidence.shows(amount: Money(minorUnits: 125), in: "Coupon CAD 1.25"))
        XCTAssertEqual(try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop)), shop)
    }
    func testCouponNeedsADistinctPrintedDiscountAndMistakenReceiptCanBeUnlinked() throws {
        let amount = Money(minorUnits: 125)
        for wording in ["Tax USD 1.25", "Beans USD 1.25", "Total savings 1.25", "Coupon valid next trip $1.25",
                        "Coupon $5.00 now $1.25", "Devolución cupón $1,25", "Coupon 1.25%"] {
            XCTAssertFalse(CouponReceiptEvidence.isDiscountLine(wording), wording)
        }
        XCTAssertTrue(CouponReceiptEvidence.shows(amount: amount, in: "MFR CPN -1.25"))
        XCTAssertTrue(CouponReceiptEvidence.shows(amount: amount, in: "Descuento $1,25-"))
        let day = try MealDay(year: 2026, month: 11, day: 19, timeZoneIdentifier: zone)
        var shop = ShoppingLedger()
        let line = try shop.addManualLine(name: "Beans", quantity: one)
        let terms = ShopCouponTerms(qualifyingSize: "", minimumPacks: 1, validThrough: day)
        try shop.pinCoupon(lineID: line, expectedRevision: shop.revisionID, terms: terms, clipped: true)
        let item = UUID()
        func evidence(_ receipt: UUID, adjustment: UUID) -> CouponReceiptEvidence {
            CouponReceiptEvidence(receiptID: receipt, itemLineID: item, itemWording: "Beans 1 pk $4.50", day: day,
                                  check: .init(packCount: 1, size: .matches),
                                  discount: .printed(lineID: adjustment, wording: "Coupon -$1.25", amount: amount))
        }
        XCTAssertThrowsError(try shop.reviewCouponReceipt(lineID: line, expectedRevision: shop.revisionID,
                                                          evidence: evidence(UUID(), adjustment: item)))
        try shop.reviewCouponReceipt(lineID: line, expectedRevision: shop.revisionID, evidence: evidence(UUID(), adjustment: UUID()))
        try shop.clearCouponReceipt(lineID: line, expectedRevision: shop.revisionID)
        XCTAssertNil(shop.lines.first?.pinnedCoupon?.receipt)
        XCTAssertEqual(shop.lines.first?.pinnedCoupon?.clipped, true)
        let corrected = evidence(UUID(), adjustment: UUID())
        try shop.reviewCouponReceipt(lineID: line, expectedRevision: shop.revisionID, evidence: corrected)
        XCTAssertEqual(shop.lines.first?.pinnedCoupon?.receipt, corrected)
    }

}
