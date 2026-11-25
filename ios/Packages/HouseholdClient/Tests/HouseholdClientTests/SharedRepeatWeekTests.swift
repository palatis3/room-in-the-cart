import XCTest
@testable import HouseholdClient

final class SharedRepeatWeekTests: XCTestCase {
    func testLiveMenuDistinguishesPendingPresentAndPreviouslyRemovedDinners() {
        let target = UUID(), source = UUID()
        let step = SharedRepeatSeries.Step(targetId: target, sourceId: source, sourceRevision: 2, day: "2026-11-12")
        let meal = SharedMeal(title: "Changed dinner", day: "2026-11-13", kind: "dinner", portions: 4, protected: false)
        let original = SharedMealOccurrence(occurrenceId: source, revision: 2, meal: meal)
        let edited = SharedMealOccurrence(occurrenceId: target, revision: 6, meal: meal)
        let saved = SharedRepeatSeries(planId: UUID(), weekStart: "2026-11-09", stopped: true,
                                      steps: [step], receipts: [target.uuidString.lowercased(): UUID().uuidString])
        let pending = SharedRepeatSeries(planId: UUID(), weekStart: saved.weekStart, stopped: false,
                                        steps: [step], receipts: [:])

        XCTAssertEqual(saved.menuState(for: step, in: [original, edited]), .present(edited))
        XCTAssertEqual(saved.menuState(for: step, in: [original]), .removed)
        XCTAssertEqual(pending.menuState(for: step, in: [original]), .pending)
        XCTAssertEqual(pending.menuState(for: step, in: [edited]), .pending)
    }

    func testSeriesBindsTheExactSourceAndPersistsTheSameTargetThroughBothShoppingEditors() throws {
        let sourceID = UUID(), targetID = UUID(), seriesID = UUID(), operation = UUID()
        let week = "2026-11-09", target = "2026-11-12"
        let fixture: [String:Any] = ["planId":seriesID.uuidString,"weekStart":week,"stopped":false,
            "steps":[["targetId":targetID.uuidString,"sourceId":sourceID.uuidString,"sourceRevision":4,"day":target]],
            "receipts":[targetID.uuidString.lowercased():operation.uuidString]]
        let series = try JSONDecoder().decode(SharedRepeatSeries.self, from: JSONSerialization.data(withJSONObject: fixture))
        let step = try XCTUnwrap(series.steps.first)
        XCTAssertTrue(series.saved(step))
        let facts: [String:Any] = ["title":"Sopa","kind":"dinner","day":"2026-11-05","protected":true,"portions":2,
            "planning":["groups":[],"ingredients":[],"completedSteps":["Chopped"],"deadline":["at":"2026-11-05T19:00:00Z","zone":"UTC"]]]
        func source(revision: Int) throws -> SharedMealOccurrence {
            try JSONDecoder().decode(SharedMealOccurrence.self, from: JSONSerialization.data(withJSONObject: [
                "occurrenceId":sourceID.uuidString, "revision":revision,"meal":facts]))
        }
        XCTAssertThrowsError(try step.reviewedEdit(source: source(revision: 5), planID: seriesID))
        let edit = try step.reviewedEdit(source: source(revision: 4), planID: seriesID)
        XCTAssertEqual(edit.occurrenceID, targetID)
        XCTAssertEqual(edit.meal?.day,target)
        XCTAssertTrue(edit.meal?.protected == true)
        XCTAssertNil(edit.meal?.planning?.completedSteps)
        XCTAssertNil(edit.meal?.planning?.deadline)
        let tracking = SharedDemandMealEdit(occurrenceId: .init(targetID), baseMealRevision: nil, meal: edit.meal,
            repeatPlanId: edit.repeatPlanID.map(SharedDemandID.init))
        let tracked = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tracking))
        XCTAssertEqual(tracked, try edit.commandValue())
    }
}
