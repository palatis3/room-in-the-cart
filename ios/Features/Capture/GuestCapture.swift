import Foundation
import CoreDomain

struct CaptureGuestGroupChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let currentServings: Rational
    let isProtected: Bool
}
struct CaptureGuestMealChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let groups: [CaptureGuestGroupChoice]
}
struct ReviewedGuestCapture: Equatable, Sendable {
    let id: UUID
    let originalText: String
    let occurrenceID: UUID
    let groupID: UUID
    let baselineServings: Rational
    let total: Rational
}

struct CaptureGuestProposal: Equatable, Sendable {
    enum Change: Sendable { case total, add, remove }

    let amount: Rational
    let change: Change

    func proposedTotal(current: Rational) throws -> Rational {
        switch change {
        case .total: return amount
        case .add: return try current.adding(amount)
        case .remove:
            let remaining = try current.subtracting(amount)
            guard remaining > .zero else { throw StructuredCaptureFailure.invalidAmount }
            return remaining
        }
    }
}

enum CaptureGuestParser {
    private static let more: Set<String> = ["more", "additional", "extra", "más", "mas", "adicional", "adicionales"]
    private static let descriptions: Set<String> = ["dinner", "lunch", "adult", "vegetarian", "vegan", "overnight"]
    private static let fewer: Set<String> = ["fewer", "less", "menos"]
    private static let add: Set<String> = ["add", "agrega", "agregar", "agregue", "añade", "añadir", "añada", "suma"]
    private static let remove: Set<String> = ["remove", "subtract", "quita", "quitar", "quite", "resta"]

    static func proposal(_ text: String) -> CaptureGuestProposal? {
        guard (try? CaptureLimits.validate(text)) != nil else { return nil }
        let words = text.lowercased().split { $0.isWhitespace || ",.!?;:¿¡".contains($0) }.map(String.init)
        let guests = words.indices.filter { StructuredCaptureParser.guestNouns.contains(words[$0]) }
        guard guests.count == 1, let guest = guests.first, let count = guestCount(in: words) else { return nil }

        // The quantity must belong to the guest phrase. “Two boxes for the guests”
        // has a valid grocery quantity and supplies no guest count.
        let between = guest < count.range.lowerBound
            ? words[(guest + 1)..<count.range.lowerBound] : words[count.range.upperBound..<guest]
        let modifiers = more.union(fewer).union(descriptions)
        guard between.allSatisfy(modifiers.contains) else { return nil }
        let start = min(guest, count.range.lowerBound)
        let end = max(guest + 1, count.range.upperBound)
        let before = words[..<start].last ?? ""
        let after = words[end...].first ?? ""
        let lowerBoundWords = words[..<start].suffix(2)
        let bounds = ["more than", "less than", "fewer than", "at least", "at most", "up to", "más de", "mas de", "menos de", "al menos"]
        guard !bounds.contains(lowerBoundWords.joined(separator: " ")) else { return nil }
        let nearby = Set(between).union([before, after])
        let increases = add.contains(before) || !more.isDisjoint(with: nearby)
        let decreases = remove.contains(before) || !fewer.isDisjoint(with: nearby)
        guard !(increases && decreases) else { return nil }
        if increases || decreases, words.contains("total") { return nil }

        // In Spanish “menos” can also introduce an exclusion. Only treat it
        // as a subtraction when it modifies the guest count itself.
        let endsWithFewer = after == "menos" && end == words.count - 1
        let otherWords = endsWithFewer ? words.dropLast() : words[...]
        guard !CaptureLimits.containsExclusion(otherWords.joined(separator: " ")),
              Set(words).isDisjoint(with: ["don't", "don’t", "never", "nunca", "jamás"]) else { return nil }
        if increases { return .init(amount: count.amount, change: .add) }
        if decreases { return .init(amount: count.amount, change: .remove) }
        return .init(amount: count.amount, change: .total)
    }

    private static func guestCount(in words: [String]) -> (amount: Rational, range: Range<Int>)? {
        var result: (Rational, Range<Int>)?
        var index = words.startIndex
        while index < words.endIndex {
            var rest = words[index...]
            guard let amount = try? ListQuantityParser.takeAmount(from: &rest, allowingWords: true) else {
                index += 1
                continue
            }
            // A partial token such as “2kg” is a measurement, not a guest count.
            guard result == nil, amount > .zero, rest.startIndex > index else { return nil }
            result = (amount, index..<rest.startIndex)
            index = rest.startIndex
        }
        return result
    }
}
