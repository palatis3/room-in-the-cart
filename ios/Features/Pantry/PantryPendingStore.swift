import Foundation
import Darwin
import CryptoKit
import LocalStore
import CoreDomain

/// Protected original retry bytes, never a saved authorization grant. Callers reauthorize every use.
@MainActor final class PantryPendingStore {
    enum Failure: Error, Equatable {
        case invalidLocation, invalidEntry, corrupt, foreignOrigin, occupied, operationConflict, missingAcknowledgment, io
    }
    struct Acknowledgment: Codable, Equatable {
        let operationID: UUID
        let committedInventoryRevision: Int64
        let adoptedInventoryRevision: Int64
        let receiptDigest: Data
    }
    struct Entry: Codable, Equatable {
        let command: InventoryCommand
        let reviewedInventoryRevision: Int64
        let consumption: PantryConsumptionIntent?
        fileprivate(set) var acknowledgment: Acknowledgment?
        var operationID: UUID { command.id }
        var commands: [InventoryCommand] { [command] + (consumption?.additionalCommands ?? []) }
        init(command: InventoryCommand, reviewedInventoryRevision: Int64, acknowledgment: Acknowledgment? = nil,
             consumption: PantryConsumptionIntent? = nil) {
            self.consumption = consumption
            self.command = command; self.reviewedInventoryRevision = reviewedInventoryRevision
            self.acknowledgment = acknowledgment
        }
        func requestBytes() throws -> Data {
            if consumption == nil {
                return try PantryPersistenceCodec.request(command, inventoryRevision: reviewedInventoryRevision)
            }
            // Acknowledgment is an outcome and cannot become part of the original idempotency key.
            var original = self
            original.acknowledgment = nil
            return try PantryPendingStore.encode(original)
        }
        func hasSameOriginal(as other: Entry) -> Bool {
            command == other.command && reviewedInventoryRevision == other.reviewedInventoryRevision && consumption == other.consumption
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let inventoryWorkspaceID: UUID
        let entry: Entry
        let digest: Data
    }
    nonisolated static let maximumFileBytes = InventoryPersistenceLimits.requestBytes + 8_192
    let inventoryWorkspaceID: UUID
    let fileURL: URL
    private let directory: URL
    private let removeFile: (URL) throws -> Void

    init(directory: URL, inventoryWorkspaceID: UUID,
         removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard directory.isFileURL else { throw Failure.invalidLocation }
        self.directory = directory
        self.inventoryWorkspaceID = inventoryWorkspaceID
        fileURL = directory.appendingPathComponent("\(inventoryWorkspaceID.uuidString).food.json")
        self.removeFile = removeFile
    }

    func read() throws -> Entry? { try withLock { try readUnlocked() } }

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
    func save(command: InventoryCommand, reviewedInventoryRevision: Int64) throws -> Entry {
        try save(Entry(command: command, reviewedInventoryRevision: reviewedInventoryRevision))
    }

    @discardableResult
    func save(_ candidate: Entry) throws -> Entry {
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
    func acknowledgeAdoption(expected: Entry, receipt: LocalStore.InventoryOperationReceipt,
                             currentInventoryRevision: Int64) throws -> Entry {
        try validate(expected)
        guard receipt.workspaceID == inventoryWorkspaceID, receipt.operationID == expected.operationID,
              receipt.migrationID == nil, expected.reviewedInventoryRevision < Int64.max,
              receipt.revision == expected.reviewedInventoryRevision + 1,
              currentInventoryRevision >= receipt.revision,
              receipt.comparisonHeads.isEmpty else { throw Failure.operationConflict }
        if let consumption = expected.consumption {
            let commands = [expected.command] + consumption.additionalCommands
            guard receipt.heads.count == commands.count * 3 else { throw Failure.operationConflict }
            for command in commands {
                guard case .revise(let edit) = command.change, let observation = edit.observation,
                      receipt.heads.contains(where: { $0.key == .init(.lot, command.lotID) && $0.revision == (command.expectedRevision ?? 0) + 1 }),
                      receipt.heads.contains(where: { $0.key == .init(.event, command.eventID) && $0.revision == 1 }),
                      receipt.heads.contains(where: { $0.key == .init(.observation, observation.observationID) && $0.revision == 1 }) else {
                    throw Failure.operationConflict
                }
            }
        } else if case .reservation(let edit) = expected.command.change {
            guard receipt.heads.count == 1, receipt.heads.first?.key == .init(.reservation, edit.id),
                  receipt.heads.first?.revision == edit.previousRevision + 1 else { throw Failure.operationConflict }
        } else {
            guard receipt.heads.contains(where: { $0.key == .init(.lot, expected.command.lotID) }),
              receipt.heads.contains(where: { $0.key == .init(.event, expected.command.eventID) }) else {
                throw Failure.operationConflict
            }
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
        try Self.archiveEntry(at: fileURL, inventoryWorkspaceID: inventoryWorkspaceID)
    }

    /// Read-only bounded archival capture; callers fence changes with exact journal digests.
    nonisolated static func archiveEntry(at fileURL: URL, inventoryWorkspaceID: UUID) throws -> Entry? {
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
        guard envelope.inventoryWorkspaceID == inventoryWorkspaceID else { throw Failure.foreignOrigin }
        guard envelope.digest == Self.digest(try Self.encode(envelope.entry)) else { throw Failure.corrupt }
        do { try Self.validateArchiveEntry(envelope.entry, inventoryWorkspaceID: inventoryWorkspaceID) }
        catch Failure.foreignOrigin { throw Failure.foreignOrigin }
        catch { throw Failure.corrupt }
        return envelope.entry
    }
    private func writeUnlocked(_ entry: Entry) throws {
        try validate(entry)
        let envelope = Envelope(version: 1, inventoryWorkspaceID: inventoryWorkspaceID,
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
        try Self.validateArchiveEntry(entry, inventoryWorkspaceID: inventoryWorkspaceID)
    }
    /// Validates saved retry bytes, not a durable authorization grant.
    nonisolated static func validateArchiveEntry(_ entry: Entry, inventoryWorkspaceID: UUID) throws {
        let command = entry.command
        guard command.originID == inventoryWorkspaceID else { throw Failure.foreignOrigin }
        guard entry.reviewedInventoryRevision >= 0, entry.reviewedInventoryRevision < Int64.max,
              command.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              command.expectedRevision.map({ $0 > 0 && $0 < Int64.max }) ?? true,
              try entry.requestBytes().count <= InventoryPersistenceLimits.requestBytes else {
            throw Failure.invalidEntry
        }
        try entry.consumption?.validate(first: command)
        if case .reservation(let edit) = command.change {
            try edit.validate()
            guard command.expectedRevision != nil else { throw Failure.invalidEntry }
        }
        if let ack = entry.acknowledgment {
            guard ack.operationID == entry.operationID,
                  ack.committedInventoryRevision == entry.reviewedInventoryRevision + 1,
                  ack.adoptedInventoryRevision >= ack.committedInventoryRevision, ack.receiptDigest.count == 32 else { throw Failure.invalidEntry }
        }
    }
    private func sameOriginal(_ lhs: Entry, _ rhs: Entry) -> Bool { lhs.hasSameOriginal(as: rhs) }
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
