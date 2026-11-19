import Combine
import Foundation
import LocalStore
import RecordArchive

/// Owns the displayed independent pantry and its store until Close succeeds.
/// The parent retains failed/closing sessions too, so cleanup cannot outlive an
/// unclosed SQLite actor or a late opening task.
@MainActor final class RecordsPantrySession: ObservableObject, Identifiable {
    enum Phase: Equatable { case idle, opening, ready, failed, closing, closeFailed, closed }
    let id: UUID
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var model: PantryModel?
    private(set) var copy: RecoveredPantryCopy
    private(set) var identity: PantryRecoveryCoordinator.Identity?
    private(set) var store: ComparisonStore?
    private(set) var pendingStore: PantryPendingStore?
    let gate: PantryMutationGate
    private let root: URL
    private let worker: PantryArchiveWorker
    private let registry: RecoveryRegistry
    private let lifetime: RecordsRecoveryLifetime
    private let authorize: RecordsToolsModel.Authorization
    private let protectedWorkspaceIDs: () -> Set<UUID>
    private let clock: () -> Date
    private var lease: RecordsRecoveryLifetime.Lease?
    private var acceptsAccess = true
    private var openingTask: Task<Void, Never>?
    private var closingTask: Task<Bool, Never>?
    private var captures = 0
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    init(copy: RecoveredPantryCopy, root: URL, worker: PantryArchiveWorker,
         registry: RecoveryRegistry, lifetime: RecordsRecoveryLifetime,
         gate: PantryMutationGate,
         protectedWorkspaceIDs: @escaping () -> Set<UUID>,
         authorize: @escaping RecordsToolsModel.Authorization, clock: @escaping () -> Date = Date.init) {
        id = copy.id; self.copy = copy; self.root = root; self.worker = worker
        self.registry = registry; self.lifetime = lifetime; self.gate = gate
        self.protectedWorkspaceIDs = protectedWorkspaceIDs; self.authorize = authorize; self.clock = clock
    }

    var hasAccess: Bool { acceptsAccess && authorize() && (lease?.authorize() ?? false) }

    @discardableResult func open() async -> Bool {
        guard phase == .idle, openingTask == nil, acceptsAccess, authorize() else { return false }
        phase = .opening
        let work = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performOpen()
        }
        openingTask = work
        await work.value
        openingTask = nil
        return phase == .ready && hasAccess
    }

    private func performOpen() async {
        do {
            let original = copy
            let acquired = try await lifetime.begin(copy: original, registry: registry, authorize: { [weak self] in
                self.map { $0.acceptsAccess && $0.authorize() } ?? false
            })
            lease = acquired
            try requireAccess()
            let ticket = try await registry.beginPantryMaterialization(original)
            try requireAccess()
            let reference = PantryArchiveStorage.Reference(bundleID: original.reference.bundleID,
                manifestDigest: original.reference.manifestDigest)
            let coordinator = try PantryRecoveryCoordinator(root: root, worker: worker, gate: gate,
                protectedWorkspaceIDs: protectedWorkspaceIDs, authorize: { [weak self] id, proposed in
                    guard let self, id == original.id, proposed == reference, self.hasAccess else { return false }
                    try await self.lifetime.revalidate(acquired, copy: original, registry: self.registry)
                    return self.hasAccess
                })
            let opened: PantryRecoveryCoordinator.Opened
            if ticket.permitsCreation {
                opened = try await coordinator.create(copyID: original.id, reference: reference, at: clock())
            } else {
                opened = try await coordinator.open(copyID: original.id, reference: reference, at: clock())
            }
            // Retain immediately, including a result arriving after cancellation.
            store = opened.store; identity = opened.identity
            try requireAccess()
            if case .ready(let expected) = ticket.copy.materialization {
                guard expected == opened.store.workspaceID else { throw ArchiveError.invalidIdentity }
            }
            let ready = try await registry.finishPantryMaterialization(ticket.copy, workspaceID: opened.store.workspaceID)
            try requireAccess()
            try await lifetime.revalidate(acquired, copy: ready, registry: registry)
            try requireAccess()
            copy = ready
            let pending = try PantryPendingStore(directory: root.appendingPathComponent(id.uuidString, isDirectory: true)
                .appendingPathComponent("pending", isDirectory: true), inventoryWorkspaceID: opened.store.workspaceID)
            pendingStore = pending
            let source = opened.source, context = opened.identity
            let repository = PantryRepository(store: opened.store, mutationGate: gate, pendingStore: pending,
                archivedUsage: { [weak self] lot in
                    guard let self, self.phase == .ready, self.identity == context else { throw ArchiveError.unavailable }
                    try self.requireAccess()
                    try await self.lifetime.revalidate(acquired, copy: ready, registry: self.registry)
                    try self.requireAccess()
                    let rows = try await self.worker.archivedUsage(source, context: context, lot: lot)
                    try await self.lifetime.revalidate(acquired, copy: ready, registry: self.registry)
                    try self.requireAccess()
                    return rows
                },
                authorize: { [weak self] in self?.hasAccess == true })
            let model = PantryModel(repository: repository, clock: clock)
            self.model = model
            await model.load()
            try requireAccess()
            try await lifetime.revalidate(acquired, copy: ready, registry: registry)
            try requireAccess()
            phase = .ready
        } catch {
            model?.accessLost()
            if phase != .closing { phase = .failed }
        }
    }

    /// Revokes the editor synchronously. The owner then awaits close before
    /// finishing registry cleanup or dropping its last strong session reference.
    func invalidate() {
        acceptsAccess = false
        model?.accessLost()
        openingTask?.cancel()
    }

    /// Re-exports this independent copy's current edits with its original lineage.
    /// The display lease and shared gate remain authoritative throughout capture.
    func captureArchive(to output: PantryArchiveWorker? = nil) async throws -> PantryArchiveHandle {
        guard phase == .ready, let identity, let store, let pendingStore, let lease else { throw ArchiveError.unavailable }
        try requireAccess()
        captures += 1
        defer {
            captures -= 1
            if captures == 0 {
                let waiting = captureWaiters; captureWaiters = []
                waiting.forEach { $0.resume() }
            }
        }
        try await lifetime.revalidate(lease, copy: copy, registry: registry)
        try requireAccess()
        let source = try await worker.open(reference: identity.reference)
        try requireAccess()
        let result = try await PantryArchiveCapture.captureIndependent(worker: output ?? worker, inventory: store,
            original: source, identity: identity, journalDirectory: pendingStore.fileURL.deletingLastPathComponent(),
            gate: gate, at: clock(), authorize: { [weak self] in
                guard let self else { throw ArchiveError.unavailable }
                try self.requireAccess()
            })
        try requireAccess()
        try await lifetime.revalidate(lease, copy: copy, registry: registry)
        try requireAccess()
        return result
    }

    @discardableResult func close() async -> Bool {
        if phase == .closed { return true }
        if let closingTask { return await closingTask.value }
        invalidate(); phase = .closing
        let opening = openingTask
        let work = Task { [self] in
            await opening?.value
            if captures > 0 { await withCheckedContinuation { captureWaiters.append($0) } }
            await gate.waitUntilIdle()
            do {
                if let store { try await store.close() }
                store = nil; pendingStore = nil; model = nil
                if let lease { lifetime.finish(lease); self.lease = nil }
                phase = .closed
                return true
            } catch {
                // The lease remains active: drain must not authorize file removal.
                phase = .closeFailed
                return false
            }
        }
        closingTask = work
        let result = await work.value
        closingTask = nil
        return result
    }

    private func requireAccess() throws {
        try Task.checkCancellation()
        guard hasAccess else { throw ArchiveError.unavailable }
    }
}
