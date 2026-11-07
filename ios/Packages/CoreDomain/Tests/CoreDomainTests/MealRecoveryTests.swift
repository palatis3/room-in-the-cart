import XCTest
@testable import CoreDomain

final class MealRecoveryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_434_400)
    func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: "\(n)") }
    func ingredient(_ n: Int, food: Int, name: String, amount: Int64, group: UUID?, protected: Bool = false) -> RecoveryIngredient {
        .init(ingredientID: id(n + 1_000), groupID: group, foodName: name,
              need: .init(id: id(n), foodID: id(food), name: name, amount: q(amount), priority: protected ? .protected : .required))
    }
    func meal(_ n: Int, revision: Int, title: String, ingredients: [RecoveryIngredient], template: Int,
              minutes: Int? = 20, lead: Int? = 20, completed: Bool = false) throws -> RecoveryMeal {
        .init(id: id(n), revisionID: id(revision), templateID: id(template), templateVersion: 1, title: title,
              servings: try Rational(4), ingredients: ingredients,
              scheduledDay: try MealDay(year: 2026, month: 11, day: n == 1 ? 10 : 11, timeZoneIdentifier: "America/New_York"),
              due: now.addingTimeInterval(TimeInterval((n == 1 ? -86_400 : 0) + 45 * 60)), timeZoneID: "America/New_York", exclusions: ["garlic"],
              remainingElapsedMinutes: minutes, requiredLeadMinutes: lead, advanceStepsCompleted: completed)
    }
    struct Fixture {
        let basket: BasketPlan
        let pickup: PickupLedger
        let settlement: SettlementLedger
        let templates: [MealTemplate]
        var state: MealRecoveryState
        var stock: [RecoveryStockEvidence]
        let tuesday: RecoveryMeal
        let wednesday: RecoveryMeal
        let lunch: StockNeed
    }
    func fixture(beanAmount: Int64 = 4, beansAvailableAt: Date? = nil, outside: [StockNeed] = []) throws -> Fixture {
        let wraps = id(100), shop = id(200)
        var basket = try BasketPlan(id: shop, revisionID: id(201),
            lines: [.init(id: wraps, name: "Wraps", quantity: q(16), expectedCost: .exact(.init(minorUnits: 500)))], createdAt: now)
        let snapshot = try basket.freeze(snapshotID: id(202), expectedRevision: basket.current.id, at: now)
        let placement = ReportedPlacement(id: id(203), intentID: id(204), snapshotID: snapshot.id, reportedAt: now)
        try basket.reportPlaced(placement)
        var pickup = try PickupLedger(orderID: placement.id, orderLines: [.init(id: wraps, branchID: "Main", name: "Wraps", ordered: q(16))])
        let key = ReceiptKey(sourceEventID: "arrival-one", orderLineID: wraps, branchID: "Main", segmentID: "first")
        let receipt = ReceiptFragment(key: key, itemName: "Wraps", received: q(8), disposition: .partial, receivedAt: now)
        try pickup.receive(receipt)
        let usable = UsableObservation(id: id(205), receipt: key, usable: q(6), confirmedAt: now,
                                      supersedesID: nil, confirmedMatchToOrderLine: true)
        try pickup.confirmUsable(usable)
        var settlement = SettlementLedger()
        try settlement.append(.init(id: id(206), evidenceKey: "posted-charge", kind: .postedCharge,
            amount: .init(minorUnits: 3720), occurredAt: now))
        try settlement.append(.init(id: id(207), evidenceKey: "pending-credit", kind: .pendingCredit,
            amount: .init(minorUnits: 240), occurredAt: now, creditID: "missing-wraps", chargeEvidenceKey: "posted-charge"))
        let tuesday = try meal(1, revision: 11, title: "Tuesday tacos",
            ingredients: [ingredient(31, food: 100, name: "Tuesday wraps", amount: 6, group: id(301))], template: 401)
        let wednesday = try meal(2, revision: 12, title: "Wednesday quesadillas",
            ingredients: [ingredient(32, food: 100, name: "Wednesday wraps", amount: 4, group: id(302))], template: 402)
        let lunch = StockNeed(id: id(33), foodID: wraps, name: "Protected lunch", amount: q(2), priority: .protected)
        let state = try MealRecoveryState(shopID: shop, originalRevisionID: id(210), originalMeals: [tuesday, wednesday], outsideDemands: [lunch] + outside)
        let stock = [RecoveryStockEvidence(lot: .init(id: usable.id, foodID: wraps, name: receipt.itemName,
            usable: usable.usable, confirmedAt: usable.confirmedAt), availableAt: receipt.receivedAt),
            RecoveryStockEvidence(lot: .init(id: id(208), foodID: id(101), name: "Beans", usable: q(beanAmount),
                confirmedAt: now, source: .freezer), availableAt: beansAvailableAt ?? now)]
        let templates = [MealTemplate(id: id(401), title: "Tacos", ingredients: [.init(id: id(501), name: "Wraps", quantity: q(6))]),
                         MealTemplate(id: id(402), title: "Quesadillas", ingredients: [.init(id: id(502), name: "Wraps", quantity: q(4))])]
        return Fixture(basket: basket, pickup: pickup, settlement: settlement, templates: templates, state: state,
                       stock: stock, tuesday: tuesday, wednesday: wednesday, lunch: lunch)
    }
    func replacement(_ target: RecoveryMeal, revision: Int = 50, need: Int = 51, template: UUID? = nil,
                     food: Int = 101, name: String = "Beans", amount: Int64 = 4, minutes: Int? = 20,
                     lead: Int? = 20, completed: Bool = false, ingredients: [RecoveryIngredient]? = nil,
                     due: Date? = nil, exclusions: [String]? = nil) -> RecoveryMeal {
        .init(id: target.id, revisionID: id(revision), templateID: template ?? id(403), templateVersion: 1,
              title: "Wednesday bean dinner", servings: target.servings,
              ingredients: ingredients ?? [ingredient(need, food: food, name: name, amount: amount, group: target.ingredients[0].groupID)],
              scheduledDay: target.scheduledDay, due: due ?? target.due, timeZoneID: target.timeZoneID,
              exclusions: exclusions ?? target.exclusions, remainingElapsedMinutes: minutes,
              requiredLeadMinutes: lead, advanceStepsCompleted: completed)
    }
    func request(_ state: MealRecoveryState, target: RecoveryMeal, replacement: RecoveryMeal, operation: Int = 60,
                 repeatOK: Bool = false, trip: Bool = false, tripOK: Bool = false, unresolvedOK: Bool = false) throws -> MealRecoveryRequest {
        .init(id: id(operation), shopID: state.shopID, baseRevisionID: try MealRecoveryEngine.project(state).revisionID,
              target: target, replacement: replacement, reviewedAt: now, agreesToRepeat: repeatOK,
              proposesExtraTrip: trip, agreesToExtraTrip: tripOK, acceptsUnresolved: unresolvedOK)
    }
    func preview(_ request: MealRecoveryRequest, _ f: Fixture, at: Date? = nil,
                 reservations: [ConfirmedStockReservation] = []) throws -> MealRecoveryReview {
        try MealRecoveryEngine.preview(request, in: f.state, stockEvidence: f.stock, reservations: reservations, at: at ?? now)
    }
    func testSixFourTwoWrapRecoveryReplacesOnlyWednesdayAndPreservesHistoryCancelReplayAndRestart() throws {
        var f = try fixture(); let original = f
        let change = try request(f.state, target: f.wednesday, replacement: replacement(f.wednesday))
        let review = try preview(change, f)
        XCTAssertEqual(review.beforeAllocation.demands.map(\.allocated), [try Rational(4), .zero, try Rational(2)])
        XCTAssertEqual(review.beforeAllocation.demands.map(\.shortfall), [try Rational(2), try Rational(4), .zero])
        XCTAssertEqual(f.state, original.state, "Preparing then dropping a review has zero mutation")
        XCTAssertTrue(review.feasible)
        XCTAssertEqual(review.after.meals.map(\.id), [f.tuesday.id, f.wednesday.id])
        XCTAssertEqual(review.after.meals[0], f.tuesday)
        XCTAssertEqual(review.after.demands.last, f.lunch)
        XCTAssertEqual(review.afterAllocation.demands.map(\.allocated), [try Rational(4), try Rational(4), try Rational(2)])
        XCTAssertEqual(review.afterAllocation.demands.map(\.shortfall), [try Rational(2), .zero, .zero])
        let event = try MealRecoveryEngine.apply(review, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        XCTAssertEqual(f.state.events, [event]); XCTAssertEqual(event.request, change)
        XCTAssertEqual(f.state.originalMeals, original.state.originalMeals)
        XCTAssertEqual(f.state.outsideDemands, original.state.outsideDemands)
        XCTAssertEqual(try MealRecoveryEngine.project(f.state), review.after)
        XCTAssertFalse(review.after.demands.contains { $0.id == f.wednesday.needs[0].id })
        XCTAssertEqual(f.basket, original.basket); XCTAssertEqual(f.basket.phase, .reportedPlaced)
        XCTAssertEqual(f.pickup, original.pickup); XCTAssertEqual(f.pickup.receipts[0].received, q(8))
        XCTAssertEqual(f.settlement, original.settlement); XCTAssertEqual(try f.settlement.summary().paidSoFar.minorUnits, 3720)
        XCTAssertEqual(f.templates, original.templates); XCTAssertEqual(f.stock, original.stock)
        let committed = f.state
        XCTAssertEqual(try MealRecoveryEngine.apply(review, to: &f.state, stockEvidence: [], reservations: [], at: now.addingTimeInterval(1)), event)
        XCTAssertEqual(f.state, committed)
        let decoded = try JSONDecoder().decode(MealRecoveryState.self, from: JSONEncoder().encode(f.state))
        XCTAssertEqual(decoded, committed); XCTAssertEqual(try MealRecoveryEngine.project(decoded), review.after)
    }
    func testRepeatedReplacementUsesCurrentWholeTargetAndRejectsSameOperationDifferentContent() throws {
        var f = try fixture(); let original = f
        let first = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday)), f)
        try MealRecoveryEngine.apply(first, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        let one = f.state, current = first.after.meals[1]
        let secondRequest = try request(f.state, target: current,
            replacement: replacement(current, revision: 70, need: 71), operation: 72, repeatOK: true)
        let second = try preview(secondRequest, f)
        XCTAssertTrue(second.repeatRequired)
        try MealRecoveryEngine.apply(second, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        XCTAssertEqual(f.state.events.count, 2)
        XCTAssertEqual(try MealRecoveryEngine.project(f.state).demands.map(\.id), [id(31), id(71), id(33)])
        let two = f.state
        let stale = try request(f.state, target: f.wednesday, replacement: replacement(f.wednesday, revision: 80, need: 81), operation: 82)
        XCTAssertThrowsError(try preview(stale, f)) { XCTAssertEqual($0 as? MealRecoveryError, .stale) }
        let conflicting = try preview(request(original.state, target: original.wednesday,
            replacement: replacement(original.wednesday, revision: 80, need: 81)), original)
        XCTAssertThrowsError(try MealRecoveryEngine.apply(conflicting, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .operationConflict)
        }
        XCTAssertEqual(f.state, two)
        var changedBasis = original
        changedBasis.stock[1] = RecoveryStockEvidence(lot: .init(id: id(208), foodID: id(101), name: "Beans",
            usable: q(5), confirmedAt: now, source: .freezer), availableAt: now)
        let sameRequestNewBasis = try preview(first.request, changedBasis)
        XCTAssertThrowsError(try MealRecoveryEngine.apply(sameRequestNewBasis, to: &f.state,
            stockEvidence: changedBasis.stock, reservations: [], at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .operationConflict)
        }
        XCTAssertEqual(f.state, two)
        XCTAssertEqual(try MealRecoveryEngine.apply(first, to: &f.state, stockEvidence: f.stock, reservations: [], at: now), one.events[0])
        XCTAssertEqual(f.state, two)
    }
    func testWholeTargetProtectedGroupsDueAndExclusionsCannotBeDroppedOrBorrowIdentities() throws {
        var f = try fixture()
        let protected = ingredient(35, food: 100, name: "Protected Wednesday lunch", amount: 2, group: id(305), protected: true)
        let originalTarget = replacement(f.wednesday, revision: 90, need: 91,
            ingredients: f.wednesday.ingredients + [protected])
        f.state = try MealRecoveryState(shopID: f.state.shopID, originalRevisionID: id(210),
            originalMeals: [f.tuesday, originalTarget], outsideDemands: [])
        let valid = replacement(originalTarget, revision: 92, need: 93,
            ingredients: [ingredient(93, food: 101, name: "Beans", amount: 4, group: id(302)), protected])
        XCTAssertTrue(try preview(request(f.state, target: originalTarget, replacement: valid, repeatOK: true), f).feasible)
        let before = f.state
        let dropping = replacement(originalTarget, revision: 94, need: 95)
        XCTAssertThrowsError(try preview(request(f.state, target: originalTarget, replacement: dropping), f))
        let borrowed = replacement(originalTarget, revision: 94, ingredients: [f.tuesday.ingredients[0], protected])
        XCTAssertThrowsError(try preview(request(f.state, target: originalTarget, replacement: borrowed), f))
        let laterDue = replacement(originalTarget, revision: 94, ingredients: valid.ingredients, due: now.addingTimeInterval(7200))
        XCTAssertThrowsError(try preview(request(f.state, target: originalTarget, replacement: laterDue), f))
        let droppedRule = replacement(originalTarget, revision: 94, ingredients: valid.ingredients, exclusions: [])
        XCTAssertThrowsError(try preview(request(f.state, target: originalTarget, replacement: droppedRule), f))
        // A target carrying only one ingredient cannot replace the complete current version.
        XCTAssertThrowsError(try preview(request(f.state, target: dropping, replacement: valid), f)) {
            XCTAssertEqual($0 as? MealRecoveryError, .stale)
        }
        XCTAssertEqual(f.state, before)
    }
    func testReplacementCannotConsumeAnotherNeedAndFivePortionsDoNotCoverFourPlusTwoProtected() throws {
        let other = StockNeed(id: id(80), foodID: id(101), name: "Thursday beans", amount: q(2), priority: .required)
        var f = try fixture(outside: [other])
        let before = f.state
        XCTAssertThrowsError(try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday)), f)) {
            XCTAssertEqual($0 as? MealRecoveryError, .protectedAllocation)
        }
        XCTAssertEqual(f.state, before)
        let protected = StockNeed(id: id(80), foodID: id(101), name: "Two protected lunches", amount: q(2), priority: .protected)
        f = try fixture(beanAmount: 5, outside: [protected])
        let review = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday)), f)
        XCTAssertFalse(review.feasible)
        XCTAssertEqual(review.afterAllocation.demands.first { $0.id == id(51) }?.shortfall, try Rational(1))
        XCTAssertEqual(review.afterAllocation.demands.first { $0.id == protected.id }?.allocated, try Rational(2))
        let unchanged = f.state
        XCTAssertThrowsError(try MealRecoveryEngine.apply(review, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .unresolved)
        }
        XCTAssertEqual(f.state, unchanged)
        // Same supply with a concrete pinned other need keeps its exact lot edges.
        let pinned = try fixture(beanAmount: 6, outside: [other])
        let pin = ConfirmedStockReservation(needID: other.id, lotID: id(208))
        let pinnedReview = try preview(request(pinned.state, target: pinned.wednesday, replacement: replacement(pinned.wednesday)), pinned, reservations: [pin])
        XCTAssertTrue(pinnedReview.feasible)
        XCTAssertEqual(pinnedReview.beforeAllocation.allocations.filter { $0.needID == other.id },
                       pinnedReview.afterAllocation.allocations.filter { $0.needID == other.id })
    }
    func testFutureArrivalEvidenceStaysUnusableUntilInstantAndStalesAnExistingReview() throws {
        var f = try fixture(beansAvailableAt: now.addingTimeInterval(60))
        let change = try request(f.state, target: f.wednesday, replacement: replacement(f.wednesday), unresolvedOK: true)
        let pending = try preview(change, f)
        XCTAssertFalse(pending.foodConfirmed)
        XCTAssertEqual(pending.afterAllocation.demands.first { $0.id == id(51) }?.shortfall, try Rational(4))
        let before = f.state
        XCTAssertThrowsError(try MealRecoveryEngine.apply(pending, to: &f.state, stockEvidence: f.stock,
            reservations: [], at: now.addingTimeInterval(60))) { XCTAssertEqual($0 as? MealRecoveryError, .stale) }
        XCTAssertEqual(f.state, before)
        let fresh = try preview(change, f, at: now.addingTimeInterval(60))
        XCTAssertTrue(fresh.feasible)
        try MealRecoveryEngine.apply(fresh, to: &f.state, stockEvidence: f.stock, reservations: [], at: now.addingTimeInterval(60))
        XCTAssertEqual(try JSONDecoder().decode(MealRecoveryState.self, from: JSONEncoder().encode(f.state)), f.state)
        // Historical decoding does not invent a current wall-clock cutoff.
        XCTAssertEqual(f.state.events[0].stockEvidence, f.stock)
    }
    func testTopUpAndRepeatConsentNeverInventFoodOrAcknowledgedCoverage() throws {
        var f = try fixture(beanAmount: 0)
        let noConsent = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday), trip: true, unresolvedOK: true), f)
        let before = f.state
        XCTAssertThrowsError(try MealRecoveryEngine.apply(noConsent, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .consentRequired)
        }
        XCTAssertEqual(f.state, before)
        let agreed = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday),
            trip: true, tripOK: true, unresolvedOK: true), f)
        XCTAssertFalse(agreed.foodConfirmed)
        try MealRecoveryEngine.apply(agreed, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        XCTAssertEqual(agreed.afterAllocation.demands.first { $0.id == id(51) }?.shortfall, try Rational(4))
        XCTAssertEqual(f.stock[1].lot.usable, q(0)); XCTAssertEqual(f.pickup.receipts.count, 1)
        var repeated = try fixture()
        let repeatRequest = try request(repeated.state, target: repeated.wednesday,
            replacement: replacement(repeated.wednesday, template: repeated.tuesday.templateID))
        let repeatReview = try preview(repeatRequest, repeated)
        XCTAssertTrue(repeatReview.repeatRequired)
        XCTAssertThrowsError(try MealRecoveryEngine.apply(repeatReview, to: &repeated.state, stockEvidence: repeated.stock, reservations: [], at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .consentRequired)
        }
        let permitted = try preview(request(repeated.state, target: repeated.wednesday,
            replacement: replacement(repeated.wednesday, template: repeated.tuesday.templateID), repeatOK: true), repeated)
        try MealRecoveryEngine.apply(permitted, to: &repeated.state, stockEvidence: repeated.stock, reservations: [], at: now)
        XCTAssertEqual(repeated.state.events.count, 1)
    }
    func testPreparationLeadAndClockBoundaryRemainConditionalWithoutChangingSavedDeadline() throws {
        var f = try fixture()
        let needsAdvance = try preview(request(f.state, target: f.wednesday,
            replacement: replacement(f.wednesday, minutes: 20, lead: 120)), f)
        XCTAssertFalse(needsAdvance.timingConfirmed)
        XCTAssertEqual(needsAdvance.after.meals[1].due, f.wednesday.due)
        XCTAssertThrowsError(try MealRecoveryEngine.apply(needsAdvance, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)) {
            XCTAssertEqual($0 as? MealRecoveryError, .unresolved)
        }
        let complete = try preview(request(f.state, target: f.wednesday,
            replacement: replacement(f.wednesday, minutes: 20, lead: 120, completed: true)), f)
        XCTAssertTrue(complete.timingConfirmed)
        XCTAssertThrowsError(try MealRecoveryEngine.apply(complete, to: &f.state, stockEvidence: f.stock,
            reservations: [], at: now.addingTimeInterval(26 * 60))) { XCTAssertEqual($0 as? MealRecoveryError, .stale) }
        XCTAssertTrue(f.state.events.isEmpty)
        let unknown = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday, minutes: nil)), f)
        XCTAssertFalse(unknown.timingConfirmed)
    }
    func testDecodedHistoryRejectsDuplicateOperationBrokenLineageAndForgedWholeTarget() throws {
        var f = try fixture()
        let review = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday)), f)
        try MealRecoveryEngine.apply(review, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(f.state)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let event = try XCTUnwrap((valid["events"] as? [[String: Any]])?.first)
        var duplicate = valid; duplicate["events"] = [event, event]
        XCTAssertThrowsError(try JSONDecoder().decode(MealRecoveryState.self, from: JSONSerialization.data(withJSONObject: duplicate)))
        var request = try XCTUnwrap(event["request"] as? [String: Any])
        request["baseRevisionID"] = id(999).uuidString
        var brokenEvent = event; brokenEvent["request"] = request
        var broken = valid; broken["events"] = [brokenEvent]
        XCTAssertThrowsError(try JSONDecoder().decode(MealRecoveryState.self, from: JSONSerialization.data(withJSONObject: broken)))
        request = try XCTUnwrap(event["request"] as? [String: Any])
        var target = try XCTUnwrap(request["target"] as? [String: Any]); target["ingredients"] = []
        request["target"] = target; brokenEvent["request"] = request; broken["events"] = [brokenEvent]
        XCTAssertThrowsError(try JSONDecoder().decode(MealRecoveryState.self, from: JSONSerialization.data(withJSONObject: broken)))
        XCTAssertEqual(try encoder.encode(f.state), data)
    }
    func testOutsideAllocationComparisonUsesExactUnitsAndStillRejectsTakingItsFood() throws {
        let other = StockNeed(id: id(80), foodID: id(101), name: "Thursday beans",
            amount: .init(amount: try Rational(500), unit: .gram, originalLiteral: "500 g"), priority: .required)
        var f = try fixture(outside: [other])
        func supply(_ grams: Int64) -> RecoveryStockEvidence {
            .init(lot: .init(id: id(208), foodID: id(101), name: "Beans",
                usable: .init(amount: try! Rational(grams), unit: .gram, originalLiteral: "\(grams) g"),
                confirmedAt: now, source: .freezer), availableAt: now)
        }
        f.stock[1] = supply(1500)
        let kilogram = RecoveryIngredient(ingredientID: id(1051), groupID: id(302), foodName: "Beans",
            need: .init(id: id(51), foodID: id(101), name: "Beans",
                amount: .init(amount: .one, unit: .kilogram, originalLiteral: "1 kg"), priority: .required))
        let change = try request(f.state, target: f.wednesday,
            replacement: replacement(f.wednesday, ingredients: [kilogram]))
        let review = try preview(change, f)
        XCTAssertTrue(review.feasible)
        XCTAssertEqual(review.beforeAllocation.demands.first { $0.id == other.id }?.allocated, try Rational(500))
        XCTAssertEqual(review.beforeAllocation.demands.first { $0.id == other.id }?.unit, .gram)
        XCTAssertEqual(review.afterAllocation.demands.first { $0.id == other.id }?.allocated, try Rational(1, 2))
        XCTAssertEqual(review.afterAllocation.demands.first { $0.id == other.id }?.unit, .kilogram)
        let baseline = f.state
        f.stock[1] = supply(1000)
        XCTAssertThrowsError(try preview(change, f)) { XCTAssertEqual($0 as? MealRecoveryError, .protectedAllocation) }
        XCTAssertEqual(f.state, baseline)
    }

}
