import Foundation
import CSQLite

extension ComparisonDatabase {
    func requireLegacyWritesAllowed() throws {
        try requireInventoryOriginLive()
        // Read database state, not an actor's initialization-time flag: another instance may have activated it.
        if try integer("PRAGMA user_version") >= 3 {
            guard try integer("SELECT active FROM inventory_state WHERE singleton = 1") == 0 else {
                throw ComparisonStoreError.inventoryRequired
            }
        }
    }

    func migrateInventory() throws {
        try transaction {
            let version = try integer("PRAGMA user_version")
            if version == 3 || version == 4 { try validateInventory(); return }
            guard version == 2 else { throw ComparisonStoreError.unsupportedSchema(version) }
            try validate(version: 2, beforeMigration: true)
            try execute(Self.inventorySchema)
            try execute(Self.inventoryMigrationSchema)
            try validateInventory()
        }
    }

    private static let inventorySchema = """
        CREATE TABLE inventory_state (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision >= 0),
            source_generation INTEGER NOT NULL CHECK(typeof(source_generation) = 'integer' AND source_generation >= 0),
            active INTEGER NOT NULL CHECK(active IN (0, 1))
        );
        INSERT INTO inventory_state VALUES (1, 0, 0, 0);
        CREATE TABLE inventory_heads (
            kind TEXT NOT NULL CHECK(kind IN ('lot','observation','event','reservation','sourceLink','intent')),
            id TEXT NOT NULL CHECK(length(id) = 36),
            revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0),
            parent_kind TEXT,
            lot_id TEXT,
            source_origin TEXT,
            source_id TEXT,
            PRIMARY KEY(kind, id),
            UNIQUE(source_origin, source_id),
            CHECK((kind IN ('lot','intent','reservation') AND parent_kind IS NULL AND lot_id IS NULL)
                OR (kind NOT IN ('lot','intent') AND parent_kind = 'lot' AND lot_id IS NOT NULL)),
            CHECK((kind = 'sourceLink' AND source_origin IS NOT NULL AND length(source_origin) = 36 AND source_id IS NOT NULL AND length(source_id) BETWEEN 1 AND 256)
                OR (kind != 'sourceLink' AND source_origin IS NULL AND source_id IS NULL)),
            FOREIGN KEY(parent_kind, lot_id) REFERENCES inventory_heads(kind, id) DEFERRABLE INITIALLY DEFERRED,
            FOREIGN KEY(kind, id, revision) REFERENCES inventory_revisions(kind, id, revision) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TABLE inventory_revisions (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0),
            lot_id TEXT,
            payload_version INTEGER NOT NULL CHECK(typeof(payload_version) = 'integer' AND payload_version BETWEEN 1 AND 10000),
            payload BLOB NOT NULL CHECK(typeof(payload) = 'blob' AND length(payload) BETWEEN 1 AND 65536),
            digest BLOB NOT NULL CHECK(typeof(digest) = 'blob' AND length(digest) = 32),
            PRIMARY KEY(kind, id, revision),
            FOREIGN KEY(kind, id) REFERENCES inventory_heads(kind, id) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TABLE inventory_tombstones (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0),
            operation_id TEXT NOT NULL CHECK(length(operation_id) = 36),
            PRIMARY KEY(kind, id)
        );
        CREATE TABLE inventory_retired_sources (
            origin_id TEXT NOT NULL CHECK(length(origin_id) = 36),
            source_id TEXT NOT NULL CHECK(length(source_id) BETWEEN 1 AND 256),
            operation_id TEXT NOT NULL CHECK(length(operation_id) = 36),
            PRIMARY KEY(origin_id, source_id)
        );
        CREATE TABLE inventory_operations (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
            digest BLOB NOT NULL CHECK(typeof(digest) = 'blob' AND length(digest) = 32),
            request_digest BLOB NOT NULL CHECK(typeof(request_digest) = 'blob' AND length(request_digest) = 32),
            receipt BLOB NOT NULL CHECK(typeof(receipt) = 'blob' AND length(receipt) BETWEEN 1 AND 131072)
        );
        CREATE TRIGGER inventory_source_insert AFTER INSERT ON comparisons
        BEGIN UPDATE inventory_state SET source_generation = source_generation + 1 WHERE singleton = 1; END;
        CREATE TRIGGER inventory_source_update AFTER UPDATE ON comparisons
        BEGIN UPDATE inventory_state SET source_generation = source_generation + 1 WHERE singleton = 1; END;
        CREATE TRIGGER inventory_source_delete AFTER DELETE ON comparisons
        BEGIN UPDATE inventory_state SET source_generation = source_generation + 1 WHERE singleton = 1; END;
        CREATE TRIGGER inventory_source_retired AFTER INSERT ON comparison_tombstones
        BEGIN UPDATE inventory_state SET source_generation = source_generation + 1 WHERE singleton = 1; END;
        CREATE TRIGGER inventory_revision_immutable BEFORE UPDATE ON inventory_revisions
        BEGIN SELECT RAISE(ABORT, 'immutable inventory revision'); END;
        CREATE TRIGGER inventory_append_only BEFORE INSERT ON inventory_revisions
        WHEN NEW.kind IN ('observation','event','sourceLink') AND NEW.revision != 1
        BEGIN SELECT RAISE(ABORT, 'append only inventory record'); END;
        CREATE TRIGGER inventory_revision_retired BEFORE INSERT ON inventory_revisions
        WHEN EXISTS (SELECT 1 FROM inventory_tombstones WHERE kind = NEW.kind AND id = NEW.id)
        BEGIN SELECT RAISE(ABORT, 'retired inventory record'); END;
        CREATE TRIGGER inventory_source_identity_retired BEFORE INSERT ON inventory_heads
        WHEN NEW.kind = 'sourceLink' AND EXISTS (SELECT 1 FROM inventory_retired_sources WHERE origin_id = NEW.source_origin AND source_id = NEW.source_id)
        BEGIN SELECT RAISE(ABORT, 'retired inventory source'); END;
        CREATE TRIGGER inventory_retired_source_update BEFORE UPDATE ON inventory_retired_sources
        BEGIN SELECT RAISE(ABORT, 'immutable retired source'); END;
        CREATE TRIGGER inventory_retired_source_delete BEFORE DELETE ON inventory_retired_sources
        BEGIN SELECT RAISE(ABORT, 'immutable retired source'); END;
        CREATE TRIGGER inventory_head_retired BEFORE INSERT ON inventory_heads
        WHEN EXISTS (SELECT 1 FROM inventory_tombstones WHERE kind = NEW.kind AND id = NEW.id)
        BEGIN SELECT RAISE(ABORT, 'retired inventory record'); END;
        CREATE TRIGGER inventory_head_identity BEFORE UPDATE ON inventory_heads
        WHEN NEW.kind != OLD.kind OR NEW.id != OLD.id OR (OLD.kind != 'reservation' AND (NEW.parent_kind IS NOT OLD.parent_kind OR NEW.lot_id IS NOT OLD.lot_id))
          OR NEW.source_origin IS NOT OLD.source_origin OR NEW.source_id IS NOT OLD.source_id
        BEGIN SELECT RAISE(ABORT, 'immutable inventory identity'); END;
        CREATE TRIGGER inventory_retire_current BEFORE INSERT ON inventory_tombstones
        WHEN NOT EXISTS (SELECT 1 FROM inventory_heads WHERE kind = NEW.kind AND id = NEW.id AND revision = NEW.revision)
        BEGIN SELECT RAISE(ABORT, 'stale inventory erasure'); END;
        CREATE TRIGGER inventory_revision_delete BEFORE DELETE ON inventory_revisions
        WHEN NOT EXISTS (SELECT 1 FROM inventory_tombstones WHERE kind = OLD.kind AND id = OLD.id AND revision >= OLD.revision)
        BEGIN SELECT RAISE(ABORT, 'inventory erasure required'); END;
        CREATE TRIGGER inventory_head_delete BEFORE DELETE ON inventory_heads
        WHEN NOT EXISTS (SELECT 1 FROM inventory_tombstones WHERE kind = OLD.kind AND id = OLD.id AND revision = OLD.revision)
        BEGIN SELECT RAISE(ABORT, 'inventory erasure required'); END;
        CREATE TRIGGER inventory_tombstone_update BEFORE UPDATE ON inventory_tombstones
        BEGIN SELECT RAISE(ABORT, 'immutable inventory tombstone'); END;
        CREATE TRIGGER inventory_tombstone_delete BEFORE DELETE ON inventory_tombstones
        BEGIN SELECT RAISE(ABORT, 'immutable inventory tombstone'); END;
        CREATE TRIGGER inventory_operation_update BEFORE UPDATE ON inventory_operations
        BEGIN SELECT RAISE(ABORT, 'immutable inventory receipt'); END;
        CREATE TRIGGER inventory_operation_delete BEFORE DELETE ON inventory_operations
        BEGIN SELECT RAISE(ABORT, 'immutable inventory receipt'); END;
        CREATE TRIGGER inventory_activation_monotonic BEFORE UPDATE ON inventory_state
        WHEN NEW.active < OLD.active OR NEW.revision < OLD.revision OR NEW.source_generation < OLD.source_generation
        BEGIN SELECT RAISE(ABORT, 'invalid inventory state'); END;
        PRAGMA user_version = 3;
        """

    func validateInventory() throws {
        try checkIntegrity()
        let tables = ["inventory_state", "inventory_heads", "inventory_revisions", "inventory_tombstones", "inventory_retired_sources", "inventory_operations", "inventory_migrations", "inventory_migration_chunks", "inventory_staged_records", "inventory_migration_sources", "inventory_migration_keys"]
        let triggers = ["inventory_source_insert", "inventory_source_update", "inventory_source_delete", "inventory_source_retired",
            "inventory_revision_immutable", "inventory_append_only", "inventory_revision_retired", "inventory_head_retired",
            "inventory_head_identity", "inventory_retire_current", "inventory_revision_delete", "inventory_head_delete",
            "inventory_tombstone_update", "inventory_tombstone_delete", "inventory_operation_update", "inventory_operation_delete",
            "inventory_activation_monotonic", "inventory_source_identity_retired", "inventory_retired_source_update", "inventory_retired_source_delete", "inventory_migration_identity", "inventory_migration_delete", "inventory_chunk_update", "inventory_chunk_delete", "inventory_staged_update", "inventory_staged_delete", "inventory_staged_insert", "inventory_migration_key_update", "inventory_migration_key_delete", "inventory_migration_source_update", "inventory_migration_source_delete"]
        for (type, names) in [("table", tables), ("trigger", triggers)] {
            for name in names {
                guard try integer("SELECT count(*) FROM sqlite_master WHERE type = '\(type)' AND name = '\(name)'") == 1 else {
                    throw ComparisonStoreError.corruptRecord
                }
            }
        }
        let redactionFloorSQL = try integer("PRAGMA user_version") >= 4 ? "CASE WHEN h.kind='reservation' THEN COALESCE((SELECT max(through_revision) FROM inventory_reservation_redactions d WHERE d.id=h.id),0) ELSE 0 END" : "0"
        guard try integer("SELECT count(*) FROM inventory_state") == 1,
              try integer("SELECT count(*) FROM inventory_state WHERE singleton = 1 AND typeof(revision) = 'integer' AND revision >= 0 AND typeof(source_generation) = 'integer' AND source_generation >= 0 AND active IN (0,1)") == 1,
              try integer("SELECT count(*) FROM inventory_heads h WHERE h.revision != (SELECT count(*) FROM inventory_revisions r WHERE r.kind = h.kind AND r.id = h.id) + " + redactionFloorSQL + " OR h.revision != (SELECT max(revision) FROM inventory_revisions r WHERE r.kind = h.kind AND r.id = h.id) OR h.lot_id IS NOT (SELECT lot_id FROM inventory_revisions r WHERE r.kind = h.kind AND r.id = h.id AND r.revision = h.revision)") == 0,
              try integer("SELECT count(*) FROM inventory_tombstones t JOIN inventory_heads h ON h.kind = t.kind AND h.id = t.id") == 0 else {
            throw ComparisonStoreError.corruptRecord
        }
        // Stream retained payloads; integrity checking never loads the whole history into memory.
        let rows = try statement("SELECT payload, digest FROM inventory_revisions")
        defer { sqlite3_finalize(rows) }
        while true {
            let status = sqlite3_step(rows)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
            let bytes = try inventoryBlob(rows, column: 0, maximum: InventoryPersistenceLimits.recordBytes)
            guard inventoryDigest(bytes) == (try inventoryBlob(rows, column: 1, maximum: 32)) else { throw ComparisonStoreError.corruptRecord }
        }
    }

    func inventoryState(workspaceID: UUID) throws -> InventoryState {
        let row = try statement("SELECT revision, active FROM inventory_state WHERE singleton = 1")
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW, sqlite3_column_type(row, 0) == SQLITE_INTEGER,
              sqlite3_column_type(row, 1) == SQLITE_INTEGER else { throw ComparisonStoreError.corruptRecord }
        let revision = sqlite3_column_int64(row, 0), active = sqlite3_column_int64(row, 1)
        guard revision >= 0, active == 0 || active == 1 else { throw ComparisonStoreError.corruptRecord }
        return InventoryState(workspaceID: workspaceID, revision: revision, active: active == 1)
    }

    func inventoryErased(_ key: InventoryRecordKey) throws -> Bool {
        let row = try statement("SELECT 1 FROM inventory_tombstones WHERE kind = ? AND id = ?", values: [.text(key.kind.rawValue), .text(key.id.uuidString)])
        defer { sqlite3_finalize(row) }
        let result = sqlite3_step(row)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw ComparisonStoreError.database(result) }
        return result == SQLITE_ROW
    }

    func inventoryRetirementOperation(_ key: InventoryRecordKey) throws -> UUID? {
        let row = try statement("SELECT operation_id FROM inventory_tombstones WHERE kind = ? AND id = ?", values: [.text(key.kind.rawValue), .text(key.id.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let id = UUID(uuidString: try text(row, column: 0)) else { throw ComparisonStoreError.corruptRecord }
        return id
    }

    func inventoryRecords(kind: InventoryRecordKind, id: UUID? = nil, after: UUID? = nil, limit: Int = 1) throws -> [InventoryRecord] {
        var query = "SELECT h.kind, h.id, h.revision, r.payload_version, r.payload, r.digest, h.lot_id, h.source_origin, h.source_id FROM inventory_heads h JOIN inventory_revisions r ON r.kind = h.kind AND r.id = h.id AND r.revision = h.revision WHERE h.kind = ?"
        var values: [ComparisonSQLValue] = [.text(kind.rawValue)]
        if let id { query += " AND h.id = ?"; values.append(.text(id.uuidString)) }
        if let after { query += " AND h.id > ?"; values.append(.text(after.uuidString)) }
        query += " ORDER BY h.id LIMIT ?"; values.append(.integer(Int64(limit)))
        let rows = try statement(query, values: values); defer { sqlite3_finalize(rows) }
        var result: [InventoryRecord] = []
        while true {
            let status = sqlite3_step(rows)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let kind = InventoryRecordKind(rawValue: try text(rows, column: 0)),
                  let id = UUID(uuidString: try text(rows, column: 1)), sqlite3_column_type(rows, 2) == SQLITE_INTEGER,
                  sqlite3_column_type(rows, 3) == SQLITE_INTEGER else { throw ComparisonStoreError.corruptRecord }
            let payload = try inventoryBlob(rows, column: 4, maximum: InventoryPersistenceLimits.recordBytes)
            guard inventoryDigest(payload) == (try inventoryBlob(rows, column: 5, maximum: 32)) else { throw ComparisonStoreError.corruptRecord }
            var lot: UUID?
            if sqlite3_column_type(rows, 6) != SQLITE_NULL {
                guard let value = UUID(uuidString: try text(rows, column: 6)) else { throw ComparisonStoreError.corruptRecord }; lot = value
            }
            var source: InventorySourceIdentity?
            if sqlite3_column_type(rows, 7) != SQLITE_NULL {
                guard let origin = UUID(uuidString: try text(rows, column: 7)) else { throw ComparisonStoreError.corruptRecord }
                source = .init(originID: origin, sourceID: try text(rows, column: 8))
            }
            let revision = sqlite3_column_int64(rows, 2), version = sqlite3_column_int64(rows, 3)
            guard revision > 0, (1...10_000).contains(version), (!kind.requiresLot || lot != nil), (kind.permitsLot || lot == nil), (kind == .sourceLink) == (source != nil) else { throw ComparisonStoreError.corruptRecord }
            result.append(InventoryRecord(key: .init(kind, id), revision: revision, payloadVersion: Int(version), payload: payload, lotID: lot, source: source))
        }
    }

    func writeInventory(_ write: InventoryWrite) throws {
        let value = write.record
        if try inventoryErased(value.key) { throw ComparisonStoreError.erased }
        let existing = try inventoryRecords(kind: value.key.kind, id: value.key.id).first
        guard (existing?.revision ?? 0) == write.expectedRevision else { throw ComparisonStoreError.staleInventory }
        if let existing {
            guard (value.key.kind == .reservation || existing.lotID == value.lotID), existing.source == value.source else { throw ComparisonStoreError.operationConflict }
        }
        try run("INSERT INTO inventory_revisions (kind,id,revision,lot_id,payload_version,payload,digest) VALUES (?,?,?,?,?,?,?)",
            [.text(value.key.kind.rawValue), .text(value.key.id.uuidString), .integer(value.revision), value.lotID.map { .text($0.uuidString) } ?? .null, .integer(Int64(value.payloadVersion)),
             .blob(value.payload), .blob(inventoryDigest(value.payload))])
        try run("INSERT INTO inventory_heads (kind,id,revision,parent_kind,lot_id,source_origin,source_id) VALUES (?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET revision = excluded.revision, parent_kind = excluded.parent_kind, lot_id = excluded.lot_id",
            [.text(value.key.kind.rawValue), .text(value.key.id.uuidString), .integer(value.revision),
             value.lotID == nil ? .null : .text("lot"), value.lotID.map { .text($0.uuidString) } ?? .null,
             value.source.map { .text($0.originID.uuidString) } ?? .null, value.source.map { .text($0.sourceID) } ?? .null])
    }

    func eraseInventory(_ erase: InventoryErase, operationID: UUID) throws {
        guard let existing = try inventoryRecords(kind: erase.key.kind, id: erase.key.id).first else {
            if try inventoryErased(erase.key) { throw ComparisonStoreError.erased }
            throw ComparisonStoreError.notFound
        }
        guard existing.revision == erase.expectedRevision else { throw ComparisonStoreError.staleInventory }
        if let source = existing.source {
            try run("INSERT INTO inventory_retired_sources (origin_id, source_id, operation_id) VALUES (?,?,?)",
                [.text(source.originID.uuidString), .text(source.sourceID), .text(operationID.uuidString)])
        }
        try run("INSERT INTO inventory_tombstones (kind,id,revision,operation_id) VALUES (?,?,?,?)",
            [.text(erase.key.kind.rawValue), .text(erase.key.id.uuidString), .integer(erase.expectedRevision), .text(operationID.uuidString)])
        try run("DELETE FROM inventory_revisions WHERE kind = ? AND id = ?", [.text(erase.key.kind.rawValue), .text(erase.key.id.uuidString)])
        try run("DELETE FROM inventory_heads WHERE kind = ? AND id = ?", [.text(erase.key.kind.rawValue), .text(erase.key.id.uuidString)])
    }

    func inventoryReceipt(_ id: UUID) throws -> (digest: Data, requestDigest: Data, receipt: InventoryOperationReceipt)? {
        let row = try statement("SELECT digest, receipt, request_digest FROM inventory_operations WHERE id = ?", values: [.text(id.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
        let digest = try inventoryBlob(row, column: 0, maximum: 32)
        let receipt: InventoryOperationReceipt
        do { receipt = try JSONDecoder().decode(InventoryOperationReceipt.self, from: inventoryBlob(row, column: 1, maximum: 131_072)) }
        catch { throw ComparisonStoreError.corruptRecord }
        guard digest.count == 32, receipt.operationID == id, receipt.revision > 0,
              receipt.committedAt.timeIntervalSinceReferenceDate.isFinite,
              receipt.heads.count + receipt.comparisonHeads.count <= InventoryPersistenceLimits.batchItems else { throw ComparisonStoreError.corruptRecord }
        let requestDigest = try inventoryBlob(row, column: 2, maximum: 32)
        guard requestDigest.count == 32 else { throw ComparisonStoreError.corruptRecord }
        return (digest, requestDigest, receipt)
    }

    func inventoryBlob(_ row: OpaquePointer, column: Int32, maximum: Int) throws -> Data {
        let length = Int(sqlite3_column_bytes(row, column))
        guard sqlite3_column_type(row, column) == SQLITE_BLOB, length > 0, length <= maximum,
              let bytes = sqlite3_column_blob(row, column) else { throw ComparisonStoreError.corruptRecord }
        return Data(bytes: bytes, count: length)
    }
}
