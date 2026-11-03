import Foundation

public enum DomainError: Error, Equatable, Sendable {
    case invalidNumber
    case negativeQuantity
    case divisionByZero
    case overflow
    case invalidInput(String)
}

/// Exact, nonnegative food quantity. Arithmetic never uses floating point.
public struct Rational: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public static let zero = Rational(normalized: 0, denominator: 1)
    public static let one = Rational(normalized: 1, denominator: 1)

    public init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
        guard denominator > 0 else { throw DomainError.divisionByZero }
        guard numerator >= 0 else { throw DomainError.negativeQuantity }
        let divisor = Self.gcd(numerator, denominator)
        self.init(normalized: numerator / divisor, denominator: denominator / divisor)
    }

    public init(numerator: Int64, denominator: Int64 = 1) throws {
        try self.init(numerator, denominator)
    }

    private init(normalized numerator: Int64, denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Accepts plain ASCII decimals, never exponent notation or a localized separator.
    /// The caller retains the user's source literal in Quantity.
    public init(decimal: String) throws {
        guard !decimal.isEmpty, decimal.utf8.count <= 64 else { throw DomainError.invalidNumber }
        let parts = decimal.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || !parts[1].isEmpty else { throw DomainError.invalidNumber }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        while fraction.last == "0" { fraction.removeLast() }
        guard fraction.count <= 18 else { throw DomainError.overflow }
        var scale: Int64 = 1
        for _ in fraction { scale = try checkedMultiply(scale, 10) }
        guard let whole = Int64(parts[0]), let remainder = Int64(fraction.isEmpty ? "0" : fraction) else {
            throw DomainError.overflow
        }
        try self.init(checkedAdd(checkedMultiply(whole, scale), remainder), scale)
    }

    public var description: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }
    /// Display approximation only; never used by the calculator.
    public var approximateValue: Double { Double(numerator) / Double(denominator) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let a = UInt64(lhs.numerator).multipliedFullWidth(by: UInt64(rhs.denominator))
        let b = UInt64(rhs.numerator).multipliedFullWidth(by: UInt64(lhs.denominator))
        return a.high == b.high ? a.low < b.low : a.high < b.high
    }

    public func adding(_ other: Self) throws -> Self {
        let divisor = Self.gcd(denominator, other.denominator)
        let left = try checkedMultiply(numerator, other.denominator / divisor)
        let right = try checkedMultiply(other.numerator, denominator / divisor)
        return try Self(checkedAdd(left, right), checkedMultiply(denominator, other.denominator / divisor))
    }

    public func subtracting(_ other: Self) throws -> Self {
        guard self >= other else { throw DomainError.negativeQuantity }
        let divisor = Self.gcd(denominator, other.denominator)
        let left = try checkedMultiply(numerator, other.denominator / divisor)
        let right = try checkedMultiply(other.numerator, denominator / divisor)
        return try Self(left - right, checkedMultiply(denominator, other.denominator / divisor))
    }

    public func multiplied(by other: Self) throws -> Self {
        let a = Self.gcd(numerator, other.denominator)
        let b = Self.gcd(other.numerator, denominator)
        return try Self(checkedMultiply(numerator / a, other.numerator / b),
                        checkedMultiply(denominator / b, other.denominator / a))
    }

    public func divided(by other: Self) throws -> Self {
        guard other.numerator > 0 else { throw DomainError.divisionByZero }
        let a = Self.gcd(numerator, other.numerator)
        let b = Self.gcd(other.denominator, denominator)
        return try Self(checkedMultiply(numerator / a, other.denominator / b),
                        checkedMultiply(denominator / b, other.numerator / a))
    }

    public func roundedUp() throws -> Int64 {
        try checkedAdd(numerator / denominator, numerator % denominator == 0 ? 0 : 1)
    }

    private static func gcd(_ first: Int64, _ second: Int64) -> Int64 {
        var a = first, b = second
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private enum CodingKeys: String, CodingKey { case numerator, denominator }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode(Int64.self, forKey: .numerator), c.decode(Int64.self, forKey: .denominator))
    }
}

func checkedAdd(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (result, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw DomainError.overflow }
    return result
}

func checkedMultiply(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow else { throw DomainError.overflow }
    return result
}
