import CoreDomain
import Foundation
import LocalStore

struct ReceiptRescanDecision: Equatable {
    let basis: UUID
    /// A nil receipt records the shopper's decision to review this as another purchase.
    let receipt: UUID?
    let existingByOrdinal: [Int: UUID]
}

struct ReceiptRescanPrompt: Error {
    struct Candidate: Identifiable {
        let id: UUID
        let original: [ReceiptAcquisition]
        /// Only original lines matching actual wording on the new document may be selected.
        let matches: [Int: [UUID]]
    }
    let basis: UUID
    let candidates: [Candidate]
    let rows: [ReceiptImportDraft.Line]
    let truncated: Bool
    let linkedReceipt: UUID?
    let fixed: [Int: UUID]
}

struct ReceiptRecognition {
    let owner, merchantDay, document: UUID
    let wording: [Int: UUID]
    let lookupKeys: Set<UUID>
    let fileDigest: String?
    let basis: UUID

    init?(draft: ReceiptImportDraft, persona: UUID?, revision: Int64) {
        guard let persona, draft.supportsRescan, draft.dateConfirmed, !draft.selectedLines.isEmpty else { return nil }
        owner = ReceiptAcquisition.identity(["receipt-owner", draft.workspaceID.uuidString, persona.uuidString])
        let merchant = Self.normalize(draft.merchant)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year,.month,.day], from: draft.purchaseDate)
        merchantDay = ReceiptAcquisition.identity(["merchant-day", owner.uuidString, merchant,
            String(date.year ?? 0), String(date.month ?? 0), String(date.day ?? 0)])
        let source = draft.imageDigest?.base64EncodedString() ?? draft.receiptID.uuidString
        fileDigest = draft.imageDigest?.map { String(format: "%02x", $0) }.joined()
        document = ReceiptAcquisition.identity(["receipt-document", owner.uuidString, source])
        var keys: [Int: UUID] = [:]
        var fields = [document.uuidString, merchantDay.uuidString, String(revision), draft.reference, draft.receiptTotal]
        for row in draft.stockLines {
            let raw = Self.normalize(row.original)
            keys[row.ordinal] = Self.wordingKey(raw)
            fields += [String(row.ordinal), raw, row.name, row.received, row.usable, row.paid, row.unit.rawValue,
                       row.location.rawValue, String(describing: row.treatment), row.appliedAlias?.id.uuidString ?? ""]
        }
        wording = keys
        var lookup = Set(keys.values)
        for line in draft.lines where line.treatment == .skip && lookup.count < 50 {
            if let key = Self.wordingKey(Self.normalize(line.original)) { lookup.insert(key) }
        }
        lookupKeys = lookup
        basis = ReceiptAcquisition.identity(fields + lookup.map(\.uuidString).sorted())
    }

    private static func wordingKey(_ normalized: String) -> UUID? {
        let words = normalized.split(separator: " ").filter { $0.contains(where: \.isLetter) }.joined(separator: " ")
        guard words.filter(\.isLetter).count >= 3 else { return nil }
        return ReceiptAcquisition.identity(["printed-line", words])
    }
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive,.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    func binding(_ row: ReceiptAcquisition, ordinal: Int, additionalDocument: Bool) -> InventoryReceiptBinding {
        .init(owner: owner, merchantDay: merchantDay,
              wording: wording[ordinal] ?? ReceiptAcquisition.identity(["unsearchable", document.uuidString, String(ordinal)]),
              document: document, ordinal: ordinal, sourceID: row.id, receiptID: row.receiptID, lotID: row.lotID, fileDigest: fileDigest, additionalDocument: additionalDocument)
    }
}

extension PantryRepository {
    struct RescanPlan {
        var receipt: UUID
        var document: UUID?
        var originals: [Int: UUID] = [:]
        var bound = Set<Int>()
        var authorizedRows = Set<UUID>()
    }

    func rescanPlan(_ draft: ReceiptImportDraft, recognition: ReceiptRecognition?, exact: UUID?) async throws -> RescanPlan {
        var result = RescanPlan(receipt: exact ?? draft.receiptID)
        guard let recognition else { return result }
        try await store.checkRescanLines(owner: recognition.owner, document: recognition.document, ordinals: draft.selectedLines.map(\.ordinal))
        try await store.checkReceiptOwner(recognition.owner, receipt: result.receipt, fileDigest: recognition.fileDigest)
        let known = try await store.rescanBindings(owner: recognition.owner, document: recognition.document)
        try requireAccess()
        let receipt = known.first?.receiptID ?? exact
        var continuedReceipt: UUID?
        if let receipt {
            try await store.checkReceiptOwner(recognition.owner, receipt: receipt)
            try requireAccess()
            guard exact == nil || exact == receipt, known.allSatisfy({ $0.receiptID == receipt && $0.merchantDay == recognition.merchantDay && $0.additionalDocument == known.first?.additionalDocument }) else { throw PantryReceiptError.changedEvidence }
            result.receipt = receipt
            result.originals = Dictionary(uniqueKeysWithValues: known.map { ($0.ordinal, $0.sourceID) })
            result.bound = Set(result.originals.keys)
            let owned = try await store.rescanBindings(owner: recognition.owner, receipt: receipt)
            try requireAccess()
            result.authorizedRows = Set(owned.map(\.sourceID))
            if known.isEmpty, !owned.isEmpty, !owned.contains(where: { $0.merchantDay == recognition.merchantDay }) {
                throw PantryReceiptError.changedEvidence
            }
            // A linked document has its own page coordinates. This also applies on the next partial selection.
            if known.first?.additionalDocument == true || (known.isEmpty && !owned.isEmpty && draft.imageDigest != nil) {
                result.document = recognition.document
                if draft.stockLines.contains(where: { result.originals[$0.ordinal] == nil }) { continuedReceipt = receipt }
            }
            if continuedReceipt == nil { return result }
        }
        guard !draft.stockLines.isEmpty, !recognition.lookupKeys.isEmpty else { return result }
        let ids: [UUID]
        if let continuedReceipt { ids = [continuedReceipt] }
        else {
            ids = try await store.rescanCandidates(owner: recognition.owner, merchantDay: recognition.merchantDay,
                wording: Array(recognition.lookupKeys))
        }
        try requireAccess()
        var candidates: [ReceiptRescanPrompt.Candidate] = []
        var payloadBudget = limits.payloadBytes
        for id in ids.prefix(8) {
            let registered = try await store.rescanBindings(owner: recognition.owner, receipt: id)
            try requireAccess()
            let verified = Array(Set(registered.map(\.sourceID)))
            var facts: [ReceiptAcquisition] = []
            let limit = InventoryPersistenceLimits.pageItems
            for index in stride(from: 0, to: verified.count, by: limit) {
                let chunk = Array(verified[index..<min(index + limit, verified.count)])
                let rows = try await store.acquisitionRows(receiptID: id, sourceIDs: chunk, firstRevisionOnly: true, limit: limit)
                try requireAccess()
                guard rows.count == chunk.count else { throw PantryReceiptError.stale }
                payloadBudget -= rows.reduce(0) { $0 + $1.payload.count }
                guard payloadBudget >= 0 else { throw ComparisonStoreError.payloadTooLarge }
                facts += try rows.map(PantryAcquisitionCodec.record)
            }
            guard !facts.isEmpty else { continue }
            let newReference = draft.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newReference.isEmpty, facts.compactMap(\.transactionReference).contains(where: { $0 != newReference }) { continue }
            let matches = recognition.wording.mapValues { key in
                Array(Set(registered.filter { $0.merchantDay == recognition.merchantDay && $0.wording == key }.map(\.sourceID))).sorted { $0.uuidString < $1.uuidString }
            }
            if continuedReceipt != nil, !matches.contains(where: { result.originals[$0.key] == nil && !$0.value.isEmpty }) {
                return result
            }
            candidates.append(.init(id: id, original: facts.sorted { $0.ordinal < $1.ordinal }, matches: matches))
        }
        guard !candidates.isEmpty || ids.count > 8 else {
            guard draft.rescanDecision == nil else { throw PantryReceiptError.stale }
            return result
        }
        let prompt = ReceiptRescanPrompt(basis: recognition.basis, candidates: candidates, rows: draft.stockLines, truncated: ids.count > 8, linkedReceipt: continuedReceipt, fixed: result.originals)
        guard let decision = draft.rescanDecision, decision.basis == recognition.basis else { throw prompt }
        guard let original = decision.receipt else { if continuedReceipt != nil { throw prompt }; return result }
        guard let choice = candidates.first(where: { $0.id == original }) else { throw prompt }
        let mapped = result.originals.merging(decision.existingByOrdinal) { saved, _ in saved }
        let selected = Set(mapped.values)
        guard selected.count == mapped.count,
              decision.existingByOrdinal.allSatisfy({ (result.originals[$0.key] == nil || result.originals[$0.key] == $0.value) && choice.matches[$0.key]?.contains($0.value) == true }),
              choice.matches.allSatisfy({ mapped[$0.key] != nil || Set($0.value).isSubset(of: selected) }) else { throw prompt }
        result.receipt = choice.id
        result.document = recognition.document
        result.originals = mapped
        result.authorizedRows = Set(choice.original.map(\.id))
        return result
    }
}
