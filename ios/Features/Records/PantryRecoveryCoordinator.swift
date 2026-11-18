import Foundation
import Darwin
import CoreDomain
import LocalStore
import RecordArchive

/// The registry authorizes creation once; existing copies reopen their exact
/// physical database. Large archive validation and restoration run off MainActor.
@MainActor final class PantryRecoveryCoordinator {
    enum Failure: Error, Equatable { case unauthorized, invalidLocation, invalidIdentity, missingIdentity, changedPlan, retired, invalidActivation, io }
    typealias Authorization = @MainActor (UUID, PantryArchiveStorage.Reference) async throws -> Bool
    typealias Identity = PantryArchiveWorker.RestorationContext
    struct Opened {
        let store: ComparisonStore
        let identity: Identity
        /// Small verified handle; historical facts never become executable jobs.
        let source: PantryArchiveHandle
        let current: PantryRepository.Snapshot
    }
    private struct Body: Codable { let identity: Identity; let plan: InventoryMigrationPlan }
    private struct Manifest: Codable { let body: Body; let digest: Data }
    private struct Activation: Codable { let identityDigest: Data; let receipt: LocalStore.InventoryOperationReceipt }
    static let manifestFilename = "pantry-recovery-v1.json"
    static let activationFilename = "pantry-activation-v1.json"
    static let databaseFilename = "pickup.sqlite"
    private static let maximumMetadataBytes = 16_384
    private let root: URL
    private let worker: PantryArchiveWorker
    private let gate: PantryMutationGate
    private let protectedWorkspaceIDs: () -> Set<UUID>
    private let authorize: Authorization

    init(root: URL, worker: PantryArchiveWorker, gate: PantryMutationGate,
         protectedWorkspaceIDs: @escaping () -> Set<UUID>, authorize: @escaping Authorization) throws {
        guard root.isFileURL else { throw Failure.invalidLocation }
        self.root = root.standardizedFileURL; self.worker = worker; self.gate = gate
        self.protectedWorkspaceIDs = protectedWorkspaceIDs; self.authorize = authorize
        try Self.directory(self.root, create: true)
    }
    func create(copyID: UUID, reference: PantryArchiveStorage.Reference, at date: Date) async throws -> Opened {
        try await materialize(copyID: copyID, reference: reference, at: date, allowCreation: true)
    }
    func open(copyID: UUID, reference: PantryArchiveStorage.Reference, at date: Date) async throws -> Opened {
        try await materialize(copyID: copyID, reference: reference, at: date, allowCreation: false)
    }
    /// Reads only the app-owned recovery marker and actual SQLite identity.
    /// Cleanup never needs the imported package and cannot recreate a missing store.
    static func workspaceForCleanup(directory: URL, protectedWorkspaceIDs: Set<UUID>) async throws -> UUID {
        try Self.directory(directory, create: false)
        let identity = try manifest(directory).body.identity
        guard UUID(uuidString: directory.lastPathComponent) == identity.copyID,
              !protectedWorkspaceIDs.contains(identity.workspaceID) else { throw Failure.invalidIdentity }
        let url = directory.appendingPathComponent(databaseFilename)
        try requireDatabase(url)
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let actual = store.workspaceID
        try await store.close()
        guard actual == identity.workspaceID, !protectedWorkspaceIDs.contains(actual) else { throw Failure.invalidIdentity }
        return actual
    }
    private func materialize(copyID: UUID, reference: PantryArchiveStorage.Reference, at date: Date,
                             allowCreation: Bool) async throws -> Opened {
        try await access(copyID, reference)
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let source = try await worker.open(reference: reference)
        try await access(copyID, reference)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidIdentity }
        var restoration: PantryRestorationHandle?
        var openedStore: ComparisonStore?
        do {
            let directory = root.appendingPathComponent(copyID.uuidString, isDirectory: true)
            if !Self.exists(directory) {
                guard allowCreation else { throw Failure.missingIdentity }
                restoration = try await provision(directory: directory, copyID: copyID, source: source, at: date)
            }
            try Self.directory(directory, create: false)
            let manifest = try Self.manifest(directory), identity = manifest.body.identity
            try Self.protect(directory.appendingPathComponent(Self.manifestFilename), permissions: 0o600)
            guard identity.copyID == copyID, identity.reference == reference,
                  !protectedWorkspaceIDs().contains(identity.workspaceID) else { throw Failure.invalidIdentity }
            if restoration == nil {
                restoration = try await worker.prepareRestoration(source: source, context: identity,
                    sourceToken: manifest.body.plan.sourceToken)
            }
            try await access(copyID, reference)
            guard let prepared = restoration, prepared.context == identity,
                  prepared.plan == manifest.body.plan else { throw Failure.changedPlan }
            let plan = prepared.plan, url = directory.appendingPathComponent(Self.databaseFilename)
            try Self.requireDatabase(url)
            let store = try ComparisonStore(url: url, inventoryEnabled: true)
            openedStore = store
            try Self.protectDatabase(url)
            guard store.workspaceID == identity.workspaceID,
                  !protectedWorkspaceIDs().contains(store.workspaceID) else { throw Failure.invalidIdentity }
            let state = try await store.inventoryState(); try await access(copyID, reference)
            let acknowledgmentURL = directory.appendingPathComponent(Self.activationFilename)
            if Self.exists(acknowledgmentURL) {
                let acknowledgment = try Self.activation(acknowledgmentURL, manifest: manifest)
                try Self.protect(acknowledgmentURL, permissions: 0o600)
                let durable = try await store.inventoryMigrationActivation(plan)
                try await access(copyID, reference)
                guard state.active, state.revision >= acknowledgment.receipt.revision,
                      durable == acknowledgment.receipt else { throw Failure.invalidActivation }
            } else {
                let progress = try await store.beginInventoryMigration(plan); try await access(copyID, reference)
                guard progress.status != .cancelled else { throw Failure.retired }
                if progress.status == .staging {
                    guard progress.plan == plan, progress.nextChunk <= plan.expectedChunkCount else { throw Failure.changedPlan }
                    for index in progress.nextChunk..<plan.expectedChunkCount {
                        let chunk = try await worker.restorationChunk(prepared, index: index)
                        try await access(copyID, reference)
                        _ = try await store.stageInventoryMigration(id: identity.restorationID, chunk: chunk)
                        try await access(copyID, reference)
                    }
                }
                let receipt = try await store.finishInventoryMigration(id: identity.restorationID, at: identity.preparedAt)
                try await access(copyID, reference)
                try Self.validate(receipt, identity: identity)
                try Self.write(ArchiveCodec.canonical(Activation(identityDigest: manifest.digest, receipt: receipt)), to: acknowledgmentURL)
            }
            let current = try await PantryRepository(store: store, authorize: { !Task.isCancelled }).load(at: max(date, identity.preparedAt))
            try await access(copyID, reference)
            guard current.state.workspaceID == identity.workspaceID else { throw Failure.invalidIdentity }
            try Self.protectDatabase(url)
            try await worker.discardRestoration(prepared); restoration = nil
            try await access(copyID, reference)
            return Opened(store: store, identity: identity, source: source, current: current)
        } catch {
            if let openedStore { try? await openedStore.close() }
            if let restoration { try? await worker.discardRestoration(restoration) }
            throw error
        }
    }

    private func provision(directory: URL, copyID: UUID, source: PantryArchiveHandle,
                           at date: Date) async throws -> PantryRestorationHandle {
        guard date >= source.descriptor.capturedAt else { throw Failure.invalidIdentity }
        let temporary = root.appendingPathComponent("pantry-preparing-" + UUID().uuidString, isDirectory: true)
        try Self.directory(temporary, create: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent(Self.databaseFilename)
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        var restoration: PantryRestorationHandle?
        do {
            try Self.protectDatabase(url)
            guard !protectedWorkspaceIDs().contains(store.workspaceID) else { throw Failure.invalidIdentity }
            let identity = Identity(version: 1, copyID: copyID, reference: source.reference,
                workspaceID: store.workspaceID, restorationID: UUID(), preparedAt: date)
            let token = try await store.inventorySourceToken(); try await access(copyID, source.reference)
            let prepared = try await worker.prepareRestoration(source: source, context: identity, sourceToken: token)
            restoration = prepared
            try await access(copyID, source.reference)
            let body = Body(identity: identity, plan: prepared.plan)
            let manifest = Manifest(body: body, digest: PantryArchiveCapture.digest(try ArchiveCodec.canonical(body)))
            try Self.write(ArchiveCodec.canonical(manifest), to: temporary.appendingPathComponent(Self.manifestFilename))
            try await store.close(); try await access(copyID, source.reference)
            try Self.protectDatabase(url)
            guard !Self.exists(directory) else { throw Failure.invalidIdentity }
            try FileManager.default.moveItem(at: temporary, to: directory)
            return prepared
        } catch {
            try? await store.close()
            if let restoration { try? await worker.discardRestoration(restoration) }
            throw error
        }
    }
    private func access(_ copyID: UUID, _ reference: PantryArchiveStorage.Reference) async throws {
        try Task.checkCancellation()
        guard try await authorize(copyID, reference) else { throw Failure.unauthorized }
        try Task.checkCancellation()
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
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
