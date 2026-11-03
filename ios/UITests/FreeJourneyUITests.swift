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
        tap(app.buttons["ledgerCreateShop"])
        XCTAssertTrue(element("ledgerImport").waitForExistence(timeout: 10))
        tap(app.tabBars.buttons["Dinners"])
        tap(element("dinnerLibrary"))
        tap(element("ledgerNewTemplate"))
        fill("Wrap dinner", into: "ledgerDinnerTitle")
        fill("6", into: "ledgerDinnerServings")
        fill("Wraps", into: "Ingredient name")
        fill("6", into: "Amount, optional")
        fill("No sesame", into: "Ingredient exclusions, one per line")
        tap(app.buttons["Add serving group"])
        fill("Lunch", into: "Group name")
        fill("2", into: "Group servings")
        enableSwitch("Protected group")
        tap(element("ledgerReviewDinner"))
        assertText("Lunch")
        tap(element("ledgerSaveDinner"))
        tap(app.buttons["Done"])
        tap(element("ledgerChooseTemplate"))
        tap(element("dinnerApply"))
        dinnerRoot()
        assertText("Unscheduled")
        capture("Free-dinner-and-protected-lunch")
        restart()
        tap(app.tabBars.buttons["Dinners"])
        assertText("Wrap dinner")
        assertText("Unscheduled")

        shopRoot()
        tap(element("openPickupList"))
        tap(app.buttons["Inspect Wraps"])
        tap(element("ledgerPackChoice"))
        fill("Four wraps", into: "First pack label")
        fill("4", into: "First pack usable amount")
        fill("2", into: "First pack price, USD")
        fill("Three wraps", into: "Second pack label")
        fill("3", into: "Second pack usable amount")
        fill("1.50", into: "Second pack price, USD")
        fill("Retailer shelf checked today", into: "Where you checked these packs and prices")
        tap(element("ledgerReviewPacks"))
        assertText("Item-only comparison")
        assertText("3.00")
        tap(element("ledgerChoosePack-b"))
        assertText("Pack choice saved for checkout review.")
        capture("Free-whole-packs-saved-for-checkout-review")
        tap(element("ledgerPackDone"))
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
        enableSwitch("Retailer total already includes all charges")
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
        enableSwitch("I checked the identity, units and meal constraints")
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
        enableSwitch("I reviewed identity, exclusions and usable quantity")
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
        tap(element("pickupOpenCreatedNextList"))
        assertText("Store not set")
        assertText("Date not set")
        tap(app.tabBars.buttons["Dinners"])
        dinnerRoot()
        tap(element("dinnerLibrary"))
        tap(element("ledgerChooseTemplate"))
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
