import Foundation
import Darwin

public enum RecoveryDisposition: String, Codable, Sendable { case absent, identical, sibling, quarantined, erased }
public struct RecoveryReviewRow: Identifiable, Equatable, Sendable {
    public let id: ArchiveIdentity
    public let record: ArchiveRecord
    public let disposition: RecoveryDisposition
    public let existingCopyID: String?
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
}
public struct RecoveryCommit: Sendable {
    public let records: [RecoveredRecord]
    public let insertedCopyIDs: [String]
    public var insertedCount: Int { insertedCopyIDs.count }
}
public enum RecoveryDeleteScope: Sendable, Equatable {
    case copy(String), copies([String]), origin(String), allRecovered
}
public struct RecoveryUndoToken: Hashable, Sendable { public let id: UUID }

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
    public func review(_ envelope: ArchiveEnvelope) throws -> RecoveryReview {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        return try makeReview(envelope)
    }
    private func makeReview(_ envelope: ArchiveEnvelope) throws -> RecoveryReview {
        try ArchiveCodec.validate(envelope)
        let rows = try envelope.payload.records.map { record -> RecoveryReviewRow in
            let identity = ArchiveCodec.identity(record, projection: envelope.projectionID)
            let digest = ArchiveCodec.digest(try ArchiveCodec.canonical(record))
            let exact = manifest.records.first { $0.receipt.identity == identity }
            let related = manifest.records.first { $0.record.origin == record.origin && $0.record.id == record.id }
            let disposition: RecoveryDisposition
            if (manifest.erasedOrigins ?? []).contains(record.origin) || manifest.erasedIdentities.contains(identity) || (manifest.erasedSources ?? []).contains(ArchiveSourceIdentity(origin: record.origin, recordID: record.id)) || (record.media ?? []).contains(where: { (manifest.erasedMediaSources ?? []).contains(ArchiveMediaSourceIdentity(origin: record.origin, mediaID: $0.id)) }) { disposition = .erased }
            else if let exact { disposition = exact.receipt.digest == digest ? .identical : .quarantined }
            else { disposition = related == nil ? .absent : .sibling }
            return RecoveryReviewRow(id: identity, record: record, disposition: disposition, existingCopyID: exact?.id)
        }
        return RecoveryReview(envelope: envelope, rows: rows, registryGeneration: manifest.generation)
    }
    /// Call only after the domain adapter has validated every private native payload.
    /// No current record is replaced. A retry returns the previous local copy IDs.
    public func apply(_ reviewed: RecoveryReview, now: Date = Date()) throws -> RecoveryCommit {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let checked = try makeReview(reviewed.envelope)
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
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        try refreshFromDisk()
        let removed = manifest.records.filter { record in
            switch scope { case let .copy(id): return record.id == id; case let .copies(ids): return ids.contains(record.id); case let .origin(origin): return record.record.origin == origin; case .allRecovered: return true }
        }
        guard !removed.isEmpty else { throw ArchiveError.unavailable }
        let ids = Set(removed.map(\.id))
        var next = manifest
        next.records.removeAll { ids.contains($0.id) }
        next.erasedIdentities = Array(Set(next.erasedIdentities).union(removed.map(\.receipt.identity)))
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
            next.records.append(record)
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
        next.records.removeAll { all.contains(ArchiveSourceIdentity(origin: $0.record.origin, recordID: $0.record.id)) }
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
        return RecoveredRecord(receipt: receipt, record: record, documentKind: saved.documentKind, recoveredAtMilliseconds: saved.recoveredAtMilliseconds)
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
            guard manifest.generation == Self.emptyGeneration else { throw ArchiveError.unavailable }
            return
        }
        manifest = try Self.readManifest(url)
    }
    private static func readManifest(_ url: URL) throws -> Manifest {
        let bytes = try boundedRead(url, maximum: maximumRegistryBytes)
        try ArchiveCodec.preflight(bytes, maximum: maximumRegistryBytes)
        let current: Manifest
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
        return current
    }
    private func persist(_ next: inout Manifest) throws {
        next.generation = UUID()
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
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ArchiveError.unavailable }
        defer { try? handle.close() }
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

    public static func text(_ records: [ArchiveRecord], owner: Bool, locale: Locale = .current) -> String {
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
                [line.label, line.originalAmount, line.originalUnit, line.purpose, line.action, line.foodStatus].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
