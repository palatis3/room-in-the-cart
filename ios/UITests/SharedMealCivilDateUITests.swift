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
