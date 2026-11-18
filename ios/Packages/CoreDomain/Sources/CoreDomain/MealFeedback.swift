import Foundation

public enum MealReaction: String, Codable, Hashable, CaseIterable, Sendable {
    case makeAgain, tooMuchEffort, childrenLikedIt, tooManyLeftovers
}

public enum MealFeedbackSource: Codable, Hashable, Sendable {
    case recipe(id: UUID, revision: Int)
    case occurrence(shopID: UUID, occurrenceID: UUID)
}

public struct PrivateMealFeedback: Codable, Equatable, Sendable {
    public let source: MealFeedbackSource
    public let owner: String
    public let revision: UUID
    public let recordedAt: Date
    public let reactions: [MealReaction]
}

public extension LedgerWorkspace {
    func feedback(for source: MealFeedbackSource, owner: String) -> PrivateMealFeedback? {
        privateMealFeedback.first { $0.source == source && $0.owner == owner }
    }

    mutating func updateMealFeedback(for source: MealFeedbackSource, owner: String,
                                     expectedRevision: UUID?, reactions: Set<MealReaction>, at now: Date) throws {
        guard feedbackSourceExists(source), !owner.isEmpty, owner.utf8.count <= 128 else {
            throw DinnerPlanningError.stalePreview
        }
        let existing = feedback(for: source, owner: owner)
        guard existing?.revision == expectedRevision else { throw DinnerPlanningError.stalePreview }
        guard reactions != Set(existing?.reactions ?? []) else { return }
        privateMealFeedback.removeAll { $0.source == source && $0.owner == owner }
        if !reactions.isEmpty {
            privateMealFeedback.append(.init(source: source, owner: owner, revision: UUID(), recordedAt: now,
                reactions: MealReaction.allCases.filter(reactions.contains)))
        }
    }

    func feedbackSourceExists(_ source: MealFeedbackSource) -> Bool {
        switch source {
        case let .recipe(id, revision):
            return mealTemplates.contains { $0.id == id && $0.revision == revision } ||
                dinnerPlanning.acceptedDinners.contains { $0.template.id == id && $0.template.revision == revision }
        case let .occurrence(shopID, occurrenceID):
            return shops.first { $0.id == shopID }?.mealOccurrences.contains { $0.id == occurrenceID && $0.removedAt == nil } == true
        }
    }

    mutating func copyPrivateMealFeedback(from workspace: Self, owner: String?, includeRecipes: Bool = true) {
        privateMealFeedback = workspace.privateMealFeedback.filter { entry in
            if case .recipe = entry.source, !includeRecipes { return false }
            return entry.owner == owner && feedbackSourceExists(entry.source)
        }
    }

    func withoutMealFeedback() -> Self {
        var copy = self
        copy.privateMealFeedback = []
        return copy
    }

    mutating func discardOrphanedMealFeedback() {
        let surviving = privateMealFeedback.filter { feedbackSourceExists($0.source) }
        privateMealFeedback = surviving
    }

    func suggestedFutureServings(shopID: UUID, occurrenceID: UUID, owner: String, at now: Date) -> Rational? {
        guard let meal = shops.first(where: { $0.id == shopID })?.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }),
              let date = meal.scheduledDay, let today = try? MealDay(date: now, timeZoneIdentifier: date.timeZoneIdentifier),
              date.iso8601 > today.iso8601, let id = meal.templateID, let revision = meal.templateRevision,
              meal.servings > .one, !meal.servingGroups.contains(where: \.isProtected) else { return nil }
        // Feedback on this very dinner is not an earlier portion experience.
        let signals = mealFeedbackSignals(owner: owner, at: now, excluding: .occurrence(shopID: shopID, occurrenceID: occurrenceID))
        guard signals[.recipe(id: id, revision: revision)]?.reviewPortions == true,
              let smaller = try? meal.servings.subtracting(.one) else { return nil }
        return max(.one, smaller)
    }

    func mealFeedbackSignals(owner: String, at now: Date, excluding source: MealFeedbackSource? = nil) -> [MealFeedbackSource: MealFeedbackSignal] {
        var result: [MealFeedbackSource: MealFeedbackSignal] = [:]
        for entry in privateMealFeedback where entry.owner == owner && entry.source != source {
            let age = now.timeIntervalSince(entry.recordedAt)
            guard age >= 0, age < 90 * 86_400 else { continue }
            let recipe: MealFeedbackSource
            switch entry.source {
            case .recipe: recipe = entry.source
            case let .occurrence(shopID, occurrenceID):
                guard let meal = shops.first(where: { $0.id == shopID })?.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }),
                      let id = meal.templateID, let revision = meal.templateRevision else { continue }
                recipe = .recipe(id: id, revision: revision)
            }
            // The latest explicit experience replaces earlier impressions. Repetition cannot accumulate weight.
            if let old = result[recipe], old.date > entry.recordedAt ||
                (old.date == entry.recordedAt && old.revision.uuidString > entry.revision.uuidString) { continue }
            let positive = entry.reactions.contains(.makeAgain) || entry.reactions.contains(.childrenLikedIt)
            let negative = entry.reactions.contains(.tooMuchEffort)
            let direction = (positive ? 1 : 0) - (negative ? 1 : 0)
            result[recipe] = MealFeedbackSignal(score: Double(direction) * (1 - age / (90 * 86_400)),
                reviewPortions: entry.reactions.contains(.tooManyLeftovers), date: entry.recordedAt, revision: entry.revision)
        }
        return result
    }
}

public struct MealFeedbackSignal: Equatable, Sendable {
    public let score: Double
    public let reviewPortions: Bool
    fileprivate let date: Date
    fileprivate let revision: UUID
}
