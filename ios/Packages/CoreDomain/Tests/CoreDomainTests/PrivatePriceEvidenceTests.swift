import Foundation
import XCTest
@testable import CoreDomain

final class PrivatePriceEvidenceTests: XCTestCase {
    private let food = UUID()
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    private func evidence(_ source: PrivatePriceEvidence.Source, amount: Int64 = 500, count: Int64 = 1,
                          unit: UnitOfMeasure = .gram, variant: String = "Unsalted", currency: String = "USD") throws -> PrivatePriceEvidence {
        let pack = PrivatePriceEvidence.Pack(count: count, perPackage: Quantity(amount: try Rational(500), unit: unit, originalLiteral: "500"))
        return PrivatePriceEvidence(id: UUID(), source: source, foodID: food, name: "Cashews", variant: variant,
                                   store: "Market", date: date, currencyCode: currency, amountMinor: amount,
                                   pack: pack, eligibility: "Members only", sourceText: "Two for five")
    }

    func testShelfQuoteAndIncompatiblePaidProductsStayOutsideComparablePaidPrices() throws {
        let paid = try evidence(.paidManual)
        let offer = try evidence(.shelf, count: 2)
        XCTAssertEqual(try offer.unitPrice(in: .kilogram), try Rational(500))
        XCTAssertFalse(try paid.comparablePaidPrice(to: offer, in: .kilogram))
        XCTAssertFalse(try paid.comparablePaidPrice(to: evidence(.currentQuote), in: .kilogram))
        XCTAssertFalse(try paid.comparablePaidPrice(to: evidence(.paidManual, currency: "EUR"), in: .kilogram))
        XCTAssertFalse(try paid.comparablePaidPrice(to: evidence(.paidManual, variant: "Salted"), in: .kilogram))
        XCTAssertFalse(try paid.comparablePaidPrice(to: evidence(.paidManual, unit: .count), in: .kilogram))
        XCTAssertTrue(try paid.comparablePaidPrice(to: evidence(.paidManual), in: .kilogram))
    }

    func testOnlyExplicitlyAllocatedRefundForThisPaidRevisionChangesUnitCost() throws {
        let paid = try evidence(.paidManual, amount: 600)
        func credit(_ kind: PrivatePriceEvidence.AdjustmentKind, revision: Int64 = 1) -> PrivatePriceEvidence {
            .init(id: UUID(), source: .adjustment(target: paid.id, revision: revision, kind: kind),
                  name: paid.name, store: paid.store, date: date, currencyCode: "USD", amountMinor: 100, pack: nil, sourceText: "Receipt credit")
        }
        let returned = credit(.refund)
        XCTAssertEqual(try paid.unitPrice(in: .kilogram, adjustments: [returned, credit(.unallocatedCredit), credit(.discount, revision: 2)]), try Rational(1_000))
        XCTAssertThrowsError(try paid.unitPrice(in: .kilogram, adjustments: [returned, returned]))
    }
}
