import CoreDomain
import Foundation
import LocalStore

extension ReceiptImportDraft.Line {
    var needsPackReview: Bool {
        original.contains(#/(?i)\b(?:packs?|pk|multipacks?|paquetes?)\b|\d\s*[x×]\s*\d/#)
    }

    /// Only a shopper's explicit selection confirms that this printed quantity came home intact.
    func permitsIntactSelection(deliveries: [InventoryLot]) -> Bool {
        guard !needsPackReview, canComparePurchase, let printed, printed.kind == .item,
              printed.quantity != nil, printed.unit != nil, printed.name != nil,
              !original.contains(#/(?i)\b(?:missing|damaged|broken|cracked|substitut\w*|replacement|unweighed|unknown|faltante|sin pesar|peso desconocido|dañad\w*|rot[oa]s?|quebrad\w*|sustitu\w*|reemplaz\w*|return\w*|devuelt\w*|refund\w*|eaten|consumid\w*)\b/#)
        else { return false }
        let key = InventoryReceiptAlias.key(name)
        return !deliveries.contains {
            PantryReceiptDelivery.fragment(of: $0) != nil && InventoryReceiptAlias.key($0.name) == key
        }
    }

    mutating func selectIntact(deliveries: [InventoryLot]) {
        guard treatment == .skip, permitsIntactSelection(deliveries: deliveries) else { return }
        usePrintedQuantity()
        usable = received
        treatment = .add
        selectedIntact = true
    }
}

struct PutawayOverlap: Error {
    enum Choice { case earlier(UUID), additional }
    let basis: UUID
    let ordinal: Int
    let line: ReviewedReceiptDecision
    let earlier: [ReviewedReceiptDecision]

    func canUse(_ prior: ReviewedReceiptDecision) -> Bool {
        // An existing physical receipt line is reconciled through the delivery/rescan stock review.
        line.lotID == nil && prior.lotID == nil && line.kind == prior.kind && line.paidMinor == prior.paidMinor &&
            line.original == prior.original && line.name == prior.name
    }
}

extension PantryRepository {
    private var receiptOwner: UUID { aliasPersonaID ?? originID }

    func preparePutaway(_ draft: ReceiptImportDraft, receiptID: UUID, documentID: UUID?,
                        facts: [ReceiptAcquisition]) async throws -> (value: ReviewedPutawayReceipt?, changed: Bool) {
        guard draft.tracksPutaway else { return (nil, false) }
        let prior = try await store.reviewedReceiptHeader(receiptID, owner: receiptOwner)
        try requireAccess()
        let money = try ComparisonModel.money(draft.receiptTotal)
        let reference = draft.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = ReviewedReceiptHeader(id: receiptID, owner: receiptOwner,
            merchant: draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines), date: draft.purchaseDate,
            totalMinor: money?.minorUnits ?? prior?.totalMinor, reference: reference.isEmpty ? prior?.reference : reference)
        if let prior {
            guard prior.date == header.date, prior.merchant == header.merchant,
                  prior.reference == nil || prior.reference == header.reference,
                  prior.totalMinor == nil || prior.totalMinor == header.totalMinor else { throw PantryReceiptError.changedEvidence }
        }
        // A second image can have identical OCR coordinates. The layout is meaningful only
        // inside the receipt already established by its reference or explicit rescan decision.
        let layout = ReceiptAcquisition.identity(["reviewed-putaway-layout", receiptID.uuidString] +
            draft.lines.flatMap { [String($0.ordinal), $0.original] })
        let ordinals = draft.selectedLines.map(\.ordinal)
        let coordinates = try await store.reviewedReceiptCoordinates(receipt: receiptID, owner: receiptOwner, layout: layout, ordinals: ordinals)
        try requireAccess()
        let byOrdinal = Dictionary(uniqueKeysWithValues: zip(draft.stockLines.map(\.ordinal), facts))
        var decisions: [ReviewedReceiptDecision] = try draft.selectedLines.map { row in
            let fact = byOrdinal[row.ordinal]
            let kind: ReviewedReceiptDecision.Kind
            switch row.treatment {
            case .skip: throw PantryReceiptError.invalid
            case .add: kind = .stored
            case .keptSome: kind = .keptSome
            case .link: kind = .linked
            case .eaten: kind = .eaten
            case .missing: kind = .missing
            case .chargeOrReturn: kind = .chargeOrReturn
            }
            guard row.documentLine?.stage != .order else { throw PantryReceiptError.invalid }
            let paid = row.paid.trimmingCharacters(in: .whitespacesAndNewlines)
            let cents = try paid.isEmpty ? nil : Money(decimal: paid).minorUnits
            guard kind == .chargeOrReturn || (cents ?? 0) >= 0 else { throw PantryReceiptError.invalid }
            if let known = coordinates[row.ordinal], let fact, known != fact.lineID { throw PantryReceiptError.changedEvidence }
            return ReviewedReceiptDecision(id: coordinates[row.ordinal] ?? fact?.lineID ?? ReceiptAcquisition.lineID(receiptID: receiptID, ordinal: row.ordinal, document: documentID),
                ordinal: fact?.ordinal ?? row.ordinal, original: fact?.originalLine ?? row.original, name: fact?.name ?? row.name,
                kind: kind, lotID: fact?.lotID, paidMinor: cents)
        }
        let saved = try await store.reviewedReceiptDecisions(receipt: receiptID, owner: receiptOwner, matching: decisions.map(\.id))
        try requireAccess()
        let byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var newIndices: [Int] = []
        for index in decisions.indices {
            let next = decisions[index]
            if let old = byID[next.id] {
                // Reordered pages can point to an earlier decision under its original ordinal.
                guard old.original == next.original, old.name == next.name, old.lotID == next.lotID,
                      old.kind == next.kind, old.paidMinor == next.paidMinor else { throw PantryReceiptError.changedEvidence }
                decisions[index] = old
            } else {
                newIndices.append(index)
            }
        }
        if prior != nil, !newIndices.isEmpty {
            // An added page may repeat an eaten/fee line that has no acquisition for the stock rescan to match.
            // Require a deliberate choice before interpreting repeated wording as an additional purchase line.
            var matches: [String: [ReviewedReceiptDecision]] = [:]
            let wanted = Set(newIndices.map { ReceiptRecognition.normalize(decisions[$0].original) })
            var cursor: UUID?, bytes = 0
            repeat {
                let page = try await putawayDecisions(receiptID: receiptID, after: cursor)
                for old in page {
                    let key = ReceiptRecognition.normalize(old.original)
                    guard wanted.contains(key) else { continue }
                    bytes += old.original.utf8.count + old.name.utf8.count + 128
                    guard bytes <= limits.payloadBytes else { throw ComparisonStoreError.payloadTooLarge }
                    matches[key, default: []].append(old)
                }
                cursor = page.count == 50 ? page.last?.id : nil
            } while cursor != nil
            for index in newIndices {
                let next = decisions[index]
                let earlier = (matches[ReceiptRecognition.normalize(next.original)] ?? []).filter {
                    ($0.lotID == nil || next.lotID == nil) && !decisions.contains($0)
                }
                guard !earlier.isEmpty else { continue }
                let basis = ReceiptAcquisition.identity([receiptID.uuidString, layout.uuidString, String(ordinals[index]),
                    next.kind.rawValue, next.name, String(describing: next.paidMinor)] + earlier.map { $0.id.uuidString }.sorted())
                let prompt = PutawayOverlap(basis: basis, ordinal: ordinals[index], line: next, earlier: earlier)
                switch draft.overlapChoices[basis] {
                case .additional: break
                case .earlier(let id):
                    guard let old = earlier.first(where: { $0.id == id }), prompt.canUse(old) else { throw prompt }
                    decisions[index] = old
                case nil: throw prompt
                }
            }
        }
        guard Set(decisions.map(\.id)).count == decisions.count else { throw PantryReceiptError.changedEvidence }
        var newIdentity = false
        for identity in draft.evidenceIdentities {
            if try await store.acquisitionReceiptID(for: identity) == nil { newIdentity = true }
            try requireAccess()
        }
        let value = ReviewedPutawayReceipt(header: header, decisions: decisions, identities: draft.evidenceIdentities, layout: layout, ordinals: ordinals)
        return (value, prior != header || saved.count != decisions.count || newIdentity || coordinates.count != decisions.count)
    }

    func putawayHeaders(after: UUID?) async throws -> [ReviewedReceiptHeader] {
        try requireAccess()
        let result = try await store.reviewedReceiptHeaders(owner: receiptOwner, after: after)
        try requireAccess()
        return result
    }

    func putawayDecisions(receiptID: UUID, after: UUID?) async throws -> [ReviewedReceiptDecision] {
        try requireAccess()
        let result = try await store.reviewedReceiptDecisions(receipt: receiptID, owner: receiptOwner, after: after)
        try requireAccess()
        return result
    }
}
