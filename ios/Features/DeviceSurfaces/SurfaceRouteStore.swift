import Foundation
import DeviceSurfaces
import Darwin

enum SurfacePrivateTarget: Codable, Equatable {
    case shop(workspaceID: UUID, shopID: UUID)
    case offer(workspaceID: UUID, journeyID: UUID, offerID: UUID)
    case deferral(workspaceID: UUID, journeyID: UUID, needID: UUID)
    var id: UUID {
        switch self { case .shop(_, let id): return id; case .offer(_, _, let id): return id; case .deferral(_, _, let id): return id }
    }
    func belongsToLedger(_ id: UUID) -> Bool { if case .shop(let workspace, _) = self { return workspace == id }; return false }
    func belongsToPickup(_ workspace: UUID, _ record: UUID) -> Bool {
        switch self { case .shop: return false; case .offer(let w, let j, _), .deferral(let w, let j, _): return w == workspace && j == record }
    }
}
struct SurfaceRouteRecord: Codable, Equatable {
    let route: PrivateRoute
    let target: SurfacePrivateTarget
    let sourceRevision: Int64
    let reminderID: UUID?
}
/// Private locators survive restart. All authorization comes from current app models.
final class SurfaceRouteStore {
    private struct Document: Codable { let version: Int; let routes: [SurfaceRouteRecord] }
    private let url: URL
    init(url: URL) throws {
        guard url.isFileURL else { throw SurfaceError.invalid }; self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.deletingLastPathComponent().path)
        #endif
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SurfaceError.unavailable }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SurfaceError.unavailable }; defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func read() throws -> [SurfaceRouteRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true, let count = attributes.fileSize, count <= 1_048_576 else { throw SurfaceError.corrupt }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw SurfaceError.unsupported }
        let rows = document.routes
        guard rows.count <= 512, Set(rows.map(\.route.handle)).count == rows.count,
              rows.allSatisfy({ $0.target.id == $0.route.targetID && $0.sourceRevision >= 0 && $0.route.expiresAt.timeIntervalSince1970.isFinite }) else { throw SurfaceError.corrupt }
        return rows
    }
    private func write(_ rows: [SurfaceRouteRecord]) throws {
        guard rows.count <= 512 else { throw SurfaceError.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Document(version: 1, routes: rows)); guard bytes.count <= 1_048_576 else { throw SurfaceError.capacity }
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: [.atomic])
        #endif
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    func all() throws -> [SurfaceRouteRecord] { try locked { try read() } }
    func put(_ row: SurfaceRouteRecord) throws {
        try locked {
            var rows = try read()
            if let old = rows.first(where: { $0.route.handle == row.route.handle }) { guard old == row else { throw SurfaceError.changedReplay }; return }
            rows.append(row); try write(rows)
        }
    }
    func remove(_ handle: RouteHandle) throws { try locked { try write(read().filter { $0.route.handle != handle }) } }
}
