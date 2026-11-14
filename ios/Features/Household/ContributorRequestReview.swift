import Foundation
import CoreDomain
import HouseholdClient

extension OwnReceipt {
    var contributorDeliveryLabel: String {
        kind == "request.send" && request.route == "next" ? ht("Received for the next shop.") : ht("Received by the household")
    }
}

/// An in-memory review lease. It contains no authority restored from capture text.
struct ContributorRequestScope: Equatable {
    let generation: UUID
    let enrollmentRevision: UUID
    let subject: String
    let householdID: String
    let memberID: String
    let deviceID: String
    let role: String
    let grantID: String?
    let selectedShopID: String?
    let targetShopID: String
    let capabilities: [String]
    let editing: OwnRequest?
    let followingUp: OwnRequest?
    let item: String
    let quantity: String
    let nextShop: Bool
    var destination: String { (editing?.route == "next" || (editing == nil && nextShop)) ? ht("Request for next shop") : ht("Request for this pickup") }
}

struct ContributorRequestReview: Equatable, Identifiable {
    let id: UUID
    let scope: ContributorRequestScope
    let originalText: String
    let item: String
    let quantity: String
    let structured: Bool

    static func typed(scope: ContributorRequestScope) throws -> Self {
        try make(scope: scope, original: scope.item, item: scope.item, quantity: scope.quantity, structured: false)
    }
    static func captured(_ capture: ReviewedCapture, scope: ContributorRequestScope) throws -> Self {
        guard let lines = capture.lines, lines.count == 1, let line = lines.first else { throw ContributorRequestReviewError.oneItem }
        try line.validate()
        guard CaptureCorrectionStore.key(line.destination) == CaptureCorrectionStore.key(scope.destination) else { throw ContributorRequestReviewError.destination }
        var item = line.name
        if !line.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item += "\n" + ht("Purpose") + ": " + line.purpose }
        if !line.exclusions.isEmpty { item += "\n" + ht("Keep these exclusions") + ": " + line.exclusions.joined(separator: "; ") }
        // The existing own-request API has human-readable item/quantity fields.
        // Preserve selected original wording explicitly rather than silently dropping it.
        if line.originalText != line.name { item += "\n" + ht("Original wording") + ": " + line.originalText }
        var amounts: [String] = []
        if let quantity = line.quantity { amounts.append(quantityText(quantity)) }
        if let packs = line.packCount {
            let pack = String(packs) + " " + ht("packs")
            amounts.append(pack + (line.amountPerPack.map { " × " + quantityText($0) } ?? " · " + ht("amount per pack unknown")))
        } else if let perPack = line.amountPerPack {
            amounts.append(ht("pack count unknown") + " × " + quantityText(perPack))
        }
        return try make(scope: scope, original: line.originalText, item: item, quantity: amounts.joined(separator: "; "), structured: true, id: capture.id)
    }
    private static func quantityText(_ value: Quantity) -> String {
        value.originalLiteral + " " + captureText(captureUnitKey(value.unit))
    }
    private static func make(scope: ContributorRequestScope, original: String, item: String, quantity: String, structured: Bool, id: UUID = UUID()) throws -> Self {
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines), quantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty, item.utf16.count <= 240, quantity.utf16.count <= 80 else { throw ContributorRequestReviewError.tooLong }
        return Self(id: id, scope: scope, originalText: original, item: item, quantity: quantity, structured: structured)
    }
}

enum ContributorRequestReviewError: Error { case oneItem, destination, tooLong }
