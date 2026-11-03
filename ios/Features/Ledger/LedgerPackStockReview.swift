import Foundation
import CoreDomain

/// Reads the actual saved pickup allocation. Names and unallocated lot totals are
/// never sufficient evidence that food is available for this list partition.
enum LedgerPackStockReview {
    static func evidence(shop: ShoppingLedger, lineID: UUID, requirement: LedgerPackRequirement,
                         journey: PickupJourney?, pickupWorkspaceID: UUID?, bindings: [DinnerPortionBinding]) throws -> LedgerPackStockEvidence? {
        guard let journey, journey.id == shop.id else { return nil }
        let relevant = journey.stockLots.contains { $0.foodID == lineID && ($0.source == .pantry || $0.source == .freezer) }
        guard relevant else { return nil }
        guard let pickupWorkspaceID, journey.closedAt == nil, journey.pickup == nil,
              let basket = journey.basket, basket.phase != .reportedPlaced,
              journey.ledgerSourceRevisionID == shop.revisionID, journey.ledgerBasis == shop.basis else { throw LedgerPackError.staleSource }
        // Review the gross source without pack evidence, so the allocation cannot
        // inherit a previously netted purchase quantity as a new meal requirement.
        let source = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 0, previous: nil, bindings: bindings)
        guard source.needs == journey.plannedNeeds else { throw LedgerPackError.staleSource }
        let snapshot = LedgerPackStockEvidence(sourceWorkspaceID: pickupWorkspaceID, journeyID: journey.id,
            journeyRevision: journey.revision, basketRevisionID: basket.current.id, shopRevisionID: shop.revisionID,
            lineID: lineID, listNeedIDs: journey.plannedNeeds.filter { $0.orderLineID == lineID }.map(\.id),
            lots: journey.stockLots.filter { $0.source == .pantry || $0.source == .freezer },
            needs: journey.physicalStockNeeds, reservations: journey.carryoverStockReservations)
        _ = try snapshot.confirmedQuantity(for: requirement)
        return snapshot
    }

    static func currentEvidence(for selection: LedgerPackSelection, shop: ShoppingLedger, journey: PickupJourney?,
                                pickupWorkspaceID: UUID?, bindings: [DinnerPortionBinding]) throws -> LedgerPackStockEvidence? {
        guard let reviewed = selection.stockEvidence else { return nil }
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: selection.lineID, bindings: bindings)
        guard let journey, let live = try evidence(shop: shop, lineID: selection.lineID, requirement: requirement,
            journey: journey, pickupWorkspaceID: pickupWorkspaceID, bindings: bindings),
              live.sourceWorkspaceID == reviewed.sourceWorkspaceID, live.journeyID == reviewed.journeyID,
              live.shopRevisionID == reviewed.shopRevisionID, live.lineID == reviewed.lineID,
              live.listNeedIDs == reviewed.listNeedIDs, live.lots == reviewed.lots,
              live.needs == reviewed.needs, live.reservations == reviewed.reservations else { throw LedgerPackError.staleSource }
        if live == reviewed { return reviewed }
        // One intentional checkout application is the only revision exception.
        // Its retained selection and exact parent basket are the application receipt.
        let appliedRevision = reviewed.journeyRevision.addingReportingOverflow(1)
        guard !appliedRevision.overflow, journey.revision == appliedRevision.partialValue,
              journey.ledgerPackSelections.contains(selection), let basket = journey.basket,
              basket.current.parentID == reviewed.basketRevisionID,
              case .applied = basket.current.reason else { throw LedgerPackError.staleSource }
        if selection.isNoPurchase {
            guard !basket.current.lines.contains(where: { $0.id == selection.lineID }) else { throw LedgerPackError.staleSource }
        } else {
            guard let line = basket.current.lines.first(where: { $0.id == selection.lineID }),
                  line.quantity == selection.purchasedQuantity,
                  line.expectedCost == selection.selectedResult.totalCost.map(CostEvidence.exact) else { throw LedgerPackError.staleSource }
        }
        return reviewed
    }

    /// Validates the already applied basket, without adopting its old selection
    /// for a new checkout revision. Quote, copy and report events can advance the
    /// journey while the exact application basket and material allocation stay fixed.
    static func basketBasisIsCurrent(_ journey: PickupJourney, pickupWorkspaceID: UUID?) -> Bool {
        guard let basket = journey.basket else { return true }
        if basket.phase == .reportedPlaced { return true } // Historical purchase facts stay sealed.
        for selection in journey.ledgerPackSelections {
            guard (try? selection.validate()) != nil else { return false }
            guard let evidence = selection.stockEvidence else {
                if journey.stockLots.contains(where: {
                    $0.foodID == selection.lineID && ($0.source == .pantry || $0.source == .freezer)
                }) { return false }
                continue
            }
            guard evidence.sourceWorkspaceID == pickupWorkspaceID, evidence.journeyID == journey.id,
                  evidence.shopRevisionID == journey.ledgerSourceRevisionID,
                  evidence.lots == journey.stockLots.filter({ $0.source == .pantry || $0.source == .freezer }),
                  evidence.needs == journey.physicalStockNeeds, evidence.reservations == journey.carryoverStockReservations,
                  evidence.listNeedIDs == journey.plannedNeeds.filter({ $0.orderLineID == selection.lineID }).map(\.id),
                  basket.current.parentID == evidence.basketRevisionID,
                  case .applied = basket.current.reason else { return false }
            if selection.isNoPurchase {
                guard !basket.current.lines.contains(where: { $0.id == selection.lineID }) else { return false }
            } else {
                guard let line = basket.current.lines.first(where: { $0.id == selection.lineID }),
                      line.quantity == selection.purchasedQuantity,
                      line.expectedCost == selection.selectedResult.totalCost.map(CostEvidence.exact) else { return false }
            }
        }
        return true
    }

    static func isCurrent(_ selection: LedgerPackSelection, shop: ShoppingLedger, workspaceID: UUID,
                          journey: PickupJourney?, pickupWorkspaceID: UUID?, bindings: [DinnerPortionBinding]) throws -> Bool {
        if selection.stockEvidence == nil {
            // A pre-stock choice must be reviewed again after someone confirms a
            // matching lot, even if the ledger's gross demand has not changed.
            if journey?.id == shop.id, journey?.stockLots.contains(where: {
                $0.foodID == selection.lineID && ($0.source == .pantry || $0.source == .freezer)
            }) == true { return false }
            return try selection.isCurrent(in: shop, workspaceID: workspaceID, bindings: bindings)
        }
        guard let evidence = try? currentEvidence(for: selection, shop: shop, journey: journey,
            pickupWorkspaceID: pickupWorkspaceID, bindings: bindings) else { return false }
        return try selection.isCurrent(in: shop, workspaceID: workspaceID, bindings: bindings, currentStockEvidence: evidence)
    }
}

extension PickupJourney {
    var isAtHomeOnlyPlan: Bool {
        let covered = Set(ledgerPackSelections.filter(\.isNoPurchase).map(\.lineID))
        return basket?.current.lines.isEmpty == true && !plannedNeeds.isEmpty &&
            plannedNeeds.allSatisfy { covered.contains($0.orderLineID) }
    }
}
