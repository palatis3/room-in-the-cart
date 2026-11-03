import Foundation
import CSQLite

public struct SavedComparison: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let payload: Data
    public let savedAt: Date
    public let revision: Int64
}

/// Readable identity for a source whose envelope cannot be opened. Listing never
/// repairs, overwrites or discards its bytes. A newer envelope may need a newer app.
public struct UnavailableComparison: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String?
    public let reason: ComparisonStoreError
}

public struct ComparisonListing: Equatable, Sendable {
    public let records: [SavedComparison]
    public let unavailable: [UnavailableComparison]
}

/// Permanent erasure evidence. Contains no title, payload, or payload digest.
/// Its origin is `comparisons/{workspaceID.uuidString}` and its source identity is `id`.
public struct ComparisonTombstone: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let workspaceID: UUID
    public let erasedRevision: Int64
    public let operationID: UUID
    public let erasedAt: Date
}

/// Errors contain no comparison titles, payloads, SQL text, or filesystem paths.
public enum ComparisonStoreError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedSchema(Int64)
    case unrecognizedSchema
    case invalidInput
    case payloadTooLarge
    case staleRevision(expected: Int64, actual: Int64)
    case operationConflict
    case erased
    case notFound
    case corruptRecord
    case unsupportedEnvelope(Int)
    case database(Int32)
    case closed
}

/// Installation-local, offline persistence. The caller owns payload semantics and its own
/// payload versioning. Each successful changed save appends an immutable full snapshot.
public actor ComparisonStore {
    public nonisolated let workspaceID: UUID
    public nonisolated static let maximumPayloadBytes = 1_048_576
    private let database: Database

    /// The parent directory must already exist. At the iOS composition root, protect that
    /// directory with completeUntilFirstUserAuthentication so journals inherit protection.
    public init(url: URL) throws {
        guard url.isFileURL else { throw ComparisonStoreError.invalidURL }
        let database = try Database(url: url)
        do {
            // Inspect first: opening an unsupported future schema must not change its data,
            // metadata, journal mode, or schema version.
            let version = try database.transaction(immediate: false) {
                let version = try database.integer("PRAGMA user_version")
                guard version <= 2 else { throw ComparisonStoreError.unsupportedSchema(version) }
                guard version >= 0 else { throw ComparisonStoreError.unrecognizedSchema }
                if version == 0 {
                    guard try database.integer("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0
                    else { throw ComparisonStoreError.unrecognizedSchema }
                    try database.checkIntegrity()
                } else {
                    try database.validate(version: version, beforeMigration: version == 1)
                }
                return version
            }
            try database.execute("PRAGMA foreign_keys = ON")
            try database.execute("PRAGMA synchronous = FULL")
            try database.execute("PRAGMA fullfsync = ON")
            try database.execute("PRAGMA secure_delete = ON")
            try database.execute("PRAGMA journal_size_limit = 0")
            if version < 2 { try database.migrate() }
            guard try database.integer("SELECT count(*) FROM workspace") == 1,
                  let id = UUID(uuidString: try database.string("SELECT id FROM workspace WHERE singleton = 1"))
            else { throw ComparisonStoreError.corruptRecord }
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            #endif
            self.database = database
            self.workspaceID = id
        } catch {
            try? database.close()
            throw error
        }
    }

    /// An exact payload/title retry returns the original timestamp and revision, even if
    /// the caller supplies a later retry time. Date is evidence, not operation identity.
    @discardableResult
    public func save(id: UUID, title: String, payload: Data, savedAt: Date) throws -> SavedComparison {
        guard payload.count <= Self.maximumPayloadBytes else { throw ComparisonStoreError.payloadTooLarge }
        guard title.utf8.count <= 4096, !title.contains("\0"), savedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw ComparisonStoreError.invalidInput }
        return try database.transaction {
            guard try !isErased(id: id) else { throw ComparisonStoreError.erased }
            let previous = try load(id: id)
            if let previous, previous.title == title, previous.payload == payload { return previous }
            guard previous?.revision != Int64.max else { throw ComparisonStoreError.corruptRecord }
            let revision = (previous?.revision ?? 0) + 1
            let encoder = JSONEncoder()
            // Base64 may consist almost entirely of '/'. Escaping each slash can
            // double the envelope and exceed SQLite's bound for a valid 1 MiB payload.
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let envelope = try encoder.encode(Envelope(version: 1, payload: payload))
            try database.run(
                "INSERT INTO comparison_revisions (comparison_id, revision, title, envelope, saved_at) VALUES (?, ?, ?, ?, ?)",
                [.text(id.uuidString), .integer(revision), .text(title), .blob(envelope), .real(savedAt.timeIntervalSinceReferenceDate)]
            )
            try database.run(
                "INSERT INTO comparisons (id, workspace_id, head_revision) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET head_revision = excluded.head_revision",
                [.text(id.uuidString), .text(workspaceID.uuidString), .integer(revision)]
            )
            return SavedComparison(id: id, title: title, payload: payload, savedAt: savedAt, revision: revision)
        }
    }

    public func list() throws -> [SavedComparison] {
        try database.records(Self.select + " ORDER BY r.saved_at DESC, c.id ASC", values: [])
    }

    /// Use for interactive browsing. Individual envelope failures are explicit;
    /// database/identity failures still throw rather than return a partial result.
    /// `list()` remains strict for callers that require a complete snapshot.
    public func listing() throws -> ComparisonListing {
        try database.listing(Self.select + " ORDER BY r.saved_at DESC, c.id ASC")
    }

    public func load(id: UUID) throws -> SavedComparison? {
        try database.records(Self.select + " WHERE c.id = ?", values: [.text(id.uuidString)]).first
    }

    /// Permanently deletes every title and payload revision for this source. There is no
    /// undo. Call only after the person confirms this source and the currently shown revision.
    /// Exact operation/id/revision retries return the first receipt and ignore a later `at`.
    /// An operation reused for another source or revision fails; a new operation for an
    /// already erased source throws `erased`. Future saves of this source ID always fail.
    ///
    /// Deletion and its tombstone commit atomically. secure_delete clears freed SQLite cells
    /// and a best-effort WAL checkpoint follows commit. Earlier bytes in active readers,
    /// external backups, filesystem snapshots, or storage media are not a forensic-erasure
    /// guarantee. Recovery must also consult this tombstone's origin before making a sibling.
    @discardableResult
    public func erase(id: UUID, expectedRevision: Int64, operationID: UUID, at: Date) throws -> ComparisonTombstone {
        guard expectedRevision > 0, at.timeIntervalSinceReferenceDate.isFinite
        else { throw ComparisonStoreError.invalidInput }
        let result = try database.transaction {
            if let receipt = try database.tombstones(
                "WHERE operation_id = ?", values: [.text(operationID.uuidString)]).first {
                guard receipt.id == id, receipt.workspaceID == workspaceID,
                      receipt.erasedRevision == expectedRevision
                else { throw ComparisonStoreError.operationConflict }
                return receipt
            }
            guard try !isErased(id: id) else { throw ComparisonStoreError.erased }
            guard let revision = try database.head(id: id, workspaceID: workspaceID)
            else { throw ComparisonStoreError.notFound }
            guard revision == expectedRevision else {
                throw ComparisonStoreError.staleRevision(expected: expectedRevision, actual: revision)
            }
            try database.run("""
                INSERT INTO comparison_tombstones
                    (comparison_id, workspace_id, erased_revision, operation_id, erased_at)
                VALUES (?, ?, ?, ?, ?)
                """, [.text(id.uuidString), .text(workspaceID.uuidString), .integer(revision),
                      .text(operationID.uuidString), .real(at.timeIntervalSinceReferenceDate)])
            try database.run("DELETE FROM comparison_revisions WHERE comparison_id = ?", [.text(id.uuidString)])
            let changed = try database.run("DELETE FROM comparisons WHERE id = ? AND head_revision = ?",
                                          [.text(id.uuidString), .integer(revision)])
            guard changed == 1 else { throw ComparisonStoreError.corruptRecord }
            return ComparisonTombstone(id: id, workspaceID: workspaceID, erasedRevision: revision,
                                       operationID: operationID, erasedAt: at)
        }
        database.checkpointAfterErasure()
        return result
    }

    public func isErased(id: UUID) throws -> Bool {
        try !database.tombstones("WHERE comparison_id = ?", values: [.text(id.uuidString)]).isEmpty
    }

    public func tombstones() throws -> [ComparisonTombstone] {
        try database.tombstones("ORDER BY erased_at, comparison_id", values: [])
    }

    /// Explicit close is useful for controlled store replacement and restart tests.
    /// Releasing the actor also closes the connection. Calling close twice is safe.
    public func close() throws { try database.close() }

    private static let select = """
        SELECT c.id, r.title, r.envelope, r.saved_at, r.revision
        FROM comparisons c JOIN comparison_revisions r
        ON c.id = r.comparison_id AND c.head_revision = r.revision
        """
}

private struct Envelope: Codable {
    let version: Int
    let payload: Data
}

private enum Value {
    case text(String), integer(Int64), real(Double), blob(Data)
}

/// This connection is exclusively owned by one actor after initialization.
private final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            sqlite3_close_v2(handle)
            handle = nil
            throw ComparisonStoreError.database(status)
        }
        sqlite3_busy_timeout(handle, 5_000)
        // Bound individual SQLite allocations as well as decoded application payloads.
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 2_097_152)
    }

    deinit { sqlite3_close_v2(handle) }

    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw ComparisonStoreError.database(result) }
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw ComparisonStoreError.closed }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw ComparisonStoreError.database(result) }
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
            // Recheck under the write lock in case another opener just migrated this file.
            var version = try integer("PRAGMA user_version")
            if version == 2 { try validate(version: 2); return }
            guard version == 0 || version == 1 else { throw ComparisonStoreError.unsupportedSchema(version) }
            if version == 0 {
                guard try integer("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0
                else { throw ComparisonStoreError.unrecognizedSchema }
                try checkIntegrity()
                try execute("""
                CREATE TABLE workspace (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    id TEXT NOT NULL UNIQUE
                );
                CREATE TABLE comparisons (
                    id TEXT PRIMARY KEY NOT NULL,
                    workspace_id TEXT NOT NULL REFERENCES workspace(id),
                    head_revision INTEGER NOT NULL CHECK(head_revision > 0),
                    FOREIGN KEY (id, head_revision) REFERENCES comparison_revisions(comparison_id, revision)
                        DEFERRABLE INITIALLY DEFERRED
                );
                CREATE TABLE comparison_revisions (
                    comparison_id TEXT NOT NULL REFERENCES comparisons(id) DEFERRABLE INITIALLY DEFERRED,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    title TEXT NOT NULL,
                    envelope BLOB NOT NULL CHECK(length(envelope) <= 2097152),
                    saved_at REAL NOT NULL,
                    PRIMARY KEY (comparison_id, revision)
                );
                CREATE TRIGGER immutable_revision_update BEFORE UPDATE ON comparison_revisions
                BEGIN SELECT RAISE(ABORT, 'immutable revision'); END;
                CREATE TRIGGER immutable_revision_delete BEFORE DELETE ON comparison_revisions
                BEGIN SELECT RAISE(ABORT, 'immutable revision'); END;
                PRAGMA user_version = 1;
                """)
                try run("INSERT INTO workspace (singleton, id) VALUES (1, ?)", [.text(UUID().uuidString)])
                version = 1
            }
            if version == 1 {
                // Validate retained v1 evidence before any schema rewrite. A malformed
                // legacy payload or unsupported envelope must leave the old file intact.
                try validate(version: 1, beforeMigration: true)
                try execute("""
                    CREATE TABLE comparison_tombstones (
                        comparison_id TEXT PRIMARY KEY NOT NULL CHECK(typeof(comparison_id) = 'text' AND length(comparison_id) = 36),
                        workspace_id TEXT NOT NULL REFERENCES workspace(id),
                        erased_revision INTEGER NOT NULL CHECK(typeof(erased_revision) = 'integer' AND erased_revision > 0),
                        operation_id TEXT NOT NULL UNIQUE CHECK(typeof(operation_id) = 'text' AND length(operation_id) = 36),
                        erased_at REAL NOT NULL CHECK(typeof(erased_at) IN ('real', 'integer'))
                    );
                    CREATE TRIGGER tombstone_requires_current_revision BEFORE INSERT ON comparison_tombstones
                    WHEN NOT EXISTS (
                        SELECT 1 FROM comparisons c WHERE c.id = NEW.comparison_id
                        AND c.workspace_id = NEW.workspace_id AND c.head_revision = NEW.erased_revision
                    )
                    BEGIN SELECT RAISE(ABORT, 'stale erasure'); END;
                    CREATE TRIGGER immutable_tombstone_update BEFORE UPDATE ON comparison_tombstones
                    BEGIN SELECT RAISE(ABORT, 'immutable tombstone'); END;
                    CREATE TRIGGER immutable_tombstone_delete BEFORE DELETE ON comparison_tombstones
                    BEGIN SELECT RAISE(ABORT, 'immutable tombstone'); END;
                    DROP TRIGGER immutable_revision_delete;
                    CREATE TRIGGER immutable_revision_delete BEFORE DELETE ON comparison_revisions
                    WHEN NOT EXISTS (
                        SELECT 1 FROM comparison_tombstones t JOIN comparisons c ON c.id = t.comparison_id
                        WHERE t.comparison_id = OLD.comparison_id AND t.workspace_id = c.workspace_id
                        AND t.erased_revision = c.head_revision AND OLD.revision <= t.erased_revision
                    )
                    BEGIN SELECT RAISE(ABORT, 'immutable revision'); END;
                    CREATE TRIGGER comparison_delete_requires_tombstone BEFORE DELETE ON comparisons
                    WHEN NOT EXISTS (
                        SELECT 1 FROM comparison_tombstones t WHERE t.comparison_id = OLD.id
                        AND t.workspace_id = OLD.workspace_id AND t.erased_revision = OLD.head_revision
                    )
                    BEGIN SELECT RAISE(ABORT, 'erasure required'); END;
                    CREATE TRIGGER erased_comparison_insert BEFORE INSERT ON comparisons
                    WHEN EXISTS (SELECT 1 FROM comparison_tombstones WHERE comparison_id = NEW.id)
                    BEGIN SELECT RAISE(ABORT, 'erased comparison'); END;
                    CREATE TRIGGER erased_comparison_update BEFORE UPDATE ON comparisons
                    WHEN EXISTS (SELECT 1 FROM comparison_tombstones WHERE comparison_id IN (OLD.id, NEW.id))
                    BEGIN SELECT RAISE(ABORT, 'erased comparison'); END;
                    CREATE TRIGGER erased_revision_insert BEFORE INSERT ON comparison_revisions
                    WHEN EXISTS (SELECT 1 FROM comparison_tombstones WHERE comparison_id = NEW.comparison_id)
                    BEGIN SELECT RAISE(ABORT, 'erased comparison'); END;
                    PRAGMA user_version = 2;
                    """)
            }
        }
    }

    func checkIntegrity() throws {
        guard try string("PRAGMA quick_check") == "ok",
              try integer("SELECT count(*) FROM pragma_foreign_key_check") == 0
        else { throw ComparisonStoreError.corruptRecord }
    }

    func validate(version: Int64, beforeMigration: Bool = false) throws {
        try checkIntegrity()
        guard try integer("SELECT count(*) FROM workspace") == 1,
              let workspaceID = UUID(uuidString: try string("SELECT id FROM workspace WHERE singleton = 1")),
              try integer("""
                SELECT count(*) FROM comparisons c WHERE c.head_revision !=
                    (SELECT COALESCE(MAX(revision), 0) FROM comparison_revisions r WHERE r.comparison_id = c.id)
                OR c.head_revision !=
                    (SELECT count(*) FROM comparison_revisions r WHERE r.comparison_id = c.id)
                """) == 0
        else { throw ComparisonStoreError.corruptRecord }
        if beforeMigration {
            _ = try records("SELECT comparison_id, title, envelope, saved_at, revision FROM comparison_revisions", values: [], keepingRecords: false)
        }
        if version == 2 {
            let erased = try tombstones("", values: [])
            guard erased.allSatisfy({ $0.workspaceID == workspaceID }),
                  try integer("SELECT count(*) FROM comparison_tombstones t JOIN comparisons c ON c.id = t.comparison_id") == 0,
                  try integer("SELECT count(*) FROM comparison_tombstones t JOIN comparison_revisions r ON r.comparison_id = t.comparison_id") == 0
            else { throw ComparisonStoreError.corruptRecord }
        }
    }

    func head(id: UUID, workspaceID: UUID) throws -> Int64? {
        let row = try statement("SELECT workspace_id, head_revision FROM comparisons WHERE id = ?", values: [.text(id.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
        guard try text(row, column: 0) == workspaceID.uuidString, sqlite3_column_type(row, 1) == SQLITE_INTEGER
        else { throw ComparisonStoreError.corruptRecord }
        let revision = sqlite3_column_int64(row, 1)
        guard revision > 0 else { throw ComparisonStoreError.corruptRecord }
        return revision
    }

    func tombstones(_ suffix: String, values: [Value]) throws -> [ComparisonTombstone] {
        let row = try statement("SELECT comparison_id, workspace_id, erased_revision, operation_id, erased_at FROM comparison_tombstones " + suffix, values: values)
        defer { sqlite3_finalize(row) }
        var result: [ComparisonTombstone] = []
        while true {
            let status = sqlite3_step(row)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
            guard let id = UUID(uuidString: try text(row, column: 0)),
                  id.uuidString == (try text(row, column: 0)),
                  let workspaceID = UUID(uuidString: try text(row, column: 1)),
                  workspaceID.uuidString == (try text(row, column: 1)),
                  sqlite3_column_type(row, 2) == SQLITE_INTEGER,
                  let operationID = UUID(uuidString: try text(row, column: 3)),
                  operationID.uuidString == (try text(row, column: 3)),
                  [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 4))
            else { throw ComparisonStoreError.corruptRecord }
            let revision = sqlite3_column_int64(row, 2)
            let time = sqlite3_column_double(row, 4)
            guard revision > 0, time.isFinite else { throw ComparisonStoreError.corruptRecord }
            result.append(ComparisonTombstone(id: id, workspaceID: workspaceID, erasedRevision: revision,
                                              operationID: operationID, erasedAt: Date(timeIntervalSinceReferenceDate: time)))
        }
    }

    func checkpointAfterErasure() {
        // COMMIT already succeeded. A busy reader can defer media cleanup, but cannot
        // undo the tombstone or make the erased source accessible through this store.
        guard let handle else { return }
        sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    private func statement(_ sql: String, values: [Value] = []) throws -> OpaquePointer {
        guard let handle else { throw ComparisonStoreError.closed }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw ComparisonStoreError.database(status) }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, transient)
                case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
                case let .real(number): result = sqlite3_bind_double(statement, index, number)
                case let .blob(data):
                    result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                }
                guard result == SQLITE_OK else { throw ComparisonStoreError.database(result) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    @discardableResult
    func run(_ sql: String, _ values: [Value]) throws -> Int32 {
        let statement = try statement(sql, values: values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw ComparisonStoreError.database(result) }
        return sqlite3_changes(handle)
    }

    func integer(_ sql: String) throws -> Int64 {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw ComparisonStoreError.database(result) }
        return sqlite3_column_int64(statement, 0)
    }

    func string(_ sql: String) throws -> String {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw ComparisonStoreError.database(result) }
        return try text(statement, column: 0)
    }

    private func text(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column)
        else { throw ComparisonStoreError.corruptRecord }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        guard let value = String(bytes: bytes, encoding: .utf8), !value.contains("\0")
        else { throw ComparisonStoreError.corruptRecord }
        return value
    }

    func records(_ sql: String, values: [Value], keepingRecords: Bool = true) throws -> [SavedComparison] {
        let statement = try statement(sql, values: values)
        defer { sqlite3_finalize(statement) }
        var records: [SavedComparison] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW else { throw ComparisonStoreError.database(result) }
            let record = try record(statement)
            if keepingRecords { records.append(record) }
        }
    }

    func listing(_ sql: String) throws -> ComparisonListing {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        var records: [SavedComparison] = []
        var unavailable: [UnavailableComparison] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return ComparisonListing(records: records, unavailable: unavailable) }
            guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
            guard let id = UUID(uuidString: try text(statement, column: 0)) else {
                throw ComparisonStoreError.corruptRecord
            }
            do { records.append(try record(statement)) }
            catch let error as ComparisonStoreError {
                switch error {
                case .corruptRecord, .unsupportedEnvelope:
                    let title = try? text(statement, column: 1)
                    unavailable.append(UnavailableComparison(id: id,
                        title: title.flatMap { $0.utf8.count <= 4096 ? $0 : nil }, reason: error))
                default: throw error
                }
            }
        }
    }

    private func record(_ statement: OpaquePointer) throws -> SavedComparison {
            guard let id = UUID(uuidString: try text(statement, column: 0)),
                  sqlite3_column_type(statement, 2) == SQLITE_BLOB,
                  let pointer = sqlite3_column_blob(statement, 2)
            else { throw ComparisonStoreError.corruptRecord }
            let title = try text(statement, column: 1)
            let length = Int(sqlite3_column_bytes(statement, 2))
            guard length > 0, length <= 2_097_152, title.utf8.count <= 4096,
                  [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, 3)),
                  sqlite3_column_type(statement, 4) == SQLITE_INTEGER
            else { throw ComparisonStoreError.corruptRecord }
            let envelope: Envelope
            do { envelope = try JSONDecoder().decode(Envelope.self, from: Data(bytes: pointer, count: length)) }
            catch { throw ComparisonStoreError.corruptRecord }
            guard envelope.version == 1 else { throw ComparisonStoreError.unsupportedEnvelope(envelope.version) }
            guard envelope.payload.count <= ComparisonStore.maximumPayloadBytes else { throw ComparisonStoreError.corruptRecord }
            let time = sqlite3_column_double(statement, 3)
            let revision = sqlite3_column_int64(statement, 4)
            guard time.isFinite, revision > 0 else { throw ComparisonStoreError.corruptRecord }
            return SavedComparison(id: id, title: title, payload: envelope.payload,
                                   savedAt: Date(timeIntervalSinceReferenceDate: time), revision: revision)
    }
}
