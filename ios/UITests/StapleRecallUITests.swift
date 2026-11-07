#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class StapleRecallUITests: XCTestCase {
    private var enteredFields = 0
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")

    func testShopperClosesExactCoffeeAfterFilteringAndReopensOnlyThePriorMarketCheck() {
        continueAfterFailure = false
        launch(fresh: true)
        let start = ProcessInfo.processInfo.systemUptime
        app.buttons["ledgerListOptions"].tap()
        app.buttons["Review prior staples"].tap()
        let coffee = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Coffee", "School lunches")).firstMatch
        XCTAssertTrue(coffee.waitForExistence(timeout: 8))
        XCTAssertTrue(coffee.label.contains("North market") && coffee.label.contains("Previously checked"), coffee.label)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "West store")).firstMatch.exists)
        let soap = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Soap")).firstMatch
        XCTAssertTrue(soap.exists)
        let filter = app.textFields["Filter by purpose"]
        enter("School", in: filter)
        XCTAssertFalse(soap.exists)
        coffee.tap()
        let buyer = app.textFields["Handled by"]
        let mark = app.buttons["Mark this list item handled"]
        let pick = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Item bought on this list")).firstMatch
        show(pick); pick.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Item 2", "School lunches")).firstMatch.tap()
        show(mark); XCTAssertFalse(mark.isEnabled)
        enter("Ana", in: buyer)
        if app.keyboards.buttons["Done"].isHittable { app.keyboards.buttons["Done"].tap() }
        show(mark); mark.tap()
        XCTAssertTrue(app.navigationBars["Review prior staples"].waitForExistence(timeout: 8))
        XCTAssertFalse(coffee.exists)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let measurement = XCTAttachment(string: "Recall review through save: \(elapsed) seconds; text fields entered: \(enteredFields)")
        measurement.name = "P05 assisted re-entry on simulator"
        measurement.lifetime = .keepAlways
        add(measurement)

        app.terminate(); launch(fresh: false)
        let active = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-"))
        XCTAssertEqual(active.count, 1)
        active.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Office"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["ledgerHistory"].tap()
        let handled = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Handled by Ana")).firstMatch
        XCTAssertTrue(handled.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["ledgerShopPicker"].tap()
        app.buttons["Previous market"].tap()
        let checked = app.buttons["Reopen Coffee"]
        app.buttons["ledgerHistory"].tap()
        show(checked)
        XCTAssertFalse(handled.exists)
        checked.tap()
        XCTAssertTrue(checked.waitForNonExistence(timeout: 6))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "ledgerInspect-", "Coffee")).firstMatch.waitForExistence(timeout: 6))
    }

    private func enter(_ value: String, in field: XCUIElement) {
        field.tap(); field.typeText(value)
        enteredFields += 1
    }

    private func launch(fresh: Bool) {
        app.launchArguments = ["--ui-testing", "--staple-recall-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if fresh { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(app.buttons["ledgerListOptions"].waitForExistence(timeout: 25))
    }

    private func show(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, element.debugDescription)
    }
}
#endif
