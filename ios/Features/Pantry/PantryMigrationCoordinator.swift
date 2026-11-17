import Foundation
import CoreDomain
import LocalStore

/// Composition shares this gate with every app-owned writer of the paired stores.
/// It is not an authorization grant or a substitute for SQLite revision checks.
@MainActor final class PantryMutationGate {
    enum Failure: Error, Equatable { case busy }
    private var writes: Set<UUID> = []
    private var migration: UUID?
    private var exclusiveWrite: UUID?

    func beginWrite() throws -> UUID {
        guard migration == nil, exclusiveWrite == nil else { throw Failure.busy }
        let id = UUID(); writes.insert(id); return id
    }
    func endWrite(_ id: UUID) { writes.remove(id) }
    func beginExclusiveWrite() throws -> UUID {
        guard migration == nil, exclusiveWrite == nil, writes.isEmpty else { throw Failure.busy }
        let id = UUID(); exclusiveWrite = id; return id
    }
    func endExclusiveWrite(_ id: UUID) { if exclusiveWrite == id { exclusiveWrite = nil } }
    func beginMigration() throws -> UUID {
        guard migration == nil, exclusiveWrite == nil, writes.isEmpty else { throw Failure.busy }
        let id = UUID(); migration = id; return id
    }
    func endMigration(_ id: UUID) { if migration == id { migration = nil } }
}

/// Coordinates a reviewed private cutover. Production composition must first route
/// ALL paired-store writers through gate and install the canonical read/write adapters.
/// Constructing this component never activates an existing workspace.
@MainActor final class PantryMigrationCoordinator {
    enum Failure: Error, Equatable {
        case unauthorized, alreadyActive, invalidReview, staleLedger, sourceChanged, noPendingMigration
    }
    struct Review {
        let sourceCount: Int
        let lotCount: Int
        let reservationCount: Int
        let issues: [PantryLegacyMigration.Issue]
        let package: PantryMigrationPackage.Package
    }
    struct Result {
        let receipt: LocalStore.InventoryOperationReceipt
        let state: InventoryState
        let replayed: Bool
    }
    private struct LedgerSnapshot {
        let origin: UUID
        let revision: Int64
        let workspace: LedgerWorkspace
        var context: PantryLegacyMigration.LedgerContext {
            .available(originID: origin, revision: revision, workspace: workspace)
        }
    }
    private let store: ComparisonStore
    private let ledger: LedgerStore
    private let gate: PantryMutationGate
    private let authorize: () -> Bool
    private let clock: () -> Date

    init(store: ComparisonStore, ledger: LedgerStore, gate: PantryMutationGate,
         authorize: @escaping () -> Bool, clock: @escaping () -> Date = Date.init) {
        self.store = store; self.ledger = ledger; self.gate = gate
        self.authorize = authorize; self.clock = clock
    }

    func prepare() async throws -> Review {
        try requireAccess()
        let lease = try gate.beginMigration(); defer { gate.endMigration(lease) }
        let state = try await store.inventoryState()
        try requireAccess()
        guard !state.active else { throw Failure.alreadyActive }
        guard try await store.inventoryPendingMigration() == nil else { throw Failure.invalidReview }
        let snapshot = try await ledgerSnapshot()
        // This token is captured BEFORE source enumeration and is never refreshed
        // for the old mapped plan. Every page is read against this exact token.
        let token = try await store.inventorySourceToken()
        let preparedAt = clock()
        let review = try await rebuild(token: token, inventoryRevision: state.revision,
            migrationID: UUID(), snapshot: snapshot, preparedAt: preparedAt)
        try await requireLedger(origin: snapshot.origin, revision: snapshot.revision)
        try requireAccess()
        return review
    }

    func apply(_ review: Review) async throws -> Result {
        try requireAccess()
        let lease = try gate.beginMigration(); defer { gate.endMigration(lease) }
        return try await activate(review.package)
    }

    /// A staging plan exists only after the user began applying a reviewed migration.
    /// Rebuild from its original token/time/context, then require an identical manifest.
    func resume() async throws -> Result {
        try requireAccess()
        let lease = try gate.beginMigration(); defer { gate.endMigration(lease) }
        guard let progress = try await store.inventoryPendingMigration(), let original = progress.plan else {
            throw Failure.noPendingMigration
        }
        let context = try decodeContext(original)
        let snapshot = try await ledgerSnapshot()
        guard snapshot.origin == context.ledgerOriginID, snapshot.revision == context.ledgerRevision else { throw Failure.staleLedger }
        let rebuilt = try await rebuild(token: original.sourceToken, inventoryRevision: original.expectedRevision,
            migrationID: original.migrationID, snapshot: snapshot, preparedAt: context.preparedAt)
        guard rebuilt.package.plan == original else { throw Failure.invalidReview }
        return try await activate(rebuilt.package)
    }

    /// Cancellation removes only inactive staging, never canonical food or original sources.
    func cancelPending() async throws {
        try requireAccess()
        let lease = try gate.beginMigration(); defer { gate.endMigration(lease) }
        if let pending = try await store.inventoryPendingMigration() {
            try requireAccess()
            _ = try await store.cancelInventoryMigration(id: pending.migrationID)
            try requireAccess()
        }
    }

    private func rebuild(token: InventorySourceToken, inventoryRevision: Int64, migrationID: UUID,
                         snapshot: LedgerSnapshot, preparedAt: Date) async throws -> Review {
        guard token.workspaceID == store.workspaceID else { throw Failure.invalidReview }
        var sources: [SavedComparison] = [], cursor: UUID?, bytes = 0
        while true {
            let page = try await store.inventorySourcePage(token: token, after: cursor, limit: InventoryPersistenceLimits.pageItems)
            try requireAccess()
            bytes += page.reduce(0) { $0 + $1.payload.count }
            guard sources.count + page.count <= PantryLegacyMigration.maximumHeads,
                  bytes <= PantryLegacyMigration.maximumSourceBytes else { throw PantryLegacyMigration.Failure.capacity }
            sources.append(contentsOf: page)
            guard page.count == InventoryPersistenceLimits.pageItems else { break }
            cursor = page.last?.id
        }
        let mapped = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: sources.map(PantryLegacyMigration.SourceHead.init), ledger: snapshot.context, at: preparedAt)
        let package = try PantryMigrationPackage.build(mapped, migrationID: migrationID, sourceToken: token,
            inventoryRevision: inventoryRevision, at: preparedAt)
        return Review(sourceCount: sources.count, lotCount: mapped.lots.count,
            reservationCount: mapped.reservations.count, issues: mapped.issues, package: package)
    }

    private func activate(_ package: PantryMigrationPackage.Package) async throws -> Result {
        let plan = package.plan, context = try decodeContext(package.plan)
        guard plan.workspaceID == store.workspaceID else { throw Failure.invalidReview }
        try requireAccess()
        if let previous = try await store.inventoryMigrationProgress(id: plan.migrationID), previous.status == .active {
            // begin verifies the complete original plan identity even after activation.
            let exact = try await store.beginInventoryMigration(plan)
            guard let receipt = exact.receipt else { throw Failure.invalidReview }
            try requireAccess()
            let state = try await store.inventoryState()
            try requireAccess()
            return Result(receipt: receipt, state: state, replayed: true)
        }
        let startingAt = clock()
        guard startingAt.timeIntervalSinceReferenceDate.isFinite, context.preparedAt <= startingAt else { throw Failure.invalidReview }
        try await requireLedger(origin: context.ledgerOriginID, revision: context.ledgerRevision)
        guard try await store.inventorySourceToken() == plan.sourceToken else { throw Failure.sourceChanged }
        try requireAccess()
        let progress = try await store.beginInventoryMigration(plan)
        guard progress.status == .staging else { throw Failure.invalidReview }
        for chunk in package.chunks.dropFirst(progress.nextChunk) {
            try requireAccess()
            _ = try await store.stageInventoryMigration(id: plan.migrationID, chunk: chunk)
        }
        // The same app-level lease is held throughout staging and final validation.
        // SQLite independently checks the complete source generation at final COMMIT.
        try await requireLedger(origin: context.ledgerOriginID, revision: context.ledgerRevision)
        try requireAccess()
        let committedAt = clock()
        guard committedAt.timeIntervalSinceReferenceDate.isFinite, committedAt >= context.preparedAt else { throw Failure.invalidReview }
        let receipt = try await store.finishInventoryMigration(id: plan.migrationID, at: committedAt)
        try requireAccess()
        let state = try await store.inventoryState()
        try requireAccess()
        return Result(receipt: receipt, state: state, replayed: false)
    }

    private func ledgerSnapshot() async throws -> LedgerSnapshot {
        try requireAccess()
        let record = try await ledger.load()
        try requireAccess()
        let workspace = try record.map { try LedgerModel.validatePayload($0.payload) } ?? LedgerWorkspace()
        return LedgerSnapshot(origin: ledger.workspaceID, revision: record?.revision ?? 0, workspace: workspace)
    }
    private func requireLedger(origin: UUID?, revision: Int64?) async throws {
        let current = try await ledgerSnapshot()
        guard current.origin == origin, current.revision == revision else { throw Failure.staleLedger }
    }
    private func decodeContext(_ plan: InventoryMigrationPlan) throws -> PantryMigrationPackage.Context {
        let context = try JSONDecoder().decode(PantryMigrationPackage.Context.self, from: plan.reviewContext)
        guard context.mapperVersion == 1, context.sourceToken == plan.sourceToken,
              context.ledgerOriginID != nil, context.ledgerRevision.map({ $0 >= 0 }) == true,
              context.preparedAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidReview }
        return context
    }
    private func requireAccess() throws { guard authorize() else { throw Failure.unauthorized } }
}
