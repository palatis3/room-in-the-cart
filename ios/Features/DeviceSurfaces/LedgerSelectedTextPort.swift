import Foundation
import CoreDomain
import DeviceSurfaces

/// Uses the same durable LedgerModel transaction and stored import receipt as typed entry.
@MainActor final class LedgerSelectedTextPort: SurfaceLedgerPort {
    private let ledger: LedgerModel
    private let currentScope: () -> SurfaceImportScope?
    private let currentGeneration: () -> UUID?
    init(ledger: LedgerModel, scope: @escaping () -> SurfaceImportScope?, generation: @escaping () -> UUID?) {
        self.ledger = ledger; currentScope = scope; currentGeneration = generation
    }
    var scope: SurfaceImportScope? {
        guard ledger.ready, !ledger.hasPendingLedgerDeletion, let scope = currentScope(), scope.workspaceID == ledger.sourceWorkspaceID else { return nil }
        return scope
    }
    var generation: UUID? { currentGeneration() }
    var hasPendingSave: Bool { ledger.hasPendingSave }
    func shop(_ id: UUID) -> ShoppingLedger? { scope == nil ? nil : ledger.workspace.shops.first { $0.id == id } }
    func stage(_ entry: SelectedTextEntry, shopID: UUID) throws -> StagedListImport {
        guard let shop = shop(shopID) else { throw SurfaceError.unavailable }
        return try shop.stageImport(text: entry.textForReview, source: .selectedText, importID: entry.id,
                                    maximumLines: SelectedTextInbox.maximumLines)
    }
    func reload() async throws {
        guard let scope = scope, let start = generation else { throw SurfaceError.unavailable }
        await ledger.discardPendingSave()
        guard self.scope == scope, generation == start, !ledger.hasPendingSave else { throw SurfaceError.unavailable }
    }
    func commit(_ draft: SurfaceImportDraft) async throws {
        guard scope == draft.scope, let start = generation, !ledger.hasPendingSave else { throw SurfaceError.stale }
        let saved = await ledger.editShop(key: "surface-import-" + draft.id.uuidString, shopID: draft.preview.shopID) { try $0.commitImport(draft.preview, decisions: draft.decisions) }
        guard saved, scope == draft.scope, generation == start else { throw SurfaceError.unavailable }
    }
}
