import Foundation

/// Snapshot and compare-before-removal prevent delayed cleanup from deleting
/// commands appended by a later session, even in the same household and shop.
public protocol SharedTrackingOutbox: Sendable {
    func operations() async throws -> [PendingOperation]
    func append(_ operation: PendingOperation) async throws
    func remove(_ id: String) async throws
    func removeIfUnchanged(_ expected: [PendingOperation]) async throws
}
extension OperationOutbox: SharedTrackingOutbox {}

/// Internal provenance for a tracking request's authenticated session. Never
/// serialized, exposed as authority, or reconstructed from a generation change.
struct SharedTrackingTransportLease: Sendable {
    let generation: UUID
    let context: SharedDemandContext
    let shopID: UUID
}
/// Created only when perform receives an access/session denial while the
/// original lease is current and synchronously clears that exact session.
struct SharedTrackingAccessInvalidated: Error, Sendable {
    let lease: SharedTrackingTransportLease
    let clearedGeneration: UUID
    let underlying: ClientError
}
