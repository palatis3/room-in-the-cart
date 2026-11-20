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
        waitForSubtotal("Picked subtotal unknown")
        app.buttons["inStoreLastPrice"].tap()
        let amount = app.textFields["inStoreAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts.matching(identifier: "Saved on this iPhone").firstMatch.isHittable)
        enter("4.25", in: amount)
        if app.buttons["inStoreAmountDone"].isHittable { app.buttons["inStoreAmountDone"].tap() }
        let save = app.buttons["Save price"]
        show(save)
        save.tap()
        waitForSubtotal("$4.25 for 1 picked item")
        checks.firstMatch.tap()
        waitForSubtotal("$4.25 for 1 of 2 picked items")
        app.buttons["inStoreUndo"].tap()
        waitForSubtotal("$4.25 for 1 picked item")
        app.buttons["Done"].tap()
        app.terminate()
        launch(fresh: false)
        show(inStore)
        inStore.tap()
        waitForSubtotal("$4.25 for 1 picked item")
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
        waitForSubtotal("Picked subtotal unknown")
        XCTAssertTrue(app.buttons[firstCheckID].exists)
        app.buttons["inStoreUndo"].tap()
        waitForSubtotal("$0.00 · No items picked")
    }

    func testMeasuredApplesAndLeavingBreadForNextTime() {
        continueAfterFailure = false
        launch(fresh: true, shelfBudget: true)
        let store = app.buttons["ledgerInStore"]
        show(store)
        store.tap()

        func aisleCheckbox(_ grocery: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                             "inStoreCheck-", "Check " + grocery)).element
        }
        let checkApples = aisleCheckbox("Apples")
        XCTAssertTrue(checkApples.waitForExistence(timeout: 8))
        checkApples.tap()
        app.buttons["inStoreLastPrice"].tap()
        let basis = app.buttons["inStorePriceBasis"]
        XCTAssertTrue(basis.waitForExistence(timeout: 8))
        basis.tap()
        app.buttons["By weight"].tap()
        enter("2.75", in: app.textFields["inStoreAmount"])
        app.buttons["inStoreAmountDone"].tap()
        enter("1.5", in: app.textFields["inStoreMeasuredAmount"])
        app.buttons["inStoreAmountDone"].tap()
        show(app.buttons["Save price"])
        app.buttons["Save price"].tap()
        waitForBudgetSubtotal("$4.13 for 1 picked item")

        aisleCheckbox("Coffee").tap()
        waitForBudgetSubtotal("$4.13 for 1 of 2")
        let bread = aisleCheckbox("Bread")
        let breadID = String(bread.identifier.dropFirst("inStoreCheck-".count))
        bread.tap()
        waitForBudgetSubtotal("$4.13 for 1 of 3")
        app.buttons["inStoreLastPrice"].tap()
        enter("4.50", in: app.textFields["inStoreAmount"])
        app.buttons["inStoreAmountDone"].tap()
        show(app.buttons["Save price"])
        app.buttons["Save price"].tap()
        waitForBudgetSubtotal("$8.63 for 2 of 3")

        let inspect = app.cells.containing(.button, identifier: "inStorePrice-" + breadID).buttons["Inspect Bread"]
        show(inspect)
        inspect.tap()
        let budget = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inStoreBudget-")).firstMatch
        show(budget)
        budget.tap()
        let flexible = app.switches["Flexible pick"]
        XCTAssertTrue(flexible.waitForExistence(timeout: 8))
        enableAisleSwitch(flexible)
        let preview = app.buttons["Preview putting it back"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        show(preview)
        preview.tap()
        XCTAssertTrue(app.staticTexts["Known item subtotal · $8.63 → $4.13"].exists)
        let leave = app.buttons["inStoreLeaveForNextTime"]
        show(leave)
        leave.tap()
        XCTAssertTrue(app.navigationBars["Item details"].waitForExistence(timeout: 8))
        app.navigationBars["Item details"].buttons["Done"].tap()
        waitForBudgetSubtotal("$4.13 for 1 of 2")
    }

    func testPartialPickUnavailableHandoffAndSecondStoreUndoAfterRestart() throws {
        continueAfterFailure = false
        launch(fresh: true, shelfBudget: true)
        tapTrip(app.buttons["ledgerInStore"])
        let apple = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "tripDetails-", "Apples")).firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 8))
        let id = String(apple.identifier.dropFirst("tripDetails-".count))
        tapTrip(apple)
        tapTrip(app.buttons["tripPickPart"])
        let amount = app.textFields["tripPartialAmount"]
        amount.tap(); amount.typeText("1")
        if app.buttons["tripPartKeyboardDone"].isHittable { app.buttons["tripPartKeyboardDone"].tap() }
        tapTrip(app.buttons["tripSavePart"])
        tapTrip(apple)
        tapTrip(app.buttons["tripUnavailable"])
        XCTAssertTrue(app.staticTexts["Couldn’t find it at this stop"].waitForExistence(timeout: 10))
        tapTrip(app.buttons["tripAddFind"])
        let field = app.textFields["tripFindName"]
        field.tap(); field.typeText("Lime")
        if app.buttons["tripFindKeyboardDone"].isHittable { app.buttons["tripFindKeyboardDone"].tap() }
        tapTrip(app.buttons["Add to picked items"])
        tapTrip(app.buttons["inStoreTripOptions"])
        tapTrip(app.buttons["Send selected items"])
        let apples = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Apples")).firstMatch
        enableAisleSwitch(apples)
        tapTrip(app.buttons["Preview message"])
        let preview = app.staticTexts["tripShareBody"]
        XCTAssertTrue(preview.waitForExistence(timeout: 6))
        XCTAssertTrue(preview.label.contains("Apples") && preview.label.contains("3"))
        XCTAssertFalse(preview.label.contains("Coffee") || preview.label.contains("Lime"))
        app.terminate()
        launch(fresh: false, shelfBudget: true)
        tapTrip(app.buttons["ledgerInStore"])
        tapTrip(app.buttons["tripNextStore"])
        let store = app.textFields["Store name"]
        store.tap(); store.typeText("East market")
        if app.buttons["tripStoreKeyboardDone"].isHittable { app.buttons["tripStoreKeyboardDone"].tap() }
        tapTrip(app.buttons["Start this stop"])
        tapTrip(app.buttons["inStoreCheck-" + id])
        tapTrip(app.buttons["inStoreUndo"])
        XCTAssertTrue(apple.waitForExistence(timeout: 8))
        XCTAssertTrue(apple.label.contains("3"))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "inStoreUndo", "Apples")).firstMatch.exists)
    }

    private func enableAisleSwitch(_ row: XCUIElement) {
        show(row)
        if row.value as? String != "1" {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.5)).tap()
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
    }

    private func tapTrip(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 6)
        if element.exists, !element.isHittable, element.frame.minY < app.frame.minY + 110 {
            for _ in 0..<5 where !element.isHittable { app.swipeDown() }
        }
        show(element)
        element.tap()
    }

    private func waitForBudgetSubtotal(_ text: String) {
        let expected = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTNSPredicateExpectation(predicate: expected, object: app.staticTexts["inStoreSubtotal"])
        XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: 8), .completed)
    }

    private func enter(_ value: String, in field: XCUIElement) {
        field.tap(); field.typeText(value)
        enteredFields += 1
    }

    private func launch(fresh: Bool, shelfBudget: Bool = false) {
        app.launchArguments = ["--ui-testing", "--staple-recall-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if shelfBudget { app.launchArguments.append("--shelf-budget-fixture") }
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
