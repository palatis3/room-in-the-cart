import XCTest
import CoreDomain
@testable import RoomInTheCart

@MainActor final class PickupReadableRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ minute: Int) -> Date { start.addingTimeInterval(TimeInterval(minute * 60)) }
    private func count(_ amount: Int64, _ original: String? = nil) throws -> Quantity {
        Quantity(amount: try Rational(amount), unit: .count, originalLiteral: original ?? String(amount))
    }

    func testPersistedTimelineKeepsOriginalOrderCorrectionsOffersAndCashDistinct() throws {
        let shop = UUID(), id = UUID(), revision = UUID()
        let line = try BasketLine(id: id, name: "Wraps de casa", quantity: count(12, "one dozen wraps"), expectedCost: .exact(Money(minorUnits: 300)))
        let context = CheckoutContext(storeID: "Mercado", branchID: "Centro", mode: .pickup, slot: "Martes",
            commitmentsID: shop, observedAt: start, source: "Original total at checkout")
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .components(
            lines: [.init(id: id, name: line.name, cost: line.expectedCost)], lineSetComplete: false,
            fees: [.init(id: "bolsa", rule: .waivedAt(threshold: Money(minorUnits: 500), belowThreshold: .exact(Money(minorUnits: 150)), basis: .eligibleItemsBeforeDiscounts))],
            discounts: [], tax: .unknown(reason: "still checking tax"), deposits: .exact(.zero)))
        var basket = try BasketPlan(id: shop, revisionID: revision, lines: [line], createdAt: start)
        let frozen = try basket.freeze(snapshotID: UUID(), expectedRevision: revision, at: at(1))
        let place = ReportedPlacement(id: UUID(), intentID: UUID(), snapshotID: frozen.id, reportedAt: at(2))
        try basket.reportPlaced(place)
        let replacement = try BasketLine(id: id, name: line.name, quantity: count(8, "ocho en total"), expectedCost: .unknown(reason: "amount not repriced"))
        try basket.confirmAmendment(.init(id: UUID(), placementID: place.id, previousAmendmentID: nil, lines: [replacement], confirmedAt: at(3), retailerReference: "Desk #B"))
        var ledger = try PickupLedger(orderID: place.id, orderLines: basket.physicalOrderLines(branch: "Centro"))
        let key = ReceiptKey(sourceEventID: "bag", orderLineID: id, branchID: "Centro", segmentID: "left")
        try ledger.receive(.init(key: key, itemName: line.name, received: count(6), disposition: .partial, receivedAt: at(4)))
        let observation = try UsableObservation(id: UUID(), receipt: key, usable: count(6, "seis al llegar"), confirmedAt: at(5), confirmedMatchToOrderLine: true)
        try ledger.confirmUsable(observation)
        try ledger.confirmUsable(.init(id: UUID(), receipt: key, usable: count(5, "cinco sanos"), confirmedAt: at(6), supersedesID: observation.id, confirmedMatchToOrderLine: true))
        var j = PickupJourney(id: shop, savedAt: at(20))
        j.context = context; j.basket = basket; j.quote = quote; j.quotedRevisionID = revision; j.frozenQuotes[frozen.id] = quote
        j.revision = 1
        let earlier = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 4_069))))
        j.earlierQuotes = [.init(id: 0, basketRevisionID: revision, quote: earlier,
            cap: CheckoutCap(scope: .wholeCheckout, commitmentsID: shop, amount: Money(minorUnits: 3_800)))]
        j.cap = CheckoutCap(scope: .item, commitmentsID: shop, amount: Money(minorUnits: 3_800))
        j.pickup = ledger
        j.needs = try [.init(id: UUID(), orderLineID: id, name: "Lunch", amount: count(2), priority: .protected),
                       .init(id: UUID(), orderLineID: id, name: "Tacos", amount: count(6), priority: .required)]
        let note = PickupCookNote(id: UUID(), text: "Aparta dos para el almuerzo.", language: "es", createdAt: at(8), revision: 7)
        j.notes = [note]
        j.cookShareEvents = [.init(id: UUID(), noteID: note.id, occurredAt: at(9), action: .shareCancelled, destination: nil)]
        j.recipientSends = [.init(channel: .cook, versionID: note.id, recipient: "Jo", language: "es", sentAt: at(11), acknowledgedAt: nil)]
        j.offers = try [.init(id: UUID(), lineID: id, replacement: "Harina", required: count(8), remainingOriginal: count(3),
            price: .bounded(lower: Money(minorUnits: 200), upper: Money(minorUnits: 250), reason: "shelf range"),
            ceiling: nil, deadline: RetailerDeadline(cutoff: at(10), timeZoneID: "America/Chicago"),
            fallback: "Sin picante", householdPreference: "Preferimos maíz", retailerResponse: "")]
        let offer = try XCTUnwrap(j.offers.first)
        let inputs = try PickupOfferEvaluationInputs(offeredUsable: count(4), retainedOriginalCharge: .exact(.zero), lineAllowance: nil,
            dishRules: j.needs.map { .init(needID: $0.id, decision: $0.priority == .protected ? .declined : .accepted, exclusionsConfirmed: false) },
            includedOfferIDs: [offer.id], otherCheckoutCost: .unknown(reason: "waiting on retailer"), wholeCheckoutCap: nil,
            checkoutSource: "Retailer worksheet", checkoutObservedAt: at(6))
        let review = try PickupOfferEvaluation.review(offer: offer, inputs: inputs, journey: j, at: at(7))
        j.offers[0].evaluation = review
        try j.settlement.append(.init(id: UUID(), evidenceKey: "bank authorization", kind: .paymentHold, amount: Money(minorUnits: 800), occurredAt: at(1)))
        try j.settlement.append(.init(id: UUID(), evidenceKey: "statement", kind: .postedCharge, amount: Money(minorUnits: 350), occurredAt: at(12)))
        try j.settlement.append(.init(id: UUID(), evidenceKey: "claim slip", kind: .pendingCredit, amount: Money(minorUnits: 150),
                                    occurredAt: at(13), creditID: "counter receipt", chargeEvidenceKey: "statement"))
        // Older private files could save a credit dated after this record's snapshot.
        try j.settlement.append(.init(id: UUID(), evidenceKey: "later-statement", kind: .postedCredit, amount: Money(minorUnits: 150),
                                    occurredAt: at(25), creditID: "counter receipt", chargeEvidenceKey: "statement"))
        let bytes = try RecordsNativeCodec.canonical(j)
        let saved = try RecordsNativeCodec.pickup(bytes)
        let text = try PickupReadableRecord.text(saved, locale: Locale(identifier: "en_US"))
        let ordered = ["Original placed order", "Desk #B", "seis al llegar", "cinco sanos", note.text, "Reported sent to: Jo", "statement"]
        var remainder = text[...]
        for marker in ordered {
            let match = try XCTUnwrap(remainder.range(of: marker), marker)
            remainder = remainder[match.upperBound...]
        }
        for marker in ["later-statement", "This entry is dated later and is excluded from these totals.", "Saved checkout quote\nCheckout evidence recorded at:", "one dozen wraps", "ocho en total", "still checking tax", "Fee waiver threshold: $5.00",
                       "Still short: 3 units", "Preferimos maíz", "Retailer response: Pending", "Cancelled",
                       "Lunch · Excluded from this dish", "Tacos · Approved for this dish", "Paid so far: $3.50",
                       "Payment holds · not spending: $8.00", "Credit reference: counter receipt", "Original posted charge: statement",
                       "Pending credits · not deducted: $1.50", "No spending cap recorded with this frozen copy",
                       "Over this scope’s cap by: $2.69", "Cap and checkout cover different commitments"] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(marker), marker)
        }
        XCTAssertFalse(text.contains("Recipient acknowledgment reported"))
        let spanish = try PickupReadableRecord.text(saved, locale: Locale(identifier: "es_US"))
        for marker in ["Cantidad utilizable corregida", "Cotización guardada del total de la compra", "Preferimos maíz", note.text, "still checking tax"] {
            XCTAssertTrue(spanish.contains(marker), marker)
        }
        XCTAssertFalse(spanish.contains("wholeCheckout"))
        XCTAssertEqual(try RecordsNativeCodec.canonical(saved), bytes)
    }

    func testFrozenShopperRecordKeepsItsReviewedCapAfterRepricingAndRestart() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = PickupModel(databaseURL: file)
        let shop = UUID()
        let line = try BasketLine(id: UUID(), name: "beans", quantity: count(2), expectedCost: .exact(Money(minorUnits: 300)))
        let context = CheckoutContext(storeID: "Market", branchID: "Main", mode: .pickup, slot: "Tuesday",
            commitmentsID: shop, observedAt: start, source: "Retailer preview")
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 300))))
        let originalCap = CheckoutCap(scope: .wholeCheckout, commitmentsID: shop, amount: Money(minorUnits: 500))
        let changedCap = CheckoutCap(scope: .wholeCheckout, commitmentsID: shop, amount: Money(minorUnits: 200))
        let started = await model.start(from: [line], shopID: shop, context: context)
        let quoted = await model.setQuote(quote, cap: originalCap)
        let didFreeze = await model.freeze()
        XCTAssertTrue(started && quoted && didFreeze)
        let original = try XCTUnwrap(model.frozenSnapshot)
        let reopened = await model.reopenDraft(reviewing: original)
        let requoted = await model.setQuote(quote, cap: changedCap)
        let refrozen = await model.freeze()
        XCTAssertTrue(reopened && requoted && refrozen)
        let restored = PickupModel(databaseURL: file)
        await restored.load()
        let saved = try XCTUnwrap(restored.journey)
        let record = try PickupReadableRecord.text(RecordsNativeCodec.pickup(RecordsNativeCodec.canonical(saved)),
                                                   locale: Locale(identifier: "en_US"))
        let freezes = record.components(separatedBy: "\n\n").filter { $0.contains("Frozen · placement unconfirmed") }
        XCTAssertEqual(freezes.count, 2)
        let first = try XCTUnwrap(freezes.first)
        let second = try XCTUnwrap(freezes.last)
        XCTAssertTrue(first.contains("Spending cap: $5.00"))
        XCTAssertTrue(first.contains("Within this scope’s cap · room remaining: $2.00"))
        XCTAssertTrue(second.contains("Spending cap: $2.00"))
        XCTAssertTrue(second.contains("Over this scope’s cap by: $1.00"))
        XCTAssertFalse(record.contains("No spending cap recorded"))
        XCTAssertFalse(HandoffCopy.retailer(original, language: "es-US").fullText.contains("$"))

        var legacy = saved
        legacy.frozenCaps = nil
        let oldBytes = try RecordsNativeCodec.canonical(legacy)
        let oldFields = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        XCTAssertNil(oldFields["frozenCaps"])
        let reopenedLegacy = try RecordsNativeCodec.pickup(oldBytes)
        XCTAssertEqual(try RecordsNativeCodec.canonical(reopenedLegacy), oldBytes)
        let legacyRecord = try PickupReadableRecord.text(reopenedLegacy, locale: Locale(identifier: "en_US"))
        for entry in legacyRecord.components(separatedBy: "\n\n").filter({ $0.contains("Frozen · placement unconfirmed") }) {
            XCTAssertTrue(entry.contains("No spending cap recorded with this frozen copy"))
            XCTAssertFalse(entry.contains("Spending cap:"))
        }

        var malformed = saved
        malformed.frozenCaps = [UUID().uuidString: originalCap]
        XCTAssertThrowsError(try RecordsNativeCodec.pickup(RecordsNativeCodec.canonical(malformed)))
    }

    func testDraftAndSavedOnlyNoteDoNotImplyPlacementPaymentOrSend() throws {
        let shop = UUID(), revision = UUID()
        let salt = try BasketLine(id: UUID(), name: "sal", quantity: count(1), expectedCost: .unknown(reason: "ask at checkout"))
        var journey = PickupJourney(id: shop, savedAt: at(3))
        var basket = try BasketPlan(id: shop, revisionID: revision, lines: [salt], createdAt: start)
        let frozen = try basket.freeze(snapshotID: UUID(), expectedRevision: revision, at: at(1))
        try basket.recordHandoff(.init(id: UUID(), snapshotID: frozen.id, kind: .shareCancelled, occurredAt: at(2)))
        journey.basket = basket
        journey.deferred = [.init(id: UUID(), sourceShopID: shop, line: salt, status: "handled")]
        journey.carriedMeals = [try .init(id: UUID(), orderLineID: salt.id, name: "Sopa de mañana",
            amount: count(1, "una pizca"), priority: .required)]
        journey.notes = [.init(id: UUID(), text: "Solo borrador", language: "es", createdAt: at(1), revision: 1)]
        let saved = try RecordsNativeCodec.pickup(RecordsNativeCodec.canonical(journey))
        let text = try PickupReadableRecord.text(saved, locale: Locale(identifier: "en_US"))
        for expected in ["ask at checkout", "Solo borrador", "Share cancelled", "Current checkout: Not confirmed", "Already handled · no new purchase · sal",
                         "Sopa de mañana", "una pizca", "No current stock or purchase is assumed for this carried need."] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        for absent in ["Original placed order", "Reported sent to", "Paid so far", "Actual arrival"] {
            XCTAssertFalse(text.contains(absent), absent)
        }
    }
}
