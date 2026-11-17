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
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.tonight"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 8))
        XCTAssertTrue(empty.waitForExistence(timeout: 8))
        tap(app.navigationBars["Tonight"].buttons.firstMatch)
        XCTAssertTrue(app.buttons["dinnerStartPickup"].waitForExistence(timeout: 8), "Browse and canceled recipe review must leave the workspace without a pickup")
        XCTAssertFalse(app.buttons["tonight.apply"].exists)
    }
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 12), element.debugDescription)
        for _ in 0..<10 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
        element.tap()
    }
}
#endif
