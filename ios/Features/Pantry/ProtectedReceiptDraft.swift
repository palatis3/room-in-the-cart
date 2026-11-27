import CoreDomain
import Darwin
import Foundation
import LocalStore

/// Only the resumable text and choices are archived. A preview, approval or attachment
/// is never sufficient authority to write stock after the editor has been reopened.
struct SavedReceiptDraft: Codable {
    enum Payload {
        case lines(ReceiptLineDraft)
        case putaway(ReceiptImportDraft)

        var sourceID: UUID {
            switch self {
            case .lines(let value): value.receiptID
            case .putaway(let value): value.draftID
            }
        }

        var workspaceID: UUID {
            switch self {
            case .lines(let value): value.workspaceID
            case .putaway(let value): value.workspaceID
            }
        }
    }
    let revision: UUID
    let payload: Payload

    private enum Storage: Codable {
        case lines(ReceiptLineDraft)
        case putaway(ReceiptPutawayDraftRecord)
    }
    private enum CodingKeys: String, CodingKey { case revision, payload }

    init(revision: UUID = UUID(), payload: Payload) {
        self.revision = revision; self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(UUID.self, forKey: .revision)
        switch try values.decode(Storage.self, forKey: .payload) {
        case .lines(let value):
            try value.validate()
            payload = .lines(value)
        case .putaway(let record):
            try record.validate()
            payload = .putaway(ReceiptImportDraft(protectedDraft: record))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        switch payload {
        case .lines(let value):
            try value.validate()
            try values.encode(Storage.lines(value), forKey: .payload)
        case .putaway(let value):
            let record = ReceiptPutawayDraftRecord(value)
            try record.validate()
            try values.encode(Storage.putaway(record), forKey: .payload)
        }
    }
}

private struct ReceiptPutawayDraftRecord: Codable {
    struct Row: Codable {
        let id: UUID
        let ordinal: Int
        let original: String
        let document: ReceiptAcquisition.DocumentLine?
        let printed: ReceiptPrintedEvidence?
        let name: String
        let treatment: ReceiptImportDraft.Treatment
        let received: String
        let usable: String
        let unit: UnitOfMeasure
        let location: InventoryLocation
        let paid: String
    }
    let draftID: UUID
    let workspaceID: UUID
    let savedPickup: ReceiptAcquisition.SavedPickup?
    let digest: Data?
    let sectionDigest: Data?
    let layout: UUID?
    let supportsRescan: Bool
    let merchant: String
    let reference: String
    let language: String
    let currency: Currency
    let tracksPutaway: Bool
    let receiptTotal: String
    let purchaseDate: Date
    let zone: String?
    let lines: [Row]

    init(_ draft: ReceiptImportDraft) {
        draftID = draft.draftID; workspaceID = draft.workspaceID; savedPickup = draft.savedPickup
        digest = draft.imageDigest; sectionDigest = draft.firstSectionDigest; layout = draft.documentLayoutID
        supportsRescan = draft.supportsRescan; merchant = draft.merchant; reference = draft.reference
        language = draft.language; currency = draft.currency; tracksPutaway = draft.tracksPutaway
        receiptTotal = draft.receiptTotal; purchaseDate = draft.purchaseDate
        zone = draft.purchaseTimeZone?.identifier
        lines = draft.lines.map { line in
            let treatment: ReceiptImportDraft.Treatment
            if case .link = line.treatment { treatment = .skip } else { treatment = line.treatment }
            return Row(id: line.id, ordinal: line.ordinal, original: line.original, document: line.documentLine,
                       printed: line.printed, name: line.name, treatment: treatment, received: line.received,
                       usable: line.usable, unit: line.unit, location: line.location, paid: line.paid)
        }
    }

    func validate() throws {
        func fits(_ value: String, _ limit: Int) -> Bool { value.utf8.count <= limit && !value.contains("\0") }
        guard (1...200).contains(lines.count), Set(lines.map(\.id)).count == lines.count,
              Set(lines.map(\.ordinal)).count == lines.count,
              savedPickup.map({ $0.originID == workspaceID }) ?? true,
              [digest, sectionDigest].compactMap({ $0 }).allSatisfy({ $0.count == 32 }),
              fits(merchant, 512), fits(reference, 512), fits(language, 20), fits(receiptTotal, 80),
              purchaseDate.timeIntervalSinceReferenceDate.isFinite,
              zone.map({ TimeZone(identifier: $0) != nil }) ?? true else { throw ProtectedReceiptDraftStore.Failure.invalid }
        for row in lines {
            guard row.ordinal >= 0, fits(row.original, 4096), fits(row.name, 2048),
                  fits(row.received, 80), fits(row.usable, 80), fits(row.paid, 80),
                  row.document.map({ $0.ordinal == row.ordinal }) ?? true else { throw ProtectedReceiptDraftStore.Failure.invalid }
            if case .link = row.treatment { throw ProtectedReceiptDraftStore.Failure.invalid }
        }
    }
}

extension ReceiptImportDraft {
    fileprivate init(protectedDraft record: ReceiptPutawayDraftRecord) {
        draftID = record.draftID; workspaceID = record.workspaceID; savedPickup = record.savedPickup
        imageDigest = record.digest; documentLayoutID = record.layout; firstSectionDigest = record.sectionDigest
        supportsRescan = record.supportsRescan; merchant = record.merchant; reference = record.reference
        language = record.language; currency = record.currency; tracksPutaway = record.tracksPutaway
        receiptTotal = record.receiptTotal; purchaseDate = record.purchaseDate
        purchaseTimeZone = record.zone.flatMap(TimeZone.init(identifier:)); dateConfirmed = false
        lines = record.lines.map { row in
            Line(id: row.id, ordinal: row.ordinal, original: row.original, documentLine: row.document,
                 printed: row.printed, sourceName: row.printed?.name, name: row.name, treatment: row.treatment,
                 received: row.received, usable: row.usable, unit: row.unit, location: row.location, paid: row.paid)
        }
    }
}

/// One device-only slot per adult and inventory origin. No app extension shares this directory.
/// The filesystem lock makes version comparison and atomic replacement one operation.
@MainActor final class ProtectedReceiptDraftStore {
    enum Failure: Error, Equatable { case invalid, changed, unavailable }
    struct Scope: Equatable {
        let origin: UUID
        let owner: UUID
    }
    struct Pending: Codable, Equatable {
        let operation: UUID
        let request: Data
    }
    struct Entry: Codable {
        let version: Int
        let origin: UUID
        let owner: UUID
        let draft: SavedReceiptDraft
        var finishing: Pending?
    }
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private let maximum = 1_048_576

    private func path(_ scope: Scope) -> URL {
        directory.appendingPathComponent(scope.origin.uuidString + "-" + scope.owner.uuidString + ".draft")
    }

    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalid }
            return true
        }
        guard errno == ENOENT else { throw Failure.unavailable }
        return false
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        try PantryArchiveFiles.directory(directory, create: true)
        let url = directory.appendingPathComponent("receipt-drafts.lock")
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        try PantryArchiveFiles.protect(url, permissions: 0o600)
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.unavailable }
        defer { flock(fd, LOCK_UN) }
        // A terminated process may have protected its replacement but not renamed it.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "new" {
            try FileManager.default.removeItem(at: file)
        }
        return try work()
    }

    private func readUnlocked(_ scope: Scope) throws -> Entry? {
        let url = path(scope)
        guard try exists(url) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: PantryArchiveFiles.read(url, maximum: maximum))
        guard entry.version == 1, entry.origin == scope.origin, entry.owner == scope.owner,
              entry.draft.payload.workspaceID == scope.origin,
              entry.finishing.map({ $0.request.count == 32 }) ?? true else { throw Failure.invalid }
        return entry
    }

    private func write(_ value: Entry, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximum else { throw Failure.invalid }
        // Protect and flush the temporary file before making it the current version.
        let temp = url.appendingPathExtension(UUID().uuidString + ".new")
        defer { try? FileManager.default.removeItem(at: temp) }
        try PantryArchiveFiles.write(data, to: temp)
        guard Darwin.rename(temp.path, url.path) == 0 else { throw Failure.unavailable }
    }

    func read(_ scope: Scope) throws -> Entry? {
        guard try exists(path(scope)) else { return nil }
        return try locked { try readUnlocked(scope) }
    }

    func replace(_ payload: SavedReceiptDraft.Payload, expected: UUID?, scope: Scope) throws -> SavedReceiptDraft {
        try locked {
            guard payload.workspaceID == scope.origin else { throw Failure.invalid }
            let before = try readUnlocked(scope)
            guard before?.draft.revision == expected, before?.finishing == nil else { throw Failure.changed }
            let new = SavedReceiptDraft(payload: payload)
            try write(Entry(version: 1, origin: scope.origin, owner: scope.owner, draft: new), to: path(scope))
            guard let saved = try readUnlocked(scope) else { throw Failure.unavailable }
            return saved.draft
        }
    }

    func mark(_ scope: Scope, revision: UUID, expected: Pending?, next: Pending?) throws {
        try locked {
            guard var entry = try readUnlocked(scope), entry.draft.revision == revision, entry.finishing == expected else { throw Failure.changed }
            entry.finishing = next
            try write(entry, to: path(scope))
        }
    }

    func remove(_ scope: Scope, revision: UUID, finishing: Pending? = nil) throws {
        try locked {
            guard let entry = try readUnlocked(scope), entry.draft.revision == revision, entry.finishing == finishing else { throw Failure.changed }
            try FileManager.default.removeItem(at: path(scope))
        }
    }

    func erase(origin: UUID) throws {
        try locked {
            let prefix = origin.uuidString + "-"
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix(prefix) && ["draft", "new"].contains(file.pathExtension) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
