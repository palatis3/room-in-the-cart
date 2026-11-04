import Foundation
import XCTest
import CoreDomain

final class CheckoutWeightPropertyTests: XCTestCase {
    func testMaximumWeightMatchesLargestAffordableBilledIncrement() throws {
        let commitmentsID = UUID()
        let produceID = UUID()
        let eligibleID = UUID()
        let ineligibleID = UUID()
        let context = CheckoutContext(storeID: "store", branchID: "branch", mode: .pickup, slot: "5 PM",
                                      commitmentsID: commitmentsID, observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      source: "Test quote")

        for seed: UInt64 in [0xCA47_2026, 0xFE_E5, 0xCE_17] {
            var state = seed
            func next(_ bound: UInt64) -> Int64 {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return Int64((state >> 32) % bound)
            }

            for index in 0..<160 {
                let rounding = WeightChargeRounding.allCases[index % WeightChargeRounding.allCases.count]
                let denominator = next(8) + 1
                // With an unknown rounding rule, whole-cent increments are still determinate.
                let rate = (next(29) + 1) * (rounding == .unknown ? denominator : 1)
                let eligibleItems = next(80)
                let ineligibleItems = next(40)
                let eligibleDiscount = next(50)
                let otherDiscount = next(30)
                let fixedFee = next(17)
                let grossThreshold = next(101)
                let grossFee = next(39)
                let netThreshold = next(81)
                let netFee = next(39)
                let tax = next(11)
                let deposit = next(11)
                let cap = next(160)
                let produceIsEligible = next(2) == 1
                let increment = try Rational(1, denominator)

                let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .components(
                    lines: [
                        CheckoutLine(id: eligibleID, name: "Eligible goods", cost: exact(eligibleItems)),
                        CheckoutLine(id: ineligibleID, name: "Ineligible goods", cost: exact(ineligibleItems),
                                     thresholdEligible: false),
                        CheckoutLine(id: produceID, name: "Produce", cost: .unknown(reason: "Not weighed"),
                                     thresholdEligible: produceIsEligible)
                    ],
                    lineSetComplete: true,
                    fees: [
                        CheckoutFee(id: "fixed", rule: .fixed(exact(fixedFee))),
                        CheckoutFee(id: "gross", rule: .waivedAt(threshold: money(grossThreshold),
                            belowThreshold: exact(grossFee), basis: .eligibleItemsBeforeDiscounts)),
                        CheckoutFee(id: "net", rule: .waivedAt(threshold: money(netThreshold),
                            belowThreshold: exact(netFee), basis: .eligibleItemsAfterEligibleDiscounts))
                    ],
                    discounts: [
                        CheckoutDiscount(id: "eligible", amount: exact(eligibleDiscount), reducesEligibleSubtotal: true),
                        CheckoutDiscount(id: "other", amount: exact(otherDiscount), reducesEligibleSubtotal: false)
                    ],
                    tax: exact(tax), deposits: exact(deposit)
                ))
                let checkoutCap = CheckoutCap(scope: .wholeCheckout, commitmentsID: commitmentsID, amount: money(cap))

                // Price each positive increment directly in integer cents. At 2,048 increments,
                // even the smallest step costs 256 cents before discounts. Subtracting the
                // largest possible discount (78 cents) still exceeds every generated cap.
                var best: (steps: Int64, charge: Int64, total: Int64)?
                for steps in Int64(1)...2_048 {
                    let numerator = steps * rate
                    var charge = numerator / denominator
                    let remainder = numerator % denominator
                    if rounding == .up && remainder > 0 { charge += 1 }
                    if rounding == .nearestCent && 2 * remainder >= denominator { charge += 1 }

                    let goods = eligibleItems + ineligibleItems + charge
                    let grossEligible = eligibleItems + (produceIsEligible ? charge : 0)
                    let netEligible = max(0, grossEligible - eligibleDiscount)
                    let total = max(0, goods - eligibleDiscount - otherDiscount) + tax + deposit + fixedFee
                        + (grossEligible < grossThreshold ? grossFee : 0)
                        + (netEligible < netThreshold ? netFee : 0)
                    if total <= cap { best = (steps, charge, total) }
                }

                let expected: CheckoutWeightLimit
                if let best {
                    expected = .maximum(weight: try Rational(best.steps, denominator),
                                        lineCost: money(best.charge), checkout: money(best.total))
                } else {
                    expected = .noPositiveIncrement
                }
                let scenario = "seed 0x\(String(seed, radix: 16)), case \(index)"
                do {
                    let actual = try CheckoutEngine.maximumWeight(quote: quote, cap: checkoutCap, lineID: produceID,
                        rate: money(rate), increment: increment, rounding: rounding)
                    XCTAssertEqual(actual, expected, scenario)
                } catch {
                    XCTFail("\(scenario) threw \(error)")
                }
            }
        }
    }

    private func money(_ cents: Int64) -> Money {
        Money(minorUnits: cents)
    }

    private func exact(_ cents: Int64) -> CostEvidence {
        .exact(money(cents))
    }
}
