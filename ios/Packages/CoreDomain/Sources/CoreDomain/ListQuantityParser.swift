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

    /// Consume a complete numeric food field without inferring a unit or ignoring trailing text.
    public static func numericAmount(_ text: String) throws -> Rational {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard value.utf8.count <= 64, value.allSatisfy({
            $0.isNumber || $0 == "." || $0 == "/" || ($0.isWhitespace && !$0.isNewline)
        }) else { throw DomainError.invalidNumber }
        var tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        let amount = try takeAmount(from: &tokens)
        guard tokens.isEmpty else { throw DomainError.invalidNumber }
        return amount
    }

    /// A measured fraction supplies quantity context in a plain list. A number
    /// inside a product name such as “Half Baked” does not supply a measure.
    static func takeListAmount(from tokens: inout ArraySlice<String>) throws -> Rational {
        let quarters = ["quarter", "quarters", "cuarto", "cuartos"]
        let halves = ["half", "media", "medio"]
        let prefix = tokens.prefix(6).map { $0.lowercased() }
        let hasQuarter = prefix.contains(where: quarters.contains)
        if hasQuarter || prefix.contains(where: halves.contains) {
            var rest = tokens
            do {
                let amount = try takeAmount(from: &rest, allowingWords: true)
                var afterMeasure = rest
                let measure = takeMeasure(amount, from: &afterMeasure)
                let consumed = tokens[..<afterMeasure.startIndex].map { $0.lowercased() }
                if consumed.contains(where: quarters.contains)
                    || (measure.unit != nil && consumed.contains(where: halves.contains)) {
                    tokens = rest
                    return amount
                }
            } catch {
                // “3 quarters of milk” must be reviewed instead of becoming three items.
                if hasQuarter { throw error }
            }
        }
        let packFollows = isPackMarker(tokens.dropFirst().first ?? "")
        return try takeAmount(from: &tokens, allowingWords: packFollows)
    }

    public static func takeAmount(from tokens: inout ArraySlice<String>, allowingWords: Bool = false) throws -> Rational {
        var rest = tokens
        let amount = try takeNumberPart(from: &rest, allowingWords: allowingWords)
        // A recognized prefix of a larger number is not an exact purchase quantity.
        if allowingWords, let next = rest.first, scales.contains(next) { throw DomainError.invalidNumber }
        tokens = rest
        return amount
    }

    private static func takeNumberPart(from tokens: inout ArraySlice<String>, allowingWords: Bool) throws -> Rational {
        guard let first = tokens.first else { throw DomainError.invalidNumber }
        var rest = tokens.dropFirst()
        if let measured = separatingUnit(first) {
            let amount = try number(measured.amount, allowingWords: false)
            tokens[tokens.startIndex] = measured.unit
            return amount
        }
        let word = first.lowercased()
        if allowingWords, startsHalfAndHalf(tokens) { throw DomainError.invalidNumber }
        if allowingWords, let quarter = try takeQuarters(from: &tokens) { return quarter }
        if allowingWords, ["a", "one"].contains(word), rest.first?.lowercased() == "half",
           !startsHalfAndHalf(rest) {
            tokens = rest.dropFirst()
            return try Rational(1, 2)
        }
        if allowingWords, word == "half", ["a", "an"].contains(rest.first?.lowercased() ?? "") {
            var measure = rest.dropFirst()
            if takeUnit(from: &measure) != nil || needsUnitReview(measure.first) { rest = rest.dropFirst() }
        }
        var amount: Rational
        if allowingWords, let tens = spokenTens(word, rest: &rest) { amount = try Rational(tens) }
        else { amount = try number(word, allowingWords: allowingWords) }
        let printedWhole = first.utf8.allSatisfy { (48...57).contains($0) }
        if (allowingWords || printedWhole), amount.denominator == 1, let fraction = try takeAddedFraction(from: &rest) {
            amount = try amount.adding(fraction)
            tokens = rest
            return amount
        }
        if let next = rest.first, printedWhole {
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
        if hyphenatedTens(first.lowercased()) == nil,
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
        let lowerStart = rest.startIndex
        guard takeRangeEndpoint(from: &rest, allowingAnd: !between) else { return false }
        _ = takeUnit(from: &rest)
        // In "between one and a half cup", the conjunction separates two endpoints.
        // In "between one and a half and two cups", it belongs to the first number.
        if between, !["and", "y"].contains(rest.first?.lowercased() ?? "") {
            let consumed = tokens[lowerStart..<rest.startIndex]
            guard let split = consumed.lastIndex(where: { ["and", "y"].contains($0.lowercased()) }) else { return false }
            var lower = consumed[..<split]
            guard takeRangeEndpoint(from: &lower) else { return false }
            _ = takeUnit(from: &lower)
            guard lower.isEmpty else { return false }
            rest = tokens[split...]
        }
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

    private static func startsHalfAndHalf(_ tokens: ArraySlice<String>) -> Bool {
        tokens.first?.lowercased() == "half"
            && ["and", "&"].contains(tokens.dropFirst().first?.lowercased() ?? "")
            && tokens.dropFirst(2).first?.lowercased() == "half"
    }

    /// A measured quarter is distinct from a product such as “2 Quarter Pounders”.
    private static func takeQuarters(from tokens: inout ArraySlice<String>, inSum: Bool = false, afterUnit: Bool = false) throws -> Rational? {
        var rest = tokens
        let numerator: Int64
        switch rest.first?.lowercased() {
        case "one", "a", "un", "uno", "1": numerator = 1; rest = rest.dropFirst()
        case "two", "dos", "2": numerator = 2; rest = rest.dropFirst()
        case "three", "tres", "3": numerator = 3; rest = rest.dropFirst()
        default: numerator = 1
        }
        guard let word = rest.first?.lowercased() else { return nil }
        switch word {
        case "quarter" where numerator == 1 || inSum, "cuarto" where numerator == 1: break
        case "quarters" where numerator > 1, "cuartos" where numerator > 1: break
        default: return nil
        }

        let tail = rest.dropFirst()
        var measure = tail
        let hasOf = ["of", "de"].contains(measure.first?.lowercased() ?? "")
        if hasOf { measure = measure.dropFirst() }
        let hasArticle = hasOf && ["a", "an", "un", "una"].contains(measure.first?.lowercased() ?? "")
        if hasArticle { measure = measure.dropFirst() }
        var unitProbe = measure
        if afterUnit && (tail.isEmpty || hasOf) {
            tokens = tail
        } else if takeUnitName(from: &unitProbe) != nil || needsUnitReview(measure.first) {
            tokens = measure
        } else if hasArticle && !measure.isEmpty {
            tokens = measure
        } else if hasOf {
            // “Three quarters of milk” lacks the unit to which the fraction applies.
            throw DomainError.invalidNumber
        } else if (inSum && tail.isEmpty) || ["to", "through", "hasta", "and", "y", "or", "o", "a"].contains(tail.first?.lowercased() ?? "") {
            tokens = tail
        } else {
            return nil
        }
        return try Rational(numerator, 4)
    }

    private static func takeAddedFraction(from tokens: inout ArraySlice<String>, afterUnit: Bool = false) throws -> Rational? {
        guard let connector = tokens.first?.lowercased(), connector == "and" || connector == "y" else { return nil }
        var rest = tokens.dropFirst()
        if let quarter = try takeQuarters(from: &rest, inSum: true, afterUnit: afterUnit) {
            tokens = rest
            return quarter
        }
        if connector == "and" {
            if ["a", "one"].contains(rest.first?.lowercased() ?? "") { rest = rest.dropFirst() }
            guard rest.first?.lowercased() == "half", !startsHalfAndHalf(rest) else { return nil }
        } else {
            guard ["media", "medio"].contains(rest.first?.lowercased() ?? "") else { return nil }
        }
        tokens = rest.dropFirst()
        return try Rational(1, 2)
    }

    private static let englishTens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                                      "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let spanishTens = ["treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60,
                                      "setenta": 70, "ochenta": 80, "noventa": 90]

    private static let englishDigits: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let spanishDigits: Set<String> = ["un", "una", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve"]

    private static func digit(_ word: String?, in allowed: Set<String>) -> Int64? {
        guard let word, allowed.contains(word) else { return nil }
        return words[word]
    }

    private static func hyphenatedTens(_ word: String) -> Int64? {
        guard word.contains("-") else { return nil }
        let parts = word.components(separatedBy: "-")
        guard parts.count == 2, let tens = englishTens[parts[0]], let ones = digit(parts[1], in: englishDigits) else { return nil }
        return Int64(tens) + ones
    }

    private static func spokenTens(_ word: String, rest: inout ArraySlice<String>) -> Int64? {
        if let tens = englishTens[word] {
            guard let ones = digit(rest.first?.lowercased(), in: englishDigits) else { return Int64(tens) }
            rest = rest.dropFirst()
            return Int64(tens) + ones
        }
        if let tens = spanishTens[word] {
            guard rest.first?.lowercased() == "y", let ones = digit(rest.dropFirst().first?.lowercased(), in: spanishDigits)
            else { return Int64(tens) }
            rest = rest.dropFirst(2)
            return Int64(tens) + ones
        }
        return hyphenatedTens(word)
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
        (try? takeNumberPart(from: &tokens, allowingWords: true)) != nil
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
        takeMeasure(nil, from: &tokens).unit
    }

    /// A mixed measure can put the unit before the fraction, as in "una taza y media de arroz".
    public static func takeMeasure(_ amount: Rational?, from tokens: inout ArraySlice<String>) -> (amount: Rational?, unit: UnitOfMeasure?) {
        guard let unit = takeUnitName(from: &tokens) else { return (amount, nil) }
        var measured = amount
        if let fraction = try? takeAddedFraction(from: &tokens, afterUnit: true) {
            let extra = fractionInUnit(fraction, unit: unit, from: &tokens)
            measured = nil
            if let amount, let extra { measured = try? amount.adding(extra) }
        }
        if let alternate = takeAlternateMeasure(from: &tokens),
           let amount = measured, !alternate.matches(amount, unit: unit) {
            measured = nil
        }
        // Preserve capitalized product names such as De Cecco.
        if let connector = tokens.first, connector == "de" || connector == "of" { tokens = tokens.dropFirst() }
        return (measured, unit)
    }

    private struct PrintedMeasure {
        let amount: Rational
        let unit: UnitOfMeasure
        let decimalPlaces: Int

        func matches(_ primary: Rational, unit primaryUnit: UnitOfMeasure) -> Bool {
            guard primaryUnit.dimension == unit.dimension,
                  let converted = try? Quantity(amount: primary, unit: primaryUnit, originalLiteral: "").converted(to: unit),
                  let difference = try? max(converted, amount).subtracting(min(converted, amount)) else { return false }
            if difference == .zero { return true }
            let halfPrintedIncrement = "0." + String(repeating: "0", count: decimalPlaces) + "5"
            guard let tolerance = try? Rational(decimal: halfPrintedIncrement) else { return false }
            return difference <= tolerance
        }
    }

    /// Only consume a complete second measurement. Parenthetical food names and slash-separated
    /// varieties remain part of the name. Compare using the precision actually printed on the label.
    private static func takeAlternateMeasure(from tokens: inout ArraySlice<String>) -> PrintedMeasure? {
        guard let marker = tokens.first?.first, marker == "(" || marker == "/" else { return nil }
        var parts = Array(tokens.prefix(5))
        parts[0].removeFirst()
        let offset = parts[0].isEmpty ? 1 : 0
        if marker == "(" {
            guard let close = parts.firstIndex(where: { $0.hasSuffix(")") }) else { return nil }
            parts = Array(parts[...close])
            parts[close].removeLast()
        }
        var measure = parts.dropFirst(offset)
        guard let first = measure.first else { return nil }
        let literal = (separatingUnit(first)?.amount ?? first).replacingOccurrences(of: ",", with: ".")
        guard let amount = try? Rational(decimal: literal) else { return nil }
        if let attached = separatingUnit(first) { measure[measure.startIndex] = attached.unit }
        else { measure = measure.dropFirst() }
        guard let unit = takeUnitName(from: &measure), marker != "(" || measure.isEmpty else { return nil }
        tokens = tokens.dropFirst(parts.count - measure.count)
        let precision = literal.split(separator: ".").dropFirst().first?.count ?? 0
        return PrintedMeasure(amount: amount, unit: unit, decimalPlaces: precision)
    }

    private static func takeUnitName(from tokens: inout ArraySlice<String>) -> UnitOfMeasure? {
        guard let first = tokens.first else { return nil }
        // The last word of a printed unit may touch its alternate size ("fl oz/355 ml").
        let pair = tokens.prefix(2)
        if pair.count == 2, let last = pair.last {
            let word = unitBeforeAlternate(last)
            if fluidOunces.contains(unitKey(first) + " " + unitKey(String(word))) {
                tokens = tokens.dropFirst(2)
                if word.count < last.count { tokens.insert(String(last.dropFirst(word.count)), at: tokens.startIndex) }
                return .fluidOunce
            }
        }
        let word = unitBeforeAlternate(first)
        guard let unit = units[unitKey(String(word))] else { return nil }
        if word.count == first.count { tokens = tokens.dropFirst() }
        else { tokens[tokens.startIndex] = String(first.dropFirst(word.count)) }
        return unit
    }

    private static func unitBeforeAlternate(_ token: String) -> Substring {
        let prefix = token.prefix { $0 != "/" && $0 != "(" }
        guard prefix.endIndex != token.endIndex else { return prefix }
        let suffix = token[token.index(after: prefix.endIndex)...]
        return suffix.isEmpty || suffix.first?.isNumber == true ? prefix : token[...]
    }

    /// In “one pound and a half ounce”, the second unit belongs to the fraction.
    private static func fractionInUnit(_ fraction: Rational, unit: UnitOfMeasure, from tokens: inout ArraySlice<String>) -> Rational? {
        var rest = tokens
        let hasOf = rest.first == "of" || rest.first == "de"
        if hasOf { rest = rest.dropFirst() }
        let hasArticle = ["a", "an", "un", "una"].contains(rest.first?.lowercased() ?? "")
        if hasArticle { rest = rest.dropFirst() }

        let start = rest
        if let otherUnit = takeUnitName(from: &rest) {
            // “of Cup Noodles” starts the food name. “de taza de arroz” names a unit.
            if hasOf && !hasArticle && !rest.isEmpty && rest.first != "of" && rest.first != "de" {
                return fraction
            }
            tokens = rest
            return try? Quantity(amount: fraction, unit: otherUnit, originalLiteral: fraction.description).converted(to: unit)
        }
        if needsUnitReview(start.first) || (hasArticle && ["of", "de"].contains(start.dropFirst().first ?? "")) {
            tokens = start.dropFirst()
            return nil
        }
        if hasArticle {
            tokens = start
            return nil
        }
        return fraction
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
                guard let number = try? takeAmount(from: &rest) else { return nil }
                let measure = takeMeasure(number, from: &rest)
                guard let unit = measure.unit else { return nil }
                size = measure.amount.map { Quantity(amount: $0, unit: unit, originalLiteral: original) }
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
            guard let amount else { return unresolved }
            let measure = takeMeasure(amount, from: &tokens)
            guard let perPack = measure.amount, let multiplier, !(measure.unit == nil && needsUnitReview(tokens.first)), !tokens.isEmpty,
                  !tokens.contains(where: isPackMarker), let contents = try? multiplier.multiplied(by: perPack)
            else { return unresolved }
            return PackLabel(count: count, amountPerPack: Quantity(amount: contents, unit: measure.unit ?? .count,
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
                guard let number = try? takeAmount(from: &suffix) else { continue }
                let measure = takeMeasure(number, from: &suffix)
                guard let unit = measure.unit else { continue }
                size = measure.amount.map { Quantity(amount: $0, unit: unit, originalLiteral: original) }
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
        let key = unitKey(String(unitBeforeAlternate(unit)))
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
        "diecisiete": 17, "dieciocho": 18, "diecinueve": 19, "veinte": 20,
        "veintiuno": 21, "veintiuna": 21, "veintiún": 21, "veintiun": 21, "veintidós": 22, "veintidos": 22,
        "veintitrés": 23, "veintitres": 23, "veinticuatro": 24, "veinticinco": 25, "veintiséis": 26,
        "veintiseis": 26, "veintisiete": 27, "veintiocho": 28, "veintinueve": 29
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
