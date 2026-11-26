import CoreDomain
import Foundation
import LocalStore

enum PantryCSVField: String, CaseIterable, Identifiable {
    case item, lot, quantity, unit, date, location, barcode, category, note
    var id: Self { self }
    var aliases: [String] {
        switch self {
        case .item: ["item", "name", "product", "food", "artículo", "alimento", "nombre", "producto"]
        case .lot: ["lot", "lot id", "batch id", "lote", "id de lote"]
        case .quantity: ["quantity", "qty", "count", "cantidad"]
        case .unit: ["unit", "units", "unidad", "unidades"]
        case .date: ["date", "best by", "expiry", "expiration", "fecha", "caducidad", "vencimiento"]
        case .location: ["location", "storage", "ubicación", "lugar"]
        case .barcode: ["barcode", "gtin", "upc", "ean", "código de barras"]
        case .category: ["category", "categoría"]
        case .note: ["note", "notes", "nota", "notas"]
        }
    }

    static func suggest(_ headers: [String]) -> [Self: Int] {
        var result: [Self: Int] = [:]
        for field in allCases {
            let matches = headers.indices.filter { column in
                field.aliases.contains { headers[column].trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            }
            if matches.count == 1 { result[field] = matches[0] }
        }
        return result
    }
}

struct PantryCSVPreview {
    enum Status: Equatable { case add, update, unchanged, invalid, conflicting }
    enum Issue: Hashable { case columns, label, lotKey, bounds, unknownPlace, ambiguousDate }
    struct Row: Identifiable {
        let issues: [Issue]
        let id: Int
        let lotID: UUID
        let source: InventorySpreadsheetRow
        let location: InventoryLocation
        let status: Status
        let expectedRevision: Int64?
    }

    let rows: [Row]
    let basis: InventoryState
    var changes: [Row] { rows.filter { $0.status == .add || $0.status == .update } }

    init(table: GroceryCSVTable, mapping: [PantryCSVField: Int], sourceName: String,
         defaultLocation: InventoryLocation, basis: InventoryState, lots: [InventoryLot]) throws {
        let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256, mapping[.item] != nil,
              Set(mapping.values).count == mapping.count, mapping.values.allSatisfy(table.headers.indices.contains)
        else { throw InventoryError.invalid("csvMapping") }
        self.basis = basis
        let byID = Dictionary(uniqueKeysWithValues: lots.map { ($0.id, $0) })
        var values: [(InventorySpreadsheetRow, String)] = []
        var occurrences: [String: Int] = [:]
        for (index, cells) in table.rows.enumerated() {
            func read(_ key: PantryCSVField) -> String {
                guard let n = mapping[key], cells.indices.contains(n) else { return "" }
                return cells[n]
            }
            let key = mapping[.lot] == nil ? "row-\(index + 1)" : "lot-" + read(.lot)
            let evidence = InventorySpreadsheetRow(sourceName: name, rowKey: key, label: read(.item),
                quantity: read(.quantity), unit: read(.unit), barcode: read(.barcode), date: read(.date),
                location: read(.location), category: read(.category), note: read(.note))
            values.append((evidence, key))
            occurrences[key, default: 0] += 1
        }
        // An ordinal-only sheet may contain several batches with the same product name.
        // A moved exact row is evidence of reordering even if the food names still match.
        var priorKeysByContent: [UUID: Set<String>] = [:]
        if mapping[.lot] == nil {
            for lot in lots {
                guard let prior = lot.spreadsheetRow, prior.sourceName == name else { continue }
                priorKeysByContent[Self.contentIdentity(prior), default: []].insert(prior.rowKey)
            }
        }
        let shifted = mapping[.lot] == nil && values.contains { evidence, key in
            let id = ReceiptAcquisition.identity(["pantry-csv-row-v1", name, key])
            guard let prior = byID[id]?.spreadsheetRow, prior != evidence else { return false }
            return prior.label != evidence.label || priorKeysByContent[Self.contentIdentity(evidence)] != nil
        }
        rows = values.enumerated().map { index, entry in
            let (evidence, key) = entry
            // Deliberately independent of the recovered workspace UUID. Its private database owns each copy.
            let id = ReceiptAcquisition.identity(["pantry-csv-row-v1", name, key])
            let old = byID[id]
            let interpreted = Self.physicalLocation(evidence.location)
            let location = old?.location ?? interpreted ?? defaultLocation
            var issues: [Issue] = []
            if table.rows[index].count != table.headers.count { issues.append(.columns) }
            if evidence.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.label) }
            if (mapping[.lot] != nil && key.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                occurrences[key] != 1 { issues.append(.lotKey) }
            if issues.isEmpty, (try? evidence.validate()) == nil { issues.append(.bounds) }
            let invalid = !issues.isEmpty
            if old == nil && interpreted == nil && !evidence.location.isEmpty { issues.append(.unknownPlace) }
            if Self.ambiguousDay(evidence.date) { issues.append(.ambiguousDate) }
            let status: Status
            if invalid {
                status = .invalid
            } else if old == nil {
                status = shifted ? .conflicting : .add
            } else if old?.spreadsheetRow == evidence {
                status = .unchanged
            } else if let prior = old?.spreadsheetRow, prior.sourceName == name, prior.rowKey == key,
                      mapping[.lot] != nil || (!shifted && prior.label == evidence.label) {
                status = .update
            } else {
                // A row number alone cannot identify a different product after a sheet has been reordered.
                status = .conflicting
            }
            return Row(issues: issues, id: index + 1, lotID: id, source: evidence, location: location,
                       status: status, expectedRevision: old?.revision)
        }
    }

    private static func contentIdentity(_ row: InventorySpreadsheetRow) -> UUID {
        ReceiptAcquisition.identity([row.label, row.quantity, row.unit, row.barcode, row.date,
                                     row.location, row.category, row.note])
    }

    static func ambiguousDay(_ raw: String) -> Bool {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split { "/-.".contains($0) }
        guard parts.count == 3, parts[0].count <= 2, parts[1].count <= 2,
              let first = Int(parts[0]), let second = Int(parts[1]), Int(parts[2]) != nil else { return false }
        return first != second && (1...12).contains(first) && (1...12).contains(second)
    }

    static func physicalLocation(_ literal: String) -> InventoryLocation? {
        switch literal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cupboard", "pantry", "despensa", "alacena": .cupboard
        case "fridge", "refrigerator", "refrigerador", "nevera": .fridge
        case "freezer", "congelador": .freezer
        default: nil
        }
    }

    static func edit(_ row: Row, origin: UUID) throws -> PantryOrganizationEdit {
        let change: InventoryChange
        switch row.status {
        case .add:
            let source = InventorySource.manual(originID: origin, sourceID: row.lotID)
            let seed = InventoryLotSeed(foodID: row.lotID, name: row.source.label,
                source: source, location: row.location, unit: .count, count: .unknown, spreadsheetRow: row.source)
            change = .create(seed, observationID: UUID())
        case .update:
            change = .revise(.init(spreadsheetRow: row.source))
        default: throw InventoryError.invalid("csvRow")
        }
        return .init(id: row.lotID, revision: row.expectedRevision, change: change)
    }
}

struct PantryOrganizationEdit {
    let id: UUID
    let revision: Int64?
    let change: InventoryChange

    func validate(origin: UUID) throws {
        switch change {
        case .create(let seed, _):
            guard revision == nil, let row = seed.spreadsheetRow,
                  seed.source == .manual(originID: origin, sourceID: id), seed.foodID == id,
                  id == ReceiptAcquisition.identity(["pantry-csv-row-v1", row.sourceName, row.rowKey]),
                  seed.name == row.label, seed.count == .unknown, seed.observedAt == nil,
                  seed.openedAt == nil, seed.packageCode == nil, seed.splitFromLotID == nil, seed.namedPlace == nil
            else { throw InventoryError.invalid("csvLot") }
        case .revise(let update):
            guard revision != nil, update.placeEdit != nil || update.spreadsheetRow != nil,
                  update.usage == nil, update.observation == nil, update.portion == nil, update.location == nil,
                  update.name == nil, update.foodID == nil, update.useFirst == nil else { throw InventoryError.invalid("organization") }
        default: throw InventoryError.invalid("organization")
        }
    }
}

struct PantryPutaway {
    struct Row: Identifiable {
        let id: UUID
        let revision: Int64
        let name: String
        let before: InventoryNamedPlace?
    }

    let storage: InventoryLocation
    let destination: InventoryNamedPlace?
    let rows: [Row]
    let basis: InventoryState

    init(storage: InventoryLocation, destination: InventoryNamedPlace?, selection: Set<UUID>,
         lots: [InventoryLot], basis: InventoryState) throws {
        try destination?.validate()
        let selected = lots.filter { selection.contains($0.id) }
        guard !selected.isEmpty, selected.count <= 64, selected.count == selection.count,
              selected.allSatisfy({ $0.location == storage }) else { throw InventoryError.stale }
        self.storage = storage
        self.destination = destination
        self.basis = basis
        rows = selected.filter { $0.namedPlace != destination }.map {
            Row(id: $0.id, revision: $0.revision, name: $0.name, before: $0.namedPlace)
        }
        guard !rows.isEmpty else { throw InventoryError.invalid("unchangedPlace") }
    }

    func edits(undo: Bool) -> [PantryOrganizationEdit] {
        rows.map { row in
            let place = undo ? row.before : destination
            return PantryOrganizationEdit(id: row.id, revision: undo ? row.revision + 1 : row.revision,
                change: .revise(.init(placeEdit: place.map(InventoryPlaceEdit.assign) ?? .clear)))
        }
    }
}
