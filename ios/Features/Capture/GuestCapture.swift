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
    let amount: Rational
    let isAdditional: Bool
    func proposedTotal(current: Rational) throws -> Rational { isAdditional ? try current.adding(amount) : amount }
}
enum CaptureGuestParser {
    static func proposal(_ text: String) -> CaptureGuestProposal? {
        guard StructuredCaptureParser.isGuestProposal(text), !CaptureLimits.containsExclusion(text), (try? CaptureLimits.validate(text)) != nil else { return nil }
        let words = text.lowercased().split { $0.isWhitespace || ",.!?;:".contains($0) }.map(String.init)
        let numbers = words.compactMap { try? CaptureNumber.parse($0) }
        guard numbers.count == 1, let amount = numbers.first, amount > .zero else { return nil }
        let extra = !Set(words).isDisjoint(with: ["more", "additional", "extra", "más", "mas"])
        return .init(amount: amount, isAdditional: extra)
    }
}
