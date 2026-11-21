import CoreDomain
import CryptoKit
import Foundation
import LocalStore

enum ProductBatchError: Error { case full, invalid, lookupUnavailable, rateLimited, chooseStockAction, changedDelivery, duplicateBarcode }

struct PantryProductBatch {
    static func homeOperationID(for candidate: UUID) -> UUID {
        ReceiptAcquisition.identity(["home-pack", candidate.uuidString])
    }

    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        let ordinal: Int
        fileprivate(set) var barcode: CapturedBarcode?
        let photoID: String?
        let original: String
        var name: String
        var perPack: String
        var unit: UnitOfMeasure
        var packages = ""
        var usable = ""
        var requiresExplicitUsable = false
        var onePackageUnknown = false
        var dateWordingDraft: String?

        var allowsOnePackageUnknown: Bool {
            let count = packages.trimmingCharacters(in: .whitespacesAndNewlines)
            return count.isEmpty || Int(count) == 1
        }

        func homeCount() throws -> InventoryCount {
            guard onePackageUnknown else { return .exact(try usableQuantity()) }
            guard allowsOnePackageUnknown, existingReceipt == nil, linkedDelivery == nil,
                  (dateWordingDraft?.utf8.count ?? 0) <= 1024, dateWordingDraft?.contains("\0") != true
            else { throw ProductBatchError.invalid }
            return .unknown
        }

        func usableQuantity() throws -> Quantity {
            let literal = usable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !onePackageUnknown, let total, !requiresExplicitUsable || !literal.isEmpty,
                  let quantity = try ComparisonModel.quantity(literal.isEmpty ? total.description : literal, unit),
                  quantity.amount >= .zero, quantity.amount <= total else { throw ProductBatchError.invalid }
            return quantity
        }
        var location = InventoryLocation.cupboard
        enum StockAction: Equatable {
            case separate
            case link(PantryReceiptDelivery)
        }
        var stockAction: StockAction?
        var linkedDelivery: PantryReceiptDelivery? {
            guard case .link(let delivery) = stockAction else { return nil }
            return delivery
        }
        var existingReceipt: ReceiptAcquisition?
        var receiptLinkSaved = false
        var included = true
        mutating func selectExistingReceipt(_ source: ReceiptAcquisition) {
            existingReceipt = source
            included = false
            stockAction = nil
            receiptLinkSaved = false
        }
        var enteredByHand = false
        var retailer = ""
        var remembered: ConfirmedPantryPack?
        var confirmedPackID: UUID? {
            guard let remembered, name == remembered.name,
                  let size = try? ComparisonModel.quantity(perPack, unit), size.amount == remembered.size.amount,
                  size.unit == remembered.size.unit else { return nil }
            return remembered.id
        }
        mutating func use(_ confirmed: ConfirmedPantryPack) {
            name = confirmed.name
            perPack = confirmed.size.amount.description
            unit = confirmed.size.unit
            remembered = confirmed
        }
        var catalog: ProductCatalogProposal?
        var appliedCatalog: ProductCatalogProposal?

        func treatment(deliveries: [PantryReceiptDelivery], workspaceID: UUID) throws -> ReceiptImportDraft.Treatment {
            switch stockAction {
            case .link(let chosen):
                guard chosen.state.workspaceID == workspaceID, deliveries.contains(chosen), chosen.lot.unit == unit else {
                    throw ProductBatchError.changedDelivery
                }
                return .link(chosen.id)
            case .separate: return .add
            case nil:
                guard deliveries.isEmpty else { throw ProductBatchError.chooseStockAction }
                return .add
            }
        }

        var total: Rational? {
            guard let count = Int64(packages.trimmingCharacters(in: .whitespaces)), (1...10_000).contains(count),
                  let size = try? ComparisonModel.quantity(perPack, unit), size.amount > .zero else { return nil }
            return try? size.amount.multiplied(by: Rational(count))
        }

        /// Reuse a complete, manually supplied label line from this physical package.
        /// Several date statements need individual review, and other packages never inherit the stamp.
        var reviewedDateWording: String? {
            if onePackageUnknown, let wording = dateWordingDraft {
                let trimmed = wording.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard enteredByHand else { return nil }
            let lines = original.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            let dates = lines.filter { PrintedDateMeaning.suggested(for: $0) != .other }
            guard dates.count == 1, let line = dates.first, line.contains(where: \.isNumber) else { return nil }
            return line
        }

        var reviewEvidenceLine: String {
            if onePackageUnknown {
                return [barcode?.displayValue, original.isEmpty ? nil : original, pantryText("One package, contents unknown")]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            let size = try? ComparisonModel.quantity(perPack, unit)
            return evidenceLine(unitLabel: pantryUnit(unit, singular: size?.amount == .one))
        }

        func evidenceLine(unitLabel: String) -> String {
            var parts = [barcode?.displayValue, original.isEmpty ? nil : original,
                         "\(packages) × \(perPack) \(unitLabel)"].compactMap { $0 }
            if let source = appliedCatalog?.attribution ?? (confirmedPackID != nil ? remembered?.attribution : nil) { parts.append(source) }
            return parts.joined(separator: " · ")
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
                let number = String(parts.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
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

    private enum CodeKey: Equatable {
        case tradeItem(String)
        case unrecognized(String)
    }

    private func codeKey(_ code: CapturedBarcode) -> CodeKey {
        if let gtin = code.canonicalGTIN { return .tradeItem(gtin) }
        return .unrecognized(code.value)
    }

    func candidate(matching code: CapturedBarcode) -> Candidate? {
        let key = codeKey(code)
        return candidates.first { $0.barcode.map(codeKey) == key }
    }

    mutating func correctManualBarcode(_ value: String, for id: UUID) throws {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              !candidates[index].receiptLinkSaved, candidates[index].enteredByHand, let original = candidates[index].barcode else {
            throw ProductBatchError.invalid
        }
        let corrected = CapturedBarcode(symbology: original.symbology, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
        try corrected.validate()
        if let other = candidate(matching: corrected), other.id != id { throw ProductBatchError.duplicateBarcode }
        guard candidates[index].barcode != corrected else { return }

        var row = candidates[index]
        row.barcode = corrected
        if let remembered = row.remembered {
            if row.name == remembered.name { row.name = "" }
            if row.unit == remembered.size.unit, row.perPack == remembered.size.amount.description { row.perPack = "" }
        }
        row.remembered = nil
        if let proposal = row.appliedCatalog {
            if row.name == proposal.name { row.name = "" }
            if let quantity = proposal.quantity, let pack = Candidate.pack(quantity), row.perPack == pack.0, row.unit == pack.1 {
                row.perPack = ""
            }
        }
        row.catalog = nil
        row.appliedCatalog = nil
        if row.linkedDelivery != nil { row.stockAction = nil }
        candidates[index] = row
    }

    mutating func addManual(name: String, code: String?, symbology: String = "manual") throws -> Bool {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reference = raw.isEmpty ? nil : CapturedBarcode(symbology: symbology, value: raw)
        try reference?.validate()
        guard text.utf8.count <= 512, !text.contains("\0"), !text.isEmpty || reference != nil else { throw ProductBatchError.invalid }
        let added = try add(code: reference, photo: nil, original: text)
        if added { candidates[candidates.count - 1].enteredByHand = true }
        return added
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
        if let code, candidate(matching: code) != nil { return false }
        if code == nil, let photo, candidates.contains(where: { $0.photoID == photo && $0.barcode == nil }) { return false }
        guard candidates.count < 12, nextOrdinal < 200 else { throw ProductBatchError.full }
        let truncated = original.utf8.count > 512
        let marker = truncated ? "…" : ""
        var remainingBytes = 512 - marker.utf8.count
        let excerpt = original.prefix { character in
            remainingBytes -= character.utf8.count
            return remainingBytes >= 0
        }
        // A clipped "1 gallon" can look like a complete "1 g" package size.
        let endsAtLineBoundary = excerpt.endIndex == original.endIndex || original[excerpt.endIndex].isNewline
        let completeLines = endsAtLineBoundary ? excerpt : excerpt.prefix(upTo: excerpt.lastIndex(where: \.isNewline) ?? excerpt.startIndex)
        let lines = completeLines.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let proposal = lines.compactMap(Candidate.pack).first
        let name = lines.first { Candidate.pack($0) == nil && $0 != code?.value } ?? ""
        candidates.append(.init(ordinal: nextOrdinal, barcode: code, photoID: photo, original: String(excerpt) + marker, name: name,
                                perPack: proposal?.0 ?? "", unit: proposal?.1 ?? .count))
        nextOrdinal += 1
        return true
    }

    mutating func addScan(_ code: CapturedBarcode) throws -> Bool {
        try code.validate()
        return try add(code: code, photo: nil, original: "")
    }

    mutating func separate(_ id: UUID, scanned: CapturedBarcode? = nil) throws {
        guard let original = candidates.first(where: { $0.id == id }), nextOrdinal < 200, candidates.count < 12 else { throw ProductBatchError.full }
        if let scanned { try scanned.validate(); guard original.barcode.map(codeKey) == codeKey(scanned) else { throw ProductBatchError.invalid } }
        // A new physical batch may have another stamp or lot even when its trade item is identical.
        let identityOnly = original.barcode?.gs1.map { CapturedBarcode(symbology: "manual", value: $0.gtin) } ?? original.barcode
        var copy = Candidate(ordinal: nextOrdinal, barcode: scanned ?? identityOnly, photoID: original.photoID,
                             original: "", name: original.name, perPack: original.perPack, unit: original.unit)
        copy.retailer = original.retailer
        copy.remembered = original.remembered
        copy.appliedCatalog = original.appliedCatalog
        copy.location = original.location
        // The second physical package needs its own count, dates and stock decision.
        if let i = candidates.firstIndex(where: { $0.id == id }), let count = Int(candidates[i].packages), count > 1 {
            let hasPartial = !original.usable.isEmpty && (try? original.usableQuantity())?.amount != original.total
            copy.requiresExplicitUsable = hasPartial || original.requiresExplicitUsable
            candidates[i].requiresExplicitUsable = copy.requiresExplicitUsable
            candidates[i].packages = String(count - 1)
            candidates[i].usable = ""
            copy.packages = "1"
        }
        candidates.append(copy); nextOrdinal += 1
    }

    mutating func revokePhotos() { candidates.removeAll { $0.photoID != nil } }

    func draft(merchant: String, purchaseDate: Date, confirmed: Bool, deliveries: [PantryReceiptDelivery] = []) throws -> ReceiptImportDraft {
        let rows = try candidates.filter(\.included).map { candidate -> ReceiptImportDraft.Line in
            guard candidate.existingReceipt == nil, let total = candidate.total, !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProductBatchError.invalid
            }
            let usable = try candidate.usableQuantity().amount.description
            let treatment = try candidate.treatment(deliveries: deliveries, workspaceID: workspaceID)
            return .init(id: candidate.id, ordinal: candidate.ordinal, original: candidate.evidenceLine(unitLabel: candidate.unit.rawValue), confirmedPackID: candidate.confirmedPackID, packageCode: candidate.barcode, name: candidate.name,
                         treatment: treatment, received: total.description, usable: usable, unit: candidate.unit, location: candidate.location)
        }
        guard confirmed, !rows.isEmpty else { throw ProductBatchError.invalid }
        return ReceiptImportDraft(batchID: id, workspaceID: workspaceID, merchant: merchant, purchaseDate: purchaseDate, lines: rows)
    }
}

extension ReceiptImportDraft {
    init(batchID: UUID, workspaceID: UUID, merchant: String, purchaseDate: Date, lines: [Line]) {
        supportsRescan = false
        draftID = batchID
        self.workspaceID = workspaceID
        savedPickup = nil
        imageDigest = nil
        documentLayoutID = nil
        self.merchant = merchant
        self.purchaseDate = purchaseDate
        dateConfirmed = true
        self.lines = lines
    }
}

extension PantryModel {
    var productDeliveries: [PantryReceiptDelivery] {
        guard phase == .ready, let snapshot else { return [] }
        let purchases = Dictionary(uniqueKeysWithValues: recentPurchases.map { ($0.id, $0) })
        return snapshot.lots.compactMap { lot in
            guard PantryReceiptDelivery.fragment(of: lot) != nil else { return nil }
            return PantryReceiptDelivery(lot: lot, state: snapshot.state, purchase: purchases[lot.id])
        }
    }

    private func verifyProductActions(_ batch: PantryProductBatch) throws {
        guard canEdit, batch.workspaceID == snapshot?.state.workspaceID else { throw PantryReceiptError.stale }
        let deliveries = productDeliveries
        for row in batch.candidates where row.included {
            _ = try row.treatment(deliveries: deliveries, workspaceID: batch.workspaceID)
        }
    }

    func reviewProducts(_ batch: PantryProductBatch, merchant: String, purchaseDate: Date, confirmed: Bool) async throws -> PantryReceiptReview {
        let draft = try batch.draft(merchant: merchant, purchaseDate: purchaseDate, confirmed: confirmed, deliveries: productDeliveries)
        let review = try await reviewReceipt(draft)
        try verifyProductActions(batch)
        return review
    }

    func saveProducts(_ batch: PantryProductBatch, review: PantryReceiptReview) async throws {
        try verifyProductActions(batch)
        try await saveReceipt(review)
    }
}

extension PantryRepository {
    /// A counted package at home has a physical source, with no merchant, price or receipt.
    func reviewHomePacks(_ intake: PantryProductBatch, basis: InventoryState, at time: Date) async throws -> PantryReceiptReview {
        let before = try await loadForEditing(at: time)
        let rows = intake.candidates.filter(\.included)
        guard basis == before.state, originID == intake.workspaceID, !rows.isEmpty else { throw PantryReceiptError.stale }
        var writes: [InventoryWrite] = []
        for row in rows {
            guard row.existingReceipt == nil, row.linkedDelivery == nil else { throw ProductBatchError.invalid }
            let count = try row.homeCount()
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let seed = InventoryLotSeed(foodID: row.confirmedPackID ?? row.id, name: name,
                source: .manual(originID: originID, sourceID: row.id), location: row.location, unit: row.unit, count: count, observedAt: time, packageCode: row.barcode, intakeOrdinal: row.ordinal)
            let command = InventoryCommand(id: PantryProductBatch.homeOperationID(for: row.id), originID: originID,
                lotID: row.id, eventID: ReceiptAcquisition.identity(["event", row.id.uuidString]), expectedRevision: nil,
                occurredAt: time, change: .create(seed, observationID: ReceiptAcquisition.identity(["count", row.id.uuidString])))
            writes += try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: time))
        }
        try validateCapacity(of: writes, replacing: before)
        try requireAccess()
        let batch = InventoryBatch(workspaceID: originID, operationID: intake.id, expectedRevision: basis.revision,
            request: Data(SHA256.hash(data: try PantryAcquisitionCodec.data(writes))), writes: writes)
        return .init(id: intake.id, workspaceID: originID, revision: basis.revision, facts: [], existing: [], batch: batch)
    }
}
