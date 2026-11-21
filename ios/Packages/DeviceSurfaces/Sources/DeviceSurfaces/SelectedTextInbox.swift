import Foundation
import CDeviceSQLite
import CryptoKit
import UniformTypeIdentifiers

public enum InboxDisposition: String, Codable, Sendable { case pending, consumed, discarded, expired }
public struct InboxReceipt: Equatable, Sendable {
    public let operationID: UUID
    public let digest: String
    public let createdAt: Date
    public let expiresAt: Date
    public let disposition: InboxDisposition

    /// Older app-private reviews saved SQLite's 15-significant-digit rendering of the deadline.
    public func matchesRecordedExpiry(_ recorded: Date) -> Bool {
        if recorded == expiresAt { return true }
        let text = withVaList([expiresAt.timeIntervalSince1970]) { sqlite3_vmprintf("%!.15g", $0) }
        guard let text else { return false }
        defer { sqlite3_free(text) }
        guard let seconds = Double(String(cString: text)) else { return false }
        return recorded == Date(timeIntervalSince1970: seconds)
    }
}
public struct SelectedTextEntry: Equatable, Sendable, Identifiable {
    public var id: UUID { receipt.operationID }
    public let receipt: InboxReceipt
    public let originalText: String
    public let editedText: String?
    public var textForReview: String { editedText ?? originalText }
}

/// Stores bounded text with deduplication receipts. The shopping-list inbox and
/// the typed capture inbox have distinct database kinds and files.
public actor SelectedTextInbox {
    public enum ReviewLimit: Error { case tooManyItems, receiptLimitReached }
    public static let maximumEntryBytes = 65_536
    public static let maximumLines = 500
    public static let maximumPending = 20
    public static let maximumTotalBytes = 1_048_576
    public static let maximumReceipts = 10_000
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    let database: SurfaceDatabase
    public init(url: URL) throws {
        try self.init(url: url, kind: "selected-text-inbox")
    }
    init(url: URL, kind: String) throws {
        database = try SurfaceDatabase(url: url, kind: kind, schema: """
        CREATE TABLE inbox (id TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL, original TEXT, edited TEXT,
        bytes INTEGER NOT NULL CHECK(bytes >= 0), created REAL NOT NULL, expires REAL NOT NULL,
        disposition TEXT NOT NULL CHECK(disposition IN ('pending','consumed','discarded','expired')));
        """)
        if kind == "shared-capture-inbox" { try Self.installReceiptStorage(database) }
    }
    public func stage(operationID: UUID, originalText: String, editedText: String? = nil, now: Date) throws -> InboxReceipt {
        try stage(operationID: operationID, originalText: originalText, editedText: editedText, now: now, insertAttachment: {})
    }

    func stage(operationID: UUID, originalText: String, editedText: String?, now: Date,
               insertAttachment: () throws -> Void) throws -> InboxReceipt {
        guard validDate(now), validDate(now.addingTimeInterval(Self.lifetime)) else { throw SurfaceError.invalid }
        let digest = try Self.digest(original: originalText, edited: editedText)
        return try database.transaction {
            try expire(now)
            if let existing = try receipt(operationID) {
                guard existing.digest == digest else { throw SurfaceError.changedReplay }
                return existing
            }
            // Prior receipts bind the original and edited text, even if this wording
            // could not open a ledger review. Apply fresh limits only to new writes.
            try Self.validateReviewItems(editedText ?? originalText)
            let counts = try database.rows("SELECT COUNT(*), COALESCE(SUM(CASE WHEN disposition='pending' THEN 1 ELSE 0 END),0), COALESCE(SUM(bytes),0) FROM inbox")[0]
            guard let all = Int(counts[0] ?? ""), let pending = Int(counts[1] ?? ""), let bytes = Int(counts[2] ?? "") else { throw SurfaceError.corrupt }
            let size = originalText.utf8.count + (editedText?.utf8.count ?? 0)
            guard all < Self.maximumReceipts else { throw ReviewLimit.receiptLimitReached }
            guard pending < Self.maximumPending, bytes <= Self.maximumTotalBytes - size else { throw SurfaceError.capacity }
            try database.execute("INSERT INTO inbox VALUES(?,?,?,?,?,?,?,?)", [.text(operationID.uuidString), .text(digest), .text(originalText), editedText.map(DBValue.text) ?? .null, .integer(Int64(size)), .double(now.timeIntervalSince1970), .double(now.addingTimeInterval(Self.lifetime).timeIntervalSince1970), .text(InboxDisposition.pending.rawValue)])
            try insertAttachment()
            guard let saved = try receipt(operationID) else { throw SurfaceError.corrupt }; return saved
        }
    }
    public func pending(now: Date) throws -> [SelectedTextEntry] {
        guard validDate(now) else { throw SurfaceError.invalid }
        return try database.transaction {
            try expire(now)
            return try database.rows("SELECT id,digest,created,expires,disposition,original,edited FROM inbox WHERE disposition='pending' ORDER BY created,id").map { row in
                let receipt = try decodeReceipt(Array(row.prefix(5)))
                guard let original = row[5], try Self.digest(original: original, edited: row[6]) == receipt.digest else { throw SurfaceError.corrupt }
                return SelectedTextEntry(receipt: receipt, originalText: original, editedText: row[6])
            }
        }
    }
    /// Call only after the containing app has durably committed or reopened its import receipt.
    public func acknowledgeCommitted(operationID: UUID, digest: String, now: Date) throws -> InboxReceipt {
        try transition(operationID, digest: digest, to: .consumed, now: now)
    }
    public func discard(operationID: UUID, digest: String, now: Date) throws -> InboxReceipt {
        try transition(operationID, digest: digest, to: .discarded, now: now)
    }
    public func receipt(_ id: UUID) throws -> InboxReceipt? {
        try database.rows("SELECT id,digest,created,expires,disposition FROM inbox WHERE id=?", [.text(id.uuidString)]).first.map(decodeReceipt)
    }
    private func transition(_ id: UUID, digest: String, to state: InboxDisposition, now: Date) throws -> InboxReceipt {
        guard validDate(now) else { throw SurfaceError.invalid }
        return try database.transaction {
            try expire(now)
            guard let existing = try receipt(id), existing.digest == digest else { throw SurfaceError.changedReplay }
            if existing.disposition == state { return existing }
            guard existing.disposition == .pending else { throw SurfaceError.stale }
            try database.execute("UPDATE inbox SET disposition=?,original=NULL,edited=NULL,bytes=0 WHERE id=?", [.text(state.rawValue), .text(id.uuidString)])
            return try receipt(id)!
        }
    }
    func expire(_ now: Date) throws {
        try database.execute("UPDATE inbox SET disposition='expired',original=NULL,edited=NULL,bytes=0 WHERE disposition='pending' AND expires <= ?", [.double(now.timeIntervalSince1970)])
    }
    private func decodeReceipt(_ row: [String?]) throws -> InboxReceipt {
        guard row.count == 5, let id = UUID(uuidString: row[0] ?? ""), let digest = row[1], digest.count == 64,
              let created = Double(row[2] ?? ""), let expires = Double(row[3] ?? ""),
              let disposition = InboxDisposition(rawValue: row[4] ?? "") else { throw SurfaceError.corrupt }
        let a = Date(timeIntervalSince1970: created), b = Date(timeIntervalSince1970: expires)
        guard validDate(a), validDate(b), b > a else { throw SurfaceError.corrupt }
        return InboxReceipt(operationID: id, digest: digest, createdAt: a, expiresAt: b, disposition: disposition)
    }
    public static func fitsEnvelope(original: String, edited: String? = nil) -> Bool {
        let remaining = maximumEntryBytes - original.utf8.count
        guard remaining >= 0, (edited?.utf8.count ?? 0) <= remaining else { return false }
        func fitsSourceLines(_ text: String) -> Bool {
            text.lazy.filter { $0 == "\n" }.prefix(maximumLines).count < maximumLines
        }
        return fitsSourceLines(original) && (edited.map(fitsSourceLines) ?? true)
    }

    private static func validateReviewItems(_ text: String) throws {
        // The ledger recognizes CRLF, bare CR and Unicode newline scalars as well as LF.
        var items = 0
        var atStart = true
        for scalar in text.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) { atStart = true }
            else if atStart && !CharacterSet.whitespaces.contains(scalar) {
                items += 1
                guard items <= maximumLines else { throw ReviewLimit.tooManyItems }
                atStart = false
            }
        }
    }

    private static func digest(original: String, edited: String?) throws -> String {
        guard fitsEnvelope(original: original, edited: edited), !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !original.contains("\0"), edited?.contains("\0") != true,
              edited == nil || !edited!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SurfaceError.invalid }
        struct Body: Encodable { let original: String; let edited: String? }
        return SHA256.hash(data: try canonical(Body(original: original, edited: edited))).map { String(format: "%02x", $0) }.joined()
    }
}

/// A byte-order hint is needed only when the provider declares UTF-16 without a byte-order mark.
public enum UnmarkedUTF16: String, Codable, Sendable {
    case littleEndian, bigEndian

    public init?(data: Data, type: UTType?) {
        guard !Self.hasMark(data) else { return nil }
        if type == .utf16PlainText { self = .littleEndian }
        else if type == .utf16ExternalPlainText { self = .bigEndian }
        else { return nil }
    }

    fileprivate static func hasMark(_ bytes: Data) -> Bool {
        bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
    }
}

public func decodePlainTextFile(_ bytes: Data, unmarkedUTF16: UnmarkedUTF16? = nil) -> String? {
    if bytes.starts(with: [0xef, 0xbb, 0xbf]) {
        // Interpret exactly one encoding marker even when Foundation's UTF-8
        // decoder keeps it. The round trip rejects repaired invalid UTF-8.
        let payload = bytes.dropFirst(3)
        let wording = String(decoding: payload, as: UTF8.self)
        return wording.utf8.elementsEqual(payload) ? wording : nil
    }
    let hasMark = UnmarkedUTF16.hasMark(bytes)
    if hasMark || unmarkedUTF16 != nil {
        // Foundation can discard a trailing half of a UTF-16 code unit.
        guard bytes.count.isMultiple(of: 2) else { return nil }
        let encoding: String.Encoding
        if hasMark { encoding = .utf16 }
        else { encoding = unmarkedUTF16 == .littleEndian ? .utf16LittleEndian : .utf16BigEndian }
        return String(data: bytes, encoding: encoding)
    }
    return String(data: bytes, encoding: .utf8)
}

extension SelectedTextInbox {
    public static func loadSelectedText(from item: NSExtensionItem,
                                        completion: @escaping @Sendable (Result<String, SurfaceError>) -> Void) {
        if let text = item.attributedContentText?.string,
           text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil {
            guard fitsEnvelope(original: text) else { completion(.failure(.capacity)); return }
            guard !text.contains("\0") else { completion(.failure(.invalid)); return }
            completion(.success(text))
            return
        }
        let providers = (item.attachments ?? []).filter {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        guard providers.count == 1 else { completion(.failure(.unsupported)); return }
        loadPlainText(from: providers[0], completion: completion)
    }

    /// Consume the system's temporary copy inside the provider callback.
    public static func loadPlainText(from provider: NSItemProvider,
                                     completion: @escaping @Sendable (Result<String, SurfaceError>) -> Void) {
        guard let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) })
            .first(where: { $0.conforms(to: .plainText) }) else {
            completion(.failure(.unsupported))
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
            guard error == nil, let url, url.isFileURL else { completion(.failure(.unavailable)); return }
            do { completion(.success(try readPlainText(at: url, type: type))) }
            catch { completion(.failure(error as? SurfaceError ?? .unavailable)) }
        }
    }

    static func readPlainText(at url: URL, type: UTType) throws -> String {
        try decodePlainText(readRegularFile(at: url, maximumBytes: maximumEntryBytes), type: type)
    }

    public static func decodePlainText(_ bytes: Data, type: UTType) throws -> String {
        guard type.conforms(to: .plainText) else { throw SurfaceError.unsupported }
        guard bytes.count <= maximumEntryBytes else { throw SurfaceError.capacity }
        guard let text = decodePlainTextFile(bytes, unmarkedUTF16: UnmarkedUTF16(data: bytes, type: type)),
              text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil,
              !text.contains("\0") else { throw SurfaceError.invalid }
        guard fitsEnvelope(original: text) else { throw SurfaceError.capacity }
        return text
    }
}

/// Cancellation is a volatile extension-session operation and cannot write a confirmed line.
public actor SelectedTextSession {
    public enum State: Equatable, Sendable { case editing, saving, staged(InboxReceipt), cancelled }
    public let operationID: UUID
    private var state: State = .editing
    public init(operationID: UUID = UUID()) { self.operationID = operationID }
    public func currentState() -> State { state }
    public func cancel() throws { guard state == .editing else { throw SurfaceError.busy }; state = .cancelled }
    public func save(original: String, edited: String?, now: Date, inbox: SelectedTextInbox) async throws -> InboxReceipt {
        let previous = state
        switch state {
        case .editing, .staged: break
        case .cancelled: throw SurfaceError.cancelled
        case .saving: throw SurfaceError.busy
        }
        state = .saving
        do { let receipt = try await inbox.stage(operationID: operationID, originalText: original, editedText: edited, now: now); state = .staged(receipt); return receipt }
        catch { state = previous; throw error }
    }
}
