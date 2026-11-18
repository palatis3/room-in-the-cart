import Foundation
import CoreDomain

/// Read-only supply for manual fallback instructions. It lends only the target's
/// own existing backing plus globally free stock; it releases no physical claim.
struct PickupFallbackCanonicalSupply {
    struct TargetSupply {
        let lots: [ConfirmedStockLot]
        let outsideGaps: [StockNeed]
        let unresolvedFoods: Set<UUID>
        let unknownCountFoods: Set<UUID>
        let pinnedTargetFoods: Set<UUID>
    }
    struct Hold: Identifiable {
        let id: UUID
        let name: String
        let amount: Quantity?
    }
    private struct Lot {
        let current: InventoryLot
        let free: Quantity?
        let usable: Bool
    }
    let basis: LedgerCanonicalPackStockEvidence.Basis
    let journeyID: UUID
    let journeyRevision: Int64
    let foodNames: [UUID: String]
    let foodLabels: [UUID: [String]]
    private let needs: [StockNeed]
    private let targets: [UUID: UUID]
    private let unresolvedTargets: Set<UUID>
    private let lots: [Lot]
    private let claims: [InventoryReservation]
    private let coverage: [UUID: InventoryReservationCoverage]
    private let edges: [StockAllocationEdge]

    @MainActor static func prepare(journey: PickupJourney, context: PantryPackStockReview.Context) throws -> Self {
        guard let head = context.mapping.sourceHeads.first(where: { $0.id == journey.id }),
              try JSONDecoder().decode(PickupJourney.self, from: head.payload) == journey,
              journey.closedAt == nil else { throw MealRecoveryError.stale }
        let live = try PantryLiveStockProjection.build(snapshot: context.snapshot, mapping: context.mapping,
            journeyID: journey.id, at: context.asOf)
        let needs = journey.physicalStockNeeds
        let demands = Dictionary(uniqueKeysWithValues: live.demands.map { ($0.id, $0) })
        var targets: [UUID: UUID] = [:], unresolved = Set<UUID>()
        for need in needs where need.amount.amount > .zero {
            guard let demand = demands[need.id], demand.reservation.foodID == need.foodID,
                  demand.reservation.state != .released else { throw MealRecoveryError.stale }
            targets[need.id] = demand.canonicalReservationID
            if !demand.issues.isEmpty || demand.reservation.state != .active { unresolved.insert(need.id) }
        }
        var names: [UUID: String] = [:], labels: [UUID: [String]] = [:]
        for row in live.lots {
            names[row.current.foodID] = names[row.current.foodID] ?? row.current.name
            labels[row.current.foodID, default: []].append(row.current.name)
        }
        return .init(basis: .init(originID: live.basis.originID, inventoryRevision: live.basis.inventoryRevision,
                sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) }),
            journeyID: journey.id, journeyRevision: journey.revision, foodNames: names, foodLabels: labels,
            needs: needs, targets: targets, unresolvedTargets: unresolved,
            lots: live.lots.map { .init(current: $0.current, free: $0.free, usable: $0.issues.isEmpty) },
            claims: context.snapshot.reservations,
            coverage: Dictionary(uniqueKeysWithValues: context.snapshot.availability.reservations.map { ($0.id, $0) }),
            edges: context.snapshot.availability.allocations)
    }

    func reservations(excluding targetID: UUID?) -> [Hold] {
        let targetClaim = targetID.flatMap { targets[$0] }
        return claims.filter { $0.state != .released && $0.id != targetClaim }
            .map { .init(id: $0.id, name: $0.name, amount: $0.amount) }
    }

    func supply(for target: StockNeed) throws -> TargetSupply {
        guard needs.contains(target), target.priority != .protected else { throw MealRecoveryError.stale }
        let targetClaim = targets[target.id]
        let pinnedTarget = claims.first { $0.id == targetClaim }?.lotID
        let edgesByClaim = Dictionary(grouping: edges, by: \.needID)
        let lotIndex = Dictionary(uniqueKeysWithValues: lots.map { ($0.current.id, $0) })
        var unresolved = Set<UUID>()
        if unresolvedTargets.contains(target.id) { unresolved.insert(target.foodID) }
        let usableTargetEdges = (targetClaim.flatMap { edgesByClaim[$0] } ?? []).filter { lotIndex[$0.lotID]?.usable == true }
        let stock = try lots.compactMap { row -> ConfirmedStockLot? in
            var amount = Rational.zero
            if pinnedTarget == nil || row.current.foodID != target.foodID {
                amount = try row.free?.converted(to: row.current.unit) ?? .zero
            }
            if !unresolvedTargets.contains(target.id) {
                for edge in usableTargetEdges where edge.lotID == row.current.id {
                    let quantity = Quantity(amount: edge.amount, unit: edge.unit, originalLiteral: edge.amount.description,
                        confirmedConversion: row.current.count.quantity?.confirmedConversion)
                    guard let converted = try quantity.converted(to: row.current.unit) else { throw MealRecoveryError.invalid }
                    amount = try amount.adding(converted)
                }
            }
            guard amount > .zero else { return nil }
            return .init(id: row.current.id, foodID: row.current.foodID, name: row.current.name,
                usable: .init(amount: amount, unit: row.current.unit, originalLiteral: amount.description, confirmedConversion: row.current.count.quantity?.confirmedConversion),
                confirmedAt: row.current.confirmedAt, source: row.current.location == .freezer ? .freezer : .pantry,
                useFirst: row.current.useFirst)
        }
        var gaps: [StockNeed] = []
        for claim in claims where claim.state != .released && claim.id != targetClaim {
            guard claim.state == .active, let row = coverage[claim.id], row.issues.isEmpty,
                  let gap = row.shortfall,
                  (edgesByClaim[claim.id] ?? []).allSatisfy({ lotIndex[$0.lotID]?.usable == true }),
                  claim.lotID == nil || gap.amount == .zero else {
                unresolved.insert(claim.foodID); continue
            }
            if gap.amount > .zero {
                let amount = Quantity(amount: gap.amount, unit: gap.unit, originalLiteral: gap.originalLiteral,
                    confirmedConversion: claim.amount?.confirmedConversion)
                gaps.append(.init(id: claim.id, foodID: claim.foodID, name: claim.name, amount: amount, priority: .protected))
            }
        }
        return .init(lots: stock, outsideGaps: gaps, unresolvedFoods: unresolved,
            unknownCountFoods: Set(lots.filter { $0.current.count.quantity == nil }.map { $0.current.foodID }),
            pinnedTargetFoods: pinnedTarget == nil ? [] : [target.foodID])
    }
}
