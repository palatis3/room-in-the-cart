import Foundation

/// Proposed divisions of an editable transcript. Substrings retain the original
/// indices and spelling, including when an item occurs several times.
public enum NaturalListSegmenter {
    public struct Item: Equatable, Sendable {
        public let wording: Substring
        public let needsBoundaryReview: Bool
    }

    public struct Proposal: Equatable, Sendable {
        public let items: [Item]
        public let timing: Substring?
        public let requiresTimingReview: Bool
    }

    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    // Keep a decimal comma inside a number. A connector inside a brand such as
    // M&M or a hyphenated name is never used as an item boundary.
    private static let tokens = try! NSRegularExpression(pattern:
        #"\r\n|\p{Nd}+(?:[.,/]\p{Nd}+)+|[\p{L}\p{M}\p{N}]+(?:['’&‑-][\p{L}\p{M}\p{N}]+)*|[^\h]"#)
    private static let timingPhrase = try! NSRegularExpression(pattern:
        #"(?i)\b(?:for\s+(?:(?:the\s+)?next|this)\s+(?:week|shop|pickup)|para\s+(?:la\s+(?:próxima|proxima|siguiente)\s+(?:semana|compra)|esta\s+(?:semana|compra)))\b"#)
    private static let conjunctions: Set<String> = ["and", "y", "e"]
    private static let scopeWords: Set<String> = [
        "for", "para", "to", "destino", "destination", "with", "con", "without", "except", "excluding",
        "avoid", "free", "no", "not", "sin", "excepto", "menos", "evitar", "libre"
    ]
    // These standalone grocery nouns give evidence for an unpunctuated list.
    // Unknown combinations stay together and the shopper can add a line break.
    private static let groceries: Set<String> = [
        "apple", "apples", "banana", "bananas", "beans", "bread", "broccoli", "butter", "carrots",
        "cereal", "cheese", "chicken", "coffee", "corn", "eggs", "flour", "juice", "lettuce", "milk", "milks",
        "oats", "oil", "onions", "oranges", "pasta", "peas", "potatoes", "rice", "salt", "sugar", "tea",
        "tomatoes", "tuna", "water", "yogurt", "agua", "aceite", "arroz", "atún", "avena", "azúcar", "brócoli",
        "café", "cebollas", "cereales", "elote", "espinacas", "frijoles", "garbanzos", "harina", "huevos",
        "jugo", "leche", "leches", "lechuga", "maíz", "mantequilla", "manzanas", "naranjas", "pan", "papas",
        "patatas", "plátanos", "pollo", "queso", "sal", "té", "tomates", "yogur", "zanahorias"
    ]
    private static let compounds: Set<String> = [
        "mac and cheese", "macaroni and cheese", "bread and butter", "butter and jelly", "biscuits and gravy",
        "half and half", "milk and honey", "rice and beans", "beans and rice", "ham and cheese", "salt and pepper",
        "oil and vinegar", "fish and chips", "arroz y frijoles", "frijoles y arroz", "jamón y queso", "sal y pimienta"
    ]
    private static let closers = ["(": ")", "[": "]", "«": "»", "“": "”", "‘": "’", "\"": "\"", "'": "'"]

    public static func propose(_ transcript: String, maximumItems: Int = 200) throws -> Proposal {
        guard maximumItems > 0, maximumItems <= StagedListImport.maximumLines else { throw LedgerError.invalid("importSize") }
        guard transcript.utf8.count <= StagedListImport.maximumTextBytes else { throw ImportTextLimit.totalBytes }
        let whole = NSRange(transcript.startIndex..., in: transcript)
        let words = tokens.matches(in: transcript, range: whole).compactMap { match -> Token? in
            guard let range = Range(match.range, in: transcript) else { return nil }
            return Token(text: transcript[range].lowercased(), range: range)
        }
        let timings = timingPhrase.matches(in: transcript, range: whole).compactMap { Range($0.range, in: transcript) }
        let timingStarts = Set(timings.map(\.lowerBound))
        var leadingTimingEnd: String.Index?
        var trailingTiming: Range<String.Index>?
        var batchTiming: Substring?
        if timings.count == 1, let range = timings.first {
            let tail = transcript[range.upperBound...]
            if tail.allSatisfy({ $0.isWhitespace || $0 == "." }) {
                trailingTiming = range
            } else if transcript[..<range.lowerBound].allSatisfy(\.isWhitespace),
                      let comma = tail.firstIndex(where: { !$0.isWhitespace }), transcript[comma] == "," {
                leadingTimingEnd = transcript.index(after: comma)
                batchTiming = transcript[range]
            }
        }

        var items: [Item] = []
        var first: String.Index?
        var last: String.Index?
        var ambiguous = false
        var quantityEndsAt = -1
        var sizeLabelEndsAt = -1
        var inField = false
        var quotes: [String] = []
        var requiresTimingReview = false

        func finish() throws {
            if let first, let last {
                guard items.count < maximumItems else { throw ImportTextLimit.nonblankLines(maximum: maximumItems) }
                items.append(Item(wording: transcript[first..<last], needsBoundaryReview: ambiguous))
            }
            first = nil
            last = nil
            inField = false
            ambiguous = false
        }

        for (index, token) in words.enumerated() {
            if let leadingTimingEnd, token.range.lowerBound < leadingTimingEnd { continue }
            let word = token.text
            let previous = index > 0 ? words[index - 1].text : ""
            let next = index + 1 < words.count ? words[index + 1].text : ""
            if first == nil, word.first?.isLetter == true || word.first?.isNumber == true {
                quantityEndsAt = leadingQuantityEnd(in: words, at: index)
            }
            if word.allSatisfy(\.isNewline) {
                try finish()
                quotes.removeAll()
                continue
            }
            if quotes.isEmpty, timingStarts.contains(token.range.lowerBound) {
                if let trailingTiming, token.range.lowerBound == trailingTiming.lowerBound, !inField, first != nil {
                    batchTiming = transcript[trailingTiming]
                    break
                }
                requiresTimingReview = true
            }
            if !quotes.isEmpty, quotes.last == word {
                quotes.removeLast()
            } else if let closer = closers[word] {
                quotes.append(closer)
            } else if quotes.isEmpty {
                if word == ";" {
                    try finish()
                    continue
                }
                if word == ",", !inField, !scopeWords.contains(next) {
                    if let end = perPackLabelEnd(in: words, after: index, transcript: transcript) {
                        sizeLabelEndsAt = end
                    } else {
                        try finish()
                        continue
                    }
                }
                if conjunctions.contains(word), !inField, index > max(quantityEndsAt, sizeLabelEndsAt) {
                    if first == nil, previous == "," { continue } // Oxford comma
                    if first != nil, !next.isEmpty {
                        let compound = compounds.contains(previous + " " + word + " " + next)
                        let nextCompound = index + 3 < words.count && compounds.contains(
                            next + " " + words[index + 2].text + " " + words[index + 3].text)
                        if !compound, groceries.contains(previous),
                           groceries.contains(next) || nextCompound || beginsAmount(next) {
                            try finish()
                            continue
                        }
                        if !compound { ambiguous = true }
                    }
                }
                if index > max(quantityEndsAt, sizeLabelEndsAt), scopeWords.contains(word) { inField = true }
            }
            if first == nil { first = token.range.lowerBound }
            last = token.range.upperBound
        }
        try finish()
        return Proposal(items: items, timing: batchTiming, requiresTimingReview: requiresTimingReview)
    }

    private static func leadingQuantityEnd(in words: [Token], at index: Int) -> Int {
        // Keep number connectors in the same quantity, e.g. “treinta y dos”
        // and “between two and three”. Only the start of each item is examined.
        let prefix = words[index...].prefix(20).map { ListQuantityParser.naturalAmountToken($0.text) }
        var remaining = prefix[...]
        if !ListQuantityParser.takeRange(from: &remaining) {
            guard let amount = try? ListQuantityParser.takeAmount(from: &remaining, allowingWords: true) else { return index - 1 }
            _ = ListQuantityParser.takeMeasure(amount, from: &remaining)
        }
        return index + prefix.count - remaining.count - 1
    }

    // A spoken comma can introduce a size on the previous product. Let the same
    // quantity grammar used for import decide whether this is a per-pack label.
    private static func perPackLabelEnd(in words: [Token], after index: Int, transcript: String) -> Int? {
        let rest = words[(index + 1)...].prefix(16)
        guard let start = rest.first, beginsAmount(start.text) else { return nil }
        for tokenIndex in rest.indices {
            let token = words[tokenIndex]
            if token.text == "," || token.text == ";" || token.text.allSatisfy(\.isNewline) { break }
            if token.text == "each" || token.text == "cada" {
                var fields = ListQuantityParser.itemTokens(String(transcript[start.range.lowerBound..<token.range.lowerBound]))
                let range = ListQuantityParser.takeRange(from: &fields)
                if !range {
                    guard (try? ListQuantityParser.takeAmount(from: &fields, allowingWords: true)) != nil,
                          ListQuantityParser.takeUnit(from: &fields) != nil else { return nil }
                }
                return fields.isEmpty ? tokenIndex : nil
            }
        }
        return nil
    }

    private static func beginsAmount(_ word: String) -> Bool {
        var tokens = [ListQuantityParser.naturalAmountToken(word)][...]
        return (try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true)) != nil
    }
}
