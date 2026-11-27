import Foundation
import CoreGraphics

/// A candidate changes one word or amount within one Vision observation.
struct ReceiptWordReading: Equatable, Codable, Sendable {
    let word: String
    let replacement: String
    let wording: String
    let wordIndex: Int
    var bounds: CGRect?

    static func choices(original: String, candidates: [String]) -> [Self] {
        guard !candidates.isEmpty, !original.contains(where: \.isNewline), original.utf8.count <= 2048 else { return [] }
        let words = original.split(whereSeparator: \.isWhitespace)
        var choices: [Self] = []
        for candidate in candidates {
            guard !candidate.contains(where: \.isNewline), candidate.utf8.count <= 2048 else { continue }
            let parts = candidate.split(whereSeparator: \.isWhitespace)
            guard parts.count == words.count else { continue }
            let changed = words.indices.filter { words[$0] != parts[$0] }
            guard changed.count == 1, let i = changed.first else { continue }
            let updated = original.replacingCharacters(in: words[i].startIndex..<words[i].endIndex, with: parts[i])
            let choice = Self(word: String(words[i]), replacement: String(parts[i]), wording: updated, wordIndex: i)
            if !choices.contains(choice) { choices.append(choice) }
            if choices.count == 2 { break }
        }
        return choices
    }

    /// Vision uses bottom-left normalized coordinates. The displayed preview is upright.
    static func pixels(for bounds: CGRect, width: Int, height: Int) -> CGRect? {
        guard !bounds.isNull, !bounds.isEmpty, width > 0, height > 0,
              [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return CGRect(x: bounds.minX * CGFloat(width), y: (1 - bounds.maxY) * CGFloat(height),
                      width: bounds.width * CGFloat(width), height: bounds.height * CGFloat(height)).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}
