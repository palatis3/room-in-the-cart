import Foundation

/// Calendar-only identity for physically reviewed food. It is not an empty recipe,
/// a grocery contribution, a receipt, or evidence of whole-meal coverage.
public struct DinnerCarryoverLink: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let sourceShopID: UUID
    public let sourceOccurrenceID: UUID
    public let sourceNeedID: UUID
    public let sourceSupplyID: UUID
    public let confirmedSupplyID: UUID
    public let reservationID: UUID
    public let quantity: Quantity
    public let observedAt: Date
    public init(operationID: UUID, sourceShopID: UUID, sourceOccurrenceID: UUID, sourceNeedID: UUID,
                sourceSupplyID: UUID, confirmedSupplyID: UUID, reservationID: UUID, quantity: Quantity, observedAt: Date) {
        self.operationID = operationID; self.sourceShopID = sourceShopID; self.sourceOccurrenceID = sourceOccurrenceID
        self.sourceNeedID = sourceNeedID; self.sourceSupplyID = sourceSupplyID; self.confirmedSupplyID = confirmedSupplyID
        self.reservationID = reservationID; self.quantity = quantity; self.observedAt = observedAt
    }
    public func validate() throws {
        guard quantity.amount > .zero, observedAt.timeIntervalSinceReferenceDate.isFinite else { throw PickupError.invalidEvidence }
        _ = try quantity.converted(to: quantity.unit)
    }
}

extension MealOccurrence {
    /// Snapshot used for the new dated target. Checkout keeps its original occurrence.
    public func carryoverSource(meal: RecoveryMeal, notes: String, sourceURL: String?,
                                evidence: RecipeSourceEvidence?, groups: [ServingGroup]) -> MealOccurrence {
        MealOccurrence(id: id, templateID: meal.templateID, templateRevision: meal.templateVersion,
            title: meal.title, servings: meal.servings, notes: notes, sourceURL: sourceURL,
            sourceEvidence: evidence, exclusions: meal.exclusions, servingGroups: groups,
            leadTimeMinutes: meal.requiredLeadMinutes, completedSteps: [], ingredientContributionIDs: [],
            scheduledDay: meal.scheduledDay, isHidden: isHidden, removedAt: removedAt)
    }
}

public struct DinnerCarryoverPlan: Codable, Equatable, Sendable {
    public let occurrenceID: UUID
    public let revisionID: UUID
    public let baseRevisionID: UUID
    public let ingredientExclusions: [String]?
    public var targetExclusions: [String] {
        source.exclusions + (ingredientExclusions ?? []).filter { !source.exclusions.contains($0) }
    }
    public let purchasedSource: MealOccurrence?
    public let source: MealOccurrence
    public let day: MealDay
    public let servings: Rational
    public let link: DinnerCarryoverLink
    public init(occurrenceID: UUID, revisionID: UUID, baseRevisionID: UUID, source: MealOccurrence,
                day: MealDay, servings: Rational, link: DinnerCarryoverLink, purchasedSource: MealOccurrence? = nil,
                ingredientExclusions: [String]? = nil) {
        self.occurrenceID = occurrenceID; self.revisionID = revisionID; self.baseRevisionID = baseRevisionID
        self.ingredientExclusions = ingredientExclusions
        self.purchasedSource = purchasedSource
        self.source = source; self.day = day; self.servings = servings; self.link = link
    }
    public func validate() throws {
        try link.validate(); try day.validate()
        guard purchasedSource.map({ $0.id == source.id && $0.carryover == nil && $0.removedAt == nil }) ?? true,
              source.id == link.sourceOccurrenceID, source.carryover == nil, source.removedAt == nil,
              occurrenceID != source.id, servings > .zero, day.date != nil else { throw PickupError.invalidEvidence }
    }
}

public struct ConfirmedStockReservation: Codable, Equatable, Sendable {
    public let needID: UUID
    public let lotID: UUID
    public init(needID: UUID, lotID: UUID) { self.needID = needID; self.lotID = lotID }
}

/// Existing priority allocator semantics, with explicit physical-identity pins.
/// Protected needs allocate first. Pinned needs cannot borrow from another lot.
/// Unknown conversions remain unknown and never manufacture spare supply.
public enum ConfirmedCarryoverAllocator {
    public static func allocate(lots: [ConfirmedStockLot], needs: [StockNeed], reservations: [ConfirmedStockReservation]) throws -> StockAllocationResult {
        if reservations.isEmpty { return try ConfirmedStockAllocator.allocate(lots: lots, needs: needs) }
        _ = try ConfirmedStockAllocator.allocate(lots: lots, needs: needs)
        guard Set(reservations.map(\.needID)).count == reservations.count else { throw PickupError.duplicateIdentity }
        let pins = Dictionary(uniqueKeysWithValues: reservations.map { ($0.needID, $0.lotID) })
        for reservation in reservations {
            guard let need = needs.first(where: { $0.id == reservation.needID }),
                  (lots.first(where: { $0.id == reservation.lotID }).map { $0.foodID == need.foodID } ?? true), need.priority != .protected else { throw PickupError.invalidEvidence }
        }
        var demands: [StockDemandCoverage] = [], edges: [StockAllocationEdge] = [], balances: [StockLotBalance] = []
        let foods = Set(lots.map(\.foodID) + needs.map(\.foodID))
        for food in foods.sorted(by: { $0.uuidString < $1.uuidString }) {
            let foodNeeds = needs.filter { $0.foodID == food }
            if !foodNeeds.contains(where: { pins[$0.id] != nil }) {
                let unchanged = try ConfirmedStockAllocator.allocate(lots: lots.filter { $0.foodID == food }, needs: foodNeeds)
                demands += unchanged.demands; edges += unchanged.allocations; balances += unchanged.remainingLots
                continue
            }
            let foodLots = lots.filter { $0.foodID == food }.sorted { ($0.useFirst == true ? 0 : 1) < ($1.useFirst == true ? 0 : 1) }
            let indexed = needs.enumerated().filter { $0.element.foodID == food }
            let ordered = indexed.sorted { left, right in
                let lp = left.element.priority == .protected ? 0 : pins[left.element.id] != nil ? 1 : left.element.priority == .required ? 2 : 3
                let rp = right.element.priority == .protected ? 0 : pins[right.element.id] != nil ? 1 : right.element.priority == .required ? 2 : 3
                return lp == rp ? left.offset < right.offset : lp < rp
            }.map(\.element)
            guard let unit = ordered.first?.amount.unit ?? foodLots.first?.usable.unit else { continue }
            let quantities = try ordered.map { try $0.amount.converted(to: unit) }
            var remaining = try foodLots.map { try $0.usable.converted(to: unit) }
            let unknownDemand = quantities.contains(where: { $0 == nil })
            for (index, need) in ordered.enumerated() {
                guard !unknownDemand, let amount = quantities[index] else {
                    demands.append(StockDemandCoverage(id: need.id, foodID: food, unit: unit, needed: quantities[index], allocated: nil, shortfall: nil, issues: [.conversionUnknown])); continue
                }
                var uncovered = amount, allocated = Rational.zero
                let eligible = foodLots.indices.filter { pins[need.id] == nil || foodLots[$0].id == pins[need.id] }
                let unresolved = eligible.contains { remaining[$0] == nil }
                for position in eligible {
                    guard let available = remaining[position] else { continue }
                    let used = min(available, uncovered)
                    if used > .zero {
                        edges.append(StockAllocationEdge(lotID: foodLots[position].id, needID: need.id, foodID: food, unit: unit, amount: used))
                        allocated = try allocated.adding(used); uncovered = try uncovered.subtracting(used)
                        remaining[position] = try available.subtracting(used)
                    }
                }
                demands.append(StockDemandCoverage(id: need.id, foodID: food, unit: unit, needed: amount,
                    allocated: unresolved && uncovered > .zero ? nil : allocated,
                    shortfall: unresolved && uncovered > .zero ? nil : uncovered, issues: unresolved ? [.conversionUnknown] : []))
            }
            for (index, lot) in foodLots.enumerated() {
                balances.append(StockLotBalance(lotID: lot.id, foodID: food, unit: unit,
                    remainingUnallocated: remaining[index] ?? .zero, issues: remaining[index] == nil || unknownDemand ? [.conversionUnknown] : []))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: needs.enumerated().map { ($0.element.id, $0.offset) })
        demands.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        return StockAllocationResult(demands: demands, allocations: edges, remainingLots: balances)
    }
}
