import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

final class PickupOfferReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func quantity(_ amount: Int64, _ unit: UnitOfMeasure = .count) -> Quantity {
        Quantity(amount: try! Rational(amount), unit: unit, originalLiteral: String(amount))
    }
    private func offer(lineID: UUID, id: UUID = UUID(), remaining: Int64 = 2,
                       unit: UnitOfMeasure = .count, price: CostEvidence = .exact(Money(minorUnits: 450))) throws -> PickupOffer {
        PickupOffer(id: id, lineID: lineID, replacement: "Replacement wraps", required: quantity(4, unit),
            remainingOriginal: quantity(remaining, unit), price: price, ceiling: Money(minorUnits: 500),
            deadline: try RetailerDeadline(cutoff: now.addingTimeInterval(-60), timeZoneID: "America/New_York"),
            fallback: "Ask me", householdPreference: "Six wraps for dinner", retailerResponse: "")
    }
    @MainActor private func placed(store: ComparisonStore) async throws -> PickupModel {
        let model = PickupModel(store: store, clock: { self.now })
        let id = UUID(), lineID = UUID()
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup,
            slot: "Evening", commitmentsID: id, observedAt: now, source: "Reviewed")
        let started = await model.start(from: [BasketLine(id: lineID, name: "Wraps", quantity: quantity(8), expectedCost: .exact(Money(minorUnits: 600)))], shopID: id, context: context)
        XCTAssertTrue(started)
        let quoted = await model.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 700)))), cap: nil)
        let frozen = await model.freeze(), reported = await model.reportPlaced()
        XCTAssertTrue(quoted); XCTAssertTrue(frozen); XCTAssertTrue(reported)
        return model
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @MainActor func testReviewedUpdateSurvivesSQLiteRestartAndPreservesUnrelatedFacts() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try ComparisonStore(url: url), model = try await placed(store: store)
        let journeyID = try XCTUnwrap(model.journey?.id), lineID = try XCTUnwrap(model.journey?.pickup?.orderLines.first?.id)
        let original = try offer(lineID: lineID), other = try offer(lineID: lineID)
        let first = await model.saveReviewedOffer(original, journeyID: journeyID, original: nil)
        let second = await model.saveReviewedOffer(other, journeyID: journeyID, original: nil)
        XCTAssertTrue(first); XCTAssertTrue(second)
        let resumed = PickupModel(store: store, clock: { self.now })
        await resumed.load()
        let resumedJourney = try XCTUnwrap(resumed.resumableJourney(for: journeyID))
        let next = try XCTUnwrap(resumedJourney.nextUnfilledOffer(at: now))
        XCTAssertEqual(try next.deadline.status(at: now), .awaitPickup)
        XCTAssertEqual(next.deadline.timeZoneID, "America/New_York")
        XCTAssertNil(resumed.resumableJourney(for: UUID()))
        let action = PickupOfferAction(id: UUID(), offerID: original.id, kind: .copied, occurredAt: now)
        let copied = await model.recordReviewedOfferAction(action, offer: original, journeyID: journeyID)
        XCTAssertTrue(copied)
        let key = ReceiptKey(sourceEventID: "receipt", orderLineID: lineID, branchID: "Branch", segmentID: "first")
        let received = await model.receive(ReceiptFragment(key: key, itemName: "Wraps", received: quantity(2), disposition: .partial, receivedAt: now), usable: nil)
        let charged = await model.settle(SettlementEntry(id: UUID(), evidenceKey: "charge", kind: .postedCharge, amount: Money(minorUnits: 700), occurredAt: now))
        XCTAssertTrue(received)
        XCTAssertNil(model.journey?.nextUnfilledOffer(at: now))
        XCTAssertTrue(charged)
        let before = try XCTUnwrap(model.journey)
        var updated = original; updated.householdPreference = "Use rice with the wraps"; updated.retailerResponse = "Retailer confirmed partial fill"
        let saved = await model.saveReviewedOffer(updated, journeyID: journeyID, original: original)
        XCTAssertTrue(saved) // Unrelated receipt/cash/revision changes do not stale the offer itself.
        let revision = model.journey?.revision
        let replay = await model.saveReviewedOffer(updated, journeyID: journeyID, original: original)
        XCTAssertTrue(replay); XCTAssertEqual(model.journey?.revision, revision)
        try await store.close()
        let reopened = PickupModel(databaseURL: url); await reopened.load()
        let after = try XCTUnwrap(reopened.journey)
        XCTAssertEqual(after.offers, [updated, other]); XCTAssertEqual(after.offerActions, [action])
        XCTAssertEqual(after.basket, before.basket); XCTAssertEqual(after.pickup, before.pickup)
        XCTAssertEqual(after.quote, before.quote); XCTAssertEqual(after.settlement, before.settlement)
        XCTAssertEqual(updated.deadline, original.deadline)
        XCTAssertEqual(try updated.deadline.status(at: now), .awaitPickup)
    }

    @MainActor func testStaleOfferAndWrongJourneyCannotOverwriteAndNewDraftUsesDistinctID() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try ComparisonStore(url: url), model = try await placed(store: store)
        let journeyID = try XCTUnwrap(model.journey?.id), lineID = try XCTUnwrap(model.journey?.pickup?.orderLines.first?.id)
        let original = try offer(lineID: lineID)
        _ = await model.saveReviewedOffer(original, journeyID: journeyID, original: nil)
        var firstEdit = original; firstEdit.retailerResponse = "No replacement"
        _ = await model.saveReviewedOffer(firstEdit, journeyID: journeyID, original: original)
        let before = model.journey
        var staleEdit = original; staleEdit.householdPreference = "Stale overwrite"
        let stale = await model.saveReviewedOffer(staleEdit, journeyID: journeyID, original: original)
        let wrong = await model.saveReviewedOffer(firstEdit, journeyID: UUID(), original: firstEdit)
        let collision = await model.saveReviewedOffer(staleEdit, journeyID: journeyID, original: nil)
        let changedIdentity = await model.saveReviewedOffer(try offer(lineID: lineID), journeyID: journeyID, original: firstEdit)
        XCTAssertFalse(stale); XCTAssertFalse(wrong); XCTAssertFalse(collision); XCTAssertFalse(changedIdentity)
        XCTAssertEqual(model.journey, before)
        let new = try offer(lineID: lineID)
        let saved = await model.saveReviewedOffer(new, journeyID: journeyID, original: nil)
        XCTAssertTrue(saved); XCTAssertEqual(model.journey?.offers.map(\.id), [original.id, new.id])
        // A route switch cannot edit the original journey even if the old offer still exists.
        let switched = await model.startNextShop(accept: [])
        XCTAssertTrue(switched)
        let oldRoute = await model.saveReviewedOffer(staleEdit, journeyID: journeyID, original: firstEdit)
        XCTAssertFalse(oldRoute)
    }

    @MainActor func testFailedPersistenceKeepsPriorOfferAndBlocksFurtherChanges() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try ComparisonStore(url: url), model = try await placed(store: store)
        let journeyID = try XCTUnwrap(model.journey?.id), lineID = try XCTUnwrap(model.journey?.pickup?.orderLines.first?.id)
        let original = try offer(lineID: lineID)
        _ = await model.saveReviewedOffer(original, journeyID: journeyID, original: nil)
        try await store.close()
        var updated = original; updated.retailerResponse = "New response"
        let failed = await model.saveReviewedOffer(updated, journeyID: journeyID, original: original)
        XCTAssertFalse(failed); XCTAssertTrue(model.hasPendingSave)
        XCTAssertEqual(model.journey?.offers, [original])
        let blocked = await model.saveReviewedOffer(try offer(lineID: lineID), journeyID: journeyID, original: nil)
        let replay = await model.retrySave()
        XCTAssertFalse(blocked); XCTAssertFalse(replay); XCTAssertEqual(model.journey?.offers, [original])
        let reopened = PickupModel(databaseURL: url); await reopened.load()
        XCTAssertEqual(reopened.journey?.offers, [original])
    }

    @MainActor func testCopyEventsRequireExactReviewedOfferAndJourneyAndReplayOnce() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try ComparisonStore(url: url), model = try await placed(store: store)
        let journeyID = try XCTUnwrap(model.journey?.id), lineID = try XCTUnwrap(model.journey?.pickup?.orderLines.first?.id)
        let original = try offer(lineID: lineID)
        _ = await model.saveReviewedOffer(original, journeyID: journeyID, original: nil)
        let action = PickupOfferAction(id: UUID(), offerID: original.id, kind: .copyAttempted, occurredAt: now)
        let first = await model.recordReviewedOfferAction(action, offer: original, journeyID: journeyID)
        let again = await model.recordReviewedOfferAction(action, offer: original, journeyID: journeyID)
        let wrong = await model.recordReviewedOfferAction(action, offer: original, journeyID: UUID())
        XCTAssertTrue(first); XCTAssertTrue(again); XCTAssertFalse(wrong)
        var updated = original; updated.householdPreference = "Changed"
        _ = await model.saveReviewedOffer(updated, journeyID: journeyID, original: original)
        let stale = await model.recordReviewedOfferAction(PickupOfferAction(id: UUID(), offerID: original.id, kind: .copied, occurredAt: now), offer: original, journeyID: journeyID)
        XCTAssertFalse(stale); XCTAssertEqual(model.journey?.offerActions, [action])
    }

    func testCeilingEvidenceNeverConvertsUnknownToZeroOrConditionalToAffordable() throws {
        let limit = Money(minorUnits: 500)
        XCTAssertEqual(try PickupOfferReview.assess(price: .exact(limit), ceiling: limit), .within)
        XCTAssertEqual(try PickupOfferReview.assess(price: .exact(Money(minorUnits: 501)), ceiling: limit), .over)
        XCTAssertEqual(try PickupOfferReview.assess(price: .bounded(lower: .zero, upper: limit, reason: "Range"), ceiling: limit), .within)
        XCTAssertEqual(try PickupOfferReview.assess(price: .bounded(lower: Money(minorUnits: 501), upper: Money(minorUnits: 800), reason: "Range"), ceiling: limit), .over)
        XCTAssertEqual(try PickupOfferReview.assess(price: .bounded(lower: limit, upper: Money(minorUnits: 800), reason: "Range"), ceiling: limit), .conditional)
        XCTAssertEqual(try PickupOfferReview.assess(price: .unknown(reason: "Awaiting store"), ceiling: limit), .unknown)
        XCTAssertEqual(try PickupOfferReview.assess(price: .unknown(reason: "Awaiting store"), ceiling: nil), .noCeiling)
        XCTAssertThrowsError(try PickupOfferReview.assess(price: .exact(Money(minorUnits: -1)), ceiling: nil))
        XCTAssertThrowsError(try PickupOfferReview.assess(price: .bounded(lower: limit, upper: .zero, reason: "Range"), ceiling: nil))
        XCTAssertThrowsError(try PickupOfferReview.assess(price: .unknown(reason: " "), ceiling: limit))
        XCTAssertThrowsError(try PickupOfferReview.assess(price: .exact(.zero), ceiling: Money(minorUnits: -1)))
    }

    func testValidationRejectsIncompatibleExcessiveAndUnboundedEvidence() throws {
        let lineID = UUID(), ordered = quantity(8)
        XCTAssertNoThrow(try PickupOfferReview.validate(offer(lineID: lineID), ordered: ordered))
        XCTAssertThrowsError(try PickupOfferReview.validate(offer(lineID: lineID, remaining: 9), ordered: ordered))
        XCTAssertThrowsError(try PickupOfferReview.validate(offer(lineID: lineID, unit: .gram), ordered: ordered))
        XCTAssertThrowsError(try PickupOfferReview.validate(offer(lineID: lineID, remaining: 1_000_000_001), ordered: quantity(2_000_000_000)))
        XCTAssertThrowsError(try PickupOfferReview.validate(offer(lineID: lineID, price: .exact(Money(minorUnits: 1_000_000_000_001))), ordered: ordered))
        var oversized = try offer(lineID: lineID); oversized.householdPreference = String(repeating: "x", count: 2049)
        XCTAssertThrowsError(try PickupOfferReview.validate(oversized, ordered: ordered))
        // Same-dimension explicit unit conversion is permitted, never count-to-mass guessing.
        XCTAssertNoThrow(try PickupOfferReview.validate(offer(lineID: lineID, remaining: 1, unit: .kilogram), ordered: quantity(2_000, .gram)))
        let valid = try offer(lineID: lineID)
        func withQuantities(required: Quantity, remaining: Quantity) -> PickupOffer {
            PickupOffer(id: valid.id, lineID: lineID, replacement: valid.replacement, required: required,
                remainingOriginal: remaining, price: valid.price, ceiling: valid.ceiling,
                deadline: valid.deadline, fallback: valid.fallback, householdPreference: "", retailerResponse: "")
        }
        let maximum = String(repeating: "é", count: 1_024)
        let atLimit = Quantity(amount: try Rational(8), unit: .count, originalLiteral: maximum)
        let overLimit = Quantity(amount: try Rational(8), unit: .count, originalLiteral: maximum + "x")
        XCTAssertNoThrow(try PickupOfferReview.validate(withQuantities(required: atLimit, remaining: atLimit), ordered: atLimit))
        XCTAssertThrowsError(try PickupOfferReview.validate(valid, ordered: overLimit))
        XCTAssertThrowsError(try PickupOfferReview.validate(withQuantities(required: overLimit, remaining: valid.remainingOriginal), ordered: ordered))
        XCTAssertThrowsError(try PickupOfferReview.validate(withQuantities(required: valid.required, remaining: overLimit), ordered: ordered))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var remaining = try XCTUnwrap(json["remainingOriginal"] as? [String: Any])
        remaining["amount"] = ["numerator": -1, "denominator": 1]
        json["remainingOriginal"] = remaining
        XCTAssertThrowsError(try JSONDecoder().decode(PickupOffer.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try RetailerDeadline(cutoff: .distantFuture, timeZoneID: "Not/AZone"))
        XCTAssertThrowsError(try RetailerDeadline(cutoff: Date(timeIntervalSince1970: .infinity), timeZoneID: "UTC"))
    }
}
