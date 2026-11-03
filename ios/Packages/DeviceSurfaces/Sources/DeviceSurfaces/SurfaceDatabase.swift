import Foundation
import CDeviceSQLite

enum DBValue { case text(String), double(Double), integer(Int64), null }
final class SurfaceDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, kind: String, schema: String) throws {
        guard url.isFileURL else { throw SurfaceError.unconfigured }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.deletingLastPathComponent().path)
        #endif
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SurfaceError.unavailable }
        do {
            sqlite3_busy_timeout(db, 5000)
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 2 * 1_048_576)
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            _ = try rows("PRAGMA secure_delete=ON")
            try transaction {
                let version = try rows("PRAGMA user_version").first?.first ?? nil
                if version == "0" {
                    guard try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else { throw SurfaceError.unsupported }
                    try execute("CREATE TABLE surface_metadata(kind TEXT PRIMARY KEY NOT NULL)")
                    try execute("INSERT INTO surface_metadata(kind) VALUES (?)", [.text(kind)])
                    try script(schema)
                    try execute("PRAGMA user_version=1")
                } else {
                    guard version == "1", try rows("SELECT kind FROM surface_metadata") == [[kind]] else { throw SurfaceError.unsupported }
                }
            }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    func script(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SurfaceError.unavailable } }
    @discardableResult func execute(_ sql: String, _ values: [DBValue] = []) throws -> Int {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SurfaceError.unavailable }
        return Int(sqlite3_changes(db))
    }
    func rows(_ sql: String, _ values: [DBValue] = []) throws -> [[String?]] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var output: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw SurfaceError.corrupt }
            output.append((0..<sqlite3_column_count(statement)).map { column in
                guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: pointer)
            })
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { _ = try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, _ values: [DBValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SurfaceError.corrupt }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1); let status: Int32
            switch value {
            case .text(let string): status = string.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let integer): status = sqlite3_bind_int64(statement, index, integer)
            case .double(let double): status = sqlite3_bind_double(statement, index, double)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { sqlite3_finalize(statement); throw SurfaceError.unavailable }
        }
        return statement
    }
}
