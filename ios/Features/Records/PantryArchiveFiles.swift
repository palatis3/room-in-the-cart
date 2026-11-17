import Foundation
import Darwin

/// Fixed-name protected worker storage. Never accepts a path component from an archive.
enum PantryArchiveFiles {
    enum Failure: Error { case invalid, io }
    static func directory(_ url: URL, create: Bool) throws {
        guard url.isFileURL else { throw Failure.invalid }
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, create else { throw Failure.invalid }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw Failure.io }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid }
        try protect(url, permissions: 0o700)
    }
    static func protect(_ url: URL, permissions: Int) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: permissions]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        var file = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.io }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximum else { throw Failure.invalid }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count == info.st_size else { throw Failure.invalid }; return bytes
    }
    static func write(_ bytes: Data, to url: URL) throws {
        var info = stat(); guard lstat(url.path, &info) != 0, errno == ENOENT else { throw Failure.invalid }
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
        try protect(url, permissions: 0o600)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    static func requireDirectory(_ url: URL) throws {
        var info = stat(); guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid }
    }
    static func requireRegular(_ url: URL) throws {
        var info = stat(); guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalid }
    }
}

/// Cancellation crosses the NSFileCoordinator callback queue through this one locked bit.
final class PantryArchiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// The directory itself carries the advisory lock. The kernel drops it on exit.
/// Root locking covers only creation and lease acquisition, never file reads.
final class PantryImportDirectory: @unchecked Sendable {
    let directory: URL
    var payload: URL { directory.appendingPathComponent("payload", isDirectory: true) }
    var marker: URL { directory.appendingPathComponent("confirmed.json") }
    private let fd: Int32

    private init(directory: URL, fd: Int32) { self.directory = directory; self.fd = fd }
    deinit { Darwin.close(fd) }

    static func ownsName(_ name: String) -> Bool {
        name.hasPrefix("review-") && UUID(uuidString: String(name.dropFirst(7)))?.uuidString == String(name.dropFirst(7))
    }

    static func create(in root: URL) throws -> PantryImportDirectory {
        try withRootLock(root) {
            let directory = root.appendingPathComponent("review-" + UUID().uuidString, isDirectory: true)
            try PantryArchiveFiles.directory(directory, create: true)
            guard let lease = try lock(directory) else { throw PantryArchiveFiles.Failure.io }
            return lease
        }
    }

    static func abandoned(_ directory: URL, root: URL) throws -> PantryImportDirectory? {
        guard ownsName(directory.lastPathComponent) else { throw PantryArchiveFiles.Failure.invalid }
        return try withRootLock(root) { try lock(directory) }
    }

    private static func lock(_ directory: URL) throws -> PantryImportDirectory? {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw PantryArchiveFiles.Failure.io
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            Darwin.close(fd)
            if busy { return nil }
            throw PantryArchiveFiles.Failure.io
        }
        return PantryImportDirectory(directory: directory, fd: fd)
    }

    private static func withRootLock<T>(_ root: URL, _ work: () throws -> T) throws -> T {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PantryArchiveFiles.Failure.io }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw PantryArchiveFiles.Failure.io }
        return try work()
    }
}
