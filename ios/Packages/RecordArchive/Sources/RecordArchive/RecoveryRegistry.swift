import Foundation
import Darwin

public enum RecoveryDisposition: String, Codable, Sendable { case absent, identical, sibling, quarantined, erased }
/// Source metadata for one separate local copy. No stored content is needed to compare versions.
public struct RecoveredCopySummary: Identifiable, Equatable, Sendable {
    public let id: ArchiveIdentity
    public let documentKind: ArchiveKind
    public let savedAtMilliseconds: Int64
    public let selectedReferenceCount: Int
}
public struct RecoveryReviewRow: Identifiable, Equatable, Sendable {
    public let id: ArchiveIdentity
    public let record: ArchiveRecord
    public let disposition: RecoveryDisposition
    public let existingCopyID: String?
    public let priorCopies: [RecoveredCopySummary]
}
public struct RecoveryReview: Sendable {
    public let envelope: ArchiveEnvelope
    public let rows: [RecoveryReviewRow]
    public let registryGeneration: UUID
    public var canApply: Bool { !rows.contains { $0.disposition == .quarantined || $0.disposition == .erased } }
}
public struct RecoveredRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { receipt.localCopyID }
    public let receipt: ArchiveReceipt
    public let record: ArchiveRecord
    public let documentKind: ArchiveKind
    public let recoveredAtMilliseconds: Int64
    // An explicit Undo reopens the same local ID, with a new lifetime for pending Files callbacks.
    fileprivate var backupLifetime: UUID? = nil
}
public struct RecoveryCommit: Sendable {
    public let records: [RecoveredRecord]
    public let insertedCopyIDs: [String]
    public var insertedCount: Int { insertedCopyIDs.count }
}
public enum RecoveryDeleteScope: Sendable, Equatable {
    case copy(String), copies([String]), origin(String), allRecovered

    fileprivate func includes(_ copy: RecoveredRecord) -> Bool {
        switch self {
        case let .copy(id): return copy.id == id
        case let .copies(ids): return ids.contains(copy.id)
        case let .origin(origin): return copy.record.origin == origin
        case .allRecovered: return true
        }
    }
}

public struct RecoveryDeletionReview: Sendable {
    fileprivate let scope: RecoveryDeleteScope
    private struct Version: Equatable, Sendable {
        let digest: String
        let lifetime: UUID?
    }
    private let versions: [String: Version]
    public var count: Int { versions.count }
    public var copyIDs: Set<String> { Set(versions.keys) }

    public init(scope: RecoveryDeleteScope, displayedCopies: [RecoveredRecord]) {
        self.scope = scope
        versions = Self.versions(of: displayedCopies.filter(scope.includes))
    }

    fileprivate func matches(_ copies: [RecoveredRecord]) -> Bool {
        versions == Self.versions(of: copies)
    }

    private static func versions(of copies: [RecoveredRecord]) -> [String: Version] {
        Dictionary(uniqueKeysWithValues: copies.map { ($0.id, Version(digest: $0.receipt.digest, lifetime: $0.backupLifetime)) })
    }
}
public struct RecoveryUndoToken: Hashable, Sendable { public let id: UUID }

/// The Files success date applies to the stable source. Only revisions in the caller's
/// current owner projection appear here, even if the saved file also contained siblings.
public struct EncryptedBackupStatus: Equatable, Sendable {
    public let savedAtMilliseconds: Int64
    public let revisions: Set<String>
}

public struct EncryptedBackupIntent: Sendable {
    fileprivate struct Target: Sendable {
        let source: ArchiveSourceIdentity
        let revision: String
        let mediaIDs: Set<String>
        // No dependencies means this revision has an independent local or live source.
        let copyLifetimes: [String: String]
    }
    fileprivate let registryID: String
    fileprivate let targets: [Target]
}

fileprivate struct BackupMark: Codable {
    struct Revision: Codable {
        let revision: String
        var dependentCopyIDs: Set<String>
    }
    let source: ArchiveSourceIdentity
    let savedAtMilliseconds: Int64
    var revisions: [Revision]
    var usesBaseOwnerIdentity: Bool?
    var couldHaveSelectedMedia: Bool {
        let id = source.recordID
        return id == "meal-library" || UUID(uuidString: id)?.uuidString == id
    }
}

/// A single atomic manifest commits snapshots and canonical receipts together. Original
/// live stores are never edited; restored records are independent sibling workspaces.
/// The composition root must supply a unique per-installation file URL and protect its
/// parent directory. The registry revalidates digest and generation at Apply.
public actor RecoveryRegistry {
    private struct Manifest: Codable {
        var formatMajor = 1
        var generation = UUID()
        var records: [RecoveredRecord] = []
        var erasedIdentities: [ArchiveIdentity] = []
        var erasedSources: [ArchiveSourceIdentity]? = []
        var erasedOrigins: [String]? = []
        var erasedMediaSources: [ArchiveMediaSourceIdentity]? = []
        var encryptedBackups: [BackupMark]?
    }
    private let url: URL
    private var manifest: Manifest
    private var undo: [UUID: [RecoveredRecord]] = [:]
    private static let emptyGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public init(url: URL) throws {
        guard url.isFileURL else { throw ArchiveError.unavailable }
        self.url = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            manifest = try Self.readManifest(url)
        } else {
            // Every new instance sees the same empty state until the first commit.
            manifest = Manifest(generation: Self.emptyGeneration)
        }
    }
    public static let maximumRegistryBytes = 64 * 1_048_576
    public func list() -> [RecoveredRecord] { manifest.records.sorted { $0.recoveredAtMilliseconds > $1.recoveredAtMilliseconds } }
    public func load(id: String) -> RecoveredRecord? { manifest.records.first { $0.id == id } }
    /// Refreshes under the same file lock used by writes, including other registry instances.
    public func refreshList() throws -> [RecoveredRecord] {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        return list()
    }
    public func refreshList(includingBackupsFor records: [ArchiveRecord], recoveredCopyIDs: [ArchiveIdentity: Set<String>] = [:]) throws -> (recovered: [RecoveredRecord], backups: [ArchiveIdentity: EncryptedBackupStatus]) {
        let recovered = try refreshList()
        return (recovered, backupStatuses(for: records, recoveredCopyIDs: recoveredCopyIDs))
    }
    public func lastEncryptedBackups(for records: [ArchiveRecord], recoveredCopyIDs: [ArchiveIdentity: Set<String>] = [:]) throws -> [ArchiveIdentity: EncryptedBackupStatus] {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        return backupStatuses(for: records, recoveredCopyIDs: recoveredCopyIDs)
    }
    private func backupStatuses(for records: [ArchiveRecord], recoveredCopyIDs: [ArchiveIdentity: Set<String>]) -> [ArchiveIdentity: EncryptedBackupStatus] {
        let marks = Dictionary(uniqueKeysWithValues: (manifest.encryptedBackups ?? []).map { ($0.source, $0) })
        let projection = ArchiveCodec.projection(for: .personalRecovery)
        var result: [ArchiveIdentity: EncryptedBackupStatus] = [:]
        for record in records where record.nativePayload != nil {
            let source = ArchiveSourceIdentity(origin: record.origin, recordID: record.id)
            guard let mark = marks[source] else { continue }
            let identity = ArchiveIdentity(origin: source.origin, recordID: source.recordID, revision: record.revision, projection: projection)
            // An imported owner copy can outlive access to a live shop with the very
            // same archive identity. Only a common backing source can disclose a date.
            let copies = recoveredCopyIDs[identity]
            let visible = mark.revisions.filter { saved in
                if let copies { return !copies.isDisjoint(with: saved.dependentCopyIDs) }
                return saved.dependentCopyIDs.isEmpty
            }
            if !visible.isEmpty {
                result[identity] = .init(savedAtMilliseconds: mark.savedAtMilliseconds,
                    revisions: visible.contains(where: { $0.revision == identity.revision }) ? [identity.revision] : [])
            }
        }
        return result
    }
    /// Capture the selected owner metadata immediately before sealing the file. The caller
    /// identifies recovered-only outputs by their base owner identity, independent of the
    /// chosen attachments. Edited IDs/revisions can differ from the import.
    public func prepareEncryptedBackup(_ records: [ArchiveRecord], recoveredCopyIDs: [ArchiveIdentity: Set<String>] = [:]) throws -> EncryptedBackupIntent {
        guard records.count <= ArchiveCodec.maximumRecords else { throw ArchiveError.tooLarge }
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let copies = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.id, $0) })
        let erasedOrigins = Set(manifest.erasedOrigins ?? []), erasedSources = Set(manifest.erasedSources ?? [])
        let erasedMedia = Set(manifest.erasedMediaSources ?? [])
        let projection = ArchiveCodec.projection(for: .personalRecovery)
        var targets: [EncryptedBackupIntent.Target] = []
        var seen = Set<ArchiveIdentity>()
        for record in records where record.nativePayload != nil {
            let source = ArchiveSourceIdentity(origin: record.origin, recordID: record.id)
            let identity = ArchiveIdentity(origin: source.origin, recordID: source.recordID, revision: record.revision, projection: projection)
            guard ArchiveCodec.identifier(source.origin), ArchiveCodec.identifier(source.recordID),
                  ArchiveCodec.identifier(identity.revision),
                  seen.insert(ArchiveCodec.identity(record, projection: projection)).inserted else { throw ArchiveError.invalidIdentity }
            let mediaIDs = Set((record.media ?? []).map(\.id))
            guard !erasedOrigins.contains(source.origin), !erasedSources.contains(source),
                  !mediaIDs.contains(where: { erasedMedia.contains(.init(origin: source.origin, mediaID: $0)) }) else { throw ArchiveError.conflict }
            var lifetimes: [String: String] = [:]
            if let ids = recoveredCopyIDs[identity] {
                guard !ids.isEmpty else { throw ArchiveError.invalidIdentity }
                for id in ids {
                    guard let copy = copies[id], copy.documentKind == .personalRecovery, copy.record.nativePayload != nil,
                          copy.record.origin == source.origin else { throw ArchiveError.staleReview }
                    lifetimes[id] = copy.backupLifetime?.uuidString ?? id
                }
            }
            targets.append(.init(source: source, revision: identity.revision, mediaIDs: mediaIDs, copyLifetimes: lifetimes))
        }
        return EncryptedBackupIntent(registryID: registryID, targets: targets)
    }
    private var registryID: String { ArchiveCodec.digest(Data(url.path.utf8)) }

    /// Call only for a successful Files save. A retry uses the same completion timestamp.
    /// A later save of an older revision is a real backup; source revision dates never order callbacks.
    public func recordSuccessfulBackup(_ intent: EncryptedBackupIntent, savedAtMilliseconds: Int64) throws {
        guard intent.registryID == registryID, savedAtMilliseconds > 0 else { throw ArchiveError.invalidIdentity }
        guard !intent.targets.isEmpty else { return }
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let erasedSources = Set(manifest.erasedSources ?? []), erasedOrigins = Set(manifest.erasedOrigins ?? [])
        let erasedMedia = Set(manifest.erasedMediaSources ?? [])
        let copies = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.id, $0.backupLifetime?.uuidString ?? $0.id) })
        var marks = Dictionary(uniqueKeysWithValues: (manifest.encryptedBackups ?? []).map { ($0.source, $0) })
        var changed = false
        for (source, targets) in Dictionary(grouping: intent.targets, by: \.source) {
            guard !erasedSources.contains(source), !erasedOrigins.contains(source.origin),
                  savedAtMilliseconds > (marks[source]?.savedAtMilliseconds ?? 0) else { continue }
            // Media selections are separate file projections with the same base owner
            // backing. Record a revision once if any selected projection remains eligible.
            var eligibleRevisions = Set<String>()
            let revisions: [BackupMark.Revision] = targets.compactMap { target in
                guard !target.mediaIDs.contains(where: { erasedMedia.contains(.init(origin: source.origin, mediaID: $0)) }) else { return nil }
                let remaining = target.copyLifetimes.filter { copies[$0.key] == $0.value }
                guard target.copyLifetimes.isEmpty || !remaining.isEmpty,
                      eligibleRevisions.insert(target.revision).inserted else { return nil }
                return .init(revision: target.revision, dependentCopyIDs: Set(remaining.keys))
            }
            guard !revisions.isEmpty else { continue }
            marks[source] = .init(source: source, savedAtMilliseconds: savedAtMilliseconds, revisions: revisions, usesBaseOwnerIdentity: true)
            changed = true
        }
        if changed {
            var next = manifest
            next.encryptedBackups = Array(marks.values)
            try persist(&next, recoveryChanged: false)
        }
    }

    private func purgeBackups(_ next: inout Manifest, removedCopies: Set<String>) {
        let sources = Set(next.erasedSources ?? []), origins = Set(next.erasedOrigins ?? [])
        next.encryptedBackups = next.encryptedBackups?.compactMap { original in
            var mark = original
            guard !sources.contains(mark.source), !origins.contains(mark.source.origin) else { return nil }
            mark.revisions = mark.revisions.compactMap { revision in
                guard !revision.dependentCopyIDs.isEmpty else { return revision }
                var remaining = revision
                remaining.dependentCopyIDs.subtract(removedCopies)
                return remaining.dependentCopyIDs.isEmpty ? nil : remaining
            }
            return mark.revisions.isEmpty ? nil : mark
        }
    }
    public func review(_ envelope: ArchiveEnvelope) throws -> RecoveryReview {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        return try makeReview(envelope)
    }
    private func makeReview(_ envelope: ArchiveEnvelope, includePriorCopies: Bool = true) throws -> RecoveryReview {
        try ArchiveCodec.validate(envelope)
        let incoming = envelope.payload.records
        let sources = Set(incoming.map { ArchiveSourceIdentity(origin: $0.origin, recordID: $0.id) })
        let erasedOrigins = Set(manifest.erasedOrigins ?? []), erasedSources = Set(manifest.erasedSources ?? [])
        let erasedMedia = Set(manifest.erasedMediaSources ?? []), erasedIdentities = Set(manifest.erasedIdentities)
        var receipts: [ArchiveIdentity: ArchiveReceipt] = [:], relatedSources = Set<ArchiveSourceIdentity>()
        var prior: [ArchiveSourceIdentity: [RecoveredCopySummary]] = [:]
        for saved in manifest.records {
            let source = ArchiveSourceIdentity(origin: saved.record.origin, recordID: saved.record.id)
            guard sources.contains(source) else { continue }
            receipts[saved.receipt.identity] = saved.receipt
            relatedSources.insert(source)
            if includePriorCopies && (envelope.documentKind == .personalRecovery || saved.documentKind == .helperShop) {
                prior[source, default: []].append(.init(id: saved.receipt.identity, documentKind: saved.documentKind,
                                                       savedAtMilliseconds: saved.receipt.savedAtMilliseconds,
                                                       selectedReferenceCount: saved.record.media?.count ?? 0))
            }
        }
        // Rows sharing a stable source share these sorted arrays. Build the redacted index
        // once, including when a personal file carries a previously imported helper projection.
        let sorted = prior.mapValues { copies in
            copies.sorted { lhs, rhs in
                if lhs.savedAtMilliseconds != rhs.savedAtMilliseconds {
                    if lhs.savedAtMilliseconds == 0 { return false }
                    if rhs.savedAtMilliseconds == 0 { return true }
                    return lhs.savedAtMilliseconds > rhs.savedAtMilliseconds
                }
                return (lhs.id.revision, lhs.id.projection) < (rhs.id.revision, rhs.id.projection)
            }
        }
        let helpers = envelope.documentKind == .helperShop ? sorted : sorted.mapValues { $0.filter { $0.documentKind == .helperShop } }
        let rows = try incoming.map { record -> RecoveryReviewRow in
            let identity = ArchiveCodec.identity(record, projection: envelope.projectionID)
            let source = ArchiveSourceIdentity(origin: record.origin, recordID: record.id)
            if erasedOrigins.contains(record.origin) || erasedSources.contains(source) || erasedIdentities.contains(identity) ||
                (record.media ?? []).contains(where: { erasedMedia.contains(.init(origin: record.origin, mediaID: $0.id)) }) {
                return .init(id: identity, record: record, disposition: .erased, existingCopyID: nil, priorCopies: [])
            }
            let exact = receipts[identity]
            let disposition: RecoveryDisposition
            if let exact {
                let digest = ArchiveCodec.digest(try ArchiveCodec.canonical(record))
                disposition = exact.digest == digest ? .identical : .quarantined
            } else { disposition = relatedSources.contains(source) ? .sibling : .absent }
            let visible = envelope.documentKind == .personalRecovery && record.nativePayload != nil ? sorted : helpers
            return .init(id: identity, record: record, disposition: disposition, existingCopyID: exact?.localCopyID,
                         priorCopies: visible[source] ?? [])
        }
        return RecoveryReview(envelope: envelope, rows: rows, registryGeneration: manifest.generation)
    }
    /// Call only after the domain adapter has validated every private native payload.
    /// No current record is replaced. A retry returns the previous local copy IDs.
    public func apply(_ reviewed: RecoveryReview, now: Date = Date()) throws -> RecoveryCommit {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let checked = try makeReview(reviewed.envelope, includePriorCopies: false)
        guard checked.canApply else { throw ArchiveError.conflict }
        // A lost successful response may retry the very same review. Reopen only
        // when every receipt now matches exactly; other generation changes re-review.
        guard reviewed.registryGeneration == manifest.generation || checked.rows.allSatisfy({ $0.disposition == .identical }) else { throw ArchiveError.staleReview }
        var next = manifest, result: [RecoveredRecord] = [], inserted: [String] = []
        for row in checked.rows {
            if let existing = row.existingCopyID, let saved = next.records.first(where: { $0.id == existing }) { result.append(saved); continue }
            let copyID = UUID().uuidString
            let receipt = try ArchiveCodec.receipt(row.record, projection: reviewed.envelope.projectionID, localCopyID: copyID)
            let saved = RecoveredRecord(receipt: receipt, record: row.record, documentKind: reviewed.envelope.documentKind, recoveredAtMilliseconds: ArchiveCodec.milliseconds(now))
            next.records.append(saved); result.append(saved); inserted.append(copyID)
        }
        if !inserted.isEmpty { try persist(&next) }
        return RecoveryCommit(records: result, insertedCopyIDs: inserted)
    }
    public func delete(_ scope: RecoveryDeleteScope) throws -> RecoveryUndoToken {
        try delete(scope, review: nil)
    }
    public func delete(_ review: RecoveryDeletionReview) throws -> RecoveryUndoToken {
        try delete(review.scope, review: review)
    }
    private func delete(_ scope: RecoveryDeleteScope, review: RecoveryDeletionReview?) throws -> RecoveryUndoToken {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let removed = manifest.records.filter(scope.includes)
        if let review, !review.matches(removed) { throw ArchiveError.deletionSelectionChanged }
        guard !removed.isEmpty else { throw ArchiveError.unavailable }
        let ids = Set(removed.map(\.id))
        var next = manifest
        next.records.removeAll { ids.contains($0.id) }
        next.erasedIdentities = Array(Set(next.erasedIdentities).union(removed.map(\.receipt.identity)))
        purgeBackups(&next, removedCopies: ids)
        try persist(&next)
        let token = RecoveryUndoToken(id: UUID()); undo[token.id] = removed
        return token
    }
    /// Undo bytes remain only in memory until exit or discardUndo, never in an on-disk trash.
    public func undoDelete(_ token: RecoveryUndoToken) throws {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        guard let records = undo[token.id] else { throw ArchiveError.unavailable }
        guard !records.contains(where: { (manifest.erasedOrigins ?? []).contains($0.record.origin) || (manifest.erasedSources ?? []).contains(ArchiveSourceIdentity(origin: $0.record.origin, recordID: $0.record.id)) }) else { throw ArchiveError.conflict }
        var next = manifest
        let erasedMedia = Set(next.erasedMediaSources ?? [])
        let restorable = try records.map { try scrubbing($0, erasedMedia: erasedMedia) }
        for record in restorable where !next.records.contains(where: { $0.receipt.identity == record.receipt.identity }) {
            var restored = record
            restored.backupLifetime = UUID()
            next.records.append(restored)
        }
        let identities = Set(restorable.map(\.receipt.identity))
        next.erasedIdentities.removeAll { identities.contains($0) }
        try persist(&next); undo[token.id] = nil
    }
    /// Local domain tombstones override every revision/projection of the erased source.
    /// This also purges recovered private text and in-memory deletion undo for that source.
    public func registerErasedSources(_ sources: [ArchiveSourceIdentity]) throws {
        guard sources.allSatisfy({ ArchiveCodec.identifier($0.origin) && ArchiveCodec.identifier($0.recordID) }) else { throw ArchiveError.invalidIdentity }
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let known = Set(manifest.erasedSources ?? []), incoming = Set(sources)
        guard !incoming.isSubset(of: known) else { return }
        let all = known.union(incoming)
        var next = manifest
        next.erasedSources = Array(all)
        let removed = next.records.filter { all.contains(ArchiveSourceIdentity(origin: $0.record.origin, recordID: $0.record.id)) }
        let ids = Set(removed.map(\.id))
        next.records.removeAll { ids.contains($0.id) }
        purgeBackups(&next, removedCopies: ids)
        try persist(&next)
        undo = undo.filter { !$0.value.contains { all.contains(ArchiveSourceIdentity(origin: $0.record.origin, recordID: $0.record.id)) } }
    }
    /// Whole-workspace erasure also covers shops that only occur in older backups.
    public func registerErasedOrigins(_ origins: [String]) throws {
        guard origins.allSatisfy(ArchiveCodec.identifier) else { throw ArchiveError.invalidIdentity }
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let known = Set(manifest.erasedOrigins ?? []), incoming = Set(origins)
        guard !incoming.isSubset(of: known) else { return }
        let all = known.union(incoming)
        var next = manifest
        next.erasedOrigins = Array(all)
        next.records.removeAll { all.contains($0.record.origin) }
        purgeBackups(&next, removedCopies: [])
        try persist(&next)
        undo = undo.filter { !$0.value.contains { all.contains($0.record.origin) } }
    }
    /// A source-reference removal also scrubs embedded evidence in earlier copies.
    /// Preserve each copy ID and its isolated edited workspace. The sanitized copy
    /// becomes a deterministic local child revision; original media cannot return
    /// through retry, older backups or deletion undo.
    public func registerErasedMedia(_ sources: [ArchiveMediaSourceIdentity]) throws {
        guard sources.allSatisfy({ ArchiveCodec.identifier($0.origin) && ArchiveCodec.identifier($0.mediaID) }) else { throw ArchiveError.invalidIdentity }
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let known = Set(manifest.erasedMediaSources ?? []), incoming = Set(sources)
        guard !incoming.isSubset(of: known) else { return }
        let all = known.union(incoming)
        var next = manifest
        next.erasedMediaSources = Array(all)
        next.records = try next.records.map { try scrubbing($0, erasedMedia: all) }
        let scrubbedUndo = try undo.mapValues { try $0.map { try scrubbing($0, erasedMedia: all) } }
        try persist(&next)
        undo = scrubbedUndo
    }
    private func scrubbing(_ saved: RecoveredRecord, erasedMedia: Set<ArchiveMediaSourceIdentity>) throws -> RecoveredRecord {
        guard let media = saved.record.media else { return saved }
        let remaining = media.filter { !erasedMedia.contains(ArchiveMediaSourceIdentity(origin: saved.record.origin, mediaID: $0.id)) }
        guard remaining.count != media.count else { return saved }
        var record = saved.record
        record.media = remaining.isEmpty ? nil : remaining
        record.parentRevision = record.revision
        // The former receipt distinguishes different original projections.
        record.revision = "media-erasure/" + ArchiveCodec.digest(try ArchiveCodec.canonical([saved.receipt.digest, ArchiveCodec.digest(try ArchiveCodec.canonical(record))]))
        let receipt = try ArchiveCodec.receipt(record, projection: ArchiveCodec.projection(for: saved.documentKind), localCopyID: saved.id)
        return RecoveredRecord(receipt: receipt, record: record, documentKind: saved.documentKind, recoveredAtMilliseconds: saved.recoveredAtMilliseconds, backupLifetime: saved.backupLifetime)
    }
    public func discardUndo() { undo.removeAll() }
    /// Roll back only snapshots inserted by this reviewed batch; identical pre-existing
    /// copies survive. Removing receipts permits a later intentional import retry.
    public func undoImport(insertedCopyIDs: [String]) throws {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let ids = Set(insertedCopyIDs)
        var next = manifest
        next.records.removeAll { ids.contains($0.id) }
        guard next.records.count != manifest.records.count else { return }
        purgeBackups(&next, removedCopies: ids)
        try persist(&next)
    }
    private func acquireLock() throws -> Int32 {
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ArchiveError.unavailable }
        guard flock(descriptor, LOCK_EX) == 0 else { Darwin.close(descriptor); throw ArchiveError.unavailable }
        return descriptor
    }
    private func releaseLock(_ descriptor: Int32) { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    private func refreshFromDisk() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A previously committed store disappearing is not a fresh installation.
            // Never recreate cached text or bypass erasure markers after external deletion.
            guard manifest.generation == Self.emptyGeneration, manifest.encryptedBackups == nil else { throw ArchiveError.unavailable }
            return
        }
        manifest = try Self.readManifest(url)
    }
    private static func readManifest(_ url: URL) throws -> Manifest {
        let bytes = try boundedRead(url, maximum: maximumRegistryBytes)
        try ArchiveCodec.preflight(bytes, maximum: maximumRegistryBytes)
        var current: Manifest
        do { current = try JSONDecoder().decode(Manifest.self, from: bytes) } catch { throw ArchiveError.malformed }
        guard current.formatMajor == 1 else { throw ArchiveError.unsupportedVersion }
        var identities = Set<ArchiveIdentity>(), copies = Set<String>()
        let origins = Set(current.erasedOrigins ?? [])
        guard origins.allSatisfy(ArchiveCodec.identifier) else { throw ArchiveError.integrity }
        let sources = Set(current.erasedSources ?? [])
        guard sources.allSatisfy({ ArchiveCodec.identifier($0.origin) && ArchiveCodec.identifier($0.recordID) }) else { throw ArchiveError.integrity }
        let erasedMedia = Set(current.erasedMediaSources ?? [])
        guard erasedMedia.allSatisfy({ ArchiveCodec.identifier($0.origin) && ArchiveCodec.identifier($0.mediaID) }) else { throw ArchiveError.integrity }
        let erased = Set(current.erasedIdentities)
        guard erased.count == current.erasedIdentities.count else { throw ArchiveError.integrity }
        for identity in erased {
            guard ArchiveCodec.identifier(identity.origin), ArchiveCodec.identifier(identity.recordID),
                  ArchiveCodec.identifier(identity.revision),
                  ArchiveCodec.validProjectionDigest(identity.projection) else { throw ArchiveError.integrity }
        }
        for saved in current.records {
            guard identities.insert(saved.receipt.identity).inserted, copies.insert(saved.id).inserted,
                  ArchiveCodec.identifier(saved.id), !erased.contains(saved.receipt.identity), !origins.contains(saved.record.origin),
                  !sources.contains(ArchiveSourceIdentity(origin: saved.record.origin, recordID: saved.record.id)),
                  !(saved.record.media ?? []).contains(where: { erasedMedia.contains(ArchiveMediaSourceIdentity(origin: saved.record.origin, mediaID: $0.id)) }),
                  try ArchiveCodec.receipt(saved.record, projection: ArchiveCodec.projection(for: saved.documentKind), localCopyID: saved.id) == saved.receipt else { throw ArchiveError.integrity }
            _ = try ArchiveCodec.make(records: [saved.record], kind: saved.documentKind, origin: saved.record.origin, revision: saved.record.revision)
            if saved.documentKind == .helperShop, saved.record.nativePayload != nil { throw ArchiveError.integrity }
        }
        let ownerCopies = Dictionary(uniqueKeysWithValues: current.records.filter { $0.documentKind == .personalRecovery && $0.record.nativePayload != nil }.map { ($0.id, $0) })
        var marked = Set<ArchiveSourceIdentity>()
        for mark in current.encryptedBackups ?? [] {
            guard marked.insert(mark.source).inserted, !sources.contains(mark.source), !origins.contains(mark.source.origin),
                  ArchiveCodec.identifier(mark.source.origin), ArchiveCodec.identifier(mark.source.recordID), mark.savedAtMilliseconds > 0,
                  !mark.revisions.isEmpty, mark.revisions.count <= ArchiveCodec.maximumRecords,
                  mark.revisions.allSatisfy({ ArchiveCodec.identifier($0.revision) && $0.dependentCopyIDs.allSatisfy { ownerCopies[$0]?.record.origin == mark.source.origin } })
            else { throw ArchiveError.integrity }
            let byRevision = Dictionary(grouping: mark.revisions, by: \.revision)
            for (revision, duplicates) in byRevision where duplicates.count > 1 {
                // The development writer could save the plain revision with its copy
                // dependencies, then the same revision once per selected-media subset
                // without dependencies. Require the actual distinct receipts as evidence.
                let scoped = duplicates.filter { !$0.dependentCopyIDs.isEmpty }
                guard mark.usesBaseOwnerIdentity == nil, mark.couldHaveSelectedMedia,
                      scoped.count == 1 else { throw ArchiveError.integrity }
                let backing = scoped[0].dependentCopyIDs.compactMap { ownerCopies[$0] }.filter {
                    $0.record.id == mark.source.recordID && $0.record.revision == revision
                }
                guard let plain = backing.first(where: { $0.record.media == nil })?.record,
                      plain.kind == .ledger || plain.kind == .pickup else { throw ArchiveError.integrity }
                let selections = backing.filter { copy in
                    guard copy.record.media != nil else { return false }
                    var base = copy.record
                    base.media = nil
                    return base == plain
                }
                guard selections.count >= duplicates.count - 1 else { throw ArchiveError.integrity }
            }
        }
        // The first development format missed recovered-copy dependencies when the
        // file included media. Its marks omitted both the record kind and the selection.
        // Native records with selectable media used canonical shop/pickup UUIDs or
        // the separate meal-library ID. Undo Import can remove the last trace of a copy.
        let neverRecovered = current.generation == emptyGeneration && current.records.isEmpty && erased.isEmpty &&
            sources.isEmpty && origins.isEmpty && erasedMedia.isEmpty
        current.encryptedBackups = current.encryptedBackups?.compactMap { original in
            guard original.usesBaseOwnerIdentity != true else { return original }
            var mark = original
            if !neverRecovered && mark.couldHaveSelectedMedia {
                mark.revisions.removeAll { $0.dependentCopyIDs.isEmpty }
            }
            mark.usesBaseOwnerIdentity = true
            return mark.revisions.isEmpty ? nil : mark
        }
        return current
    }
    private func persist(_ next: inout Manifest, recoveryChanged: Bool = true) throws {
        if recoveryChanged { next.generation = UUID() }
        let bytes = try ArchiveCodec.canonical(next)
        guard bytes.count <= Self.maximumRegistryBytes else { throw ArchiveError.tooLarge }
        do {
            #if os(iOS)
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try bytes.write(to: url, options: .atomic)
            #endif
        } catch { throw ArchiveError.unavailable }
        manifest = next
    }
    public static func boundedRead(_ url: URL, maximum: Int = ArchiveCodec.maximumFileBytes) throws -> Data {
        guard url.isFileURL, maximum >= 0, maximum < Int.max else { throw ArchiveError.unavailable }
        // Refuse links during open and inspect that descriptor before reading. A
        // selected pipe must return immediately, even when it has no writer.
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ArchiveError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.unavailable }
        guard info.st_size <= maximum else { throw ArchiveError.tooLarge }
        var bytes = Data()
        do {
            while let chunk = try handle.read(upToCount: min(65536, maximum + 1 - bytes.count)), !chunk.isEmpty {
                bytes.append(chunk)
                if bytes.count > maximum { throw ArchiveError.tooLarge }
            }
        } catch let error as ArchiveError { throw error } catch { throw ArchiveError.unavailable }
        return bytes
    }
}

public enum ReadableArchive {
    public static func heading(_ record: ArchiveRecord, locale: Locale) -> String {
        let spanish = locale.language.languageCode?.identifier == "es"
        let saved = record.savedAtMilliseconds == 0
            ? (spanish ? "Fecha de guardado no indicada" : "Saved date not supplied")
            : (spanish ? "Guardado: " : "Saved: ") + Date(timeIntervalSince1970: Double(record.savedAtMilliseconds) / 1000).formatted(.iso8601)
        return [record.title, (spanish ? "Fuente: " : "Source: ") + record.origin,
                (spanish ? "Revisión: " : "Revision: ") + record.revision, saved].joined(separator: "\n")
    }

    public static func text(_ records: [ArchiveRecord], owner: Bool, locale: Locale = .current,
                            quantityText: (HelperLine) -> String = {
                                [$0.originalAmount, $0.originalUnit].filter { !$0.isEmpty }.joined(separator: " · ")
                            }) -> String {
        let spanish = locale.language.languageCode?.identifier == "es"
        return records.map { record in
            var lines = [heading(record, locale: locale)]
            if owner, record.kind == .recipe, let payload = record.nativePayload,
               let recipe = try? JSONDecoder().decode(ImportedRecipe.self, from: payload).validated() {
                if !recipe.yieldText.isEmpty { lines.append((spanish ? "Rinde: " : "Yield: ") + recipe.yieldText) }
                if !recipe.ingredients.isEmpty {
                    lines.append(spanish ? "Ingredientes" : "Ingredients")
                    lines += recipe.ingredients
                }
                if !recipe.steps.isEmpty {
                    lines.append(spanish ? "Preparación" : "Instructions")
                    lines += recipe.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
                }
                if !recipe.notes.isEmpty { lines.append((spanish ? "Notas: " : "Notes: ") + recipe.notes) }
                if let url = recipe.sourceURL, !url.isEmpty { lines.append((spanish ? "Enlace de la receta: " : "Recipe link: ") + url) }
                return lines.joined(separator: "\n")
            }
            lines += record.helperLines.map { line in
                [line.label, quantityText(line), line.purpose, line.action, line.foodStatus].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if owner, let bytes = record.nativePayload, let text = String(data: bytes, encoding: .utf8) { lines.append(text) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    public static func supportReport(error: ArchiveError?, recordCount: Int, locale: Locale = .current) -> String {
        let spanish = locale.language.languageCode?.identifier == "es"
        let formats = ArchiveCodec.supportedMinorVersions.map { "1.\($0)" }.joined(separator: ", ")
        let count = max(0, recordCount)
        let code = error.map { String(describing: $0) } ?? "ok"
        if spanish {
            return "Soporte de Room in the Cart\nFormatos compatibles: \(formats)\nNúmero de registros: \(count)\nEstado: \(code)"
        }
        return "Room in the Cart support\nSupported archive formats: \(formats)\nRecord count: \(count)\nStatus: \(code)"
    }
}
