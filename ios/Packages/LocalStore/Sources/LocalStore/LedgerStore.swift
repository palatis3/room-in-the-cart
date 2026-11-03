import Foundation
import CryptoKit
import CSQLite

public struct LedgerRecord: Equatable, Sendable {
    public let workspaceID: UUID
    public let revision: Int64
    public let payload: Data
    public let savedAt: Date
    public let operationID: UUID
}

/// Permanent, payload-free evidence for the retired `ledger/{workspaceID}` origin.
public struct LedgerWorkspaceTombstone: Equatable, Sendable {
    public let workspaceID: UUID
    public let erasedRevision: Int64
    public let replacementWorkspaceID: UUID
    public let operationID: UUID
    public let erasedAt: Date
}

/// Errors deliberately contain no payload, SQL text, or filesystem path.
public enum LedgerStoreError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedSchema(Int64)
    case unrecognizedSchema
    case invalidInput
    case payloadTooLarge
    case staleRevision(expected: Int64, actual: Int64)
    case operationConflict
    case erased
    case corruptRecord
    case database(Int32)
    case closed
}

/// A separate, installation-local ledger database. The domain owns the opaque payload's
/// Codable format and version. SQLite stores its bytes directly, without a JSON envelope.
/// Each accepted operation appends an immutable whole-workspace snapshot atomically.
public actor LedgerStore {
    public nonisolated let workspaceID: UUID
    public nonisolated static let maximumPayloadBytes = 4 * 1_024 * 1_024
    private let database: LedgerDatabase

    /// The parent directory must already exist. Use a dedicated `ledger.sqlite` URL;
    /// this store cannot open or migrate the independent comparison database.
    public init(url: URL) throws {
        guard url.isFileURL else { throw LedgerStoreError.invalidURL }
        let database = try LedgerDatabase(url: url)
        do {
            // Inspect before any migration or persistent configuration. Unsupported and
            // corrupt databases remain available for recovery, never replaced or reset.
            // A read transaction keeps the schema, head, and history on one snapshot
            // while other connections initialize or append revisions.
            let version = try database.transaction(immediate: false) {
                let version = try database.integer("PRAGMA user_version")
                guard version <= 2 else { throw LedgerStoreError.unsupportedSchema(version) }
                guard version >= 0 else { throw LedgerStoreError.unrecognizedSchema }
                if version == 0 {
                    guard try database.integer("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0
                    else { throw LedgerStoreError.unrecognizedSchema }
                    try database.checkIntegrity()
                } else {
                    try database.validate(version: version)
                }
                return version
            }
            #if os(iOS)
            // Protect the database before its first payload write. Protecting the parent
            // also covers transient SQLite journals created during future transactions.
            let attributes: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.deletingLastPathComponent().path)
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
            for suffix in ["-journal", "-wal", "-shm"] {
                let path = url.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
                }
            }
            #endif
            try database.execute("PRAGMA foreign_keys = ON")
            try database.execute("PRAGMA synchronous = FULL")
            try database.execute("PRAGMA fullfsync = ON")
            try database.execute("PRAGMA secure_delete = ON")
            try database.execute("PRAGMA journal_size_limit = 0")
            if version < 2 { try database.migrate() }
            self.workspaceID = try database.workspace().id
            self.database = database
        } catch {
            try? database.close()
            throw error
        }
    }

    public func load() throws -> LedgerRecord? {
        try database.current(workspaceID: workspaceID)
    }

    /// Initial writes expect revision zero. Every new operation requires the current
    /// revision and appends a snapshot, including when its payload equals the current one.
    /// Replaying an operation with identical bytes and base returns its original record,
    /// even after newer commits. A retry's savedAt is ignored; the first timestamp wins.
    /// A reused operation ID with different bytes or base throws operationConflict.
    /// No result is returned until SQLite COMMIT succeeds.
    @discardableResult
    public func save(payload: Data, expectedRevision: Int64, operationID: UUID, savedAt: Date) throws -> LedgerRecord {
        guard payload.count <= Self.maximumPayloadBytes else { throw LedgerStoreError.payloadTooLarge }
        guard expectedRevision >= 0, savedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw LedgerStoreError.invalidInput }
        return try database.transaction {
            let current = try database.current(workspaceID: workspaceID)
            guard try !database.isRetiredOperation(operationID) else { throw LedgerStoreError.erased }
            guard try database.tombstones("WHERE operation_id = ?", values: [.text(operationID.uuidString)]).isEmpty
            else { throw LedgerStoreError.operationConflict }
            if let previous = try database.record(operationID: operationID, workspaceID: workspaceID) {
                guard previous.revision - 1 == expectedRevision, previous.payload == payload
                else { throw LedgerStoreError.operationConflict }
                return previous
            }
            let actualRevision = current?.revision ?? 0
            guard expectedRevision == actualRevision else {
                throw LedgerStoreError.staleRevision(expected: expectedRevision, actual: actualRevision)
            }
            guard actualRevision < Int64.max else { throw LedgerStoreError.invalidInput }
            let revision = actualRevision + 1
            try database.run("""
                INSERT INTO ledger_revisions
                    (workspace_id, revision, base_revision, operation_id, payload, payload_sha256, saved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.text(workspaceID.uuidString), .integer(revision), .integer(expectedRevision),
                      .text(operationID.uuidString), .blob(payload), .blob(Data(SHA256.hash(data: payload))),
                      .real(savedAt.timeIntervalSinceReferenceDate)])
            let changed = try database.run("""
                UPDATE ledger_workspace SET head_revision = ?
                WHERE singleton = 1 AND id = ? AND COALESCE(head_revision, 0) = ?
                """, [.integer(revision), .text(workspaceID.uuidString), .integer(expectedRevision)])
            guard changed == 1 else { throw LedgerStoreError.corruptRecord }
            return LedgerRecord(workspaceID: workspaceID, revision: revision, payload: payload,
                                savedAt: savedAt, operationID: operationID)
        }
    }

    /// Permanently erases this entire workspace, including all shops, reusable meals,
    /// historical snapshots, and private save receipts. Requires explicit whole-workspace
    /// confirmation at the current revision (zero for an empty workspace). There is no undo.
    /// A fresh empty workspace is created in the same transaction. This actor keeps its
    /// original workspaceID; its subsequent load/save calls throw `erased`. Close/reopen
    /// the store and clear UI drafts/pending bytes before using the replacement workspace.
    ///
    /// An exact operation/workspace/revision retry returns the original replacement ID and
    /// timestamp, including from a newly opened actor. Retired save-operation UUIDs remain
    /// as payload-free metadata, so replaying an old save on a new actor also throws `erased`.
    /// Recovery must reject the whole retired origin, including previously unseen shop IDs.
    /// secure_delete and best-effort WAL truncation do not erase external backups, active
    /// reader snapshots, or filesystem/media copies. Success is returned only after COMMIT.
    @discardableResult
    public func eraseWorkspace(workspaceID target: UUID, expectedRevision: Int64,
                               operationID: UUID, at: Date) throws -> LedgerWorkspaceTombstone {
        guard expectedRevision >= 0, at.timeIntervalSinceReferenceDate.isFinite
        else { throw LedgerStoreError.invalidInput }
        let receipt = try database.transaction {
            if let previous = try database.tombstones("WHERE operation_id = ?", values: [.text(operationID.uuidString)]).first {
                guard previous.workspaceID == target, previous.erasedRevision == expectedRevision
                else { throw LedgerStoreError.operationConflict }
                return previous
            }
            guard try !database.isRetiredWorkspace(target), try !database.isRetiredOperation(operationID)
            else { throw LedgerStoreError.erased }
            let current = try database.workspace()
            if current.id != workspaceID {
                guard try !database.isRetiredWorkspace(workspaceID) else { throw LedgerStoreError.erased }
                throw LedgerStoreError.corruptRecord
            }
            guard target == workspaceID else { throw LedgerStoreError.invalidInput }
            guard expectedRevision == current.revision else {
                throw LedgerStoreError.staleRevision(expected: expectedRevision, actual: current.revision)
            }
            guard try !database.hasSaveOperation(operationID) else { throw LedgerStoreError.operationConflict }
            var replacement = UUID()
            while try database.isRetiredWorkspace(replacement) || replacement == target { replacement = UUID() }
            try database.run("""
                INSERT INTO ledger_workspace_tombstones
                    (workspace_id, erased_revision, replacement_workspace_id, operation_id, erased_at)
                VALUES (?, ?, ?, ?, ?)
                """, [.text(target.uuidString), .integer(expectedRevision), .text(replacement.uuidString),
                      .text(operationID.uuidString), .real(at.timeIntervalSinceReferenceDate)])
            try database.run("""
                INSERT INTO ledger_retired_operations (operation_id, workspace_id)
                SELECT operation_id, workspace_id FROM ledger_revisions WHERE workspace_id = ?
                """, [.text(target.uuidString)])
            try database.run("DELETE FROM ledger_revisions WHERE workspace_id = ?", [.text(target.uuidString)])
            let removed = try database.run("DELETE FROM ledger_workspace WHERE id = ? AND COALESCE(head_revision, 0) = ?",
                                           [.text(target.uuidString), .integer(expectedRevision)])
            guard removed == 1 else { throw LedgerStoreError.corruptRecord }
            try database.run("INSERT INTO ledger_workspace (singleton, id) VALUES (1, ?)", [.text(replacement.uuidString)])
            return LedgerWorkspaceTombstone(workspaceID: target, erasedRevision: expectedRevision,
                replacementWorkspaceID: replacement, operationID: operationID, erasedAt: at)
        }
        database.checkpointAfterErasure()
        return receipt
    }

    public func tombstones() throws -> [LedgerWorkspaceTombstone] {
        try database.tombstones("ORDER BY erased_at, workspace_id", values: [])
    }

    public func retiredWorkspaceIDs() throws -> [UUID] { try tombstones().map(\.workspaceID) }

    /// Idempotent. Releasing the actor also closes its connection.
    public func close() throws { try database.close() }
}

private enum LedgerValue {
    case text(String), integer(Int64), real(Double), blob(Data)
}

/// Exclusively owned by its LedgerStore actor after synchronous initialization.
private final class LedgerDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let applicationID: Int64 = 0x5249544C // RITL
    private static let columns = "workspace_id, revision, base_revision, operation_id, payload, payload_sha256, saved_at"

    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            sqlite3_close_v2(handle)
            handle = nil
            throw LedgerStoreError.database(status)
        }
        sqlite3_busy_timeout(handle, 5_000)
        // SQLite's length limit includes the complete encoded row, not just its BLOB.
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(LedgerStore.maximumPayloadBytes + 65_536))
    }

    deinit { sqlite3_close_v2(handle) }

    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw LedgerStoreError.database(result) }
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw LedgerStoreError.closed }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw LedgerStoreError.database(result) }
    }

    func transaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        try execute(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func migrate() throws {
        try transaction {
            // A second connection may have completed migration while we waited.
            var version = try integer("PRAGMA user_version")
            if version == 2 { try validate(version: 2); return }
            guard version == 0 || version == 1 else { throw LedgerStoreError.unsupportedSchema(version) }
            if version == 0 {
                guard try integer("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0
                else { throw LedgerStoreError.unrecognizedSchema }
                try checkIntegrity()
                try execute("""
                CREATE TABLE ledger_workspace (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    id TEXT NOT NULL UNIQUE CHECK(typeof(id) = 'text' AND length(id) = 36),
                    head_revision INTEGER CHECK(head_revision IS NULL OR (typeof(head_revision) = 'integer' AND head_revision > 0)),
                    FOREIGN KEY (id, head_revision) REFERENCES ledger_revisions(workspace_id, revision)
                        DEFERRABLE INITIALLY DEFERRED
                );
                CREATE TABLE ledger_revisions (
                    workspace_id TEXT NOT NULL REFERENCES ledger_workspace(id),
                    revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0),
                    base_revision INTEGER NOT NULL CHECK(typeof(base_revision) = 'integer' AND base_revision >= 0 AND base_revision = revision - 1),
                    operation_id TEXT NOT NULL UNIQUE CHECK(typeof(operation_id) = 'text' AND length(operation_id) = 36),
                    payload BLOB NOT NULL CHECK(typeof(payload) = 'blob' AND length(payload) <= \(LedgerStore.maximumPayloadBytes)),
                    payload_sha256 BLOB NOT NULL CHECK(typeof(payload_sha256) = 'blob' AND length(payload_sha256) = 32),
                    saved_at REAL NOT NULL CHECK(typeof(saved_at) IN ('real', 'integer')),
                    PRIMARY KEY (workspace_id, revision)
                );
                CREATE TRIGGER ledger_revision_immutable_update BEFORE UPDATE ON ledger_revisions
                BEGIN SELECT RAISE(ABORT, 'immutable ledger revision'); END;
                CREATE TRIGGER ledger_revision_immutable_delete BEFORE DELETE ON ledger_revisions
                BEGIN SELECT RAISE(ABORT, 'immutable ledger revision'); END;
                CREATE TRIGGER ledger_workspace_immutable_identity BEFORE UPDATE OF id, singleton ON ledger_workspace
                BEGIN SELECT RAISE(ABORT, 'immutable ledger identity'); END;
                CREATE TRIGGER ledger_workspace_immutable_delete BEFORE DELETE ON ledger_workspace
                BEGIN SELECT RAISE(ABORT, 'immutable ledger identity'); END;
                PRAGMA application_id = \(Self.applicationID);
                PRAGMA user_version = 1;
                """)
                try run("INSERT INTO ledger_workspace (singleton, id) VALUES (1, ?)", [.text(UUID().uuidString)])
                version = 1
            }
            if version == 1 {
                try validate(version: 1)
                try execute("""
                    CREATE TABLE ledger_workspace_tombstones (
                        workspace_id TEXT PRIMARY KEY NOT NULL CHECK(typeof(workspace_id) = 'text' AND length(workspace_id) = 36),
                        erased_revision INTEGER NOT NULL CHECK(typeof(erased_revision) = 'integer' AND erased_revision >= 0),
                        replacement_workspace_id TEXT NOT NULL UNIQUE CHECK(typeof(replacement_workspace_id) = 'text' AND length(replacement_workspace_id) = 36 AND replacement_workspace_id != workspace_id),
                        operation_id TEXT NOT NULL UNIQUE CHECK(typeof(operation_id) = 'text' AND length(operation_id) = 36),
                        erased_at REAL NOT NULL CHECK(typeof(erased_at) IN ('real', 'integer'))
                    );
                    CREATE TABLE ledger_retired_operations (
                        operation_id TEXT PRIMARY KEY NOT NULL CHECK(typeof(operation_id) = 'text' AND length(operation_id) = 36),
                        workspace_id TEXT NOT NULL REFERENCES ledger_workspace_tombstones(workspace_id)
                    );
                    CREATE TRIGGER ledger_tombstone_requires_current_revision BEFORE INSERT ON ledger_workspace_tombstones
                    WHEN NOT EXISTS (SELECT 1 FROM ledger_workspace WHERE id = NEW.workspace_id AND COALESCE(head_revision, 0) = NEW.erased_revision)
                        OR EXISTS (SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = NEW.replacement_workspace_id)
                    BEGIN SELECT RAISE(ABORT, 'invalid retirement'); END;
                    CREATE TRIGGER ledger_tombstone_immutable_update BEFORE UPDATE ON ledger_workspace_tombstones
                    BEGIN SELECT RAISE(ABORT, 'immutable retirement'); END;
                    CREATE TRIGGER ledger_tombstone_immutable_delete BEFORE DELETE ON ledger_workspace_tombstones
                    BEGIN SELECT RAISE(ABORT, 'immutable retirement'); END;
                    CREATE TRIGGER ledger_retired_operation_requires_snapshot BEFORE INSERT ON ledger_retired_operations
                    WHEN NOT EXISTS (SELECT 1 FROM ledger_revisions WHERE operation_id = NEW.operation_id AND workspace_id = NEW.workspace_id)
                    BEGIN SELECT RAISE(ABORT, 'invalid retired operation'); END;
                    CREATE TRIGGER ledger_retired_operation_immutable_update BEFORE UPDATE ON ledger_retired_operations
                    BEGIN SELECT RAISE(ABORT, 'immutable retired operation'); END;
                    CREATE TRIGGER ledger_retired_operation_immutable_delete BEFORE DELETE ON ledger_retired_operations
                    BEGIN SELECT RAISE(ABORT, 'immutable retired operation'); END;
                    DROP TRIGGER ledger_revision_immutable_delete;
                    CREATE TRIGGER ledger_revision_immutable_delete BEFORE DELETE ON ledger_revisions
                    WHEN NOT EXISTS (
                        SELECT 1 FROM ledger_workspace_tombstones t JOIN ledger_retired_operations o ON o.workspace_id = t.workspace_id
                        WHERE t.workspace_id = OLD.workspace_id AND t.erased_revision >= OLD.revision AND o.operation_id = OLD.operation_id
                    )
                    BEGIN SELECT RAISE(ABORT, 'immutable ledger revision'); END;
                    DROP TRIGGER ledger_workspace_immutable_delete;
                    CREATE TRIGGER ledger_workspace_immutable_delete BEFORE DELETE ON ledger_workspace
                    WHEN NOT EXISTS (SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = OLD.id AND erased_revision = COALESCE(OLD.head_revision, 0))
                    BEGIN SELECT RAISE(ABORT, 'immutable ledger identity'); END;
                    CREATE TRIGGER ledger_retired_workspace_insert BEFORE INSERT ON ledger_workspace
                    WHEN EXISTS (SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = NEW.id)
                    BEGIN SELECT RAISE(ABORT, 'retired workspace'); END;
                    CREATE TRIGGER ledger_retired_workspace_update BEFORE UPDATE ON ledger_workspace
                    WHEN EXISTS (SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = OLD.id)
                    BEGIN SELECT RAISE(ABORT, 'retired workspace'); END;
                    CREATE TRIGGER ledger_retired_revision_insert BEFORE INSERT ON ledger_revisions
                    WHEN EXISTS (SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = NEW.workspace_id OR operation_id = NEW.operation_id)
                        OR EXISTS (SELECT 1 FROM ledger_retired_operations WHERE operation_id = NEW.operation_id)
                    BEGIN SELECT RAISE(ABORT, 'retired workspace or operation'); END;
                    PRAGMA user_version = 2;
                    """)
            }
        }
    }

    /// Validate all retained snapshots before opening an existing database for writes.
    /// The digest detects damaged opaque bytes; payload decoding remains a domain concern.
    func validate(version: Int64) throws {
        guard try integer("PRAGMA application_id") == Self.applicationID else { throw LedgerStoreError.unrecognizedSchema }
        try checkIntegrity()
        guard try integer("SELECT count(*) FROM pragma_foreign_key_check") == 0
        else { throw LedgerStoreError.corruptRecord }
        let workspace = try workspace()
        let rows = try statement("SELECT \(Self.columns) FROM ledger_revisions ORDER BY revision")
        defer { sqlite3_finalize(rows) }
        var last: Int64 = 0
        while true {
            let status = sqlite3_step(rows)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
            let record = try decode(rows, workspaceID: workspace.id)
            guard last < Int64.max, record.revision == last + 1 else { throw LedgerStoreError.corruptRecord }
            last = record.revision
        }
        guard last == workspace.revision else { throw LedgerStoreError.corruptRecord }
        if version == 2 {
            let receipts = try tombstones("", values: [])
            let retired = Dictionary(uniqueKeysWithValues: receipts.map { ($0.workspaceID, $0) })
            guard retired[workspace.id] == nil,
                  try integer("SELECT count(*) FROM ledger_retired_operations o JOIN ledger_revisions r ON r.operation_id = o.operation_id") == 0,
                  try integer("""
                    SELECT count(*) FROM ledger_workspace_tombstones t WHERE t.erased_revision !=
                        (SELECT count(*) FROM ledger_retired_operations o WHERE o.workspace_id = t.workspace_id)
                    """) == 0
            else { throw LedgerStoreError.corruptRecord }
            var connected: Set<UUID> = [workspace.id]
            for receipt in receipts {
                var visited = Set<UUID>(), cursor = receipt.workspaceID
                while !connected.contains(cursor) {
                    guard visited.insert(cursor).inserted, let next = retired[cursor]
                    else { throw LedgerStoreError.corruptRecord }
                    cursor = next.replacementWorkspaceID
                }
                connected.formUnion(visited)
            }
            let operations = try statement("SELECT operation_id FROM ledger_retired_operations")
            defer { sqlite3_finalize(operations) }
            while true {
                let status = sqlite3_step(operations)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let id = UUID(uuidString: try text(operations, 0)),
                      id.uuidString == (try text(operations, 0))
                else { throw LedgerStoreError.corruptRecord }
            }
        }
    }

    func checkIntegrity() throws {
        let check = try statement("PRAGMA quick_check")
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW, try text(check, 0) == "ok",
              sqlite3_step(check) == SQLITE_DONE
        else { throw LedgerStoreError.corruptRecord }
    }

    func workspace() throws -> (id: UUID, revision: Int64) {
        let row = try statement("SELECT singleton, id, head_revision FROM ledger_workspace")
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW,
              sqlite3_column_type(row, 0) == SQLITE_INTEGER, sqlite3_column_int64(row, 0) == 1,
              let id = UUID(uuidString: try text(row, 1)), id.uuidString == (try text(row, 1))
        else { throw LedgerStoreError.corruptRecord }
        let revision: Int64
        switch sqlite3_column_type(row, 2) {
        case SQLITE_NULL: revision = 0
        case SQLITE_INTEGER:
            revision = sqlite3_column_int64(row, 2)
            guard revision > 0 else { throw LedgerStoreError.corruptRecord }
        default: throw LedgerStoreError.corruptRecord
        }
        guard sqlite3_step(row) == SQLITE_DONE else { throw LedgerStoreError.corruptRecord }
        return (id, revision)
    }

    func current(workspaceID: UUID) throws -> LedgerRecord? {
        // A single statement keeps head and revision reads on the same SQLite snapshot,
        // including when another actor/connection commits concurrently.
        let row = try statement("""
            SELECT r.\(Self.columns.replacingOccurrences(of: ", ", with: ", r.")), w.id, w.head_revision,
                   (SELECT MAX(revision) FROM ledger_revisions),
                   EXISTS(SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = ?)
            FROM ledger_workspace w LEFT JOIN ledger_revisions r
            ON r.workspace_id = w.id AND r.revision = w.head_revision
            WHERE w.singleton = 1
            """, values: [.text(workspaceID.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
        guard sqlite3_column_int64(row, 10) == 0 else { throw LedgerStoreError.erased }
        guard try text(row, 7) == workspaceID.uuidString
        else { throw LedgerStoreError.corruptRecord }
        let result: LedgerRecord?
        if sqlite3_column_type(row, 8) == SQLITE_NULL {
            guard sqlite3_column_type(row, 9) == SQLITE_NULL else { throw LedgerStoreError.corruptRecord }
            result = nil
        } else {
            result = try decode(row, workspaceID: workspaceID)
            guard sqlite3_column_type(row, 8) == SQLITE_INTEGER,
                  sqlite3_column_type(row, 9) == SQLITE_INTEGER,
                  result?.revision == sqlite3_column_int64(row, 8),
                  result?.revision == sqlite3_column_int64(row, 9)
            else { throw LedgerStoreError.corruptRecord }
        }
        guard sqlite3_step(row) == SQLITE_DONE else { throw LedgerStoreError.corruptRecord }
        return result
    }

    func record(operationID: UUID, workspaceID: UUID) throws -> LedgerRecord? {
        let row = try statement("SELECT \(Self.columns) FROM ledger_revisions WHERE operation_id = ?", values: [.text(operationID.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
        let result = try decode(row, workspaceID: workspaceID)
        guard sqlite3_step(row) == SQLITE_DONE else { throw LedgerStoreError.corruptRecord }
        return result
    }

    func tombstones(_ suffix: String, values: [LedgerValue]) throws -> [LedgerWorkspaceTombstone] {
        let row = try statement("""
            SELECT workspace_id, erased_revision, replacement_workspace_id, operation_id, erased_at
            FROM ledger_workspace_tombstones
            """ + " " + suffix, values: values)
        defer { sqlite3_finalize(row) }
        var receipts: [LedgerWorkspaceTombstone] = []
        while true {
            let status = sqlite3_step(row)
            if status == SQLITE_DONE { return receipts }
            guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
            guard let workspace = UUID(uuidString: try text(row, 0)), workspace.uuidString == (try text(row, 0)),
                  sqlite3_column_type(row, 1) == SQLITE_INTEGER,
                  let replacement = UUID(uuidString: try text(row, 2)), replacement.uuidString == (try text(row, 2)),
                  replacement != workspace,
                  let operation = UUID(uuidString: try text(row, 3)), operation.uuidString == (try text(row, 3)),
                  [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 4))
            else { throw LedgerStoreError.corruptRecord }
            let revision = sqlite3_column_int64(row, 1), time = sqlite3_column_double(row, 4)
            guard revision >= 0, time.isFinite else { throw LedgerStoreError.corruptRecord }
            receipts.append(LedgerWorkspaceTombstone(workspaceID: workspace, erasedRevision: revision,
                replacementWorkspaceID: replacement, operationID: operation,
                erasedAt: Date(timeIntervalSinceReferenceDate: time)))
        }
    }

    func isRetiredWorkspace(_ id: UUID) throws -> Bool {
        try exists("SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = ?", values: [.text(id.uuidString)])
    }

    func isRetiredOperation(_ id: UUID) throws -> Bool {
        try exists("SELECT 1 FROM ledger_retired_operations WHERE operation_id = ?", values: [.text(id.uuidString)])
    }

    func hasSaveOperation(_ id: UUID) throws -> Bool {
        try exists("SELECT 1 FROM ledger_revisions WHERE operation_id = ?", values: [.text(id.uuidString)])
    }

    private func exists(_ sql: String, values: [LedgerValue]) throws -> Bool {
        let row = try statement(sql, values: values)
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
        return true
    }

    func checkpointAfterErasure() {
        // The tombstone and replacement are already committed. Busy readers can defer
        // media cleanup but cannot undo logical erasure or revive retired operations.
        guard let handle else { return }
        sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    private func decode(_ row: OpaquePointer, workspaceID: UUID) throws -> LedgerRecord {
        guard try text(row, 0) == workspaceID.uuidString,
              sqlite3_column_type(row, 1) == SQLITE_INTEGER, sqlite3_column_type(row, 2) == SQLITE_INTEGER,
              let operationID = UUID(uuidString: try text(row, 3)), operationID.uuidString == (try text(row, 3)),
              [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 6))
        else { throw LedgerStoreError.corruptRecord }
        let revision = sqlite3_column_int64(row, 1)
        let time = sqlite3_column_double(row, 6)
        guard revision > 0, sqlite3_column_int64(row, 2) == revision - 1, time.isFinite
        else { throw LedgerStoreError.corruptRecord }
        let payload = try blob(row, 4, limit: LedgerStore.maximumPayloadBytes)
        let digest = try blob(row, 5, limit: 32)
        guard digest == Data(SHA256.hash(data: payload)) else { throw LedgerStoreError.corruptRecord }
        return LedgerRecord(workspaceID: workspaceID, revision: revision, payload: payload,
                            savedAt: Date(timeIntervalSinceReferenceDate: time), operationID: operationID)
    }

    private func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(row, column)
        else { throw LedgerStoreError.corruptRecord }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(row, column)))
        guard let result = String(bytes: bytes, encoding: .utf8), !result.contains("\0")
        else { throw LedgerStoreError.corruptRecord }
        return result
    }

    private func blob(_ row: OpaquePointer, _ column: Int32, limit: Int) throws -> Data {
        guard sqlite3_column_type(row, column) == SQLITE_BLOB else { throw LedgerStoreError.corruptRecord }
        let count = Int(sqlite3_column_bytes(row, column))
        guard count <= limit else { throw LedgerStoreError.corruptRecord }
        if count == 0 { return Data() }
        guard let pointer = sqlite3_column_blob(row, column) else { throw LedgerStoreError.corruptRecord }
        return Data(bytes: pointer, count: count)
    }

    private func statement(_ sql: String, values: [LedgerValue] = []) throws -> OpaquePointer {
        guard let handle else { throw LedgerStoreError.closed }
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let prepared else {
            sqlite3_finalize(prepared)
            throw LedgerStoreError.database(status)
        }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case let .text(text): result = sqlite3_bind_text(prepared, index, text, -1, transient)
                case let .integer(number): result = sqlite3_bind_int64(prepared, index, number)
                case let .real(number): result = sqlite3_bind_double(prepared, index, number)
                case let .blob(data):
                    if data.isEmpty { result = sqlite3_bind_zeroblob(prepared, index, 0) }
                    else {
                        result = data.withUnsafeBytes {
                            sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32($0.count), transient)
                        }
                    }
                }
                guard result == SQLITE_OK else { throw LedgerStoreError.database(result) }
            }
            return prepared
        } catch {
            sqlite3_finalize(prepared)
            throw error
        }
    }

    @discardableResult
    func run(_ sql: String, _ values: [LedgerValue]) throws -> Int32 {
        let row = try statement(sql, values: values)
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        guard status == SQLITE_DONE else { throw LedgerStoreError.database(status) }
        return sqlite3_changes(handle)
    }

    func integer(_ sql: String) throws -> Int64 {
        let row = try statement(sql)
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
        guard sqlite3_column_type(row, 0) == SQLITE_INTEGER else { throw LedgerStoreError.corruptRecord }
        return sqlite3_column_int64(row, 0)
    }
}
