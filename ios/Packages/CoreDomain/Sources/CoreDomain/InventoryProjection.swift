import Foundation

public enum InventoryAvailabilityIssue: String, Codable, Sendable {
    case countUnknown, reservationUnresolved, conversionUnknown, sourceUnavailable
}
public struct InventoryLotAvailability: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revision: Int64
    public let count: InventoryCount
    public let remaining: Quantity?
    /// Confirmed backing. Nil means a held claim cannot currently be quantified.
    public let held: Quantity?
    public let free: Quantity?
    public let issues: [InventoryAvailabilityIssue]
}
public struct InventoryReservationCoverage: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let requested: Quantity?
    public let backed: Quantity?
    public let shortfall: Quantity?
    public let issues: [InventoryAvailabilityIssue]
    public var unresolved: Bool { !issues.isEmpty }
}
public struct InventoryProjection: Equatable, Sendable {
    public static let maximumLots = 10_000
    public static let maximumReservations = 20_000
    public let lots: [InventoryLotAvailability]
    public let reservations: [InventoryReservationCoverage]

    /// Input must be one authoritative, revision-consistent private snapshot,
    /// including claims from every shop. A selected-shop subset is insufficient.
    public static func build(originID: UUID, lots: [InventoryLot], reservations: [InventoryReservation], at now: Date) throws -> InventoryProjection {
        guard lots.count <= maximumLots, reservations.count <= maximumReservations else { throw InventoryError.capacity }
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw InventoryError.invalid("now") }
        guard Set(lots.map(\.id)).count == lots.count, Set(lots.map(\.source)).count == lots.count,
              Set(lots.map(\.observationID)).count == lots.count,
              Set(reservations.map(\.id)).count == reservations.count else { throw InventoryError.duplicateIdentity }
        for lot in lots {
            try lot.validate()
            guard lot.source.originID == originID else { throw InventoryError.wrongOrigin }
            guard lot.updatedAt <= now else { throw InventoryError.invalid("futureLot") }
        }
        let indexedLots = Dictionary(uniqueKeysWithValues: lots.map { ($0.id, $0) })
        for reservation in reservations {
            try reservation.validate()
            guard reservation.originID == originID else { throw InventoryError.wrongOrigin }
            if let id = reservation.lotID, let lot = indexedLots[id] {
                guard lot.foodID == reservation.foodID else { throw InventoryError.invalid("reservationFood") }
            }
        }
        let held = reservations.filter { $0.state != .released }
        let unresolvedHolds = held.filter { $0.state == .unresolved }
        func affects(_ claim: InventoryReservation, _ lot: InventoryLot) -> Bool {
            claim.lotID.map { $0 == lot.id } ?? (claim.foodID == lot.foodID)
        }
        func blocked(_ lot: InventoryLot) -> Bool { unresolvedHolds.contains { affects($0, lot) } }
        let stock = lots.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { lot -> ConfirmedStockLot? in
            guard !blocked(lot), let quantity = lot.count.quantity else { return nil }
            return ConfirmedStockLot(id: lot.id, foodID: lot.foodID, name: lot.name, usable: quantity,
                confirmedAt: lot.confirmedAt, source: lot.location == .freezer ? .freezer : .pantry, useFirst: lot.useFirst)
        }
        let active = held.filter { $0.state == .active }.sorted { $0.id.uuidString < $1.id.uuidString }
        let protectedPins = active.filter { $0.priority == .protected && $0.lotID != nil }
        let other = active.filter { $0.priority != .protected || $0.lotID == nil }
        func allocate(_ claims: [InventoryReservation], from available: [ConfirmedStockLot], protectedPinStage: Bool = false) throws -> StockAllocationResult {
            let foods = Set(claims.map(\.foodID))
            let needs = claims.map { claim in
                // This stage contains ONLY protected pins: no unpinned demand can
                // compete until these exact physical claims have been allocated.
                StockNeed(id: claim.id, foodID: claim.foodID, name: claim.name, amount: claim.amount!,
                          priority: protectedPinStage ? .required : claim.priority)
            }
            return try ConfirmedCarryoverAllocator.allocate(lots: available.filter { foods.contains($0.foodID) }, needs: needs,
                reservations: claims.compactMap { claim in claim.lotID.map { ConfirmedStockReservation(needID: claim.id, lotID: $0) } })
        }
        let first = try allocate(protectedPins, from: stock, protectedPinStage: true)
        let firstUncertainFoods = Set(first.demands.filter { !$0.issues.isEmpty }.map(\.foodID) +
            first.remainingLots.filter { !$0.issues.isEmpty }.compactMap { indexedLots[$0.lotID]?.foodID })
        func used(_ edges: [StockAllocationEdge], by lot: ConfirmedStockLot) throws -> Rational {
            try edges.filter { $0.lotID == lot.id }.reduce(.zero) { total, edge in
                let amount = Quantity(amount: edge.amount, unit: edge.unit, originalLiteral: edge.amount.description)
                guard let value = try amount.converted(to: lot.usable.unit, using: lot.usable.confirmedConversion) else {
                    throw InventoryError.invalid("allocationConversion")
                }
                return try total.adding(value)
            }
        }
        let remaining = try stock.filter { !firstUncertainFoods.contains($0.foodID) }.map { lot in
            ConfirmedStockLot(id: lot.id, foodID: lot.foodID, name: lot.name,
                usable: Quantity(amount: try lot.usable.amount.subtracting(used(first.allocations, by: lot)), unit: lot.usable.unit,
                                 originalLiteral: lot.usable.originalLiteral, confirmedConversion: lot.usable.confirmedConversion),
                confirmedAt: lot.confirmedAt, source: lot.source, useFirst: lot.useFirst == true)
        }
        let second = try allocate(other, from: remaining)
        let uncertainFoods = firstUncertainFoods.union(second.demands.filter { !$0.issues.isEmpty }.map(\.foodID))
            .union(second.remainingLots.filter { !$0.issues.isEmpty }.compactMap { indexedLots[$0.lotID]?.foodID })
        let edges = first.allocations + second.allocations
        let coverage = Dictionary(uniqueKeysWithValues: (first.demands + second.demands).map { ($0.id, $0) })
        let rows = try lots.map { lot -> InventoryLotAvailability in
            var issues: [InventoryAvailabilityIssue] = []
            if lot.count.quantity == nil { issues.append(.countUnknown) }
            let unquantifiedHold = blocked(lot) || (lot.count.quantity == nil && held.contains { affects($0, lot) })
            if unquantifiedHold { issues.append(.reservationUnresolved) }
            if uncertainFoods.contains(lot.foodID) { issues.append(.conversionUnknown) }
            let basis = ConfirmedStockLot(id: lot.id, foodID: lot.foodID, name: lot.name,
                usable: lot.count.quantity ?? Quantity(amount: .zero, unit: lot.unit, originalLiteral: "0"), confirmedAt: lot.confirmedAt)
            let amount = try used(edges, by: basis)
            let heldAmount = unquantifiedHold || uncertainFoods.contains(lot.foodID) ? nil : Quantity(amount: amount, unit: lot.unit, originalLiteral: amount.description)
            let free: Quantity?
            if issues.isEmpty, let quantity = lot.count.quantity {
                let balance = try quantity.amount.subtracting(amount)
                free = Quantity(amount: balance, unit: quantity.unit, originalLiteral: balance.description, confirmedConversion: quantity.confirmedConversion)
            } else { free = nil }
            return InventoryLotAvailability(id: lot.id, revision: lot.revision, count: lot.count,
                remaining: lot.count.quantity, held: heldAmount, free: free, issues: issues)
        }
        let claims = held.map { claim -> InventoryReservationCoverage in
            guard claim.state == .active, let requested = claim.amount, let result = coverage[claim.id] else {
                return InventoryReservationCoverage(id: claim.id, requested: claim.amount, backed: nil, shortfall: nil, issues: [.reservationUnresolved])
            }
            let relevant = lots.filter { affects(claim, $0) }
            var issues: [InventoryAvailabilityIssue] = []
            if claim.lotID != nil && relevant.isEmpty { issues.append(.sourceUnavailable) }
            if uncertainFoods.contains(claim.foodID) || !result.issues.isEmpty { issues.append(.conversionUnknown) }
            let unknownBacking = relevant.contains { $0.count.quantity == nil || blocked($0) }
            if unknownBacking && result.shortfall != .zero { issues.append(.reservationUnresolved) }
            let backed = result.allocated.map { Quantity(amount: $0, unit: result.unit, originalLiteral: $0.description) }
            let shortfall = issues.isEmpty ? result.shortfall.map { Quantity(amount: $0, unit: result.unit, originalLiteral: $0.description) } : nil
            return InventoryReservationCoverage(id: claim.id, requested: requested, backed: backed, shortfall: shortfall, issues: issues)
        }
        return InventoryProjection(lots: rows, reservations: claims)
    }
}
