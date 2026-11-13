import XCTest
@testable import HouseholdClient

final class SharedDemandLegacySourceTests: XCTestCase {
    private let household = SharedDemandID(), shop = SharedDemandID(), request = SharedDemandID(), line = SharedDemandID()
    private func row() -> [String: Any] {
        ["id": SharedDemandID().string, "source": ["kind": "request", "requestId": request.string, "appliedRequestRevision": 8],
         "sourceLabel": "Oat milk", "productName": "Oat milk", "originalText": "Original family wording", "originalQuantityText": "a little",
         "quantity": NSNull(), "requiredLineId": line.string, "sourceExclusions": []]
    }
    private func page(_ sources: Any?) throws -> SharedDemandPage {
        var json: [String: Any] = ["schemaVersion": 1, "shopId": shop.string, "shopRevision": 4, "authorityEpoch": 2, "status": "legacy", "graph": NSNull(), "totals": []]
        if let sources { json["legacySources"] = sources }
        return try JSONDecoder().decode(SharedDemandPage.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testOldServerMissingCatalogRemainsAbsentInsteadOfInventingEmptySources() throws {
        let page = try page(nil); try page.validate(householdID: household.string, shopID: shop.uuid)
        XCTAssertNil(page.legacySources)
    }
    func testExactRequestLinkRevisionAndOriginalWordingSurviveRoundtrip() throws {
        let value = try page(["sources": [row()]])
        try value.validate(householdID: household.string, shopID: shop.uuid)
        let copy = try JSONDecoder().decode(SharedDemandPage.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(copy, value)
        XCTAssertEqual(copy.legacySources?.sources[0].source, .request(requestId: request, appliedRequestRevision: 8))
        XCTAssertEqual(copy.legacySources?.sources[0].requiredLineId, line)
        XCTAssertNil(copy.legacySources?.sources[0].quantity)
        XCTAssertEqual(copy.legacySources?.sources[0].originalQuantityText, "a little")
    }
    func testRequiredNullableDescriptorKeysCannotBeOmitted() throws {
        for key in ["quantity", "originalQuantityText", "requiredLineId"] {
            var row = row(); row.removeValue(forKey: key)
            XCTAssertThrowsError(try page(["sources": [row]]), key)
        }
    }
    func testRequestWithoutMandatoryLineAndDuplicateSourceIdentityFail() throws {
        var missing = row(); missing["requiredLineId"] = NSNull()
        XCTAssertThrowsError(try page(["sources": [missing]]).validate(householdID: household.string, shopID: shop.uuid))
        var duplicate = row(); duplicate["id"] = SharedDemandID().string
        XCTAssertThrowsError(try page(["sources": [row(), duplicate]]).validate(householdID: household.string, shopID: shop.uuid))
    }
    func testManualOriginCannotMasqueradeAsRequiredServerSource() throws {
        var manual = row(); manual["source"] = ["kind": "manual"]
        XCTAssertThrowsError(try page(["sources": [manual]]).validate(householdID: household.string, shopID: shop.uuid))
    }
    func testForgedMealExclusionIdentityFailsWithoutGuessingAnAllergen() throws {
        var row = row(); let occurrence = SharedDemandID(), ingredient = SharedDemandID()
        row["source"] = ["kind": "meal", "occurrenceId": occurrence.string, "ingredientId": ingredient.string, "groupId": NSNull(), "bindingId": NSNull()]
        row["requiredLineId"] = NSNull()
        row["sourceExclusions"] = [["occurrenceId": SharedDemandID().string, "ingredientId": ingredient.string, "label": "Exact family wording", "resolution": ["kind": "unresolved"]]]
        XCTAssertThrowsError(try page(["sources": [row]]).validate(householdID: household.string, shopID: shop.uuid))
    }
    func testReservationClarificationIntentRejectsMissingWrongDuplicateOrCombinedRows() throws {
        let row = SharedDemandContribution(lineId: line, source: .reservation(reservationId: .init(), purpose: "Lunch", originOccurrenceId: .init(), ingredientId: .init(), groupId: nil, bindingId: nil), productKey: "wraps", productName: "Wraps", originalText: "Lunch wraps", quantity: nil)
        try SharedDemandChange(contributions: [row], clarifyReservationProductIds: [row.id]).validate()
        XCTAssertThrowsError(try SharedDemandChange(clarifyReservationProductIds: [row.id]).validate())
        XCTAssertThrowsError(try SharedDemandChange(contributions: [row], clarifyReservationProductIds: [row.id, row.id]).validate())
        XCTAssertThrowsError(try SharedDemandChange(contributions: [row], quantifyReservationIds: [row.id], clarifyReservationProductIds: [row.id]).validate())
        var manual = row; manual.source = .manual
        XCTAssertThrowsError(try SharedDemandChange(contributions: [manual], clarifyReservationProductIds: [manual.id]).validate())
        var nilKey = row; nilKey.productKey = nil
        XCTAssertThrowsError(try SharedDemandChange(contributions: [nilKey], clarifyReservationProductIds: [nilKey.id]).validate())
    }
    func testBoundReservationClarificationReviewPreservesEveryOtherFactAndCannotBeUndo() throws {
        let old = SharedDemandContribution(lineId: line, source: .reservation(reservationId: .init(), purpose: "Lunch", originOccurrenceId: .init(), ingredientId: .init(), groupId: nil, bindingId: nil), productKey: nil, productName: "Wraps", originalText: "Two lunch wraps", quantity: .init(amount: try .init(numerator: 2), unit: .count, originalLiteral: "2"))
        let row = SharedDemandLine(id: line, name: "Wraps", unit: .count, originalOrder: 0)
        let before = SharedDemandGraph(householdId: household, shopId: shop, revision: 1, lines: [row], contributions: [old], edges: [], usedIds: [line, old.id])
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: nil, capScope: "unknown", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        let basket = ShopperBasketLine(lineId: line.uuid, originalItem: "Wraps", packs: 1, unitPriceMinor: nil, feeEligible: true)
        let pack = SharedDemandPackReview(lineId: line, usablePerPack: nil, acceptUnresolved: true)
        func review(_ next: SharedDemandContribution, listed: Bool = true) -> SharedDemandReview {
            var after = before; after.revision = 2; after.contributions = [next]
            let total = SharedDemandLineTotal(lineId: line, unit: .count, quantity: old.quantity!.amount, activeContributionIds: [old.id])
            let request = SharedDemandPreviewRequest(mode: .change, base: .init(shopRevision: 4, authorityEpoch: 2, graphRevision: 1),
                change: .init(contributions: [next], clarifyReservationProductIds: listed ? [old.id] : nil),
                action: .patch(.init(quote: quote, lines: [basket])), packs: [pack])
            return .init(context: .init(subject: "adult", householdID: household.string, memberID: SharedDemandID().string, deviceID: "device"), shopID: shop.uuid, request: request,
                preview: .init(previewId: .init(), previewDigest: String(repeating: "a", count: 64), expiresAt: "2099-01-01T00:00:00Z", before: before, after: after,
                    receipt: .init(schemaVersion: 1, operationId: .init(), householdId: household, shopId: shop, baseRevision: 1, resultRevision: 2, lines: [], contributions: [.init(id: old.id, before: old, after: next)], edges: []),
                    packs: [pack], beforeTotals: [total], afterTotals: [total], shopRevision: 4, authorityEpoch: 2))
        }
        var next = old; next.productKey = "wraps"
        let accepted = review(next); try accepted.validate()
        let roundtrip = try JSONDecoder().decode(SharedDemandReview.self, from: JSONEncoder().encode(accepted))
        XCTAssertEqual(roundtrip.request.change.clarifyReservationProductIds, [old.id]); try roundtrip.validate()
        XCTAssertThrowsError(try review(next, listed: false).validate())
        next.contains = ["dairy"]; XCTAssertThrowsError(try review(next).validate())
        next = old; next.productKey = "wraps"; next.originalText = "Changed wording"
        XCTAssertThrowsError(try review(next).validate())
        var undo = accepted.request; undo.mode = .undo; undo.undoOperationId = .init()
        XCTAssertThrowsError(try undo.validate())
    }

}
