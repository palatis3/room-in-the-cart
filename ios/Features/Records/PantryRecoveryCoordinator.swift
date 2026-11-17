import Foundation
import Darwin
import CoreDomain
import LocalStore
import RecordArchive

/// Opens only a locally bound independent copy. Registry membership/lifetime and
/// current private access remain the caller's authority; archive metadata grants none.
@MainActor final class PantryRecoveryCoordinator {
    enum Failure: Error, Equatable { case unauthorized, invalidLocation, invalidIdentity, missingIdentity, changedPlan, retired, invalidActivation, io }
    typealias Authorization = @MainActor (UUID, PantryArchiveStorage.Reference) async throws -> Bool
    struct Identity: Codable, Equatable {
        let version: Int
        let copyID: UUID
        let reference: PantryArchiveStorage.Reference
        let workspaceID: UUID
        let restorationID: UUID
        let preparedAt: Date
    }
    struct Opened {
        /// Caller owns closing this actor and binding subsequent operations to its recovery lease.
        let store: ComparisonStore
        let identity: Identity
        /// Immutable derived baseline/history, not the mutable current physical stock.
        let baseline: PantryArchiveCodec.Snapshot
        let original: PantryArchiveStorage.VerifiedBundle
        let current: PantryRepository.Snapshot
    }
    private struct Body: Codable, Equatable { let identity: Identity; let plan: InventoryMigrationPlan }
    private struct Manifest: Codable { let body: Body; let digest: Data }
    private struct Activation: Codable {
        let identityDigest: Data
        let receipt: LocalStore.InventoryOperationReceipt
    }
    static let manifestFilename = "pantry-recovery-v1.json"
    static let activationFilename = "pantry-activation-v1.json"
    static let databaseFilename = "pickup.sqlite"
    private static let maximumMetadataBytes = 16_384
    private let root: URL
    private let archives: PantryArchiveStorage
    private let gate: PantryMutationGate
    private let protectedWorkspaceIDs: () -> Set<UUID>
    private let authorize: Authorization

    init(root: URL, archives: PantryArchiveStorage, gate: PantryMutationGate,
         protectedWorkspaceIDs: @escaping () -> Set<UUID>, authorize: @escaping Authorization) throws {
        guard root.isFileURL else { throw Failure.invalidLocation }
        self.root = root.standardizedFileURL; self.archives = archives; self.gate = gate
        self.protectedWorkspaceIDs = protectedWorkspaceIDs; self.authorize = authorize
        try Self.directory(self.root, create: true)
    }

    /// Only the registry's durable first-materialization path may call create.
    /// Reopening a previously materialized copy MUST use open, including after files disappear.
    func create(copyID: UUID, reference: PantryArchiveStorage.Reference, at date: Date) async throws -> Opened {
        try await materialize(copyID: copyID, reference: reference, at: date, allowCreation: true)
    }
    func open(copyID: UUID, reference: PantryArchiveStorage.Reference, at date: Date) async throws -> Opened {
        try await materialize(copyID: copyID, reference: reference, at: date, allowCreation: false)
    }
    private func materialize(copyID: UUID, reference: PantryArchiveStorage.Reference, at date: Date,
                             allowCreation: Bool) async throws -> Opened {
        try await access(copyID, reference)
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        // Always reopen protected external history, never trust a cached VerifiedBundle.
        let original = try archives.open(reference)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidIdentity }
        let directory = root.appendingPathComponent(copyID.uuidString, isDirectory: true)
        if !Self.exists(directory) {
            guard allowCreation else { throw Failure.missingIdentity }
            try await provision(directory: directory, copyID: copyID, reference: reference,
                original: original, at: date)
        }
        try Self.directory(directory, create: false)
        let manifest = try Self.manifest(directory)
        try Self.protect(directory.appendingPathComponent(Self.manifestFilename), permissions: 0o600)
        let identity = manifest.body.identity
        guard identity.copyID == copyID, identity.reference == reference,
              !protectedWorkspaceIDs().contains(identity.workspaceID) else { throw Failure.invalidIdentity }
        let baseline = try PantryArchiveRestore.prepare(original.captured.snapshot, newOriginID: identity.workspaceID,
            restorationID: identity.restorationID, at: identity.preparedAt)
        let chunks = try Self.chunks(baseline)
        let rebuilt = try Self.plan(identity, sourceToken: manifest.body.plan.sourceToken, chunks: chunks)
        guard rebuilt == manifest.body.plan else { throw Failure.changedPlan }
        let url = directory.appendingPathComponent(Self.databaseFilename)
        try Self.requireDatabase(url)
        try await access(copyID, reference)
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        do {
            try Self.protectDatabase(url)
            guard store.workspaceID == identity.workspaceID,
                  !protectedWorkspaceIDs().contains(store.workspaceID) else { throw Failure.invalidIdentity }
            let state = try await store.inventoryState(); try await access(copyID, reference)
            let acknowledgmentURL = directory.appendingPathComponent(Self.activationFilename)
            if Self.exists(acknowledgmentURL) {
                let acknowledgment = try Self.activation(acknowledgmentURL, manifest: manifest)
                try Self.protect(acknowledgmentURL, permissions: 0o600)
                let durable = try await store.inventoryMigrationActivation(rebuilt)
                try await access(copyID, reference)
                guard state.active, state.revision >= acknowledgment.receipt.revision,
                      durable == acknowledgment.receipt else { throw Failure.invalidActivation }
            } else {
                let progress = try await store.beginInventoryMigration(rebuilt); try await access(copyID, reference)
                guard progress.status != .cancelled else { throw Failure.retired }
                if progress.status == .staging {
                    guard progress.plan == rebuilt, progress.nextChunk <= chunks.count else { throw Failure.changedPlan }
                    for chunk in chunks.dropFirst(progress.nextChunk) {
                        _ = try await store.stageInventoryMigration(id: identity.restorationID, chunk: chunk)
                        try await access(copyID, reference)
                    }
                }
                let receipt = try await store.finishInventoryMigration(id: identity.restorationID, at: identity.preparedAt)
                try await access(copyID, reference)
                try Self.validate(receipt, identity: identity)
                let acknowledgment = Activation(identityDigest: manifest.digest, receipt: receipt)
                try Self.write(ArchiveCodec.canonical(acknowledgment), to: acknowledgmentURL)
            }
            // These read-only awaits expose no state until the caller's async authority is checked again.
            let current = try await PantryRepository(store: store, authorize: { !Task.isCancelled }).load(at: max(date, identity.preparedAt))
            try await access(copyID, reference)
            guard current.state.workspaceID == identity.workspaceID else { throw Failure.invalidIdentity }
            try Self.protectDatabase(url)
            return Opened(store: store, identity: identity, baseline: baseline, original: original, current: current)
        } catch {
            try? await store.close()
            throw error
        }
    }

    private func provision(directory: URL, copyID: UUID, reference: PantryArchiveStorage.Reference,
                           original: PantryArchiveStorage.VerifiedBundle, at date: Date) async throws {
        guard date >= original.captured.snapshot.descriptor.capturedAt else { throw Failure.invalidIdentity }
        let temporary = root.appendingPathComponent("pantry-preparing-" + UUID().uuidString, isDirectory: true)
        try Self.directory(temporary, create: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent(Self.databaseFilename)
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        do {
            try Self.protectDatabase(url)
            guard !protectedWorkspaceIDs().contains(store.workspaceID) else { throw Failure.invalidIdentity }
            let identity = Identity(version: 1, copyID: copyID, reference: reference, workspaceID: store.workspaceID,
                restorationID: UUID(), preparedAt: date)
            let baseline = try PantryArchiveRestore.prepare(original.captured.snapshot, newOriginID: identity.workspaceID,
                restorationID: identity.restorationID, at: date)
            let token = try await store.inventorySourceToken(); try await access(copyID, reference)
            let plan = try Self.plan(identity, sourceToken: token, chunks: Self.chunks(baseline))
            let body = Body(identity: identity, plan: plan)
            let manifest = Manifest(body: body, digest: PantryArchiveCapture.digest(try ArchiveCodec.canonical(body)))
            try Self.write(ArchiveCodec.canonical(manifest), to: temporary.appendingPathComponent(Self.manifestFilename))
            try await store.close(); try await access(copyID, reference)
            try Self.protectDatabase(url)
            guard !Self.exists(directory) else { throw Failure.invalidIdentity }
            // Publish identity AND inactive SQLite together; an interrupted unpublished
            // scratch directory cannot become a different copy's recovery identity.
            try FileManager.default.moveItem(at: temporary, to: directory)
        } catch {
            try? await store.close()
            throw error
        }
    }

    private func access(_ copyID: UUID, _ reference: PantryArchiveStorage.Reference) async throws {
        try Task.checkCancellation()
        guard try await authorize(copyID, reference) else { throw Failure.unauthorized }
        try Task.checkCancellation()
    }
    private static func plan(_ identity: Identity, sourceToken: InventorySourceToken,
                             chunks: [InventoryMigrationChunk]) throws -> InventoryMigrationPlan {
        guard sourceToken.workspaceID == identity.workspaceID else { throw Failure.invalidIdentity }
        var digest = InventoryMigrationManifest.initialDigest, count = 0
        for chunk in chunks { digest = try InventoryMigrationManifest.appending(chunk, to: digest); count += chunk.records.count }
        return .init(migrationID: identity.restorationID, workspaceID: identity.workspaceID, expectedRevision: 0,
            sourceToken: sourceToken, reviewContext: try ArchiveCodec.canonical(identity), expectedChunkCount: chunks.count,
            expectedRecordCount: count, manifestDigest: digest)
    }
    private static func chunks(_ baseline: PantryArchiveCodec.Snapshot) throws -> [InventoryMigrationChunk] {
        var records: [InventoryRecord] = []
        for lot in baseline.lots {
            records.append(.init(key: .init(.lot, lot.id), revision: 1, payload: try ArchiveCodec.canonical(lot)))
        }
        for observation in baseline.observations {
            records.append(.init(key: .init(.observation, observation.id), revision: 1,
                payload: try ArchiveCodec.canonical(observation), lotID: observation.lotID))
        }
        for claim in baseline.reservations {
            records.append(.init(key: .init(.reservation, claim.id), revision: 1,
                payload: try ArchiveCodec.canonical(claim), lotID: claim.lotID))
        }
        for link in baseline.sourceLinks {
            records.append(.init(key: .init(.sourceLink, link.lotID), revision: 1, payload: try ArchiveCodec.canonical(link),
                lotID: link.lotID, source: try PantryPersistenceCodec.sourceIdentity(link.source)))
        }
        records.sort { ($0.key.kind.rawValue, $0.key.id.uuidString) < ($1.key.kind.rawValue, $1.key.id.uuidString) }
        var result: [InventoryMigrationChunk] = [], pending: [InventoryRecord] = [], bytes = 0
        func flush() throws {
            guard !pending.isEmpty else { return }
            let chunk = InventoryMigrationChunk(index: result.count, records: pending)
            _ = try InventoryMigrationManifest.appending(chunk, to: InventoryMigrationManifest.initialDigest)
            result.append(chunk); pending = []; bytes = 0
        }
        // Match LocalStore's canonical encoder for its exact encoded chunk budget.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for record in records {
            guard record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.changedPlan }
            let size = try encoder.encode(record).count
            if pending.count == InventoryPersistenceLimits.batchItems || bytes + size + 2_048 > InventoryPersistenceLimits.batchBytes { try flush() }
            pending.append(record); bytes += size + 1
        }
        try flush()
        return result
    }
    private static func manifest(_ directory: URL) throws -> Manifest {
        let data = try read(directory.appendingPathComponent(manifestFilename))
        try ArchiveCodec.preflight(data, maximum: maximumMetadataBytes)
        let value = try JSONDecoder().decode(Manifest.self, from: data), identity = value.body.identity
        guard identity.version == 1, identity.reference.manifestDigest.count == 32,
              identity.preparedAt.timeIntervalSinceReferenceDate.isFinite,
              value.digest == PantryArchiveCapture.digest(try ArchiveCodec.canonical(value.body)),
              try ArchiveCodec.canonical(value) == data else { throw Failure.invalidIdentity }
        return value
    }
    private static func activation(_ url: URL, manifest: Manifest) throws -> Activation {
        let data = try read(url)
        try ArchiveCodec.preflight(data, maximum: maximumMetadataBytes)
        let value = try JSONDecoder().decode(Activation.self, from: data)
        guard value.identityDigest == manifest.digest, try ArchiveCodec.canonical(value) == data else { throw Failure.invalidActivation }
        try validate(value.receipt, identity: manifest.body.identity)
        return value
    }
    private static func validate(_ receipt: LocalStore.InventoryOperationReceipt, identity: Identity) throws {
        guard receipt.workspaceID == identity.workspaceID, receipt.operationID == identity.restorationID,
              receipt.migrationID == identity.restorationID, receipt.revision == 1, receipt.heads.isEmpty,
              receipt.comparisonHeads.isEmpty, receipt.committedAt == identity.preparedAt else { throw Failure.invalidActivation }
    }
    private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    private static func directory(_ url: URL, create: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, create else { throw Failure.invalidLocation }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw Failure.io }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidLocation }
        try protect(url, permissions: 0o700)
    }
    private static func requireDatabase(_ url: URL) throws {
        guard exists(url) else { throw Failure.missingIdentity }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            var info = stat()
            if lstat(file.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidIdentity }
            } else if errno != ENOENT { throw Failure.io }
        }
    }
    private static func protectDatabase(_ url: URL) throws {
        try requireDatabase(url)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if exists(file) { try protect(file, permissions: 0o600) }
        }
    }
    private static func protect(_ url: URL, permissions: Int) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: permissions]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        var file = url, resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try file.setResourceValues(resources)
    }
    private static func write(_ bytes: Data, to url: URL) throws {
        guard bytes.count <= maximumMetadataBytes, !exists(url) else { throw Failure.invalidIdentity }
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
        try protect(url, permissions: 0o600)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
    private static func read(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.missingIdentity }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumMetadataBytes else { throw Failure.invalidIdentity }
        let data = try handle.read(upToCount: maximumMetadataBytes + 1) ?? Data()
        guard data.count == info.st_size else { throw Failure.invalidIdentity }
        return data
    }
}
