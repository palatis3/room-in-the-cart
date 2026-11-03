import Foundation
import CoreDomain

struct LedgerPackReview {
    let operationID: UUID
    let sourceWorkspaceID: UUID
    let workspaceRevision: Int64
    let sourceShop: ShoppingLedger
    let lineID: UUID
    let requirement: LedgerPackRequirement
    let request: ComparisonRequest
    let result: CoreDomain.ComparisonResult
    let reviewedAt: Date
    let source: String

    @MainActor static func prepare(ledger: LedgerModel, shopID: UUID, lineID: UUID,
                                  offerA: PackOffer, offerB: PackOffer, itemCap: Money?,
                                  at: Date, source: String) throws -> LedgerPackReview {
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave,
              let workspaceID = ledger.sourceWorkspaceID,
              let shop = ledger.workspace.shops.first(where: { $0.id == shopID }) else { throw LedgerPackError.staleSource }
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: lineID)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
            protectedAmount: requirement.protectedQuantity, offerA: offerA, offerB: offerB, itemCap: itemCap)
        return LedgerPackReview(operationID: UUID(), sourceWorkspaceID: workspaceID, workspaceRevision: ledger.revision,
            sourceShop: shop, lineID: lineID, requirement: requirement, request: request,
            result: try PackComparison.evaluate(request), reviewedAt: at, source: source)
    }

    @MainActor func save(offerID: String, ledger: LedgerModel) async throws -> Bool {
        let selection = try LedgerPackSelection(id: operationID, workspaceID: sourceWorkspaceID,
            shop: sourceShop, lineID: lineID, request: request, selectedOfferID: offerID, at: reviewedAt, source: source)
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave, ledger.sourceWorkspaceID == sourceWorkspaceID else { throw LedgerPackError.staleSource }
        if let existing = ledger.workspace.packSelections.first(where: { $0.id == operationID }) {
            guard existing == selection else { throw LedgerPackError.operationConflict }
            return true
        }
        guard ledger.revision == workspaceRevision,
              ledger.workspace.shops.first(where: { $0.id == sourceShop.id }) == sourceShop else { throw LedgerPackError.staleSource }
        return await ledger.change(key: "pack-selection-\(operationID.uuidString)") { workspace in
            _ = try workspace.recordPackSelection(selection, workspaceID: sourceWorkspaceID)
        }
    }
}
