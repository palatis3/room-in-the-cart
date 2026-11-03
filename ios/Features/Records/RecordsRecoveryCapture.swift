import Foundation
import LocalStore
import RecordArchive
import Darwin

/// A registry row must still exist when an independent store is opened. Deletion
/// invalidates synchronous authorizers before awaiting the registry, then drains
/// in-flight users before removing directories. A stale row cannot mint a new scope.
@MainActor final class RecordsRecoveryLifetime {
    static let shared = RecordsRecoveryLifetime()
    struct Lease {
        fileprivate let id: UUID
        let authorize: RecordsToolsModel.Authorization
    }
    private var generation = UUID()
    private var active: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func begin(copy: RecoveredRecord, registry: RecoveryRegistry, authorize: @escaping RecordsToolsModel.Authorization) async throws -> Lease {
        let captured = generation
        guard authorize(), try await registry.refreshList().contains(copy), authorize(), generation == captured else { throw ArchiveError.unavailable }
        let id = UUID(); active.insert(id)
        return Lease(id: id, authorize: { [weak self] in
            guard let self else { return false }
            return self.generation == captured && self.active.contains(id) && authorize()
        })
    }
    func revalidate(_ lease: Lease, copy: RecoveredRecord, registry: RecoveryRegistry) async throws {
        guard lease.authorize(), try await registry.refreshList().contains(copy), lease.authorize() else { throw ArchiveError.unavailable }
    }
    func finish(_ lease: Lease) {
        active.remove(lease.id)
        if active.isEmpty { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }
    func invalidate() { generation = UUID() }
    func drain() async {
        guard !active.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Runtime authority is minted from a store opened at an app-owned recovery URL.
/// ArchiveCaptureNamespace is only the inert, portable description of that scope.
@MainActor enum RecordsRecoveryCapture {
    @MainActor struct Scope {
        let declaration: ArchiveCaptureNamespace
        fileprivate init(_ declaration: ArchiveCaptureNamespace) { self.declaration = declaration }
        var workspaceID: UUID { declaration.physicalWorkspaceID }
        func accepts(_ source: SourceMediaRecord) -> Bool {
            source.target.workspaceID == workspaceID &&
                (declaration.storeKind == .ledger ? source.target.kind != .receiptEvidence : source.target.kind == .receiptEvidence)
        }
        func attachment(_ source: SourceMediaRecord) throws -> ArchiveMediaAttachment {
            guard accepts(source) else { throw ArchiveError.invalidIdentity }
            let value = try RecordsMediaCodec.attachment(source)
            return ArchiveMediaAttachment(id: value.id, kind: value.kind, contentType: value.contentType,
                data: value.data, captureNamespace: declaration)
        }
        func filtering(_ listing: CaptureMediaArchiveListing) -> CaptureMediaArchiveListing {
            let readable = listing.records.filter(accepts)
            return CaptureMediaArchiveListing(records: readable,
                unavailableCount: listing.unavailableCount + listing.records.count - readable.count)
        }
    }
    private struct PhysicalScope: Codable, Equatable {
        let formatMajor: Int
        let recoveryCopyID: UUID
        let storeKind: ArchiveCaptureNamespace.StoreKind
        let physicalWorkspaceID: UUID
    }
    private struct LocalManifest: Codable { let scope: PhysicalScope; let digest: String }
    private static let filename = "capture-scope-v1.json"
    private static let maximumBytes = 4096

    static func openLedger(copy: RecoveredRecord, directory: URL, authorize: @escaping RecordsToolsModel.Authorization) async throws -> (store: LedgerStore, scope: Scope) {
        guard authorize(), copy.record.kind == .ledger else { throw ArchiveError.unavailable }
        try validateCopy(copy)
        try prepare(directory, copyID: copy.id)
        let url = directory.appendingPathComponent("ledger.sqlite")
        try requireStoreFiles(url)
        let store = try LedgerStore(url: url)
        do {
            guard authorize() else { throw ArchiveError.unavailable }
            let scope = try register(copy: copy, directory: directory, kind: .ledger, workspaceID: store.workspaceID)
            guard authorize() else { throw ArchiveError.unavailable }
            return (store, scope)
        } catch { try? await store.close(); throw error }
    }
    static func openPickup(copy: RecoveredRecord, directory: URL, authorize: @escaping RecordsToolsModel.Authorization) async throws -> (store: ComparisonStore, scope: Scope) {
        guard authorize(), copy.record.kind == .pickup else { throw ArchiveError.unavailable }
        try validateCopy(copy)
        try prepare(directory, copyID: copy.id)
        let url = directory.appendingPathComponent("pickup.sqlite")
        try requireStoreFiles(url)
        let store = try ComparisonStore(url: url)
        do {
            guard authorize() else { throw ArchiveError.unavailable }
            let scope = try register(copy: copy, directory: directory, kind: .pickup, workspaceID: store.workspaceID)
            guard authorize() else { throw ArchiveError.unavailable }
            return (store, scope)
        } catch { try? await store.close(); throw error }
    }
    /// Called before removing an orphaned recovery directory. The local journal
    /// survives registry-row removal and partial cleanup. Imported declarations
    /// are never read here, and active root namespaces may not be retired.
    static func erase(directory: URL, protectedWorkspaceIDs: Set<UUID>, media: CaptureMediaStore = .shared,
                      corrections: CaptureCorrectionStore = .shared) async throws {
        guard let copyID = UUID(uuidString: directory.lastPathComponent) else { throw ArchiveError.invalidIdentity }
        try requireDirectory(directory)
        let ledgerURL = directory.appendingPathComponent("ledger.sqlite"), pickupURL = directory.appendingPathComponent("pickup.sqlite")
        let hasLedger = FileManager.default.fileExists(atPath: ledgerURL.path), hasPickup = FileManager.default.fileExists(atPath: pickupURL.path)
        guard !(hasLedger && hasPickup) else { throw ArchiveError.integrity }
        let actual: PhysicalScope?
        if hasLedger {
            try requireStoreFiles(ledgerURL)
            let store = try LedgerStore(url: ledgerURL)
            actual = PhysicalScope(formatMajor: 1, recoveryCopyID: copyID, storeKind: .ledger, physicalWorkspaceID: store.workspaceID)
            try await store.close()
        } else if hasPickup {
            try requireStoreFiles(pickupURL)
            let store = try ComparisonStore(url: pickupURL)
            actual = PhysicalScope(formatMajor: 1, recoveryCopyID: copyID, storeKind: .pickup, physicalWorkspaceID: store.workspaceID)
            try await store.close()
        } else { actual = nil }
        let physical: PhysicalScope?
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
            physical = try read(directory, copyID: copyID)
            guard physical == actual else { throw ArchiveError.integrity }
        } else {
            // Pre-journal recovered stores used these same fixed filenames. Read
            // their actual SQLite identity; never infer it from archive metadata.
            physical = actual
            if let physical { try write(physical, directory: directory) }
        }
        guard let physical else { return }
        guard !protectedWorkspaceIDs.contains(physical.physicalWorkspaceID) else { throw ArchiveError.conflict }
        try await media.eraseWorkspace(physical.physicalWorkspaceID)
        try await corrections.eraseProfile(CaptureCorrectionScope(profileID: "local:" + physical.physicalWorkspaceID.uuidString, localeIdentifier: "en-US"))
    }
    private static func register(copy: RecoveredRecord, directory: URL, kind: ArchiveCaptureNamespace.StoreKind, workspaceID: UUID) throws -> Scope {
        guard let copyID = UUID(uuidString: copy.id) else { throw ArchiveError.invalidIdentity }
        let declaration = ArchiveCaptureNamespace(archiveOrigin: copy.record.origin, storeKind: kind, physicalWorkspaceID: workspaceID)
        try declaration.validate(origin: copy.record.origin, recordKind: copy.record.kind, mediaKind: kind == .ledger ? .packageReference : .receiptEvidence)
        // An independent recovery must not share the original physical namespace.
        let prefix = kind == .ledger ? "ledger/" : "pickups/"
        guard copy.record.origin != prefix + workspaceID.uuidString else { throw ArchiveError.invalidIdentity }
        let expected = PhysicalScope(formatMajor: 1, recoveryCopyID: copyID, storeKind: kind, physicalWorkspaceID: workspaceID)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
            guard try read(directory, copyID: copyID) == expected else { throw ArchiveError.integrity }
        } else { try write(expected, directory: directory) }
        return Scope(declaration)
    }
    private static func validateCopy(_ copy: RecoveredRecord) throws {
        guard copy.documentKind == .personalRecovery, copy.record.nativePayload != nil,
              try ArchiveCodec.receipt(copy.record, projection: ArchiveCodec.projection(for: copy.documentKind), localCopyID: copy.id) == copy.receipt else { throw ArchiveError.invalidIdentity }
        try RecordsNativeCodec.validate(copy.record)
    }
    private static func prepare(_ directory: URL, copyID: String) throws {
        guard directory.isFileURL, let id = UUID(uuidString: copyID), directory.lastPathComponent == id.uuidString else { throw ArchiveError.invalidIdentity }
        var value = stat()
        if lstat(directory.path, &value) == 0 {
            guard value.st_mode & S_IFMT == S_IFDIR else { throw ArchiveError.unavailable }
        } else {
            guard errno == ENOENT else { throw ArchiveError.unavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
    private static func read(_ directory: URL, copyID: UUID) throws -> PhysicalScope {
        let url = directory.appendingPathComponent(filename)
        guard try mode(url) & S_IFMT == S_IFREG else { throw ArchiveError.unavailable }
        let bytes = try RecoveryRegistry.boundedRead(url, maximum: maximumBytes)
        try ArchiveCodec.preflight(bytes, maximum: maximumBytes)
        let value: LocalManifest
        do { value = try JSONDecoder().decode(LocalManifest.self, from: bytes) } catch { throw ArchiveError.malformed }
        guard value.scope.formatMajor == 1 else { throw ArchiveError.unsupportedVersion }
        guard value.scope.recoveryCopyID == copyID,
              try ArchiveCodec.canonical(value) == bytes,
              ArchiveCodec.digest(try ArchiveCodec.canonical(value.scope)) == value.digest else { throw ArchiveError.integrity }
        return value.scope
    }
    private static func write(_ value: PhysicalScope, directory: URL) throws {
        try requireDirectory(directory)
        let url = directory.appendingPathComponent(filename)
        try requireNonLinkIfPresent(url)
        let bytes = try ArchiveCodec.canonical(LocalManifest(scope: value, digest: ArchiveCodec.digest(try ArchiveCodec.canonical(value))))
        guard bytes.count <= maximumBytes else { throw ArchiveError.tooLarge }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
        var folder = directory, attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
    }
    private static func requireNonLinkIfPresent(_ url: URL) throws {
        var value = stat()
        if lstat(url.path, &value) == 0 {
            guard value.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.unavailable }
        } else if errno != ENOENT { throw ArchiveError.unavailable }
    }
    private static func requireStoreFiles(_ url: URL) throws {
        for suffix in ["", "-journal", "-wal", "-shm"] { try requireNonLinkIfPresent(URL(fileURLWithPath: url.path + suffix)) }
    }
    private static func requireDirectory(_ url: URL) throws {
        guard try mode(url) & S_IFMT == S_IFDIR else { throw ArchiveError.unavailable }
    }
    private static func mode(_ url: URL) throws -> mode_t {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ArchiveError.unavailable }
        return value.st_mode
    }
}
