import Foundation

public enum Currency: String, Codable, Sendable { case usd = "USD" }

/// Signed USD minor units. Negative adjustments/headroom are intentional;
/// package prices and item caps must be nonnegative at the request boundary.
public struct Money: Codable, Hashable, Sendable, Comparable {
    public let minorUnits: Int64
    public let currency: Currency
    public static let zero = Money(minorUnits: 0)

    public init(minorUnits: Int64, currency: Currency = .usd) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// Exact dollar input. Fractional cents are rejected rather than silently rounded.
    public init(decimal: String) throws {
        let cents = try Rational(decimal: decimal).multiplied(by: Rational(100))
        guard cents.denominator == 1 else { throw DomainError.invalidNumber }
        self.init(minorUnits: cents.numerator)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.minorUnits < rhs.minorUnits }
    public func multiplied(by count: Int64) throws -> Self {
        guard count >= 0 else { throw DomainError.negativeQuantity }
        return Self(minorUnits: try checkedMultiply(minorUnits, count))
    }
    public func subtracting(_ other: Self) throws -> Self {
        let (result, overflow) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflow else { throw DomainError.overflow }
        return Self(minorUnits: result)
    }
}
