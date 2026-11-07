import XCTest
@testable import CoreDomain

extension MealRecoveryTests {
    func testNewOutsideDemandIsAnExplicitRevisionAndInvalidatesAnOlderReplacementReview() throws {
        var f = try fixture(beanAmount: 5)
        let first = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday)), f)
        try MealRecoveryEngine.apply(first, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        let saved = f.state, current = try MealRecoveryEngine.project(saved)
        let laterReplacement = try preview(request(f.state, target: current.meals[1],
            replacement: replacement(current.meals[1], revision: 80, need: 81), operation: 82, repeatOK: true), f)
        let extra = StockNeed(id: id(83), foodID: id(101), name: "Friday beans", amount: q(1), priority: .required)
        let context = MealRecoveryContextRequest(id: id(84), shopID: saved.shopID, baseRevisionID: current.revisionID,
            revisionID: id(85), change: .appendOutside([extra]), reviewedAt: now)
        let reviewed = try MealRecoveryEngine.previewContext(context, in: saved, at: now)
        XCTAssertEqual(f.state, saved)
        let event = try MealRecoveryEngine.applyContext(reviewed, to: &f.state, at: now)
        XCTAssertEqual(f.state.originalMeals, saved.originalMeals)
        XCTAssertEqual(f.state.outsideDemands, saved.outsideDemands)
        XCTAssertEqual(f.state.events, saved.events)
        XCTAssertEqual(f.state.contextChanges, [event])
        XCTAssertEqual(try MealRecoveryEngine.project(f.state).outsideDemands, saved.outsideDemands + [extra])
        let withExtra = f.state
        XCTAssertThrowsError(try MealRecoveryEngine.apply(laterReplacement, to: &f.state,
            stockEvidence: f.stock, reservations: [], at: now)) { XCTAssertEqual($0 as? MealRecoveryError, .stale) }
        XCTAssertEqual(f.state, withExtra)
        let fresh = try preview(request(f.state, target: current.meals[1],
            replacement: replacement(current.meals[1], revision: 80, need: 81), operation: 82, repeatOK: true), f)
        XCTAssertEqual(fresh.afterAllocation.demands.first { $0.id == extra.id }?.allocated, .one)
        try MealRecoveryEngine.apply(fresh, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        XCTAssertEqual(f.state.events.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(MealRecoveryState.self, from: JSONEncoder().encode(f.state)), f.state)
        XCTAssertEqual(try MealRecoveryEngine.applyContext(reviewed, to: &f.state, at: now), event)
    }
    func testCalendarMovePreservesMealQuantitiesAndSavedDeadlineThroughRecoveryHistory() throws {
        var f = try fixture()
        let first = try preview(request(f.state, target: f.wednesday, replacement: replacement(f.wednesday)), f)
        try MealRecoveryEngine.apply(first, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        let old = try MealRecoveryEngine.project(f.state), baseline = f.state
        let tomorrow = try MealDay(year: 2026, month: 11, day: 12, timeZoneIdentifier: "America/New_York")
        let move = MealRecoveryContextRequest(id: id(80), shopID: f.state.shopID, baseRevisionID: old.revisionID,
            revisionID: id(81), change: .moveMeal(occurrenceID: f.wednesday.id, from: old.meals[1].scheduledDay, to: tomorrow), reviewedAt: now)
        let review = try MealRecoveryEngine.previewContext(move, in: f.state, at: now)
        XCTAssertEqual(review.after.meals[1].ingredients, old.meals[1].ingredients)
        XCTAssertEqual(review.after.meals[1].due, old.meals[1].due, "Moving the date cannot silently extend a saved deadline")
        XCTAssertEqual(review.after.meals[0], old.meals[0])
        XCTAssertEqual(review.after.demands, old.demands)
        XCTAssertEqual(f.state, baseline)
        try MealRecoveryEngine.applyContext(review, to: &f.state, at: now)
        XCTAssertEqual(try MealRecoveryEngine.project(f.state).meals[1].scheduledDay, tomorrow)
        XCTAssertEqual(f.state.originalMeals, baseline.originalMeals)
        let extend = MealRecoveryContextRequest(id: id(82), shopID: f.state.shopID, baseRevisionID: id(81),
            revisionID: id(83), change: .confirmDeadline(occurrenceID: f.wednesday.id, due: now.addingTimeInterval(7200)), reviewedAt: now)
        XCTAssertThrowsError(try MealRecoveryEngine.previewContext(extend, in: f.state, at: now))
        XCTAssertEqual(try JSONDecoder().decode(MealRecoveryState.self, from: JSONEncoder().encode(f.state)), f.state)
    }
    func testUnknownDeadlineCanBeExplicitlyConfirmedAndHistoricalNeedIDsCannotReturn() throws {
        var f = try fixture()
        let meal = f.wednesday
        let unknown = RecoveryMeal(id: meal.id, revisionID: meal.revisionID, templateID: meal.templateID,
            templateVersion: meal.templateVersion, title: meal.title, servings: meal.servings, ingredients: meal.ingredients,
            scheduledDay: meal.scheduledDay, due: nil, timeZoneID: meal.timeZoneID, exclusions: meal.exclusions,
            remainingElapsedMinutes: meal.remainingElapsedMinutes, requiredLeadMinutes: meal.requiredLeadMinutes,
            advanceStepsCompleted: meal.advanceStepsCompleted)
        f.state = try MealRecoveryState(shopID: f.state.shopID, originalRevisionID: f.state.originalRevisionID,
            originalMeals: [f.tuesday, unknown], outsideDemands: [f.lunch])
        let confirm = MealRecoveryContextRequest(id: id(80), shopID: f.state.shopID, baseRevisionID: f.state.originalRevisionID,
            revisionID: id(81), change: .confirmDeadline(occurrenceID: meal.id, due: now.addingTimeInterval(2700)), reviewedAt: now)
        let review = try MealRecoveryEngine.previewContext(confirm, in: f.state, at: now)
        try MealRecoveryEngine.applyContext(review, to: &f.state, at: now)
        let current = try MealRecoveryEngine.project(f.state).meals[1]
        XCTAssertNil(f.state.originalMeals[1].due)
        XCTAssertEqual(current.due, now.addingTimeInterval(2700))
        let repair = try preview(request(f.state, target: current, replacement: replacement(current)), f)
        try MealRecoveryEngine.apply(repair, to: &f.state, stockEvidence: f.stock, reservations: [], at: now)
        let before = f.state
        let reuse = MealRecoveryContextRequest(id: id(82), shopID: f.state.shopID,
            baseRevisionID: try MealRecoveryEngine.project(f.state).revisionID, revisionID: id(83),
            change: .appendOutside(meal.needs), reviewedAt: now)
        XCTAssertThrowsError(try MealRecoveryEngine.previewContext(reuse, in: f.state, at: now))
        XCTAssertEqual(f.state, before)
        // Dropping the optional new field remains compatible with v1 history.
        let plain = try fixture().state
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        json.removeValue(forKey: "contextChanges")
        XCTAssertEqual(try JSONDecoder().decode(MealRecoveryState.self, from: JSONSerialization.data(withJSONObject: json)), plain)
    }
}
