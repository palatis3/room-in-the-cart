import XCTest

/// Shipping app, ordinary typed entry and native navigation. Relaunch uses the
/// same durable workspace with no prefilled model or replacement app root.
@MainActor final class NavigationRestorationUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app.terminate() }

    func testKillRelaunchRestoresRecordsDetailAndIndependentShoppingList() {
        launch(reset: true)
        tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Restoration Saturday pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        XCTAssertTrue(app.navigationBars["Restoration Saturday pickup"].waitForExistence(timeout: 8))
        tap(app.tabBars.buttons["Records"])
        tap(app.tabBars.buttons["Shop"])
        XCTAssertTrue(app.navigationBars["Restoration Saturday pickup"].exists, "Changing tabs keeps the originating stack")
        tap(app.navigationBars["Restoration Saturday pickup"].buttons["Shop"])
        tap(element("newComparison"))
        fill("Restoration family wraps", into: "itemName")
        fill("12", into: "needed"); fill("8", into: "aQuantity"); fill("3", into: "aPrice")
        fill("6", into: "bQuantity"); fill("2", into: "bPrice")
        tap(element("compare")); tap(element("saveComparison"))
        tap(app.tabBars.buttons["Records"]); tap(element("savedComparison"))
        XCTAssertTrue(element("editComparison").waitForExistence(timeout: 8))
        capture("Records detail before process termination")
        app.terminate(); launch(reset: false)
        XCTAssertTrue(app.tabBars.buttons["Records"].isSelected)
        XCTAssertTrue(element("editComparison").waitForExistence(timeout: 10), "The same saved comparison should reopen without selecting its row again")
        XCTAssertTrue(app.staticTexts["Restoration family wraps"].exists)
        capture("Records detail restored after process relaunch")
        // Open the independent shop route, then kill there too.
        tap(app.tabBars.buttons["Shop"])
        let back = app.navigationBars.buttons["Shop"]
        if back.exists { tap(back) }
        tap(element("openPickupList"))
        XCTAssertTrue(app.navigationBars["Restoration Saturday pickup"].waitForExistence(timeout: 8))
        app.terminate(); launch(reset: false)
        XCTAssertTrue(app.tabBars.buttons["Shop"].isSelected)
        XCTAssertTrue(app.navigationBars["Restoration Saturday pickup"].waitForExistence(timeout: 10))
        tap(app.tabBars.buttons["Records"])
        XCTAssertTrue(element("editComparison").waitForExistence(timeout: 8), "Both explicit stacks survive the second process death")
        capture("Independent Shop and Records stacks restored")
    }
    func testKillRelaunchRestoresSelectedDinnersTabWithoutRestoringUnsavedComparison() {
        launch(reset: true)
        tap(element("newComparison")); fill("Unsaved draft", into: "itemName")
        tap(app.tabBars.buttons["Dinners"])
        app.terminate(); launch(reset: false)
        XCTAssertTrue(app.tabBars.buttons["Dinners"].isSelected)
        tap(app.tabBars.buttons["Shop"])
        XCTAssertTrue(element("newComparison").waitForExistence(timeout: 8))
        XCTAssertFalse(element("itemName").exists, "Transient unsaved forms do not become restored records")
        capture("Selected Dinners tab restored")
    }
    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Shop"].waitForExistence(timeout: 15))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ element: XCUIElement) { reveal(element); XCTAssertTrue(element.isHittable, element.debugDescription); element.tap() }
    private func fill(_ text: String, into id: String) {
        let field = element(id); tap(field); app.typeText(text)
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let bounds = app.frame
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.midX, dy: bounds.height * 0.68))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.midX, dy: bounds.height * 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, element.debugDescription)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
