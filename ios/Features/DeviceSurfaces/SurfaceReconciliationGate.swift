import Foundation
import DeviceSurfaces

/// A ready model is a complete source snapshot. Pending/uncertain saves and ledger
/// retirement are handled by their own recovery flows, never inferred as orphaning.
struct SurfaceSourceSnapshot: Equatable {
    let ledgerReady: Bool
    let pickupReady: Bool
    let ledgerSaving: Bool
    let pickupSaving: Bool
    let ledgerHasPendingSave: Bool
    let pickupHasPendingSave: Bool
    let ledgerHasPendingDeletion: Bool
    let ledgerWorkspaceID: UUID?
    let ledgerRevision: Int64
    let pickupRevisions: [UUID: Int64]
    var permitsReconciliation: Bool {
        ledgerReady && pickupReady && !ledgerSaving && !pickupSaving && !ledgerHasPendingSave
            && !pickupHasPendingSave && !ledgerHasPendingDeletion && ledgerWorkspaceID != nil
    }
}
struct SurfaceReconciliationGate {
    let expected: SurfaceSourceSnapshot
    func requireCurrent(_ current: SurfaceSourceSnapshot) throws {
        guard expected.permitsReconciliation, current.permitsReconciliation, current == expected else { throw SurfaceError.stale }
    }
}
