import Foundation
import CoreDomain

/// Binds a replacement to the complete canonical food and claim graph. Original
/// pickup counts remain historical; another shop's reservations stay in the proof.
@MainActor enum PantryMealRecoveryEvidence {
    static func prepare(request: MealRecoveryRequest, history: PickupMealRecoveryHistory,
                        journey: PickupJourney, context: PantryPackStockReview.Context) throws -> CanonicalRecoveryAllocation {
        guard context.snapshot.state.active,
              let head = context.mapping.sourceHeads.first(where: { $0.id == journey.id }),
              try JSONDecoder().decode(PickupJourney.self, from: head.payload) == journey,
              request.shopID == journey.id else { throw PickupMealRecoveryError.stale }
        let live = try PantryLiveStockProjection.build(snapshot: context.snapshot, mapping: context.mapping,
            journeyID: journey.id, at: context.asOf)
        let current = try MealRecoveryEngine.project(history.domain)
        let demands = Dictionary(uniqueKeysWithValues: live.demands.map { ($0.id, $0) })
        let bindings = try current.demands.map { need -> CanonicalRecoveryAllocation.Binding in
            guard let demand = demands[need.id], demand.reservation.foodID == need.foodID else {
                throw PickupMealRecoveryError.sourceChanged
            }
            return .init(needID: need.id, reservationID: demand.canonicalReservationID)
        }
        let replacement = try request.replacement.needs.filter { $0.priority != .protected }.map { need in
            CanonicalRecoveryAllocation.Binding(needID: need.id,
                reservationID: try PantryLegacyMigration.claimIdentity(originID: context.snapshot.state.workspaceID,
                    needID: need.id, foodID: need.foodID))
        }
        return try CanonicalRecoveryAllocation.review(
            basis: .init(originID: live.basis.originID, inventoryRevision: live.basis.inventoryRevision,
                sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) }),
            journeyRevision: journey.revision, lots: context.snapshot.lots, claims: context.snapshot.reservations,
            bindings: bindings, replacementBindings: replacement,
            eligibility: PantryPackStockReview.lotEligibility(live: live, context: context), at: context.asOf)
    }
}
