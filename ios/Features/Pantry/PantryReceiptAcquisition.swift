import CoreDomain
import CryptoKit
import Foundation
import LocalStore

struct ReceiptImportDraft {
    enum Treatment: Hashable { case skip, add, link(UUID) }
    struct Line: Identifiable, Equatable {
        let id: UUID
        let ordinal: Int
        let original: String
        var nameBeforeAlias: String?
        var appliedAlias: InventoryReceiptAlias?

        mutating func use(_ alias: InventoryReceiptAlias) {
            if appliedAlias == nil { nameBeforeAlias = name }
            appliedAlias = alias
            name = alias.product
        }

        mutating func clearAlias() {
            if let nameBeforeAlias { name = nameBeforeAlias }
            self.nameBeforeAlias = nil
            appliedAlias = nil
        }
        var name: String
        var treatment: Treatment = .skip
        var received: String = ""
        var usable: String = ""
        var unit: UnitOfMeasure = .count
        var location: InventoryLocation = .cupboard
        var paid: String = ""
    }

    let draftID: UUID
    let workspaceID: UUID
    let savedPickup: ReceiptAcquisition.SavedPickup?
    let imageDigest: Data?
    var merchant: String
    var language = Bundle.main.preferredLocalizations.first?.hasPrefix("es") == true ? "es" : "en"
    var reference = ""
    var purchaseDate = Calendar.current.startOfDay(for: Date())
    var dateConfirmed = false
    var lines: [Line]

    init(source: SourceMediaRecord, fromSavedPickup: Bool = false) throws {
        try source.validate()
        guard source.target.kind == .receiptEvidence, !source.receiptLines.isEmpty else { throw ScanFailure.needsReview }
        savedPickup = fromSavedPickup ? .init(originID: source.target.workspaceID, id: source.target.containerID) : nil
        draftID = source.id
        workspaceID = source.target.workspaceID
        imageDigest = source.imageJPEG.map { Data(SHA256.hash(data: $0)) }
        merchant = source.reviewedLabel
        lines = source.receiptLines.enumerated().map { ordinal, line in
            Line(id: line.id, ordinal: ordinal, original: line.originalText, name: line.reviewedText)
        }
    }

    mutating func clearAliases() {
        for index in lines.indices { lines[index].clearAlias() }
    }

    var receiptID: UUID {
        ReceiptAcquisition.receiptID(merchant: cleaned(merchant), transactionReference: cleaned(reference).isEmpty ? nil : cleaned(reference),
                                     imageDigest: imageDigest, draftID: draftID)
    }

    var evidenceIdentities: [UUID] {
        var ids: [UUID] = []
        if let imageDigest { ids.append(ReceiptAcquisition.identity(["image", imageDigest.base64EncodedString()])) }
        if !cleaned(reference).isEmpty { ids.append(receiptID) }
        return ids
    }

    func facts(receiptID: UUID, snapshot: PantryRepository.Snapshot, at now: Date) throws -> [ReceiptAcquisition] {
        guard snapshot.state.workspaceID == workspaceID, dateConfirmed, purchaseDate <= now,
              !cleaned(merchant).isEmpty else { throw PantryReceiptError.invalid }
        let selected = lines.filter { $0.treatment != .skip }
        guard (1...50).contains(selected.count) else { throw PantryReceiptError.selection }
        return try selected.map { row in
            guard let received = try ComparisonModel.quantity(row.received, row.unit),
                  let usable = try ComparisonModel.quantity(row.usable, row.unit) else { throw PantryReceiptError.invalid }
            let lineID = ReceiptAcquisition.lineID(receiptID: receiptID, ordinal: row.ordinal)
            let lotID: UUID, foodID: UUID, stock: ReceiptAcquisition.Stock
            switch row.treatment {
            case .skip: throw PantryReceiptError.invalid
            case .add:
                lotID = ReceiptAcquisition.identity(["lot", workspaceID.uuidString, lineID.uuidString])
                foodID = row.appliedAlias?.foodID ?? lotID
                stock = .added(location: row.location)
            case .link(let id):
                guard let lot = snapshot.lots.first(where: { $0.id == id }),
                      case .receipt(_, let key) = lot.source,
                      !key.sourceEventID.hasPrefix("receipt-acquisition/"), received.unit == lot.unit else { throw PantryReceiptError.stale }
                if let alias = row.appliedAlias, alias.foodID != lot.foodID { throw PantryReceiptError.stale }
                lotID = id; foodID = lot.foodID; stock = .linked(fragment: key)
            }
            let fact = try ReceiptAcquisition(receiptID: receiptID, ordinal: row.ordinal, lotID: lotID,
                foodID: foodID, merchant: cleaned(merchant), purchaseDate: purchaseDate,
                transactionReference: cleaned(reference).isEmpty ? nil : cleaned(reference), imageDigest: imageDigest,
                originalLine: row.original, name: cleaned(row.name), received: received, usable: usable,
                paidLineTotal: cleaned(row.paid).isEmpty ? nil : Money(decimal: cleaned(row.paid)), stock: stock, savedPickup: savedPickup)
            try fact.validate()
            return fact
        }
    }

    static func containsWording(_ wording: String, in original: String) -> Bool {
        let key = InventoryReceiptAlias.key(wording)
        guard !key.isEmpty else { return false }
        return (" " + InventoryReceiptAlias.key(original) + " ").contains(" " + key + " ")
    }

    private func cleaned(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum PantryReceiptError: Error { case invalid, selection, stale, changedEvidence }
struct PantryReceiptReview: Identifiable {
    let id: UUID
    let workspaceID: UUID
    let revision: Int64
    let facts: [ReceiptAcquisition]
    let existing: Set<UUID>
    let batch: InventoryBatch?
}

enum PantryAcquisitionCodec {
    static func validateLot(_ row: ReceiptAcquisition, lot: InventoryLot?) throws {
        guard let lot, lot.id == row.lotID, lot.foodID == row.foodID,
              case .receipt(_, let key) = lot.source else { throw PantryReceiptError.invalid }
        switch row.stock {
        case .added:
            guard key.sourceEventID == "receipt-acquisition/" + row.receiptID.uuidString,
                  key.orderLineID == row.lineID, key.branchID == row.merchant, key.segmentID == String(row.ordinal) else { throw PantryReceiptError.invalid }
        case .linked(let fragment):
            guard key == fragment else { throw PantryReceiptError.invalid }
        }
    }

    static func record(_ row: InventoryAcquisitionRow) throws -> ReceiptAcquisition {
        let value = try JSONDecoder().decode(ReceiptAcquisition.self, from: row.payload)
        try value.validate()
        guard value.id == row.id, value.receiptID == row.receiptID, value.lineID == row.lineID, value.lotID == row.lotID,
              value.revision == row.revision, value.supersedesID == row.supersedesID else { throw PantryReceiptError.invalid }
        guard try self.row(value) == row else { throw PantryReceiptError.invalid }
        return value
    }
    static func row(_ value: ReceiptAcquisition) throws -> InventoryAcquisitionRow {
        try value.validate()
        return .init(id: value.id, receiptID: value.receiptID, lineID: value.lineID, lotID: value.lotID, revision: value.revision,
                     supersedesID: value.supersedesID, payload: try data(value),
                     imageIdentity: value.imageDigest.map { ReceiptAcquisition.identity(["image", $0.base64EncodedString()]) },
                     transactionIdentity: value.transactionReference.map {
                         ReceiptAcquisition.receiptID(merchant: value.merchant, transactionReference: $0, imageDigest: nil, draftID: value.receiptID)
                     })
    }
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
