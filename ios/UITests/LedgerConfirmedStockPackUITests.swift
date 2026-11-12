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
        enterReviewedPacks()
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

    func testHidingProtectedLunchKeepsTotalAndTwoWholePacksWithoutStock() {
        createWrapList()
        tap(app.buttons["Inspect wraps"])
        XCTAssertFalse(element("ledgerShowProtectedNeeds").exists)
        tap(app.buttons["Protect an amount for lunch or another need"])
        fill("School lunch", into: "Who or what this is for")
        fill("2", into: "Amount, unknown if blank")
        tap(element("ledgerProtectedReservation"))
        tap(app.buttons["Within 12 items"])
        tap(app.buttons["Save protected need"])
        assertText("Protected: School lunch")

        let visibility = app.switches["ledgerShowProtectedNeeds"]
        reveal(visibility)
        XCTAssertEqual(visibility.value as? String, "1")
        // SwiftUI exposes a row-wide switch containing the actual trailing
        // control; tapping the row center can hit its noninteractive label.
        visibility.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(visibility.value as? String, "0")
        XCTAssertFalse(app.staticTexts["Protected: School lunch"].exists)
        assertText("Hidden protected needs still count toward the total and whole packs.")
        let total = element("ledgerIngredientTotal")
        reveal(total)
        XCTAssertEqual(total.label, "12 items")

        tap(element("ledgerPackChoice"))
        // The reservation must remain protected, not merely absorbed by the
        // unchanged imported total after its row disappears from the detail.
        XCTAssertTrue(app.staticTexts["Protected inside that amount, 2 items"].waitForExistence(timeout: 5))
        enterReviewedPacks()
        tap(element("ledgerReviewPacks"))
        let packs = element("ledgerPackCount-a")
        reveal(packs)
        XCTAssertEqual(packs.label, "Whole packs to buy, 2")
        capture("hidden-lunch-still-needs-two-eight-packs")
        tap(app.buttons["Cancel"])
        reveal(visibility)
        XCTAssertEqual(visibility.value as? String, "0")
        visibility.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        assertText("Protected: School lunch")

        app.terminate(); launch(reset: false); shopRoot()
        tap(element("openPickupList")); tap(app.buttons["Inspect wraps"])
        assertText("Protected: School lunch")
        reveal(total)
        XCTAssertEqual(total.label, "12 items")
    }

    private func createWrapList() {
        launch(reset: true)
        tap(element("openPickupList"))
        tap(element("ledgerImport"))
        let original = editableElement("ledgerImportText")
        tap(original); app.typeText("12 wraps")
        dismissKeyboard()
        XCTAssertEqual(original.value as? String, "12 wraps")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
    }

    private func createListAndConfirmStock(amount: String) {
        createWrapList()
        shopRoot(); tap(app.buttons["Review checkout"]); tap(app.buttons["Continue to checkout review"])
        tap(app.buttons["Apply reviewed checkout copy"])
        shopRoot(); tap(element("openPickupList")); tap(app.buttons["Inspect wraps"])
        tap(app.buttons["Confirm pantry or freezer food"])
        fill("Checked freezer wraps", into: "Actual food or freezer batch")
        let usableAmount = editableElement("Confirmed usable amount")
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
    private func editableElement(_ id: String) -> XCUIElement {
        // Persistent labels can share an input's accessible name. Select only
        // an editable control, including lazily materialized multiline fields.
        let types: [XCUIElement.ElementType] = [.textField, .textView, .secureTextField, .searchField]
        return app.descendants(matching: .any).matching(identifier: id)
            .matching(NSPredicate(format: "elementType IN %@", types.map { $0.rawValue })).firstMatch
    }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func fill(_ text: String, into id: String) {
        tap(editableElement(id)); app.typeText(text)
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
    }
    private func enterReviewedPacks() {
        let fields = [
            ("First pack label", "Eight wraps"), ("First pack usable amount", "8"), ("First pack price, USD", "3.00"),
            ("Second pack label", "Six wraps"), ("Second pack usable amount", "6"), ("Second pack price, USD", "2.50"),
            ("Where you checked these packs and prices", "Reviewed shelf")
        ]
        // These are consecutive fields on one form. Finish editing once after entering the evidence source.
        for (label, value) in fields {
            let field = editableElement(label)
            reveal(field, keyboardDone: app.buttons["Done"])
            field.tap()
            field.typeText(value)
            XCTAssertEqual(field.value as? String, value, label)
        }
        dismissKeyboard()
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
    private func reveal(_ target: XCUIElement, keyboardDone: XCUIElement? = nil) {
        for attempt in 0..<20 {
            let bounds = app.frame
            let bottom = keyboardDone.flatMap { $0.exists ? $0.frame.minY : nil } ?? bounds.maxY
            let height = bottom - bounds.minY
            let frame = target.exists ? target.frame : .zero
            if !frame.isEmpty && target.isHittable && frame.midY < bottom { return }
            let upward = frame.isEmpty ? attempt < 13 : frame.midY > bounds.minY + height * 0.5
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.width * 0.5, dy: height * (upward ? 0.78 : 0.28)))
            let end = origin.withOffset(CGVector(dx: bounds.width * 0.5, dy: height * (upward ? 0.28 : 0.78)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal " + target.debugDescription)
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
