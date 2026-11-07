import Foundation
import HouseholdClient
import XCTest
@testable import RoomInTheCart

final class SharedFallbackDraftTests: XCTestCase {
    private func recipeDraft() -> DisclosedFallbackDraft {
        var recipe = DisclosedFallbackDraft()
        recipe.title = "Frijoles"
        recipe.portions = "4"
        recipe.notes = "Warm gently"
        recipe.exclusions = "No sesame\nNo nuts"
        recipe.ingredients[0].name = "Beans"
        recipe.ingredients[0].amount = "1,5"
        recipe.ingredients[0].notes = "Rinse first"
        recipe.ingredients[0].exclusions = "No salt"
        return recipe
    }

    func testReviewedRecipeKeepsEnteredFractionNotesExclusionsAndUnknowns() throws {
        var draft = recipeDraft()
        draft.lead = "1000000"
        let recipe = try draft.recipe()
        XCTAssertEqual(recipe.ingredients.first?.quantity?.amount, .init(numerator: 3, denominator: 2))
        XCTAssertEqual(recipe.ingredients.first?.quantity?.originalLiteral, "1,5")
        XCTAssertEqual(recipe.ingredients.first?.notes, "Rinse first")
        XCTAssertEqual(recipe.exclusions, ["No sesame", "No nuts"])
        XCTAssertEqual(recipe.ingredients.first?.exclusions, ["No salt"])
        XCTAssertNil(recipe.elapsedMinutes)
        XCTAssertEqual(recipe.requiredLeadMinutes, 1_000_000)
        draft.ingredients[0].amount = ""
        XCTAssertNil(try draft.recipe().ingredients.first?.quantity)
        draft.ingredients[0].amount = "0"
        XCTAssertThrowsError(try draft.recipe())
        draft.ingredients[0].amount = "-2"
        XCTAssertThrowsError(try draft.recipe())
    }

    func testTwoIngredientsShareOneReviewedPackOnlyByItsSelectedIdentity() throws {
        var raw = recipeDraft()
        var second = DinnerIngredientDraft()
        second.name = "Beans for lunch"; second.amount = "2"
        raw.ingredients.append(second)
        let recipe = try raw.recipe()
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe))
        let data = try JSONSerialization.data(withJSONObject: ["candidateId":UUID().uuidString, "revision":2, "usual":false, "recipe":json])
        let candidate = try JSONDecoder().decode(SharedFallbackLibrary.Candidate.self, from: data)
        var review = CandidateReviewDraft(candidate)
        for index in review.ingredients.indices {
            review.ingredients[index].hasOwnPack = true
            review.ingredients[index].pack.label = "Beans"
            review.ingredients[index].pack.amount = "4"
            review.ingredients[index].pack.price = "1,49"
            review.ingredients[index].pack.availability = "2"
        }
        let independent = try review.review(includeOffers: true)
        let firstPack = try XCTUnwrap(independent.ingredients[0].offer)
        XCTAssertNotEqual(firstPack.packId, independent.ingredients[1].offer?.packId)
        review.ingredients[1].sharedPackID = firstPack.packId
        review.ingredients[1].hasOwnPack = false
        let linked = try review.review(includeOffers: true)
        XCTAssertEqual(linked.ingredients[1].offer, firstPack)
        XCTAssertEqual(firstPack.priceMinor, 149)
        review.ingredients[0].hasOwnPack = false
        XCTAssertThrowsError(try review.review(includeOffers: true))
        XCTAssertTrue(try review.review(includeOffers: false).ingredients.allSatisfy { $0.offer == nil })
    }

    func testTripRequiresReviewedTimeChargesAndLimitEvenWhenZero() throws {
        var trip = FallbackTripDraft()
        XCTAssertNil(try trip.trip())
        trip.include = true
        trip.minutes = "12"; trip.budget = "5,20"
        XCTAssertThrowsError(try trip.trip())
        trip.charges = "0"
        let reviewed = try XCTUnwrap(trip.trip())
        XCTAssertEqual(reviewed.chargesMinor, 0)
        XCTAssertEqual(reviewed.minutes, 12)
        XCTAssertEqual(reviewed.budgetMinor, 520)
        XCTAssertEqual(reviewed.currency, "USD")
        trip.budget = "-1"
        XCTAssertThrowsError(try trip.trip())
    }
}
