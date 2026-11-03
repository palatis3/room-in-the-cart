import XCTest

/// Real visible entry, no seeded model data. Run only on the isolated DEBUG
/// workspace after the parent releases its simulator/accessibility audit lane.
@MainActor final class FreeJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Free-flow-failure") }
        app.terminate()
    }

    func testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop() throws {
        launch(reset: true)
        tap(element("openPickupList"))
        tap(element("ledgerStartShop"))
        fill("Tuesday family pickup", into: "ledgerShopName")
        tap(app.buttons["Start pickup"])
        XCTAssertTrue(element("ledgerImport").waitForExistence(timeout: 10))
        tap(app.tabBars.buttons["Dinners"])
        tap(element("Accepted dinners and Free reusable dinner"))
        tap(element("Save a familiar dinner"))
        fill("Wrap dinner", into: "Dinner name")
        fill("6", into: "Total servings")
        fill("Wraps", into: "Ingredient name")
        fill("6", into: "Amount, optional")
        fill("No sesame", into: "Ingredient exclusions, one per line")
        tap(app.buttons["Add serving group"])
        fill("Lunch", into: "Group name")
        fill("2", into: "Group servings")
        tap(app.switches["Protected group"])
        tap(element("Review"))
        tap(element("Save accepted dinner"))
        tap(app.buttons["Done"])
        tap(element("Choose for this pickup"))
        tap(element("dinnerApply"))
        dinnerRoot()
        assertText("Unscheduled")
        capture("Free-dinner-and-protected-lunch")
        restart()
        tap(app.tabBars.buttons["Dinners"])
        assertText("Wrap dinner")
        assertText("Unscheduled")

        // The existing Free flow currently transfers a reviewed pack price by
        // explicit manual entry. A future pack-choice bridge has its own gate.
        shopRoot()
        tap(element("newComparison"))
        fill("Wraps", into: "itemName")
        fill("6", into: "needed")
        fill("4", into: "aQuantity")
        fill("2", into: "aPrice")
        fill("3", into: "bQuantity")
        fill("1.50", into: "bPrice")
        tap(element("compare"))
        assertText("Item-only comparison")
        assertElementContains("bTotal", "3.00")
        assertElementContains("bPacks", "2")
        capture("Free-whole-packs-manual-price-review")
        shopRoot()
        tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"])
        assertText("Lunch")
        tap(app.buttons["Apply reviewed checkout copy"])
        tap(app.buttons["Review whole checkout"])
        fill("Family market", into: "Store", replacing: true)
        fill("Main branch", into: "Branch", replacing: true)
        fill("Tuesday 5 PM", into: "Pickup or delivery slot", replacing: true)
        fill("Retailer preview reviewed by shopper", into: "Source of these prices", replacing: true)
        tap(app.switches["Retailer total already includes all charges"])
        fill("3.00", into: "Inclusive total")
        tap(app.buttons["Save and evaluate checkout"])
        assertText("3.00")
        back(to: "Prepare retailer handoff")
        tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["Freeze reviewed basket"])
        tap(app.buttons["Copy dated list"])
        capture("Free-frozen-placement-unconfirmed")
        restart()
        shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        assertText("Frozen · placement unconfirmed")
        tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["I placed this order"])
        back(to: "Record what came home")
        tap(app.buttons["Record what came home"])
        choose("Original order line", value: "Wraps")
        choose("What happened", value: "Partial fill")
        fill("4", into: "Physical amount received")
        fill("4", into: "Confirmed usable amount (optional)")
        tap(app.switches["I checked the identity, units and meal constraints"])
        fill("segment-1", into: "Segment ID (distinct for each split delivery)")
        tap(app.buttons["Save observed arrival"])
        assertText("segment-1")
        capture("Free-observed-short-fill")
        tap(app.buttons["Review protected portions and repair meals"])
        assertText("Lunch")
        assertText("Still short")
        choose("Reviewed matching food need", value: "Wraps")
        fill("Two checked freezer wraps", into: "Actual food or freezer batch")
        fill("2", into: "Confirmed usable amount")
        tap(app.switches["I reviewed identity, exclusions and usable quantity"])
        tap(app.buttons["Confirm this separate stock lot"])
        choose("Affected meal need", value: "Wrap dinner")
        fill("Set aside two lunch wraps first. Use the two checked freezer wraps for dinner. Keep sesame excluded.", into: "Exact food, portions, exclusions and instructions")
        tap(app.buttons["Save reviewed repair instructions"])
        tap(app.buttons["Preview a dated cook instruction"])
        tap(app.buttons["Prepare complete dated instruction"])
        let instruction = app.textViews["Editable cook instruction"]
        reveal(instruction)
        XCTAssertTrue((instruction.value as? String ?? "").contains("set aside first"))
        XCTAssertTrue((instruction.value as? String ?? "").contains("No sesame"))
        tap(app.buttons["Save dated copy"])
        capture("Free-complete-cook-note")
        restart()
        shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Tell the cook"])
        assertText("Set aside two lunch wraps first")
        back(to: "Close the pickup")
        tap(app.buttons["Close the pickup"])
        fill("2.00", into: "Amount")
        fill("net-receipt-2", into: "Unique receipt or transaction evidence ID")
        tap(app.buttons["Save financial evidence"])
        assertText("2.00")
        tap(app.buttons["Close this pickup"])
        capture("Free-settlement-keeps-food-separate")
        tap(app.buttons["Review next shop"])
        tap(app.buttons["Create fresh next-shop draft"])
        tap(app.buttons["Open next shopping list"])
        assertText("Store not set")
        assertText("Date not set")
        tap(app.tabBars.buttons["Dinners"])
        dinnerRoot()
        tap(element("Accepted dinners and Free reusable dinner"))
        tap(element("Choose for this pickup"))
        tap(element("dinnerApply"))
        dinnerRoot()
        assertText("Wrap dinner")
        capture("Free-one-dinner-reused-for-next-shop")
        restart()
        tap(app.tabBars.buttons["Dinners"])
        assertText("Wrap dinner")
        assertText("Next shop")
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
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        let field = element(id); tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func reveal(_ target: XCUIElement) {
        for _ in 0..<14 { if target.exists && target.isHittable { return }; app.swipeUp() }
        for _ in 0..<14 { if target.exists && target.isHittable { return }; app.swipeDown() }
        XCTAssertTrue(target.exists, "Missing UI element: \(target)")
    }
    private func assertText(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists, "Missing visible text: \(text)")
    }
    private func assertElementContains(_ id: String, _ text: String) {
        let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text), target.label)
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        tap(app.buttons[value])
    }
    private func dinnerRoot() {
        for _ in 0..<8 {
            if element("Accepted dinners and Free reusable dinner").exists { return }
            let button = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(button.exists); button.tap()
        }
        XCTAssertTrue(element("Accepted dinners and Free reusable dinner").exists)
    }
    private func shopRoot() {
        tap(app.tabBars.buttons["Shop"])
        for _ in 0..<8 {
            if element("newComparison").exists { return }
            let button = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(button.exists); button.tap()
        }
        XCTAssertTrue(element("newComparison").exists)
    }
    private func back(to label: String) {
        for _ in 0..<8 {
            if app.buttons[label].exists { return }
            let button = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(button.exists); button.tap()
        }
        XCTAssertTrue(app.buttons[label].exists)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
