import Foundation
import SQLite3
import CoreDomain
import RecordArchive

/// Disposable verification index owned by the archive worker. Never a physical
/// pantry database or a source of permissions. History payloads stay on disk.
final class PantryArchiveIndex {
    enum Failure: Error { case invalid, database(Int32) }
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else { throw Failure.database(status) }
        do {
            // Setting journal_mode returns the effective mode as a result row.
            let mode = try statement("PRAGMA journal_mode=DELETE")
            let selected = sqlite3_step(mode) == SQLITE_ROW && sqlite3_column_text(mode, 0).map { String(cString: $0) } == "delete"
            let completed = sqlite3_step(mode)
            sqlite3_finalize(mode)
            guard selected, completed == SQLITE_DONE else { throw Failure.invalid }
            // Every ordered scan below has a covering order index; no unbounded
            // history sort or plaintext temporary file is needed outside this protected directory.
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA cache_size=-2048")
            try execute("CREATE TABLE items (kind TEXT NOT NULL,id TEXT NOT NULL,lot TEXT,revision INTEGER,payload BLOB NOT NULL,ordinal INTEGER NOT NULL,PRIMARY KEY(kind,id))")
            try execute("CREATE INDEX item_ordinal ON items(ordinal)")
            try execute("CREATE INDEX item_kind_ordinal ON items(kind,ordinal)")
            try execute("CREATE INDEX item_lot_revision ON items(kind,lot,revision,id)")
            try execute("CREATE UNIQUE INDEX event_revision ON items(lot,revision) WHERE kind='event'")
            try execute("CREATE TABLE baselines (lot TEXT NOT NULL,payload BLOB NOT NULL)")
            try execute("CREATE INDEX baseline_lot ON baselines(lot)")
            try execute("CREATE TABLE evidence (ordinal INTEGER PRIMARY KEY,payload BLOB NOT NULL)")
            try execute("CREATE TABLE metadata (kind TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(kind,id))")
            try execute("BEGIN IMMEDIATE")
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { if let database { sqlite3_close(database) } }
    func close() throws {
        guard let database else { return }
        try execute("COMMIT")
        let status = sqlite3_close(database); guard status == SQLITE_OK else { throw Failure.database(status) }
        self.database = nil
    }
    private func statement(_ sql: String, texts: [String] = [], data: Data? = nil) throws -> OpaquePointer {
        guard let database else { throw Failure.invalid }
        var result: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &result, nil)
        guard status == SQLITE_OK, let result else { throw Failure.database(status) }
        do {
            for (offset, value) in texts.enumerated() {
                guard sqlite3_bind_text(result, Int32(offset + 1), value, -1, transient) == SQLITE_OK else { throw Failure.invalid }
            }
            if let data {
                let bound = data.withUnsafeBytes { sqlite3_bind_blob(result, Int32(texts.count + 1), $0.baseAddress, Int32($0.count), transient) }
                guard bound == SQLITE_OK else { throw Failure.invalid }
            }
            return result
        } catch { sqlite3_finalize(result); throw error }
    }
    private func execute(_ sql: String, texts: [String] = [], data: Data? = nil) throws {
        let row = try statement(sql, texts: texts, data: data); defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row); guard status == SQLITE_DONE else { throw Failure.database(status) }
    }
    private func blob(_ row: OpaquePointer, _ column: Int32 = 0) throws -> Data {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, count <= PantryArchiveCodec.maximumChunkBytes,
              let bytes = sqlite3_column_blob(row, column) else { throw Failure.invalid }
        return Data(bytes: bytes, count: count)
    }
    func count(_ kind: String) throws -> Int {
        let row = try statement("SELECT count(*) FROM items WHERE kind=?", texts: [kind]); defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw Failure.invalid }
        return Int(sqlite3_column_int64(row, 0))
    }
    func append(_ item: PantryArchiveCodec.Item, ordinal: Int, at date: Date) throws {
        let bytes = try ArchiveCodec.canonical(item)
        guard bytes.count <= PantryArchiveCodec.maximumChunkBytes - 2048 else { throw PantryArchiveCodec.Failure.capacity }
        let kind: String, id: String, lot: String, revision: Int64
        switch item {
        case .lot(let value):
            try value.validate(); kind = "lot"; id = value.id.uuidString; lot = id; revision = value.revision
        case .observation(let value):
            try value.validate(); kind = "observation"; id = value.id.uuidString; lot = value.lotID.uuidString; revision = value.revision
        case .event(let value):
            try PantryArchiveCodec.validateEventShape(value); kind = "event"; id = value.id.uuidString; lot = value.lotID.uuidString; revision = value.revision
        case .reservation(let value):
            try value.validate(); kind = "reservation"; id = value.id.uuidString; lot = value.lotID?.uuidString ?? ""; revision = value.revision
        case .sourceLink(let value):
            try value.source.validate(); kind = "sourceLink"; id = value.lotID.uuidString; lot = id; revision = 1
        case .historical(let value):
            try PantryArchiveCodec.validateHistory(value, at: date)
            kind = "history"; id = ArchiveCodec.digest(bytes); lot = ""; revision = 0
            switch value {
            case .originalLot(let original) where original.revision == 1:
                try execute("INSERT INTO baselines(lot,payload) VALUES (?,?)", texts: [original.id.uuidString], data: ArchiveCodec.canonical(original))
            case .migration(let envelope):
                if case let .originalLot(original, baselineID) = envelope.body {
                    let baseline = InventoryLot(id: original.id, foodID: original.foodID, name: original.name, source: original.source,
                        revision: 1, location: original.location, openedAt: original.openedAt, unit: original.unit, count: original.count,
                        observationID: baselineID, confirmedAt: original.confirmedAt, updatedAt: original.updatedAt, useFirst: original.useFirst)
                    try execute("INSERT INTO baselines(lot,payload) VALUES (?,?)", texts: [original.id.uuidString], data: ArchiveCodec.canonical(baseline))
                }
            default: break
            }
        }
        try execute("INSERT INTO items(kind,id,lot,revision,ordinal,payload) VALUES (?,?,?,?,?,?)",
            texts: [kind,id,lot,String(revision),String(ordinal)], data: bytes)
    }
    func containsHistory(_ item: PantryArchiveCodec.Item) throws -> Bool {
        try self.item(kind: "history", id: ArchiveCodec.digest(ArchiveCodec.canonical(item))) != nil
    }
    func item(kind: String, id: String) throws -> PantryArchiveCodec.Item? {
        let row = try statement("SELECT payload FROM items WHERE kind=? AND id=?", texts: [kind,id]); defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw Failure.database(status) }
        return try JSONDecoder().decode(PantryArchiveCodec.Item.self, from: blob(row))
    }
    func forEach(kind: String? = nil, lot: UUID? = nil, _ body: (PantryArchiveCodec.Item) throws -> Void) throws {
        var sql = "SELECT payload FROM items", terms: [String] = [], texts: [String] = []
        if let kind { terms.append("kind=?"); texts.append(kind) }
        if let lot { terms.append("lot=?"); texts.append(lot.uuidString) }
        if !terms.isEmpty { sql += " WHERE " + terms.joined(separator: " AND ") }
        sql += lot == nil ? " ORDER BY ordinal" : " ORDER BY revision,id"
        let row = try statement(sql, texts: texts); defer { sqlite3_finalize(row) }
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(row)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Failure.database(status) }
            try body(JSONDecoder().decode(PantryArchiveCodec.Item.self, from: blob(row)))
        }
    }
    private func baseline(for lot: InventoryLot) throws -> InventoryLot? {
        let row = try statement("SELECT payload FROM baselines WHERE lot=?", texts: [lot.id.uuidString]); defer { sqlite3_finalize(row) }
        var found: InventoryLot?
        while true {
            let status = sqlite3_step(row)
            if status == SQLITE_DONE { return found }
            guard status == SQLITE_ROW else { throw Failure.database(status) }
            let value = try JSONDecoder().decode(InventoryLot.self, from: blob(row))
            if value.source != lot.source { continue }
            if let found, found != value { throw Failure.invalid }
            found = value
        }
    }
    private func observation(_ id: UUID) throws -> InventoryObservation? {
        guard let value = try item(kind: "observation", id: id.uuidString) else { return nil }
        guard case .observation(let result) = value else { throw Failure.invalid }; return result
    }
    func validate(descriptor: PantryArchiveCodec.Descriptor) throws {
        try PantryArchiveCodec.validateDescriptor(descriptor)
        guard try count("lot") <= InventoryProjection.maximumLots,
              try count("reservation") <= InventoryProjection.maximumReservations,
              try count("lot") == count("sourceLink") else { throw PantryArchiveCodec.Failure.capacity }
        // Constant-memory foreign-key/uniqueness checks include facts which no live lot visits.
        let row = try statement("SELECT count(*) FROM items c LEFT JOIN items l ON l.kind='lot' AND l.id=c.lot WHERE c.kind IN ('observation','event','sourceLink') AND l.id IS NULL")
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW, sqlite3_column_int64(row, 0) == 0 else { throw Failure.invalid }
        var lots: [InventoryLot] = [], claims: [InventoryReservation] = []
        try forEach(kind: "lot") { item in
            guard case .lot(let lot) = item, lot.source.originID == descriptor.originID,
                  lot.revision <= descriptor.inventoryRevision, lot.updatedAt <= descriptor.capturedAt,
                  case .sourceLink(let link)? = try self.item(kind: "sourceLink", id: lot.id.uuidString), link.source == lot.source else { throw Failure.invalid }
            var previous: InventoryObservation?
            try self.forEach(kind: "observation", lot: lot.id) { item in
                guard case .observation(let value) = item, value.revision <= lot.revision,
                      value.supersedesID == previous?.id, value.observedAt <= lot.updatedAt,
                      previous.map({ $0.revision < value.revision && $0.observedAt <= value.observedAt }) ?? true else { throw Failure.invalid }
                previous = value
            }
            guard let latest = previous, latest.id == lot.observationID, latest.count == lot.count,
                  latest.observedAt == lot.confirmedAt else { throw Failure.invalid }
            var current: InventoryLot?, initialized = false
            try self.forEach(kind: "event", lot: lot.id) { item in
                guard case .event(let event) = item, event.originID == descriptor.originID,
                      event.revision <= lot.revision, event.occurredAt <= lot.updatedAt else { throw Failure.invalid }
                if !initialized {
                    if event.revision != 1 { current = try self.initial(lot) }
                    initialized = true
                }
                var observed: [UUID: InventoryObservation] = [:]
                let id: UUID?
                switch event.change {
                case .create(_, let value), .count(_, let value), .usedUp(let value): id = value
                case .revise(let value): id = value.observation?.observationID
                default: id = nil
                }
                if let id, let value = try self.observation(id) { observed[id] = value }
                try PantryArchiveCodec.validateEvent(event, observations: observed)
                let command = InventoryCommand(id: event.operationID, originID: event.originID, lotID: event.lotID,
                    eventID: event.id, expectedRevision: current?.revision, occurredAt: event.occurredAt, change: event.change)
                let prepared = try InventoryEngine.prepare(command, current: current, at: descriptor.capturedAt)
                guard prepared.event == event else { throw Failure.invalid }
                if let value = prepared.observation { guard observed[value.id] == value else { throw Failure.invalid } }
                current = prepared.lot
            }
            if !initialized { current = try self.initial(lot) }
            guard current == lot else { throw Failure.invalid }
            lots.append(lot)
        }
        try forEach(kind: "reservation") { item in
            guard case .reservation(let claim) = item, claim.originID == descriptor.originID,
                  claim.revision <= descriptor.inventoryRevision else { throw Failure.invalid }
            if let id = claim.lotID {
                guard case .lot(let lot)? = try self.item(kind: "lot", id: id.uuidString), lot.foodID == claim.foodID else { throw Failure.invalid }
            }
            claims.append(claim)
        }
        // Only the explicitly domain-bounded live head projection is materialized;
        // observation/event/provenance history never joins these arrays.
        _ = try InventoryProjection.build(originID: descriptor.originID, lots: lots, reservations: claims, at: descriptor.capturedAt)
    }
    private func initial(_ lot: InventoryLot) throws -> InventoryLot {
        let candidate: InventoryLot? = try (lot.revision == 1 ? lot : baseline(for: lot))
        guard let value = candidate, let first = try observation(value.observationID), first.lotID == lot.id,
              first.revision == 1, first.supersedesID == nil, first.count == value.count,
              first.observedAt == value.confirmedAt else { throw Failure.invalid }
        return value
    }
    func putMetadata(kind: String, id: String, bytes: Data) throws {
        try execute("INSERT INTO metadata(kind,id,payload) VALUES (?,?,?)", texts: [kind,id], data: bytes)
    }
    func metadata(kind: String, id: String) throws -> Data? {
        let row = try statement("SELECT payload FROM metadata WHERE kind=? AND id=?", texts: [kind,id]); defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row); if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw Failure.database(status) }; return try blob(row)
    }
    func forEachMetadata(kind: String, after: String? = nil, limit: Int? = nil, _ body: (String, Data) throws -> Void) throws {
        guard limit.map({ (1...200).contains($0) }) ?? true else { throw Failure.invalid }
        let sql = "SELECT id,payload FROM metadata WHERE kind=?" + (after == nil ? "" : " AND id>?") + " ORDER BY id" + (limit.map { " LIMIT \($0)" } ?? "")
        let row = try statement(sql, texts: [kind] + (after.map { [$0] } ?? [])); defer { sqlite3_finalize(row) }
        while true {
            let status = sqlite3_step(row); if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW, let raw = sqlite3_column_text(row, 0) else { throw Failure.database(status) }
            try body(String(cString: raw), blob(row, 1))
        }
    }
    func appendEvidence(_ bytes: Data, ordinal: Int) throws {
        guard bytes.count <= PantryArchiveCodec.maximumChunkBytes else { throw Failure.invalid }
        try execute("INSERT INTO evidence(ordinal,payload) VALUES (?,?)", texts: [String(ordinal)], data: bytes)
    }
    func forEachEvidence(_ body: (Data) throws -> Void) throws {
        let row = try statement("SELECT payload FROM evidence ORDER BY ordinal"); defer { sqlite3_finalize(row) }
        while true {
            let status = sqlite3_step(row); if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw Failure.database(status) }
            try body(blob(row))
        }
    }
}
