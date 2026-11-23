import CSQLite
import Foundation

/// Reviewed evidence from a single explicitly selected delivery PDF. Amounts use the reviewed receipt currency.
public struct PrivateDeliveryRevision: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case finalReceipt, adjustment, refund }
    public enum Disposition: String, Codable, CaseIterable, Sendable {
        case unresolved, dining, readyToEat, leftovers, fridge, freezer, cupboard
        case tax, tip, fee, discount, refund
    }
    public struct Line: Codable, Identifiable, Equatable, Sendable {
        public var id: Int { (page - 1) * 200 + line - 1 }
        public let page: Int
        public let line: Int
        public let scanned: Bool
        public let uncertain: Bool
        public let wording: String
        public var disposition: Disposition
        public var cents: Int?
        public init(page: Int, line: Int, scanned: Bool, uncertain: Bool, wording: String,
                    disposition: Disposition, cents: Int?) {
            self.page = page
            self.line = line
            self.scanned = scanned
            self.uncertain = uncertain
            self.wording = wording
            self.disposition = disposition
            self.cents = cents
        }
    }

    public let digest: Data
    public let layoutID: UUID
    public let order: String
    public let merchant: String
    public let kind: Kind
    public let purchaseDate: Date?
    public let purchaseTimeZoneIdentifier: String?
    public let purchaseDay: String?
    public let deliveryDate: Date?
    public let deliveryTimeZoneIdentifier: String?
    public let deliveryDay: String?
    public let importedAt: Date
    private let storedCurrency: String?
    public var currencyCode: String { storedCurrency ?? "USD" }
    public let finalCents: Int?
    public private(set) var lines: [Line]

    public init(digest: Data, layoutID: UUID, order: String, merchant: String, kind: Kind,
                purchaseDate: Date?, deliveryDate: Date?, importedAt: Date, finalCents: Int?, lines: [Line],
                purchaseTimeZoneIdentifier: String? = nil, deliveryTimeZoneIdentifier: String? = nil, currencyCode: String = "USD") {
        self.digest = digest
        self.layoutID = layoutID
        self.order = order
        self.merchant = merchant
        self.kind = kind
        self.purchaseDate = purchaseDate
        self.purchaseTimeZoneIdentifier = purchaseTimeZoneIdentifier
        self.purchaseDay = purchaseDate.flatMap { Self.civilDay($0, zone: purchaseTimeZoneIdentifier) }
        self.deliveryDate = deliveryDate
        self.deliveryTimeZoneIdentifier = deliveryTimeZoneIdentifier
        self.deliveryDay = deliveryDate.flatMap { Self.civilDay($0, zone: deliveryTimeZoneIdentifier) }
        self.importedAt = importedAt
        self.storedCurrency = currencyCode == "USD" ? nil : currencyCode
        self.finalCents = finalCents
        self.lines = lines
    }

    fileprivate mutating func applyChoice(_ choice: Disposition, ordinal: Int) throws {
        guard let index = lines.firstIndex(where: { $0.id == ordinal }) else { throw ComparisonStoreError.invalidInput }
        let financial: Set<Disposition> = [.tax, .tip, .fee, .discount, .refund]
        guard !financial.contains(choice), !financial.contains(lines[index].disposition) else { throw ComparisonStoreError.invalidInput }
        lines[index].disposition = choice
    }

    public var orderKey: String { order.lowercased(with: Locale(identifier: "en_US_POSIX")) }

    private static func civilDay(_ date: Date, zone: String?) -> String? {
        guard let zone, let timeZone = TimeZone(identifier: zone), date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    func validate() throws {
        let validOrder = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard ["USD", "MXN"].contains(currencyCode), digest.count == 32, !order.isEmpty, order.utf8.count <= 100,
              order.unicodeScalars.allSatisfy(validOrder.contains),
              !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, merchant.utf8.count <= 256,
              !merchant.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              finalCents.map({ (0...99_999_999).contains($0) }) ?? (kind != .finalReceipt),
              [purchaseDate, deliveryDate, importedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              (purchaseTimeZoneIdentifier == nil) == (purchaseDay == nil),
              purchaseDay == purchaseDate.flatMap({ Self.civilDay($0, zone: purchaseTimeZoneIdentifier) }),
              (deliveryTimeZoneIdentifier == nil) == (deliveryDay == nil),
              deliveryDay == deliveryDate.flatMap({ Self.civilDay($0, zone: deliveryTimeZoneIdentifier) }),
              lines.count <= 200,
              lines.allSatisfy({ (1...20).contains($0.page) && (1...200).contains($0.line)
                  && !$0.wording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.wording.utf8.count <= 2048
                  && !$0.wording.contains("\0") && ($0.cents.map({ (-99_999_999...99_999_999).contains($0) }) ?? true) }),
              Set(lines.map(\.id)).count == lines.count,
              kind == .finalReceipt || finalCents != nil || lines.contains(where: { $0.cents != nil })
        else { throw ComparisonStoreError.invalidInput }
    }
}

public struct PrivateDeliveryPurchase: Equatable, Identifiable, Sendable {
    public var id: String { latest.orderKey }
    public let latest: PrivateDeliveryRevision
    public let revision: Int
}

extension ComparisonDatabase {
    func installPrivateDeliveryPurchases() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS private_delivery_revisions (
                persona TEXT NOT NULL, order_key TEXT NOT NULL, revision INTEGER NOT NULL,
                file_digest BLOB NOT NULL CHECK(length(file_digest)=32),
                payload BLOB NOT NULL CHECK(length(payload) BETWEEN 1 AND 524288),
                PRIMARY KEY(persona,order_key,revision), UNIQUE(persona,file_digest));
            CREATE TABLE IF NOT EXISTS private_delivery_choices (
                persona TEXT NOT NULL, file_digest BLOB NOT NULL, ordinal INTEGER NOT NULL,
                disposition TEXT NOT NULL, PRIMARY KEY(persona,file_digest,ordinal),
                FOREIGN KEY(persona,file_digest) REFERENCES private_delivery_revisions(persona,file_digest) ON DELETE CASCADE);
            CREATE TRIGGER IF NOT EXISTS erase_private_deliveries AFTER INSERT ON inventory_origin_retirement
            BEGIN DELETE FROM private_delivery_revisions; END;
            """)
    }
}

extension ComparisonStore {
    public func privateDeliveryPurchases(persona: UUID) throws -> [PrivateDeliveryPurchase] {
        guard try inventoryState().active else { throw ComparisonStoreError.inventoryInactive }
        return try deliveryRows("""
            SELECT d.revision,d.file_digest,d.payload FROM private_delivery_revisions d
            WHERE d.persona=? AND NOT EXISTS (SELECT 1 FROM private_delivery_revisions n
                WHERE n.persona=d.persona AND n.order_key=d.order_key AND n.revision>d.revision)
            ORDER BY d.rowid DESC
            """, [.text(persona.uuidString)])
    }

    public func privateDeliveryWithFile(persona: UUID, digest: Data) throws -> PrivateDeliveryPurchase? {
        guard try inventoryState().active else { throw ComparisonStoreError.inventoryInactive }
        return try deliveryRows("SELECT revision,file_digest,payload FROM private_delivery_revisions WHERE persona=? AND file_digest=?",
                                [.text(persona.uuidString), .blob(digest)]).first
    }

    public func privateDeliveryHistory(persona: UUID, orderKey: String) throws -> [PrivateDeliveryPurchase] {
        guard try inventoryState().active else { throw ComparisonStoreError.inventoryInactive }
        return try database.transaction(immediate: false) {
            let entries = try deliveryRows("""
                SELECT revision,file_digest,payload FROM private_delivery_revisions WHERE persona=? AND order_key=? ORDER BY revision DESC
                """, [.text(persona.uuidString), .text(orderKey)])
            return try entries.map { entry in
                var reviewed = entry.latest
                let cursor = try database.statement("SELECT ordinal,disposition FROM private_delivery_choices WHERE persona=? AND file_digest=?",
                                                    values: [.text(persona.uuidString), .blob(reviewed.digest)])
                defer { sqlite3_finalize(cursor) }
                while true {
                    switch sqlite3_step(cursor) {
                    case SQLITE_DONE: return PrivateDeliveryPurchase(latest: reviewed, revision: entry.revision)
                    case SQLITE_ROW:
                        guard let value = try PrivateDeliveryRevision.Disposition(rawValue: database.text(cursor, column: 1)) else {
                            throw ComparisonStoreError.corruptRecord
                        }
                        try reviewed.applyChoice(value, ordinal: Int(sqlite3_column_int64(cursor, 0)))
                    default: throw ComparisonStoreError.corruptRecord
                    }
                }
            }
        }
    }

    @discardableResult public func savePrivateDelivery(_ record: PrivateDeliveryRevision, persona: UUID,
                                                       expectedRevision: Int) throws -> PrivateDeliveryPurchase {
        try record.validate()
        return try database.transaction {
            guard try inventoryState().active else { throw ComparisonStoreError.inventoryInactive }
            let person = ComparisonSQLValue.text(persona.uuidString)
            let duplicate = try deliveryRows("SELECT revision,file_digest,payload FROM private_delivery_revisions WHERE persona=? AND file_digest=?",
                                             [person, .blob(record.digest)]).first
            let latest = try deliveryRows("SELECT revision,file_digest,payload FROM private_delivery_revisions WHERE persona=? AND order_key=? ORDER BY revision DESC LIMIT 1",
                                          [person, .text(record.orderKey)]).first
            if let duplicate {
                guard duplicate.id == record.orderKey, let latest else { throw ComparisonStoreError.operationConflict }
                return latest
            }
            guard (latest?.revision ?? 0) == expectedRevision, latest != nil || record.kind == .finalReceipt else {
                throw ComparisonStoreError.staleInventory
            }
            if let latest, latest.latest.currencyCode != record.currencyCode || InventoryReceiptAlias.key(latest.latest.merchant) != InventoryReceiptAlias.key(record.merchant) {
                throw ComparisonStoreError.operationConflict
            }
            let next = expectedRevision + 1
            let payload = try JSONEncoder().encode(record)
            guard payload.count <= 524_288 else { throw ComparisonStoreError.payloadTooLarge }
            try database.run("INSERT INTO private_delivery_revisions(persona,order_key,revision,file_digest,payload) VALUES(?,?,?,?,?)",
                             [person, .text(record.orderKey), .integer(Int64(next)), .blob(record.digest), .blob(payload)])
            return PrivateDeliveryPurchase(latest: record, revision: next)
        }
    }

    public func reviewPrivateDeliveryLine(persona: UUID, orderKey: String, digest: Data, ordinal: Int,
                                          from expected: PrivateDeliveryRevision.Disposition, to choice: PrivateDeliveryRevision.Disposition) throws {
        try database.transaction {
            guard try inventoryState().active else { throw ComparisonStoreError.inventoryInactive }
            let owner = ComparisonSQLValue.text(persona.uuidString)
            guard var entry = try privateDeliveryWithFile(persona: persona, digest: digest)?.latest,
                  entry.orderKey == orderKey, let line = entry.lines.first(where: { $0.id == ordinal }) else {
                throw ComparisonStoreError.notFound
            }
            let whereLine: [ComparisonSQLValue] = [owner, .blob(digest), .integer(Int64(ordinal))]
            let cursor = try database.statement("SELECT disposition FROM private_delivery_choices WHERE persona=? AND file_digest=? AND ordinal=?", values: whereLine)
            defer { sqlite3_finalize(cursor) }
            let current: PrivateDeliveryRevision.Disposition
            switch sqlite3_step(cursor) {
            case SQLITE_ROW:
                guard let stored = try PrivateDeliveryRevision.Disposition(rawValue: database.text(cursor, column: 0)) else {
                    throw ComparisonStoreError.corruptRecord
                }
                current = stored
            case SQLITE_DONE: current = line.disposition
            default: throw ComparisonStoreError.corruptRecord
            }
            guard current == expected || current == choice else { throw ComparisonStoreError.staleInventory }
            try entry.applyChoice(choice, ordinal: ordinal)
            try database.run("""
                INSERT INTO private_delivery_choices(persona,file_digest,ordinal,disposition) VALUES(?,?,?,?)
                ON CONFLICT(persona,file_digest,ordinal) DO UPDATE SET disposition=excluded.disposition
                """, whereLine + [.text(choice.rawValue)])
        }
    }

    public func deletePrivateDelivery(persona: UUID, orderKey: String, expectedRevision: Int) throws {
        try database.transaction {
            guard try inventoryState().active else { throw ComparisonStoreError.inventoryInactive }
            let current = try deliveryRows("SELECT revision,file_digest,payload FROM private_delivery_revisions WHERE persona=? AND order_key=? ORDER BY revision DESC LIMIT 1",
                                           [.text(persona.uuidString), .text(orderKey)]).first
            guard current?.revision == expectedRevision else { throw ComparisonStoreError.staleInventory }
            try database.run("DELETE FROM private_delivery_revisions WHERE persona=? AND order_key=?", [.text(persona.uuidString), .text(orderKey)])
        }
    }

    private func deliveryRows(_ sql: String, _ args: [ComparisonSQLValue]) throws -> [PrivateDeliveryPurchase] {
        let cursor = try database.statement(sql, values: args)
        defer { sqlite3_finalize(cursor) }
        var rows: [PrivateDeliveryPurchase] = []
        while true {
            switch sqlite3_step(cursor) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                let bytes = try database.inventoryBlob(cursor, column: 2, maximum: 524_288)
                let record = try JSONDecoder().decode(PrivateDeliveryRevision.self, from: bytes)
                try record.validate()
                guard try record.digest == database.inventoryBlob(cursor, column: 1, maximum: 32) else { throw ComparisonStoreError.corruptRecord }
                rows.append(.init(latest: record, revision: Int(sqlite3_column_int64(cursor, 0))))
            default: throw ComparisonStoreError.corruptRecord
            }
        }
    }
}
