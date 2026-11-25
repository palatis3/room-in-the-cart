#if DEBUG && targetEnvironment(simulator)
import XCTest

/// The ordinary private application: create a dinner, cancel cooking, then
/// explicitly record untracked use and reopen its saved unresolved status.
@MainActor final class CookCompletionUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.lifetime = .keepAlways; add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        }
        app.terminate()
    }
    func testDinnerCookingCancelExplicitUntrackedConfirmationAndReopen() throws {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if #unavailable(iOS 18) { app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable" }
        app.launch()
        tap(app.shopToolButton("shop.myPantry")); tap(app.buttons["pantry.setup.apply"])
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinnerStartPickup"])
        fill(app.textFields["ledgerShopName"], "Cooking review")
        tap(app.buttons["ledgerCreateShop"])
        tap(app.buttons["dinnerManual"])
        fill(app.textFields["ledgerDinnerTitle"], "Actual rice dinner")
        fill(app.textFields["ledgerDinnerServings"], "2")
        let ingredient = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'ingredient.' AND identifier ENDSWITH '.name'")).firstMatch
        fill(ingredient, "Rice")
        tapVisibleFormControl(app.buttons["ledgerReviewDinner"], in: "Manual dinner", captureName: "Manual dinner Review above tab bar")
        XCTAssertTrue(app.navigationBars["Dinner preview"].waitForExistence(timeout: 4), app.debugDescription)
        captureScreen("Dinner preview opened from the visible Review button")
        tap(app.buttons["dinnerApply"])
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["dinnerApply"])
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 15), .completed, app.debugDescription)
        // Applied manual editor remains in its navigation path. Return to the
        // actual Dinners tab root before opening the saved occurrence.
        tap(app.tabBars.buttons["Shop"]); tap(app.tabBars.buttons["Dinners"])
        let dinnersBar = app.navigationBars["Dinners"]
        for _ in 0..<4 where !dinnersBar.exists {
            let back = app.navigationBars.firstMatch.buttons.firstMatch
            if back.exists { back.tap() }
        }
        XCTAssertTrue(dinnersBar.waitForExistence(timeout: 4), app.debugDescription)
        let chosenDinners = app.buttons["All chosen dinners, including earlier dates"]
        let list = app.collectionViews.firstMatch
        // Returning from the editor can leave this row above the compact viewport.
        for attempt in 0..<8 {
            let exists = chosenDinners.exists
            if exists && chosenDinners.isHittable { break }
            let searchAbove = exists ? chosenDinners.frame.midY < list.frame.midY : attempt < 4
            if searchAbove { list.swipeDown(velocity: .slow) }
            else { list.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(chosenDinners.exists && chosenDinners.isHittable, app.debugDescription)
        chosenDinners.tap()
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerOccurrence-' AND label CONTAINS 'Actual rice dinner'")).firstMatch)
        tap(app.buttons["cooking.openDinner"])
        XCTAssertTrue(app.staticTexts["This recipe has no written instructions."].waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Rice"].exists)
        tap(app.buttons["cooking.finish"])
        XCTAssertTrue(app.textFields["cook.servings"].waitForExistence(timeout: 12), app.debugDescription)
        tap(app.buttons["Cancel"])
        tap(app.buttons["cooking.finish"])
        XCTAssertFalse(app.staticTexts["cook.saved"].exists, "Cancel must not record cooking")
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.textFields["cook.servings"])
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 10), .completed, app.debugDescription)
        let ingredientPicker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cook.ingredient.'")).element
        let currentUse = ingredientPicker.staticTexts["Choose what happened"]
        tapVisibleFormControl(currentUse, in: "Record cooking")
        let used = app.buttons["Used"]
        XCTAssertTrue(used.waitForExistence(timeout: 4) && used.isHittable, app.debugDescription)
        used.tap()
        let partPicker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cook.part.'")).element
        tapVisibleFormControl(partPicker.staticTexts["Choose a record type"], in: "Record cooking")
        tap(app.buttons["Food not tracked in this pantry"])
        let relationPicker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cook.relation.'")).element
        tapVisibleFormControl(relationPicker.staticTexts["Review the food used"], in: "Record cooking")
        tap(app.buttons["The planned ingredient"])
        tapVisibleFormControl(app.buttons["cook.leftoverChoice"].staticTexts["Choose what remains"], in: "Record cooking")
        tap(app.buttons["No leftovers"])
        tap(app.buttons["cook.review"])
        XCTAssertTrue(app.navigationBars["Confirm cooking"].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["cook.confirm"])
        XCTAssertTrue(app.staticTexts["cook.saved"].waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(app.staticTexts["cook.inventoryStatus"].label.contains("Inventory needs review"), app.debugDescription)
        tap(app.buttons["cook.mealFeedback"])
        let reaction = app.switches["mealFeedback.makeAgain"]
        XCTAssertTrue(reaction.waitForExistence(timeout: 10), app.debugDescription)
        reaction.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(reaction.value as? String, "1")
        tap(app.buttons["mealFeedback.save"])
        XCTAssertTrue(app.staticTexts["cook.saved"].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["cook.mealFeedback"])
        XCTAssertTrue(app.buttons["mealFeedback.remove"].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["mealFeedback.remove"])
        XCTAssertTrue(app.staticTexts["cook.saved"].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["Close"]); tap(app.buttons["cooking.finish"])
        XCTAssertTrue(app.staticTexts["cook.saved"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["cook.confirm"].exists, "Saved cooking cannot be recorded twice")
        tap(app.buttons["cook.resolution.open"])
        tap(app.buttons["cook.resolution.action"])
        tap(app.buttons["The food came from outside this pantry"])
        tap(app.buttons["cook.resolution.review"])
        tap(app.buttons["cook.resolution.confirm"])
        XCTAssertTrue(app.staticTexts["cook.resolution.complete"].waitForExistence(timeout: 12), app.debugDescription)
        // The covered cooking screen also has Cancel. Dismiss the visible
        // resolution sheet so its onDismiss reload can publish the saved status.
        tap(app.navigationBars["Review unresolved ingredient use"].buttons["Cancel"])
        // On a compact phone the saved Form retains its previous scroll offset.
        // Its status row can be virtualized above the viewport after dismissal.
        let savedStatus = app.staticTexts["cook.inventoryStatus"]
        for _ in 0..<8 {
            if savedStatus.exists && savedStatus.isHittable { break }
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(savedStatus.exists && savedStatus.isHittable, app.debugDescription)
        let resolved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Inventory changes recorded."), object: savedStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["cook.resolution.open"].exists, "The original unresolved history must not appear as unfinished after resolution")
    }
    private func captureScreen(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    private func tapVisibleFormControl(_ control: XCUIElement, in screen: String, captureName: String? = nil) {
        // A compact Form can expose a control while its activation point is still behind a bar.
        let form = app.collectionViews.firstMatch
        let bar = app.navigationBars[screen]
        let tabs = app.tabBars.firstMatch
        for _ in 0..<8 {
            let top = bar.frame.maxY
            let bottom = tabs.frame.minY
            let frame = control.exists ? control.frame : .zero
            print("\(screen) control frame: \(frame), visible form: \(top)...\(bottom)")
            if !frame.isEmpty, frame.minY >= top, frame.maxY <= bottom, control.isHittable {
                XCTAssertTrue(control.isEnabled, app.debugDescription)
                if let captureName { captureScreen(captureName) }
                control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            if !frame.isEmpty && frame.midY < top { form.swipeDown() }
            else { form.swipeUp() }
        }
        XCTFail("Could not reveal the control between the navigation and tab bars on \(screen). " + app.debugDescription)
    }
    private func tap(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 4)
        for _ in 0..<16 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription); element.tap()
    }
    private func fill(_ element: XCUIElement, _ value: String) {
        tap(element); element.typeText(value)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        else if app.buttons["Done"].exists && app.buttons["Done"].isHittable { app.buttons["Done"].tap() }
        else { app.swipeUp() }
    }
}
#endif
