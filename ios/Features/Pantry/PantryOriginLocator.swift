import Darwin
import Foundation
import LocalStore

/// One immutable, receipt-bound link per explicit fresh start. The original
/// database and each retired successor remain available for erasure evidence.
struct PantryOriginLocator {
    enum Failure: Error { case invalid, unavailable }
    private struct Link: Codable, Equatable {
        let version: Int
        let retired: UUID
        let operation: UUID
        let successor: UUID
    }
    let base: URL
    private var directory: URL { base.appendingPathExtension("origins") }

    private func marker(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func database(_ id: UUID) -> URL { folder(id).appendingPathComponent("pickup.sqlite") }

    private func exists(_ url: URL, kind: mode_t) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == kind else { throw Failure.invalid }
            return true
        }
        guard errno == ENOENT else { throw Failure.unavailable }
        return false
    }

    /// If a previously registered chain is damaged, never mint a fresh root.
    func checkBase() throws {
        if try exists(directory, kind: S_IFDIR), try !exists(base, kind: S_IFREG) { throw Failure.invalid }
    }

    private func read(_ id: UUID) throws -> Link? {
        guard try exists(directory, kind: S_IFDIR), try exists(marker(id), kind: S_IFREG) else { return nil }
        let data = try PantryArchiveFiles.read(marker(id), maximum: 1024)
        let value = try JSONDecoder().decode(Link.self, from: data)
        guard value.version == 1, value.retired == id, value.retired != value.successor else { throw Failure.invalid }
        return value
    }

    private func checkDatabase(_ id: UUID, requireExisting: Bool) throws {
        let present = try exists(database(id), kind: S_IFREG)
        guard present || !requireExisting else { throw Failure.invalid }
        for suffix in ["-wal", "-shm", "-journal"] {
            let companion = URL(fileURLWithPath: database(id).path + suffix)
            if try exists(companion, kind: S_IFREG), !present { throw Failure.invalid }
        }
    }

    func resolve(from initial: ComparisonStore, previous: Set<UUID>) async throws -> (store: ComparisonStore, retired: Set<UUID>) {
        var current = initial, retired = previous
        while let next = try read(current.workspaceID) {
            try Task.checkCancellation()
            guard retired.insert(current.workspaceID).inserted, !retired.contains(next.successor),
                  let receipt = try await current.inventoryOriginRetirement(), receipt.workspaceID == next.retired,
                  receipt.scope == .origin, receipt.operationID == next.operation,
                  try exists(folder(current.workspaceID), kind: S_IFDIR) else { throw Failure.invalid }
            try checkDatabase(current.workspaceID, requireExisting: true)
            let successor = try ComparisonStore(url: database(current.workspaceID), inventoryEnabled: true)
            guard successor.workspaceID == next.successor else { throw Failure.invalid }
            current = successor
        }
        return (current, retired)
    }

    /// Publish only after the empty database exists. A crash before publication
    /// leaves the retired origin selected and the same empty candidate reusable.
    @MainActor func start(after receipt: InventoryErasureReceipt, previous: Set<UUID>,
                          authorize: () -> Bool) async throws -> ComparisonStore {
        guard authorize(), receipt.scope == .origin, !previous.contains(receipt.workspaceID),
              try read(receipt.workspaceID) == nil else { throw Failure.invalid }
        try PantryArchiveFiles.directory(directory, create: true)
        try PantryArchiveFiles.directory(folder(receipt.workspaceID), create: true)
        try checkDatabase(receipt.workspaceID, requireExisting: false)
        let next = try ComparisonStore(url: database(receipt.workspaceID), inventoryEnabled: true)
        let state = try await next.inventoryState()
        guard !state.active, state.revision == 0, next.workspaceID != receipt.workspaceID,
              !previous.contains(next.workspaceID), try await next.inventoryPendingMigration() == nil,
              try await next.list().isEmpty, try await next.tombstones().isEmpty, authorize() else { throw Failure.invalid }
        let value = Link(version: 1, retired: receipt.workspaceID, operation: receipt.operationID, successor: next.workspaceID)
        let staged = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try PantryArchiveFiles.write(JSONEncoder().encode(value), to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        // link(2) publishes complete protected bytes without replacing an existing choice.
        if Darwin.link(staged.path, marker(receipt.workspaceID).path) != 0 {
            guard errno == EEXIST, try read(receipt.workspaceID) == value else { throw Failure.unavailable }
        }
        return next
    }
}
