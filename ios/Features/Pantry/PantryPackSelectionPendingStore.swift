import Foundation
import Darwin
import CryptoKit
import LocalStore
import CoreDomain

/// One protected original request per ordered origin pair. Grants are never stored.
@MainActor final class PantryPackSelectionPendingStore {
    enum Failure: Error, Equatable {
        case invalidLocation, invalidEntry, corrupt, foreignOrigin, occupied, operationConflict, missingAcknowledgment, io
    }
    struct Acknowledgment: Codable, Equatable {
        let operationID: UUID
        let committedLedgerRevision: Int64
        let adoptedLedgerRevision: Int64
        let receiptDigest: Data
    }
    struct Entry: Codable, Equatable {
        let request: PantryPackSelectionCommitPort.Request
        fileprivate(set) var acknowledgment: Acknowledgment?
        var operationID: UUID { request.selection.id }
        init(request: PantryPackSelectionCommitPort.Request, acknowledgment: Acknowledgment? = nil) {
            self.request = request; self.acknowledgment = acknowledgment
        }
        func hasSameOriginal(as other: Entry) -> Bool { request == other.request }
    }
    private struct Envelope: Codable {
        let version: Int
        let inventoryWorkspaceID: UUID
        let ledgerWorkspaceID: UUID
        let entry: Entry
        let digest: Data
    }
    static let maximumFileBytes = PantryPackSelectionCommitPort.maximumRequestBytes + 8_192
    let inventoryWorkspaceID: UUID
    let ledgerWorkspaceID: UUID
    let fileURL: URL
    private let directory: URL
    private let removeFile: (URL) throws -> Void
    init(directory: URL, inventoryWorkspaceID: UUID, ledgerWorkspaceID: UUID,
         removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard directory.isFileURL else { throw Failure.invalidLocation }
        self.directory = directory; self.inventoryWorkspaceID = inventoryWorkspaceID; self.ledgerWorkspaceID = ledgerWorkspaceID
        fileURL = directory.appendingPathComponent("\(inventoryWorkspaceID.uuidString).\(ledgerWorkspaceID.uuidString).pack.json")
        self.removeFile = removeFile
    }
    func read() throws -> Entry? { try withLock { try readUnlocked() } }
    func ensureProtected(expected: Entry) throws {
        try validate(expected)
        try withLock {
            guard try readUnlocked() == expected else { throw Failure.operationConflict }
            try protectFile()
        }
    }
    @discardableResult func save(_ request: PantryPackSelectionCommitPort.Request) throws -> Entry {
        let candidate = Entry(request: request); try validate(candidate)
        return try withLock {
            if let prior = try readUnlocked() {
                guard prior.operationID == candidate.operationID else { throw Failure.occupied }
                guard prior.hasSameOriginal(as: candidate) else { throw Failure.operationConflict }
                try protectFile(); return prior
            }
            try writeUnlocked(candidate); return candidate
        }
    }
    @discardableResult func acknowledgeAdoption(expected: Entry, receipt: LedgerRecord, currentLedgerRevision: Int64) throws -> Entry {
        try validate(expected)
        try PantryPackSelectionCommitPort.validateReceipt(receipt, request: expected.request)
        guard currentLedgerRevision >= receipt.revision else { throw Failure.operationConflict }
        struct ReceiptDigest: Encodable {
            let origin: UUID; let id: UUID; let revision: Int64; let payloadDigest: Data; let savedAt: Date
        }
        let ack = Acknowledgment(operationID: receipt.operationID, committedLedgerRevision: receipt.revision,
            adoptedLedgerRevision: currentLedgerRevision,
            receiptDigest: Self.digest(try Self.encode(ReceiptDigest(origin: receipt.workspaceID, id: receipt.operationID,
                revision: receipt.revision, payloadDigest: Self.digest(receipt.payload), savedAt: receipt.savedAt))))
        return try withLock {
            guard var prior = try readUnlocked(), prior.hasSameOriginal(as: expected) else { throw Failure.operationConflict }
            if let existing = prior.acknowledgment {
                guard existing.operationID == ack.operationID, existing.receiptDigest == ack.receiptDigest else { throw Failure.operationConflict }
                return prior
            }
            prior.acknowledgment = ack; try writeUnlocked(prior); return prior
        }
    }
    func clearAcknowledged(expected: Entry) throws {
        try validate(expected)
        guard expected.acknowledgment != nil else { throw Failure.missingAcknowledgment }
        try withLock {
            guard let current = try readUnlocked() else { return }
            guard current == expected else { throw Failure.operationConflict }
            try removeFile(fileURL)
        }
    }
    /// Requires receipt absence under the paired exclusive lease; retry never recreates this file.
    func discardUnapplied(expected: Entry) throws {
        try validate(expected)
        guard expected.acknowledgment == nil else { throw Failure.operationConflict }
        try withLock {
            guard let current = try readUnlocked() else { return }
            guard current == expected else { throw Failure.operationConflict }
            try removeFile(fileURL)
        }
    }
    private func readUnlocked() throws -> Entry? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= Self.maximumFileBytes else { throw Failure.corrupt }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: bytes) }
        catch { throw Failure.corrupt }
        guard envelope.version == 1 else { throw Failure.corrupt }
        guard envelope.inventoryWorkspaceID == inventoryWorkspaceID && envelope.ledgerWorkspaceID == ledgerWorkspaceID else { throw Failure.foreignOrigin }
        guard envelope.digest == Self.digest(try Self.encode(envelope.entry)) else { throw Failure.corrupt }
        do { try validate(envelope.entry) }
        catch Failure.foreignOrigin { throw Failure.foreignOrigin }
        catch { throw Failure.corrupt }
        return envelope.entry
    }
    private func writeUnlocked(_ entry: Entry) throws {
        try validate(entry)
        let envelope = Envelope(version: 1, inventoryWorkspaceID: inventoryWorkspaceID, ledgerWorkspaceID: ledgerWorkspaceID,
            entry: entry, digest: Self.digest(try Self.encode(entry)))
        let bytes = try Self.encode(envelope)
        guard bytes.count <= Self.maximumFileBytes else { throw Failure.invalidEntry }
        #if os(iOS)
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: fileURL, options: [.atomic])
        #endif
        try protectFile()
    }
    private func protectFile() throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
        var url = fileURL; var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try url.setResourceValues(resources)
    }
    private func validate(_ entry: Entry) throws {
        try Self.validateArchiveEntry(entry, inventoryWorkspaceID: inventoryWorkspaceID, ledgerWorkspaceID: ledgerWorkspaceID)
    }
    /// Archival validation cannot recreate a live pending request or authorization.
    static func validateArchiveEntry(_ entry: Entry, inventoryWorkspaceID: UUID, ledgerWorkspaceID: UUID) throws {
        try PantryPackSelectionCommitPort.validate(entry.request)
        guard entry.request.inventoryWorkspaceID == inventoryWorkspaceID,
              entry.request.ledgerWorkspaceID == ledgerWorkspaceID else { throw Failure.foreignOrigin }
        if let ack = entry.acknowledgment {
            guard ack.operationID == entry.operationID,
                  ack.committedLedgerRevision == entry.request.reviewedLedgerRevision + 1,
                  ack.adoptedLedgerRevision >= ack.committedLedgerRevision,
                  ack.receiptDigest.count == 32 else { throw Failure.invalidEntry }
        }
    }
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        let lockURL = fileURL.appendingPathExtension("lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.io }
        defer { Darwin.close(fd) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: lockURL.path)
        #endif
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.io }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest(_ value: Data) -> Data { Data(SHA256.hash(data: value)) }
}
