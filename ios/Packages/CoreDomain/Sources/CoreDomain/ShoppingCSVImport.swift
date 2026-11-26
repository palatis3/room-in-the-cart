import Foundation

public enum ShoppingCSVColumn: String, CaseIterable, Hashable, Sendable {
    case item, category, note, quantity, unit, barcode

    private var aliases: [String] {
        switch self {
        case .item: return ["item", "name", "description", "articulo", "producto", "nombre", "descripcion"]
        case .category: return ["category", "aisle", "categoria", "departamento", "pasillo"]
        case .note: return ["note", "notes", "nota", "notas"]
        case .quantity: return ["quantity", "qty", "cantidad"]
        case .unit: return ["unit", "units", "unidad", "unidades"]
        case .barcode: return ["barcode", "upc", "ean", "codigo de barras"]
        }
    }

    /// Repeated or ambiguous candidate headings require a deliberate selection.
    public static func suggestedMapping(_ headers: [String]) -> [Self: Int] {
        var mapping: [Self: Int] = [:]
        for field in allCases {
            let matches = headers.indices.filter { field.aliases.contains(normalizedProduct(headers[$0])) }
            if matches.count == 1 { mapping[field] = matches[0] }
        }
        return mapping
    }
}

/// The mapped source values remain private, including the literal barcode and decimal spelling.
public struct ShoppingCSVRecord: Codable, Equatable, Hashable, Sendable {
    public let item, category, note, quantityText, unitText, barcode: String
    public let occurrence: Int

    func measure() throws -> Quantity? {
        let literal = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitLabel = unitText.trimmingCharacters(in: .whitespacesAndNewlines)
        if literal.isEmpty && unitLabel.isEmpty { return nil }
        // With no declared locale, 1,250 (or 1.250) could mean one and a quarter or 1250.
        let parts = literal.split(whereSeparator: { $0 == "," || $0 == "." })
        if parts.count == 2, parts[0].count <= 3, parts[0].first != "0", parts[0].allSatisfy(\.isNumber),
           parts[1].count == 3 && parts[1].allSatisfy(\.isNumber) { throw LedgerError.invalid("csvDecimal") }
        let amount = try ListQuantityParser.numericAmount(literal)
        guard amount > .zero else { throw LedgerError.invalid("csvAmount") }
        let unit: UnitOfMeasure
        if unitLabel.isEmpty || ["ea","each","count","pieza","piezas","unidad","unidades"].contains(unitLabel.lowercased()) {
            unit = .count
        } else {
            var tokens = ListQuantityParser.itemTokens(unitLabel)
            guard let value = UnitOfMeasure(rawValue: unitLabel) else {
                guard let parsed = ListQuantityParser.takeUnit(from: &tokens), tokens.isEmpty else { throw LedgerError.invalid("csvUnit") }
                return Quantity(amount: amount, unit: parsed, originalLiteral: [quantityText,unitText].joined(separator: " "))
            }
            unit = value
        }
        return Quantity(amount: amount, unit: unit, originalLiteral: [quantityText,unitText].filter { !$0.isEmpty }.joined(separator: " "))
    }

    func validate() throws {
        try ledgerText(item, nonempty: true, maximum: 512)
        try ledgerText(category, maximum: 512)
        try ledgerText(note)
        try ledgerText(barcode, maximum: 128)
        try ledgerText(quantityText, maximum: 64)
        try ledgerText(unitText, maximum: 128)
        guard occurrence > 0 && occurrence <= StagedListImport.maximumLines else { throw LedgerError.invalid("csvOccurrence") }
    }
}

public struct ShoppingCSVReview: Sendable {
    public enum Status: Equatable, Sendable {
        case ready, matchingName, previouslyImported, invalidFields, invalidQuantity, wrongColumnCount
    }
    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let record: ShoppingCSVRecord
        public let status: Status
        fileprivate let entry: StagedImportLine?
    }
    public let rows: [Row]
    public let shopID: UUID
    public let baseRevision: Int
    public let id: UUID

    public init(table: GroceryCSVTable, mapping: [ShoppingCSVColumn: Int], shop: ShoppingLedger) throws {
        guard mapping[.item] != nil, Set(mapping.values).count == mapping.count,
              mapping.values.allSatisfy(table.headers.indices.contains) else { throw LedgerError.invalid("csvMapping") }
        guard table.rows.count <= StagedListImport.maximumLines else { throw ImportTextLimit.nonblankLines(maximum: StagedListImport.maximumLines) }
        shopID = shop.id; baseRevision = shop.revision; id = UUID()
        let previous = shop.importedCSVRecords
        var names = Set(shop.lines.lazy.filter { !$0.isTrashed }.map { normalizedProduct($0.name) })
        var counts: [[String]: Int] = [:]
        var results: [Row] = []
        for (offset, cells) in table.rows.enumerated() {
            func value(_ field: ShoppingCSVColumn) -> String {
                guard let column = mapping[field], cells.indices.contains(column) else { return "" }
                return cells[column]
            }
            let values = ShoppingCSVColumn.allCases.map(value)
            let occurrence = (counts[values] ?? 0) + 1
            counts[values] = occurrence
            let record = ShoppingCSVRecord(item: value(.item), category: value(.category), note: value(.note),
                quantityText: value(.quantity), unitText: value(.unit), barcode: value(.barcode), occurrence: occurrence)
            func row(_ status: Status, _ entry: StagedImportLine? = nil) -> Row {
                Row(id: offset + 1, record: record, status: status, entry: entry)
            }
            guard cells.count == table.headers.count else { results.append(row(.wrongColumnCount)); continue }
            guard (try? record.validate()) != nil else { results.append(row(.invalidFields)); continue }
            let quantity: Quantity?
            do { quantity = try record.measure() } catch { results.append(row(.invalidQuantity)); continue }
            if previous.contains(record) { results.append(row(.previouslyImported)); continue }
            let distinct = names.insert(normalizedProduct(record.item)).inserted
            var entry = StagedImportLine(id: UUID(), proposedLineID: UUID(), originalText: record.item,
                name: record.item, quantity: quantity, unresolvedReason: nil, duplicateLineIDs: [])
            entry.csvRecord = record
            results.append(row(distinct ? .ready : .matchingName, entry))
        }
        rows = results
    }

    /// Selected matching names explicitly create separate lines. Existing rows are never overwritten.
    @discardableResult
    public func apply(selected: Set<Int>, to shop: inout ShoppingLedger, at date: Date = Date()) throws -> UUID {
        let entries = rows.filter { selected.contains($0.id) }.compactMap(\.entry)
        guard shop.id == shopID, !entries.isEmpty, entries.count == selected.count else { throw LedgerError.invalid("csvSelection") }
        let preview = StagedListImport(id: id, shopID: shopID, baseRevision: baseRevision, source: .csv,
            originalText: entries.map(\.originalText).joined(separator: "\n"), lines: entries)
        return try shop.commitImport(preview, decisions: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, .addNew) }), at: date)
    }
}


extension ShoppingLedger {
    var importedCSVRecords: Set<ShoppingCSVRecord> {
        Set(importBatches.lazy.filter { $0.source == .csv && $0.undoneAt == nil }.flatMap { batch in
            batch.preview.lines.compactMap { batch.decisions[$0.id] == .skip ? nil : $0.csvRecord }
        })
    }
}
