import Foundation
import XCTest
@testable import CoreDomain

final class ReviewedPriceImageTests: XCTestCase {
    func testMemberBundleRequiresReviewedDenominatorAndKeepsImageLineIdentity() throws {
        let wording = "Members only · 2 for $5"
        let guess = ReviewedShelfImage.propose(wording)
        XCTAssertEqual(guess.packages, 2)
        XCTAssertEqual(guess.amount, Money(minorUnits: 500))
        XCTAssertEqual(guess.conditions, wording)
        XCTAssertNil(guess.currencyCode)
        XCTAssertEqual(ReviewedShelfImage.propose("2 por €5,25").currencyCode, "EUR")
        XCTAssertEqual(ReviewedShelfImage.propose("2 for £5").currencyCode, "GBP")
        XCTAssertEqual(ReviewedShelfImage.propose("2 for $5 CAD").currencyCode, "CAD")
        XCTAssertNil(ReviewedShelfImage.propose("2 for $5, also €5").currencyCode)
        let printed = try PriceImageLine(digest: Data(repeating: 1, count: 32), ordinal: 2, wording: wording, uncertain: true)
        XCTAssertEqual(try PriceImageLine(digest: printed.digest, ordinal: 2, wording: wording, uncertain: true).shelfID, printed.shelfID)
        XCTAssertNotEqual(try PriceImageLine(digest: printed.digest, ordinal: 3, wording: wording, uncertain: true).shelfID, printed.shelfID)
        XCTAssertNil(ReviewedShelfImage.propose("$4 / lb").packages)
        let observation = PrivatePriceEvidence(id: printed.shelfID, source: .shelf, name: "Pasta", store: "Market",
            date: Date(), currencyCode: "USD", amountMinor: 500, pack: nil, eligibility: guess.conditions,
            sourceText: wording, shelfImage: .init(printed: printed, basis: .bundle))
        XCTAssertNil(try observation.unitPrice(in: .pound))
        XCTAssertFalse(observation.isPaidPrice)
    }

    func testCheckoutProposesUniqueBilingualFieldsAndLeavesAmbiguousAmountsForReview() throws {
        let digest = Data(repeating: 5, count: 32)
        let text = ["Subtotal: $18.00", "Descuento -$2,50", "Tax $0.70", "Sales tax $0.40",
                    "Propina 1,25", "Gastos de envío: USD 2", "Total a pagar $19.85"]
        let lines = try text.enumerated().map { try PriceImageLine(digest: digest, ordinal: $0.offset, wording: $0.element, uncertain: false) }
        let offers = ReviewedCheckoutImage.proposals(from: lines)
        XCTAssertEqual(offers[.subtotal]?.amount?.minorUnits, 1800)
        XCTAssertEqual(offers[.discount]?.amount?.minorUnits, 250)
        XCTAssertEqual(offers[.tip]?.amount?.minorUnits, 125)
        XCTAssertEqual(offers[.fee]?.amount?.minorUnits, 200)
        XCTAssertNil(offers[.tax])
        XCTAssertEqual(offers[.total]?.line, lines.last)
        let review = try ReviewedCheckoutImage(charges: Array(offers.values))
        XCTAssertEqual(review.displayedTotal?.minorUnits, 1985)
        XCTAssertTrue(review.charges.allSatisfy { $0.inclusion == .unknown })

        for raw in ["Estimated credit $8", "Total 10.00 CAD", "Tax 8%", "Tip -$4", "Total $2.345",
                    "Total $10 / $12", "Tax €2.15"] {
            let line = try PriceImageLine(digest: digest, ordinal: 0, wording: raw, uncertain: false)
            XCTAssertTrue(ReviewedCheckoutImage.proposals(from: [line]).isEmpty, raw)
        }
        let uncertain = try PriceImageLine(digest: digest, ordinal: 0, wording: "Total $50", uncertain: true)
        XCTAssertNil(ReviewedCheckoutImage.proposals(from: [uncertain])[.total])
        let standalone = try PriceImageLine(digest: digest, ordinal: 0, wording: "$3.25", uncertain: false)
        XCTAssertTrue(ReviewedCheckoutImage.proposals(from: [standalone]).isEmpty)
        XCTAssertEqual(ReviewedCheckoutImage.proposedAmount(for: .fee, from: standalone)?.minorUnits, 325)
        XCTAssertNil(ReviewedCheckoutImage.proposedAmount(for: .total, from: lines[0]))
    }

    func testShelfPackageSizeAndPriceStayIndependentOfUnitRatesAndPromotions() {
        let shelf = ReviewedShelfImage.propose("Yogur 1,5 kg — socios 2 por $5,50 USD")
        XCTAssertEqual(shelf.amount?.minorUnits, 550)
        XCTAssertEqual(shelf.packages, 2)
        XCTAssertEqual(ReviewedShelfImage.propose("Members only 2 for $5 USD 500 g").amount?.minorUnits, 500)
        XCTAssertEqual(ReviewedShelfImage.propose("Aceite 250 ml 4,90 EUR").amount?.minorUnits, 490)
        XCTAssertNil(ReviewedShelfImage.propose("Members 2 for $5, regular $4 each").amount)
        XCTAssertEqual(shelf.packageSize?.amount, try? Rational(3, 2))
        XCTAssertEqual(shelf.packageSize?.unit, .kilogram)
        XCTAssertNotNil(shelf.conditions)
        XCTAssertEqual(ReviewedShelfImage.propose("Milk 12 fl oz $2.75").packageSize?.unit, .fluidOunce)
        XCTAssertEqual(ReviewedShelfImage.propose("Oats 500g $3.29").amount?.minorUnits, 329)
        let rate = ReviewedShelfImage.propose("unit price $0.75 per 100 g")
        XCTAssertNil(rate.packageSize)
        XCTAssertEqual(rate.rateQuantity?.amount, try? Rational(100))
        XCTAssertEqual(rate.rateQuantity?.unit, .gram)
        XCTAssertEqual(rate.priceBasis, .unit)
        XCTAssertEqual(ReviewedShelfImage.propose("Oats 500g $3.29").priceBasis, .bundle)
        XCTAssertEqual(ReviewedShelfImage.propose("$4/lb").rateQuantity?.unit, .pound)
        XCTAssertNil(ReviewedShelfImage.propose("Tea 100 g or 250 g $4.00").packageSize)
        XCTAssertNil(ReviewedShelfImage.propose("Juice 6 x 12 fl oz $8").packageSize)
        XCTAssertNil(ReviewedShelfImage.propose("Save $1.50 with coupon").amount)
        XCTAssertNil(ReviewedShelfImage.propose("Was $6.00 now $4.00").amount)
    }

    func testCheckoutKeepsPrintedTotalIndependentOfUnknownTaxTipAndSubtotal() throws {
        let digest = Data(repeating: 3, count: 32)
        func line(_ index: Int, _ text: String) throws -> PriceImageLine {
            try .init(digest: digest, ordinal: index, wording: text, uncertain: false)
        }
        let charges: [ReviewedCheckoutImage.Charge] = [
            .init(field: .subtotal, amount: .init(minorUnits: 1600), inclusion: .included, line: try line(0, "Subtotal $16")),
            .init(field: .discount, amount: .init(minorUnits: 300), inclusion: .included, line: try line(1, "Discount -$3")),
            .init(field: .tax, amount: nil, inclusion: .unknown, line: try line(2, "Tax at pickup")),
            .init(field: .tip, amount: .init(minorUnits: 200), inclusion: .additional, line: try line(3, "Tip $2 additional"))
        ]
        let subtotalOnly = try ReviewedCheckoutImage(charges: charges)
        XCTAssertNil(subtotalOnly.displayedTotal)
        let preview = LedgerRetailerPreview(total: nil, source: "Market checkout", capturedAt: Date(), screenshot: subtotalOnly)
        XCTAssertNoThrow(try preview.validate())
        XCTAssertThrowsError(try LedgerRetailerPreview(total: .init(minorUnits: 1500), source: "Market", capturedAt: Date(), screenshot: subtotalOnly).validate())
        var shop = ShoppingLedger()
        let originalShopRevision = shop.revisionID
        var oldStore = shop.basis
        oldStore.branch = "East market"
        var newStore = oldStore
        newStore.branch = "West market"
        newStore.retailerPreview = preview
        XCTAssertThrowsError(try shop.updateBasis(newStore, evidenceFor: oldStore.retailerTerms, reviewing: originalShopRevision))
        XCTAssertEqual(shop.revisionID, originalShopRevision)
        try shop.updateBasis(newStore, evidenceFor: newStore.retailerTerms, reviewing: originalShopRevision)
        XCTAssertEqual(shop.basis.retailerPreview, preview)
        XCTAssertTrue(shop.lines.isEmpty)
        let total = ReviewedCheckoutImage.Charge(field: .total, amount: .init(minorUnits: 1400), inclusion: .unknown, line: try line(4, "Total $14"))
        XCTAssertEqual(try ReviewedCheckoutImage(charges: charges + [total]).displayedTotal?.minorUnits, 1400)
        XCTAssertThrowsError(try ReviewedCheckoutImage(charges: charges + [charges[0]]))
    }
}
