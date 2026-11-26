import CoreDomain
import CryptoKit
import Foundation

public enum CookingSourceKind: String, Sendable { case recipe, dinner, reusableDinner }

public struct CookingSessionKey: Hashable, Sendable {
    public let workspace: UUID
    public let kind: CookingSourceKind
    public let source: UUID
    public let revision: String
    fileprivate let digest: String
    let privateAudienceFilename: String

    public init(workspace: UUID, actor: UUID, audience: [String?], kind: CookingSourceKind, source: UUID, revision: String) throws {
        guard !revision.isEmpty, revision.utf8.count <= 256, audience.count <= 8,
              audience.allSatisfy({ ($0?.utf8.count ?? 0) <= 512 }) else { throw CookingSessionError.invalid }
        self.workspace = workspace
        self.kind = kind
        self.source = source
        self.revision = revision
        privateAudienceFilename = SHA256.hash(data: try JSONEncoder().encode([actor.uuidString] + audience)).map { String(format: "%02x", $0) }.joined()
        let identity = [actor.uuidString, revision] + audience
        digest = SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CookingSessionError: Error { case invalid, stale, capacity }

public struct CookingTimer: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let step: Int
    public let seconds: Int
    public var deadline: Date?
    public var pausedSeconds: Int?
    public var alert: Bool
    public func remaining(at now: Date) -> Int {
        if let pausedSeconds { return pausedSeconds }
        guard let deadline else { return 0 }
        let interval = deadline.timeIntervalSince(now)
        guard interval.isFinite else { return 0 }
        return Int(min(Double(seconds), max(0, ceil(interval))))
    }
}

public struct CookingSession: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public var step: Int
    public var stepAmounts: CookingStepAmounts?
    public var timers: [CookingTimer]
    public init() { version = 1; id = UUID(); step = 0; timers = [] }
    public mutating func start(minutes: Int, step: Int, alert: Bool, at now: Date) throws {
        guard (1...1440).contains(minutes), step >= 0 else { throw CookingSessionError.invalid }
        guard timers.count < 8 else { throw CookingSessionError.capacity }
        let duration = minutes * 60
        timers.append(CookingTimer(id: UUID(), step: step, seconds: duration,
            deadline: now.addingTimeInterval(Double(duration)), pausedSeconds: nil, alert: alert))
    }
    public mutating func pause(_ id: UUID, at now: Date) throws {
        guard let i = timers.firstIndex(where: { $0.id == id }), timers[i].deadline != nil,
              timers[i].remaining(at: now) > 0 else { throw CookingSessionError.stale }
        timers[i].pausedSeconds = timers[i].remaining(at: now)
        timers[i].deadline = nil
    }
    public mutating func resume(_ id: UUID, at now: Date) throws {
        guard let i = timers.firstIndex(where: { $0.id == id }), let remaining = timers[i].pausedSeconds else {
            throw CookingSessionError.stale
        }
        timers[i].deadline = now.addingTimeInterval(Double(remaining))
        timers[i].pausedSeconds = nil
    }
    public mutating func remove(_ id: UUID) { timers.removeAll { $0.id == id } }

    fileprivate func validate(count: Int) throws {
        try stepAmounts?.validate(stepCount: count)
        guard version == 1, (1...1000).contains(count), (0..<count).contains(step), timers.count <= 8,
              Set(timers.map(\.id)).count == timers.count else { throw CookingSessionError.invalid }
        for timer in timers {
            guard (0..<count).contains(timer.step), (1...86400).contains(timer.seconds),
                  (timer.pausedSeconds == nil) != (timer.deadline == nil),
                  timer.pausedSeconds.map({ (1...timer.seconds).contains($0) }) ?? true,
                  timer.deadline.map({ abs($0.timeIntervalSince1970) < 253402300800 }) ?? true else {
                throw CookingSessionError.invalid
            }
        }
    }
}

/// The containing app owns these files. The main actor serializes their read/compare/write
/// operations across presentations. Files include reviewed measures and timer state for the exact source revision.
@MainActor public final class CookingSessionStore {
    private let root: URL
    public init(directory: URL) { root = directory }
    func file(_ key: CookingSessionKey) -> URL {
        root.appendingPathComponent(key.workspace.uuidString, isDirectory: true)
            .appendingPathComponent(key.kind.rawValue, isDirectory: true)
            .appendingPathComponent(key.source.uuidString, isDirectory: true).appendingPathComponent(key.digest + ".json")
    }
    private func read(_ url: URL) throws -> CookingSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let facts = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink != true,
              let size = facts.fileSize, size <= 262_144 else { throw CookingSessionError.invalid }
        return try JSONDecoder().decode(CookingSession.self, from: Data(contentsOf: url))
    }
    public func load(_ key: CookingSessionKey, stepCount: Int) throws -> CookingSession? {
        let value = try read(file(key))
        try value?.validate(count: stepCount)
        return value
    }
    public func replace(_ expected: CookingSession?, with next: CookingSession?, for key: CookingSessionKey, stepCount: Int) throws {
        let url = file(key)
        guard try load(key, stepCount: stepCount) == expected else { throw CookingSessionError.stale }
        guard let next else {
            if expected != nil { try FileManager.default.removeItem(at: url) }
            return
        }
        try next.validate(count: stepCount)
        guard expected == nil || next.id == expected?.id else { throw CookingSessionError.stale }
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var availability = URLResourceValues()
        availability.isExcludedFromBackup = true
        try folder.setResourceValues(availability)
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 262_144 else { throw CookingSessionError.capacity }
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
    public func erase(workspace: UUID) throws -> [CookingTimer] {
        try eraseFolder(root.appendingPathComponent(workspace.uuidString, isDirectory: true))
    }
    public func eraseUnretainedRecipes(retaining ids: Set<UUID>) throws -> [CookingTimer] {
        let files = FileManager.default
        guard files.fileExists(atPath: root.path) else { return [] }
        var removed: [CookingTimer] = []
        for workspace in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where UUID(uuidString: workspace.lastPathComponent) != nil {
            let recipes = workspace.appendingPathComponent(CookingSourceKind.recipe.rawValue, isDirectory: true)
            guard files.fileExists(atPath: recipes.path) else { continue }
            for copy in try files.contentsOfDirectory(at: recipes, includingPropertiesForKeys: nil) {
                if let id = UUID(uuidString: copy.lastPathComponent), !ids.contains(id) {
                    removed += try eraseFolder(copy)
                }
            }
        }
        return removed
    }
    private func eraseFolder(_ folder: URL) throws -> [CookingTimer] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        var timers: [CookingTimer] = []
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "json", let saved = try read(url) { timers += saved.timers }
        }
        try FileManager.default.removeItem(at: folder)
        return timers
    }
}
