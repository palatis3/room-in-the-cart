import Foundation
import CryptoKit
import CSQLite

struct InventoryMigrationHeader {
    let id: UUID
    let digest: Data
    let plan: InventoryMigrationPlan?
    let status: InventoryMigrationProgress.Status
    let nextChunk: Int
    let recordCount: Int
    let chainDigest: Data
}

extension ComparisonDatabase {
    static let inventoryMigrationSchema = """
        CREATE TABLE inventory_migrations (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
            digest BLOB NOT NULL CHECK(typeof(digest) = 'blob' AND length(digest) = 32),
            plan BLOB CHECK(plan IS NULL OR (typeof(plan) = 'blob' AND length(plan) BETWEEN 1 AND 131072)),
            status TEXT NOT NULL CHECK(status IN ('staging','active','cancelled')),
            next_chunk INTEGER NOT NULL CHECK(typeof(next_chunk) = 'integer' AND next_chunk BETWEEN 0 AND 1000000),
            record_count INTEGER NOT NULL CHECK(typeof(record_count) = 'integer' AND record_count BETWEEN 0 AND 256000000),
            chain_digest BLOB NOT NULL CHECK(typeof(chain_digest) = 'blob' AND length(chain_digest) = 32),
            CHECK((status = 'staging' AND plan IS NOT NULL) OR (status != 'staging' AND plan IS NULL))
        );
        CREATE UNIQUE INDEX inventory_one_staging ON inventory_migrations(status) WHERE status = 'staging';
        CREATE TABLE inventory_migration_chunks (
            migration_id TEXT NOT NULL REFERENCES inventory_migrations(id),
            chunk_index INTEGER NOT NULL CHECK(typeof(chunk_index) = 'integer' AND chunk_index BETWEEN 0 AND 999999),
            digest BLOB NOT NULL CHECK(typeof(digest) = 'blob' AND length(digest) = 32),
            record_count INTEGER NOT NULL CHECK(typeof(record_count) = 'integer' AND record_count BETWEEN 1 AND 256),
            PRIMARY KEY(migration_id, chunk_index)
        );
        CREATE TABLE inventory_staged_records (
            migration_id TEXT NOT NULL REFERENCES inventory_migrations(id),
            kind TEXT NOT NULL CHECK(kind IN ('lot','observation','event','reservation','sourceLink','intent')),
            id TEXT NOT NULL CHECK(length(id) = 36),
            chunk_index INTEGER NOT NULL,
            record_ordinal INTEGER NOT NULL CHECK(record_ordinal BETWEEN 0 AND 255),
            source_origin TEXT,
            source_id TEXT,
            record BLOB NOT NULL CHECK(typeof(record) = 'blob' AND length(record) BETWEEN 1 AND 131072),
            PRIMARY KEY(migration_id, kind, id),
            UNIQUE(migration_id, source_origin, source_id),
            UNIQUE(migration_id, chunk_index, record_ordinal),
            FOREIGN KEY(migration_id, chunk_index) REFERENCES inventory_migration_chunks(migration_id, chunk_index) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TABLE inventory_migration_sources (
            migration_id TEXT NOT NULL REFERENCES inventory_migrations(id),
            comparison_id TEXT NOT NULL CHECK(length(comparison_id) = 36),
            revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0),
            PRIMARY KEY(migration_id, comparison_id)
        );
        CREATE TABLE inventory_migration_keys (
            migration_id TEXT NOT NULL REFERENCES inventory_migrations(id),
            kind TEXT NOT NULL,
            id TEXT NOT NULL CHECK(length(id) = 36),
            PRIMARY KEY(migration_id, kind, id)
        );
        CREATE TRIGGER inventory_migration_identity BEFORE UPDATE ON inventory_migrations
        WHEN NEW.id != OLD.id OR NEW.digest != OLD.digest OR OLD.status != 'staging'
          OR NEW.next_chunk < OLD.next_chunk OR NEW.record_count < OLD.record_count
          OR (NEW.status = 'staging' AND NEW.plan != OLD.plan)
        BEGIN SELECT RAISE(ABORT, 'immutable migration identity'); END;
        CREATE TRIGGER inventory_migration_delete BEFORE DELETE ON inventory_migrations
        BEGIN SELECT RAISE(ABORT, 'migration retirement required'); END;
        CREATE TRIGGER inventory_chunk_update BEFORE UPDATE ON inventory_migration_chunks
        BEGIN SELECT RAISE(ABORT, 'immutable migration chunk'); END;
        CREATE TRIGGER inventory_chunk_delete BEFORE DELETE ON inventory_migration_chunks
        BEGIN SELECT RAISE(ABORT, 'immutable migration chunk'); END;
        CREATE TRIGGER inventory_staged_update BEFORE UPDATE ON inventory_staged_records
        BEGIN SELECT RAISE(ABORT, 'immutable staged record'); END;
        CREATE TRIGGER inventory_staged_delete BEFORE DELETE ON inventory_staged_records
        WHEN EXISTS (SELECT 1 FROM inventory_migrations WHERE id = OLD.migration_id AND status = 'staging')
        BEGIN SELECT RAISE(ABORT, 'active staging record'); END;
        CREATE TRIGGER inventory_staged_insert BEFORE INSERT ON inventory_staged_records
        WHEN NOT EXISTS (SELECT 1 FROM inventory_migrations WHERE id = NEW.migration_id AND status = 'staging')
        BEGIN SELECT RAISE(ABORT, 'retired migration'); END;
        CREATE TRIGGER inventory_migration_key_update BEFORE UPDATE ON inventory_migration_keys
        BEGIN SELECT RAISE(ABORT, 'immutable migration key'); END;
        CREATE TRIGGER inventory_migration_key_delete BEFORE DELETE ON inventory_migration_keys
        BEGIN SELECT RAISE(ABORT, 'immutable migration key'); END;
        CREATE TRIGGER inventory_migration_source_update BEFORE UPDATE ON inventory_migration_sources
        BEGIN SELECT RAISE(ABORT, 'immutable migration source'); END;
        CREATE TRIGGER inventory_migration_source_delete BEFORE DELETE ON inventory_migration_sources
        WHEN NOT EXISTS (SELECT 1 FROM inventory_migrations WHERE id = OLD.migration_id AND status = 'cancelled')
        BEGIN SELECT RAISE(ABORT, 'retained migration source'); END;
        """

    /// Only small identity rows enter the hash at any time; original payloads are never concatenated.
    func inventorySourceToken(workspaceID: UUID) throws -> InventorySourceToken {
        var hash = SHA256()
        hash.update(data: Data("inventory-source-manifest:v1:\(workspaceID.uuidString)".utf8))
        let queries = ["SELECT id, head_revision, '' FROM comparisons ORDER BY id",
            "SELECT comparison_id, erased_revision, operation_id FROM comparison_tombstones ORDER BY comparison_id"]
        for (index, query) in queries.enumerated() {
            hash.update(data: Data([UInt8(index)]))
            let rows = try statement(query); defer { sqlite3_finalize(rows) }
            while true {
                let status = sqlite3_step(rows)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, sqlite3_column_type(rows, 1) == SQLITE_INTEGER else { throw ComparisonStoreError.corruptRecord }
                let id = try text(rows, column: 0), operation = try text(rows, column: 2)
                guard UUID(uuidString: id)?.uuidString == id, operation.isEmpty || UUID(uuidString: operation)?.uuidString == operation else { throw ComparisonStoreError.corruptRecord }
                let revision = sqlite3_column_int64(rows, 1)
                guard revision > 0 else { throw ComparisonStoreError.corruptRecord }
                hash.update(data: Data("\(id):\(revision):\(operation)\n".utf8))
            }
        }
        return InventorySourceToken(workspaceID: workspaceID,
            generation: try integer("SELECT source_generation FROM inventory_state WHERE singleton = 1"), digest: Data(hash.finalize()))
    }

    func hasStagingMigration() throws -> Bool { try integer("SELECT count(*) FROM inventory_migrations WHERE status = 'staging'") != 0 }

    func migrationHeader(_ id: UUID) throws -> InventoryMigrationHeader? {
        let row = try statement("SELECT digest,plan,status,next_chunk,record_count,chain_digest FROM inventory_migrations WHERE id = ?", values: [.text(id.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let state = InventoryMigrationProgress.Status(rawValue: try text(row, column: 2)),
              sqlite3_column_type(row, 3) == SQLITE_INTEGER, sqlite3_column_type(row, 4) == SQLITE_INTEGER else { throw ComparisonStoreError.corruptRecord }
        let digest = try inventoryBlob(row, column: 0, maximum: 32)
        let chain = try inventoryBlob(row, column: 5, maximum: 32)
        var plan: InventoryMigrationPlan?
        if sqlite3_column_type(row, 1) != SQLITE_NULL {
            let bytes = try inventoryBlob(row, column: 1, maximum: 131_072)
            guard inventoryDigest(bytes) == digest else { throw ComparisonStoreError.corruptRecord }
            do { plan = try JSONDecoder().decode(InventoryMigrationPlan.self, from: bytes) }
            catch { throw ComparisonStoreError.corruptRecord }
            guard plan?.version == 1, plan?.migrationID == id else { throw ComparisonStoreError.corruptRecord }
        }
        let count = sqlite3_column_int64(row, 4), next = sqlite3_column_int64(row, 3)
        guard (state == .staging) == (plan != nil), (0...1_000_000).contains(next), (0...256_000_000).contains(count),
              digest.count == 32, chain.count == 32 else { throw ComparisonStoreError.corruptRecord }
        return InventoryMigrationHeader(id: id, digest: digest, plan: plan, status: state, nextChunk: Int(next), recordCount: Int(count), chainDigest: chain)
    }

    func migrationChunkDigest(_ id: UUID, index: Int) throws -> Data? {
        let row = try statement("SELECT digest FROM inventory_migration_chunks WHERE migration_id = ? AND chunk_index = ?",
            values: [.text(id.uuidString), .integer(Int64(index))]); defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
        return try inventoryBlob(row, column: 0, maximum: 32)
    }

    func stagedRecords(_ id: UUID, kind: InventoryRecordKind, after: UUID?) throws -> [InventoryRecord] {
        var query = "SELECT kind,id,record FROM inventory_staged_records WHERE migration_id = ? AND kind = ?"
        var values: [ComparisonSQLValue] = [.text(id.uuidString), .text(kind.rawValue)]
        if let after { query += " AND id > ?"; values.append(.text(after.uuidString)) }
        query += " ORDER BY id LIMIT 200"
        return try decodedStagedRecords(query, values: values)
    }

    private func decodedStagedRecords(_ query: String, values: [ComparisonSQLValue]) throws -> [InventoryRecord] {
        let rows = try statement(query, values: values); defer { sqlite3_finalize(rows) }
        var records: [InventoryRecord] = []
        while true {
            let status = sqlite3_step(rows)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW, records.count < InventoryPersistenceLimits.batchItems else { throw ComparisonStoreError.corruptRecord }
            let value: InventoryRecord
            do { value = try JSONDecoder().decode(InventoryRecord.self, from: inventoryBlob(rows, column: 2, maximum: 131_072)) }
            catch { throw ComparisonStoreError.corruptRecord }
            guard value.key.kind.rawValue == (try text(rows, column: 0)), value.key.id.uuidString == (try text(rows, column: 1)) else { throw ComparisonStoreError.corruptRecord }
            records.append(value)
        }
    }

    func forEachStagedAcquisition(_ id: UUID, chunk: Int? = nil, _ body: (InventoryAcquisitionRow) throws -> Void) throws {
        var query = "SELECT row FROM inventory_staged_acquisitions WHERE migration_id=?"
        var args: [ComparisonSQLValue] = [.text(id.uuidString)]
        if let chunk {
            query += " AND chunk_index=? ORDER BY ordinal"
            args.append(.integer(Int64(chunk)))
        } else { query += " ORDER BY revision,id" }
        let cursor = try statement(query, values: args)
        defer { sqlite3_finalize(cursor) }
        while true {
            let status = sqlite3_step(cursor)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
            try body(JSONDecoder().decode(InventoryAcquisitionRow.self, from: inventoryBlob(cursor, column: 0, maximum: 131_072)))
        }
    }

    func validateStagedManifest(_ header: InventoryMigrationHeader) throws {
        guard try integer("SELECT (SELECT count(*) FROM inventory_staged_records WHERE migration_id = '\(header.id.uuidString)') + (SELECT count(*) FROM inventory_staged_acquisitions WHERE migration_id = '\(header.id.uuidString)')") == Int64(header.recordCount),
              try integer("SELECT count(*) FROM inventory_migration_chunks WHERE migration_id = '\(header.id.uuidString)'") == Int64(header.nextChunk) else {
            throw ComparisonStoreError.corruptRecord
        }
        var digest = InventoryMigrationManifest.initialDigest, count = 0
        for index in 0..<header.nextChunk {
            let records = try decodedStagedRecords("SELECT kind,id,record FROM inventory_staged_records WHERE migration_id = ? AND chunk_index = ? ORDER BY record_ordinal LIMIT 257",
                values: [.text(header.id.uuidString), .integer(Int64(index))])
            var acquisitions: [InventoryAcquisitionRow] = []
            try forEachStagedAcquisition(header.id, chunk: index) { row in
                guard records.count + acquisitions.count < InventoryPersistenceLimits.batchItems else { throw ComparisonStoreError.corruptRecord }
                acquisitions.append(row)
            }
            let chunk = InventoryMigrationChunk(index: index, records: records, acquisitions: acquisitions)
            try validateInventoryMigrationChunk(chunk)
            guard try migrationChunkDigest(header.id, index: index) == inventoryDigest(inventoryCanonical(chunk)) else { throw ComparisonStoreError.corruptRecord }
            digest = try InventoryMigrationManifest.appending(chunk, to: digest); count += chunk.itemCount
        }
        guard count == header.recordCount, digest == header.chainDigest else { throw ComparisonStoreError.corruptRecord }
    }

    /// Indexed SQL EXISTS checks do not materialize the imported-key manifest, however large it is.
    func validateMigrationReceiptAccess(_ id: UUID, receipt: InventoryOperationReceipt) throws {
        guard receipt.operationID == id, let header = try migrationHeader(id), header.status == .active,
              receipt.heads.isEmpty, receipt.comparisonHeads.isEmpty,
              try integer("SELECT count(*) FROM inventory_migration_keys WHERE migration_id = '\(id.uuidString)'") == Int64(header.recordCount) else { throw ComparisonStoreError.corruptRecord }
        if try integer("PRAGMA user_version") >= 4,
           try integer("SELECT count(*) FROM inventory_migration_keys k JOIN inventory_reservation_redactions d ON k.kind='reservation' AND k.id=d.id WHERE k.migration_id='\(id.uuidString)'") > 0 { throw ComparisonStoreError.erased }
        let rows = try statement("""
            SELECT EXISTS(SELECT 1 FROM inventory_migration_keys k JOIN inventory_tombstones t ON t.kind = k.kind AND t.id = k.id WHERE k.migration_id = ?),
                   EXISTS(SELECT 1 FROM inventory_migration_sources s JOIN comparison_tombstones t ON t.comparison_id = s.comparison_id WHERE s.migration_id = ?)
            """, values: [.text(id.uuidString), .text(id.uuidString)]); defer { sqlite3_finalize(rows) }
        guard sqlite3_step(rows) == SQLITE_ROW else { throw ComparisonStoreError.corruptRecord }
        guard sqlite3_column_int64(rows, 0) == 0, sqlite3_column_int64(rows, 1) == 0 else { throw ComparisonStoreError.erased }
    }
}
