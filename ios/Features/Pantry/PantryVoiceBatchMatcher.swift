import CoreDomain
import Foundation

/// Used for discovery only. Ledger identity and quantity compatibility use their own exact checks.
enum GroceryNameSpelling {
    static let pluralEndings = ["s", "es"]

    static func folded(_ value: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        return value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: locale).lowercased(with: locale)
    }
}

/// Candidates come only from the private snapshot supplied by the caller.
/// Plural or accent-insensitive matches help discovery but never select a lot.
enum PantryVoiceBatchMatcher {
    static func suggestions(for food: String, in lots: [InventoryLot]) -> [InventoryLot] {
        let qualified = storageQualifier(in: food)
        let query = words(in: qualified?.food ?? food)
        guard !query.isEmpty else { return [] }
        return lots.filter { lot in
            // A literal product name may itself end with a storage phrase.
            if exactLabel(lot.name) == exactLabel(food) { return true }
            if let qualified, lot.location != qualified.location { return false }
            let label = words(in: lot.name)
            return query.allSatisfy { term in
                label.contains { matches($0, term) }
            }
        }
    }

    static func uniqueExact(for food: String, in lots: [InventoryLot]) -> InventoryLot? {
        let candidates = suggestions(for: food, in: lots)
        guard candidates.count == 1, let only = candidates.first,
              exactLabel(food) == exactLabel(only.name) ||
                exactLabel(storageQualifier(in: food)?.food ?? food) == exactLabel(only.name) else { return nil }
        return only
    }

    /// Only explicit trailing location phrases qualify a food. “Freezer jam” is a food name.
    static func storageQualifier(in value: String) -> (food: String, location: InventoryLocation, phrase: String)? {
        let suffixes: [(InventoryLocation, [String])] = [
            (.fridge, ["from the refrigerator", "from the fridge", "in the refrigerator", "in the fridge",
                       "del refrigerador", "de la nevera", "del frigorífico", "en el refrigerador", "en la nevera", "en el frigorífico"]),
            (.freezer, ["from the freezer", "in the freezer", "del congelador", "en el congelador"]),
            (.cupboard, ["from the cupboard", "from the pantry", "in the cupboard", "in the pantry",
                         "de la alacena", "de la despensa", "en la alacena", "en la despensa"])
        ]
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        for (location, endings) in suffixes {
            for ending in endings {
                if let range = trimmed.range(of: " " + ending, options: [.backwards, .anchored, .caseInsensitive, .diacriticInsensitive]) {
                    let food = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    if !food.isEmpty { return (food, location, String(trimmed[range])) }
                }
            }
        }
        return nil
    }

    private static func matches(_ label: String, _ term: String) -> Bool {
        if label == term { return true }
        let shorter = label.count < term.count ? label : term
        let longer = label.count < term.count ? term : label
        return GroceryNameSpelling.pluralEndings.contains { longer == shorter + $0 }
    }

    private static func exactLabel(_ value: String) -> String {
        // Punctuation can carry product information, as in “2% milk”.
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func words(in value: String) -> [String] {
        GroceryNameSpelling.folded(value).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
