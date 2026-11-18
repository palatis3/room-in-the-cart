import Foundation
import CoreDomain

enum PantryVoiceIntent: Equatable, Sendable {
    case consume([PantryVoiceItem])
    case dateQuery(String)
    case observation(PantryVoiceObservation)
    case askRemaining(food: String?, original: String)
    case needsReview(String)
}

struct PantryVoiceItem: Equatable, Sendable {
    let original: String
    let food: String
    let amount: PantryVoiceAmount
}

enum PantryVoiceAmount: Equatable, Sendable {
    case measured(Quantity)
    case pieces(Rational, String)
    case all
    case someUsed
    case unknown
}

struct PantryVoiceObservation: Equatable, Sendable {
    let food: String
    let original: String
    let remaining: PantryVoiceRemaining
    let remainingWording: String
}

enum PantryVoiceRemaining: Equatable, Sendable {
    case low, some, nearlyEmpty, empty
    case fraction(Rational, container: String?)
    case lessThanFraction(Rational, container: String?)
    case aboutFraction(Rational, container: String?)
}

/// Produces review proposals. The interpreter neither looks up batches nor changes stock.
enum PantryVoiceParser {
    private static let container = #"bottle|jar|carton|bag|box|can|botella|frasco|cartón|bolsa|caja|lata"#
    private static let vague = #"some|a little(?: bit)?(?: of)?|a bit of|un poco de|algo de"#
    private static let pieces = ["piece", "pieces", "slice", "slices", "rebanada", "rebanadas", "trozo",
                                 "trozos", "pedazo", "pedazos", "pieza", "piezas"]

    static func parse(_ text: String, localeIdentifier: String) -> PantryVoiceIntent {
        let review = PantryVoiceIntent.needsReview(text)
        guard !text.isEmpty, text.utf8.count <= 2_048, !text.contains(where: \.isNewline) else { return review }
        let locale = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        guard locale == "en" || locale == "es" else { return review }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let spoken = trimmed.replacingOccurrences(of: #"^(?:hey|oye)[,\s]+|\s*[.!]+$"#,
                                                  with: "", options: [.regularExpression, .caseInsensitive])
        // Dictation may append this courtesy request as a separate question. Strip only this
        // exact ending after a use command, leaving substantive questions for review.
        let update = #"^(.*?)(?:\s*[,.;!—–]\s*|\s+)(?:can you (?:please )?update my (?:fridge|pantry)(?:,? please)?|¿?puedes actualizar mi (?:despensa|refrigerador)(?:,? por favor)?)\??$"#
        let command: String
        if let beforeUpdate = groups(update, spoken)?.first {
            guard matches(#"^(?:(?:i (?:just )?)?used|(?:yo )?(?:ya )?usé|acabo de usar|delete|remove|borra|elimina|quita)\b"#, beforeUpdate) else { return review }
            command = beforeUpdate
        } else { command = spoken }
        if let target = dateFood(command) { return .dateQuery(target) }
        guard !command.contains("?"), !command.contains("¿"),
              !matches(#"\b(?:expired|expire[sd]?|expiration|caduc\w*|vencid\w*|vence|if|unless|instead|except|but|rather|or|not|never|no|nunca|pero|excepto|quizás|tal vez|maybe|think)\b"#, command)
        else { return review }

        if let observation = observation(command, original: text) { return .observation(observation) }
        let allForms = [
            #"^(?:delete|remove) (?:the |my )?(.+?)[,\s]+(?:because )?i (?:just )?used (?:it|them) all$"#,
            #"^(?:borra|elimina|quita) (?:(?:el|la|los|las|mi|mis) )?(.+?)[,\s]+(?:porque )?(?:ya )?(?:lo|la|los|las) (?:usé|use) tod[oa]s?$"#,
            #"^(?:i (?:just )?used|used) all (?:of )?(?:the |my )?(.+)$"#,
            #"^(?:(?:ya )?(?:usé|use)|acabo de usar) tod[oa]s? (?:(?:el|la|los|las|mi|mis) )?(.+)$"#
        ]
        if let food = firstFood(allForms, in: command) {
            return .consume([PantryVoiceItem(original: trimmed, food: food, amount: .all)])
        }
        let use = #"^(?:(?:i (?:just )?)?used|(?:yo )?(?:(?:ya )?usé|acabo de usar)) (.+)$"#
        let source: String
        if let item = groups(use, command)?.first {
            source = item
        } else if let item = groups(#"^((?:some|a little|un poco de|algo de) .+) used$"#, command)?.first {
            source = item
        } else { return review }

        if let fraction = fractionAndFood(source) {
            return .askRemaining(food: fraction.food, original: text)
        }

        // The list grammar already protects compound food names and mixed quantities.
        // Give unmeasured ingredients the same explicit boundary as a numbered next ingredient.
        let separated = source.replacingOccurrences(of: #"\s+(?:and|y)\s+(?=(?:"# + vague + #")\s)"#,
                                                     with: "\n", options: [.regularExpression, .caseInsensitive])
        var items: [PantryVoiceItem] = []
        for line in separated.components(separatedBy: "\n") {
            guard let list = try? NaturalListSegmenter.propose(line, maximumItems: 20), list.timing == nil,
                  !list.requiresTimingReview else { return review }
            for candidate in list.items {
                guard !candidate.needsBoundaryReview, let item = consumedItem(String(candidate.wording), spanish: locale == "es"),
                      items.count < 20, !items.contains(where: { $0.food.caseInsensitiveCompare(item.food) == .orderedSame })
                else { return review }
                items.append(item)
            }
        }
        return items.isEmpty ? review : .consume(items)
    }

    private static func dateFood(_ command: String) -> String? {
        let question = command.trimmingCharacters(in: CharacterSet(charactersIn: "¿? "))
        return firstFood([
            #"^is (?:my |the )?(.+?) expired$"#,
            #"^has (?:my |the )?(.+?) expired$"#,
            #"^when (?:does|did) (?:my |the )?(.+?) expire$"#,
            #"^(?:(?:ya )?está (?:vencid[oa]|caducad[oa])|(?:cuándo |ya )?(?:vence|caducó|caduca)) (?:(?:mi|el|la) )?(.+)$"#,
            #"^(?:(?:mi|el|la) )?(.+?) (?:ya )?(?:está (?:vencid[oa]|caducad[oa])|caducó)$"#
        ], in: question)
    }

    private static func observation(_ command: String, original: String) -> PantryVoiceObservation? {
        let low = #"^(?:(?:i['’]m|i am|we['’]re|we are) running low on|running low on|me queda poc[oa]|nos queda poc[oa]) (.+)$"#
        let punctuated = command.replacingOccurrences(of: #"(?<=[\p{L}])\s+(?=i have |me queda |nos queda )"#,
                                                     with: ",", options: [.regularExpression, .caseInsensitive])
        let clauses = punctuated.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = clauses.first, let food = firstFood([low], in: first) {
            if clauses.count == 1, let hint = groups(#"\b(running low|poc[oa])\b"#, first)?.first {
                return PantryVoiceObservation(food: food, original: original, remaining: .low, remainingWording: hint)
            }
            guard clauses.count == 2, let following = remainingPhrase(clauses[1]),
                  let fraction = fractionAndFood(following), fraction.food == nil
            else { return nil }
            return PantryVoiceObservation(food: food, original: original, remaining: fraction.remaining,
                                         remainingWording: remainingWording(fraction.wording, in: clauses[1]))
        }

        if let phrase = remainingPhrase(command) {
            if let fraction = fractionAndFood(phrase) {
                return PantryVoiceObservation(food: fraction.food ?? "", original: original, remaining: fraction.remaining,
                                             remainingWording: remainingWording(fraction.wording, in: command))
            }
            if let parts = groups(#"^(some|a little(?: bit)?|algo|un poco)(?:(?: of| de)? (.+))?$"#, phrase),
               let food = parts[1].isEmpty ? "" : checkedFood(parts[1]) {
                return PantryVoiceObservation(food: food, original: original, remaining: .some,
                                             remainingWording: remainingWording(parts[0], in: command))
            }
        }

        let containerPrefix = #"(?:(?:the |my |el |la |mi )?(?:"# + container + #") (?:of|de) )?"#
        let states: [(String, PantryVoiceRemaining)] = [
            (#"nearly empty|almost empty|casi vací[oa]"#, .nearlyEmpty), (#"empty|vací[oa]"#, .empty)
        ]
        for (state, remaining) in states {
            let unnamed = #"^(?:(?:(?:the|my|el|la|mi) )?(?:"# + container + #") (?:is|está)|it is|it['’]s|está) ("# + state + #")$"#
            if let wording = groups(unnamed, command)?.first {
                return PantryVoiceObservation(food: "", original: original, remaining: remaining, remainingWording: wording)
            }
            let pattern = #"^"# + containerPrefix + #"(?:(?:the|my|el|la|mi) )?(.+?) (?:is|está) ("# + state + #")$"#
            if let parts = groups(pattern, command), let food = checkedFood(parts[0]) {
                return PantryVoiceObservation(food: food, original: original, remaining: remaining, remainingWording: parts[1])
            }
        }
        return nil
    }

    private static func remainingWording(_ amount: String, in clause: String) -> String {
        let suffix = groups(#"( left)$"#, clause)?.first ?? ""
        return amount + suffix
    }

    private static func remainingPhrase(_ command: String) -> String? {
        for pattern in [#"^(?:i have |there is |there['’]s |we have )?(.+) left$"#,
                        #"^(?:(?:me |nos )?queda|tengo) (.+?)(?: restante)?$"#] {
            if let phrase = groups(pattern, command)?.first { return phrase }
        }
        return nil
    }

    /// Separate the verbal qualifier before reading the fraction. An estimate never acquires an exact value.
    private static func fractionAndFood(_ phrase: String) -> (remaining: PantryVoiceRemaining, food: String?, wording: String)? {
        let qualifier = #"(?:(less than|under|menos de|about|around|roughly|like|como|aproximadamente|más o menos) )?"#
        let fraction = #"(half|a half|(?:la )?mitad|medi[oa]|(?:a |one |un )?quarter|(?:un )?cuarto|1/2|1/4)"#
        let vessel = #"(?: (?:(?:of |de )?(?:a |an |the |una? |la |el ))?("# + container + #"))?"#
        let name = #"(?: (?:of|de) (.+))?"#
        guard let parts = groups("^" + qualifier + fraction + vessel + name + "$", phrase),
              let value = try? Rational(1, matches(#"quarter|cuarto|1/4"#, parts[1]) ? 4 : 2)
        else { return nil }
        let food = parts[3].isEmpty ? nil : checkedFood(parts[3])
        guard parts[3].isEmpty || food != nil else { return nil }
        let package = parts[2].isEmpty ? nil : parts[2]
        let wording = parts[3].isEmpty ? phrase : String(phrase.dropLast(parts[3].count))
            .replacingOccurrences(of: #" (?:of|de) $"#, with: "", options: [.regularExpression, .caseInsensitive])
        switch parts[0].lowercased() {
        case "": return (.fraction(value, container: package), food, wording)
        case "less than", "under", "menos de": return (.lessThanFraction(value, container: package), food, wording)
        default: return (.aboutFraction(value, container: package), food, wording)
        }
    }

    private static func consumedItem(_ wording: String, spanish: Bool) -> PantryVoiceItem? {
        if let food = firstFood([#"^(?:"# + vague + #") (.+)$"#], in: wording) {
            return PantryVoiceItem(original: wording, food: food, amount: .someUsed)
        }
        var tokens = ListQuantityParser.itemTokens(wording)
        var rangeCheck = tokens
        guard !ListQuantityParser.takeRange(from: &rangeCheck) else { return nil }
        guard let number = try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true, allowingDecimalComma: spanish) else {
            guard let food = checkedFood(wording) else { return nil }
            return PantryVoiceItem(original: wording, food: food, amount: .unknown)
        }
        guard number > .zero, let first = tokens.first else { return nil }
        if pieces.contains(first.lowercased()) {
            tokens = tokens.dropFirst()
            if let connector = tokens.first, ["of", "de"].contains(connector.lowercased()) { tokens = tokens.dropFirst() }
            guard let food = checkedFood(tokens.joined(separator: " ")) else { return nil }
            return PantryVoiceItem(original: wording, food: food, amount: .pieces(number, first))
        }
        let measure = ListQuantityParser.takeMeasure(number, from: &tokens)
        guard let value = measure.amount, let food = checkedFood(tokens.joined(separator: " ")),
              !ListQuantityParser.needsUnitReview(tokens.first), !ListQuantityParser.isPackMarker(tokens.first ?? "")
        else { return nil }
        // An unknown measure ("two scoops of flour") must not turn into two counts of flour.
        if measure.unit == nil, matches(#"^\S+ (?:of|de) |^(?:"# + container + #")s?\b"#, food) { return nil }
        let quantity = Quantity(amount: value, unit: measure.unit ?? .count, originalLiteral: wording)
        return PantryVoiceItem(original: wording, food: food, amount: .measured(quantity))
    }

    private static func firstFood(_ forms: [String], in text: String) -> String? {
        for pattern in forms {
            if let first = groups(pattern, text)?.first, let food = checkedFood(first) { return food }
        }
        return nil
    }

    private static func checkedFood(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare("half and half") == .orderedSame { return trimmed }
        if matches(#"\b(?:and|y|e)\b"#, trimmed) {
            guard let list = try? NaturalListSegmenter.propose(trimmed), list.items.count == 1,
                  list.items[0].needsBoundaryReview == false else { return nil }
        }
        guard trimmed.utf8.count <= 180, matches(#"^[\p{L}\p{M}]+(?:[ ’'\-][\p{L}\p{M}]+)*$"#, trimmed),
              !matches(#"\b(?:used|use|usé|usar|buy|bought|add|added|update|compré|compra|añade|agrega|actualiza|delete|remove|borra|elimina|left|queda|quedan|expired|vencid\w*|empty|vacío|vacía|half|mitad|about|like|maybe|all|todo|toda|some|except|remaining|have|i|you|porque|then|after|before|instead|with|without|sin|approximately|approx|around|under|less|more|either|not|only|other|me|it|them|yesterday|tomorrow|ayer|mañana|later|después|para|today|hoy|before|ago|another|extra|plus|más|menos|casi|nearly|few|couple|several|roughly|perhaps|probably|for|from|was|were|tengo|unos|unas|aproximadamente|varios|varias|o)\b"#, trimmed),
              !matches(#"^(?:of|de|and|y|a|an|un|una|one|two|three|four|five|six|seven|eight|nine|ten|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|medio|media|some|either|roughly|almost|handfuls?|puñados?)\b"#, trimmed)
        else { return nil }
        return trimmed
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Each optional capture retains its position as an empty string.
    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
