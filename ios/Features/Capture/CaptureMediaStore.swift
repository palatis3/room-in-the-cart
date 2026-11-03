import Foundation
import CryptoKit
import Darwin

struct CaptureMediaArchiveListing: Sendable {
    var records: [SourceMediaRecord] = []
    var unavailableCount = 0
}

/// Sidecar evidence only. Saved bytes are never recovered as access, payment, food receipt or meal approval.
actor CaptureMediaStore {
    static let shared = CaptureMediaStore()
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }

    func save(_ record: SourceMediaRecord, authorize: @MainActor @Sendable () -> Bool) async throws -> SourceMediaReference {
        guard await authorize() else { throw ScanFailure.stale }
        try record.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        guard bytes.count <= ScanLimits.maximumRecordBytes else { throw ScanFailure.tooLarge }
        let inserted = try withLock {
            let workspace = try workspaceDirectory(record.target.workspaceID)
            guard try !retired(record.target, mediaID: record.id) else { throw ScanFailure.retired }
            try ensureDirectory(workspace)
            let url = workspace.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                guard try readUnlocked(url) == record else { throw ScanFailure.replay }; return false
            }
            guard try recordFiles(workspace).count < ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.tooLarge }
            try write(bytes, to: url)
            return true
        }
        guard await authorize() else {
            // Remove only this newly created sidecar; an existing accepted receipt is not undone.
            if inserted { try removeExact(record) }
            throw ScanFailure.stale
        }
        return record.reference
    }
    func read(_ reference: SourceMediaReference, target: CaptureTarget,
              authorize: @MainActor @Sendable () -> Bool) async throws -> SourceMediaRecord {
        guard reference.workspaceID == target.workspaceID, await authorize() else { throw ScanFailure.stale }
        let result = try withLock {
            guard try !retired(target, mediaID: reference.mediaID) else { throw ScanFailure.retired }
            let directory = try workspaceDirectory(target.workspaceID)
            let value = try readUnlocked(directory.appendingPathComponent(reference.mediaID.uuidString.lowercased() + ".json"))
            guard value.id == reference.mediaID, value.target.sameObject(as: target) else { throw ScanFailure.stale }
            return value
        }
        guard await authorize() else { throw ScanFailure.stale }
        return result
    }
    func list(target: CaptureTarget, authorize: @MainActor @Sendable () -> Bool) async throws -> [SourceMediaRecord] {
        guard await authorize() else { throw ScanFailure.stale }
        let result = try withLock {
            guard try !retired(target) else { throw ScanFailure.retired }
            let directory = try workspaceDirectory(target.workspaceID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [SourceMediaRecord]() }
            return try recordFiles(directory).map(readUnlocked).filter { record in
                guard record.target.sameObject(as: target) else { return false }
                return try !retired(record.target, mediaID: record.id)
            }.sorted { $0.capturedAt < $1.capturedAt }
        }
        guard await authorize() else { throw ScanFailure.stale }
        return result
    }
    /// Records supplies a domain-owned namespace and filters targets against its
    /// scoped typed snapshot. This does not accept a decoded document as authority.
    func archiveListing(workspaceID: UUID, authorize: @MainActor @Sendable () -> Bool) async throws -> CaptureMediaArchiveListing {
        guard await authorize() else { throw ScanFailure.stale }
        let result = try withLock {
            let directory = try workspaceDirectory(workspaceID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return CaptureMediaArchiveListing() }
            try ensureNotLink(directory)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count <= ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.tooLarge }
            var listing = CaptureMediaArchiveListing()
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                          file.lastPathComponent == id.uuidString.lowercased() + ".json" else { throw ScanFailure.storage }
                    // Retired IDs remain excluded even if corrupted bytes survive cleanup.
                    guard !FileManager.default.fileExists(atPath: try mediaMarker(workspaceID, id).path),
                          !FileManager.default.fileExists(atPath: try workspaceMarker(workspaceID).path) else { continue }
                    let record = try readUnlocked(file)
                    guard record.id == id, record.target.workspaceID == workspaceID else { throw ScanFailure.storage }
                    if try !retired(record.target, mediaID: record.id) { listing.records.append(record) }
                } catch { listing.unavailableCount += 1 }
            }
            return listing
        }
        guard await authorize() else { throw ScanFailure.stale }
        return result
    }
    /// Known removal markers also apply to a backup brought back to this device.
    /// This reads tombstones only and never opens an old source namespace.
    func isRetired(_ record: SourceMediaRecord) throws -> Bool {
        try withLock { try retired(record.target, mediaID: record.id) }
    }
    func eraseWorkspace(_ workspaceID: UUID) async throws {
        try withLock {
            try write(Data(), to: workspaceMarker(workspaceID))
            let directory = try workspaceDirectory(workspaceID)
            if FileManager.default.fileExists(atPath: directory.path) { try ensureNotLink(directory); try FileManager.default.removeItem(at: directory) }
        }
    }
    func erasePickupRecord(workspaceID: UUID, recordID: UUID) async throws {
        try withLock {
            try write(Data(), to: recordMarker(workspaceID, recordID))
            let directory = try workspaceDirectory(workspaceID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            for url in try recordFiles(directory) {
                let value = try readUnlocked(url)
                if value.target.kind == .receiptEvidence && value.target.containerID == recordID { try FileManager.default.removeItem(at: url) }
            }
        }
    }
    func remove(_ reference: SourceMediaReference, target: CaptureTarget,
                authorize: @MainActor @Sendable () -> Bool) async throws {
        guard reference.workspaceID == target.workspaceID, await authorize() else { throw ScanFailure.stale }
        try withLock {
            let directory = try workspaceDirectory(target.workspaceID)
            let url = directory.appendingPathComponent(reference.mediaID.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                let record = try readUnlocked(url)
                guard record.target.sameObject(as: target) else { throw ScanFailure.stale }
                try write(Data(), to: mediaMarker(target.workspaceID, reference.mediaID))
                try FileManager.default.removeItem(at: url)
            } else {
                try write(Data(), to: mediaMarker(target.workspaceID, reference.mediaID))
            }
        }
    }
    nonisolated static func defaultDirectory(applicationSupport: URL, arguments: [String]) -> URL {
        #if DEBUG
        if arguments.contains("--ui-testing") { return applicationSupport.appendingPathComponent("UITestWorkspace/CaptureMedia", isDirectory: true) }
        #endif
        return applicationSupport.appendingPathComponent("RoomInTheCart/CaptureMedia", isDirectory: true)
    }
    private func root() throws -> URL {
        if let directory { return directory }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return Self.defaultDirectory(applicationSupport: base, arguments: ProcessInfo.processInfo.arguments)
    }
    private func workspaceDirectory(_ id: UUID) throws -> URL { try root().appendingPathComponent(hash(id.uuidString), isDirectory: true) }
    private func workspaceMarker(_ id: UUID) throws -> URL { try root().appendingPathComponent("workspace-" + hash(id.uuidString) + ".retired") }
    private func recordMarker(_ workspace: UUID, _ id: UUID) throws -> URL { try root().appendingPathComponent("record-" + hash(workspace.uuidString + ":" + id.uuidString) + ".retired") }
    private func mediaMarker(_ workspace: UUID, _ id: UUID) throws -> URL { try root().appendingPathComponent("media-" + hash(workspace.uuidString + ":" + id.uuidString) + ".retired") }
    private func retired(_ target: CaptureTarget, mediaID: UUID? = nil) throws -> Bool {
        if FileManager.default.fileExists(atPath: try workspaceMarker(target.workspaceID).path) { return true }
        if target.kind == .receiptEvidence, FileManager.default.fileExists(atPath: try recordMarker(target.workspaceID, target.containerID).path) { return true }
        if let mediaID, FileManager.default.fileExists(atPath: try mediaMarker(target.workspaceID, mediaID).path) { return true }
        return false
    }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func readUnlocked(_ url: URL) throws -> SourceMediaRecord {
        try ensureNotLink(url); try ensureNotLink(url.deletingLastPathComponent())
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= ScanLimits.maximumRecordBytes else { throw ScanFailure.storage }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: ScanLimits.maximumRecordBytes + 1) ?? Data()
        guard bytes.count <= ScanLimits.maximumRecordBytes else { throw ScanFailure.tooLarge }
        let result = try JSONDecoder().decode(SourceMediaRecord.self, from: bytes)
        try result.validate(); return result
    }
    private func recordFiles(_ directory: URL) throws -> [URL] {
        try ensureNotLink(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard files.count <= ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.tooLarge }
        for file in files {
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  file.lastPathComponent == id.uuidString.lowercased() + ".json" else { throw ScanFailure.storage }
            try ensureNotLink(file)
        }
        return files
    }
    private func removeExact(_ record: SourceMediaRecord) throws {
        try withLock {
            let url = try workspaceDirectory(record.target.workspaceID).appendingPathComponent(record.id.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: url.path), try readUnlocked(url) == record { try FileManager.default.removeItem(at: url) }
        }
    }
    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let directory = try root(); try ensureDirectory(directory)
        let lock = directory.appendingPathComponent("store.lock")
        if FileManager.default.fileExists(atPath: lock.path) { try ensureNotLink(lock) }
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ScanFailure.storage }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ScanFailure.storage }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    private func ensureNotLink(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ScanFailure.storage }
    }
    private func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try ensureNotLink(url)
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ScanFailure.storage }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var value = url; var resource = URLResourceValues(); resource.isExcludedFromBackup = true; try value.setResourceValues(resource)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    private func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try ensureNotLink(url) }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
