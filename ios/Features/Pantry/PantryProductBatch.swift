import CoreDomain
import CryptoKit
import Foundation

enum ProductBatchError: Error { case full, invalid, lookupUnavailable, rateLimited }

struct PantryProductBatch {
    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        let ordinal: Int
        let barcode: CapturedBarcode?
        let photoID: String?
        let original: String
        var name: String
        var perPack: String
        var unit: UnitOfMeasure
        var packages = ""
        var location = InventoryLocation.cupboard
        var included = true
        var catalog: ProductCatalogProposal?
        var appliedCatalog: ProductCatalogProposal?

        var total: Rational? {
            guard let count = Int64(packages.trimmingCharacters(in: .whitespaces)), (1...10_000).contains(count),
                  let size = try? ComparisonModel.quantity(perPack, unit), size.amount > .zero else { return nil }
            return try? size.amount.multiplied(by: Rational(count))
        }

        mutating func use(_ proposal: ProductCatalogProposal) {
            if let text = proposal.name { name = text }
            if let pack = Self.pack(proposal.quantity ?? "") { perPack = pack.0; unit = pack.1 }
            catalog = proposal
            appliedCatalog = proposal
        }

        static func pack(_ literal: String) -> (String, UnitOfMeasure)? {
            let parts = literal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let units: [(String, UnitOfMeasure)] = [("fl oz", .fluidOunce), ("kg", .kilogram), ("ml", .milliliter),
                ("oz", .ounce), ("lb", .pound), ("ct", .count), ("g", .gram), ("l", .liter)]
            for (suffix, unit) in units where parts.hasSuffix(suffix) {
                let number = String(parts.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                if let quantity = try? ComparisonModel.quantity(number, unit), quantity.amount > .zero { return (number, unit) }
            }
            return nil
        }
    }

    let id = UUID()
    let workspaceID: UUID
    private(set) var nextOrdinal = 0
    var candidates: [Candidate] = []

    init(workspaceID: UUID) { self.workspaceID = workspaceID }

    private func codeKey(_ code: CapturedBarcode) -> String {
        code.validGTIN ? String(repeating: "0", count: 14 - code.value.count) + code.value : code.value
    }

    mutating func addManual(name: String, code: String?) throws -> Bool {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reference = raw.isEmpty ? nil : CapturedBarcode(symbology: "manual", value: raw)
        try reference?.validate()
        guard text.utf8.count <= 512, !text.contains("\0"), !text.isEmpty || reference != nil else { throw ProductBatchError.invalid }
        return try add(code: reference, photo: nil, original: text)
    }

    mutating func addPhoto(_ source: ScannedSource) throws -> Int {
        guard !source.originalImageData.isEmpty, source.originalImageData.count <= CaptureLimits.imageBytes else { throw ScanFailure.tooLarge }
        try ScanLimits.text(source.originalText)
        guard source.barcodes.count <= 16 else { throw ProductBatchError.full }
        let photo = SHA256.hash(data: source.originalImageData).map { String(format: "%02x", $0) }.joined()
        let codes: [CapturedBarcode?] = source.barcodes.isEmpty ? [nil] : source.barcodes.map(Optional.some)
        var next = self
        let before = candidates.count
        for code in codes {
            try code?.validate()
            // A label photographed beside several barcodes cannot establish which product owns its wording.
            _ = try next.add(code: code, photo: photo, original: codes.count == 1 ? source.originalText : "")
        }
        self = next
        return candidates.count - before
    }

    private mutating func add(code: CapturedBarcode?, photo: String?, original: String) throws -> Bool {
        if let code, candidates.contains(where: { $0.barcode.map(codeKey) == codeKey(code) }) { return false }
        if code == nil, let photo, candidates.contains(where: { $0.photoID == photo && $0.barcode == nil }) { return false }
        guard candidates.count < 12, nextOrdinal < 200 else { throw ProductBatchError.full }
        let text = String(decoding: original.utf8.prefix(512), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let proposal = lines.compactMap(Candidate.pack).first
        let name = lines.first { Candidate.pack($0) == nil && $0 != code?.value } ?? ""
        candidates.append(.init(ordinal: nextOrdinal, barcode: code, photoID: photo, original: text, name: name,
                                perPack: proposal?.0 ?? "", unit: proposal?.1 ?? .count))
        nextOrdinal += 1
        return true
    }

    mutating func revokePhotos() { candidates.removeAll { $0.photoID != nil } }

    func draft(merchant: String, purchaseDate: Date, confirmed: Bool) throws -> ReceiptImportDraft {
        let rows = try candidates.filter(\.included).map { candidate -> ReceiptImportDraft.Line in
            guard let total = candidate.total, !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProductBatchError.invalid
            }
            var evidence = [candidate.barcode?.value, candidate.original.isEmpty ? nil : candidate.original,
                            "\(candidate.packages) × \(candidate.perPack) \(candidate.unit.rawValue)"].compactMap { $0 }
            if let proposal = candidate.appliedCatalog {
                evidence.append(proposal.attribution)
            }
            return .init(id: candidate.id, ordinal: candidate.ordinal, original: evidence.joined(separator: " · "), name: candidate.name,
                         treatment: .add, received: total.description, usable: total.description, unit: candidate.unit, location: candidate.location)
        }
        guard confirmed, !rows.isEmpty else { throw ProductBatchError.invalid }
        return ReceiptImportDraft(batchID: id, workspaceID: workspaceID, merchant: merchant, purchaseDate: purchaseDate, lines: rows)
    }
}

extension ReceiptImportDraft {
    init(batchID: UUID, workspaceID: UUID, merchant: String, purchaseDate: Date, lines: [Line]) {
        draftID = batchID
        self.workspaceID = workspaceID
        savedPickup = nil
        imageDigest = nil
        self.merchant = merchant
        self.purchaseDate = purchaseDate
        dateConfirmed = true
        self.lines = lines
    }
}
