import Foundation
import CoreDomain

/// New-demand evidence only: canonical claims have already been subtracted once.
/// Replacing a meal never implicitly releases its existing physical reservations.
enum DinnerPantrySupply {
    typealias Basis = LedgerCanonicalPackStockEvidence.Basis
    struct Snapshot {
        let basis: Basis
        let foods: [IdeaSupplyFood]
        let globallyFreeLots: [ConfirmedStockLot]
        let reservations: [UUID: [IdeaSupplyReservation]]
        let unresolvedFoodIDs: Set<UUID>
        let representedNeedIDs: Set<UUID>
    }

    /// Private matching choices use the same current observation wording as the pantry shelf.
    static func lotDetail(_ lot: InventoryLot) -> String {
        [pantryLocationName(lot.location), pantryCount(lot.count, estimate: lot.countWording),
         lot.confirmedAt.formatted(date: .abbreviated, time: .shortened)].joined(separator: " · ")
    }

    @MainActor static func read(pickup: PickupModel, workspaceID: UUID?, linkedWorkspaceID: UUID?,
                               shopID: UUID) throws -> Snapshot? {
        guard pickup.pantryIsActive else { return nil }
        guard let workspaceID, workspaceID == linkedWorkspaceID,
              let context = try pickup.pantryReviewContext() else { throw DinnerPlanningError.forbidden }
        return try build(context: context, shopID: shopID)
    }

    @MainActor static func build(context: PantryPackStockReview.Context, shopID: UUID) throws -> Snapshot {
        let live = try PantryLiveStockProjection.buildGlobal(snapshot: context.snapshot, mapping: context.mapping, at: context.asOf)
        let basis = Basis(originID: live.basis.originID, inventoryRevision: live.basis.inventoryRevision,
            sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) })
        let foods = live.lots.map { row in
            IdeaSupplyFood(id: row.current.foodID, name: row.current.name, detail: lotDetail(row.current))
        }
        var reservations: [UUID: [IdeaSupplyReservation]] = [:]
        for claim in context.snapshot.reservations where claim.state != .released {
            reservations[claim.foodID, default: []].append(.init(id: claim.id, name: claim.name,
                quantity: claim.amount, protected: claim.priority == .protected))
        }
        // Independent confirmed lots can still provide a conservative credit. If
        // every row is unknown/held, absence of a free numeric row is not zero food.
        let resolvedFoods = Set(live.lots.filter { $0.free != nil }.map { $0.current.foodID })
        let unresolved = Set(live.lots.filter { $0.free == nil }.map { $0.current.foodID }).subtracting(resolvedFoods)
            .union(context.snapshot.reservations.filter { $0.state == .unresolved }.map(\.foodID))
        let represented = Set(context.mapping.claimLinks.filter { $0.journeyIDs.contains(shopID) }.map(\.legacyNeedID))
        return Snapshot(basis: basis, foods: foods, globallyFreeLots: live.globallyFreeLots,
            reservations: reservations, unresolvedFoodIDs: unresolved, representedNeedIDs: represented)
    }
}
