import Foundation
import CryptoKit
import CoreDomain
import DeviceSurfaces
import Darwin

struct SurfaceImportScope: Codable, Equatable {
    let personaID: UUID
    let workspaceID: UUID
}
struct SurfaceImportAttempt: Codable, Equatable {
    let preview: StagedListImport
    let decisions: [UUID: ImportResolution]
}
struct SurfaceImportDraft: Codable, Equatable, Identifiable {
    enum Phase: String, Codable { case review, committing }
    var id: UUID { operationID }
    let operationID: UUID
    let inboxDigest: String
    let scope: SurfaceImportScope
    let originalText: String
    let editedText: String?
    let expiresAt: Date
    var preview: StagedListImport
    var decisions: [UUID: ImportResolution]
    var phase: Phase
    // Older journals contain the decided actions without tracking explicit separate choices.
    var explicitSeparate: Set<UUID>?
    var confirmedAttempts: [SurfaceImportAttempt] = []
}

/// App-private durable reviews. Full row identities and choices survive interruption;
/// the shared inbox contains neither this scope nor any ledger identity.
final class SurfaceImportJournal {
    private struct Document: Codable { let version: Int; let draft: SurfaceImportDraft }
    private let directory: URL
    init(directory: URL) throws {
        guard directory.isFileURL else { throw SurfaceError.invalid }
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        let fd = Darwin.open(directory.appendingPathComponent("journal.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SurfaceError.unavailable }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SurfaceError.unavailable }; defer { flock(fd, LOCK_UN) }
        return try action()
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func readUnlocked(_ id: UUID) throws -> SurfaceImportDraft? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes <= 1_048_576 else { throw SurfaceError.corrupt }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.version == 1 else { throw SurfaceError.unsupported }
        let result = document.draft
        try validate(result, id: id)
        return result
    }
    private func validate(_ result: SurfaceImportDraft, id: UUID) throws {
        guard result.id == id, result.preview.id == id, result.preview.source == .selectedText,
              result.preview.originalText == (result.editedText ?? result.originalText),
              result.inboxDigest == (try Self.digest(original: result.originalText, edited: result.editedText)),
              result.originalText.utf8.count + (result.editedText?.utf8.count ?? 0) <= SelectedTextInbox.maximumEntryBytes,
              !result.originalText.contains("\0"), result.editedText?.contains("\0") != true,
              result.preview.baseRevision >= 0, result.preview.lines.count <= SelectedTextInbox.maximumLines,
              Set(result.preview.lines.map(\.id)).count == result.preview.lines.count,
              Set(result.decisions.keys).isSubset(of: Set(result.preview.lines.map(\.id))),
              (result.explicitSeparate ?? []).allSatisfy({ result.decisions[$0] == .addNew }),
              result.confirmedAttempts.count <= 3,
              result.confirmedAttempts.allSatisfy({ $0.preview.id == result.id && $0.preview.shopID == result.preview.shopID && $0.preview.source == .selectedText && $0.preview.originalText == result.preview.originalText }),
              result.expiresAt.timeIntervalSince1970.isFinite else { throw SurfaceError.corrupt }
    }
    func read(_ id: UUID) throws -> SurfaceImportDraft? { try locked { try readUnlocked(id) } }
    func save(_ draft: SurfaceImportDraft, replacing expected: SurfaceImportDraft?, explicitlyRefreshed: Bool = false) throws {
        try validate(draft, id: draft.id)
        try locked {
            guard try readUnlocked(draft.id) == expected else { throw SurfaceError.stale }
            if let expected { guard expected.phase != .committing || expected == draft || explicitlyRefreshed else { throw SurfaceError.stale } }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            guard expected != nil || files.count < 20 else { throw SurfaceError.capacity }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(version: 1, draft: draft)); guard data.count <= 1_048_576 else { throw SurfaceError.capacity }
            #if os(iOS)
            try data.write(to: url(draft.id), options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url(draft.id), options: [.atomic])
            #endif
            let file = try FileHandle(forWritingTo: url(draft.id)); defer { try? file.close() }; try file.synchronize()
            guard try readUnlocked(draft.id) == draft else { throw SurfaceError.corrupt }
        }
    }
    func remove(_ id: UUID, expected: SurfaceImportDraft) throws {
        try locked {
            guard let actual = try readUnlocked(id) else { return }
            guard actual == expected else { throw SurfaceError.stale }
            try FileManager.default.removeItem(at: url(id))
        }
    }
    func entries(workspaceID: UUID) throws -> [SurfaceImportDraft] {
        try locked {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.compactMap { file in
                guard let operation = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let row = try readUnlocked(operation) else { throw SurfaceError.corrupt }
                return row.scope.workspaceID == workspaceID ? row : nil
            }
        }
    }
    func eraseWorkspace(_ id: UUID) throws {
        try locked {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let operation = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let row = try readUnlocked(operation) else { throw SurfaceError.corrupt }
                if row.scope.workspaceID == id { try FileManager.default.removeItem(at: file) }
            }
        }
    }
    func prune(pendingIDs: Set<UUID>, now: Date) throws {
        try locked {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let operation = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let row = try readUnlocked(operation) else { throw SurfaceError.corrupt }
                if row.expiresAt <= now || !pendingIDs.contains(operation) { try FileManager.default.removeItem(at: file) }
            }
        }
    }
    private static func digest(original: String, edited: String?) throws -> String {
        struct Body: Encodable { let original: String; let edited: String? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(Body(original: original, edited: edited))).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor protocol SurfaceLedgerPort: AnyObject {
    var scope: SurfaceImportScope? { get }
    var generation: UUID? { get }
    var hasPendingSave: Bool { get }
    func shop(_ id: UUID) -> ShoppingLedger?
    func stage(_ entry: SelectedTextEntry, shopID: UUID) throws -> StagedListImport
    func commit(_ draft: SurfaceImportDraft) async throws
    func reload() async throws
}

enum SurfaceImportDestinationConflict: Error {
    case replaceReview(SurfaceImportDraft)
    case recoverOriginalPickup
}

@MainActor final class SurfaceImportBridge {
    private let inbox: SelectedTextInbox
    private let journal: SurfaceImportJournal
    private let port: any SurfaceLedgerPort
    private let clock: () -> Date
    init(inbox: SelectedTextInbox, journal: SurfaceImportJournal, port: any SurfaceLedgerPort, clock: @escaping () -> Date = Date.init) {
        self.inbox = inbox; self.journal = journal; self.port = port; self.clock = clock
    }
    func open(_ entry: SelectedTextEntry, shopID: UUID, replacing reviewToReplace: SurfaceImportDraft? = nil) async throws -> SurfaceImportDraft? {
        guard let scope = port.scope, let generation = port.generation else { throw SurfaceError.unavailable }
        let current = try await inbox.pending(now: clock()).first { $0.id == entry.id }
        guard current == entry, port.scope == scope, port.generation == generation else { throw SurfaceError.stale }
        let previous = try journal.read(entry.id)
        if let reviewToReplace, previous != reviewToReplace { throw SurfaceError.stale }
        if let saved = previous {
            guard saved.scope == scope, saved.inboxDigest == entry.receipt.digest, saved.expiresAt == entry.receipt.expiresAt else { throw SurfaceError.stale }
            if let receipt = port.shop(saved.preview.shopID)?.importBatches.first(where: { $0.id == entry.id }) {
                try validate(receipt, draft: saved)
                _ = try await inbox.acknowledgeCommitted(operationID: entry.id, digest: saved.inboxDigest, now: clock())
                try journal.remove(saved.id, expected: saved)
                return nil
            }
            if saved.preview.shopID == shopID { return saved }
            // An attempt that might have reached the ledger must recover against its original pickup.
            guard saved.phase == .review, saved.confirmedAttempts.isEmpty else { throw SurfaceImportDestinationConflict.recoverOriginalPickup }
            guard reviewToReplace != nil else { throw SurfaceImportDestinationConflict.replaceReview(saved) }
        }
        // A receipt without its matching private journal cannot establish the inbox digest.
        guard port.shop(shopID)?.importBatches.contains(where: { $0.id == entry.id }) == false, !port.hasPendingSave else { throw SurfaceError.stale }
        let preview = try port.stage(entry, shopID: shopID)
        guard preview.id == entry.id else { throw SurfaceError.changedReplay }
        let draft = SurfaceImportDraft(operationID: entry.id, inboxDigest: entry.receipt.digest, scope: scope,
            originalText: entry.originalText, editedText: entry.editedText, expiresAt: entry.receipt.expiresAt, preview: preview,
            decisions: Dictionary(uniqueKeysWithValues: preview.lines.filter { $0.duplicateLineIDs.isEmpty }.map { ($0.id, .addNew) }), phase: .review)
        try journal.save(draft, replacing: previous)
        return draft
    }
    func saveReview(_ draft: SurfaceImportDraft, replacing previous: SurfaceImportDraft) throws {
        try validateReview(draft, replacing: previous)
        try journal.save(draft, replacing: previous)
    }
    /// Validate a sheet edit without making an unconfirmed choice durable.
    func validateReview(_ draft: SurfaceImportDraft, replacing previous: SurfaceImportDraft) throws {
        guard port.scope == draft.scope, port.generation != nil, !port.hasPendingSave, previous.phase == .review,
              draft.phase == .review, draft.id == previous.id, draft.inboxDigest == previous.inboxDigest,
              draft.scope == previous.scope, draft.confirmedAttempts == previous.confirmedAttempts, draft.originalText == previous.originalText, draft.editedText == previous.editedText,
              draft.preview.id == previous.preview.id, draft.preview.shopID == previous.preview.shopID,
              draft.preview.baseRevision == previous.preview.baseRevision, draft.preview.originalText == previous.preview.originalText,
              draft.preview.lines.map(\.id) == previous.preview.lines.map(\.id),
              draft.preview.lines.map(\.proposedLineID) == previous.preview.lines.map(\.proposedLineID),
              draft.preview.lines.map(\.originalText) == previous.preview.lines.map(\.originalText) else { throw SurfaceError.stale }
    }
    func commit(_ draft: SurfaceImportDraft) async throws {
        guard let generation = port.generation, port.scope == draft.scope, draft.expiresAt > clock(),
              let saved = try journal.read(draft.id), saved == draft else { throw SurfaceError.stale }
        let pending = try await inbox.pending(now: clock()).first { $0.id == draft.id }
        guard pending?.receipt.digest == draft.inboxDigest, port.generation == generation else { throw SurfaceError.stale }
        if let receipt = port.shop(draft.preview.shopID)?.importBatches.first(where: { $0.id == draft.id }) {
            try validate(receipt, draft: draft)
        } else {
            guard !port.hasPendingSave, draft.preview.lines.allSatisfy({ draft.decisions[$0.id] != nil }) else { throw SurfaceError.busy }
            var frozen = draft; frozen.phase = .committing
            if draft.phase == .review { try journal.save(frozen, replacing: draft) }
            try await port.commit(frozen)
            guard port.scope == draft.scope, port.generation == generation,
                  let receipt = port.shop(draft.preview.shopID)?.importBatches.first(where: { $0.id == draft.id }) else { throw SurfaceError.stale }
            try validate(receipt, draft: frozen)
        }
        guard port.generation == generation, port.scope == draft.scope else { throw SurfaceError.stale }
        _ = try await inbox.acknowledgeCommitted(operationID: draft.id, digest: draft.inboxDigest, now: clock())
        if let frozen = try journal.read(draft.id) { try journal.remove(draft.id, expected: frozen) }
    }
    /// Explicitly reload the authoritative ledger before refreshing stale review. Keep
    /// prior confirmed attempts so a racing successful receipt can still be recognized.
    func refreshReview(_ operationID: UUID) async throws -> SurfaceImportDraft? {
        guard let scope = port.scope, let generation = port.generation, let saved = try journal.read(operationID), saved.scope == scope else { throw SurfaceError.stale }
        try await port.reload()
        guard port.scope == scope, port.generation == generation, !port.hasPendingSave else { throw SurfaceError.stale }
        guard let entry = try await inbox.pending(now: clock()).first(where: { $0.id == operationID }), entry.receipt.digest == saved.inboxDigest,
              port.scope == scope, port.generation == generation else { throw SurfaceError.stale }
        if let receipt = port.shop(saved.preview.shopID)?.importBatches.first(where: { $0.id == operationID }) {
            try validate(receipt, draft: saved)
            _ = try await inbox.acknowledgeCommitted(operationID: operationID, digest: saved.inboxDigest, now: clock())
            try journal.remove(operationID, expected: saved); return nil
        }
        var fresh = saved
        if saved.phase == .committing {
            guard fresh.confirmedAttempts.count < 3 else { throw SurfaceError.capacity }
            fresh.confirmedAttempts.append(SurfaceImportAttempt(preview: saved.preview, decisions: saved.decisions))
        }
        fresh.preview = try port.stage(entry, shopID: saved.preview.shopID)
        fresh.explicitSeparate = nil
        fresh.decisions = Dictionary(uniqueKeysWithValues: fresh.preview.lines.filter { $0.duplicateLineIDs.isEmpty }.map { ($0.id, .addNew) })
        fresh.phase = .review
        try journal.save(fresh, replacing: saved, explicitlyRefreshed: true)
        return fresh
    }
    private func validate(_ receipt: LedgerImportBatch, draft: SurfaceImportDraft) throws {
        let recognized = (receipt.preview == draft.preview && receipt.decisions == draft.decisions)
            || draft.confirmedAttempts.contains(where: { $0.preview == receipt.preview && $0.decisions == receipt.decisions })
        guard receipt.id == draft.id, recognized else { throw SurfaceError.changedReplay }
        // An explicitly undone receipt still proves this operation happened. Never recreate it.
    }
}
