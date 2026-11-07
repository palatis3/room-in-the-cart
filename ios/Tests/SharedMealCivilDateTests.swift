import XCTest
import HouseholdClient
@testable import RoomInTheCart

final class SharedMealCivilDateTests: XCTestCase {
    func testLocalizedCivilDayKeepsTheExactGregorianWireDayAcrossUSDSTBoundaries() throws {
        let examples = [
            ("2026-03-07", "March 7, 2026", "7 de marzo de 2026"),
            ("2026-03-08", "March 8, 2026", "8 de marzo de 2026"),
            ("2026-03-09", "March 9, 2026", "9 de marzo de 2026"),
            ("2026-10-31", "October 31, 2026", "31 de octubre de 2026"),
            ("2026-11-01", "November 1, 2026", "1 de noviembre de 2026"),
            ("2026-11-02", "November 2, 2026", "2 de noviembre de 2026"),
            ("2026-11-03", "November 3, 2026", "3 de noviembre de 2026"),
            ("2026-11-05", "November 5, 2026", "5 de noviembre de 2026"),
            ("2024-02-29", "February 29, 2024", "29 de febrero de 2024")
        ]
        for (wireDay, english, spanish) in examples {
            let date = try XCTUnwrap(sharedMealDate(wireDay))
            XCTAssertEqual(sharedMealDay(date), wireDay)
            XCTAssertEqual(sharedMealDayText(wireDay, locale: Locale(identifier: "en_US")), english)
            XCTAssertEqual(sharedMealDayText(wireDay, locale: Locale(identifier: "es_US")), spanish)
        }
    }

    func testDateLabelsUseGregorianCivilDayEvenWhenLocalePrefersAnotherCalendar() {
        XCTAssertEqual(sharedMealDayText("2026-11-05", locale: Locale(identifier: "en_US@calendar=buddhist")),
            "November 5, 2026")
    }

    func testMalformedOrImpossibleCivilDaysDoNotProduceADifferentDayLabel() {
        for day in ["", "2026-2-03", "2026-02-30", "2026-02-29", "2026-13-01", "2026-00-01",
                    "2026-11-00", "2026-11-31", "2026-11-05T00:00:00Z", "2026-11-05-06", "2026/11/05"] {
            XCTAssertNil(sharedMealDate(day), day)
            XCTAssertNil(sharedMealDayText(day, locale: Locale(identifier: "en_US")), day)
            XCTAssertNil(sharedMealDayText(day, locale: Locale(identifier: "es_US")), day)
        }
    }

    func testRenderingDoesNotAlterTheMealOrEncodedWireDay() throws {
        let meal = SharedMeal(title: "Soup", day: "2026-11-05", kind: "dinner", portions: 4, protected: false)
        let before = try JSONEncoder().encode(meal)
        _ = sharedMealDayText(meal.day, locale: Locale(identifier: "es_US"))
        XCTAssertEqual(meal.day, "2026-11-05")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meal)) as? [String: Any])
        XCTAssertEqual(raw["day"] as? String, "2026-11-05")
        XCTAssertEqual(try JSONDecoder().decode(SharedMeal.self, from: before), meal)
    }
}

extension SharedMealCivilDateTests {
    func testTwoRepeatedNewYorkClockTimesKeepDistinctInstantsAndDisplayOffsets() throws {
        let early=SharedMealDeadline(at:"2026-11-01T05:30:00Z",zone:"America/New_York")
        let later=SharedMealDeadline(at:"2026-11-01T06:30:00Z",zone:"America/New_York")
        try early.validate(day:"2026-11-01");try later.validate(day:"2026-11-01")
        XCTAssertEqual(try XCTUnwrap(later.instant).timeIntervalSince(try XCTUnwrap(early.instant)),3600)
        for lang in ["en-US","es-US"] {
            let locale=Locale(identifier:lang)
            XCTAssertTrue(try XCTUnwrap(early.display(locale:locale)).contains("UTC−04:00"))
            XCTAssertTrue(try XCTUnwrap(later.display(locale:locale)).contains("UTC−05:00"))
        }
        let same="2026-11-02T07:30:00Z"
        try SharedMealDeadline(at:same,zone:"America/Los_Angeles").validate(day:"2026-11-01")
        try SharedMealDeadline(at:same,zone:"Pacific/Kiritimati").validate(day:"2026-11-02")
        XCTAssertThrowsError(try SharedMealDeadline(at:same,zone:"America/Los_Angeles").validate(day:"2026-11-02"))
    }

    func testDateOnlyMovePreservesOtherPlanningAndDeskCanReviewExactOldAndNewDeadlines() throws {
        let deadline=SharedMealDeadline(at:"2026-11-01T01:30:00.125-05:00",zone:"America/New_York")
        var meal=SharedMeal(title:"Beans",day:"2026-11-01",kind:"dinner",portions:4,protected:false,
                            planning:.init(groups:[],ingredients:[],leadTimeMinutes:45,completedSteps:["Beans soaked"]))
        try meal.setDeadline(deadline)
        let previous=meal
        meal.move(to:meal.day);XCTAssertEqual(meal,previous)
        meal.move(to:"2026-11-04")
        XCTAssertEqual(previous.planning?.deadline,deadline);XCTAssertNil(meal.planning?.deadline)
        XCTAssertEqual(meal.planning?.completedSteps,previous.planning?.completedSteps);XCTAssertEqual(meal.planning?.leadTimeMinutes,45)
        let ready=SharedMealDeadline(at:"2026-11-05T00:00:00Z",zone:"America/New_York")
        try meal.setDeadline(ready);XCTAssertEqual(meal.planning?.deadline,ready)
        XCTAssertThrowsError(try meal.setDeadline(deadline));XCTAssertEqual(meal.planning?.deadline,ready)
        let roundTrip=try JSONDecoder().decode(SharedMeal.self,from:JSONEncoder().encode(meal))
        XCTAssertEqual(roundTrip,meal)
    }

    func testInvalidDeadlineCannotBeReadOrSubmittedAndLegacyAbsenceStaysUnknown() throws {
        let legacy=SharedMeal(title:"Dinner",day:"2026-03-08",kind:"dinner",portions:2,protected:false)
        XCTAssertNil(try JSONDecoder().decode(SharedMeal.self,from:JSONEncoder().encode(legacy)).planning)
        for invalid in [SharedMealDeadline(at:"2026-03-08T14:30:00",zone:"America/New_York"),
                        .init(at:"2026-02-30T14:30:00Z",zone:"UTC"),.init(at:"2026-03-08T14:30:00Z",zone:"+03:00"),
                        .init(at:"2026-03-07T14:30:00Z",zone:"America/Los_Angeles")] {
            var meal=legacy;meal.planning = .init(groups:[],ingredients:[],deadline:invalid)
            XCTAssertThrowsError(try JSONDecoder().decode(SharedMeal.self,from:JSONEncoder().encode(meal)))
            XCTAssertThrowsError(try SharedMealEdit(occurrenceID:UUID(),meal:meal).commandValue())
        }
    }
}
