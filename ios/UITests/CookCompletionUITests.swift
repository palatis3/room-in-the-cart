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
        tap(app.buttons["shop.myPantry"]); tap(app.buttons["pantry.setup.apply"])
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinnerStartPickup"])
        fill(app.textFields["ledgerShopName"], "Cooking review")
        tap(app.buttons["ledgerCreateShop"])
        tap(app.buttons["dinnerManual"])
        fill(app.textFields["ledgerDinnerTitle"], "Actual rice dinner")
        fill(app.textFields["ledgerDinnerServings"], "2")
        let ingredient = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'ingredient.' AND identifier ENDSWITH '.name'")).firstMatch
        fill(ingredient, "Rice")
        tap(app.buttons["ledgerReviewDinner"]); tap(app.buttons["dinnerApply"])
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["dinnerApply"])
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 15), .completed, app.debugDescription)
        // Applied manual editor remains in its navigation path. Return to the
        // actual Dinners tab root before opening the saved occurrence.
        tap(app.tabBars.buttons["Shop"]); tap(app.tabBars.buttons["Dinners"])
        for _ in 0..<4 where !app.buttons["All chosen dinners, including earlier dates"].exists {
            if app.navigationBars.firstMatch.buttons.firstMatch.exists { app.navigationBars.firstMatch.buttons.firstMatch.tap() }
        }
        tap(app.buttons["All chosen dinners, including earlier dates"])
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerOccurrence-' AND label CONTAINS 'Actual rice dinner'")).firstMatch)
        tap(app.buttons["dinner.cookCompletion"])
        XCTAssertTrue(app.textFields["cook.servings"].waitForExistence(timeout: 12), app.debugDescription)
        tap(app.buttons["Cancel"])
        tap(app.buttons["dinner.cookCompletion"])
        XCTAssertFalse(app.staticTexts["cook.saved"].exists, "Cancel must not record cooking")
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.textFields["cook.servings"])
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 10), .completed, app.debugDescription)
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cook.ingredient.'")).firstMatch)
        tap(app.buttons["Used"])
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cook.part.'")).firstMatch)
        tap(app.buttons["Food not tracked in this pantry"])
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cook.relation.'")).firstMatch)
        tap(app.buttons["The planned ingredient"])
        tap(app.buttons["cook.leftoverChoice"]); tap(app.buttons["No leftovers"])
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
        tap(app.buttons["Close"]); tap(app.buttons["dinner.cookCompletion"])
        XCTAssertTrue(app.staticTexts["cook.saved"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["cook.confirm"].exists, "Saved cooking cannot be recorded twice")
        tap(app.buttons["cook.resolution.open"])
        tap(app.buttons["cook.resolution.action"])
        tap(app.buttons["The food came from outside this pantry"])
        tap(app.buttons["cook.resolution.review"])
        tap(app.buttons["cook.resolution.confirm"])
        XCTAssertTrue(app.staticTexts["cook.resolution.complete"].waitForExistence(timeout: 12), app.debugDescription)
        tap(app.buttons["Cancel"])
        let resolved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Inventory changes recorded."), object: app.staticTexts["cook.inventoryStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["cook.resolution.open"].exists, "The original unresolved history must not appear as unfinished after resolution")
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
