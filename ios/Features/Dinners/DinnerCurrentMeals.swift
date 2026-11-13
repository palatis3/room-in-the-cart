import Foundation
import CoreDomain

/// Read-only presentation rows. The original ledger remains the immutable
/// purchase/planning source; a recovered meal is never forged into that ledger.
enum DinnerCurrentMeal: Equatable, Identifiable {
    case original(MealOccurrence)
    case recovered(original: MealOccurrence, current: PickupRecoveryMealDefinition)
    var id: UUID { switch self { case .original(let meal): meal.id; case .recovered(let meal, _): meal.id } }
    var title: String { switch self { case .original(let meal): meal.title; case .recovered(_, let value): value.meal.title } }
    var servings: Rational { switch self { case .original(let meal): meal.servings; case .recovered(_, let value): value.meal.servings } }
    var scheduledDay: MealDay? { switch self { case .original(let meal): meal.scheduledDay; case .recovered(_, let value): value.meal.scheduledDay } }
    var isHidden: Bool { switch self { case .original(let meal): meal.isHidden; case .recovered(let meal, _): meal.isHidden } }
}

struct DinnerCurrentMeals: Equatable {
    let all: [DinnerCurrentMeal]
    func on(_ day: MealDay) -> [DinnerCurrentMeal] { all.filter { $0.scheduledDay?.hasSameCivilDate(as: day) == true } }
    var unscheduled: [DinnerCurrentMeal] { all.filter { $0.scheduledDay == nil } }
    func occurrence(_ id: UUID) throws -> DinnerCurrentMeal {
        guard let value = all.first(where: { $0.id == id }) else { throw PickupMealRecoveryError.sourceChanged }
        return value
    }
    static func project(shop: ShoppingLedger, definitions: [PickupRecoveryMealDefinition], recovered: Set<UUID>) throws -> Self {
        let active = shop.mealOccurrences.filter { $0.removedAt == nil }
        guard Set(active.map(\.id)).count == active.count,
              Set(definitions.map { $0.meal.id }).count == definitions.count,
              recovered.isSubset(of: Set(active.map(\.id))) else { throw PickupMealRecoveryError.sourceChanged }
        return .init(all: try active.map { original in
            guard recovered.contains(original.id) else { return .original(original) }
            guard let current = definitions.first(where: { $0.meal.id == original.id }) else { throw PickupMealRecoveryError.sourceChanged }
            return .recovered(original: original, current: current)
        })
    }
}

enum DinnerMealDestination: Equatable {
    case original(MealOccurrence)
    case recovered(shopID: UUID, occurrenceID: UUID)
}

extension DinnerFeatureModel {
    /// Route identity is not read/write authority. Keep the same recovery entry
    /// alive during its own pending CAS; that entry owns the live access lease.
    func currentMealDestination(_ id: UUID, pickup: PickupModel) throws -> DinnerMealDestination {
        guard let shop, let original = shop.mealOccurrences.first(where: { $0.id == id && $0.removedAt == nil }) else {
            throw PickupMealRecoveryError.sourceChanged
        }
        guard store is LedgerModel else { return .original(original) }
        if let access = accessProvider(shop.id), case .household = access.scope { return .original(original) }
        guard pickup.ready else { throw PickupMealRecoveryError.unavailable }
        guard let history = pickup.journeys.first(where: { $0.id == shop.id })?.mealRecovery,
              history.domain.events.contains(where: { $0.request.target.id == id }) else { return .original(original) }
        guard pickup.selectedID == shop.id, pickup.recoveryLedger?.sourceWorkspaceID == store.sourceWorkspaceID,
              pickup.recoveryLedger?.shop == shop else { throw PickupMealRecoveryError.sourceChanged }
        return .recovered(shopID: shop.id, occurrenceID: id)
    }

    /// All calendar/list/detail routes share this checked projection. Failure is
    /// surfaced to the user, never converted to the superseded original meal.
    func currentMeals(pickup: PickupModel) throws -> DinnerCurrentMeals {
        guard let shop, let identity = editorIdentity else { throw PickupMealRecoveryError.forbidden }
        guard case .local = identity.scope else {
            return try .project(shop: shop, definitions: [], recovered: [])
        }
        guard pickup.ready else { throw PickupMealRecoveryError.unavailable }
        guard let journey = pickup.journeys.first(where: { $0.id == shop.id }), let history = journey.mealRecovery else {
            return try .project(shop: shop, definitions: [], recovered: [])
        }
        guard pickup.selectedID == shop.id,
              pickup.recoveryLedger?.sourceWorkspaceID == store.sourceWorkspaceID,
              pickup.recoveryLedger?.shop == shop else { throw PickupMealRecoveryError.sourceChanged }
        return try .project(shop: shop, definitions: pickup.recoveryDefinitions(),
            recovered: Set(history.domain.events.map { $0.request.target.id }))
    }
}
