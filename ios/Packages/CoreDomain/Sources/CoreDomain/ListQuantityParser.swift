import Foundation

/// The two list entry paths share these exact quantities and US customary units.
/// A count remains available for ordinary item names with no measure.
public enum ListQuantityParser {
    public static func itemTokens(_ text: String) -> ArraySlice<String> {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        // Only expand a leading printed multiplier. Keep identifiers such as X15 in the product name.
        if let first = tokens.first, let index = first.firstIndex(where: { "xX×".contains($0) }) {
            let left = first[..<index], right = first[first.index(after: index)...]
            if !left.isEmpty, !right.isEmpty, left.utf8.allSatisfy({ (48...57).contains($0) }),
               (try? number(separatingUnit(String(right))?.amount ?? String(right), allowingWords: false)) != nil {
                tokens.replaceSubrange(tokens.startIndex...tokens.startIndex, with: [String(left), "×", String(right)])
            }
        }
        return tokens
    }

    public static func takeAmount(from tokens: inout ArraySlice<String>, allowingWords: Bool = false) throws -> Rational {
        guard let first = tokens.first else { throw DomainError.invalidNumber }
        var rest = tokens.dropFirst()
        if let measured = separatingUnit(first) {
            let amount = try number(measured.amount, allowingWords: false)
            tokens[tokens.startIndex] = measured.unit
            return amount
        }
        var amount = try number(first.lowercased(), allowingWords: allowingWords)
        if let next = rest.first, first.utf8.allSatisfy({ (48...57).contains($0) }) {
            let measured = separatingUnit(next)
            let literal = measured?.amount ?? next
            if isFractionToken(literal) {
                let fraction = try number(literal, allowingWords: false)
                guard fraction < .one else { throw DomainError.invalidNumber }
                amount = try amount.adding(fraction)
                if let measured { rest[rest.startIndex] = measured.unit }
                else { rest = rest.dropFirst() }
            }
        }
        tokens = rest
        return amount
    }

    /// Consume a unit before interpreting a bare number as an item count.
    /// In "onzas líquidas" the two words are one volume unit, distinct from "onzas".
    public static func takeUnit(from tokens: inout ArraySlice<String>) -> UnitOfMeasure? {
        guard let first = tokens.first?.lowercased() else { return nil }
        let unit: UnitOfMeasure
        if fluidOunces.contains(tokens.prefix(2).joined(separator: " ").lowercased()) {
            unit = .fluidOunce
            tokens = tokens.dropFirst(2)
        } else if let single = units[first] {
            unit = single
            tokens = tokens.dropFirst()
        } else { return nil }
        // Preserve capitalized product names such as De Cecco.
        if let connector = tokens.first, connector == "de" || connector == "of" { tokens = tokens.dropFirst() }
        return unit
    }

    public static func needsUnitReview(_ token: String?) -> Bool {
        guard let token else { return false }
        return unresolvedMeasures.contains(token.lowercased())
    }

    public struct PackLabel: Codable, Equatable, Sendable {
        public let count: Int?
        public let amountPerPack: Quantity?

        func validate() throws {
            guard count.map({ $0 >= 0 }) ?? true else { throw DomainError.negativeQuantity }
            try amountPerPack?.validate()
        }

        public var total: Quantity? {
            guard let count, let amountPerPack,
                  let amount = try? amountPerPack.amount.multiplied(by: Rational(Int64(count))) else { return nil }
            return Quantity(amount: amount, unit: amountPerPack.unit, originalLiteral: amountPerPack.originalLiteral)
        }
    }

    /// Parse an explicit pack chain, leaving the source product name in tokens.
    /// Inner package counts qualify the contents of one outer pack.
    public static func takePackLabel(count: Rational, from tokens: inout ArraySlice<String>, original: String) -> PackLabel? {
        let count = count.denominator == 1 ? Int(exactly: count.numerator) : nil
        if !consumePackMarker(from: &tokens) {
            // "2 15 oz cans of beans" places the size before the container.
            var rest = tokens
            guard let amount = try? takeAmount(from: &rest), let unit = takeUnit(from: &rest),
                  rest.first.map({ containers.contains($0.lowercased()) }) == true,
                  consumePackMarker(from: &rest) else { return nil }
            tokens = rest
            return PackLabel(count: count, amountPerPack: Quantity(amount: amount, unit: unit, originalLiteral: original))
        }
        let unresolved = PackLabel(count: count, amountPerPack: nil)
        if let labelled = trailingSize(in: &tokens, original: original) {
            return PackLabel(count: count, amountPerPack: labelled)
        }
        var multiplier = Rational.one
        while let amount = try? takeAmount(from: &tokens, allowingWords: true) {
            if consumePackMarker(from: &tokens) {
                guard amount.denominator == 1, let nested = try? multiplier.multiplied(by: amount) else { return unresolved }
                multiplier = nested
                continue
            }
            let measure = takeUnit(from: &tokens)
            guard !(measure == nil && needsUnitReview(tokens.first)), !tokens.isEmpty,
                  !tokens.contains(where: isPackMarker), let contents = try? multiplier.multiplied(by: amount)
            else { return unresolved }
            return PackLabel(count: count, amountPerPack: Quantity(amount: contents, unit: measure ?? .count,
                                                                    originalLiteral: original))
        }
        return unresolved
    }

    /// Both "beans, 15 oz each" and "frijoles, 15 onzas cada una" explicitly
    /// identify a per-pack amount. A bare number in the product name does not.
    private static func trailingSize(in tokens: inout ArraySlice<String>, original: String) -> Quantity? {
        guard let last = tokens.last?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ")")) else { return nil }
        var body = tokens.dropLast()
        if last == "una" || last == "uno" {
            guard body.last?.lowercased() == "cada" else { return nil }
            body = body.dropLast()
        } else if last != "each" { return nil }

        // A mixed fraction and a two-word unit occupy at most four tokens.
        for position in body.suffix(4).indices where position > body.startIndex {
            var suffix = Array(body[position...])[...]
            if let first = suffix.first, first.hasPrefix("(") { suffix[suffix.startIndex] = String(first.dropFirst()) }
            guard let amount = try? takeAmount(from: &suffix), let unit = takeUnit(from: &suffix), suffix.isEmpty else { continue }
            var name = body[..<position]
            if name.last == "de" { name = name.dropLast() }
            if let tail = name.last, tail.hasSuffix(",") { name[name.index(before: name.endIndex)] = String(tail.dropLast()) }
            guard !name.isEmpty, !name.contains(where: isPackMarker) else { return nil }
            tokens = name
            return Quantity(amount: amount, unit: unit, originalLiteral: original)
        }
        return nil
    }

    public static func isPackMarker(_ token: String) -> Bool {
        let word = token.lowercased()
        return containers.contains(word) || word == "×" || word == "x"
    }

    private static let containers: Set<String> = [
        "pack", "packs", "package", "packages", "box", "boxes", "can", "cans",
        "paquete", "paquetes", "caja", "cajas", "lata", "latas"
    ]

    private static func consumePackMarker(from tokens: inout ArraySlice<String>) -> Bool {
        guard let first = tokens.first, isPackMarker(first) else { return false }
        tokens = tokens.dropFirst()
        if let connector = tokens.first, ["of", "de"].contains(connector.lowercased()) { tokens = tokens.dropFirst() }
        if containers.contains(first.lowercased()), let separator = tokens.first, ["x", "×"].contains(separator.lowercased()) {
            tokens = tokens.dropFirst()
        }
        return true
    }

    /// Split a printed measure such as "15oz" or "15-ounce" only in an
    /// amount position. Identifiers and free-text product names remain intact.
    private static func separatingUnit(_ token: String) -> (amount: String, unit: String)? {
        guard let start = token.firstIndex(where: \.isLetter), start != token.startIndex else { return nil }
        let unit = String(token[start...])
        guard units[unit.lowercased()] != nil else { return nil }
        var amount = token[..<start]
        if amount.last == "-" { amount = amount.dropLast() }
        guard !amount.isEmpty else { return nil }
        return (String(amount), unit)
    }

    private static func isFractionToken(_ token: String) -> Bool {
        if token.count == 1, let character = token.first, fractions[character] != nil { return true }
        return token.contains("/") && token.utf8.allSatisfy { (48...57).contains($0) || $0 == 47 }
    }

    private static func number(_ text: String, allowingWords: Bool) throws -> Rational {
        if allowingWords {
            if let whole = words[text] { return try Rational(whole) }
            if ["half", "medio", "media"].contains(text) { return try Rational(1, 2) }
        }
        if let last = text.last, let (top, bottom) = fractions[last] {
            let prefix = text.dropLast()
            let fraction = try Rational(top, bottom)
            guard !prefix.isEmpty else { return fraction }
            guard prefix.utf8.allSatisfy({ (48...57).contains($0) }), let whole = Int64(prefix) else {
                throw DomainError.invalidNumber
            }
            return try Rational(whole).adding(fraction)
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let top = Int64(parts[0]), let bottom = Int64(parts[1]) { return try Rational(top, bottom) }
        return try Rational(decimal: text)
    }

    private static let fractions: [Character: (Int64, Int64)] = [
        "¼": (1, 4), "½": (1, 2), "¾": (3, 4), "⅓": (1, 3), "⅔": (2, 3),
        "⅛": (1, 8), "⅜": (3, 8), "⅝": (5, 8), "⅞": (7, 8)
    ]
    private static let words: [String: Int64] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "a": 1, "an": 1, "un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4,
        "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11,
        "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dieciséis": 16, "dieciseis": 16,
        "diecisiete": 17, "dieciocho": 18, "diecinueve": 19, "veinte": 20
    ]
    private static let fluidOunces: Set<String> = [
        "fl oz", "fl ounce", "fl ounces", "fluid ounce", "fluid ounces", "onza líquida", "onzas líquidas",
        "onza liquida", "onzas liquidas"
    ]
    private static let units: [String: UnitOfMeasure] = [
        "count": .count, "ct": .count, "each": .count, "unit": .count, "units": .count, "unidad": .count, "unidades": .count,
        "g": .gram, "gram": .gram, "grams": .gram, "gramo": .gram, "gramos": .gram,
        "kg": .kilogram, "kilogram": .kilogram, "kilograms": .kilogram, "kilogramo": .kilogram, "kilogramos": .kilogram,
        "kilo": .kilogram, "kilos": .kilogram,
        "oz": .ounce, "ounce": .ounce, "ounces": .ounce, "onza": .ounce, "onzas": .ounce,
        "lb": .pound, "lbs": .pound, "pound": .pound, "pounds": .pound, "libra": .pound, "libras": .pound,
        "ml": .milliliter, "milliliter": .milliliter, "milliliters": .milliliter, "mililitro": .milliliter, "mililitros": .milliliter,
        "l": .liter, "liter": .liter, "liters": .liter, "litro": .liter, "litros": .liter,
        "cup": .cup, "cups": .cup, "taza": .cup, "tazas": .cup
    ]
    private static let unresolvedMeasures: Set<String> = [
        "tbsp", "tsp", "tablespoon", "tablespoons", "teaspoon", "teaspoons", "dozen", "dozens", "scoop", "scoops",
        "handful", "handfuls", "pinch", "pinches", "bunch", "bunches", "about", "approximately", "fl", "fluid",
        "cucharada", "cucharadas", "cucharadita", "cucharaditas", "docena", "docenas", "puñado", "puñados",
        "manojo", "manojos", "pizca", "pizcas", "aproximadamente"
    ]
}
