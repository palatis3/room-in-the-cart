#if DEBUG && targetEnvironment(simulator)
import XCTest

/// Uses the normal empty local workspace and production pantry setup. No seeded
/// recipe or selected shop hides the no-shop composition requirement.
@MainActor final class TonightUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            let state = XCTAttachment(string: app.debugDescription); state.lifetime = .keepAlways; add(state)
            let screen = XCTAttachment(screenshot: app.screenshot()); screen.lifetime = .keepAlways; add(screen)
        }
        app.terminate()
    }
    func testBothPrivateTonightEntriesWorkWithoutShopAndCancelCreatesNothing() throws {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if #unavailable(iOS 18) { app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable" }
        app.launch()
        tap(app.buttons["shop.myPantry"])
        tap(app.buttons["pantry.setup.apply"])
        tap(app.buttons["pantry.tonight"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 12))
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No reviewed recipes are available.")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 12))
        tap(app.buttons["Review a recipe by hand"])
        XCTAssertTrue(app.navigationBars["Review a recipe"].waitForExistence(timeout: 8))
        tap(app.buttons["Cancel"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 8))
        // A real reviewed recipe can be saved before any shop exists. Canceling
        // earlier must not have filled the reusable slot or created a pickup.
        tap(app.buttons["Review a recipe by hand"])
        fill(app.textFields["tonight.recipe.title"], "No-shop rice dinner")
        fill(app.textFields["tonight.recipe.servings"], "1")
        fill(app.textFields["tonight.recipe.ingredient"], "Rice")
        fill(app.textFields["Amount, unknown if blank"], "1")
        tap(app.buttons["tonight.recipe.review"])
        tap(app.buttons["tonight.recipe.save"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 10))
        let recipe = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "No-shop rice dinner")).firstMatch
        tap(recipe)
        XCTAssertTrue(app.staticTexts["Some amounts or package prices still need review."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tonight.choose.")).firstMatch.isEnabled,
                       "No stock match cannot be offered as a pantry-based dinner")
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.tonight"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "No-shop rice dinner")).firstMatch.waitForExistence(timeout: 8))
        tap(app.navigationBars["Tonight"].buttons.firstMatch)
        XCTAssertTrue(app.buttons["dinnerStartPickup"].waitForExistence(timeout: 8), "Browse and canceled recipe review must leave the workspace without a pickup")
        XCTAssertFalse(app.buttons["tonight.apply"].exists)
    }
    private func fill(_ element: XCUIElement, _ value: String) {
        tap(element); element.typeText(value)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
    }
    private func tap(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<14 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
        element.tap()
    }
}
#endif
