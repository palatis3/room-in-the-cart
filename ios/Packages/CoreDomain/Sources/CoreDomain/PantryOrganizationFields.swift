import Foundation

/// Optional subdivisions of a physical storage type. String labels never describe food condition.
public struct InventoryNamedPlace: Codable, Hashable, Sendable {
    public let storage: String
    public let drawer: String

    public init(storage: String, drawer: String = "") {
        self.storage = storage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.drawer = drawer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validate() throws {
        guard !storage.isEmpty, [storage, drawer].allSatisfy({
            $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) && $0.utf8.count <= 128 &&
                $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { throw InventoryError.invalid("namedPlace") }
    }
}

public enum InventoryPlaceEdit: Codable, Equatable, Sendable {
    case assign(InventoryNamedPlace), clear
}

/// Literal source evidence is private to the lot. No amount or date in this record
/// is a physical observation, a shelf-life estimate or a reservation.
public struct InventorySpreadsheetRow: Codable, Equatable, Sendable {
    public let sourceName: String
    public let rowKey: String
    public let label: String
    public let quantity: String
    public let unit: String
    public let barcode: String
    public let date: String
    public let location: String
    public let category: String
    public let note: String

    public init(sourceName: String, rowKey: String, label: String, quantity: String, unit: String,
                barcode: String, date: String, location: String, category: String, note: String) {
        self.sourceName = sourceName
        self.rowKey = rowKey
        self.label = label
        self.quantity = quantity
        self.unit = unit
        self.barcode = barcode
        self.date = date
        self.location = location
        self.category = category
        self.note = note
    }

    public func validate() throws {
        guard !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rowKey.isEmpty, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [sourceName, rowKey, label, quantity, unit, barcode, date, location, category, note]
                .allSatisfy({ $0.utf8.count <= 512 && !$0.contains("\0") })
        else { throw InventoryError.invalid("spreadsheetRow") }
    }
}
