import XCTest

/// Unseeded production routes and isolated local persistence. Run in the parent's
/// exclusive simulator acceptance lane; no account, retailer, or provider calls.
@MainActor final class LedgerConfirmedStockPackUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "confirmed-stock-pack-failure"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        app.terminate()
    }

    func testTwelveNeededEightConfirmedEightPerPackReviewsOneWholePack() {
        createListAndConfirmStock(amount: "8")
        tap(element("ledgerPackChoice"))
        fill("Eight wraps", into: "First pack label")
        fill("8", into: "First pack usable amount")
        fill("3.00", into: "First pack price, USD")
        fill("Six wraps", into: "Second pack label")
        fill("6", into: "Second pack usable amount")
        fill("2.50", into: "Second pack price, USD")
        fill("Reviewed shelf", into: "Where you checked these packs and prices")
        tap(element("ledgerReviewPacks"))
        let count = element("ledgerPackCount-a"); reveal(count)
        XCTAssertTrue(count.label.contains("1"), count.label)
        assertText("Confirmed food allocated to this need")
        capture("twelve-needed-eight-confirmed-one-eight-pack")
        tap(element("ledgerChoosePack-a")); tap(element("ledgerPackDone"))
        shopRoot(); tap(app.buttons["Review checkout"]); tap(app.buttons["Continue to checkout review"])
        assertText("Confirmed at home for this need: 8")
        assertText("Purchased usable amount: 8")
        tap(app.buttons["Apply reviewed checkout copy"])
        app.terminate(); launch(reset: false); shopRoot()
        tap(element("openPickupList")); tap(app.buttons["Inspect wraps"])
        assertText("Confirmed at home for this need: 8")
        capture("confirmed-stock-pack-choice-durable-after-restart")
    }

    func testFullyCoveredSavesUseAtHomePlanWithoutPurchasedItemOrRetailerOrder() {
        createListAndConfirmStock(amount: "12")
        tap(element("ledgerPackChoice")); tap(element("ledgerReviewAtHome"))
        assertText("Use confirmed food at home · no purchase needed")
        XCTAssertFalse(element("ledgerChoosePack-a").exists)
        tap(element("ledgerUseAtHome")); tap(element("ledgerPackDone"))
        shopRoot(); tap(app.buttons["Review checkout"]); tap(app.buttons["Continue to checkout review"])
        tap(element("ledgerSaveAtHomePlan"))
        assertText("No retailer order was created.")
        assertText("Meal needs kept in this plan")
        XCTAssertFalse(app.buttons["Prepare retailer handoff"].exists)
        XCTAssertFalse(app.buttons["I placed this order"].exists)
        capture("fully-covered-explicit-use-at-home-plan")
        app.terminate(); launch(reset: false); shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        XCTAssertFalse(app.buttons["Prepare retailer handoff"].exists)
        tap(app.buttons["Use-at-home plan"])
        assertText("No retailer order was created.")
        capture("use-at-home-plan-durable-without-retailer-placement")
    }

    private func createListAndConfirmStock(amount: String) {
        launch(reset: true)
        tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Confirmed stock packs", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport"))
        let original = element("ledgerImportText")
        tap(original); app.typeText("12 wraps")
        dismissKeyboard()
        XCTAssertEqual(original.value as? String, "12 wraps")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"]); tap(app.buttons["Continue to checkout review"])
        tap(app.buttons["Apply reviewed checkout copy"])
        shopRoot(); tap(element("openPickupList")); tap(app.buttons["Inspect wraps"])
        tap(app.buttons["Confirm pantry or freezer food"])
        fill("Checked freezer wraps", into: "Actual food or freezer batch")
        let usableAmount = element("Confirmed usable amount")
        tap(usableAmount); app.typeText(amount)
        dismissKeyboard()
        XCTAssertEqual(usableAmount.value as? String, amount)
        enable("I reviewed identity, exclusions and usable quantity")
        tap(app.buttons["Confirm this separate stock lot"])
        let batch = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "stockBatch-")).firstMatch
        reveal(batch); XCTAssertTrue(batch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("ledgerPackChoice").waitForExistence(timeout: 8))
    }
    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Shop"].waitForExistence(timeout: 15))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func fill(_ text: String, into id: String) {
        tap(element(id)); app.typeText(text)
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
    }
    private func dismissKeyboard() {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable, "The editor must offer a reachable keyboard dismissal control")
        done.tap()
    }
    private func enable(_ id: String) {
        let control = app.switches[id]; reveal(control)
        if control.value as? String == "0" { control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(control.value as? String, "1")
    }
    private func reveal(_ target: XCUIElement) {
        for attempt in 0..<20 {
            if target.exists && target.isHittable { return }
            let upward = target.exists && !target.frame.isEmpty ? target.frame.midY > app.frame.midY : attempt < 13
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.78 : 0.28))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.28 : 0.78))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(target.exists && target.isHittable, target.debugDescription)
    }
    private func shopRoot() {
        tap(app.tabBars.buttons["Shop"])
        for _ in 0..<8 {
            if element("newComparison").exists && element("newComparison").isHittable { return }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        reveal(element("newComparison"))
    }
    private func assertText(_ text: String) {
        let target = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists, text)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
