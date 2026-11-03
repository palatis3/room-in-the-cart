import Foundation

public enum WeightChargeRounding: String, CaseIterable, Sendable { case unknown, up, nearestCent }
public enum CheckoutWeightLimit: Equatable, Sendable {
    case unresolved
    case noPositiveIncrement
    case maximum(weight: Rational, lineCost: Money, checkout: Money)
}

extension CheckoutEngine {
    /// One variable-weight line under a reviewed whole-pickup cap. The retailer bills in
    /// multiples of increment, in the same mass unit as rate. All other original lines stay.
    public static func maximumWeight(quote: CheckoutQuote, cap: CheckoutCap?, lineID: UUID,
                                     rate: Money, increment: Rational, rounding: WeightChargeRounding) throws -> CheckoutWeightLimit {
        guard quote.scope == .wholeCheckout, let cap, cap.scope == quote.scope,
              cap.commitmentsID == quote.context.commitmentsID, cap.amount.minorUnits >= 0,
              rate.minorUnits > 0, increment > .zero,
              case let .components(lines, complete, fees, discounts, tax, deposits) = quote.pricing,
              complete, lines.contains(where: { $0.id == lineID }) else { return .unresolved }
        _ = try evaluate(quote, cap: cap)
        func exact(_ evidence: CostEvidence) -> Money? {
            switch evidence {
            case .exact(let value): return value
            case .bounded(let lower, let upper, _) where lower == upper: return lower
            default: return nil
            }
        }
        guard let taxAmount = exact(tax), let depositAmount = exact(deposits) else { return .unresolved }
        var otherItems = Money(minorUnits: 0), reductions = Money(minorUnits: 0)
        for item in lines where item.id != lineID {
            guard let amount = exact(item.cost) else { return .unresolved }
            otherItems = try Money(minorUnits: checkedAdd(otherItems.minorUnits, amount.minorUnits))
        }
        for discount in discounts {
            guard let amount = exact(discount.amount) else { return .unresolved }
            reductions = try Money(minorUnits: checkedAdd(reductions.minorUnits, amount.minorUnits))
        }
        let available = try cap.amount.subtracting(taxAmount).subtracting(depositAmount)
        guard available.minorUnits >= 0 else { return .noPositiveIncrement }
        let remainder = try available.subtracting(otherItems)
        let beforeFees = try Money(minorUnits: checkedAdd(remainder.minorUnits, reductions.minorUnits))
        guard beforeFees.minorUnits >= 0 else { return .noPositiveIncrement }
        let stepCost = try increment.multiplied(by: Rational(rate.minorUnits))
        guard rounding != .unknown || stepCost.denominator == 1 else { return .unresolved }

        // Start with the largest possible weight before fees. Every downward threshold
        // crossing can only add charges. Re-solve at the new fee until a candidate fits.
        var allowance = beforeFees
        for _ in 0...(fees.count + 1) {
            let limit = try Rational(allowance.minorUnits)
            let steps: Int64
            if rounding == .nearestCent {
                // Half a cent rounds up, so the upper endpoint is exclusive.
                steps = try limit.adding(Rational(1, 2)).divided(by: stepCost).roundedUp() - 1
            } else {
                let ratio = try limit.divided(by: stepCost)
                steps = ratio.numerator / ratio.denominator
            }
            guard steps > 0 else { return .noPositiveIncrement }
            let rawCharge = try stepCost.multiplied(by: Rational(steps))
            let cents: Int64
            if rounding == .nearestCent {
                let adjusted = try rawCharge.adding(Rational(1, 2))
                cents = adjusted.numerator / adjusted.denominator
            } else { cents = try rawCharge.roundedUp() }
            let charge = Money(minorUnits: cents)
            let priced = lines.map { item in
                item.id == lineID ? CheckoutLine(id: item.id, name: item.name, cost: .exact(charge), thresholdEligible: item.thresholdEligible) : item
            }
            let proposed = CheckoutQuote(scope: quote.scope, context: quote.context, pricing: .components(lines: priced,
                lineSetComplete: true, fees: fees, discounts: discounts, tax: tax, deposits: deposits))
            let result = try evaluateWithFees(proposed)
            guard let total = result.result.total.exact, let fee = result.fees?.exact else { return .unresolved }
            if total.minorUnits <= cap.amount.minorUnits {
                return try .maximum(weight: increment.multiplied(by: Rational(steps)), lineCost: charge, checkout: total)
            }
            guard fee.minorUnits <= available.minorUnits else { return .noPositiveIncrement }
            let next = try beforeFees.subtracting(fee)
            guard next.minorUnits >= 0, next.minorUnits < allowance.minorUnits else { return .noPositiveIncrement }
            allowance = next
        }
        return .unresolved
    }
}
