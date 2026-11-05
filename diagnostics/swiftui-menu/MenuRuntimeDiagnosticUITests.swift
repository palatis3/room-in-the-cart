import XCTest

@MainActor
final class MenuRuntimeDiagnosticUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(fixture: Bool = false) {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if fixture {
            app.launchArguments.append("--fixture-menu-context")
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Menu diagnostic"].waitForExistence(timeout: 10))
        assertUnchanged()
    }

    func testPickupControlWithoutOpeningMenu() {
        launch()
        XCTContext.runActivity(named: "Pickup control without opening a Menu") { _ in
            XCTAssertTrue(app.buttons["probe.pickupMenu"].exists)
            tapOutsideMenu()
            assertUnchanged()
        }
    }

    func testFixtureControlWithoutOpeningMenu() {
        launch(fixture: true)
        XCTContext.runActivity(named: "Fixture control without opening a Menu") { _ in
            XCTAssertTrue(app.buttons["probe.fixtureMenu"].exists)
            tapOutsideMenu()
            assertUnchanged()
        }
    }

    func testOpenAndCancelSinglePickupMenu() {
        launch()
        openAndDismiss(menu: "probe.pickupMenu", option: "Start another pickup", name: "pickup Menu")
    }

    func testOpenAndCancelFixtureControlsMenu() {
        launch(fixture: true)
        openAndDismiss(menu: "probe.fixtureMenu", option: "Advance fixture revision", name: "fixture Menu")
    }

    private func openAndDismiss(menu identifier: String, option label: String, name: String) {
        let menu = app.buttons.matching(identifier: identifier).firstMatch
        let option = app.buttons[label].firstMatch
        XCTContext.runActivity(named: "Open \(name)") { _ in
            XCTAssertTrue(menu.waitForExistence(timeout: 8))
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(option.waitForExistence(timeout: 8))
            XCTAssertTrue(option.isHittable)
        }
        XCTContext.runActivity(named: "Dismiss \(name) without selection") { _ in
            tapOutsideMenu()
            XCTAssertTrue(option.waitForNonExistence(timeout: 8))
            assertUnchanged()
        }
    }

    private func tapOutsideMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).tap()
    }

    private func assertUnchanged() {
        XCTAssertEqual(app.staticTexts["probe.pickup"].label, "Selected pickup: Original pickup")
        XCTAssertEqual(app.staticTexts["probe.actions"].label, "Menu actions: 0")
    }
}
