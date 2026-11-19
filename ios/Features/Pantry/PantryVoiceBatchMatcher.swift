import CoreDomain
import Foundation

/// Candidates come only from the private snapshot supplied by the caller.
/// Plural or accent-insensitive matches help discovery but never select a lot.
enum PantryVoiceBatchMatcher {
    static func suggestions(for food: String, in lots: [InventoryLot]) -> [InventoryLot] {
        let query = words(in: food)
        guard !query.isEmpty else { return [] }
        return lots.filter { lot in
            let label = words(in: lot.name)
            return query.allSatisfy { term in
                label.contains { matches($0, term) }
            }
        }
    }

    static func uniqueExact(for food: String, in lots: [InventoryLot]) -> InventoryLot? {
        let candidates = suggestions(for: food, in: lots)
        guard candidates.count == 1, let only = candidates.first,
              exactLabel(food) == exactLabel(only.name) else { return nil }
        return only
    }

    private static func matches(_ label: String, _ term: String) -> Bool {
        if label == term { return true }
        let shorter = label.count < term.count ? label : term
        let longer = label.count < term.count ? term : label
        return longer == shorter + "s" || longer == shorter + "es"
    }

    private static func exactLabel(_ value: String) -> String {
        // Punctuation can carry product information, as in “2% milk”.
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func words(in value: String) -> [String] {
        let locale = Locale(identifier: "en_US_POSIX")
        let text = value.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                 locale: locale).lowercased(with: locale)
        return text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
