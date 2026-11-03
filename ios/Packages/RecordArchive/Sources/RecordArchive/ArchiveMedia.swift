import Foundation

/// These are saved source references, never audio, executable files or authority.
public enum ArchiveMediaKind: String, Codable, Sendable { case packageReference, recipeSource, receiptEvidence }
public enum ArchiveMediaContentType: String, Codable, Sendable {
    case captureEvidenceJSON = "application/vnd.room-in-the-cart.capture-evidence+json"
}
public struct ArchiveMediaSourceIdentity: Codable, Hashable, Sendable {
    public let origin: String
    public let mediaID: String
    public init(origin: String, mediaID: String) { self.origin = origin; self.mediaID = mediaID }
}

/// Archived provenance only. A declaration never authorizes reading a native
/// namespace; the app mints it from an actually opened independent local store.
public struct ArchiveCaptureNamespace: Codable, Equatable, Sendable {
    public enum StoreKind: String, Codable, Sendable { case ledger, pickup }
    public let formatMajor: Int
    public let archiveOrigin: String
    public let storeKind: StoreKind
    public let physicalWorkspaceID: UUID
    public init(archiveOrigin: String, storeKind: StoreKind, physicalWorkspaceID: UUID) {
        formatMajor = 1; self.archiveOrigin = archiveOrigin; self.storeKind = storeKind; self.physicalWorkspaceID = physicalWorkspaceID
    }
    public func validate(origin: String, recordKind: ArchiveRecordKind, mediaKind: ArchiveMediaKind) throws {
        guard formatMajor == 1 else { throw ArchiveError.unsupportedVersion }
        guard archiveOrigin == origin, ArchiveCodec.identifier(origin),
              (storeKind == .ledger && recordKind == .ledger && mediaKind != .receiptEvidence) ||
              (storeKind == .pickup && recordKind == .pickup && mediaKind == .receiptEvidence) else { throw ArchiveError.invalidIdentity }
    }
}

/// The app must also decode/re-encode the versioned evidence allowlist and validate
/// its reduced JPEG before review and apply. No paths, URLs or remote fetches occur.
public struct ArchiveMediaAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ArchiveMediaKind
    public let contentType: ArchiveMediaContentType
    public let data: Data
    public let captureNamespace: ArchiveCaptureNamespace?
    public init(id: String, kind: ArchiveMediaKind, contentType: ArchiveMediaContentType = .captureEvidenceJSON, data: Data, captureNamespace: ArchiveCaptureNamespace? = nil) {
        self.id = id; self.kind = kind; self.contentType = contentType; self.data = data
        self.captureNamespace = captureNamespace
    }
}

public struct ArchiveMediaManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let origin: String
        public let recordID: String
        public let revision: String
        public let mediaID: String
        public let kind: ArchiveMediaKind
        public let contentType: ArchiveMediaContentType
        public let byteCount: Int
        public let digest: String
        public let captureNamespace: ArchiveCaptureNamespace?
    }
    public let formatMajor: Int
    public let entries: [Entry]
    public var totalBytes: Int { entries.reduce(0) { $0 + $1.byteCount } }
    var envelopeFormatMinor: Int { entries.contains { $0.captureNamespace != nil } ? 2 : 1 }

    static func make(records: [ArchiveRecord]) throws -> Self? {
        var entries: [Entry] = [], total = 0
        for record in records {
            guard let media = record.media else { continue }
            guard !media.isEmpty, media.count <= ArchiveCodec.maximumMediaAttachments else { throw ArchiveError.tooLarge }
            guard media.map(\.id) == media.map(\.id).sorted() else { throw ArchiveError.unsupportedRecord }
            guard record.nativePayload != nil else { throw ArchiveError.unsupportedRecord }
            var ids = Set<String>()
            for attachment in media {
                guard ArchiveCodec.identifier(attachment.id), ids.insert(attachment.id).inserted else { throw ArchiveError.invalidIdentity }
                guard !attachment.data.isEmpty else { throw ArchiveError.malformed }
                try attachment.captureNamespace?.validate(origin: record.origin, recordKind: record.kind, mediaKind: attachment.kind)
                guard attachment.data.count <= ArchiveCodec.maximumMediaBytes,
                      attachment.data.count <= ArchiveCodec.maximumTotalMediaBytes - total,
                      entries.count < ArchiveCodec.maximumMediaAttachments else { throw ArchiveError.tooLarge }
                total += attachment.data.count
                entries.append(Entry(origin: record.origin, recordID: record.id, revision: record.revision, mediaID: attachment.id,
                    kind: attachment.kind, contentType: attachment.contentType, byteCount: attachment.data.count, digest: ArchiveCodec.digest(attachment.data), captureNamespace: attachment.captureNamespace))
            }
        }
        return entries.isEmpty ? nil : Self(formatMajor: 1, entries: entries.sorted {
            ($0.origin, $0.recordID, $0.revision, $0.mediaID) < ($1.origin, $1.recordID, $1.revision, $1.mediaID)
        })
    }
}

extension ArchiveCodec {
    public static let maximumMediaAttachments = 12
    public static let maximumMediaBytes = 2_100_000
    public static let maximumTotalMediaBytes = 4_200_000

    /// A chosen subset is a projection of a source revision. Different subsets may
    /// recover beside one another; changed bytes under the same subset quarantine.
    /// Legacy records retain the established projection and receipt bytes.
    static func recordProjection(_ record: ArchiveRecord, base: String) -> String {
        guard base == projection(for: .personalRecovery), let media = record.media, !media.isEmpty else { return base }
        let scope = media.map(\.id).sorted().map { "\($0.utf8.count):\($0)" }.joined()
        return digest(Data((base + "/selected-source-media/v1/" + scope).utf8))
    }
    static func validProjectionDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
