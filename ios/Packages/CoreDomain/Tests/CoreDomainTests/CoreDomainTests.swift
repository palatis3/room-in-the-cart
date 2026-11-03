import XCTest
@testable import CoreDomain

final class CoreDomainTests: XCTestCase {
    private func quantity(_ numerator: Int64, _ denominator: Int64 = 1,
                          unit: UnitOfMeasure = .count) throws -> Quantity {
        Quantity(amount: try Rational(numerator, denominator), unit: unit, originalLiteral: "\(numerator)/\(denominator)")
    }

    private func request(need: Quantity?, stock: Quantity? = nil, protected: Quantity? = nil,
                         yield: Quantity? = nil, price: Money? = Money(minorUnits: 349),
                         cap: Money? = nil) throws -> ComparisonRequest {
        ComparisonRequest(itemName: "Wraps", needed: need, confirmedAtHome: stock,
                          protectedAmount: protected,
                          offerA: PackOffer(id: "a", label: "Pack A", usableQuantity: yield, price: price),
                          offerB: PackOffer(id: "b", label: "Pack B", usableQuantity: yield, price: price), itemCap: cap)
    }

    func testExactDecimalsAndCanonicalRationals() throws {
        XCTAssertEqual(try Rational(decimal: "0.1").adding(Rational(decimal: "0.2")), try Rational(decimal: "0.3"))
        XCTAssertEqual(try Rational(decimal: "0001.5000"), try Rational(3, 2))
        XCTAssertEqual(try Rational(10, 20), try Rational(1, 2))
        XCTAssertEqual(try Rational(decimal: "0.000000000000000001"), try Rational(1, 1_000_000_000_000_000_000))
        XCTAssertEqual(try Money(decimal: "3.49"), Money(minorUnits: 349))
        XCTAssertThrowsError(try Money(decimal: "3.491"))
        for text in ["", " ", "-1", "NaN", "inf", "1e3", "1,5", "1.", ".5", "1.2.3", "1/2"] {
            XCTAssertThrowsError(try Rational(decimal: text), text)
        }
    }

    func testWholePacksAndProtectedPartition() throws {
        let input = try request(need: quantity(12), stock: quantity(0), protected: quantity(2),
                                yield: quantity(8), cap: Money(minorUnits: 600))
        let result = try PackComparison.evaluate(input)
        XCTAssertEqual(result.scope, .itemOnly)
        XCTAssertEqual(result.offerA.packsToBuy, 2)
        XCTAssertEqual(result.offerA.totalCost?.minorUnits, 698)
        XCTAssertEqual(result.offerA.itemHeadroom?.minorUnits, -98)
        XCTAssertEqual(result.offerA.unitCeiling?.minorUnits, 300)
        XCTAssertEqual(result.offerA.leftover, try Rational(4))
        XCTAssertEqual(result.offerA.protectedAmount, try Rational(2))
        XCTAssertEqual(result.offerA.remainingNeed, .zero)
        XCTAssertNil(result.preferredOfferID)
    }

    func testConfirmedStockDeductedOnlyOnce() throws {
        let input = try request(need: quantity(12), stock: quantity(6), protected: quantity(2), yield: quantity(8))
        let result = try PackComparison.evaluate(input).offerA
        XCTAssertEqual(result.amountToBuy, try Rational(6))
        XCTAssertEqual(result.packsToBuy, 1)
        XCTAssertEqual(result.leftover, try Rational(2))
        XCTAssertEqual(result.protectedAmount, try Rational(2))
        XCTAssertThrowsError(try PackComparison.evaluate(request(need: quantity(1), protected: quantity(2), yield: quantity(8))))
    }

    func testCheaperKnownOfferPreferenceDoesNotAssertItemCap() throws {
        let input = ComparisonRequest(itemName: "Wraps", needed: try quantity(12),
            offerA: PackOffer(id: "a", label: "Eight", usableQuantity: try quantity(8), price: Money(minorUnits: 349)),
            offerB: PackOffer(id: "b", label: "Six", usableQuantity: try quantity(6), price: Money(minorUnits: 299)),
            itemCap: Money(minorUnits: 500))
        let result = try PackComparison.evaluate(input)
        XCTAssertEqual(result.preferredOfferID, "b")
        XCTAssertEqual(result.offerB.itemHeadroom?.minorUnits, -98)
        XCTAssertEqual(result.scope, .itemOnly)
    }

    func testUnknownYieldAndMissingPriceAreUnresolved() throws {
        let unknownYield = try PackComparison.evaluate(request(need: quantity(12)))
        XCTAssertNil(unknownYield.offerA.packsToBuy)
        XCTAssertNil(unknownYield.offerA.totalCost)
        XCTAssertTrue(unknownYield.offerA.issues.contains(.usableQuantityUnknown))
        XCTAssertNil(unknownYield.preferredOfferID)

        let missingPrice = try PackComparison.evaluate(request(need: quantity(12), yield: quantity(8), price: nil))
        XCTAssertEqual(missingPrice.offerA.packsToBuy, 2)
        XCTAssertNil(missingPrice.offerA.totalCost)
        XCTAssertNil(missingPrice.offerA.itemHeadroom)
        XCTAssertEqual(missingPrice.offerA.issues, [.priceUnknown])
        XCTAssertNil(missingPrice.preferredOfferID)

        let free = try PackComparison.evaluate(request(need: quantity(12), yield: quantity(8), price: .zero))
        XCTAssertEqual(free.offerA.totalCost, .zero)
        XCTAssertTrue(free.offerA.isResolved)
    }

    func testEmptyUnknownAndZeroNeedRemainDistinct() throws {
        let empty = try PackComparison.evaluate(request(need: nil))
        XCTAssertEqual(empty.offerA.issues, [.neededQuantityUnknown])
        XCTAssertNil(empty.offerA.totalCost)
        XCTAssertNil(empty.unit)

        let noNeed = try PackComparison.evaluate(request(need: quantity(0), price: nil))
        XCTAssertTrue(noNeed.offerA.isResolved)
        XCTAssertEqual(noNeed.offerA.packsToBuy, 0)
        XCTAssertEqual(noNeed.offerA.totalCost, .zero)
        XCTAssertNil(noNeed.offerA.unitCeiling)

        let enough = try PackComparison.evaluate(request(need: quantity(2), stock: quantity(5), price: nil))
        XCTAssertEqual(enough.offerA.packsToBuy, 0)
        XCTAssertEqual(enough.offerA.leftover, try Rational(3))
        XCTAssertEqual(enough.offerA.totalCost, .zero)
    }

    func testZeroYieldKeepsNeedOpen() throws {
        let result = try PackComparison.evaluate(request(need: quantity(5), yield: quantity(0))).offerA
        XCTAssertEqual(result.issues, [.noUsableYield])
        XCTAssertEqual(result.remainingNeed, try Rational(5))
        XCTAssertNil(result.totalCost)
        XCTAssertNil(result.packsToBuy)
    }

    func testMassConversionsPreservePackages() throws {
        let input = try request(need: quantity(30, unit: .ounce), yield: quantity(15, unit: .ounce))
        XCTAssertEqual(try PackComparison.evaluate(input).offerA.packsToBuy, 2)
        XCTAssertEqual(try quantity(1, unit: .pound).converted(to: .ounce), try Rational(16))
        XCTAssertEqual(try quantity(1, unit: .kilogram).converted(to: .gram), try Rational(1000))
        XCTAssertEqual(try quantity(1, unit: .cup).converted(to: .fluidOunce), try Rational(8))
        XCTAssertEqual(try quantity(1, unit: .pound).converted(to: .gram), try Rational(decimal: "453.59237"))
    }

    func testMassVolumeNeverAssumedAndConfirmedBasisIsScoped() throws {
        let input = try request(need: quantity(240, unit: .gram), yield: quantity(1, unit: .cup))
        let unresolved = try PackComparison.evaluate(input)
        XCTAssertEqual(unresolved.offerA.issues, [.usableConversionUnknown])
        XCTAssertNil(unresolved.offerA.packsToBuy)
        let basis = UnitBasis(sourceUnit: .cup, targetUnit: .gram,
                              targetAmountPerSourceUnit: try Rational(120), sourceNote: "Confirmed flour label")
        let offer = PackOffer(id: "a", label: "Flour", usableQuantity: try quantity(1, unit: .cup),
                              price: Money(minorUnits: 200), confirmedConversion: basis)
        let known = try PackComparison.evaluate(ComparisonRequest(itemName: "Flour", needed: input.needed,
                                                                   offerA: offer, offerB: input.offerB))
        XCTAssertEqual(known.offerA.packsToBuy, 2)
        XCTAssertTrue(known.offerA.isResolved)
        XCTAssertFalse(known.offerB.isResolved)
        XCTAssertNil(known.preferredOfferID)
        XCTAssertEqual(try quantity(60, unit: .gram).converted(to: .cup, using: basis), try Rational(1, 2))
        XCTAssertNil(try quantity(1, unit: .count).converted(to: .gram, using: basis))
    }

    func testUnconvertibleConfirmedStockAndProtectedQuantityBlockCoverage() throws {
        let stock = try PackComparison.evaluate(request(need: quantity(10), stock: quantity(3, unit: .gram), yield: quantity(8)))
        XCTAssertEqual(stock.offerA.issues, [.atHomeConversionUnknown])
        XCTAssertNil(stock.offerA.packsToBuy)
        let protected = try PackComparison.evaluate(request(need: quantity(10), protected: quantity(2, unit: .cup), yield: quantity(8)))
        XCTAssertEqual(protected.offerA.issues, [.protectedConversionUnknown])
        XCTAssertNil(protected.offerA.packsToBuy)
    }

    func testOverflowAndInvalidDataFailWithoutTrapping() throws {
        XCTAssertThrowsError(try Rational(-1))
        XCTAssertThrowsError(try Rational(1, 0))
        XCTAssertThrowsError(try Rational(1, -1))
        XCTAssertThrowsError(try Rational(Int64.max).adding(.one))
        XCTAssertThrowsError(try Rational(Int64.max).multiplied(by: Rational(2)))
        XCTAssertThrowsError(try Rational.one.divided(by: .zero))
        XCTAssertThrowsError(try Rational(decimal: "9223372036854775808"))
        XCTAssertThrowsError(try Rational(decimal: String(repeating: "1", count: 100)))
        XCTAssertThrowsError(try Money(minorUnits: Int64.max).multiplied(by: 2))
        XCTAssertThrowsError(try Money(minorUnits: Int64.min).subtracting(Money(minorUnits: 1)))
        XCTAssertThrowsError(try PackComparison.evaluate(request(need: quantity(2), yield: quantity(1), price: Money(minorUnits: Int64.max))))
        XCTAssertThrowsError(try PackComparison.evaluate(request(need: quantity(1), yield: quantity(1), price: Money(minorUnits: -1))))
        XCTAssertThrowsError(try PackComparison.evaluate(request(need: quantity(1), yield: quantity(1), cap: Money(minorUnits: -1))))
        XCTAssertThrowsError(try JSONDecoder().decode(Rational.self, from: Data(#"{"numerator":1,"denominator":0}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Money.self, from: Data(#"{"minorUnits":12,"currency":"EUR"}"#.utf8)))
        XCTAssertGreaterThan(try Rational(Int64.max, Int64.max - 1), .one)
        XCTAssertEqual(try Rational(Int64.max, 2).multiplied(by: Rational(2, Int64.max)), .one)
    }

    func testRequestRoundTripRetainsOriginalLabelsAndBasis() throws {
        let basis = UnitBasis(sourceUnit: .count, targetUnit: .gram, targetAmountPerSourceUnit: try Rational(150), sourceNote: "Label")
        let amount = Quantity(amount: try Rational(3, 2), unit: .count, originalLiteral: "1.500 unidades", confirmedConversion: basis)
        let input = try request(need: amount, yield: quantity(1))
        let restored = try JSONDecoder().decode(ComparisonRequest.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(restored, input)
        XCTAssertEqual(restored.needed?.originalLiteral, "1.500 unidades")
        XCTAssertEqual(try PackComparison.evaluate(restored), try PackComparison.evaluate(input))
    }

    func testRandomizedConservationAndMinimalWholePackages() throws {
        var state: UInt64 = 0xCA47_2026
        func next(_ bound: UInt64) -> Int64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int64((state >> 32) % bound)
        }
        for _ in 0..<2_000 {
            let denominator = next(20) + 1
            let need = try Rational(next(10_000), denominator)
            let stock = try Rational(next(10_000), denominator)
            let yield = try Rational(next(1_000) + 1, denominator)
            let protected = try need.divided(by: Rational(next(10) + 1))
            let price = next(1_000)
            let q: (Rational) -> Quantity = { Quantity(amount: $0, unit: .count, originalLiteral: $0.description) }
            let result = try PackComparison.evaluate(request(need: q(need), stock: q(stock), protected: q(protected),
                                                               yield: q(yield), price: Money(minorUnits: price))).offerA
            let packs = try XCTUnwrap(result.packsToBuy)
            let purchased = try XCTUnwrap(result.purchasedAmount)
            let leftover = try XCTUnwrap(result.leftover)
            XCTAssertEqual(try stock.adding(purchased), try need.adding(leftover))
            XCTAssertEqual(result.totalCost?.minorUnits, packs * price)
            XCTAssertEqual(result.remainingNeed, .zero)
            XCTAssertEqual(result.protectedAmount, protected)
            if packs > 0 {
                let oneFewer = try yield.multiplied(by: Rational(packs - 1))
                XCTAssertLessThan(try stock.adding(oneFewer), need)
            }
        }
    }

    func testSharedContractVectors() throws {
        struct Expected: Decodable {
            let packsToBuy: Int64?
            let totalMinorUnits: Int64?
            let leftover: Rational?
            let issues: [ComparisonIssue]
        }
        struct Vector: Decodable { let name: String; let request: ComparisonRequest; let expectedA: Expected; let expectedB: Expected }
        struct File: Decodable { let schemaVersion: Int; let fixtures: [Vector] }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let fixtureURL = root.appendingPathComponent("shared/contracts/pack-comparisons.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertGreaterThanOrEqual(file.fixtures.count, 8)
        for vector in file.fixtures {
            let result = try PackComparison.evaluate(vector.request)
            for (actual, expected) in [(result.offerA, vector.expectedA), (result.offerB, vector.expectedB)] {
                XCTAssertEqual(actual.packsToBuy, expected.packsToBuy, vector.name)
                XCTAssertEqual(actual.totalCost?.minorUnits, expected.totalMinorUnits, vector.name)
                XCTAssertEqual(actual.leftover, expected.leftover, vector.name)
                XCTAssertEqual(actual.issues, expected.issues, vector.name)
            }
        }
    }
}
