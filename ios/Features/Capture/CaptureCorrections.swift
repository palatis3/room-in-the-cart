import Foundation
import CryptoKit
import Combine

struct CaptureCorrectionScope: Equatable, Hashable, Sendable {
    let profileID: String
    let localeIdentifier: String
    let accountID: String?
    fileprivate var previousFileKey: String?
    var isPreviousRegion: Bool { previousFileKey != nil }

    // The language of the app's labels can differ from the region used for formatting.
    static func appLanguage(_ localization: String = Bundle.main.preferredLocalizations.first ?? "en") -> String {
        Locale(identifier: localization).language.languageCode?.identifier == "es" ? "es-US" : "en-US"
    }

    init(profileID: String, localeIdentifier: String) {
        self.init(profileID: profileID, localeIdentifier: localeIdentifier, accountID: nil)
    }
    private init(profileID: String, localeIdentifier: String, accountID: String?) {
        self.profileID = profileID
        self.localeIdentifier = Locale(identifier: localeIdentifier).identifier.replacingOccurrences(of: "_", with: "-")
        self.accountID = accountID
    }
    static func connected(subject: String, householdID: String, memberID: String, localeIdentifier: String) -> Self? {
        guard let household = UUID(uuidString: householdID), let member = UUID(uuidString: memberID),
              validAccountID(subject) else { return nil }
        return Self(profileID: household.uuidString + ":" + member.uuidString,
                    localeIdentifier: localeIdentifier, accountID: subject)
    }
    fileprivate static func validAccountID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 300 && !value.contains("@")
    }
}
struct CaptureCorrection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let original: String
    let replacement: String
    let createdAt: Date
}
struct CaptureCorrectionSnapshot: Codable, Equatable, Sendable {
    var enabled = false
    var entries: [CaptureCorrection] = []
}
enum CaptureCorrectionFailure: Error { case invalidScope, invalidProduct, disabled, storage }

/// Optional local product fragments only. No raw audio, transcript list, sync, or shared archive.
actor CaptureCorrectionStore {
    static let shared = CaptureCorrectionStore()
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }

    func load(_ scope: CaptureCorrectionScope) throws -> CaptureCorrectionSnapshot {
        let url = try file(scope)
        if try isErased(scope) { return .init() }
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 128_001) ?? Data()
        guard bytes.count <= 128_000 else { throw CaptureCorrectionFailure.storage }
        let snapshot = try JSONDecoder().decode(CaptureCorrectionSnapshot.self, from: bytes)
        guard snapshot.entries.count <= 100,
              snapshot.entries.allSatisfy({ Self.validProduct($0.original) && Self.validProduct($0.replacement) }) else {
            throw CaptureCorrectionFailure.storage
        }
        return snapshot
    }
    /// Older list captures keyed private spellings by the full formatting locale.
    /// Keep those opt-ins separate: an absent current-language file may mean the user opted out.
    func previousRegionalScopes(for scope: CaptureCorrectionScope) throws -> [CaptureCorrectionScope] {
        try validate(scope)
        guard scope.accountID == nil, try !isErased(scope) else { return [] }
        let directory = try profileDirectory(scope)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let prefix = Self.digest(scope.profileID) + "-"
        let currentKeys = [Self.digest("en-US"), Self.digest("es-US")]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let keys = files.compactMap { url -> String? in
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", stem.hasPrefix(prefix) else { return nil }
            let key = String(stem.dropFirst(prefix.count))
            guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !currentKeys.contains(key) else { return nil }
            return key
        }
        guard !keys.isEmpty else { return [] }
        var names = Self.regionalNames
        let current = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        names[Self.digest(current)] = current
        return keys.sorted().map { key in
            // Legacy filenames contain only a hash. A custom region may no longer
            // be identifiable, but its owner can still inspect and delete that file.
            var previous = CaptureCorrectionScope(profileID: scope.profileID, localeIdentifier: names[key] ?? "und")
            previous.previousFileKey = key
            return previous
        }
    }

    private static let regionalNames: [String: String] = {
        var names = [String: String]()
        for id in Locale.availableIdentifiers {
            let locale = Locale(identifier: id)
            guard ["en", "es"].contains(locale.language.languageCode?.identifier ?? "") else { continue }
            let name = locale.identifier.replacingOccurrences(of: "_", with: "-")
            names[digest(name)] = name
        }
        return names
    }()

    func setEnabled(_ enabled: Bool, scope: CaptureCorrectionScope) throws {
        if !enabled {
            let url = try file(scope)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        guard !scope.isPreviousRegion else { throw CaptureCorrectionFailure.invalidScope }
        var value = try load(scope); value.enabled = true
        try save(value, scope: scope)
    }
    func remember(original: String, replacement: String, scope: CaptureCorrectionScope) throws {
        guard !scope.isPreviousRegion else { throw CaptureCorrectionFailure.invalidScope }
        guard Self.validProduct(original), Self.validProduct(replacement), Self.key(original) != Self.key(replacement) else {
            throw CaptureCorrectionFailure.invalidProduct
        }
        var value = try load(scope)
        guard value.enabled else { throw CaptureCorrectionFailure.disabled }
        value.entries.removeAll { Self.key($0.original) == Self.key(original) }
        value.entries.append(.init(id: UUID(), original: original, replacement: replacement, createdAt: Date()))
        if value.entries.count > 100 { value.entries.removeFirst(value.entries.count - 100) }
        try save(value, scope: scope)
    }
    func forget(_ id: UUID, scope: CaptureCorrectionScope) throws {
        var value = try load(scope)
        guard value.enabled, let index = value.entries.firstIndex(where: { $0.id == id }) else { return }
        value.entries.remove(at: index)
        try save(value, scope: scope)
    }
    /// Erases all locale files for the retired profile. Root composes this into durable erasure cleanup.
    func eraseProfile(_ scope: CaptureCorrectionScope) async throws {
        try validate(scope)
        let directory = try profileDirectory(scope)
        try retire(at: marker(scope))
        let prefix = Self.digest(scope.profileID) + "-"
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            try FileManager.default.removeItem(at: url)
        }
    }
    /// Account deletion also clears spelling files for memberships that are no longer selected.
    func eraseConnectedAccount(_ subject: String) throws {
        guard CaptureCorrectionScope.validAccountID(subject) else { throw CaptureCorrectionFailure.invalidScope }
        let directory = try accountDirectory(subject)
        try retire(at: directory.appendingPathExtension("erased"))
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    nonisolated static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    nonisolated static func validProduct(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160, !trimmed.contains(where: { $0.isNumber || $0.isNewline }),
              !CaptureLimits.containsExclusion(trimmed) else { return false }
        let words = Set(key(trimmed).split(whereSeparator: { !$0.isLetter }).map(String.init))
        return words.isDisjoint(with: ["free", "libre", "allergen", "allergy", "alergia"])
    }
    private func validate(_ scope: CaptureCorrectionScope) throws {
        guard !scope.profileID.isEmpty, scope.profileID.utf8.count <= 300,
              !scope.profileID.contains("@"), scope.isPreviousRegion || ["en", "es"].contains(Locale(identifier: scope.localeIdentifier).language.languageCode?.identifier ?? "") else {
            throw CaptureCorrectionFailure.invalidScope
        }
    }
    private func root() throws -> URL {
        if let directory { return directory }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return Self.defaultDirectory(applicationSupport: base, arguments: ProcessInfo.processInfo.arguments)
    }
    nonisolated static func defaultDirectory(applicationSupport: URL, arguments: [String]) -> URL {
        #if DEBUG
        if arguments.contains("--ui-testing") {
            return applicationSupport.appendingPathComponent("UITestWorkspace/CaptureCorrections", isDirectory: true)
        }
        #endif
        return applicationSupport.appendingPathComponent("RoomInTheCart/CaptureCorrections", isDirectory: true)
    }
    private func marker(_ scope: CaptureCorrectionScope) throws -> URL {
        try profileDirectory(scope).appendingPathComponent(Self.digest(scope.profileID) + ".erased")
    }
    private func accountDirectory(_ subject: String) throws -> URL {
        try root().appendingPathComponent("Connected", isDirectory: true)
            .appendingPathComponent(Self.digest(subject), isDirectory: true)
    }
    private func profileDirectory(_ scope: CaptureCorrectionScope) throws -> URL {
        if let subject = scope.accountID { return try accountDirectory(subject) }
        return try root()
    }
    private func isErased(_ scope: CaptureCorrectionScope) throws -> Bool {
        if let subject = scope.accountID,
           FileManager.default.fileExists(atPath: try accountDirectory(subject).appendingPathExtension("erased").path) { return true }
        return FileManager.default.fileExists(atPath: try marker(scope).path)
    }
    private func file(_ scope: CaptureCorrectionScope) throws -> URL {
        try validate(scope)
        return try profileDirectory(scope).appendingPathComponent(Self.digest(scope.profileID) + "-" + (scope.previousFileKey ?? Self.digest(scope.localeIdentifier)) + ".json")
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func prepareDirectory(_ url: URL) throws {
        var directory = url
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
    }
    private func retire(at url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        // The content-free marker rejects late writes across process restarts.
        #if os(iOS)
        try Data().write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try Data().write(to: url, options: .atomic)
        #endif
    }
    private func save(_ value: CaptureCorrectionSnapshot, scope: CaptureCorrectionScope) throws {
        let url = try file(scope)
        guard try !isErased(scope) else { throw CaptureCorrectionFailure.invalidScope }
        try prepareDirectory(url.deletingLastPathComponent())
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 128_000 else { throw CaptureCorrectionFailure.storage }
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
}

@MainActor final class CaptureCorrectionsModel: ObservableObject {
    @Published private(set) var snapshot = CaptureCorrectionSnapshot()
    @Published private(set) var scope: CaptureCorrectionScope?
    @Published private(set) var previousRegions: [CaptureCorrectionScope] = []
    @Published private(set) var failed = false
    private let store: CaptureCorrectionStore
    private var generation = UUID()
    init(store: CaptureCorrectionStore = .shared) { self.store = store }
    func bind(_ scope: CaptureCorrectionScope?, includePreviousRegions: Bool = false) async {
        invalidate(); self.scope = scope
        guard let scope else { return }
        let generation = self.generation
        do {
            let value = try await store.load(scope)
            let previous = includePreviousRegions ? try await store.previousRegionalScopes(for: scope) : []
            guard self.generation == generation, self.scope == scope else { return }
            previousRegions = previous
            snapshot = value
        } catch { if self.generation == generation { failed = true } }
    }
    func invalidate() { generation = UUID(); scope = nil; snapshot = .init(); previousRegions = []; failed = false }
    func suggestion(for original: String) -> CaptureCorrection? {
        guard scope != nil, !failed, snapshot.enabled else { return nil }
        return snapshot.entries.first { CaptureCorrectionStore.key($0.original) == CaptureCorrectionStore.key(original) }
    }
    func setEnabled(_ enabled: Bool) async { await change { try await self.store.setEnabled(enabled, scope: $0) } }
    func remember(original: String, replacement: String) async {
        await change { try await self.store.remember(original: original, replacement: replacement, scope: $0) }
    }
    func forget(_ id: UUID) async { await change { try await self.store.forget(id, scope: $0) } }
    private func change(_ mutation: (CaptureCorrectionScope) async throws -> Void) async {
        guard let scope else { return }
        generation = UUID()
        let generation = self.generation
        do {
            try await mutation(scope)
            let value = try await store.load(scope)
            guard self.generation == generation, self.scope == scope else { return }
            snapshot = value; failed = false
        } catch { if self.generation == generation { failed = true } }
    }
}
