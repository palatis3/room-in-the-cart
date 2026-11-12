import Foundation

public enum UnitDimension: String, Codable, Sendable { case count, mass, volume }

public enum UnitOfMeasure: String, Codable, CaseIterable, Sendable {
    case count, gram, kilogram, ounce, pound, milliliter, liter, fluidOunce, cup

    public var dimension: UnitDimension {
        switch self {
        case .count: return .count
        case .gram, .kilogram, .ounce, .pound: return .mass
        case .milliliter, .liter, .fluidOunce, .cup: return .volume
        }
    }

    /// Versioned exact US customary / metric definitions. Mass ounce and fluid
    /// ounce are deliberately separate. Count never implicitly means a package.
    public static let conversionTableVersion = "us-customary-metric-v1"

    var canonicalFactor: Rational {
        get throws {
            switch self {
            case .count, .gram, .milliliter: return .one
            case .kilogram, .liter: return try Rational(1_000)
            case .ounce: return try Rational(45_359_237, 1_600_000)
            case .pound: return try Rational(45_359_237, 100_000)
            case .fluidOunce: return try Rational(473_176_473, 16_000_000)
            case .cup: return try Rational(473_176_473, 2_000_000)
            }
        }
    }
}

/// Ingredient-specific, explicitly confirmed conversion, e.g. 1 cup = 120 grams.
/// This is not a global density guess. Preserve it with the observed quantity.
public struct UnitBasis: Codable, Hashable, Sendable {
    public let sourceUnit: UnitOfMeasure
    public let targetUnit: UnitOfMeasure
    public let targetAmountPerSourceUnit: Rational
    public let sourceNote: String
    /// Original measured equality. Older observations retain their normalized rate alone.
    public let sourceLiteral: String?
    public let targetLiteral: String?
    public init(sourceUnit: UnitOfMeasure, targetUnit: UnitOfMeasure,
                targetAmountPerSourceUnit: Rational, sourceNote: String = "",
                sourceLiteral: String? = nil, targetLiteral: String? = nil) {
        self.sourceUnit = sourceUnit
        self.targetUnit = targetUnit
        self.targetAmountPerSourceUnit = targetAmountPerSourceUnit
        self.sourceNote = sourceNote
        self.sourceLiteral = sourceLiteral
        self.targetLiteral = targetLiteral
    }

    func validate() throws {
        guard targetAmountPerSourceUnit > .zero, sourceNote.utf8.count <= 2_048,
              sourceUnit.dimension != targetUnit.dimension else {
            throw DomainError.invalidInput("conversionBasis")
        }
        if sourceLiteral != nil || targetLiteral != nil {
            guard let sourceLiteral, let targetLiteral,
                  try Self.measuredAmount(targetLiteral).divided(by: Self.measuredAmount(sourceLiteral)) == targetAmountPerSourceUnit
            else { throw DomainError.invalidInput("conversionBasis") }
        }
    }

    private static func measuredAmount(_ literal: String) throws -> Rational {
        guard literal.utf8.count <= StagedListImport.maximumOriginalLineBytes else { throw DomainError.invalidNumber }
        let text = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 64,
              text.allSatisfy({ $0.isNumber || $0 == "/" || $0 == "." || ($0.isWhitespace && !$0.isNewline) })
        else { throw DomainError.invalidNumber }
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        let amount = try ListQuantityParser.takeAmount(from: &tokens)
        guard tokens.isEmpty, amount > .zero else { throw DomainError.invalidNumber }
        return amount
    }
}

public struct Quantity: Codable, Hashable, Sendable {
    public let amount: Rational
    public let unit: UnitOfMeasure
    public let originalLiteral: String
    public let confirmedConversion: UnitBasis?

    public init(amount: Rational, unit: UnitOfMeasure, originalLiteral: String,
                confirmedConversion: UnitBasis? = nil) {
        self.amount = amount
        self.unit = unit
        self.originalLiteral = originalLiteral
        self.confirmedConversion = confirmedConversion
    }

    func validate() throws {
        // A reviewed list quantity can carry the entire source label.
        guard originalLiteral.utf8.count <= StagedListImport.maximumOriginalLineBytes else { throw DomainError.invalidInput("quantityLiteral") }
        try confirmedConversion?.validate()
    }

    /// Nil means unresolved. A zero amount requires no conversion to prove zero.
    public func converted(to target: UnitOfMeasure, using basis: UnitBasis? = nil) throws -> Rational? {
        try validate()
        try basis?.validate()
        if amount == .zero { return .zero }
        if unit.dimension == target.dimension {
            return try amount.multiplied(by: unit.canonicalFactor.divided(by: target.canonicalFactor))
        }
        guard let conversion = basis ?? confirmedConversion else { return nil }
        if unit.dimension == conversion.sourceUnit.dimension && target.dimension == conversion.targetUnit.dimension {
            let source = try amount.multiplied(by: unit.canonicalFactor.divided(by: conversion.sourceUnit.canonicalFactor))
            return try source.multiplied(by: conversion.targetAmountPerSourceUnit)
                .multiplied(by: conversion.targetUnit.canonicalFactor.divided(by: target.canonicalFactor))
        }
        if unit.dimension == conversion.targetUnit.dimension && target.dimension == conversion.sourceUnit.dimension {
            let source = try amount.multiplied(by: unit.canonicalFactor.divided(by: conversion.targetUnit.canonicalFactor))
            return try source.divided(by: conversion.targetAmountPerSourceUnit)
                .multiplied(by: conversion.sourceUnit.canonicalFactor.divided(by: target.canonicalFactor))
        }
        return nil
    }
}
