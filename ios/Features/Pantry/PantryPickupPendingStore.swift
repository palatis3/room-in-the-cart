import Foundation
import Darwin
import CryptoKit
import LocalStore

/// Protected original retry bytes, never a saved authorization grant. Callers reauthorize every use.
@MainActor final class PantryPickupPendingStore {
    enum Failure: Error, Equatable {
        case invalidLocation, invalidEntry, corrupt, foreignOrigin, occupied, operationConflict, missingAcknowledgment, io
    }
    enum Selection: Codable, Equatable { case preserve, select(UUID) }
    struct Acknowledgment: Codable, Equatable {
        let operationID: UUID
        let committedInventoryRevision: Int64
        let adoptedInventoryRevision: Int64
        let receiptDigest: Data
    }
    struct Entry: Codable, Equatable {
        let submission: PantryPickupCommitPort.Submission
        let selection: Selection
        let recoveryOperationID: UUID?
        let requiresActionAuthorization: Bool
        fileprivate(set) var acknowledgment: Acknowledgment?
        var operationID: UUID { submission.request.operationID }
        init(submission: PantryPickupCommitPort.Submission, selection: Selection, recoveryOperationID: UUID?,
             requiresActionAuthorization: Bool, acknowledgment: Acknowledgment? = nil) {
            self.submission = submission; self.selection = selection; self.recoveryOperationID = recoveryOperationID
            self.requiresActionAuthorization = requiresActionAuthorization; self.acknowledgment = acknowledgment
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let inventoryWorkspaceID: UUID
        let ledgerWorkspaceID: UUID
        let entry: Entry
        let digest: Data
    }
    nonisolated static let maximumFileBytes = InventoryPersistenceLimits.batchBytes + 8_192
    let inventoryWorkspaceID: UUID
    let ledgerWorkspaceID: UUID
    let fileURL: URL
    private let directory: URL
    private let removeFile: (URL) throws -> Void

    init(directory: URL, inventoryWorkspaceID: UUID, ledgerWorkspaceID: UUID,
         removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard directory.isFileURL else { throw Failure.invalidLocation }
        self.directory = directory
        self.inventoryWorkspaceID = inventoryWorkspaceID; self.ledgerWorkspaceID = ledgerWorkspaceID
        fileURL = directory.appendingPathComponent("\(inventoryWorkspaceID.uuidString).json")
        self.removeFile = removeFile
    }

    func read() throws -> Entry? { try withLock { try readUnlocked() } }

    /// Both editors reopen the same origin-scoped journal directory. The food
    /// journal has its own filename and cannot replace a pickup submission.
    func makeFoodPendingStore() throws -> PantryPendingStore {
        try PantryPendingStore(directory: directory, inventoryWorkspaceID: inventoryWorkspaceID)
    }

    /// Repairs attributes after an interrupted atomic write without ever creating
    /// a journal that another authorized owner has already discarded.
    func ensureProtected(expected: Entry) throws {
        try validate(expected)
        try withLock {
            guard try readUnlocked() == expected else { throw Failure.operationConflict }
            try protectFile()
        }
    }

    @discardableResult
    func save(submission: PantryPickupCommitPort.Submission, selection: Selection,
              recoveryOperationID: UUID?, requiresActionAuthorization: Bool) throws -> Entry {
        let candidate = Entry(submission: submission, selection: selection, recoveryOperationID: recoveryOperationID,
            requiresActionAuthorization: requiresActionAuthorization, acknowledgment: nil)
        try validate(candidate)
        return try withLock {
            if let prior = try readUnlocked() {
                guard prior.operationID == candidate.operationID else { throw Failure.occupied }
                guard sameOriginal(prior, candidate) else { throw Failure.operationConflict }
                try protectFile()
                return prior // Never regress durable adoption to an uncommitted pending phase.
            }
            try writeUnlocked(candidate)
            return candidate
        }
    }

    /// Call only after exact receipt recognition AND successful adoption of the current state.
    @discardableResult
    func acknowledgeAdoption(expected: Entry, receipt: InventoryOperationReceipt,
                             currentInventoryRevision: Int64) throws -> Entry {
        try validate(expected)
        guard receipt.workspaceID == inventoryWorkspaceID, receipt.operationID == expected.operationID,
              receipt.migrationID == nil, expected.submission.request.inventoryRevision < Int64.max,
              receipt.revision == expected.submission.request.inventoryRevision + 1,
              receipt.committedAt == expected.submission.preparedAt,
              currentInventoryRevision >= receipt.revision,
              receipt.comparisonHeads == Dictionary(uniqueKeysWithValues: expected.submission.changedHeads.map { ($0.id, $0.revision) }) else {
            throw Failure.operationConflict
        }
        let acknowledgment = Acknowledgment(operationID: receipt.operationID, committedInventoryRevision: receipt.revision,
            adoptedInventoryRevision: currentInventoryRevision, receiptDigest: Self.digest(try Self.encode(receipt)))
        return try withLock {
            guard var prior = try readUnlocked(), sameOriginal(prior, expected) else { throw Failure.operationConflict }
            if let existing = prior.acknowledgment {
                guard existing.operationID == acknowledgment.operationID, existing.receiptDigest == acknowledgment.receiptDigest else {
                    throw Failure.operationConflict
                }
                return prior
            }
            prior.acknowledgment = acknowledgment
            try writeUnlocked(prior)
            return prior
        }
    }

    /// A failed removal leaves the acknowledged entry available for the same cleanup retry.
    func clearAcknowledged(expected: Entry) throws {
        try validate(expected)
        guard expected.acknowledgment != nil else { throw Failure.missingAcknowledgment }
        try withLock {
            guard let current = try readUnlocked() else { return }
            guard current == expected else { throw Failure.operationConflict }
            try removeFile(fileURL)
        }
    }

    /// Caller MUST establish that no database receipt exists while holding the paired-store
    /// exclusive lease. Every resumed writer must also recheck this exact pending file.
    func discardUnapplied(expected: Entry) throws {
        try validate(expected)
        guard expected.acknowledgment == nil else { throw Failure.operationConflict }
        try withLock {
            guard let current = try readUnlocked() else { return }
            guard current == expected, current.acknowledgment == nil else { throw Failure.operationConflict }
            try removeFile(fileURL)
        }
    }

    private func readUnlocked() throws -> Entry? {
        try Self.archiveEntry(at: fileURL, inventoryWorkspaceID: inventoryWorkspaceID, ledgerWorkspaceID: ledgerWorkspaceID)
    }

    /// Read-only bounded archival capture; callers fence changes with exact journal digests.
    nonisolated static func archiveEntry(at fileURL: URL, inventoryWorkspaceID: UUID, ledgerWorkspaceID: UUID) throws -> Entry? {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.io
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= Self.maximumFileBytes else { throw Failure.corrupt }
        let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= Self.maximumFileBytes else { throw Failure.corrupt }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: bytes) }
        catch { throw Failure.corrupt }
        guard envelope.version == 1 else { throw Failure.corrupt }
        guard envelope.inventoryWorkspaceID == inventoryWorkspaceID, envelope.ledgerWorkspaceID == ledgerWorkspaceID else { throw Failure.foreignOrigin }
        guard envelope.digest == Self.digest(try Self.encode(envelope.entry)) else { throw Failure.corrupt }
        do { try Self.validateArchiveEntry(envelope.entry, inventoryWorkspaceID: inventoryWorkspaceID, ledgerWorkspaceID: ledgerWorkspaceID) }
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
    /// Pure evidence validation. This does not authorize or persist a recovered action.
    nonisolated static func validateArchiveEntry(_ entry: Entry, inventoryWorkspaceID: UUID, ledgerWorkspaceID: UUID) throws {
        let submission = entry.submission, request = submission.request
        guard request.originID == inventoryWorkspaceID, request.ledgerOriginID == ledgerWorkspaceID else { throw Failure.foreignOrigin }
        guard submission.version == 1, request.version == 1, request.inventoryRevision >= 0,
              request.priorDigest.count == 32, request.proposedDigest.count == 32,
              request.ledgerRevision.map({ $0 >= 0 }) == true, request.ledgerDigest?.count == 32,
              submission.preparedAt.timeIntervalSinceReferenceDate.isFinite,
              !submission.changedHeads.isEmpty, submission.changedHeads.count <= InventoryPersistenceLimits.batchItems,
              Set(submission.changedHeads.map(\.id)).count == submission.changedHeads.count,
              try Self.encode(submission).count <= InventoryPersistenceLimits.batchBytes else { throw Failure.invalidEntry }
        for head in submission.changedHeads {
            guard head.revision > 0, head.savedAt == submission.preparedAt,
                  !head.payload.isEmpty, head.payload.count <= ComparisonStore.maximumPayloadBytes else { throw Failure.invalidEntry }
            let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            guard journey.id == head.id, journey.savedAt == head.savedAt else { throw Failure.invalidEntry }
            try PickupModel.validate(journey)
        }
        if case let .select(id) = entry.selection {
            guard submission.changedHeads.contains(where: { $0.id == id }) else { throw Failure.invalidEntry }
        }
        if let ack = entry.acknowledgment {
            guard ack.operationID == entry.operationID, request.inventoryRevision < Int64.max,
                  ack.committedInventoryRevision == request.inventoryRevision + 1,
                  ack.adoptedInventoryRevision >= ack.committedInventoryRevision, ack.receiptDigest.count == 32 else { throw Failure.invalidEntry }
        }
    }
    private func sameOriginal(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.submission == rhs.submission && lhs.selection == rhs.selection && lhs.recoveryOperationID == rhs.recoveryOperationID &&
            lhs.requiresActionAuthorization == rhs.requiresActionAuthorization
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
    nonisolated private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    nonisolated private static func digest(_ value: Data) -> Data { Data(SHA256.hash(data: value)) }
}
