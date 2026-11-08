import XCTest
import CoreDomain
import LocalStore
import SQLite3
@testable import RoomInTheCart

@MainActor final class PickupAmendmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_799_000_000)

    private func quantity(_ amount: Int64) -> Quantity {
        Quantity(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount))
    }

    private func fixture() async throws -> (model: PickupModel, directory: URL, actor: UUID, line: BasketLine) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let instant = now, actor = UUID(), shop = UUID()
        let model = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        let line = BasketLine(id: UUID(), name: "Wraps", quantity: quantity(8), expectedCost: .exact(Money(minorUnits: 300)))
        let context = CheckoutContext(storeID: "Market", branchID: "Main", mode: .pickup, slot: "Tuesday",
            commitmentsID: shop, observedAt: now, source: "Retailer")
        let started = await model.start(from: [line], shopID: shop, context: context, plannedNeeds: [
            AllocationNeed(id: UUID(), orderLineID: line.id, name: "Lunch", amount: quantity(2), priority: .protected),
            AllocationNeed(id: UUID(), orderLineID: line.id, name: "Tacos", amount: quantity(6), priority: .required)
        ])
        XCTAssertTrue(started)
        let quoted = await model.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context,
            pricing: .inclusiveTotal(.exact(Money(minorUnits: 300)))), cap: nil)
        XCTAssertTrue(quoted)
        let frozen = await model.freeze()
        XCTAssertTrue(frozen)
        let placed = await model.reportPlaced(by: actor)
        XCTAssertTrue(placed)
        return (model, directory, actor, line)
    }

    private func review(_ model: PickupModel, actor: UUID, lines: [BasketLine], id: UUID = UUID()) throws -> PickupAmendmentReview {
        let journey = try XCTUnwrap(model.journey)
        let base = try XCTUnwrap(PickupAmendmentBase(journey: journey, workspaceID: model.sourceWorkspaceID, actorID: actor))
        return PickupAmendmentReview(base: base, event: ConfirmedAmendment(id: id, placementID: base.placementID,
            previousAmendmentID: base.predecessor, lines: lines, confirmedAt: now,
            retailerReference: "Retailer confirmation ABC-51", recordedByLocalActorID: actor))
    }

    func testConfirmedChangesPreserveOriginalOrderPhysicalFoodAndCashAcrossRestart() async throws {
        let f = try await fixture()
        let key = ReceiptKey(sourceEventID: "bag", orderLineID: f.line.id, branchID: "Main", segmentID: "one")
        let receipt = ReceiptFragment(key: key, itemName: "Wraps", received: quantity(3), disposition: .partial, receivedAt: now)
        let usable = UsableObservation(id: UUID(), receipt: key, usable: quantity(3), confirmedAt: now, confirmedMatchToOrderLine: true)
        let received = await f.model.receive(receipt, usable: usable)
        XCTAssertTrue(received)
        let before = try XCTUnwrap(f.model.journey), allocation = f.model.allocation
        let beans = BasketLine(id: UUID(), name: "Beans", quantity: quantity(4), expectedCost: .unknown(reason: "Retailer has not priced this line"))
        let correction = try review(f.model, actor: f.actor, lines: [beans])
        let saved = await f.model.confirmRetailerAmendment(correction, currentActor: { f.actor })
        XCTAssertTrue(saved)
        let after = try XCTUnwrap(f.model.journey)
        XCTAssertEqual(after.basket?.reportedOrderLines, [f.line])
        XCTAssertEqual(after.basket?.effectiveOrderLines, [beans])
        XCTAssertEqual(after.basket?.snapshots, before.basket?.snapshots)
        XCTAssertEqual(after.frozenQuotes, before.frozenQuotes)
        XCTAssertEqual(after.pickup?.orderLines.first { $0.id == f.line.id }?.ordered.amount, .zero)
        XCTAssertEqual(after.pickup?.orderLines.first { $0.id == beans.id }?.ordered, beans.quantity)
        XCTAssertEqual(after.pickup?.receipts, [receipt])
        XCTAssertEqual(after.pickup?.usableObservations, [usable])
        XCTAssertEqual(after.settlement, before.settlement)
        XCTAssertEqual(after.needs, before.needs)
        XCTAssertEqual(f.model.allocation, allocation)
        XCTAssertNil(f.model.result, "The original checkout total cannot price the amended order")
        let replay = await f.model.confirmRetailerAmendment(correction, currentActor: { f.actor })
        XCTAssertTrue(replay)
        XCTAssertEqual(f.model.journey, after)
        let reopened = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"))
        await reopened.load()
        XCTAssertEqual(reopened.journey, after)
        let cancelled = try review(f.model, actor: f.actor, lines: [])
        let cancellationSaved = await f.model.confirmRetailerAmendment(cancelled, currentActor: { f.actor })
        XCTAssertTrue(cancellationSaved)
        XCTAssertEqual(f.model.journey?.basket?.effectiveOrderLines, [])
        XCTAssertEqual(f.model.journey?.pickup?.receipts, [receipt])
        XCTAssertEqual(f.model.journey?.basket?.amendments.count, 2)
    }

    func testStaleWrongActorConflictingAndReidentifiedChangesLeaveTheOrderUntouched() async throws {
        let f = try await fixture()
        let line = BasketLine(id: f.line.id, name: f.line.name, quantity: quantity(5), expectedCost: .unknown(reason: "Unpriced"))
        let candidate = try review(f.model, actor: f.actor, lines: [line])
        let before = try XCTUnwrap(f.model.journey)
        let denied = await f.model.confirmRetailerAmendment(candidate, currentActor: { UUID() })
        XCTAssertFalse(denied)
        let renamed = BasketLine(id: f.line.id, name: "Different food", quantity: quantity(5), expectedCost: .exact(.zero))
        let invalid = try review(f.model, actor: f.actor, lines: [renamed])
        let rejectedIdentity = await f.model.confirmRetailerAmendment(invalid, currentActor: { f.actor })
        XCTAssertFalse(rejectedIdentity)
        XCTAssertEqual(f.model.journey, before)
        let saved = await f.model.confirmRetailerAmendment(candidate, currentActor: { f.actor })
        XCTAssertTrue(saved)
        let after = f.model.journey
        let stale = PickupAmendmentReview(base: candidate.base, event: ConfirmedAmendment(id: UUID(), placementID: candidate.base.placementID,
            previousAmendmentID: nil, lines: [], confirmedAt: now, retailerReference: "A competing confirmation", recordedByLocalActorID: f.actor))
        let rejectedStale = await f.model.confirmRetailerAmendment(stale, currentActor: { f.actor })
        XCTAssertFalse(rejectedStale)
        let conflict = PickupAmendmentReview(base: candidate.base, event: ConfirmedAmendment(id: candidate.event.id, placementID: candidate.base.placementID,
            previousAmendmentID: nil, lines: [], confirmedAt: now, retailerReference: "Changed retry", recordedByLocalActorID: f.actor))
        let rejectedConflict = await f.model.confirmRetailerAmendment(conflict, currentActor: { f.actor })
        XCTAssertFalse(rejectedConflict)
        XCTAssertEqual(f.model.journey, after)
    }

    func testBlockedDatabaseRetryRechecksActorAndCommitsOneConfirmation() async throws {
        let f = try await fixture(), before = f.model.journey
        let candidate = try review(f.model, actor: f.actor, lines: [])
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.directory.appendingPathComponent("pickup.sqlite").path, &lock), SQLITE_OK)
        defer { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close(lock); f.model.discardPending() }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        var actor: UUID? = f.actor
        let saved = await f.model.confirmRetailerAmendment(candidate, currentActor: { actor })
        XCTAssertFalse(saved)
        XCTAssertTrue(f.model.hasPendingSave)
        XCTAssertEqual(f.model.journey, before)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        actor = nil
        let denied = await f.model.retrySave()
        XCTAssertFalse(denied)
        actor = f.actor
        let retried = await f.model.confirmRetailerAmendment(candidate, currentActor: { actor })
        XCTAssertTrue(retried)
        XCTAssertFalse(f.model.hasPendingSave)
        XCTAssertEqual(f.model.journey?.basket?.amendments, [candidate.event])
    }

    func testEarlierAmendmentDocumentUpgradesItsOrderProjectionAndRetainsUnknownReporter() async throws {
        let f = try await fixture()
        var earlier = try XCTUnwrap(f.model.journey)
        let placement = try XCTUnwrap(earlier.basket?.placements.first)
        let wraps = BasketLine(id: f.line.id, name: f.line.name, quantity: quantity(5), expectedCost: .exact(.zero))
        let beans = BasketLine(id: UUID(), name: "Beans", quantity: quantity(4), expectedCost: .exact(.zero))
        let amendment = ConfirmedAmendment(id: UUID(), placementID: placement.id, previousAmendmentID: nil,
            lines: [wraps, beans], confirmedAt: now, retailerReference: "Earlier retailer reference")
        try earlier.basket?.confirmAmendment(amendment)
        XCTAssertEqual(earlier.pickup?.orderLines.count, 1)
        let decoded = try JSONDecoder().decode(PickupJourney.self, from: JSONEncoder().encode(earlier))
        try PickupModel.validate(decoded)
        XCTAssertEqual(decoded.pickup?.orderLines.count, 2)
        XCTAssertEqual(decoded.pickup?.orderLines.first { $0.id == wraps.id }?.ordered, wraps.quantity)
        XCTAssertNil(decoded.basket?.amendments.first?.recordedByLocalActorID)
        XCTAssertEqual(decoded.basket?.snapshots, earlier.basket?.snapshots)
        var reordered = decoded
        reordered.pickup = try decoded.pickup?.withOrderLines(Array(try XCTUnwrap(decoded.pickup?.orderLines).reversed()))
        try PickupModel.validate(reordered)
        let roundTrip = try JSONDecoder().decode(PickupJourney.self, from: JSONEncoder().encode(reordered))
        XCTAssertEqual(roundTrip, reordered)
    }

    func testLateRetailerConfirmationCanCorrectAClosedPickupWithoutInventingPaymentOrFood() async throws {
        let f = try await fixture()
        let closedAt = now
        let closed = await f.model.change { $0.closedAt = closedAt }
        XCTAssertTrue(closed)
        let before = try XCTUnwrap(f.model.journey)
        let candidate = try review(f.model, actor: f.actor, lines: [])
        let saved = await f.model.confirmRetailerAmendment(candidate, currentActor: { f.actor })
        XCTAssertTrue(saved)
        XCTAssertEqual(f.model.journey?.closedAt, closedAt)
        XCTAssertEqual(f.model.journey?.settlement, before.settlement)
        XCTAssertEqual(f.model.journey?.pickup?.receipts, before.pickup?.receipts)
        XCTAssertEqual(f.model.journey?.basket?.placements, before.basket?.placements)
    }

    func testCancelledLineKeepsOfferHistoryWithoutNewOffersOrDeadlineReminders() async throws {
        let f = try await fixture()
        func offer() throws -> PickupOffer {
            PickupOffer(id: UUID(), lineID: f.line.id, replacement: "Alternative wraps", required: quantity(2),
                remainingOriginal: quantity(0), price: .exact(.zero), ceiling: nil,
                deadline: try RetailerDeadline(cutoff: now.addingTimeInterval(60), timeZoneID: "UTC"),
                fallback: "Leave unresolved", householdPreference: "Review", retailerResponse: "")
        }
        let original = try offer()
        let saved = await f.model.saveReviewedOffer(original, journeyID: f.model.selectedID!, original: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(f.model.journey?.unfilledOffers(at: now), [original])
        let correction = try review(f.model, actor: f.actor, lines: [])
        let cancelled = await f.model.confirmRetailerAmendment(correction, currentActor: { f.actor })
        XCTAssertTrue(cancelled)
        let after = f.model.journey
        XCTAssertEqual(after?.offers, [original])
        XCTAssertEqual(after?.unfilledOffers(at: now), [])
        XCTAssertEqual(after?.retailerOrderLines, [])
        let replay = await f.model.saveReviewedOffer(original, journeyID: after!.id, original: nil)
        XCTAssertTrue(replay)
        let denied = await f.model.saveReviewedOffer(try offer(), journeyID: after!.id, original: nil)
        XCTAssertFalse(denied)
        XCTAssertEqual(f.model.journey, after)
    }
}
