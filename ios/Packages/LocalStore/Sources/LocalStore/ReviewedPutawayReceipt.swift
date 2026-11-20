import CSQLite
import Foundation

public struct ReviewedReceiptHeader: Equatable, Codable, Identifiable, Sendable {
    public let id: UUID
    public let owner: UUID
    public let merchant: String
    public let date: Date
    public let totalMinor: Int64?
    public let reference: String?

    public init(id: UUID, owner: UUID, merchant: String, date: Date, totalMinor: Int64?, reference: String? = nil) {
        self.id = id
        self.owner = owner
        self.merchant = merchant
        self.date = date
        self.totalMinor = totalMinor
        self.reference = reference
    }
}

public struct ReviewedReceiptDecision: Equatable, Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case stored, keptSome, eaten, missing, chargeOrReturn, linked }
    public let id: UUID
    public let ordinal: Int
    public let original: String
    public let name: String
    public let kind: Kind
    public let lotID: UUID?
    public let paidMinor: Int64?

    public init(id: UUID, ordinal: Int, original: String, name: String, kind: Kind, lotID: UUID?, paidMinor: Int64?) {
        self.id = id
        self.ordinal = ordinal
        self.original = original
        self.name = name
        self.kind = kind
        self.lotID = lotID
        self.paidMinor = paidMinor
    }
}

public struct ReviewedPutawayReceipt: Equatable, Codable, Sendable {
    public let header: ReviewedReceiptHeader
    public let decisions: [ReviewedReceiptDecision]
    public let identities: [UUID]
    public let layout: UUID?
    public let ordinals: [Int]?

    public init(header: ReviewedReceiptHeader, decisions: [ReviewedReceiptDecision], identities: [UUID], layout: UUID? = nil, ordinals: [Int]? = nil) {
        self.header = header
        self.decisions = decisions
        self.identities = identities
        self.layout = layout
        self.ordinals = ordinals
    }

    func validate() throws {
        let validText: (String, Int) -> Bool = { text, bytes in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= bytes && !text.contains("\0")
        }
        guard (layout == nil) == (ordinals == nil),
              ordinals.map({ $0.count == decisions.count && Set($0).count == $0.count && $0.allSatisfy { (0..<4000).contains($0) } }) ?? true,
              validText(header.merchant, 256), header.date.timeIntervalSinceReferenceDate.isFinite,
              header.totalMinor.map({ $0 >= 0 }) ?? true, header.reference.map({ validText($0, 256) }) ?? true, (1...50).contains(decisions.count),
              identities.count <= 2, Set(decisions.map(\.id)).count == decisions.count,
              decisions.allSatisfy({ line in
                  (0..<4000).contains(line.ordinal) && validText(line.original, 2048) && validText(line.name, 2048)
                  && ([.stored, .keptSome, .linked].contains(line.kind) == (line.lotID != nil))
                  && (line.kind == .chargeOrReturn || (line.paidMinor ?? 0) >= 0)
              }) else { throw ComparisonStoreError.invalidInput }
    }
}

extension ComparisonDatabase {
    func installReviewedPutawayReceipts() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS putaway_receipts(
                id TEXT PRIMARY KEY NOT NULL, owner TEXT NOT NULL, header BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS putaway_receipts_owner ON putaway_receipts(owner,id);
            CREATE TABLE IF NOT EXISTS putaway_receipt_lines(
                id TEXT PRIMARY KEY NOT NULL, receipt TEXT NOT NULL REFERENCES putaway_receipts(id) ON DELETE CASCADE,
                body BLOB NOT NULL, lot TEXT, acquisition TEXT REFERENCES inventory_acquisitions(id) ON DELETE CASCADE);
            CREATE INDEX IF NOT EXISTS putaway_receipt_lines_receipt ON putaway_receipt_lines(receipt,id);
            CREATE TABLE IF NOT EXISTS putaway_receipt_coordinates(
                receipt TEXT NOT NULL, layout TEXT NOT NULL, ordinal INTEGER NOT NULL, line TEXT NOT NULL
                    REFERENCES putaway_receipt_lines(id) ON DELETE CASCADE, PRIMARY KEY(receipt,layout,ordinal));
            CREATE TRIGGER IF NOT EXISTS retire_putaway_receipts AFTER INSERT ON inventory_origin_retirement
                BEGIN DELETE FROM putaway_receipts; END;
            CREATE TRIGGER IF NOT EXISTS prune_putaway_receipts AFTER DELETE ON putaway_receipt_lines
                WHEN NOT EXISTS (SELECT 1 FROM putaway_receipt_lines WHERE receipt=OLD.receipt)
                BEGIN DELETE FROM putaway_receipts WHERE id=OLD.receipt; END;
            """)
    }

    func savePutaway(_ review: ReviewedPutawayReceipt) throws {
        let header = review.header
        if let prior = try putawayHeader(header.id) {
            guard prior.owner == header.owner, prior.date == header.date, prior.merchant == header.merchant,
                  prior.reference == nil || prior.reference == header.reference,
                  prior.totalMinor == nil || prior.totalMinor == header.totalMinor else { throw ComparisonStoreError.operationConflict }
        }
        try run("INSERT INTO putaway_receipts(id,owner,header) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET header=excluded.header",
                [.text(header.id.uuidString), .text(header.owner.uuidString), .blob(try inventoryCanonical(header))])
        for identity in review.identities { try indexReceiptIdentity(identity, receiptID: header.id) }
        for line in review.decisions {
            let body = try inventoryCanonical(line)
            let retired = try statement("SELECT 1 FROM inventory_retired_acquisition_lines WHERE line_id=?", values: [.text(line.id.uuidString)])
            defer { sqlite3_finalize(retired) }
            guard sqlite3_step(retired) == SQLITE_DONE else { throw ComparisonStoreError.erased }
            let old = try statement("SELECT receipt,body FROM putaway_receipt_lines WHERE id=?", values: [.text(line.id.uuidString)])
            defer { sqlite3_finalize(old) }
            switch sqlite3_step(old) {
            case SQLITE_ROW:
                guard try text(old, column: 0) == header.id.uuidString,
                      try inventoryBlob(old, column: 1, maximum: 8192) == body else { throw ComparisonStoreError.operationConflict }
                continue
            case SQLITE_DONE: break
            default: throw ComparisonStoreError.corruptRecord
            }
            let acquisition = try statement("SELECT id,lot_id FROM inventory_acquisitions WHERE receipt_id=? AND line_id=? AND revision=1",
                                           values: [.text(header.id.uuidString), .text(line.id.uuidString)])
            defer { sqlite3_finalize(acquisition) }
            let source: ComparisonSQLValue
            switch sqlite3_step(acquisition) {
            case SQLITE_ROW:
                guard let lotID = line.lotID, try text(acquisition, column: 1) == lotID.uuidString else { throw ComparisonStoreError.operationConflict }
                source = .text(try text(acquisition, column: 0))
            case SQLITE_DONE:
                guard line.lotID == nil else { throw ComparisonStoreError.operationConflict }
                source = .null
            default: throw ComparisonStoreError.corruptRecord
            }
            try run("INSERT INTO putaway_receipt_lines(id,receipt,body,lot,acquisition) VALUES(?,?,?,?,?)",
                    [.text(line.id.uuidString), .text(header.id.uuidString), .blob(body), line.lotID.map { .text($0.uuidString) } ?? .null, source])
        }
        if let layout = review.layout, let ordinals = review.ordinals {
            for (ordinal, line) in zip(ordinals, review.decisions) {
                let key: [ComparisonSQLValue] = [.text(header.id.uuidString), .text(layout.uuidString), .integer(Int64(ordinal))]
                try run("INSERT OR IGNORE INTO putaway_receipt_coordinates(receipt,layout,ordinal,line) VALUES(?,?,?,?)",
                        key + [.text(line.id.uuidString)])
                let row = try statement("SELECT line FROM putaway_receipt_coordinates WHERE receipt=? AND layout=? AND ordinal=?", values: key)
                defer { sqlite3_finalize(row) }
                guard sqlite3_step(row) == SQLITE_ROW, try text(row, column: 0) == line.id.uuidString else { throw ComparisonStoreError.operationConflict }
            }
        }
    }

    func putawayHeader(_ id: UUID) throws -> ReviewedReceiptHeader? {
        let row = try statement("SELECT header FROM putaway_receipts WHERE id=?", values: [.text(id.uuidString)])
        defer { sqlite3_finalize(row) }
        switch sqlite3_step(row) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: return try JSONDecoder().decode(ReviewedReceiptHeader.self, from: inventoryBlob(row, column: 0, maximum: 2048))
        default: throw ComparisonStoreError.corruptRecord
        }
    }
}

extension ComparisonStore {
    public func reviewedReceiptHeader(_ id: UUID, owner: UUID) throws -> ReviewedReceiptHeader? {
        guard try inventoryState().active else { throw ComparisonStoreError.inventoryInactive }
        let header = try database.putawayHeader(id)
        guard header == nil || header?.owner == owner else { throw ComparisonStoreError.operationConflict }
        return header
    }

    public func reviewedReceiptHeaders(owner: UUID, after: UUID?, limit: Int = 30) throws -> [ReviewedReceiptHeader] {
        guard try inventoryState().active, (1...50).contains(limit) else { throw ComparisonStoreError.invalidInput }
        let row = try database.statement("SELECT header FROM putaway_receipts WHERE owner=? AND id>? ORDER BY id LIMIT ?",
                values: [.text(owner.uuidString), .text(after?.uuidString ?? ""), .integer(Int64(limit))])
        defer { sqlite3_finalize(row) }
        var results: [ReviewedReceiptHeader] = []
        while true {
            switch sqlite3_step(row) {
            case SQLITE_DONE: return results
            case SQLITE_ROW: results.append(try JSONDecoder().decode(ReviewedReceiptHeader.self, from: database.inventoryBlob(row, column: 0, maximum: 2048)))
            default: throw ComparisonStoreError.corruptRecord
            }
        }
    }

    public func reviewedReceiptCoordinates(receipt: UUID, owner: UUID, layout: UUID, ordinals: [Int]) throws -> [Int: UUID] {
        guard try reviewedReceiptHeader(receipt, owner: owner) != nil else { return [:] }
        guard (1...50).contains(ordinals.count) else { throw ComparisonStoreError.invalidInput }
        let marks = Array(repeating: "?", count: ordinals.count).joined(separator: ",")
        let row = try database.statement("SELECT ordinal,line FROM putaway_receipt_coordinates WHERE receipt=? AND layout=? AND ordinal IN (" + marks + ")",
            values: [.text(receipt.uuidString), .text(layout.uuidString)] + ordinals.map { .integer(Int64($0)) })
        defer { sqlite3_finalize(row) }
        var result: [Int: UUID] = [:]
        while true {
            switch sqlite3_step(row) {
            case SQLITE_DONE: return result
            case SQLITE_ROW:
                guard let id = try UUID(uuidString: database.text(row, column: 1)) else { throw ComparisonStoreError.corruptRecord }
                result[Int(sqlite3_column_int64(row, 0))] = id
            default: throw ComparisonStoreError.corruptRecord
            }
        }
    }

    public func reviewedReceiptDecisions(receipt: UUID, owner: UUID, matching: [UUID]? = nil,
                                        after: UUID? = nil, limit: Int = 50) throws -> [ReviewedReceiptDecision] {
        guard try reviewedReceiptHeader(receipt, owner: owner) != nil else { return [] }
        guard (1...200).contains(limit) else { throw ComparisonStoreError.invalidInput }
        var query = "SELECT body FROM putaway_receipt_lines WHERE receipt=? AND id>?"
        var values: [ComparisonSQLValue] = [.text(receipt.uuidString), .text(after?.uuidString ?? "")]
        if let matching {
            guard (1...50).contains(matching.count) else { throw ComparisonStoreError.invalidInput }
            query += " AND id IN (" + Array(repeating: "?", count: matching.count).joined(separator: ",") + ")"
            values += matching.map { .text($0.uuidString) }
        }
        let row = try database.statement(query + " ORDER BY id LIMIT ?", values: values + [.integer(Int64(limit))])
        defer { sqlite3_finalize(row) }
        var results: [ReviewedReceiptDecision] = []
        while true {
            switch sqlite3_step(row) {
            case SQLITE_DONE: return results
            case SQLITE_ROW: results.append(try JSONDecoder().decode(ReviewedReceiptDecision.self, from: database.inventoryBlob(row, column: 0, maximum: 8192)))
            default: throw ComparisonStoreError.corruptRecord
            }
        }
    }
}
