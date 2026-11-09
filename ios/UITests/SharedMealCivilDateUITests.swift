#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class SharedMealCivilDateUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws { app.terminate() }

    func testEnglishCivilDaysStayExactUnderUSTimeZoneEnvironments() {
        checkDays(language: "en", locale: "en_US", labels: ["March 7, 2026", "March 8, 2026", "March 9, 2026",
            "October 31, 2026", "November 1, 2026", "November 2, 2026", "November 3, 2026", "November 5, 2026"])
    }

    func testSpanishCivilDaysStayExactUnderUSTimeZoneEnvironments() {
        checkDays(language: "es", locale: "es_US", labels: ["7 de marzo de 2026", "8 de marzo de 2026", "9 de marzo de 2026",
            "31 de octubre de 2026", "1 de noviembre de 2026", "2 de noviembre de 2026", "3 de noviembre de 2026", "5 de noviembre de 2026"])
    }

    func testEnglishUnscheduledMealCanBeScheduledWithoutReplacingItsNeeds() {
        checkOptionalNight(language: "en", locale: "en_US", edit: "Edit this meal", discard: "Discard meal edit", unscheduled: "Unscheduled")
    }

    func testSpanishUnscheduledMealCanBeScheduledWithoutReplacingItsNeeds() {
        checkOptionalNight(language: "es", locale: "es_US", edit: "Editar esta comida", discard: "Descartar los cambios en la comida", unscheduled: "Sin programar")
    }

    private func checkOptionalNight(language: String, locale: String, edit: String, discard: String, unscheduled: String) {
        app.launchArguments = ["--ui-testing", "--shared-meal-fixture", "--shared-meal-undated-fixture",
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        let facts = app.staticTexts["shared-meal-civil-date"]
        XCTAssertTrue(facts.waitForExistence(timeout: 25)); XCTAssertEqual(facts.label, unscheduled)
        app.buttons[edit].tap()
        let identity = app.staticTexts["fixture.undated.occurrence"]
        let ingredient = app.staticTexts["fixture.undated.ingredient"]
        let originalID = identity.label, originalNeed = ingredient.label
        XCTAssertEqual(originalID.lowercased(), "55555555-5555-4555-8555-555555555555")
        XCTAssertEqual(originalNeed.lowercased(), "77777777-7777-4777-8777-777777777777")
        let toggle = app.switches["sharedMeal.assignNight"]
        let dayControl = app.descendants(matching: .any)["sharedMeal.day"]
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(dayControl.exists)
        XCTAssertFalse(app.buttons["sharedMeal.editDeadline"].isEnabled)
        // SwiftUI exposes the whole labelled row as a switch; target its visible thumb.
        XCTAssertTrue(toggle.isHittable)
        toggle.coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(dayControl.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sharedMeal.unscheduled"].exists)
        let assigned = XCTAttachment(screenshot: app.screenshot())
        assigned.name = "shared-night-assigned-\(locale)"; assigned.lifetime = .keepAlways; add(assigned)
        XCTAssertTrue(app.buttons["sharedMeal.editDeadline"].isEnabled)
        XCTAssertEqual(identity.label, originalID); XCTAssertEqual(ingredient.label, originalNeed)
        toggle.coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(dayControl.exists)
        XCTAssertFalse(app.buttons["sharedMeal.editDeadline"].isEnabled)
        XCTAssertEqual(app.staticTexts["sharedMeal.unscheduled"].label, unscheduled)
        XCTAssertEqual(identity.label, originalID); XCTAssertEqual(ingredient.label, originalNeed)
        let review = app.buttons["fixture.undated.review"]
        for _ in 0..<5 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.isHittable); review.tap()
        let reviewed = app.staticTexts["fixture.undated.reviewedOccurrence"]
        for _ in 0..<5 where !reviewed.exists { app.swipeUp() }
        XCTAssertTrue(reviewed.waitForExistence(timeout: 5))
        XCTAssertEqual(reviewed.label, originalID)
        let discardButton = app.buttons[discard]
        for _ in 0..<5 where !discardButton.isHittable { app.swipeDown() }
        XCTAssertTrue(discardButton.isHittable); discardButton.tap()
        let addMeal = app.buttons["sharedMeal.add"]
        for _ in 0..<5 where !addMeal.isHittable { app.swipeUp() }
        XCTAssertTrue(addMeal.isHittable); addMeal.tap()
        XCTAssertEqual(app.switches["sharedMeal.assignNight"].value as? String, "0")
        XCTAssertEqual(app.staticTexts["sharedMeal.unscheduled"].label, unscheduled)
        XCTAssertFalse(dayControl.exists)
        XCTAssertNotEqual(identity.label, originalID)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "shared-optional-night-\(locale)"; capture.lifetime = .keepAlways; add(capture)
    }

    private func checkDays(language: String, locale: String, labels: [String]) {
        let days = ["2026-03-07", "2026-03-08", "2026-03-09", "2026-10-31",
            "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-05"]
        // New York/Los Angeles observe DST. Phoenix/Honolulu cover US zones without it.
        for zone in ["America/New_York", "America/Los_Angeles", "America/Phoenix", "Pacific/Honolulu"] {
            app.launchArguments = ["--ui-testing", "--shared-meal-fixture", "--shared-meal-civil-date-fixture",
                "--shared-meal-civil-date-zone", zone, "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            let zoneLabel = app.staticTexts["fixture.civil-date.zone"]
            XCTAssertTrue(zoneLabel.waitForExistence(timeout: 15))
            XCTAssertEqual(zoneLabel.label, zone)
            for index in days.indices {
                XCTAssertEqual(app.staticTexts["fixture.civil-date.wire-day"].label, days[index])
                // Read the production Text node, not a formatter duplicated in the test fixture.
                XCTAssertEqual(app.staticTexts["shared-meal-civil-date"].label, labels[index], "\(zone) \(days[index]) \(locale)")
                if index < days.count - 1 { app.buttons["fixture.civil-date.next"].tap() }
            }
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "shared-civil-day-\(zone.replacingOccurrences(of: "/", with: "-"))-\(locale)-2026-11-05"
            capture.lifetime = .keepAlways
            add(capture)
            app.terminate()
        }
    }
}
#endif
