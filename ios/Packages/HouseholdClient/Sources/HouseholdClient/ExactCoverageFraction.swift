import Foundation

// Nonnegative integers in little-endian base 10^9. Coverage can combine more
// denominators than Decimal can represent, even though individual inputs fit.
private struct CoverageInteger: Comparable {
    private static let base: UInt64 = 1_000_000_000
    private let digits: [UInt64]

    init(_ text: String) {
        var digits = [UInt64](), bytes = text.utf8[...]
        while !bytes.isEmpty {
            digits.append(bytes.suffix(9).reduce(0) { $0 * 10 + UInt64($1 - 48) })
            bytes = bytes.dropLast(min(9, bytes.count))
        }
        self.init(digits)
    }

    private init(_ input: [UInt64]) {
        var normalized = input
        while normalized.last == 0 { normalized.removeLast() }
        digits = normalized
    }

    var text: String {
        guard let leading = digits.last else { return "0" }
        return String(leading) + digits.dropLast().reversed().map { String(format: "%09llu", $0) }.joined()
    }

    static func < (left: Self, right: Self) -> Bool {
        if left.digits.count != right.digits.count { return left.digits.count < right.digits.count }
        return left.digits.reversed().lexicographicallyPrecedes(right.digits.reversed())
    }
    static func + (left: Self, right: Self) -> Self {
        var result = [UInt64](), carry: UInt64 = 0
        for index in 0..<max(left.digits.count, right.digits.count) {
            let value = carry + (index < left.digits.count ? left.digits[index] : 0) + (index < right.digits.count ? right.digits[index] : 0)
            result.append(value % base)
            carry = value / base
        }
        result.append(carry)
        return Self(result)
    }
    static func * (left: Self, right: Self) -> Self {
        var result = Array(repeating: UInt64(0), count: left.digits.count + right.digits.count)
        for (i, a) in left.digits.enumerated() {
            var carry: UInt64 = 0
            for (j, b) in right.digits.enumerated() {
                let value = result[i+j] + a*b + carry
                result[i+j] = value % base
                carry = value / base
            }
            result[i + right.digits.count] = carry
        }
        return Self(result)
    }
}

extension SharedDeliveryCoverage.Fraction {
    static var zero: Self { .init(numerator: "0", denominator: "1") }

    func compare(_ other: Self) -> ComparisonResult {
        let left = CoverageInteger(numerator) * CoverageInteger(other.denominator)
        let right = CoverageInteger(other.numerator) * CoverageInteger(denominator)
        return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }

    func adding(_ other: Self) -> Self {
        if numerator == "0" { return other }
        if other.numerator == "0" { return self }
        if denominator == other.denominator {
            return .init(numerator: (CoverageInteger(numerator) + CoverageInteger(other.numerator)).text, denominator: denominator)
        }
        let left = CoverageInteger(numerator) * CoverageInteger(other.denominator)
        let right = CoverageInteger(other.numerator) * CoverageInteger(denominator)
        return .init(numerator: (left + right).text, denominator: (CoverageInteger(denominator) * CoverageInteger(other.denominator)).text)
    }
    func multiplied(by other: Self) -> Self {
        .init(numerator: (CoverageInteger(numerator) * CoverageInteger(other.numerator)).text,
              denominator: (CoverageInteger(denominator) * CoverageInteger(other.denominator)).text)
    }
}

struct ReviewedFoodSupply {
    let id: UUID
    let quantity: SharedMealQuantity?
    var matches: [SharedDeliveryPage.IngredientMatch]
    var reservations: [SharedDeliveryPage.Reservation]

    init(id: UUID, quantity: SharedMealQuantity?, matches: [SharedDeliveryPage.IngredientMatch], reservations: [SharedDeliveryPage.Reservation]) {
        self.id = id; self.quantity = quantity; self.matches = matches; self.reservations = reservations
    }
    init(_ source: SharedDeliveryPage.Source) {
        self.init(id: source.id, quantity: source.confirmed?.quantity, matches: source.matches ?? [], reservations: source.reservations ?? [])
    }
}
