import Foundation

/// The two list entry paths share these exact quantities and US customary units.
/// A count remains available for ordinary item names with no measure.
public enum ListQuantityParser {
    public static func itemTokens(_ text: String) -> ArraySlice<String> {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        // Only expand a leading printed multiplier. Keep identifiers such as X15 in the product name.
        if let first = tokens.first, let index = first.firstIndex(where: { "xX×".contains($0) }) {
            let left = first[..<index], right = first[first.index(after: index)...]
            if !left.isEmpty, !right.isEmpty, left.utf8.allSatisfy({ (48...57).contains($0) }) {
                let size = String(right)
                var range = [size][...]
                if (try? number(separatingUnit(size)?.amount ?? size, allowingWords: false)) != nil
                    || (takeRange(from: &range) && range.isEmpty) {
                    tokens.replaceSubrange(tokens.startIndex...tokens.startIndex, with: [String(left), "×", size])
                }
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

    /// Consume both endpoints together. Neither endpoint is an exact purchase quantity.
    /// Leave product names (including model numbers) outside amount positions alone.
    public static func takeRange(from tokens: inout ArraySlice<String>) -> Bool {
        var rest = tokens
        let prefix = rest.first?.lowercased()
        let between = prefix == "between" || prefix == "entre"
        if between || prefix == "from" || prefix == "de" { rest = rest.dropFirst() }
        guard let first = rest.first else { return false }
        let dashes = "-–—"
        if !isHyphenatedTens(first.lowercased()),
           let dash = first.firstIndex(where: dashes.contains), dash != first.startIndex {
            var low = [String(first[..<dash])][...]
            if takeRangeEndpoint(from: &low) {
                _ = takeUnit(from: &low)
                if low.isEmpty {
                    let upper = first[first.index(after: dash)...]
                    var end = rest
                    if upper.isEmpty { end = end.dropFirst() }
                    else { end[end.startIndex] = String(upper) }
                    if takeRangeEndpoint(from: &end) {
                        _ = takeUnit(from: &end)
                        tokens = end
                        return true
                    }
                }
            }
        }
        guard takeRangeEndpoint(from: &rest, allowingAnd: !between) else { return false }
        _ = takeUnit(from: &rest)
        guard let connector = rest.first?.lowercased() else { return false }
        if between {
            guard connector == "and" || connector == "y" else { return false }
            rest = rest.dropFirst()
        } else if let mark = connector.first, dashes.contains(mark) {
            if connector.count == 1 { rest = rest.dropFirst() }
            else { rest[rest.startIndex] = String(connector.dropFirst()) }
        } else {
            guard ["to", "through", "a", "hasta", "or", "o"].contains(connector) else { return false }
            rest = rest.dropFirst()
        }
        guard takeRangeEndpoint(from: &rest) else { return false }
        _ = takeUnit(from: &rest)
        tokens = rest
        return true
    }

    // These words establish a range without assigning a numeric value to either end.
    // Standalone exact number parsing keeps its existing vocabulary.
    private static let englishTens: Set<String> = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let spanishTens: Set<String> = ["treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa"]
    private static let spanishTwenties: Set<String> = ["veintiuno", "veintiuna", "veintiún", "veintiun", "veintidós", "veintidos",
        "veintitrés", "veintitres", "veinticuatro", "veinticinco", "veintiséis", "veintiseis", "veintisiete", "veintiocho", "veintinueve"]

    private static func singleDigitWord(_ word: String) -> Bool {
        guard let digit = words[word], (1...9).contains(digit) else { return false }
        return word != "a" && word != "an"
    }

    private static func isHyphenatedTens(_ word: String) -> Bool {
        let parts = word.split(separator: "-", maxSplits: 1)
        return parts.count == 2 && englishTens.contains(String(parts[0])) && singleDigitWord(String(parts[1]))
    }

    private static let scales: Set<String> = [
        "hundred", "thousand", "million", "billion", "trillion", "cien", "ciento", "mil", "millón", "millon", "millones",
        "doscientos", "doscientas", "trescientos", "trescientas", "cuatrocientos", "cuatrocientas", "quinientos", "quinientas",
        "seiscientos", "seiscientas", "setecientos", "setecientas", "ochocientos", "ochocientas", "novecientos", "novecientas"
    ]

    private static func takeRangeEndpoint(from tokens: inout ArraySlice<String>, allowingAnd: Bool = true) -> Bool {
        var rest = tokens
        if rest.first.map({ scales.contains($0.lowercased()) }) != true,
           !takeNumberPart(from: &rest) { return false }
        while rest.first.map({ scales.contains($0.lowercased()) }) == true {
            rest = rest.dropFirst()
            var remainder = rest
            if allowingAnd, remainder.first?.lowercased() == "and" { remainder = remainder.dropFirst() }
            // Spanish "a" between endpoints must remain available to the range parser.
            if remainder.first?.lowercased() != "a", takeNumberPart(from: &remainder) { rest = remainder }
        }
        tokens = rest
        return true
    }

    private static func takeNumberPart(from tokens: inout ArraySlice<String>) -> Bool {
        guard let word = tokens.first?.lowercased() else { return false }
        var rest = tokens.dropFirst()
        if englishTens.contains(word) {
            if rest.first.map({ singleDigitWord($0.lowercased()) }) == true { rest = rest.dropFirst() }
        } else if spanishTens.contains(word) {
            if rest.first?.lowercased() == "y", rest.dropFirst().first.map({ singleDigitWord($0.lowercased()) }) == true {
                rest = rest.dropFirst(2)
            }
        } else if !spanishTwenties.contains(word) && !isHyphenatedTens(word) {
            return (try? takeAmount(from: &tokens, allowingWords: true)) != nil
        }
        tokens = rest
        return true
    }

    /// Count initial "to" markers consumed by an amount or its pack label.
    /// The first marker still in the product text can start a named destination.
    public static func quantityConnectorCount(in clause: String) -> Int {
        let words = itemTokens(clause)
        var product = words
        let ranged = takeRange(from: &product)
        let count = ranged ? nil : try? takeAmount(from: &product, allowingWords: true)
        guard ranged || count != nil else { return 0 }
        _ = takePackLabel(count: count, from: &product, original: clause)
        var consumed = 0
        for index in words.indices where words[index].lowercased() == "to" {
            if product.indices.contains(index) { break }
            consumed += 1
        }
        return consumed
    }

    /// Consume a unit before interpreting a bare number as an item count.
    /// In "onzas líquidas" the two words are one volume unit, distinct from "onzas".
    public static func takeUnit(from tokens: inout ArraySlice<String>) -> UnitOfMeasure? {
        guard let first = tokens.first.map(unitKey) else { return nil }
        let unit: UnitOfMeasure
        if fluidOunces.contains(tokens.prefix(2).map(unitKey).joined(separator: " ")) {
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
        return unresolvedMeasures.contains(unitKey(token))
    }

    // Printed abbreviations may end in a period. Only normalize candidate units,
    // leaving product names and the original label untouched.
    private static func unitKey(_ token: String) -> String {
        let word = token.lowercased()
        return word.hasSuffix(".") ? String(word.dropLast()) : word
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
    public static func takePackLabel(count: Rational?, from tokens: inout ArraySlice<String>, original: String) -> PackLabel? {
        let count = count.flatMap { $0.denominator == 1 ? Int(exactly: $0.numerator) : nil }
        let unresolved = PackLabel(count: count, amountPerPack: nil)
        if !consumePackMarker(from: &tokens) {
            // "2 15 oz cans of beans" places the size before the container.
            var rest = tokens
            let size: Quantity?
            if takeRange(from: &rest) { size = nil }
            else {
                guard let amount = try? takeAmount(from: &rest), let unit = takeUnit(from: &rest) else { return nil }
                size = Quantity(amount: amount, unit: unit, originalLiteral: original)
            }
            guard rest.first.map({ containers.contains($0.lowercased()) }) == true,
                  consumePackMarker(from: &rest) else { return nil }
            tokens = rest
            return PackLabel(count: count, amountPerPack: size)
        }
        if let labelled = trailingSize(in: &tokens, count: count, original: original) { return labelled }
        var multiplier: Rational? = .one
        while !tokens.isEmpty {
            let amount: Rational?
            if takeRange(from: &tokens) { amount = nil }
            else if let exact = try? takeAmount(from: &tokens, allowingWords: true) { amount = exact }
            else { return unresolved }
            if consumePackMarker(from: &tokens) {
                if let amount, amount.denominator == 1 { multiplier = try? multiplier?.multiplied(by: amount) }
                else { multiplier = nil }
                continue
            }
            let measure = amount == nil ? nil : takeUnit(from: &tokens)
            guard let amount, let multiplier, !(measure == nil && needsUnitReview(tokens.first)), !tokens.isEmpty,
                  !tokens.contains(where: isPackMarker), let contents = try? multiplier.multiplied(by: amount)
            else { return unresolved }
            return PackLabel(count: count, amountPerPack: Quantity(amount: contents, unit: measure ?? .count,
                                                                    originalLiteral: original))
        }
        return unresolved
    }

    /// Both "beans, 15 oz each" and "frijoles, 15 onzas cada una" explicitly
    /// identify a per-pack amount. A bare number in the product name does not.
    private static func trailingSize(in tokens: inout ArraySlice<String>, count: Int?, original: String) -> PackLabel? {
        guard let last = tokens.last?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ")")) else { return nil }
        var body = tokens.dropLast()
        if last == "una" || last == "uno" {
            guard body.last?.lowercased() == "cada" else { return nil }
            body = body.dropLast()
        } else if last != "each" { return nil }

        // Work forward so a range consumes its upper bound before it can be mistaken for an exact label.
        for position in body.indices.dropFirst() {
            var suffix = body[position...]
            if let first = suffix.first, first.hasPrefix("(") { suffix[suffix.startIndex] = String(first.dropFirst()) }
            let size: Quantity?
            if takeRange(from: &suffix) { size = nil }
            else {
                guard let amount = try? takeAmount(from: &suffix), let unit = takeUnit(from: &suffix) else { continue }
                size = Quantity(amount: amount, unit: unit, originalLiteral: original)
            }
            guard suffix.isEmpty else { continue }
            var name = body[..<position]
            if name.last == "de" { name = name.dropLast() }
            if let tail = name.last, tail.hasSuffix(",") { name[name.index(before: name.endIndex)] = String(tail.dropLast()) }
            guard !name.isEmpty, !name.contains(where: isPackMarker) else { return nil }
            tokens = name
            return PackLabel(count: count, amountPerPack: size)
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
        let key = unitKey(unit)
        guard units[key] != nil || unresolvedMeasures.contains(key) else { return nil }
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
        "onza liquida", "onzas liquidas", "oz líq", "oz liq", "oz líquidas", "oz liquidas"
    ]
    private static let units: [String: UnitOfMeasure] = [
        "count": .count, "ct": .count, "each": .count, "unit": .count, "units": .count, "unidad": .count, "unidades": .count,
        "g": .gram, "gram": .gram, "grams": .gram, "gramo": .gram, "gramos": .gram,
        "kg": .kilogram, "kilogram": .kilogram, "kilograms": .kilogram, "kilogramo": .kilogram, "kilogramos": .kilogram,
        "kilo": .kilogram, "kilos": .kilogram,
        "fl.oz": .fluidOunce, "floz": .fluidOunce,
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
