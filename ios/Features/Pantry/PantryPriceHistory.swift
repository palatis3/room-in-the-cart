import CoreDomain
import Foundation
import LocalStore

struct PantryPricePage {
    let standalone: [PrivatePriceEvidence]
    let receipts: [PrivatePriceEvidence]
    let nextStandalone: InventoryPriceRow?
    let nextReceipt: UUID?
    let state: InventoryState
}

enum PantryPriceError: Error { case imageAlreadySaved }

enum PantryPriceCodec {
    static func row(_ evidence: PrivatePriceEvidence) throws -> InventoryPriceRow {
        try evidence.validate()
        if case .paidReceipt = evidence.source { throw PantryReceiptError.invalid }
        let target: UUID?
        if case .adjustment(let id, _, _) = evidence.source { target = id } else { target = nil }
        return try .init(id: evidence.id, revision: evidence.revision, lotID: evidence.linkedLotID, adjustsPriceID: target,
                         payload: PantryAcquisitionCodec.data(evidence))
    }

    static func evidence(_ row: InventoryPriceRow) throws -> PrivatePriceEvidence {
        let evidence = try JSONDecoder().decode(PrivatePriceEvidence.self, from: row.payload)
        guard try self.row(evidence) == row else { throw PantryReceiptError.invalid }
        return evidence
    }
}
