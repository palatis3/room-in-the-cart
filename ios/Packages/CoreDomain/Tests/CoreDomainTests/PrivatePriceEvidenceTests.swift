import Foundation
import XCTest
@testable import CoreDomain

final class PrivatePriceEvidenceTests: XCTestCase {
    private let food = UUID()
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    private func evidence(_ source: PrivatePriceEvidence.Source, amount: Int64 = 500, count: Int64 = 1,
                          unit: UnitOfMeasure = .gram, variant: String? = "Unsalted", currency: String = "USD") throws -> PrivatePriceEvidence {
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
        XCTAssertFalse(try paid.comparablePaidPrice(to: evidence(.paidManual, variant: nil), in: .kilogram))
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

extension PrivatePriceEvidenceTests {
    func testLiveShelfRateUsesLatestMatchingPaidVariantAndNetComparableQuantity() throws {
        let size = Quantity(amount: try Rational(8), unit: .ounce, originalLiteral: "8 oz")
        let offer = ShelfPriceOffer(product: " Cereal ", variant: "plain", pack: .init(perPackage: size),
                                   amountMinor: 300, currency: "USD", eligibility: "members", tax: .excluded)
        func make(_ amount: Int64?, days: Double = 0, kind: PrivatePriceEvidence.Source = .paidManual,
                  variant: String? = "Plain", unit: UnitOfMeasure = .ounce, tax: PrivatePriceEvidence.TaxTreatment? = .excluded,
                  terms: String? = "Members", currency: String = "USD") throws -> PrivatePriceEvidence {
            .init(id: UUID(), source: kind, name: "Cereal", variant: variant, store: "Market",
                  date: date.addingTimeInterval(days * 86400), currencyCode: currency, amountMinor: amount,
                  pack: .init(count: 2, perPackage: .init(amount: try Rational(6), unit: unit, originalLiteral: "6")),
                  eligibility: terms, sourceText: "Matched label", taxTreatment: tax)
        }
        let last = try make(300)
        let records = try [make(100, days: -1), make(50, kind: .shelf), make(50, kind: .currentQuote), make(50, days: 1),
                           make(nil), make(100, variant: "Honey"), make(100, unit: .fluidOunce), make(100, tax: .included),
                           make(100, terms: nil), make(100, currency: "CAD"), last]
        let matches = offer.candidates(in: records, through: date)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(offer.purchase(in: matches, chosenID: nil), last)
        let credit = PrivatePriceEvidence(id: UUID(), source: .adjustment(target: last.id, revision: 1, kind: .refund),
            name: last.name, store: last.store, date: date, currencyCode: "USD", amountMinor: 60, pack: nil,
            sourceText: "Credited for this purchase")
        let rates = try XCTUnwrap(offer.unitRates(for: last, adjustments: [credit], sameBasisConfirmed: true))
        XCTAssertEqual(rates.shelf, try Rational(75, 2)) // $3 for 8 oz
        XCTAssertEqual(rates.paid, try Rational(20)) // ($3 - 60¢) for 12 oz
        XCTAssertNotNil(try offer.unitRates(for: last, adjustments: [], sameBasisConfirmed: false))
    }

    func testShopperCanMatchUnlabelledPurchaseWithoutGuessingAZeroOrUnknownPrice() throws {
        let paid = try evidence(.paidManual, amount: 0, variant: nil)
        func offer(_ amount: Int64?) -> ShelfPriceOffer {
            .init(product: paid.name, variant: "", pack: paid.pack, amountMinor: amount, currency: "USD",
                  eligibility: "Members only", tax: nil)
        }
        let free = offer(0)
        let rows = free.candidates(in: [paid], through: date)
        XCTAssertNil(free.purchase(in: rows, chosenID: nil))
        XCTAssertEqual(free.purchase(in: rows, chosenID: paid.id), paid)
        XCTAssertNil(try free.unitRates(for: paid, adjustments: [], sameBasisConfirmed: false))
        let rates = try XCTUnwrap(free.unitRates(for: paid, adjustments: [], sameBasisConfirmed: true))
        XCTAssertEqual(rates.shelf, .zero)
        XCTAssertEqual(rates.paid, .zero)
        XCTAssertNil(try offer(nil).unitRates(for: paid, adjustments: [], sameBasisConfirmed: true))
    }
}

extension PrivatePriceEvidenceTests {
    func testOlderPriceRecordDecodesWithoutMakingUpTaxOrUsableAmount() throws {
        let value = try evidence(.paidManual)
        let data = try JSONEncoder().encode(value)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(document["taxTreatment"])
        XCTAssertNil(document["confirmedUsable"])
        let restored = try JSONDecoder().decode(PrivatePriceEvidence.self, from: data)
        XCTAssertEqual(restored, value)
        XCTAssertNil(restored.taxTreatment)
        XCTAssertNil(restored.confirmedUsable)
    }

    func testReceiptDenominatorHonorsPurchasedVersusUsableAmountsAndUnknownLegacyTax() throws {
        let quantity = Quantity(amount: try Rational(12), unit: .ounce, originalLiteral: "12 oz")
        func purchase(usable: Rational) throws -> PrivatePriceEvidence {
            try .init(receipt: ReceiptAcquisition(receiptID: UUID(), ordinal: 0, lotID: UUID(), foodID: UUID(),
                merchant: "North", purchaseDate: date, transactionReference: nil, imageDigest: nil,
                originalLine: "12 oz berries", name: "Berries", received: quantity,
                usable: .init(amount: usable, unit: .ounce, originalLiteral: usable.description),
                paidLineTotal: .init(minorUnits: 300), stock: .added(location: .fridge)))
        }
        func offer(_ basis: ShelfPriceOffer.QuantityBasis) -> ShelfPriceOffer {
            .init(product: "Berries", variant: "", pack: .init(perPackage: quantity), amountMinor: 300,
                  currency: "USD", eligibility: "", tax: nil, basis: basis)
        }
        let paid = try purchase(usable: Rational(8))
        XCTAssertNil(paid.taxTreatment)
        let purchasedRate = try XCTUnwrap(offer(.purchased).unitRates(for: paid, adjustments: [], sameBasisConfirmed: true))
        let usableRate = try XCTUnwrap(offer(.usable).unitRates(for: paid, adjustments: [], sameBasisConfirmed: true))
        XCTAssertEqual(purchasedRate.paid, try Rational(25))
        XCTAssertEqual(usableRate.paid, try Rational(75, 2))
        XCTAssertNil(try offer(.usable).unitRates(for: purchase(usable: .zero), adjustments: [], sameBasisConfirmed: true))
    }
}
