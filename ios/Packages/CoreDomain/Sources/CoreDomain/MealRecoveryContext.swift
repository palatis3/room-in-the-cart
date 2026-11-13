import Foundation

/// These are new current-context facts, not edits to an earlier recovery baseline.
/// Existing demand removal/quantity changes require their own reviewed operation;
/// they cannot be smuggled through an additive context update.
public enum MealRecoveryContextChange: Codable, Equatable, Sendable {
    case appendOutside([StockNeed])
    case transferCarryover(occurrenceID: UUID, source: StockNeed, reservation: StockNeed)
    case moveMeal(occurrenceID: UUID, from: MealDay?, to: MealDay?)
    case confirmDeadline(occurrenceID: UUID, due: Date)
}
public struct MealRecoveryContextRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let shopID: UUID
    public let baseRevisionID: UUID
    public let revisionID: UUID
    public let change: MealRecoveryContextChange
    public let reviewedAt: Date
    public init(id: UUID, shopID: UUID, baseRevisionID: UUID, revisionID: UUID,
                change: MealRecoveryContextChange, reviewedAt: Date) {
        self.id = id; self.shopID = shopID; self.baseRevisionID = baseRevisionID
        self.revisionID = revisionID; self.change = change; self.reviewedAt = reviewedAt
    }
}
public struct MealRecoveryContextEvent: Codable, Equatable, Sendable, Identifiable {
    public let request: MealRecoveryContextRequest
    public let appliedAt: Date
    public var id: UUID { request.id }
}
public struct MealRecoveryContextReview: Equatable, Sendable {
    public let request: MealRecoveryContextRequest
    public let source: MealRecoveryState
    public let after: MealRecoveryProjection
}

extension MealRecoveryEngine {
    public static func previewContext(_ request: MealRecoveryContextRequest, in state: MealRecoveryState,
                                      at instant: Date) throws -> MealRecoveryContextReview {
        _ = try project(state)
        var candidate = state
        candidate.append(MealRecoveryContextEvent(request: request, appliedAt: instant))
        return MealRecoveryContextReview(request: request, source: state, after: try project(candidate))
    }
    @discardableResult public static func applyContext(_ review: MealRecoveryContextReview, to state: inout MealRecoveryState,
                                                      at instant: Date) throws -> MealRecoveryContextEvent {
        _ = try project(state)
        if let old = state.contextChanges.first(where: { $0.id == review.request.id }) {
            guard old.request == review.request else { throw MealRecoveryError.operationConflict }
            return old
        }
        guard state == review.source else { throw MealRecoveryError.stale }
        let fresh = try previewContext(review.request, in: state, at: instant)
        guard fresh == review else { throw MealRecoveryError.stale }
        let event = MealRecoveryContextEvent(request: review.request, appliedAt: instant)
        var candidate = state; candidate.append(event); _ = try project(candidate)
        state = candidate
        return event
    }

    static func applyContextEvent(_ event: MealRecoveryContextEvent, shopID: UUID,
                                  current: MealRecoveryProjection, usedNeeds: Set<UUID>, usedRevisions: Set<UUID>) throws -> MealRecoveryProjection {
        let request = event.request
        guard request.shopID == shopID, request.baseRevisionID == current.revisionID,
              request.reviewedAt.timeIntervalSinceReferenceDate.isFinite, event.appliedAt.timeIntervalSinceReferenceDate.isFinite,
              request.reviewedAt <= event.appliedAt, !usedRevisions.contains(request.revisionID) else { throw MealRecoveryError.stale }
        var meals = current.meals, outside = current.outsideDemands
        var remainders = current.carryoverRemainders
        switch request.change {
        case .appendOutside(let additions):
            guard !additions.isEmpty, additions.allSatisfy({ !usedNeeds.contains($0.id) }) else { throw MealRecoveryError.invalid }
            outside += additions
        case let .transferCarryover(occurrenceID, source, reservation):
            guard let meal = meals.first(where: { $0.id == occurrenceID }),
                  meal.needs.contains(where: { $0.id == source.id }), current.demands.contains(source),
                  source.priority != .protected, reservation.priority == .required,
                  !usedNeeds.contains(reservation.id), source.foodID == reservation.foodID,
                  let moved = try reservation.amount.converted(to: source.amount.unit),
                  moved > .zero, moved <= source.amount.amount else { throw MealRecoveryError.invalid }
            let amount = try source.amount.amount.subtracting(moved)
            let remainder = Quantity(amount: amount, unit: source.amount.unit, originalLiteral: amount.description,
                confirmedConversion: source.amount.confirmedConversion)
            remainders[source.id] = StockNeed(id: source.id, foodID: source.foodID, name: source.name,
                amount: remainder, priority: source.priority)
            outside.append(reservation)
        case let .moveMeal(occurrenceID, from, to):
            guard let index = meals.firstIndex(where: { $0.id == occurrenceID }), meals[index].scheduledDay == from,
                  to != from, to.map({ $0.timeZoneIdentifier == meals[index].timeZoneID }) ?? true else { throw MealRecoveryError.stale }
            try to?.validate()
            meals[index] = contextCopy(meals[index], revision: request.revisionID, day: to, due: meals[index].due)
        case let .confirmDeadline(occurrenceID, due):
            guard let index = meals.firstIndex(where: { $0.id == occurrenceID }), meals[index].due == nil,
                  due.timeIntervalSinceReferenceDate.isFinite else { throw MealRecoveryError.invalid }
            meals[index] = contextCopy(meals[index], revision: request.revisionID, day: meals[index].scheduledDay, due: due)
        }
        for meal in meals { try validate(meal) }
        let result = projection(revision: request.revisionID, meals: meals, outside: outside, remainders: remainders)
        try validateDemands(result.demands)
        return result
    }
    private static func contextCopy(_ meal: RecoveryMeal, revision: UUID, day: MealDay?, due: Date?) -> RecoveryMeal {
        RecoveryMeal(id: meal.id, revisionID: revision, templateID: meal.templateID, templateVersion: meal.templateVersion,
            title: meal.title, servings: meal.servings, ingredients: meal.ingredients, scheduledDay: day, due: due,
            timeZoneID: meal.timeZoneID, exclusions: meal.exclusions, remainingElapsedMinutes: meal.remainingElapsedMinutes,
            requiredLeadMinutes: meal.requiredLeadMinutes, advanceStepsCompleted: meal.advanceStepsCompleted)
    }
}
