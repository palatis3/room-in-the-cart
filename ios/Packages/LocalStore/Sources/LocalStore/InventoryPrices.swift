import CSQLite
import Foundation

/// Price revisions may exist without a lot. An explicitly linked physical lot carries its erasure policy.
public struct InventoryPriceRow: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: Int64
    public let lotID: UUID?
    public let adjustsPriceID: UUID?
    public let payload: Data

    public init(id: UUID, revision: Int64, lotID: UUID?, adjustsPriceID: UUID? = nil, payload: Data) {
        self.id = id
        self.revision = revision
        self.lotID = lotID
        self.adjustsPriceID = adjustsPriceID
        self.payload = payload
    }
}

extension ComparisonStore {
    public func priceWasErased(_ id: UUID) throws -> Bool {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        return try database.priceWasErased(id)
    }
    public func retiredPriceIDs(after: UUID? = nil, limit: Int = 100) throws -> [UUID] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        guard (1...InventoryPersistenceLimits.pageItems).contains(limit) else { throw ComparisonStoreError.invalidInput }
        let query = try database.statement("SELECT id FROM inventory_retired_prices WHERE id>? ORDER BY id LIMIT ?",
            values: [.text(after?.uuidString ?? ""), .integer(Int64(limit))])
        defer { sqlite3_finalize(query) }
        var ids: [UUID] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return ids }
            guard status == SQLITE_ROW, let id = UUID(uuidString: try database.text(query, column: 0)) else {
                throw ComparisonStoreError.corruptRecord
            }
            ids.append(id)
        }
    }

    public func priceRevisionCount(for id: UUID? = nil, lotIDs: Set<UUID>? = nil) throws -> Int {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        func count(_ predicate: String, _ values: [ComparisonSQLValue]) throws -> Int {
            let read = try database.statement("SELECT count(*) FROM inventory_prices " + predicate, values: values)
            defer { sqlite3_finalize(read) }
            guard sqlite3_step(read) == SQLITE_ROW else { throw ComparisonStoreError.corruptRecord }
            return Int(sqlite3_column_int64(read, 0))
        }
        if let id { return try count("WHERE id=? OR adjusts=?", [.text(id.uuidString), .text(id.uuidString)]) }
        guard let lotIDs else { return try count("", []) }
        let ids = Array(lotIDs)
        var total = 0
        for start in stride(from: 0, to: ids.count, by: 200) {
            let slice = ids[start..<min(start + 200, ids.count)]
            let slots = Array(repeating: "?", count: slice.count).joined(separator: ",")
            total += try count("WHERE lot_id IN (" + slots + ")", slice.map { .text($0.uuidString) })
        }
        return total
    }

    public func priceRows(id: UUID? = nil, revision: Int64? = nil, adjustmentsFor: UUID? = nil, after: InventoryPriceRow? = nil, latestOnly: Bool = true,
                          limit: Int = 100) throws -> [InventoryPriceRow] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        guard (1...InventoryPersistenceLimits.pageItems).contains(limit) else { throw ComparisonStoreError.invalidInput }
        var predicates = ["1=1"]
        var values: [ComparisonSQLValue] = []
        if let id { predicates.append("p.id=?"); values.append(.text(id.uuidString)) }
        if let revision { predicates.append("p.revision=?"); values.append(.integer(revision)) }
        if let adjustmentsFor { predicates.append("p.adjusts=?"); values.append(.text(adjustmentsFor.uuidString)) }
        if latestOnly {
            predicates.append("NOT EXISTS(SELECT 1 FROM inventory_prices n WHERE n.id=p.id AND n.revision>p.revision)")
        }
        if let after {
            predicates.append("(p.id,p.revision)>(?,?)")
            values += [.text(after.id.uuidString), .integer(after.revision)]
        }
        values.append(.integer(Int64(limit)))
        let query = try database.statement("""
            SELECT p.id,p.revision,p.lot_id,p.payload,p.digest,p.adjusts FROM inventory_prices p
            WHERE \(predicates.joined(separator: " AND ")) ORDER BY p.id,p.revision LIMIT ?
            """, values: values)
        defer { sqlite3_finalize(query) }
        var rows: [InventoryPriceRow] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW, let id = UUID(uuidString: try database.text(query, column: 0)) else {
                throw ComparisonStoreError.corruptRecord
            }
            let lotID: UUID?
            if sqlite3_column_type(query, 2) == SQLITE_NULL { lotID = nil }
            else {
                guard let linked = UUID(uuidString: try database.text(query, column: 2)) else { throw ComparisonStoreError.corruptRecord }
                lotID = linked
            }
            let payload = try database.inventoryBlob(query, column: 3, maximum: InventoryPersistenceLimits.recordBytes)
            guard try database.inventoryBlob(query, column: 4, maximum: 32) == inventoryDigest(payload) else { throw ComparisonStoreError.corruptRecord }
            let adjusts: UUID?
            if sqlite3_column_type(query, 5) == SQLITE_NULL { adjusts = nil }
            else {
                guard let value = UUID(uuidString: try database.text(query, column: 5)) else { throw ComparisonStoreError.corruptRecord }
                adjusts = value
            }
            rows.append(.init(id: id, revision: sqlite3_column_int64(query, 1), lotID: lotID, adjustsPriceID: adjusts, payload: payload))
        }
    }
}

extension ComparisonDatabase {
    func migratePrices() throws {
        try transaction {
            let version = try integer("PRAGMA user_version")
            if version == 7 { try validatePrices(); return }
            guard version == 6 else { throw ComparisonStoreError.unsupportedSchema(version) }
            try execute("""
                CREATE TABLE inventory_prices(
                    id TEXT NOT NULL CHECK(length(id)=36), revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
                    parent_kind TEXT NOT NULL DEFAULT 'lot' CHECK(parent_kind='lot'), lot_id TEXT, adjusts TEXT CHECK(adjusts IS NULL OR length(adjusts)=36),
                    payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 65536),
                    digest BLOB NOT NULL CHECK(typeof(digest)='blob' AND length(digest)=32),
                    PRIMARY KEY(id,revision), FOREIGN KEY(parent_kind,lot_id) REFERENCES inventory_heads(kind,id) ON DELETE CASCADE);
                CREATE INDEX inventory_prices_lot ON inventory_prices(lot_id);
                CREATE INDEX inventory_price_adjustments ON inventory_prices(adjusts,id,revision);
                CREATE TABLE inventory_staged_prices(
                    migration_id TEXT NOT NULL REFERENCES inventory_migrations(id), id TEXT NOT NULL, revision INTEGER NOT NULL,
                    chunk_index INTEGER NOT NULL, ordinal INTEGER NOT NULL, row BLOB NOT NULL,
                    PRIMARY KEY(migration_id,id,revision), UNIQUE(migration_id,chunk_index,ordinal),
                    FOREIGN KEY(migration_id,chunk_index) REFERENCES inventory_migration_chunks(migration_id,chunk_index) DEFERRABLE INITIALLY DEFERRED);
                CREATE INDEX inventory_staged_price_order ON inventory_staged_prices(migration_id,revision,id);
                CREATE TABLE inventory_retired_prices(id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36));
                CREATE TRIGGER inventory_price_insert BEFORE INSERT ON inventory_prices
                WHEN EXISTS(SELECT 1 FROM inventory_retired_prices WHERE id=NEW.id)
                    OR EXISTS(SELECT 1 FROM inventory_origin_retirement)
                    OR (NEW.revision>1 AND NOT EXISTS(SELECT 1 FROM inventory_prices p
                        WHERE p.id=NEW.id AND p.revision=NEW.revision-1 AND p.lot_id IS NEW.lot_id AND p.adjusts IS NEW.adjusts))
                BEGIN SELECT RAISE(ABORT,'invalid price revision'); END;
                CREATE TRIGGER inventory_price_update BEFORE UPDATE ON inventory_prices
                BEGIN SELECT RAISE(ABORT,'immutable price'); END;
                CREATE TRIGGER inventory_price_retire BEFORE DELETE ON inventory_prices
                BEGIN INSERT OR IGNORE INTO inventory_retired_prices(id) VALUES(OLD.id); END;
                PRAGMA user_version=7;
                """)
            try validatePrices()
        }
    }

    func validatePrices() throws {
        guard try integer("""
            SELECT count(*) FROM sqlite_master WHERE
            (type='table' AND name IN ('inventory_prices','inventory_retired_prices','inventory_staged_prices')) OR
            (type='index' AND name IN ('inventory_prices_lot','inventory_price_adjustments','inventory_staged_price_order')) OR
            (type='trigger' AND name IN ('inventory_price_insert','inventory_price_update','inventory_price_retire'))
            """) == 9 else { throw ComparisonStoreError.corruptRecord }
    }

    func priceWasErased(_ id: UUID) throws -> Bool {
        let query = try statement("SELECT 1 FROM inventory_retired_prices WHERE id=?", values: [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        switch sqlite3_step(query) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let status: throw ComparisonStoreError.database(status)
        }
    }

    func erasePrice(_ price: InventoryErasureManifest.Price) throws -> Int64 {
        let query = try statement("SELECT max(revision) FROM inventory_prices WHERE id=?", values: [.text(price.id.uuidString)])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_type(query, 0) != SQLITE_NULL,
              sqlite3_column_int64(query, 0) == price.revision else { throw ComparisonStoreError.staleInventory }
        try run("DELETE FROM inventory_prices WHERE id=? OR adjusts=?", [.text(price.id.uuidString), .text(price.id.uuidString)])
        return try integer("SELECT changes()")
    }

    func insertPrice(_ row: InventoryPriceRow) throws {
        guard row.revision > 0, !row.payload.isEmpty, row.payload.count <= InventoryPersistenceLimits.recordBytes else {
            throw ComparisonStoreError.invalidInput
        }
        try run("INSERT INTO inventory_prices(id,revision,lot_id,payload,digest,adjusts) VALUES(?,?,?,?,?,?)",
                [.text(row.id.uuidString), .integer(row.revision), row.lotID.map { .text($0.uuidString) } ?? .null,
                 .blob(row.payload), .blob(inventoryDigest(row.payload)), row.adjustsPriceID.map { .text($0.uuidString) } ?? .null])
    }
}
