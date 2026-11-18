import CSQLite
import Foundation

public struct InventoryReceiptAlias: Codable, Equatable, Identifiable, Sendable {
    public static let maximumPerPersona = 200
    public let id: UUID
    public let personaID: UUID
    public let merchant: String
    public let language: String
    public let wording: String
    public let product: String
    public let foodID: UUID
    public let sourceID: UUID
    public let lotID: UUID

    public init(id: UUID = UUID(), personaID: UUID, merchant: String, language: String, wording: String,
                product: String, foodID: UUID, sourceID: UUID, lotID: UUID) {
        self.id = id; self.personaID = personaID; self.merchant = merchant; self.language = language
        self.wording = wording; self.product = product; self.foodID = foodID; self.sourceID = sourceID; self.lotID = lotID
    }

    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    func validate() throws {
        guard ["en", "es"].contains(language) else { throw ComparisonStoreError.invalidInput }
        for (text, limit) in [(merchant, 256), (wording, 128), (product, 512)] {
            guard !Self.key(text).isEmpty, text.utf8.count <= limit,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ComparisonStoreError.invalidInput }
        }
    }
}

public enum InventoryReceiptAliasEdit: Codable, Equatable, Sendable {
    case remember(InventoryReceiptAlias)
    case forget(personaID: UUID, ids: [UUID])

    var removesSpellings: Bool {
        if case .forget = self { return true }
        return false
    }

    func validate() throws {
        switch self {
        case .remember(let alias): try alias.validate()
        case .forget(_, let ids):
            guard !ids.isEmpty, ids.count <= InventoryReceiptAlias.maximumPerPersona,
                  Set(ids).count == ids.count else { throw ComparisonStoreError.invalidInput }
        }
    }
}

extension ComparisonStore {
    public func receiptAliases(personaID: UUID, merchant: String? = nil, language: String? = nil) throws -> [InventoryReceiptAlias] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        var query = "SELECT id,source_id,payload,digest,merchant,language,wording FROM inventory_receipt_aliases WHERE persona=?"
        var args: [ComparisonSQLValue] = [.text(personaID.uuidString)]
        if let merchant { query += " AND merchant=?"; args.append(.text(InventoryReceiptAlias.key(merchant))) }
        if let language { query += " AND language=?"; args.append(.text(language)) }
        query += " ORDER BY merchant,language,wording LIMIT 201"
        let cursor = try database.statement(query, values: args)
        defer { sqlite3_finalize(cursor) }
        var result: [InventoryReceiptAlias] = []
        while true {
            let status = sqlite3_step(cursor)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, result.count < InventoryReceiptAlias.maximumPerPersona else { throw ComparisonStoreError.corruptRecord }
            let bytes = try database.inventoryBlob(cursor, column: 2, maximum: 4096)
            let alias = try JSONDecoder().decode(InventoryReceiptAlias.self, from: bytes)
            try alias.validate()
            guard try inventoryDigest(bytes) == database.inventoryBlob(cursor, column: 3, maximum: 32),
                  try database.text(cursor, column: 0) == alias.id.uuidString,
                  try database.text(cursor, column: 1) == alias.sourceID.uuidString,
                  alias.personaID == personaID,
                  try database.text(cursor, column: 4) == InventoryReceiptAlias.key(alias.merchant),
                  try database.text(cursor, column: 5) == alias.language,
                  try database.text(cursor, column: 6) == InventoryReceiptAlias.key(alias.wording) else { throw ComparisonStoreError.corruptRecord }
            result.append(alias)
        }
    }

    public func receiptAliasCount(lotIDs: Set<UUID>? = nil) throws -> Int {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        guard let lotIDs else { return Int(try database.integer("SELECT count(*) FROM inventory_receipt_aliases")) }
        let ids = Array(lotIDs)
        var count = 0
        for offset in stride(from: 0, to: ids.count, by: 200) {
            let page = ids[offset..<min(ids.count, offset + 200)]
            let slots = Array(repeating: "?", count: page.count).joined(separator: ",")
            let query = """
                SELECT count(*) FROM inventory_acquisitions a JOIN inventory_receipt_aliases r ON r.source_id=a.id
                WHERE a.lot_id IN (\(slots))
                """
            let cursor = try database.statement(query, values: page.map { .text($0.uuidString) })
            defer { sqlite3_finalize(cursor) }
            guard sqlite3_step(cursor) == SQLITE_ROW else { throw ComparisonStoreError.corruptRecord }
            count += Int(sqlite3_column_int64(cursor, 0))
        }
        return count
    }
}

extension ComparisonDatabase {
    func migrateReceiptAliases() throws {
        try transaction {
            let version = try integer("PRAGMA user_version")
            if (6...7).contains(version) { try validateReceiptAliases(); return }
            guard version == 5 else { throw ComparisonStoreError.unsupportedSchema(version) }
            try execute("""
                CREATE TABLE inventory_receipt_aliases (
                    id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
                    persona TEXT NOT NULL CHECK(length(persona)=36),
                    merchant TEXT NOT NULL, language TEXT NOT NULL CHECK(language IN ('en','es')),
                    wording TEXT NOT NULL, source_id TEXT NOT NULL REFERENCES inventory_acquisitions(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 4096),
                    digest BLOB NOT NULL CHECK(typeof(digest)='blob' AND length(digest)=32),
                    UNIQUE(persona,merchant,language,wording)
                );
                CREATE INDEX inventory_alias_source ON inventory_receipt_aliases(source_id);
                CREATE TRIGGER inventory_alias_immutable BEFORE UPDATE ON inventory_receipt_aliases
                    BEGIN SELECT RAISE(ABORT,'immutable receipt alias'); END;
                PRAGMA user_version=6;
                """)
            try validateReceiptAliases()
        }
    }

    func validateReceiptAliases() throws {
        guard try integer("""
            SELECT count(*) FROM sqlite_master WHERE (type='table' AND name='inventory_receipt_aliases')
               OR (type='index' AND name='inventory_alias_source') OR (type='trigger' AND name='inventory_alias_immutable')
            """) == 3 else { throw ComparisonStoreError.corruptRecord }
    }

    func applyReceiptAlias(_ edit: InventoryReceiptAliasEdit) throws {
        switch edit {
        case .remember(let alias):
            guard try integer("SELECT count(*) FROM inventory_receipt_aliases WHERE persona='\(alias.personaID.uuidString)'") < Int64(InventoryReceiptAlias.maximumPerPersona) else {
                throw ComparisonStoreError.payloadTooLarge
            }
            let source = try statement("SELECT lot_id FROM inventory_acquisitions WHERE id=? AND revision=1", values: [.text(alias.sourceID.uuidString)])
            defer { sqlite3_finalize(source) }
            guard sqlite3_step(source) == SQLITE_ROW, try text(source, column: 0) == alias.lotID.uuidString else { throw ComparisonStoreError.staleInventory }
            let bytes = try inventoryCanonical(alias)
            try run("INSERT INTO inventory_receipt_aliases (id,persona,merchant,language,wording,source_id,payload,digest) VALUES(?,?,?,?,?,?,?,?)",
                    [.text(alias.id.uuidString), .text(alias.personaID.uuidString), .text(InventoryReceiptAlias.key(alias.merchant)),
                     .text(alias.language), .text(InventoryReceiptAlias.key(alias.wording)), .text(alias.sourceID.uuidString),
                     .blob(bytes), .blob(inventoryDigest(bytes))])
        case .forget(let persona, let ids):
            for id in ids {
                try run("DELETE FROM inventory_receipt_aliases WHERE id=? AND persona=?", [.text(id.uuidString), .text(persona.uuidString)])
                guard try integer("SELECT changes()") == 1 else { throw ComparisonStoreError.staleInventory }
            }
        }
    }
}
