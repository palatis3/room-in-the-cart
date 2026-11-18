import CSQLite
import Foundation

/// Device-local recognition metadata. The hashes include the authorized persona and inventory origin.
/// A binding always points to an immutable first revision, so lot/receipt erasure removes it.
public struct InventoryReceiptBinding: Codable, Sendable, Equatable {
    public let owner, merchantDay, wording, document, sourceID, receiptID, lotID: UUID
    public let ordinal: Int
    public let fileDigest: String?
    public let additionalDocument: Bool
    public init(owner: UUID, merchantDay: UUID, wording: UUID, document: UUID, ordinal: Int,
                sourceID: UUID, receiptID: UUID, lotID: UUID, fileDigest: String? = nil, additionalDocument: Bool = false) {
        self.additionalDocument = additionalDocument
        self.fileDigest = fileDigest
        self.owner = owner; self.merchantDay = merchantDay; self.wording = wording; self.document = document
        self.ordinal = ordinal; self.sourceID = sourceID; self.receiptID = receiptID; self.lotID = lotID
    }
}

extension ComparisonStore {
    public func rescanCandidates(owner: UUID, merchantDay: UUID, wording: [UUID]) throws -> [UUID] {
        try database.requireInventoryOriginLive()
        guard !wording.isEmpty, wording.count <= 50 else { throw ComparisonStoreError.invalidInput }
        let marks = Array(repeating: "?", count: wording.count).joined(separator: ",")
        let query = try database.statement("""
            SELECT DISTINCT receipt FROM receipt_recognition WHERE owner=? AND merchant_day=? AND wording IN (\(marks))
            ORDER BY receipt LIMIT 9
            """, values: [.text(owner.uuidString), .text(merchantDay.uuidString)] + wording.map { .text($0.uuidString) })
        defer { sqlite3_finalize(query) }
        var ids: [UUID] = []
        while true {
            switch sqlite3_step(query) {
            case SQLITE_DONE: return ids
            case SQLITE_ROW:
                guard let id = try UUID(uuidString: database.text(query, column: 0)) else { throw ComparisonStoreError.corruptRecord }
                ids.append(id)
            default: throw ComparisonStoreError.corruptRecord
            }
        }
    }

    public func rescanBindings(owner: UUID, receipt: UUID? = nil, document: UUID? = nil) throws -> [InventoryReceiptBinding] {
        try database.requireInventoryOriginLive()
        guard (receipt == nil) != (document == nil), let id = receipt ?? document else { throw ComparisonStoreError.invalidInput }
        let field = receipt != nil ? "receipt" : "document"
        let query = try database.statement("""
            SELECT merchant_day,wording,document,ordinal,source,receipt,lot,file_digest,additional_document FROM receipt_recognition
            WHERE owner=? AND \(field)=? ORDER BY source,document,ordinal LIMIT 401
            """, values: [.text(owner.uuidString), .text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        var bindings: [InventoryReceiptBinding] = []
        while true {
            switch sqlite3_step(query) {
            case SQLITE_DONE: return bindings
            case SQLITE_ROW:
                guard bindings.count < 400 else { throw ComparisonStoreError.payloadTooLarge }
                func uuid(_ column: Int32) throws -> UUID {
                    guard let value = try UUID(uuidString: database.text(query, column: column)) else { throw ComparisonStoreError.corruptRecord }
                    return value
                }
                bindings.append(try .init(owner: owner, merchantDay: uuid(0), wording: uuid(1), document: uuid(2),
                    ordinal: Int(sqlite3_column_int64(query, 3)), sourceID: uuid(4), receiptID: uuid(5), lotID: uuid(6),
                    fileDigest: sqlite3_column_type(query, 7) == SQLITE_NULL ? nil : database.text(query, column: 7),
                    additionalDocument: sqlite3_column_int(query, 8) == 1))
            default: throw ComparisonStoreError.corruptRecord
            }
        }
    }

    public func checkRescanLines(owner: UUID, document: UUID, ordinals: [Int]) throws {
        try database.requireInventoryOriginLive()
        guard (1...50).contains(ordinals.count) else { throw ComparisonStoreError.invalidInput }
        let marks = Array(repeating: "?", count: ordinals.count).joined(separator: ",")
        let query = try database.statement("SELECT 1 FROM retired_receipt_recognition WHERE owner=? AND document=? AND ordinal IN (\(marks)) LIMIT 1",
            values: [.text(owner.uuidString), .text(document.uuidString)] + ordinals.map { .integer(Int64($0)) })
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw ComparisonStoreError.invalidInput }
    }

    public func rescanDocumentDigests(for lotIDs: [UUID]) throws -> Set<String> {
        try database.requireInventoryOriginLive()
        guard (1...InventoryPersistenceLimits.pageItems).contains(lotIDs.count) else { throw ComparisonStoreError.invalidInput }
        let marks = Array(repeating: "?", count: lotIDs.count).joined(separator: ",")
        let query = try database.statement("SELECT DISTINCT file_digest FROM receipt_recognition WHERE lot IN (\(marks)) AND file_digest IS NOT NULL",
            values: lotIDs.map { .text($0.uuidString) })
        defer { sqlite3_finalize(query) }
        var values = Set<String>()
        while true {
            switch sqlite3_step(query) {
            case SQLITE_DONE: return values
            case SQLITE_ROW: values.insert(try database.text(query, column: 0))
            default: throw ComparisonStoreError.corruptRecord
            }
        }
    }

    public func checkReceiptOwner(_ owner: UUID, receipt: UUID, fileDigest: String? = nil) throws {
        try database.requireInventoryOriginLive()
        let query = try database.statement("SELECT 1 FROM receipt_recognition WHERE (receipt=? OR file_digest=?) AND owner<>? LIMIT 1",
            values: [.text(receipt.uuidString), fileDigest.map(ComparisonSQLValue.text) ?? .null, .text(owner.uuidString)])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw ComparisonStoreError.invalidInput }
    }
}

extension ComparisonDatabase {
    func installReceiptRecognition() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS receipt_recognition(
                owner TEXT NOT NULL, merchant_day TEXT NOT NULL, wording TEXT NOT NULL,
                document TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 3999),
                source TEXT NOT NULL REFERENCES inventory_acquisitions(id) ON DELETE CASCADE,
                receipt TEXT NOT NULL, lot TEXT NOT NULL, file_digest TEXT, additional_document INTEGER NOT NULL CHECK(additional_document IN (0,1)), PRIMARY KEY(owner,document,ordinal));
            CREATE INDEX IF NOT EXISTS receipt_recognition_search ON receipt_recognition(owner,merchant_day,wording,receipt);
            CREATE INDEX IF NOT EXISTS receipt_recognition_original ON receipt_recognition(receipt,owner,source);
            CREATE TABLE IF NOT EXISTS retired_receipt_recognition(
                owner TEXT NOT NULL, document TEXT NOT NULL, ordinal INTEGER NOT NULL, PRIMARY KEY(owner,document,ordinal));
            CREATE TRIGGER IF NOT EXISTS retire_receipt_recognition BEFORE DELETE ON receipt_recognition
                BEGIN INSERT OR IGNORE INTO retired_receipt_recognition VALUES (OLD.owner,OLD.document,OLD.ordinal); END;
            CREATE TRIGGER IF NOT EXISTS prohibit_retired_receipt_recognition BEFORE INSERT ON receipt_recognition
                WHEN EXISTS(SELECT 1 FROM retired_receipt_recognition WHERE owner=NEW.owner AND document=NEW.document AND ordinal=NEW.ordinal)
                BEGIN SELECT RAISE(ABORT,'receipt line previously erased'); END;
            CREATE INDEX IF NOT EXISTS receipt_recognition_file ON receipt_recognition(file_digest,owner);
            CREATE INDEX IF NOT EXISTS receipt_recognition_lot ON receipt_recognition(lot);
            CREATE INDEX IF NOT EXISTS receipt_recognition_source ON receipt_recognition(source);
            """)
    }

    func bindReceipt(_ value: InventoryReceiptBinding) throws {
        try run("""
            INSERT INTO receipt_recognition(owner,merchant_day,wording,document,ordinal,source,receipt,lot,file_digest,additional_document)
            SELECT ?,?,?,?,?,a.id,a.receipt_id,a.lot_id,?,? FROM inventory_acquisitions a
            WHERE a.id=? AND a.receipt_id=? AND a.lot_id=? AND a.revision=1
            AND NOT EXISTS(SELECT 1 FROM receipt_recognition WHERE (receipt=a.receipt_id OR file_digest=?) AND owner<>?)
            AND NOT EXISTS(SELECT 1 FROM receipt_recognition WHERE owner=? AND document=? AND receipt<>a.receipt_id)
            """, [.text(value.owner.uuidString), .text(value.merchantDay.uuidString), .text(value.wording.uuidString),
                  .text(value.document.uuidString), .integer(Int64(value.ordinal)), value.fileDigest.map(ComparisonSQLValue.text) ?? .null, .integer(value.additionalDocument ? 1 : 0), .text(value.sourceID.uuidString),
                  .text(value.receiptID.uuidString), .text(value.lotID.uuidString), value.fileDigest.map(ComparisonSQLValue.text) ?? .null, .text(value.owner.uuidString),
                  .text(value.owner.uuidString), .text(value.document.uuidString)])
        guard try integer("SELECT changes()") == 1 else { throw ComparisonStoreError.invalidInput }
    }
}
