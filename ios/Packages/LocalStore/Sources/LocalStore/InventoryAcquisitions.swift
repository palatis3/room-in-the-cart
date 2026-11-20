import CSQLite
import Foundation

/// Indexed metadata for an immutable acquisition-line revision. The app validates
/// food, provenance and price semantics before supplying the bounded payload.
public struct InventoryAcquisitionRow: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let receiptID: UUID
    public let lineID: UUID
    public let lotID: UUID
    public let revision: Int64
    public let supersedesID: UUID?
    public let imageIdentity: UUID?
    public let transactionIdentity: UUID?
    public let payload: Data
    public init(id: UUID, receiptID: UUID, lineID: UUID, lotID: UUID, revision: Int64, supersedesID: UUID?, payload: Data, imageIdentity: UUID? = nil, transactionIdentity: UUID? = nil) {
        self.id = id; self.receiptID = receiptID; self.lineID = lineID; self.lotID = lotID
        self.imageIdentity = imageIdentity; self.transactionIdentity = transactionIdentity
        self.revision = revision; self.supersedesID = supersedesID; self.payload = payload
    }
}

extension ComparisonStore {
    public func acquisitionReceiptID(for identity: UUID) throws -> UUID? {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        let row = try database.statement("SELECT receipt_id FROM inventory_acquisition_identities WHERE identity=?", values: [.text(identity.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let result = try UUID(uuidString: database.text(row, column: 0)) else { throw ComparisonStoreError.corruptRecord }
        return result
    }

    public func acquisitionRows(receiptID: UUID? = nil, lineIDs: [UUID]? = nil, sourceIDs: [UUID]? = nil, revision: Int64? = nil, firstRevisionOnly: Bool = false, latestForLine: Bool = false, currentOnly: Bool = false, after: UUID? = nil, limit: Int = 100) throws -> [InventoryAcquisitionRow] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        guard (1...InventoryPersistenceLimits.pageItems).contains(limit) else { throw ComparisonStoreError.invalidInput }
        var conditions = ["1=1"], values: [ComparisonSQLValue] = []
        if let receiptID { conditions.append("receipt_id=?"); values.append(.text(receiptID.uuidString)) }
        guard !latestForLine || (lineIDs?.count == 1 && after == nil && limit == 1) else { throw ComparisonStoreError.invalidInput }
        if let lineIDs {
            guard !lineIDs.isEmpty, lineIDs.count <= InventoryPersistenceLimits.pageItems else { throw ComparisonStoreError.invalidInput }
            let parameters = Array(repeating: "?", count: lineIDs.count).joined(separator: ",")
            conditions.append("line_id IN (" + parameters + ")")
            values += lineIDs.map { .text($0.uuidString) }
        }
        if let sourceIDs {
            guard (1...InventoryPersistenceLimits.pageItems).contains(sourceIDs.count) else { throw ComparisonStoreError.invalidInput }
            let marks = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            conditions.append("id IN (" + marks + ")")
            values += sourceIDs.map { .text($0.uuidString) }
        }
        if currentOnly {
            conditions.append("NOT EXISTS(SELECT 1 FROM inventory_acquisitions n WHERE n.line_id=a.line_id AND n.revision>a.revision)")
        }
        if let revision { conditions.append("revision=?"); values.append(.integer(revision)) }
        if firstRevisionOnly { conditions.append("revision=1") }
        if let after { conditions.append("id>?"); values.append(.text(after.uuidString)) }
        values.append(.integer(Int64(limit)))
        let query = try database.statement("""
          SELECT id,receipt_id,line_id,lot_id,revision,supersedes,payload,digest,image_identity,transaction_identity FROM inventory_acquisitions a
          WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(latestForLine ? "revision DESC" : "id") LIMIT ?
          """, values: values)
        defer { sqlite3_finalize(query) }
        var result: [InventoryAcquisitionRow] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
            func uuid(_ column: Int32) throws -> UUID {
                guard let text = sqlite3_column_text(query, column), let id = UUID(uuidString: String(cString: text)) else {
                    throw ComparisonStoreError.corruptRecord
                }
                return id
            }
            let bytes = try database.inventoryBlob(query, column: 6, maximum: InventoryPersistenceLimits.recordBytes)
            guard try database.inventoryBlob(query, column: 7, maximum: 32) == inventoryDigest(bytes) else { throw ComparisonStoreError.corruptRecord }
            result.append(try .init(id: uuid(0), receiptID: uuid(1), lineID: uuid(2), lotID: uuid(3),
                revision: sqlite3_column_int64(query, 4), supersedesID: sqlite3_column_type(query, 5) == SQLITE_NULL ? nil : uuid(5), payload: bytes,
                imageIdentity: sqlite3_column_type(query, 8) == SQLITE_NULL ? nil : uuid(8),
                transactionIdentity: sqlite3_column_type(query, 9) == SQLITE_NULL ? nil : uuid(9)))
        }
    }
}

extension ComparisonDatabase {
    func migrateAcquisitions() throws {
        try transaction {
            let version = try integer("PRAGMA user_version")
            if (5...Self.inventorySchemaVersion).contains(version) { try validateAcquisitions(); return }
            guard version == 4 else { throw ComparisonStoreError.unsupportedSchema(version) }
            try execute("""
              CREATE TABLE inventory_acquisitions (
                id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
                receipt_id TEXT NOT NULL CHECK(length(receipt_id)=36),
                line_id TEXT NOT NULL CHECK(length(line_id)=36),
                lot_id TEXT NOT NULL CHECK(length(lot_id)=36),
                parent_kind TEXT NOT NULL DEFAULT 'lot' CHECK(parent_kind='lot'),
                revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
                supersedes TEXT UNIQUE,
                image_identity TEXT, transaction_identity TEXT,
                payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 65536),
                digest BLOB NOT NULL CHECK(typeof(digest)='blob' AND length(digest)=32),
                UNIQUE(line_id, revision),
                CHECK((revision=1 AND supersedes IS NULL) OR (revision>1 AND supersedes IS NOT NULL)),
                FOREIGN KEY(parent_kind,lot_id) REFERENCES inventory_heads(kind,id) ON DELETE CASCADE
              );
              CREATE TABLE inventory_acquisition_identities (
                identity TEXT PRIMARY KEY NOT NULL CHECK(length(identity)=36), receipt_id TEXT NOT NULL CHECK(length(receipt_id)=36)
              );
              CREATE INDEX inventory_acquisitions_receipt ON inventory_acquisitions(receipt_id,id);
              CREATE INDEX inventory_acquisitions_lot ON inventory_acquisitions(lot_id);
              CREATE TABLE inventory_retired_acquisition_lines (line_id TEXT PRIMARY KEY NOT NULL CHECK(length(line_id)=36));
              CREATE TRIGGER inventory_acquisition_retire BEFORE DELETE ON inventory_acquisitions
                BEGIN INSERT OR IGNORE INTO inventory_retired_acquisition_lines VALUES (OLD.line_id); END;
              CREATE TRIGGER inventory_acquisition_immutable BEFORE UPDATE ON inventory_acquisitions
                BEGIN SELECT RAISE(ABORT,'immutable acquisition'); END;
              CREATE TRIGGER inventory_acquisition_identity BEFORE INSERT ON inventory_acquisitions
                WHEN EXISTS(SELECT 1 FROM inventory_retired_acquisition_lines WHERE line_id=NEW.line_id)
                  OR (NEW.revision>1 AND NOT EXISTS(SELECT 1 FROM inventory_acquisitions p WHERE p.id=NEW.supersedes
                      AND p.receipt_id=NEW.receipt_id AND p.line_id=NEW.line_id AND p.lot_id=NEW.lot_id AND p.revision=NEW.revision-1))
                BEGIN SELECT RAISE(ABORT,'invalid acquisition lineage'); END;
              CREATE TABLE inventory_staged_acquisitions (
                migration_id TEXT NOT NULL REFERENCES inventory_migrations(id),
                id TEXT NOT NULL, revision INTEGER NOT NULL,
                chunk_index INTEGER NOT NULL, ordinal INTEGER NOT NULL,
                row BLOB NOT NULL, PRIMARY KEY(migration_id,id),
                UNIQUE(migration_id,chunk_index,ordinal),
                FOREIGN KEY(migration_id,chunk_index) REFERENCES inventory_migration_chunks(migration_id,chunk_index) DEFERRABLE INITIALLY DEFERRED
              );
              CREATE INDEX inventory_staged_acquisition_order ON inventory_staged_acquisitions(migration_id,revision,id);
              CREATE TRIGGER inventory_origin_acquisition_retirement BEFORE INSERT ON inventory_origin_retirement
                WHEN EXISTS(SELECT 1 FROM inventory_acquisitions) OR EXISTS(SELECT 1 FROM inventory_staged_acquisitions)
                BEGIN SELECT RAISE(ABORT,'origin still has receipt evidence'); END;
              PRAGMA user_version=5;
              """)
            try validateAcquisitions()
        }
    }
    func validateAcquisitions() throws {
        guard try integer("""
             SELECT count(*) FROM sqlite_master WHERE (type='table' AND name IN ('inventory_acquisitions','inventory_retired_acquisition_lines','inventory_staged_acquisitions','inventory_acquisition_identities'))
             OR (type='trigger' AND name IN ('inventory_acquisition_retire','inventory_acquisition_immutable','inventory_acquisition_identity','inventory_origin_acquisition_retirement'))
             OR (type='index' AND name IN ('inventory_acquisitions_receipt','inventory_acquisitions_lot','inventory_staged_acquisition_order'))
             """) == 11,
              try integer("SELECT count(*) FROM inventory_acquisitions a JOIN inventory_retired_acquisition_lines t ON t.line_id=a.line_id") == 0
        else { throw ComparisonStoreError.corruptRecord }
    }
    func indexReceiptIdentity(_ identity: UUID, receiptID: UUID) throws {
        try run("INSERT INTO inventory_acquisition_identities(identity,receipt_id) VALUES(?,?) ON CONFLICT(identity) DO NOTHING",
            [.text(identity.uuidString), .text(receiptID.uuidString)])
        let check = try statement("SELECT receipt_id FROM inventory_acquisition_identities WHERE identity=?", values: [.text(identity.uuidString)])
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW, try text(check, column: 0) == receiptID.uuidString else { throw ComparisonStoreError.operationConflict }
    }
    func insertAcquisition(_ row: InventoryAcquisitionRow) throws {
        for identity in [row.imageIdentity, row.transactionIdentity].compactMap({ $0 }) {
            try indexReceiptIdentity(identity, receiptID: row.receiptID)
        }
        let old = row.supersedesID.map { ComparisonSQLValue.text($0.uuidString) } ?? .null
        try run("INSERT INTO inventory_acquisitions(id,receipt_id,line_id,lot_id,revision,supersedes,payload,digest,image_identity,transaction_identity) VALUES(?,?,?,?,?,?,?,?,?,?)", [
            .text(row.id.uuidString), .text(row.receiptID.uuidString), .text(row.lineID.uuidString), .text(row.lotID.uuidString),
            .integer(row.revision), old, .blob(row.payload), .blob(inventoryDigest(row.payload)),
            row.imageIdentity.map { .text($0.uuidString) } ?? .null, row.transactionIdentity.map { .text($0.uuidString) } ?? .null])
    }
}
