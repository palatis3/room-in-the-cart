import Foundation
import CoreDomain
import CryptoKit

/// Private-only evidence. The widget receives no recipe, food or journey identifiers.
struct TonightHomeBasis: Codable, Equatable {
    let ledger: UUID
    let ledgerRevision: Int64
    let stockDigest: Data
    init(ledger: UUID, revision: Int64, stock: LedgerCanonicalPackStockEvidence.Basis) throws {
        self.ledger = ledger; self.ledgerRevision = revision
        let canonical = LedgerCanonicalPackStockEvidence.Basis(originID: stock.originID,
            inventoryRevision: stock.inventoryRevision,
            sourceHeads: stock.sourceHeads.sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        stockDigest = Data(SHA256.hash(data: try encoder.encode(canonical)))
    }
    @MainActor static func current(ledger: LedgerModel, pickup: PickupModel) throws -> Self {
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave, !ledger.hasPendingLedgerDeletion,
              let origin = ledger.sourceWorkspaceID, let context = try pickup.pantryReviewContext() else {
            throw TonightMealModel.Failure.unavailable
        }
        let live = try PantryLiveStockProjection.buildGlobal(snapshot: context.snapshot, mapping: context.mapping, at: context.asOf)
        let stock = LedgerCanonicalPackStockEvidence.Basis(originID: live.basis.originID, inventoryRevision: live.basis.inventoryRevision,
            sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) })
        return try Self(ledger: origin, revision: ledger.revision, stock: stock)
    }
}
