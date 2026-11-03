import XCTest

/// Visible navigation on an isolated Free workspace, without seeded account authority.
@MainActor final class ContextualNavigationUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Contextual-navigation-failure") }
        app.terminate()
    }

    func testUnknownProduceWeightUsesSavedWholePickupCapAndBillingIncrement() {
        enterWeighedPickup(knownTax: true)
    }

    func testUnknownTaxKeepsWeighedPickupUnresolved() {
        enterWeighedPickup(knownTax: false)
    }

    private func enterWeighedPickup(knownTax: Bool) {
        launch(reset: true)
        shopRoot(); tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Weighed produce", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport")); fill("1 apples\n1 rice", into: "ledgerImportText")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"]); tap(app.buttons["Continue to checkout review"])
        tap(app.buttons["Apply reviewed checkout copy"]); tap(app.buttons["Review whole checkout"])
        fill("Family market", into: "Store", replacing: true)
        fill("Main branch", into: "Branch", replacing: true)
        fill("Tuesday 5 PM", into: "Pickup or delivery slot", replacing: true)
        fill("Retailer quote", into: "Source of these prices", replacing: true)
        fill("38", into: "Spending cap", replacing: true)
        fill("34", into: "rice")
        fill("0", into: "Fee below threshold or fixed fee")
        fill("0", into: "Eligible discount")
        fill("0", into: "Deposits and other charges")
        if knownTax { fill("0", into: "Tax") }
        tap(app.buttons["Save and evaluate checkout"])
        tap(element("checkout.weightReview"))
        tap(element("checkout.weightLine")); tap(app.buttons["apples"])
        fill("2", into: "checkout.weightRate"); fill("0.01", into: "checkout.weightIncrement")
        if !knownTax {
            reveal(element("checkout.weightUnresolved"))
            capture("S05-unknown-tax-keeps-weight-conditional")
            return
        }
        let result = element("checkout.maximumWeight")
        reveal(result)
        XCTAssertTrue(result.label.contains("2 pounds") || (result.value as? String)?.contains("2 pounds") == true, result.debugDescription)
        for (id, amount) in [("checkout.maximumLineCharge", "$4.00"), ("checkout.maximumTotal", "$38.00")] {
            let row = element(id)
            reveal(row)
            XCTAssertTrue(row.label.contains(amount) || (row.value as? String)?.contains(amount) == true, row.debugDescription)
        }
        capture("S05-billed-weight-under-saved-cap")
        tap(app.navigationBars["Check price by weight"].buttons["Whole checkout"])
        XCTAssertTrue(app.navigationBars["Whole checkout"].waitForExistence(timeout: 5))
        let price = app.textFields["apples"]
        reveal(price)
        XCTAssertTrue(price.value as? String == price.placeholderValue || price.value as? String == "", price.debugDescription)
    }

    func testFreeContextualRoutesKeepPrivateAndSharedWorkSeparate() throws {
        launch(reset: true)
        XCTAssertFalse(element("shop.familyInbox").exists)
        tap(app.tabBars.buttons["Records"])
        XCTAssertFalse(element("records.managedViews").exists)
        shopRoot()
        tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Context route pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport")); fill("2 wraps", into: "ledgerImportText")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"]); tap(app.buttons["Apply reviewed checkout copy"])
        tap(app.buttons["Review whole checkout"])
        tap(element("checkout.twoStoreQuotes"))
        XCTAssertTrue(app.navigationBars["Two store trips"].waitForExistence(timeout: 8))
        assertText("Same commitments at both stores")
        capture("Checkout-direct-two-store-quotes")
        back(to: "Save and evaluate checkout")
        fill("Family market", into: "Store", replacing: true)
        fill("Main branch", into: "Branch", replacing: true)
        fill("Tuesday 5 PM", into: "Pickup or delivery slot", replacing: true)
        fill("Retailer preview", into: "Source of these prices", replacing: true)
        enableSwitch("Retailer total already includes all charges")
        fill("3.00", into: "Inclusive total")
        tap(app.buttons["Save and evaluate checkout"])
        back(to: "Prepare retailer handoff"); tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["Freeze reviewed basket"]); tap(app.buttons["I placed this order"])
        back(to: "Tell the cook"); tap(app.buttons["Tell the cook"])
        tap(element("cook.currentSharedView"))
        assertText("Your private cook note is not copied here")
        XCTAssertFalse(element("cook.openSharedComposer").exists)
        capture("Cook-distinct-private-copy-and-current-view")
        back(to: "Start the next shop"); tap(app.buttons["Start the next shop"])
        tap(app.buttons["Create fresh next-shop draft"])
        tap(element("nextShop.reuseDinner"))
        XCTAssertTrue(app.navigationBars["Dinner library"].waitForExistence(timeout: 10))
        assertText("One accepted dinner can be your Free reusable dinner")
        assertText("No accepted dinners yet.")
        XCTAssertTrue(element("ledgerNewTemplate").exists)
        capture("Next-shop-direct-Free-dinner-library")
    }

    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(element("newComparison").waitForExistence(timeout: 15))
    }
    private func restart() { app.terminate(); launch(reset: false) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control)
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        let field = element(id); tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func reveal(_ target: XCUIElement) {
        for attempt in 0..<24 {
            if target.exists && target.isHittable { return }
            let area = scrollableArea()
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            scrollContent(upward: upward)
        }
        XCTAssertTrue(target.exists && target.isHittable, "Missing actionable UI element: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        let bounds = app.frame
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY }.min() ?? bounds.maxY
        let barBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame.maxY }.max() ?? bounds.minY + 88
        let top = max(bounds.minY + 88, min(barBottom + 12, keyboardTop - 140))
        let bottom = min(bounds.maxY - 100, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = scrollableArea(), bounds = app.frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertText(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists && target.isHittable, "Missing visible text: \(text)")
    }
    private func assertElementContains(_ id: String, _ text: String) {
        let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text), target.label)
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        tap(app.buttons[value])
    }
    private func dinnerRoot() { returnToVisibleAnchor(element("dinnerLibrary")) }
    private func shopRoot() {
        tap(app.tabBars.buttons["Shop"])
        returnToVisibleAnchor(element("newComparison"))
    }
    private func back(to label: String) {
        returnToVisibleAnchor(app.buttons.matching(identifier: label).firstMatch)
    }
    private func returnToVisibleAnchor(_ target: XCUIElement) {
        for _ in 0..<8 {
            if target.exists {
                // A covered parent can still exist in the accessibility tree.
                // Scroll only to reveal it, and return only if it is actionable.
                for _ in 0..<2 {
                    if target.isHittable { return }
                    scrollContent(upward: true)
                }
                for _ in 0..<4 {
                    if target.isHittable { return }
                    scrollContent(upward: false)
                }
                if target.isHittable { return }
            }
            let leading = app.navigationBars.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && $0.identifier != "settings" && $0.frame.midX < app.frame.midX
            }.sorted { $0.frame.minX < $1.frame.minX }
            guard let button = leading.first else {
                XCTFail("No visible back control while returning to \(target)")
                return
            }
            button.tap()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Root or destination is not visible: \(target)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
