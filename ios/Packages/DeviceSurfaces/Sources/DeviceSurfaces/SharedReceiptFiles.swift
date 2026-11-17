import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct SharedReceiptDescriptor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case pdf, image, text }
    public static let maximumBytes = 10_000_000
    public let id: UUID
    public let kind: Kind
    public let size: Int
    public let fileDigest: String

    init(id: UUID, kind: Kind, data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw SurfaceError.capacity }
        self.id = id; self.kind = kind; size = data.count; fileDigest = Self.digest(data)
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SharedReceiptScope: Equatable, Sendable {
    public let origin: UUID
    public let persona: UUID
    public init(origin: UUID, persona: UUID) { self.origin = origin; self.persona = persona }
}

public struct SharedReceiptItem: Identifiable, Equatable, Sendable {
    public var id: UUID { descriptor.id }
    public let descriptor: SharedReceiptDescriptor
    public let receipt: InboxReceipt
}

public struct SharedReceiptRetirement: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let receiptDigest: String
    public let fileDigest: String
    public let unclaimed: Bool?
}

extension SharedCaptureInbox {
    public func expireReceipts(now: Date) async throws { try await storage.sweepReceiptExpiry(now) }

    public func stageReceipt(_ bytes: Data, kind: SharedReceiptDescriptor.Kind, id: UUID, now: Date) async throws -> InboxReceipt {
        let descriptor = try SharedReceiptDescriptor(id: id, kind: kind, data: bytes)
        return try await storage.stageReceipt(bytes, descriptor: descriptor, now: now)
    }
    public func pendingReceiptFiles(scope: SharedReceiptScope, now: Date) async throws -> [SharedReceiptItem] {
        try await storage.pendingReceiptFiles(scope: scope, now: now)
    }
    public func openReceipt(_ item: SharedReceiptItem, scope: SharedReceiptScope, now: Date) async throws -> Data {
        try await storage.openReceipt(item, scope: scope, now: now)
    }
    public func finishReceipt(_ item: SharedReceiptItem, scope: SharedReceiptScope, committed: Bool, now: Date) async throws {
        try await storage.finishReceipt(item, scope: scope, committed: committed, now: now)
    }
    public func receiptErasureCandidates(origin: UUID, now: Date) async throws -> [SharedReceiptRetirement] {
        try await storage.receiptErasureCandidates(origin: origin, now: now)
    }
    public func retireReceipts(_ clips: [SharedReceiptRetirement], origin: UUID, now: Date) async throws {
        try await storage.retireReceipts(clips, origin: origin, now: now)
    }
}

extension SelectedTextInbox {
    func sweepReceiptExpiry(_ now: Date) throws {
        guard validDate(now) else { throw SurfaceError.invalid }
        try database.transaction { try expire(now) }
    }

    static func installReceiptStorage(_ db: SurfaceDatabase) throws {
        try db.transaction {
            try db.script("""
            CREATE TABLE IF NOT EXISTS receipt_file (
                id TEXT PRIMARY KEY REFERENCES inbox(id) ON DELETE CASCADE, kind TEXT NOT NULL,
                digest TEXT NOT NULL CHECK(length(digest)=64), bytes INTEGER NOT NULL CHECK(bytes BETWEEN 1 AND 10000000),
                origin TEXT, persona TEXT, CHECK((origin IS NULL)=(persona IS NULL)));
            CREATE TABLE IF NOT EXISTS receipt_bytes (
                id TEXT NOT NULL REFERENCES receipt_file(id) ON DELETE CASCADE,
                position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 39),
                chunk BLOB NOT NULL CHECK(typeof(chunk)='blob' AND length(chunk) BETWEEN 1 AND 262144), PRIMARY KEY(id,position));
            CREATE TRIGGER IF NOT EXISTS release_shared_receipt AFTER UPDATE OF disposition ON inbox
                WHEN NEW.disposition != 'pending' BEGIN DELETE FROM receipt_file WHERE id=NEW.id; END;
            """)
        }
    }

    func stageReceipt(_ bytes: Data, descriptor: SharedReceiptDescriptor, now: Date) throws -> InboxReceipt {
        let envelope = try SharedCaptureEnvelope(receipt: descriptor)
        return try stage(operationID: descriptor.id, originalText: String(decoding: canonical(envelope), as: UTF8.self),
            editedText: nil, now: now) {
            let used = try database.rows("SELECT COALESCE(sum(bytes),0) FROM receipt_file").first?.first ?? nil
            guard let used, let total = Int(used), total <= 20_000_000 - bytes.count else { throw SurfaceError.capacity }
            let id = DBValue.text(descriptor.id.uuidString)
            try database.execute("INSERT INTO receipt_file(id,kind,digest,bytes) VALUES(?,?,?,?)",
                [id, .text(descriptor.kind.rawValue), .text(descriptor.fileDigest), .integer(Int64(bytes.count))])
            for start in stride(from: 0, to: bytes.count, by: 262_144) {
                try database.execute("INSERT INTO receipt_bytes(id,position,chunk) VALUES(?,?,?)",
                    [id, .integer(Int64(start / 262_144)), .blob(bytes.subdata(in: start..<min(start + 262_144, bytes.count)))])
            }
        }
    }

    func pendingReceiptFiles(scope: SharedReceiptScope, now: Date) throws -> [SharedReceiptItem] {
        guard validDate(now) else { throw SurfaceError.invalid }
        return try database.transaction {
            try expire(now)
            let rows = try database.rows("""
                SELECT r.id,i.original FROM receipt_file r JOIN inbox i ON i.id=r.id
                WHERE i.disposition='pending' AND (r.origin IS NULL OR (r.origin=? AND r.persona=?))
                ORDER BY i.created,r.id LIMIT 21
                """, [.text(scope.origin.uuidString), .text(scope.persona.uuidString)])
            guard rows.count <= Self.maximumPending else { throw SurfaceError.corrupt }
            return try rows.map { row in
                guard let text = row[1] else { throw SurfaceError.corrupt }
                let envelope = try JSONDecoder().decode(SharedCaptureEnvelope.self, from: Data(text.utf8))
                guard envelope.version == 1, envelope.kind == .receiptFile else { throw SurfaceError.corrupt }
                let descriptor = try JSONDecoder().decode(SharedReceiptDescriptor.self, from: Data(envelope.value.utf8))
                guard descriptor.id.uuidString == row[0], (1...SharedReceiptDescriptor.maximumBytes).contains(descriptor.size),
                      let receipt = try receipt(descriptor.id), receipt.disposition == .pending else { throw SurfaceError.corrupt }
                return SharedReceiptItem(descriptor: descriptor, receipt: receipt)
            }
        }
    }

    func openReceipt(_ item: SharedReceiptItem, scope: SharedReceiptScope, now: Date) throws -> Data {
        guard validDate(now), (1...SharedReceiptDescriptor.maximumBytes).contains(item.descriptor.size) else { throw SurfaceError.invalid }
        return try database.transaction {
            try expire(now)
            guard try receipt(item.id) == item.receipt, item.receipt.disposition == .pending else { throw SurfaceError.stale }
            try claim(item, scope: scope)
            let bytes = try database.joinedBlobs("SELECT chunk FROM receipt_bytes WHERE id=? ORDER BY position", [.text(item.id.uuidString)],
                expected: item.descriptor.size, chunkLimit: 262_144)
            guard SharedReceiptDescriptor.digest(bytes) == item.descriptor.fileDigest else { throw SurfaceError.corrupt }
            return bytes
        }
    }

    private func claim(_ item: SharedReceiptItem, scope: SharedReceiptScope, allowUnclaimed: Bool = true) throws {
        let origin = DBValue.text(scope.origin.uuidString), persona = DBValue.text(scope.persona.uuidString)
        guard try database.execute("""
            UPDATE receipt_file SET origin=?,persona=? WHERE id=? AND digest=? AND kind=? AND bytes=?
            AND ((?=1 AND origin IS NULL) OR (origin=? AND persona=?))
            """, [origin, persona, .text(item.id.uuidString), .text(item.descriptor.fileDigest), .text(item.descriptor.kind.rawValue),
                  .integer(Int64(item.descriptor.size)), .integer(allowUnclaimed ? 1 : 0), origin, persona]) == 1 else { throw SurfaceError.stale }
    }

    func finishReceipt(_ item: SharedReceiptItem, scope: SharedReceiptScope, committed: Bool, now: Date) throws {
        guard validDate(now) else { throw SurfaceError.invalid }
        try database.transaction {
            try expire(now)
            guard let current = try receipt(item.id), current.digest == item.receipt.digest else { throw SurfaceError.stale }
            let next: InboxDisposition = committed ? .consumed : .discarded
            if current.disposition == next { return }
            guard current.disposition == .pending else { throw SurfaceError.stale }
            try claim(item, scope: scope, allowUnclaimed: !committed)
            try database.execute("UPDATE inbox SET disposition=?,original=NULL,edited=NULL,bytes=0 WHERE id=?",
                [.text(next.rawValue), .text(item.id.uuidString)])
        }
    }

    func receiptErasureCandidates(origin: UUID, now: Date) throws -> [SharedReceiptRetirement] {
        guard validDate(now) else { throw SurfaceError.invalid }
        return try database.transaction {
            try expire(now)
            return try database.rows("""
                SELECT r.id,i.digest,r.digest,r.origin FROM receipt_file r JOIN inbox i ON i.id=r.id
                WHERE (r.origin=? OR r.origin IS NULL) AND i.disposition='pending' ORDER BY r.id
                """, [.text(origin.uuidString)]).map { row in
                    guard let id = UUID(uuidString: row[0] ?? ""), let token = row[1], let digest = row[2] else { throw SurfaceError.corrupt }
                    return SharedReceiptRetirement(id: id, receiptDigest: token, fileDigest: digest, unclaimed: row[3] == nil ? true : nil)
                }
        }
    }

    func retireReceipts(_ clips: [SharedReceiptRetirement], origin: UUID, now: Date) throws {
        guard validDate(now), clips.count <= Self.maximumPending else { throw SurfaceError.invalid }
        try database.transaction {
            try expire(now)
            for clip in clips {
                guard let existing = try receipt(clip.id), existing.digest == clip.receiptDigest else { throw SurfaceError.stale }
                guard existing.disposition == .pending else { continue }
                guard try database.execute("""
                    UPDATE inbox SET disposition='discarded',original=NULL,edited=NULL,bytes=0
                    WHERE id=? AND EXISTS(SELECT 1 FROM receipt_file WHERE id=? AND (origin=? OR (?=1 AND origin IS NULL)) AND digest=?)
                    """, [.text(clip.id.uuidString), .text(clip.id.uuidString), .text(origin.uuidString), .integer(clip.unclaimed == true ? 1 : 0), .text(clip.fileDigest)]) == 1
                else { throw SurfaceError.stale }
            }
        }
    }
}
