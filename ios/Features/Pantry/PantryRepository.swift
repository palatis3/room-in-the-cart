import Foundation
import CoreDomain
import LocalStore

/// Private pantry access only. Composition supplies current workspace/persona authorization;
/// knowing a database UUID is never authorization. Migration activation is a separate operation.
@MainActor
final class PantryRepository {
    enum Failure: Error, Equatable {
        case inactive, unauthorized, wrongWorkspace, inconsistentSnapshot, invalidProvenance
    }

    struct ReadLimits {
        let payloadBytes: Int
        let observations: Int
        static let standard = ReadLimits(payloadBytes: 32 * 1_024 * 1_024, observations: 100_000)
    }

    struct Snapshot {
        let state: InventoryState
        let lots: [InventoryLot]
        let reservations: [InventoryReservation]
        let availability: InventoryProjection
        let loadedPayloadBytes: Int
        fileprivate let observationCount: Int
        fileprivate let lotPayloadBytes: [UUID: Int]
        fileprivate let reservationPayloadBytes: [UUID: Int]
    }

    struct Review {
        let command: InventoryCommand
        let before: Snapshot
        let proposedLot: InventoryLot
        let proposedAvailability: InventoryProjection

        /// Includes newly unresolved or shortfall-backed commitments, not just numeric changes.
        var affectedReservations: [InventoryReservationCoverage] {
            let previous = Dictionary(uniqueKeysWithValues: before.availability.reservations.map { ($0.id, $0) })
            return proposedAvailability.reservations.filter { previous[$0.id] != $0 }
        }
    }

    struct Result {
        let receipt: LocalStore.InventoryOperationReceipt
        let current: Snapshot
        let replayed: Bool
    }

    private let store: ComparisonStore
    private let authorize: () -> Bool
    private let limits: ReadLimits
    private let mutationGate: PantryMutationGate?

    init(store: ComparisonStore, limits: ReadLimits = .standard, mutationGate: PantryMutationGate? = nil,
         authorize: @escaping () -> Bool) {
        self.store = store
        self.authorize = authorize
        self.limits = limits
        self.mutationGate = mutationGate
    }

    /// Read every live claim, including other shops. Never publish partially read pages.
    func load(at now: Date) async throws -> Snapshot {
        try requireAccess()
        let initial = try await store.inventoryState()
        try requireAccess()
        guard initial.active else { throw Failure.inactive }
        // Bound the complete read and fetch history in pages, rather than doing
        // two actor/database round trips per lot. Capacity failure publishes no stock.
        var remainingBytes = limits.payloadBytes
        let lotRows = try await records(.lot, maximum: InventoryProjection.maximumLots, maximumBytes: remainingBytes)
        remainingBytes -= lotRows.reduce(0) { $0 + $1.payload.count }
        let claimRows = try await records(.reservation, maximum: InventoryProjection.maximumReservations, maximumBytes: remainingBytes)
        remainingBytes -= claimRows.reduce(0) { $0 + $1.payload.count }
        let sourceRows = try await records(.sourceLink, maximum: InventoryProjection.maximumLots, maximumBytes: remainingBytes)
        remainingBytes -= sourceRows.reduce(0) { $0 + $1.payload.count }
        let observationRows = try await records(.observation, maximum: limits.observations, maximumBytes: remainingBytes)
        let final = try await store.inventoryState()
        try requireAccess()
        guard initial == final else { throw Failure.inconsistentSnapshot }
        let lots = try lotRows.map(PantryPersistenceCodec.lot)
        let claims = try claimRows.map(PantryPersistenceCodec.reservation)
        let sourceLinks = try sourceRows.map(PantryPersistenceCodec.sourceLink)
        let observations = try observationRows.map(PantryPersistenceCodec.observation)
        let sources = Dictionary(uniqueKeysWithValues: sourceLinks.map { ($0.lotID, $0) })
        let histories = Dictionary(grouping: observations, by: \.lotID)
        let lotIDs = Set(lots.map(\.id))
        guard Set(sources.keys) == lotIDs, Set(histories.keys) == lotIDs else { throw Failure.invalidProvenance }
        for lot in lots {
            let history = (histories[lot.id] ?? []).sorted { $0.revision < $1.revision }
            var predecessor: InventoryObservation?
            for observation in history {
                guard observation.supersedesID == predecessor?.id,
                      observation.revision <= lot.revision,
                      predecessor.map({ $0.revision < observation.revision && $0.observedAt <= observation.observedAt }) ?? true else {
                    throw Failure.invalidProvenance
                }
                predecessor = observation
            }
            guard let latest = predecessor, latest.id == lot.observationID,
                  latest.count == lot.count, latest.observedAt == lot.confirmedAt,
                  sources[lot.id]?.source == lot.source else { throw Failure.invalidProvenance }
        }
        return Snapshot(state: final, lots: lots, reservations: claims,
            availability: try InventoryProjection.build(originID: final.workspaceID, lots: lots, reservations: claims, at: now),
            loadedPayloadBytes: limits.payloadBytes - remainingBytes + observationRows.reduce(0) { $0 + $1.payload.count },
            observationCount: observationRows.count,
            lotPayloadBytes: Dictionary(uniqueKeysWithValues: lotRows.map { ($0.key.id, $0.payload.count) }),
            reservationPayloadBytes: Dictionary(uniqueKeysWithValues: claimRows.map { ($0.key.id, $0.payload.count) }))
    }

    func review(_ command: InventoryCommand, at now: Date) async throws -> Review {
        try requireAccess()
        guard command.originID == store.workspaceID else { throw Failure.wrongWorkspace }
        let before = try await load(at: now)
        let prepared = try InventoryEngine.prepare(command, current: before.lots.first { $0.id == command.lotID }, at: now)
        let proposedLots = before.lots.filter { $0.id != command.lotID } + [prepared.lot]
        try validateCapacity(of: PantryPersistenceCodec.writes(prepared), replacing: before)
        return Review(command: command, before: before, proposedLot: prepared.lot,
            proposedAvailability: try InventoryProjection.build(originID: before.state.workspaceID,
                lots: proposedLots, reservations: before.reservations, at: now))
    }

    /// The original command and reviewed global revision are the durable retry input.
    /// A stale review is never silently rebased. A successful old receipt reloads today's
    /// heads rather than restoring the old proposed count over intervening changes.
    func apply(_ command: InventoryCommand, reviewedInventoryRevision: Int64, at now: Date) async throws -> Result {
        try requireAccess()
        let lease = try mutationGate?.beginWrite()
        defer { if let lease { mutationGate?.endWrite(lease) } }
        guard command.originID == store.workspaceID else { throw Failure.wrongWorkspace }
        let request = try PantryPersistenceCodec.request(command, inventoryRevision: reviewedInventoryRevision)
        if let prior = try await store.inventoryCommittedOperation(id: command.id, request: request) {
            try requireAccess()
            return Result(receipt: prior, current: try await load(at: now), replayed: true)
        }
        let current = try await load(at: now)
        guard current.state.revision == reviewedInventoryRevision else { throw ComparisonStoreError.staleInventory }
        let prepared = try InventoryEngine.prepare(command, current: current.lots.first { $0.id == command.lotID }, at: now)
        // Validate the complete resulting physical/claim graph before writing, even
        // when this caller resumed a saved command instead of keeping an in-memory review.
        _ = try InventoryProjection.build(originID: current.state.workspaceID,
            lots: current.lots.filter { $0.id != command.lotID } + [prepared.lot],
            reservations: current.reservations, at: now)
        let writes = try PantryPersistenceCodec.writes(prepared)
        try validateCapacity(of: writes, replacing: current)
        let batch = InventoryBatch(workspaceID: current.state.workspaceID, operationID: command.id,
            expectedRevision: reviewedInventoryRevision, request: request, writes: writes)
        try requireAccess()
        let receipt = try await store.commitInventory(batch, at: now)
        try requireAccess()
        return Result(receipt: receipt, current: try await load(at: now), replayed: false)
    }

    /// Shared by single-food edits and atomic shopping deltas. Call after validating
    /// the proposed graph and before committing against this exact global revision.
    /// Observation/source rows are append-only; mutable heads replace their old bytes.
    func validateCapacity(of writes: [InventoryWrite], replacing snapshot: Snapshot) throws {
        try requireAccess()
        guard snapshot.state.workspaceID == store.workspaceID else { throw Failure.wrongWorkspace }
        var seen = Set<InventoryRecordKey>()
        var bytes = snapshot.loadedPayloadBytes
        var observations = snapshot.observationCount
        var lots = snapshot.lots.count
        var reservations = snapshot.reservations.count
        for write in writes {
            let record = write.record
            guard seen.insert(record.key).inserted else { throw InventoryError.duplicateIdentity }
            switch record.key.kind {
            case .lot:
                let old = snapshot.lotPayloadBytes[record.key.id]
                bytes += record.payload.count - (old ?? 0)
                if old == nil { lots += 1 }
            case .reservation:
                let old = snapshot.reservationPayloadBytes[record.key.id]
                bytes += record.payload.count - (old ?? 0)
                if old == nil { reservations += 1 }
            case .observation:
                guard write.expectedRevision == 0 else { throw Failure.invalidProvenance }
                observations += 1
                bytes += record.payload.count
            case .sourceLink:
                guard write.expectedRevision == 0 else { throw Failure.invalidProvenance }
                bytes += record.payload.count
            case .event, .intent: break
            }
        }
        guard observations <= limits.observations, bytes <= limits.payloadBytes,
              lots <= InventoryProjection.maximumLots,
              reservations <= InventoryProjection.maximumReservations else { throw InventoryError.capacity }
    }

    private func records(_ kind: InventoryRecordKind, maximum: Int, maximumBytes: Int) async throws -> [InventoryRecord] {
        var result: [InventoryRecord] = []
        var cursor: UUID?
        var bytes = 0
        while true {
            let page = try await store.inventoryRecords(kind: kind, after: cursor, limit: InventoryPersistenceLimits.pageItems)
            try requireAccess()
            bytes += page.reduce(0) { $0 + $1.payload.count }
            guard result.count + page.count <= maximum, bytes <= maximumBytes else { throw InventoryError.capacity }
            result.append(contentsOf: page)
            guard page.count == InventoryPersistenceLimits.pageItems else { return result }
            cursor = page.last?.key.id
        }
    }

    private func requireAccess() throws {
        guard authorize() else { throw Failure.unauthorized }
        guard (1...ReadLimits.standard.payloadBytes).contains(limits.payloadBytes),
              (1...ReadLimits.standard.observations).contains(limits.observations) else {
            throw InventoryError.invalid("readLimits")
        }
    }
}
