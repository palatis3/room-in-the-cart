import Foundation
import CryptoKit
import CoreDomain
import LocalStore

/// Atomic private source/canonical submission. Composition must give every paired
/// writer the same gate. The caller must durably retain Submission before applying;
/// this component neither owns a pending journal nor activates inventory.
@MainActor final class PantryPickupCommitPort {
    enum Failure: Error, Equatable { case unauthorized, invalidSubmission, staleSources, staleLedger, inconsistentSnapshot, capacity }
    struct Submission: Codable, Equatable {
        let version: Int
        let request: PantryPickupDelta.Request
        let changedHeads: [PantryLegacyMigration.SourceHead]
        let preparedAt: Date
    }
    struct Review {
        let submission: Submission
        let affectedReservations: [InventoryReservationCoverage]
        let sourceRevisions: [UUID: Int64]
    }
    struct Result {
        let receipt: LocalStore.InventoryOperationReceipt
        let current: PantryRepository.Snapshot
        let sources: [PantryLegacyMigration.SourceHead]
        let replayed: Bool
    }
    struct CurrentSnapshot {
        let inventory: PantryRepository.Snapshot
        let sources: [PantryLegacyMigration.SourceHead]
    }
    private struct HeadBinding: Codable {
        let id: UUID
        let revision: Int64
        let savedAt: Date
        let payloadDigest: Data
    }
    private struct Envelope: Codable {
        let namespace: String
        let version: Int
        let request: PantryPickupDelta.Request
        let changedHeadsDigest: Data
        let preparedAt: Date
    }
    private struct Current {
        let inventory: PantryRepository.Snapshot
        let token: InventorySourceToken
        let sources: [PantryLegacyMigration.SourceHead]
    }
    private struct LedgerSnapshot {
        let originID: UUID
        let revision: Int64
        let workspace: LedgerWorkspace
        var context: PantryLegacyMigration.LedgerContext {
            .available(originID: originID, revision: revision, workspace: workspace)
        }
    }
    private let store: ComparisonStore
    private let ledger: LedgerStore
    private let gate: PantryMutationGate
    private let repository: PantryRepository
    private let authorize: (UUID, UUID) -> Bool
    private let clock: () -> Date

    init(store: ComparisonStore, ledger: LedgerStore, gate: PantryMutationGate,
         readLimits: PantryRepository.ReadLimits = .standard,
         authorize: @escaping (UUID, UUID) -> Bool, clock: @escaping () -> Date = Date.init) {
        self.store = store; self.ledger = ledger; self.gate = gate; self.authorize = authorize; self.clock = clock
        // This port owns the exclusive lease; the repository must not nest one.
        repository = PantryRepository(store: store, limits: readLimits,
            authorize: { authorize(store.workspaceID, ledger.workspaceID) })
    }

    func prepare(operationID: UUID, changedHeads: [PantryLegacyMigration.SourceHead], preparedAt: Date) async throws -> Review {
        try requireAccess()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        try validateHeads(changedHeads, preparedAt: preparedAt)
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, preparedAt <= now else { throw Failure.invalidSubmission }
        let current = try await readCurrent(at: now), planning = try await readLedger()
        let proposed = try merge(changedHeads, into: current.sources)
        let delta = try PantryPickupDelta.prepare(operationID: operationID, originID: store.workspaceID,
            prior: current.sources, proposed: proposed, inventory: current.inventory, ledger: planning.context, at: preparedAt)
        let submission = Submission(version: 1, request: delta.request,
            changedHeads: delta.changedHeads.sorted { $0.id.uuidString < $1.id.uuidString }, preparedAt: preparedAt)
        let request = try envelope(submission)
        let batch = batch(delta, request: request)
        try validateBatchSize(batch)
        try repository.validateCapacity(of: batch.writes, replacing: current.inventory)
        try await requireLedger(planning)
        try await requireCurrent(current)
        return Review(submission: submission, affectedReservations: delta.affectedReservations,
            sourceRevisions: Dictionary(uniqueKeysWithValues: current.sources.map { ($0.id, $0.revision) }))
    }

    func loadCurrent() async throws -> CurrentSnapshot {
        try requireAccess()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let current = try await readCurrent(at: clock())
        return CurrentSnapshot(inventory: current.inventory, sources: current.sources)
    }

    /// Read-only recognition also works when an action-specific grant has expired.
    /// The supplied authorization still must permit reading this private workspace.
    func recover(_ submission: Submission) async throws -> Result? {
        try requireAccess()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        return try await recognized(submission)
    }

    /// The caller removes its exact pending file while this lease still excludes
    /// writers. Every resumed writer must reauthorize against that file; it must
    /// never recreate a missing journal just to retry a cached submission.
    func reconcileForDiscard(_ submission: Submission, whenUnapplied: () throws -> Void) async throws -> Result? {
        try requireAccess()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        if let result = try await recognized(submission) { return result }
        try requireAccess()
        try whenUnapplied()
        return nil
    }

    private func recognized(_ submission: Submission) async throws -> Result? {
        let request = try envelope(submission)
        let receipt = try await store.inventoryCommittedOperation(id: submission.request.operationID, request: request)
        try requireAccess()
        guard let receipt else { return nil }
        let current = try await readCurrent(at: clock())
        return Result(receipt: receipt, current: current.inventory, sources: current.sources, replayed: true)
    }

    func apply(_ submission: Submission) async throws -> Result {
        try requireAccess()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        // Bind the exact changed bytes even on replay, without consulting a new
        // source set, ledger base, or preparation clock first.
        let request = try envelope(submission)
        if let receipt = try await store.inventoryCommittedOperation(id: submission.request.operationID, request: request) {
            try requireAccess()
            let current = try await readCurrent(at: clock())
            return Result(receipt: receipt, current: current.inventory, sources: current.sources, replayed: true)
        }
        try requireAccess()
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, submission.preparedAt <= now else { throw Failure.invalidSubmission }
        let current = try await readCurrent(at: now)
        guard current.inventory.state.revision == submission.request.inventoryRevision else { throw ComparisonStoreError.staleInventory }
        let planning = try await readLedger()
        guard planning.originID == submission.request.ledgerOriginID,
              planning.revision == submission.request.ledgerRevision else { throw Failure.staleLedger }
        let proposed = try merge(submission.changedHeads, into: current.sources)
        let rebuiltRequest = try PantryPickupDelta.request(operationID: submission.request.operationID, originID: store.workspaceID,
            inventoryRevision: current.inventory.state.revision, prior: current.sources, proposed: proposed, ledger: planning.context)
        guard rebuiltRequest.ledgerDigest == submission.request.ledgerDigest else { throw Failure.staleLedger }
        guard rebuiltRequest == submission.request else { throw Failure.staleSources }
        let delta = try PantryPickupDelta.prepare(operationID: submission.request.operationID, originID: store.workspaceID,
            prior: current.sources, proposed: proposed, inventory: current.inventory, ledger: planning.context, at: submission.preparedAt)
        guard delta.request == submission.request else { throw Failure.invalidSubmission }
        let batch = batch(delta, request: request)
        try validateBatchSize(batch)
        try repository.validateCapacity(of: batch.writes, replacing: current.inventory)
        try await requireLedger(planning)
        try await requireCurrent(current)
        try requireAccess()
        let receipt = try await store.commitInventory(batch, at: submission.preparedAt)
        try requireAccess()
        let after = try await readCurrent(at: now)
        return Result(receipt: receipt, current: after.inventory, sources: after.sources, replayed: false)
    }

    private func readCurrent(at now: Date) async throws -> Current {
        try requireAccess()
        let inventory = try await repository.load(at: now)
        try requireAccess()
        let token = try await store.inventorySourceToken()
        try requireAccess()
        var sources: [PantryLegacyMigration.SourceHead] = [], cursor: UUID?, bytes = 0
        while true {
            let page = try await store.inventorySourcePage(token: token, after: cursor, limit: InventoryPersistenceLimits.pageItems)
            try requireAccess()
            bytes += page.reduce(0) { $0 + $1.payload.count }
            guard sources.count + page.count <= PantryLegacyMigration.maximumHeads,
                  bytes <= PantryLegacyMigration.maximumSourceBytes else { throw Failure.capacity }
            sources += page.map(PantryLegacyMigration.SourceHead.init)
            if page.count < InventoryPersistenceLimits.pageItems { break }
            cursor = page.last?.id
        }
        let result = Current(inventory: inventory, token: token, sources: sources)
        try await requireCurrent(result)
        return result
    }
    private func requireCurrent(_ current: Current) async throws {
        let state = try await store.inventoryState()
        try requireAccess()
        let token = try await store.inventorySourceToken()
        try requireAccess()
        guard state == current.inventory.state, token == current.token else { throw Failure.inconsistentSnapshot }
    }
    private func readLedger() async throws -> LedgerSnapshot {
        try requireAccess()
        let record = try await ledger.load()
        try requireAccess()
        let workspace = try record.map { try LedgerModel.validatePayload($0.payload) } ?? LedgerWorkspace()
        return LedgerSnapshot(originID: ledger.workspaceID, revision: record?.revision ?? 0, workspace: workspace)
    }
    private func requireLedger(_ expected: LedgerSnapshot) async throws {
        let current = try await readLedger()
        guard current.originID == expected.originID, current.revision == expected.revision,
              current.workspace == expected.workspace else { throw Failure.staleLedger }
    }
    private func merge(_ changed: [PantryLegacyMigration.SourceHead], into current: [PantryLegacyMigration.SourceHead]) throws -> [PantryLegacyMigration.SourceHead] {
        var values = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for head in changed { values[head.id] = head }
        guard values.count <= PantryLegacyMigration.maximumHeads,
              values.values.reduce(0, { $0 + $1.payload.count }) <= PantryLegacyMigration.maximumSourceBytes else { throw Failure.capacity }
        return values.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func envelope(_ submission: Submission) throws -> Data {
        let request = submission.request
        guard submission.version == 1, request.version == 1, request.originID == store.workspaceID,
              request.inventoryRevision >= 0, request.priorDigest.count == 32, request.proposedDigest.count == 32,
              request.ledgerOriginID != nil, request.ledgerRevision.map({ $0 >= 0 }) == true,
              request.ledgerDigest?.count == 32 else { throw Failure.invalidSubmission }
        try validateHeads(submission.changedHeads, preparedAt: submission.preparedAt)
        guard try encode(submission).count <= InventoryPersistenceLimits.batchBytes else { throw Failure.capacity }
        let heads = submission.changedHeads.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            HeadBinding(id: $0.id, revision: $0.revision, savedAt: $0.savedAt, payloadDigest: Self.digest($0.payload))
        }
        let bytes = try encode(Envelope(namespace: "pantry-pickup-submission/v1", version: 1, request: request,
            changedHeadsDigest: Self.digest(try encode(heads)), preparedAt: submission.preparedAt))
        guard bytes.count <= InventoryPersistenceLimits.requestBytes else { throw Failure.capacity }
        return bytes
    }
    private func validateHeads(_ heads: [PantryLegacyMigration.SourceHead], preparedAt: Date) throws {
        guard preparedAt.timeIntervalSinceReferenceDate.isFinite, !heads.isEmpty,
              heads.count <= InventoryPersistenceLimits.batchItems, Set(heads.map(\.id)).count == heads.count,
              heads.allSatisfy({ $0.revision > 0 && $0.savedAt == preparedAt && !$0.payload.isEmpty && $0.payload.count <= ComparisonStore.maximumPayloadBytes }) else { throw Failure.invalidSubmission }
        guard heads.reduce(0, { $0 + $1.payload.count }) <= InventoryPersistenceLimits.batchBytes else { throw Failure.capacity }
    }
    private func batch(_ delta: PantryPickupDelta.Review, request: Data) -> InventoryBatch {
        InventoryBatch(workspaceID: store.workspaceID, operationID: delta.request.operationID,
            expectedRevision: delta.request.inventoryRevision, request: request, writes: delta.batch.writes,
            comparisons: delta.batch.comparisons)
    }
    private func validateBatchSize(_ batch: InventoryBatch) throws {
        guard batch.writes.count + batch.comparisons.count <= InventoryPersistenceLimits.batchItems,
              try encode(batch).count <= InventoryPersistenceLimits.batchBytes else { throw Failure.capacity }
    }
    private func requireAccess() throws {
        guard authorize(store.workspaceID, ledger.workspaceID) else { throw Failure.unauthorized }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest(_ value: Data) -> Data { Data(SHA256.hash(data: value)) }
}
