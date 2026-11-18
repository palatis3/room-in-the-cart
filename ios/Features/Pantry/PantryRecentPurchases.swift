import CoreDomain
import Foundation
import LocalStore

/// A receipt can be carried by several pickup histories. The option identifies
/// one existing physical pantry lot and the inventory revision shown to its owner.
struct PantryRecentPurchase: Identifiable, Equatable {
    let id: UUID
    let receiptKey: ReceiptKey
    let reviewedFood: PantryReviewedFood
    let receivedAt: Date
    let usableObservationID: UUID
    let confirmedAt: Date
    let received: Quantity
}

/// The exact private delivery and optional pickup details displayed when a shopper links a package.
struct PantryReceiptDelivery: Identifiable, Equatable {
    let lot: InventoryLot
    let state: InventoryState
    let purchase: PantryRecentPurchase?
    var id: UUID { lot.id }

    static func fragment(of lot: InventoryLot) -> ReceiptKey? {
        guard case .receipt(_, let key) = lot.source, !key.sourceEventID.hasPrefix("receipt-acquisition/") else { return nil }
        return key
    }

    static func label(for lot: InventoryLot, purchase: PantryRecentPurchase?) -> String {
        let title = pantryFormat("Link delivery: %@ · %@", lot.name, String(lot.id.uuidString.suffix(8)))
        guard let purchase else { return title }
        return title + " · " + pantryQuantity(purchase.received) + " · " + purchase.receivedAt.formatted(date: .abbreviated, time: .omitted)
    }
}
