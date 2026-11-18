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
