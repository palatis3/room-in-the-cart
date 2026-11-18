import CoreDomain
import Foundation

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
