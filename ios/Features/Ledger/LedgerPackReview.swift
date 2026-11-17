import Foundation
import CoreDomain

struct LedgerPackReview {
    let operationID: UUID
    let sourceWorkspaceID: UUID
    let workspaceRevision: Int64
    let bindings: [DinnerPortionBinding]
    let sourceShop: ShoppingLedger
    let lineID: UUID
    let requirement: LedgerPackRequirement
    let stockEvidence: LedgerPackStockEvidence?
    let canonicalStockEvidence: LedgerCanonicalPackStockEvidence?
    let grossBasis: PantryPackSelectionCommitPort.GrossBasis?
    let request: ComparisonRequest
    let result: CoreDomain.ComparisonResult
    let reviewedAt: Date
    let source: String

    @MainActor static func prepare(ledger: LedgerModel, shopID: UUID, lineID: UUID,
                                  offerA: PackOffer, offerB: PackOffer, itemCap: Money?,
                                  at: Date, source: String, pickup: PickupModel? = nil) throws -> LedgerPackReview {
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave,
              let workspaceID = ledger.sourceWorkspaceID,
              let shop = ledger.workspace.shops.first(where: { $0.id == shopID }) else { throw LedgerPackError.staleSource }
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: lineID, bindings: ledger.workspace.dinnerPlanning.portionBindings)
        if let pickup { guard pickup.ready, !pickup.saving, !pickup.hasPendingSave else { throw LedgerPackError.staleSource } }
        let context = try pickup?.pantryReviewContext()
        let canonicalStockEvidence: LedgerCanonicalPackStockEvidence?
        let grossBasis: PantryPackSelectionCommitPort.GrossBasis?
        if let context {
            if context.mapping.sourceHeads.contains(where: { $0.id == shopID }) {
                canonicalStockEvidence = try PantryPackStockReview.evidence(shop: shop, lineID: lineID, requirement: requirement,
                    bindings: ledger.workspace.dinnerPlanning.portionBindings, context: context)
                grossBasis = nil
            } else {
                // Only a complete successful read with explicit source absence
                // admits gross comparison. Invalid canonical evidence never falls back.
                grossBasis = try .review(context: context, absentJourneyID: shopID)
                canonicalStockEvidence = nil
            }
        } else { canonicalStockEvidence = nil; grossBasis = nil }
        guard pickup?.pantryIsActive != true || context != nil else { throw LedgerPackError.staleSource }
        let stockEvidence = try context == nil ? LedgerPackStockReview.evidence(shop: shop, lineID: lineID, requirement: requirement,
            journey: pickup?.journeys.first { $0.id == shopID }, pickupWorkspaceID: pickup?.sourceWorkspaceID,
            bindings: ledger.workspace.dinnerPlanning.portionBindings) : nil
        let confirmed = try canonicalStockEvidence?.confirmedQuantity(for: requirement) ?? stockEvidence?.confirmedQuantity(for: requirement)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
            confirmedAtHome: confirmed, protectedAmount: requirement.protectedQuantity, offerA: offerA, offerB: offerB, itemCap: itemCap)
        return LedgerPackReview(operationID: UUID(), sourceWorkspaceID: workspaceID, workspaceRevision: ledger.revision,
            bindings: ledger.workspace.dinnerPlanning.portionBindings, sourceShop: shop, lineID: lineID, requirement: requirement, stockEvidence: stockEvidence, canonicalStockEvidence: canonicalStockEvidence, grossBasis: grossBasis, request: request,
            result: try PackComparison.evaluate(request), reviewedAt: at, source: source)
    }

    @MainActor func save(offerID: String, ledger: LedgerModel, pickup: PickupModel? = nil) async throws -> Bool {
        let selection = try LedgerPackSelection(id: operationID, workspaceID: sourceWorkspaceID,
            shop: sourceShop, lineID: lineID, request: request, selectedOfferID: offerID, at: reviewedAt, source: source, bindings: bindings, stockEvidence: stockEvidence, canonicalStockEvidence: canonicalStockEvidence)
        if let inventoryOrigin = canonicalStockEvidence?.basis.originID ?? grossBasis?.originID {
            guard let pickup else { throw LedgerPackError.staleSource }
            let port = try pickup.makePantryPackSelectionPort()
            return try await ledger.savePantryPack(.init(inventoryWorkspaceID: inventoryOrigin,
                ledgerWorkspaceID: sourceWorkspaceID, selection: selection, reviewedLedgerRevision: workspaceRevision,
                grossBasis: grossBasis), using: port)
        }
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave, ledger.sourceWorkspaceID == sourceWorkspaceID else { throw LedgerPackError.staleSource }
        // Exact retained body is a completed operation, even if current stock has
        // since changed. A different offer/body under this ID remains a conflict.
        if let existing = ledger.workspace.packSelections.first(where: { $0.id == operationID }) {
            guard existing == selection else { throw LedgerPackError.operationConflict }
            return true
        }
        if let pickup { guard pickup.ready, !pickup.saving, !pickup.hasPendingSave else { throw LedgerPackError.staleSource } }
        guard pickup?.pantryIsActive != true else { throw LedgerPackError.staleSource }
        if stockEvidence != nil {
            _ = try LedgerPackStockReview.currentEvidence(for: selection, shop: sourceShop,
                journey: pickup?.journeys.first { $0.id == sourceShop.id }, pickupWorkspaceID: pickup?.sourceWorkspaceID, bindings: bindings)
        } else if pickup?.journeys.first(where: { $0.id == sourceShop.id })?.stockLots.contains(where: {
            $0.foodID == lineID && ($0.source == .pantry || $0.source == .freezer)
        }) == true { throw LedgerPackError.staleSource }
        guard ledger.revision == workspaceRevision,
              ledger.workspace.shops.first(where: { $0.id == sourceShop.id }) == sourceShop else { throw LedgerPackError.staleSource }
        return await ledger.change(key: "pack-selection-\(operationID.uuidString)") { workspace in
            _ = try workspace.recordPackSelection(selection, workspaceID: sourceWorkspaceID, currentStockEvidence: stockEvidence)
        }
    }
}
