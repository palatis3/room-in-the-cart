#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest
import HouseholdClient
@testable import RoomInTheCart

final class SharedCreatedMealUndoUIFactsTests: XCTestCase {
    func testCompleteCreationFixtureValidatesNullRemovalAndExactSurvivors() throws {
        let review = try OperationUndoUIFacts.review(OperationUndoUIFacts.creationObject())
        try review.validate()
        let candidate = review.candidate, meal = try XCTUnwrap(candidate.mealUndo)
        XCTAssertNil(meal.targetBefore.revision); XCTAssertNil(meal.targetBefore.meal)
        XCTAssertEqual(meal.current, meal.targetAfter); XCTAssertEqual(meal.current.revision, 5)
        XCTAssertEqual(meal.current.meal?.title, "Added taco dinner"); XCTAssertNil(meal.restoredMeal)
        let edit = try XCTUnwrap(candidate.action.body.mealEdit)
        XCTAssertEqual(edit.baseMealRevision, 5); XCTAssertNil(edit.meal)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.action)) as! [String: Any]
        let body = encoded["body"] as! [String: Any], removal = body["mealEdit"] as! [String: Any]
        XCTAssertTrue(removal["meal"] is NSNull)
        XCTAssertEqual(review.shop.meals?.map { $0.meal.title }, ["Protected lunch", "Added taco dinner", "Later independent soup"])
        XCTAssertEqual(review.shop.meals?.map(\.revision), [4, 5, 6])
        XCTAssertEqual(candidate.before.lines, candidate.after.lines)
        XCTAssertEqual(candidate.before.edges, candidate.after.edges)
        XCTAssertEqual(candidate.before.usedIds, candidate.after.usedIds)
        let dinnerID = "00000000-0000-4000-8000-000000000021"
        XCTAssertEqual(candidate.before.contributions.count, 4); XCTAssertEqual(candidate.after.contributions.count, 4)
        for original in candidate.before.contributions {
            let result = try XCTUnwrap(candidate.after.contributions.first { $0.id == original.id })
            if original.id.string == dinnerID {
                XCTAssertNil(original.removedAt); XCTAssertNotNil(result.removedAt)
                var activeAgain = result; activeAgain.removedAt = nil
                XCTAssertEqual(activeAgain, original)
            } else { XCTAssertEqual(result, original) }
        }
        XCTAssertEqual(review.shop.lines.map(\.packs), [2, 1])
        XCTAssertEqual(candidate.action.body.lines.map(\.packs), [1, 1])
        XCTAssertEqual(candidate.action.body.lines[1], review.shop.lines[1])
        XCTAssertEqual(candidate.action.body.quote, review.shop.quote)
        XCTAssertEqual(candidate.beforeCheckout.totalMinor, 700); XCTAssertEqual(candidate.afterCheckout.totalMinor, 500)
        XCTAssertEqual(candidate.beforeTotals[0].quantity?.numerator, 10)
        XCTAssertEqual(candidate.afterTotals[0].quantity?.numerator, 4)
        XCTAssertNil(candidate.afterTotals[1].quantity)
    }
}
#endif
