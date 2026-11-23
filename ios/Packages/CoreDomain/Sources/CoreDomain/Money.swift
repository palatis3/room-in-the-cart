import Foundation

public enum Currency: String, CaseIterable, Codable, Sendable {
    case usd = "USD"
    case mxn = "MXN"

    public static func groceryDefault(for locale: Locale = .current) -> Self {
        locale.region?.identifier == "MX" ? .mxn : .usd
    }

    /// Unknown evidence can share the currency of a known amount. Two explicit currencies never share a total.
    static func matching(_ currencies: [Self?]) throws -> Self? {
        let known = currencies.compactMap { $0 }
        guard known.allSatisfy({ $0 == known.first }) else { throw DomainError.invalidInput("currencyMismatch") }
        return known.first
    }
}

/// Signed minor units. Package prices and item caps must be nonnegative at the request boundary.
public struct Money: Codable, Hashable, Sendable {
    public let minorUnits: Int64
    public let currency: Currency
    public static let zero = Money(minorUnits: 0)

    public init(minorUnits: Int64, currency: Currency = .usd) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// Exact major-unit input. Fractional cents are rejected rather than silently rounded.
    public init(decimal: String, currency: Currency = .usd) throws {
        self.init(minorUnits: try Self.minorUnits(decimal: decimal), currency: currency)
    }

    public static func minorUnits(decimal: String) throws -> Int64 {
        let cents = try Rational(decimal: decimal).multiplied(by: Rational(100))
        guard cents.denominator == 1 else { throw DomainError.invalidNumber }
        return cents.numerator
    }

    // Amounts have an ordering only within their currency.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.currency == rhs.currency && lhs.minorUnits < rhs.minorUnits }
    public static func <= (lhs: Self, rhs: Self) -> Bool { lhs.currency == rhs.currency && lhs.minorUnits <= rhs.minorUnits }
    public static func > (lhs: Self, rhs: Self) -> Bool { rhs < lhs }
    public static func >= (lhs: Self, rhs: Self) -> Bool { rhs <= lhs }

    public func multiplied(by count: Int64) throws -> Self {
        guard count >= 0 else { throw DomainError.negativeQuantity }
        return Self(minorUnits: try checkedMultiply(minorUnits, count), currency: currency)
    }
    public func adding(_ other: Self) throws -> Self {
        guard currency == other.currency else { throw DomainError.invalidInput("currencyMismatch") }
        return Self(minorUnits: try checkedAdd(minorUnits, other.minorUnits), currency: currency)
    }
    public func subtracting(_ other: Self) throws -> Self {
        guard currency == other.currency else { throw DomainError.invalidInput("currencyMismatch") }
        let (result, overflow) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflow else { throw DomainError.overflow }
        return Self(minorUnits: result, currency: currency)
    }
}
