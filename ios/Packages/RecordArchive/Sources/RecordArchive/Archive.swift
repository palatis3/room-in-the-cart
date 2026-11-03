import Foundation
import CryptoKit

/// Public errors deliberately contain no user text, filenames, URLs or decoder diagnostics.
public enum ArchiveError: Error, Equatable, Sendable {
    case tooLarge, malformed, unsupportedVersion, integrity, invalidIdentity, unsupportedProjection
    case locked, invalidKey, conflict, staleReview, unavailable, invalidRecipe, unsupportedRecord
}

public enum ArchiveKind: String, Codable, Sendable { case personalRecovery, helperShop }
public enum ArchiveRecordKind: String, Codable, Sendable { case comparison, ledger, pickup, recipe }

/// The helper representation is an allowlist, not a filtered native model.
public struct HelperLine: Codable, Equatable, Sendable {
    public var label: String
    public var originalAmount: String
    public var originalUnit: String
    public var originalLanguage: String?
    public var purpose: String?
    public var action: String?
    public var foodStatus: String?
    public init(label: String, originalAmount: String = "", originalUnit: String = "", originalLanguage: String? = nil, purpose: String? = nil, action: String? = nil, foodStatus: String? = nil) {
        self.label = label; self.originalAmount = originalAmount; self.originalUnit = originalUnit
        self.originalLanguage = originalLanguage; self.purpose = purpose; self.action = action; self.foodStatus = foodStatus
    }
}

/// A native payload must be decoded and re-encoded from an explicit domain allowlist
/// by the application's transactional adapter. Never supply databases or account state.
public struct ArchiveRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var origin: String
    public var revision: String
    public var parentRevision: String?
    public var kind: ArchiveRecordKind
    public var title: String
    public var savedAtMilliseconds: Int64
    public var helperLines: [HelperLine]
    public var nativePayload: Data?
    /// Explicitly selected owner evidence. Omitted from v1.0 and every helper projection.
    public var media: [ArchiveMediaAttachment]?
    public init(id: String, origin: String, revision: String, parentRevision: String? = nil, kind: ArchiveRecordKind, title: String, savedAtMilliseconds: Int64, helperLines: [HelperLine] = [], nativePayload: Data? = nil, media: [ArchiveMediaAttachment]? = nil) {
        self.id = id; self.origin = origin; self.revision = revision; self.parentRevision = parentRevision
        self.kind = kind; self.title = title; self.savedAtMilliseconds = savedAtMilliseconds
        self.helperLines = helperLines; self.nativePayload = nativePayload
        self.media = media
    }
}

public struct ArchivePayload: Codable, Equatable, Sendable {
    public var records: [ArchiveRecord]
    public init(records: [ArchiveRecord]) { self.records = records }
}

public struct ArchiveEnvelope: Codable, Equatable, Sendable {
    public let formatMajor: Int
    public let formatMinor: Int
    public let documentKind: ArchiveKind
    public let originNamespace: String
    public let shopID: String?
    public let sourceRevisionID: String
    public let parentRevisionID: String?
    public let projectionID: String
    public let producerBuild: String
    public let exportedAtMilliseconds: Int64
    public let lastSavedAtMilliseconds: Int64
    public let canonicalPayloadDigest: String
    public let payload: ArchivePayload
    public let mediaManifest: ArchiveMediaManifest?
}

public struct ArchiveIdentity: Codable, Hashable, Sendable {
    public let origin: String
    public let recordID: String
    public let revision: String
    public let projection: String
    public init(origin: String, recordID: String, revision: String, projection: String) {
        self.origin = origin; self.recordID = recordID; self.revision = revision; self.projection = projection
    }
}
public struct ArchiveSourceIdentity: Codable, Hashable, Sendable {
    public let origin: String
    public let recordID: String
    public init(origin: String, recordID: String) { self.origin = origin; self.recordID = recordID }
}
public struct ArchiveReceipt: Codable, Equatable, Sendable {
    public let identity: ArchiveIdentity
    public let digest: String
    public let localCopyID: String
    public let parentRevision: String?
    public let savedAtMilliseconds: Int64
    public init(identity: ArchiveIdentity, digest: String, localCopyID: String, parentRevision: String?, savedAtMilliseconds: Int64) {
        self.identity = identity; self.digest = digest; self.localCopyID = localCopyID
        self.parentRevision = parentRevision; self.savedAtMilliseconds = savedAtMilliseconds
    }
}

public enum ArchiveCodec {
    public static let maximumFileBytes = 8 * 1_048_576
    public static let maximumRecords = 500
    public static let maximumNativeBytes = 4 * 1_048_576
    public static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func projection(for kind: ArchiveKind) -> String {
        digest(Data((kind == .helperShop
            ? "record-archive/v1/helper-shop/all-recipients/id,origin,revision,parentRevision,kind,title,savedAtMilliseconds,helperLines(label,originalAmount,originalUnit,originalLanguage,purpose,action,foodStatus)"
            : "record-archive/v1/personal-recovery/owner/records+native-domain-payload").utf8))
    }
    public static func make(records: [ArchiveRecord], kind: ArchiveKind, origin: String, revision: String, parent: String? = nil, shopID: String? = nil, producerBuild: String = "1", exportedAt: Date = Date()) throws -> ArchiveEnvelope {
        guard records.count <= maximumRecords else { throw ArchiveError.tooLarge }
        let projected = records.map { record -> ArchiveRecord in
            var copy = record
            if kind == .helperShop { copy.nativePayload = nil; copy.media = nil }
            else { copy.media = copy.media?.sorted { $0.id < $1.id }; if copy.media?.isEmpty == true { copy.media = nil } }
            return copy
        }.sorted { ($0.origin, $0.id, $0.revision) < ($1.origin, $1.id, $1.revision) }
        let manifest = try ArchiveMediaManifest.make(records: projected)
        // Bound the total before joining native payloads into one canonical buffer.
        var payloadBytes = 0
        for record in projected {
            guard (record.nativePayload?.count ?? 0) <= maximumNativeBytes,
                  record.helperLines.count <= 2000 else { throw ArchiveError.tooLarge }
            let count = try canonical(record).count
            guard count <= maximumFileBytes - payloadBytes else { throw ArchiveError.tooLarge }
            payloadBytes += count
        }
        let payload = ArchivePayload(records: projected)
        let envelope = ArchiveEnvelope(formatMajor: 1, formatMinor: manifest == nil ? 0 : 1, documentKind: kind, originNamespace: origin, shopID: shopID, sourceRevisionID: revision, parentRevisionID: parent, projectionID: projection(for: kind), producerBuild: producerBuild, exportedAtMilliseconds: milliseconds(exportedAt), lastSavedAtMilliseconds: records.map(\.savedAtMilliseconds).max() ?? milliseconds(exportedAt), canonicalPayloadDigest: digest(try canonical(payload)), payload: payload, mediaManifest: manifest)
        try validate(envelope)
        return envelope
    }
    public static func encode(_ envelope: ArchiveEnvelope) throws -> Data {
        try validate(envelope)
        let data = try canonical(envelope)
        guard data.count <= maximumFileBytes else { throw ArchiveError.tooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> ArchiveEnvelope {
        try preflight(data)
        try checkEnvelopeKeys(data)
        let value: ArchiveEnvelope
        do { value = try JSONDecoder().decode(ArchiveEnvelope.self, from: data) }
        catch { throw ArchiveError.malformed }
        // v1.0 is the first public schema; v1.1 adds explicitly selected media.
        // Pre-release v0 and future minor versions
        // are explicitly unsupported, rather than guessed or silently downgraded.
        try validate(value)
        return value
    }
    /// Unknown schema keys are rejected instead of silently discarding newly introduced
    /// private fields or unsupported restore semantics.
    private static func checkEnvelopeKeys(_ data: Data) throws {
        let root: [String: Any]
        do { guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArchiveError.malformed }; root = object }
        catch { throw ArchiveError.malformed }
        try allowedKeys(root, ["formatMajor", "formatMinor", "documentKind", "originNamespace", "shopID", "sourceRevisionID", "parentRevisionID", "projectionID", "producerBuild", "exportedAtMilliseconds", "lastSavedAtMilliseconds", "canonicalPayloadDigest", "payload", "mediaManifest"])
        guard let payload = root["payload"] as? [String: Any], let records = payload["records"] as? [[String: Any]] else { throw ArchiveError.malformed }
        try allowedKeys(payload, ["records"])
        for record in records {
            try allowedKeys(record, ["id", "origin", "revision", "parentRevision", "kind", "title", "savedAtMilliseconds", "helperLines", "nativePayload", "media"])
            if let attachments = record["media"] {
                guard let media = attachments as? [[String: Any]] else { throw ArchiveError.malformed }
                for attachment in media { try allowedKeys(attachment, ["id", "kind", "contentType", "data"]) }
            }
            guard let lines = record["helperLines"] as? [[String: Any]] else { throw ArchiveError.malformed }
            for line in lines { try allowedKeys(line, ["label", "originalAmount", "originalUnit", "originalLanguage", "purpose", "action", "foodStatus"]) }
        }
        if let value = root["mediaManifest"] {
            guard let manifest = value as? [String: Any], let entries = manifest["entries"] as? [[String: Any]] else { throw ArchiveError.malformed }
            try allowedKeys(manifest, ["formatMajor", "entries"])
            for entry in entries { try allowedKeys(entry, ["origin", "recordID", "revision", "mediaID", "kind", "contentType", "byteCount", "digest"]) }
        }
    }
    static func allowedKeys(_ object: [String: Any], _ allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw ArchiveError.unsupportedRecord }
    }
    public static func validate(_ value: ArchiveEnvelope) throws {
        guard value.formatMajor == 1, (0...1).contains(value.formatMinor) else { throw ArchiveError.unsupportedVersion }
        guard value.projectionID == projection(for: value.documentKind) else { throw ArchiveError.unsupportedProjection }
        guard identifier(value.originNamespace), identifier(value.sourceRevisionID), value.parentRevisionID.map(identifier) ?? true,
              value.shopID.map(identifier) ?? true, value.producerBuild.utf8.count <= 128 else { throw ArchiveError.invalidIdentity }
        guard value.payload.records.count <= maximumRecords else { throw ArchiveError.tooLarge }
        var identities = Set<ArchiveIdentity>()
        for record in value.payload.records {
            guard identifier(record.id), identifier(record.origin), identifier(record.revision), record.parentRevision.map(identifier) ?? true else { throw ArchiveError.invalidIdentity }
            guard record.title.utf8.count <= 4096, !record.title.contains("\0"), record.helperLines.count <= 2000,
                  (record.nativePayload?.count ?? 0) <= maximumNativeBytes else { throw ArchiveError.tooLarge }
            guard identities.insert(identity(record, projection: value.projectionID)).inserted else { throw ArchiveError.invalidIdentity }
            if value.documentKind == .helperShop, record.nativePayload != nil || record.media != nil { throw ArchiveError.unsupportedProjection }
            for line in record.helperLines {
                guard [line.label, line.originalAmount, line.originalUnit, line.originalLanguage ?? "", line.purpose ?? "", line.action ?? "", line.foodStatus ?? ""].allSatisfy({ $0.utf8.count <= 8192 && !$0.contains("\0") }) else { throw ArchiveError.tooLarge }
            }
        }
        if let manifest = value.mediaManifest, manifest.formatMajor != 1 { throw ArchiveError.unsupportedVersion }
        let expectedManifest = try ArchiveMediaManifest.make(records: value.payload.records)
        guard value.mediaManifest == expectedManifest,
              value.formatMinor == (expectedManifest == nil ? 0 : 1) else { throw ArchiveError.integrity }
        guard digest(try canonical(value.payload)) == value.canonicalPayloadDigest else { throw ArchiveError.integrity }
    }
    public static func identity(_ record: ArchiveRecord, projection: String) -> ArchiveIdentity {
        ArchiveIdentity(origin: record.origin, recordID: record.id, revision: record.revision, projection: recordProjection(record, base: projection))
    }
    public static func receipt(_ record: ArchiveRecord, projection: String, localCopyID: String) throws -> ArchiveReceipt {
        ArchiveReceipt(identity: identity(record, projection: projection), digest: digest(try canonical(record)), localCopyID: localCopyID, parentRevision: record.parentRevision, savedAtMilliseconds: record.savedAtMilliseconds)
    }
    public static func milliseconds(_ date: Date) -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > Double(Int64.min), milliseconds < Double(Int64.max) else { return 0 }
        return Int64(milliseconds.rounded(.towardZero))
    }
    static func identifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0") }
    /// Bound allocation and nesting before Foundation sees the untrusted JSON.
    public static func preflight(_ data: Data, maximum: Int = maximumFileBytes) throws {
        guard !data.isEmpty else { throw ArchiveError.malformed }
        guard maximum >= 0, data.count <= maximum else { throw ArchiveError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw ArchiveError.malformed }
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 48 { throw ArchiveError.tooLarge } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { throw ArchiveError.malformed } }
        }
        guard depth == 0, !quoted else { throw ArchiveError.malformed }
    }
}

/// Platform authenticated encryption. The key is user-held and never saved in an archive.
public enum EncryptedArchive {
    private struct Container: Codable { let formatMajor: Int; let algorithm: String; let combined: Data }
    public static func generateKey() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() } }
    public static func seal(_ envelope: ArchiveEnvelope, key: String) throws -> Data {
        let key = try symmetricKey(key)
        let sealed = try AES.GCM.seal(try ArchiveCodec.encode(envelope), using: key, authenticating: Data("RoomInTheCart/recovery/v1".utf8))
        guard let combined = sealed.combined else { throw ArchiveError.locked }
        let data = try ArchiveCodec.canonical(Container(formatMajor: 1, algorithm: "AES-256-GCM", combined: combined))
        guard data.count <= ArchiveCodec.maximumFileBytes else { throw ArchiveError.tooLarge }
        return data
    }
    public static func open(_ data: Data, key: String) throws -> ArchiveEnvelope {
        try ArchiveCodec.preflight(data)
        let container: Container
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArchiveError.malformed }
        try ArchiveCodec.allowedKeys(object, ["formatMajor", "algorithm", "combined"])
        do { container = try JSONDecoder().decode(Container.self, from: data) } catch { throw ArchiveError.malformed }
        guard container.formatMajor == 1, container.algorithm == "AES-256-GCM" else { throw ArchiveError.unsupportedVersion }
        let decodedKey = try symmetricKey(key)
        do {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: container.combined), using: decodedKey, authenticating: Data("RoomInTheCart/recovery/v1".utf8))
            return try ArchiveCodec.decode(bytes)
        } catch let error as ArchiveError { throw error }
        catch { throw ArchiveError.locked }
    }
    private static func symmetricKey(_ string: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else { throw ArchiveError.invalidKey }
        return SymmetricKey(data: data)
    }
}
