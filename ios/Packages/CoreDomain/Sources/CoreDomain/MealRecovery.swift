import Foundation

public enum MealRecoveryError: Error, Equatable {
    case invalid, stale, operationConflict, protectedAllocation, consentRequired, unresolved
}

/// Explicit ingredient/group/food identity. A label never establishes a food match.
public struct RecoveryIngredient: Codable, Equatable, Sendable {
    public let ingredientID: UUID
    public let groupID: UUID?
    public let foodName: String
    public let need: StockNeed
    public init(ingredientID: UUID, groupID: UUID?, foodName: String, need: StockNeed) {
        self.ingredientID = ingredientID; self.groupID = groupID; self.foodName = foodName; self.need = need
    }
}

/// A complete current meal version, separate from the sealed purchase and reusable recipe.
/// Protected ingredients remain part of the snapshot and survive replacement exactly.
public struct RecoveryMeal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revisionID: UUID
    public let templateID: UUID?
    public let templateVersion: Int?
    public let title: String
    public let servings: Rational
    public let ingredients: [RecoveryIngredient]
    public let scheduledDay: MealDay?
    public let due: Date?
    public let timeZoneID: String
    public let exclusions: [String]
    public let remainingElapsedMinutes: Int?
    public let requiredLeadMinutes: Int?
    public let advanceStepsCompleted: Bool
    public init(id: UUID, revisionID: UUID, templateID: UUID?, templateVersion: Int?, title: String,
                servings: Rational, ingredients: [RecoveryIngredient], scheduledDay: MealDay?, due: Date?,
                timeZoneID: String, exclusions: [String], remainingElapsedMinutes: Int?,
                requiredLeadMinutes: Int?, advanceStepsCompleted: Bool) {
        self.id = id; self.revisionID = revisionID; self.templateID = templateID; self.templateVersion = templateVersion
        self.title = title; self.servings = servings; self.ingredients = ingredients; self.scheduledDay = scheduledDay
        self.due = due; self.timeZoneID = timeZoneID; self.exclusions = exclusions
        self.remainingElapsedMinutes = remainingElapsedMinutes; self.requiredLeadMinutes = requiredLeadMinutes
        self.advanceStepsCompleted = advanceStepsCompleted
    }
    public var needs: [StockNeed] { ingredients.map(\.need) }
}

/// Availability includes both arrival and usable-confirmation time. The adapter must
/// supply only the latest nonsuperseded, explicitly matched observation for each origin.
/// Future evidence is retained here but cannot feed an earlier projection.
public struct RecoveryStockEvidence: Codable, Equatable, Sendable {
    public let lot: ConfirmedStockLot
    public let availableAt: Date
    public init(lot: ConfirmedStockLot, availableAt: Date) { self.lot = lot; self.availableAt = availableAt }
}

/// Caller-reserved operation/output IDs and complete reviewed target prevent partial
/// replacement or name-based targeting. Consent belongs to this exact request.
public struct MealRecoveryRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let shopID: UUID
    public let baseRevisionID: UUID
    public let target: RecoveryMeal
    public let replacement: RecoveryMeal
    public let reviewedAt: Date
    public let agreesToRepeat: Bool
    public let proposesExtraTrip: Bool
    public let agreesToExtraTrip: Bool
    public let acceptsUnresolved: Bool
    public init(id: UUID, shopID: UUID, baseRevisionID: UUID, target: RecoveryMeal, replacement: RecoveryMeal,
                reviewedAt: Date, agreesToRepeat: Bool = false, proposesExtraTrip: Bool = false,
                agreesToExtraTrip: Bool = false, acceptsUnresolved: Bool = false) {
        self.id = id; self.shopID = shopID; self.baseRevisionID = baseRevisionID; self.target = target
        self.replacement = replacement; self.reviewedAt = reviewedAt; self.agreesToRepeat = agreesToRepeat
        self.proposesExtraTrip = proposesExtraTrip; self.agreesToExtraTrip = agreesToExtraTrip
        self.acceptsUnresolved = acceptsUnresolved
    }
}

public struct MealRecoveryProjection: Equatable, Sendable {
    public let revisionID: UUID
    public let meals: [RecoveryMeal]
    public let demands: [StockNeed]
}

public struct MealRecoveryEvent: Codable, Equatable, Sendable, Identifiable {
    public let request: MealRecoveryRequest
    public let stockEvidence: [RecoveryStockEvidence]
    public let reservations: [ConfirmedStockReservation]
    public let appliedAt: Date
    public var id: UUID { request.id }
}

/// This value contains meal history only. Purchase lines, receipts, charges, templates
/// and recipient sends are owned elsewhere and cannot be mutated by this engine.
public struct MealRecoveryState: Codable, Equatable, Sendable {
    public let shopID: UUID
    public let originalRevisionID: UUID
    public let originalMeals: [RecoveryMeal]
    public let outsideDemands: [StockNeed]
    public private(set) var events: [MealRecoveryEvent]
    public init(shopID: UUID, originalRevisionID: UUID, originalMeals: [RecoveryMeal], outsideDemands: [StockNeed]) throws {
        self.shopID = shopID; self.originalRevisionID = originalRevisionID; self.originalMeals = originalMeals
        self.outsideDemands = outsideDemands; self.events = []
        _ = try MealRecoveryEngine.project(self)
    }
    private enum CodingKeys: String, CodingKey { case shopID, originalRevisionID, originalMeals, outsideDemands, events }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shopID = try c.decode(UUID.self, forKey: .shopID)
        originalRevisionID = try c.decode(UUID.self, forKey: .originalRevisionID)
        originalMeals = try c.decode([RecoveryMeal].self, forKey: .originalMeals)
        outsideDemands = try c.decode([StockNeed].self, forKey: .outsideDemands)
        events = try c.decode([MealRecoveryEvent].self, forKey: .events)
        // Historical validation uses event instants, never the decoder's wall clock.
        _ = try MealRecoveryEngine.project(self)
    }
    fileprivate mutating func append(_ event: MealRecoveryEvent) { events.append(event) }
}

public struct MealRecoveryReview: Equatable, Sendable {
    public let request: MealRecoveryRequest
    public let source: MealRecoveryState
    public let stockEvidence: [RecoveryStockEvidence]
    public let reservations: [ConfirmedStockReservation]
    public let before: MealRecoveryProjection
    public let after: MealRecoveryProjection
    public let beforeAllocation: StockAllocationResult
    public let afterAllocation: StockAllocationResult
    public let foodConfirmed: Bool
    public let timingConfirmed: Bool
    public let repeatRequired: Bool
    public var feasible: Bool { foodConfirmed && timingConfirmed }
}

public enum MealRecoveryEngine {
    public static func project(_ state: MealRecoveryState) throws -> MealRecoveryProjection {
        guard state.originalMeals.count <= 1_000, state.events.count <= 1_000,
              Set(state.originalMeals.map(\.id)).count == state.originalMeals.count,
              Set(state.originalMeals.map(\.revisionID)).count == state.originalMeals.count else { throw MealRecoveryError.invalid }
        for meal in state.originalMeals { try validate(meal) }
        var current = projection(revision: state.originalRevisionID, meals: state.originalMeals, outside: state.outsideDemands)
        try validateDemands(current.demands)
        var operations = Set<UUID>()
        var usedNeeds = Set(current.demands.map(\.id))
        var usedRevisions = Set(state.originalMeals.map(\.revisionID) + [state.originalRevisionID])
        var knownTemplates = Set(state.originalMeals.compactMap(\.templateID))
        var priorInstant: Date?
        for event in state.events {
            guard operations.insert(event.id).inserted,
                  priorInstant.map({ event.appliedAt >= $0 }) ?? true else { throw MealRecoveryError.invalid }
            let result = try evaluate(event.request, shopID: state.shopID, current: current,
                outside: state.outsideDemands, usedNeeds: usedNeeds, usedRevisions: usedRevisions,
                knownTemplates: knownTemplates, evidence: event.stockEvidence, reservations: event.reservations, at: event.appliedAt)
            try consent(event.request, feasible: result.food && result.timing, repeats: result.repeats)
            current = result.after
            usedNeeds.formUnion(event.request.replacement.needs.map(\.id))
            usedRevisions.insert(event.request.replacement.revisionID)
            if let template = event.request.replacement.templateID { knownTemplates.insert(template) }
            priorInstant = event.appliedAt
        }
        return current
    }

    public static func preview(_ request: MealRecoveryRequest, in state: MealRecoveryState,
                               stockEvidence: [RecoveryStockEvidence], reservations: [ConfirmedStockReservation],
                               at instant: Date) throws -> MealRecoveryReview {
        let current = try project(state)
        let meals = state.originalMeals + state.events.map { $0.request.replacement }
        let result = try evaluate(request, shopID: state.shopID, current: current, outside: state.outsideDemands,
            usedNeeds: Set(meals.flatMap(\.needs).map(\.id) + state.outsideDemands.map(\.id)),
            usedRevisions: Set(meals.map(\.revisionID) + [state.originalRevisionID]),
            knownTemplates: Set(meals.compactMap(\.templateID)), evidence: stockEvidence, reservations: reservations, at: instant)
        return MealRecoveryReview(request: request, source: state, stockEvidence: stockEvidence, reservations: reservations,
            before: current, after: result.after, beforeAllocation: result.beforeAllocation, afterAllocation: result.afterAllocation,
            foodConfirmed: result.food, timingConfirmed: result.timing, repeatRequired: result.repeats)
    }

    /// Domain validation is not authorization. The local/server adapter must recheck
    /// current actor/scope even for retries, then atomically persist this value by CAS.
    @discardableResult public static func apply(_ review: MealRecoveryReview, to state: inout MealRecoveryState,
                                               stockEvidence: [RecoveryStockEvidence], reservations: [ConfirmedStockReservation],
                                               at instant: Date) throws -> MealRecoveryEvent {
        _ = try project(state)
        if let existing = state.events.first(where: { $0.id == review.request.id }) {
            guard existing.request == review.request, existing.stockEvidence == review.stockEvidence,
                  existing.reservations == review.reservations else { throw MealRecoveryError.operationConflict }
            return existing
        }
        guard state == review.source, stockEvidence == review.stockEvidence, reservations == review.reservations else {
            throw MealRecoveryError.stale
        }
        let fresh = try preview(review.request, in: state, stockEvidence: stockEvidence, reservations: reservations, at: instant)
        guard fresh == review else { throw MealRecoveryError.stale }
        try consent(review.request, feasible: fresh.feasible, repeats: fresh.repeatRequired)
        let event = MealRecoveryEvent(request: review.request, stockEvidence: stockEvidence, reservations: reservations, appliedAt: instant)
        var candidate = state; candidate.append(event)
        _ = try project(candidate)
        state = candidate
        return event
    }

    private struct Evaluation {
        let after: MealRecoveryProjection
        let beforeAllocation: StockAllocationResult
        let afterAllocation: StockAllocationResult
        let food: Bool
        let timing: Bool
        let repeats: Bool
    }
    private static func evaluate(_ request: MealRecoveryRequest, shopID: UUID, current: MealRecoveryProjection,
                                 outside: [StockNeed], usedNeeds: Set<UUID>, usedRevisions: Set<UUID>, knownTemplates: Set<UUID>,
                                 evidence: [RecoveryStockEvidence], reservations: [ConfirmedStockReservation], at instant: Date) throws -> Evaluation {
        guard instant.timeIntervalSinceReferenceDate.isFinite, request.reviewedAt.timeIntervalSinceReferenceDate.isFinite,
              request.reviewedAt <= instant, request.shopID == shopID, request.baseRevisionID == current.revisionID,
              let index = current.meals.firstIndex(where: { $0.id == request.target.id }),
              current.meals[index] == request.target else { throw MealRecoveryError.stale }
        let old = request.target, new = request.replacement
        try validate(new)
        guard new.id == old.id, !usedRevisions.contains(new.revisionID), new.servings == old.servings,
              new.due == old.due, new.timeZoneID == old.timeZoneID, new.scheduledDay == old.scheduledDay,
              Set(old.exclusions).isSubset(of: Set(new.exclusions)) else { throw MealRecoveryError.invalid }
        let protected = old.ingredients.filter { $0.need.priority == .protected }
        guard new.ingredients.filter({ $0.need.priority == .protected }) == protected,
              old.ingredients.contains(where: { $0.need.priority != .protected }),
              new.ingredients.contains(where: { $0.need.priority != .protected }),
              new.ingredients.filter({ $0.need.priority != .protected }).allSatisfy({ !usedNeeds.contains($0.need.id) && $0.need.priority == .required }),
              Set(new.ingredients.filter { $0.need.priority != .protected }.map(\.groupID)) ==
                Set(old.ingredients.filter { $0.need.priority != .protected }.map(\.groupID)) else {
            throw MealRecoveryError.invalid
        }
        let replacedIDs = Set(old.needs.filter { $0.priority != .protected }.map(\.id))
        guard !reservations.contains(where: { replacedIDs.contains($0.needID) }) else { throw MealRecoveryError.protectedAllocation }
        var meals = current.meals; meals[index] = new
        let after = projection(revision: new.revisionID, meals: meals, outside: outside)
        try validateDemands(after.demands)
        guard evidence.count <= 10_000, Set(evidence.map { $0.lot.id }).count == evidence.count else { throw MealRecoveryError.invalid }
        for item in evidence {
            guard item.availableAt.timeIntervalSinceReferenceDate.isFinite, item.availableAt >= item.lot.confirmedAt, item.lot.usable.amount >= .zero else {
                throw MealRecoveryError.invalid
            }
        }
        // Validate even retained future evidence; availability only affects counting.
        _ = try ConfirmedStockAllocator.allocate(lots: evidence.map(\.lot), needs: [])
        let lots = evidence.filter { $0.availableAt <= instant }.map(\.lot)
        let beforeAllocation = try ConfirmedCarryoverAllocator.allocate(lots: lots, needs: current.demands, reservations: reservations)
        let afterAllocation = try ConfirmedCarryoverAllocator.allocate(lots: lots, needs: after.demands, reservations: reservations)
        let affectedFoods = Set((old.needs + new.needs).filter { $0.priority != .protected }.map(\.foodID))
        for need in current.demands where !replacedIDs.contains(need.id) {
            guard after.demands.first(where: { $0.id == need.id }) == need,
                  let before = beforeAllocation.demands.first(where: { $0.id == need.id }),
                  let after = afterAllocation.demands.first(where: { $0.id == need.id }) else { throw MealRecoveryError.protectedAllocation }
            if let b = before.allocated, let a = after.allocated {
                let compared = try Quantity(amount: a, unit: after.unit, originalLiteral: "",
                    confirmedConversion: need.amount.confirmedConversion).converted(to: before.unit)
                guard let compared, compared >= b, after.issues.isEmpty || after.issues == before.issues else {
                    throw MealRecoveryError.protectedAllocation
                }
            } else if before != after || affectedFoods.contains(need.foodID) { throw MealRecoveryError.protectedAllocation }
            if reservations.contains(where: { $0.needID == need.id }) {
                let beforeEdges = beforeAllocation.allocations.filter { $0.needID == need.id }
                let afterEdges = afterAllocation.allocations.filter { $0.needID == need.id }
                guard beforeEdges.count == afterEdges.count else { throw MealRecoveryError.protectedAllocation }
                for edge in beforeEdges {
                    guard let updated = afterEdges.first(where: { $0.lotID == edge.lotID && $0.foodID == edge.foodID }),
                          try Quantity(amount: updated.amount, unit: updated.unit, originalLiteral: "",
                            confirmedConversion: need.amount.confirmedConversion).converted(to: edge.unit) == edge.amount else {
                        throw MealRecoveryError.protectedAllocation
                    }
                }
            }
        }
        // Apply the same saved exclusion vocabulary to named ingredients and actual
        // matched lots, without inventing medical judgments or identity from labels.
        let names = new.ingredients.map(\.foodName) + lots.filter { lot in new.needs.contains { $0.foodID == lot.foodID } }.map(\.name)
        for name in names {
            let recipe = MealTemplate(id: new.id, title: new.title,
                ingredients: [MealIngredient(id: new.id, name: name, quantity: nil)], exclusions: new.exclusions)
            guard (try? recipe.validate()) != nil else { throw MealRecoveryError.invalid }
        }
        let ids = Set(new.needs.map(\.id))
        let food = afterAllocation.demands.filter { ids.contains($0.id) }.allSatisfy { $0.shortfall == .zero && $0.issues.isEmpty }
        let timing: Bool
        if let due = new.due, let minutes = new.remainingElapsedMinutes {
            timing = instant.addingTimeInterval(TimeInterval(minutes) * 60) <= due &&
                (new.requiredLeadMinutes.map { minutes >= $0 || new.advanceStepsCompleted } ?? true)
        } else { timing = false }
        return Evaluation(after: after, beforeAllocation: beforeAllocation, afterAllocation: afterAllocation, food: food,
                          timing: timing, repeats: new.templateID.map(knownTemplates.contains) ?? false)
    }
    private static func consent(_ request: MealRecoveryRequest, feasible: Bool, repeats: Bool) throws {
        guard (!repeats || request.agreesToRepeat), (!request.proposesExtraTrip || request.agreesToExtraTrip) else {
            throw MealRecoveryError.consentRequired
        }
        guard feasible || request.acceptsUnresolved else { throw MealRecoveryError.unresolved }
    }
    private static func projection(revision: UUID, meals: [RecoveryMeal], outside: [StockNeed]) -> MealRecoveryProjection {
        MealRecoveryProjection(revisionID: revision, meals: meals, demands: meals.flatMap(\.needs) + outside)
    }
    private static func validateDemands(_ demands: [StockNeed]) throws {
        guard demands.count <= 10_000, demands.allSatisfy({ $0.amount.amount > .zero }) else { throw MealRecoveryError.invalid }
        _ = try ConfirmedStockAllocator.allocate(lots: [], needs: demands)
    }
    private static func validate(_ meal: RecoveryMeal) throws {
        guard !meal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meal.title.utf8.count <= 2_048,
              meal.servings > .zero, !meal.ingredients.isEmpty, meal.ingredients.count <= 1_000,
              meal.templateVersion.map({ $0 >= 0 }) ?? true,
              (meal.templateID == nil) == (meal.templateVersion == nil), TimeZone(identifier: meal.timeZoneID) != nil,
              meal.due?.timeIntervalSinceReferenceDate.isFinite != false,
              [meal.remainingElapsedMinutes, meal.requiredLeadMinutes].allSatisfy({ $0.map { $0 >= 0 && $0 <= 525_600 } ?? true }),
              meal.ingredients.allSatisfy({ !$0.foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(meal.ingredients.map { [$0.ingredientID.uuidString, $0.groupID?.uuidString ?? ""] }).count == meal.ingredients.count else {
            throw MealRecoveryError.invalid
        }
        try meal.scheduledDay?.validate()
        guard meal.scheduledDay.map({ $0.timeZoneIdentifier == meal.timeZoneID }) ?? true else { throw MealRecoveryError.invalid }
        try validateDemands(meal.needs)
        let recipe = MealTemplate(id: meal.id, title: meal.title, ingredients: meal.ingredients.map { MealIngredient(id: $0.need.id, name: $0.foodName, quantity: $0.need.amount) }, exclusions: meal.exclusions)
        guard (try? recipe.validate()) != nil else { throw MealRecoveryError.invalid }
    }
}
