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
        let shopPicker = app.buttons["ledgerShopPicker"]
        XCTAssertEqual(shopPicker.label, "This trip")
        app.buttons["ledgerListOptions"].tap()
        app.buttons["List history"].tap()
        let handled = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Handled by Ana")).firstMatch
        XCTAssertTrue(handled.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        shopPicker.tap()
        app.buttons["Previous market"].tap()
        let previousMarket = app.buttons.matching(identifier: "ledgerShopPicker")
            .matching(NSPredicate(format: "label == %@", "Previous market")).firstMatch
        XCTAssertTrue(previousMarket.waitForExistence(timeout: 8))
        let checked = app.buttons["Reopen Coffee"]
        let footerHistory = app.buttons["ledgerHistory"]
        show(footerHistory)
        footerHistory.tap()
        show(checked)
        XCTAssertFalse(handled.exists)
        checked.tap()
        XCTAssertTrue(checked.waitForNonExistence(timeout: 6))
        app.buttons["Done"].tap()
        // Closing history returns to its footer. The reopened grocery is in the active list above it.
        let reopened = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "ledgerInspect-", "Inspect Coffee")).firstMatch
        app.revealRestoredGrocery(reopened)
        XCTAssertEqual(shopPicker.label, "Previous market")
        reopened.tap()
        XCTAssertTrue(app.navigationBars["Inspect ingredient"].waitForExistence(timeout: 6))
    }

    func testInStoreCheckPriceCoverageAndOneHandedUndo() {
        continueAfterFailure = false
        launch(fresh: true)
        let inStore = app.buttons["ledgerInStore"]
        show(inStore)
        inStore.tap()
        let checks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inStoreCheck-"))
        XCTAssertTrue(checks.firstMatch.waitForExistence(timeout: 8))
        let firstCheckID = checks.firstMatch.identifier
        let firstLineID = firstCheckID.dropFirst("inStoreCheck-".count)
        checks.firstMatch.tap()
        let subtotal = app.staticTexts["inStoreSubtotal"]
        func waitForSubtotal(_ expected: String) {
            let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", expected), object: subtotal)
            XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 8), .completed)
        }
        waitForSubtotal("0 of 1 picked items")
        app.buttons["inStoreLastPrice"].tap()
        let amount = app.textFields["inStoreAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts.matching(identifier: "Saved on this iPhone").firstMatch.isHittable)
        enter("4.25", in: amount)
        if app.buttons["inStoreAmountDone"].isHittable { app.buttons["inStoreAmountDone"].tap() }
        let save = app.buttons["Save price"]
        show(save)
        save.tap()
        waitForSubtotal("$4.25 for 1 of 1 picked items")
        checks.firstMatch.tap()
        waitForSubtotal("$4.25 for 1 of 2 picked items")
        app.buttons["inStoreUndo"].tap()
        waitForSubtotal("$4.25 for 1 of 1 picked items")
        app.buttons["Done"].tap()
        app.terminate()
        launch(fresh: false)
        show(inStore)
        inStore.tap()
        waitForSubtotal("$4.25 for 1 of 1 picked items")
        checks.firstMatch.tap()
        waitForSubtotal("$4.25 for 1 of 2 picked items")
        let firstPrice = app.buttons["inStorePrice-" + firstLineID]
        XCTAssertTrue(firstPrice.label.contains("Saved price · $4.25"))
        firstPrice.tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 8))
        app.buttons["Cancel"].tap()
        let firstUncheck = app.buttons["inStoreUncheck-" + firstLineID]
        XCTAssertTrue(firstUncheck.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(firstUncheck.frame.width, 44)
        XCTAssertGreaterThanOrEqual(firstUncheck.frame.height, 44)
        firstUncheck.tap()
        waitForSubtotal("$0.00 for 0 of 1 picked items")
        XCTAssertTrue(app.buttons[firstCheckID].exists)
        app.buttons["inStoreUndo"].tap()
        waitForSubtotal("$0.00 for 0 of 0 picked items")
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
