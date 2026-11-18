import XCTest
@testable import CoreDomain

final class CanonicalRecoveryAllocationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_434_400)
    func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: "\(n)") }
    func need(_ n: Int, food: Int = 100, amount: Int64 = 4, protected: Bool = false) -> StockNeed {
        .init(id: id(n), foodID: id(food), name: "Food \(n)", amount: q(amount), priority: protected ? .protected : .required)
    }
    func meal(_ n: Int, revision: Int, needs: [StockNeed]) throws -> RecoveryMeal {
        .init(id: id(n), revisionID: id(revision), templateID: nil, templateVersion: nil, title: "Dinner",
            servings: try Rational(2), ingredients: needs.map { .init(ingredientID: $0.id, groupID: id(300), foodName: "Beans", need: $0) },
            scheduledDay: nil, due: now.addingTimeInterval(3_600), timeZoneID: "UTC", exclusions: ["garlic"],
            remainingElapsedMinutes: 10, requiredLeadMinutes: 10, advanceStepsCompleted: false)
    }
    func lot(_ n: Int = 10, food: Int = 100, count: InventoryCount? = nil, name: String = "Beans", receipt: Bool = false) -> InventoryLot {
        .init(id: id(n), foodID: id(food), name: name,
            source: receipt ? .receipt(originID: id(1), key: .init(sourceEventID: "arrival", orderLineID: id(food), branchID: "shop", segmentID: "one")) : .manual(originID: id(1), sourceID: id(n)),
            revision: 1, location: .cupboard, unit: .count, count: count ?? .exact(q(4)), observationID: id(n + 1_000),
            confirmedAt: now, updatedAt: now)
    }
    func claim(_ n: Int, need: StockNeed, pin: UUID? = nil, state: InventoryReservationState = .active) -> InventoryReservation {
        .init(id: id(n), originID: id(1), revision: 3, foodID: need.foodID, lotID: pin,
            name: need.name, amount: need.amount, priority: need.priority, state: state)
    }
    struct Fixture { var state: MealRecoveryState; let request: MealRecoveryRequest; let old: StockNeed; let new: StockNeed }
    func fixture(protected: StockNeed? = nil, oldFood: Int = 100) throws -> Fixture {
        let old = need(20, food: oldFood), new = need(21)
        let target = try meal(2, revision: 3, needs: [old] + (protected.map { [$0] } ?? []))
        let replacement = try meal(2, revision: 4, needs: [new] + (protected.map { [$0] } ?? []))
        let state = try MealRecoveryState(shopID: id(5), originalRevisionID: id(6), originalMeals: [target], outsideDemands: [])
        let request = MealRecoveryRequest(id: id(7), shopID: id(5), baseRevisionID: id(6), target: target, replacement: replacement, reviewedAt: now)
        return .init(state: state, request: request, old: old, new: new)
    }
    func proof(_ f: Fixture, lots: [InventoryLot]? = nil, claims: [InventoryReservation]? = nil,
               bindings: [CanonicalRecoveryAllocation.Binding]? = nil, inventoryRevision: Int64 = 8,
               status: LedgerCanonicalPackStockEvidence.LotEligibility.Status = .eligible) throws -> CanonicalRecoveryAllocation {
        let lots = lots ?? [lot()]
        return try .review(basis: .init(originID: id(1), inventoryRevision: inventoryRevision,
            sourceHeads: [.init(journeyID: id(5), revision: 2), .init(journeyID: id(9), revision: 1)]),
            journeyRevision: 1, lots: lots, claims: claims ?? [claim(40, need: f.old)],
            bindings: bindings ?? [.init(needID: f.old.id, reservationID: id(40))],
            replacementBindings: [.init(needID: f.new.id, reservationID: id(41))],
            eligibility: lots.map { lot in .init(lotID: lot.id, source: lot.source, observationID: lot.observationID,
                status: status, receiptEvidenceDigest: { if case .receipt = lot.source { return Data(repeating: 1, count: 32) }; return nil }()) }, at: now)
    }

    func testOwnClaimCanBeReplacedWhenGlobalFreeIsZeroAndHistoricalReplayIsStable() throws {
        var f = try fixture(); let evidence = try proof(f)
        let original = try InventoryProjection.build(originID: id(1), lots: evidence.lots, reservations: evidence.claims, at: now)
        XCTAssertEqual(original.lots.first?.free?.amount, .zero)
        let review = try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)
        XCTAssertTrue(review.feasible)
        XCTAssertEqual(review.afterAllocation.demands.first?.allocated, try Rational(4))
        let expected = try XCTUnwrap(review.canonicalAfterClaims)
        XCTAssertEqual(expected.first { $0.id == id(40) }?.state, .released)
        XCTAssertEqual(expected.first { $0.id == id(40) }?.revision, 4)
        XCTAssertEqual(expected.first { $0.id == id(41) }?.revision, 1)
        let event = try MealRecoveryEngine.apply(review, to: &f.state, canonicalAllocation: evidence, at: now)
        let bytes = try JSONEncoder().encode(f.state)
        let reopened = try JSONDecoder().decode(MealRecoveryState.self, from: bytes)
        XCTAssertEqual(reopened, f.state)
        let recounted = try proof(f, lots: [lot(count: .exact(q(0)))], inventoryRevision: 9)
        XCTAssertEqual(try MealRecoveryEngine.apply(review, to: &f.state, canonicalAllocation: recounted, at: now.addingTimeInterval(60)), event)
        XCTAssertEqual(f.state.events.count, 1)
    }

    func testExternalProtectedBackingSurvivesAndCannotBeCountedAgain() throws {
        let f = try fixture(), other = need(60, amount: 4, protected: true)
        let held = claim(61, need: other, pin: id(10))
        let evidence = try proof(f, claims: [claim(40, need: f.old), held])
        let review = try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)
        XCTAssertFalse(review.foodConfirmed)
        XCTAssertEqual(review.afterAllocation.demands.first?.shortfall, try Rational(4))
        XCTAssertEqual(review.canonicalAfterClaims?.first { $0.id == held.id }, held)
        var state = f.state
        XCTAssertThrowsError(try MealRecoveryEngine.apply(review, to: &state, canonicalAllocation: evidence, at: now))
        XCTAssertEqual(state, f.state)
    }

    func testProtectedTargetIngredientIsRetainedExactlyAlongsideReplacement() throws {
        let protected = need(70, food: 101, amount: 2, protected: true)
        let f = try fixture(protected: protected), held = claim(71, need: protected, pin: id(11))
        let evidence = try proof(f, lots: [lot(), lot(11, food: 101, count: .exact(q(2)))],
            claims: [claim(40, need: f.old), held], bindings: [.init(needID: f.old.id, reservationID: id(40)), .init(needID: protected.id, reservationID: held.id)])
        let review = try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)
        XCTAssertTrue(review.foodConfirmed)
        XCTAssertEqual(review.canonicalAfterClaims?.first { $0.id == held.id }, held)
        XCTAssertEqual(review.afterAllocation.allocations.first { $0.needID == protected.id }?.lotID, id(11))
    }

    func testTargetPinAndUnresolvedClaimCannotBeReleasedEvenWithConsent() throws {
        let f = try fixture()
        for held in [claim(40, need: f.old, pin: id(10)), claim(40, need: f.old, state: .unresolved)] {
            let evidence = try proof(f, claims: [held])
            XCTAssertThrowsError(try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)) {
                XCTAssertEqual($0 as? MealRecoveryError, .protectedAllocation)
            }
        }
    }

    func testUnknownCountAndIneligibleReceiptNeverConfirmReplacement() throws {
        let f = try fixture()
        for evidence in [try proof(f, lots: [lot(count: .haveEnough)]),
                         try proof(f, lots: [lot(receipt: true)], status: .ineligible)] {
            var state = f.state
            let review = try MealRecoveryEngine.preview(f.request, in: state, canonicalAllocation: evidence, at: now)
            XCTAssertFalse(review.foodConfirmed)
            XCTAssertNil(review.afterAllocation.demands.first?.allocated)
            let accepted = review.confirming(repeatMeal: false, extraTrip: false, unresolved: true)
            _ = try MealRecoveryEngine.apply(accepted, to: &state, canonicalAllocation: evidence, at: now)
            XCTAssertEqual(state.events.count, 1)
        }
    }

    func testExternalUnresolvedHoldIsPreservedAndAffectedUnknownPartitionRefused() throws {
        let f = try fixture(), otherFood = need(80, food: 102)
        let held = claim(81, need: otherFood, state: .unresolved)
        let evidence = try proof(f, claims: [claim(40, need: f.old), held])
        let review = try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)
        XCTAssertEqual(review.canonicalAfterClaims?.first { $0.id == held.id }, held)
        let sameFood = claim(82, need: need(83), state: .unresolved)
        XCTAssertThrowsError(try MealRecoveryEngine.preview(f.request, in: f.state,
            canonicalAllocation: proof(f, claims: [claim(40, need: f.old), sameFood]), at: now))
    }

    func testChangedBasisOrCountsRejectUncommittedReviewWithoutMutation() throws {
        let f = try fixture(), evidence = try proof(f)
        let review = try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)
        for changed in [try proof(f, inventoryRevision: 9), try proof(f, lots: [lot(count: .exact(q(0)))])] {
            var state = f.state
            XCTAssertThrowsError(try MealRecoveryEngine.apply(review, to: &state, canonicalAllocation: changed, at: now)) {
                XCTAssertEqual($0 as? MealRecoveryError, .stale)
            }
            XCTAssertEqual(state, f.state)
        }
    }

    func testUnknownCanonicalLotNameStillEnforcesSavedExclusion() throws {
        let f = try fixture(), evidence = try proof(f, lots: [lot(count: .unknown, name: "Garlic beans")])
        XCTAssertThrowsError(try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .invalid)
        }
    }

    func testMalformedBindingsEligibilityAndOversizedProofFailClosed() throws {
        let f = try fixture(), evidence = try proof(f)
        XCTAssertThrowsError(try proof(f, claims: [claim(40, need: f.old), claim(40, need: f.old)]))
        XCTAssertThrowsError(try proof(f, bindings: [.init(needID: f.old.id, reservationID: id(99))]).evaluate(
            before: [f.old], after: [f.new], replacedNeedIDs: [f.old.id]))
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(evidence)) as? [String: Any])
        json["eligibility"] = []
        let altered = try JSONDecoder().decode(CanonicalRecoveryAllocation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try altered.validate())
        let huge = (0..<2_000).map { lot(10_000 + $0, food: 102, name: String(repeating: "b", count: 512)) }
        XCTAssertThrowsError(try proof(f, lots: huge)) { XCTAssertEqual($0 as? InventoryError, .capacity) }
    }

    func testReplacementCannotStealAnExternalRequiredClaimByEarlierIdentity() throws {
        let f = try fixture(oldFood: 101), other = need(60)
        // New claim 41 sorts before external claim 61, but the outside promise
        // already owns these four portions. A scoped allocator would miss this.
        let evidence = try proof(f, claims: [claim(40, need: f.old), claim(61, need: other)])
        XCTAssertThrowsError(try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .protectedAllocation)
        }
    }

    func testCommittedOperationRejectsDifferentCanonicalBodyAndMalformedStoredProof() throws {
        var f = try fixture(); let evidence = try proof(f)
        let review = try MealRecoveryEngine.preview(f.request, in: f.state, canonicalAllocation: evidence, at: now)
        _ = try MealRecoveryEngine.apply(review, to: &f.state, canonicalAllocation: evidence, at: now)
        let changed = try proof(f, inventoryRevision: 9)
        let conflictingReview = try MealRecoveryEngine.preview(f.request, in: review.source, canonicalAllocation: changed, at: now)
        XCTAssertThrowsError(try MealRecoveryEngine.apply(conflictingReview, to: &f.state, canonicalAllocation: changed, at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .operationConflict)
        }
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(f.state)) as? [String: Any])
        var events = try XCTUnwrap(json["events"] as? [[String: Any]])
        var proofJSON = try XCTUnwrap(events[0]["canonicalAllocation"] as? [String: Any])
        proofJSON["bindings"] = []
        events[0]["canonicalAllocation"] = proofJSON; json["events"] = events
        XCTAssertThrowsError(try JSONDecoder().decode(MealRecoveryState.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testLegacyEventEncodingOmitsCanonicalFieldAndReopensUnchanged() throws {
        var f = try fixture()
        let stock = [RecoveryStockEvidence(lot: .init(id: id(10), foodID: id(100), name: "Beans", usable: q(4), confirmedAt: now), availableAt: now)]
        let review = try MealRecoveryEngine.preview(f.request, in: f.state, stockEvidence: stock, reservations: [], at: now)
        let event = try MealRecoveryEngine.apply(review, to: &f.state, stockEvidence: stock, reservations: [], at: now)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertNil(json["canonicalAllocation"])
        let reopened = try JSONDecoder().decode(MealRecoveryState.self, from: JSONEncoder().encode(f.state))
        XCTAssertEqual(reopened, f.state)
        XCTAssertNil(reopened.events.first?.canonicalAllocation)
    }
}
