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
        tap(element("settings"))
        let consent = app.switches["Offer optional feedback after a pickup"]
        XCTAssertEqual(consent.value as? String, "0")
        enableSwitch("Offer optional feedback after a pickup")
        tap(app.buttons["Done"])
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
        XCTAssertFalse(app.buttons["Record how this pickup turned out"].exists)
        tap(app.buttons["Close this pickup"])
        tap(app.buttons["Record how this pickup turned out"])
        choose("What happened?", value: "I kept my plan")
        choose("Usual workflow", value: "My usual list or notes")
        choose("Compared with your usual workflow", value: "Same result")
        tap(app.buttons["Save my response"])
        assertText("I kept my plan")
        assertText("This pickup counts as zero additional benefit")
        tap(app.buttons["Remove this response"])
        tap(app.buttons["Stop offering feedback"])
        XCTAssertFalse(app.buttons["Record how this pickup turned out"].exists)
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
        tap(app.tabBars.buttons["Records"])
        tap(app.buttons["Family decision history"])
        tap(app.buttons["Saved pickup decisions on this iPhone"])
        assertText("Set aside two lunch wraps first")
        assertText("Meal outcome unconfirmed")
        capture("Free-saved-repair-decision-without-inferred-outcome")
    }

    func testPairingEnumerationUsesTheChosenScheduleAndDoesNotOfferItAgain() {
        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"])
        tap(element("dinnerStartPickup"))
        fill("Dinner plan", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("dinnerLibrary")); tap(element("ledgerNewTemplate"))
        fill("Pepper rice", into: "ledgerDinnerTitle"); fill("3", into: "ledgerDinnerServings")
        fill("Peppers", into: "Ingredient name"); fill("3", into: "Amount, optional")
        tap(element("ledgerReviewDinner")); tap(element("ledgerSaveDinner")); tap(app.buttons["Done"])
        tap(element("ledgerChooseTemplate")); tap(element("dinnerApply")); dinnerRoot()
        tap(app.buttons["Pairing and fallback evidence"])
        tap(app.buttons["Load chosen dinners and protected serving groups"])
        tap(app.buttons["Find accepted dinners not chosen for this pickup"])
        assertText("No new pairing; these dinners are already selected.")
        capture("P02-accepted-library-current-schedule")
    }

    func testFreePickupRepairKeepsTheNeedOpenWhenAcceptedFallbackToolsAreUnavailable() {
        launch(reset: true)
        tap(element("urgentRepairShortcut"))
        fill("Peppers", into: "Food that is short")
        fill("Wednesday rice", into: "Meal or purpose")
        fill("4", into: "Required amount")
        fill("1", into: "Usable amount available now")
        enableSwitch("I checked this food’s identity and usable amount")
        tap(app.buttons["Save need and repair meal"])
        tap(app.buttons["Recover with an accepted dinner"])
        assertText("This assisted tool requires paid access.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertText("Free manual meal repair")
        assertText("Open meal need")
    }

    func testFreeCookCorrectionAndExplicitRecipientAcknowledgment() {
        launch(reset: true)
        tap(element("urgentRepairShortcut"))
        fill("Beans", into: "Food that is short")
        fill("Soup", into: "Meal or purpose")
        fill("4", into: "Required amount")
        fill("1", into: "Usable amount available now")
        enableSwitch("I checked this food’s identity and usable amount")
        tap(app.buttons["Save need and repair meal"])
        tap(app.buttons["Preview a dated cook instruction"])
        tap(app.buttons["Prepare complete dated instruction"])
        tap(app.buttons["Save dated copy"])
        tap(app.buttons["Review correction"])
        assertText("Complete current instruction")
        tap(app.buttons["Copy reviewed correction"])
        assertText("Copied. Mark the version sent only after sending it.")
        fill("Ana", into: "handoffRecipient")
        tap(app.buttons["I sent this version to this recipient"])
        assertText("Acknowledgment unknown")
        tap(app.buttons["The recipient acknowledged this version"])
        assertText("Recipient acknowledgment reported")
        capture("P06-Free-cook-acknowledged-version")
    }

    func testCorrectFreezerBatchAndReadReservationsAfterRestart() {
        launch(reset: true)
        tap(element("urgentRepairShortcut"))
        fill("Wraps", into: "Food that is short")
        fill("Dinner", into: "Meal or purpose")
        fill("4", into: "Required amount")
        fill("0", into: "Usable amount available now")
        enableSwitch("I checked this food’s identity and usable amount")
        tap(app.buttons["Save need and repair meal"])
        choose("Reviewed matching food need", value: "Dinner")
        fill("Opened freezer wraps", into: "Actual food or freezer batch")
        fill("3", into: "Confirmed usable amount")
        enableSwitch("Use this batch first")
        enableSwitch("I reviewed identity, exclusions and usable quantity")
        tap(app.buttons["Confirm this separate stock lot"])
        let batch = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "stockBatch-")).firstMatch
        tap(batch)
        assertText("Dinner · 3")
        fill("1", into: "Confirmed usable amount")
        enableSwitch("I reviewed identity, exclusions and usable quantity")
        tap(app.buttons["Save reviewed batch"])
        restart()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Repair a meal"])
        assertText("Still short: 3")
        tap(batch)
        assertText("Dinner · 1")
        assertText("Unreserved: 0")
        capture("E06-corrected-freezer-reservations-after-restart")
    }

    func testUrgentRepairWithoutAnOrderPersistsAcrossRestart() throws {
        launch(reset: true)
        tap(element("urgentRepairShortcut"))
        fill("Tortillas", into: "Food that is short")
        fill("Wednesday supper", into: "Meal or purpose")
        fill("6", into: "Required amount")
        fill("2", into: "Usable amount available now")
        enableSwitch("I checked this food’s identity and usable amount")
        fill("3", into: "Usable amount available now", replacing: true)
        XCTAssertFalse(app.buttons["Save need and repair meal"].isEnabled)
        enableSwitch("I checked this food’s identity and usable amount")
        tap(app.buttons["Save need and repair meal"])
        assertText("Open meal need")
        assertText("Wednesday supper")
        capture("Free-urgent-need-before-shopping")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        fill("Beans", into: "Food that is short")
        fill("Thursday lunch", into: "Meal or purpose")
        fill("4", into: "Required amount")
        fill("1", into: "Usable amount available now")
        enableSwitch("I checked this food’s identity and usable amount")
        tap(app.buttons["Save need and repair meal"])
        assertText("Thursday lunch")
        restart()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Repair a meal"])
        assertText("Open meal need")
        assertText("Wednesday supper")
        assertText("Thursday lunch")
    }

    func testStagedListCanReturnToOriginalAndMergeADuplicateAfterRestart() throws {
        launch(reset: true)
        tap(element("openPickupList"))
        tap(element("ledgerStartShop"))
        fill("Saturday market", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(element("ledgerImport"))
        fill("2 wraps", into: "ledgerImportText")
        tap(element("ledgerReviewImport"))
        tap(app.buttons["Edit original text"])
        XCTAssertEqual(element("ledgerImportText").value as? String, "2 wraps")
        tap(element("ledgerReviewImport"))
        tap(element("ledgerCommitImport"))
        let line = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-")).firstMatch
        reveal(line)
        let id = line.identifier
        restart()
        tap(element("openPickupList"))
        reveal(element(id))
        tap(element("ledgerImport"))
        fill("2 wraps", into: "ledgerImportText")
        tap(element("ledgerReviewImport"))
        XCTAssertFalse(element("ledgerCommitImport").isEnabled)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "How to add this line")).firstMatch)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Merge same need")).firstMatch)
        tap(element("ledgerCommitImport"))
        reveal(element(id))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-")).count, 1)
        tap(element(id.replacingOccurrences(of: "ledgerInspect-", with: "ledgerCheck-")))
        tap(app.buttons["Recently checked, Handled and Trash"])
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reopen ")).firstMatch)
        XCTAssertTrue(app.navigationBars["List history"].exists)
        tap(app.buttons["Done"])
        reveal(element(id))
        tap(element(id))
        tap(app.buttons["Mark handled by someone"])
        fill("Sam", into: "ledgerHandledBy")
        tap(app.buttons["Mark handled"])
        returnToVisibleAnchor(element("ledgerHistory"))
        tap(element("ledgerHistory"))
        assertText("Handled by Sam")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reopen ")).firstMatch)
        tap(app.buttons["Done"])
        tap(element(id))
        tap(app.buttons["Review removing this item"])
        tap(app.buttons["Move item to Trash"])
        restart()
        tap(element("openPickupList"))
        XCTAssertFalse(element(id).exists)
        tap(element("ledgerHistory"))
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restore ")).firstMatch)
        tap(app.buttons["Done"])
        reveal(element(id))
    }

    func testManualListOrderSurvivesRestartAndOpensLargePrint() throws {
        launch(reset: true)
        tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Market walk", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport")); fill("Apples\nMilk", into: "ledgerImportText")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        tap(element("ledgerListOptions")); tap(app.buttons["List order and aisles"])
        choose("List order", value: "Manual item order")
        tap(app.buttons["Move Milk up"]); tap(element("saveListOrder"))
        restart(); tap(element("openPickupList"))
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(items.firstMatch.label.contains("Milk"))
        tap(element("ledgerListOptions")); tap(app.buttons["Large-print list"])
        XCTAssertTrue(element("printShoppingList").waitForExistence(timeout: 8))
        XCTAssertTrue(element("printShoppingList").isEnabled)
        assertText("Milk"); assertText("Apples")
        capture("Large-print-shopping-list")
        tap(app.buttons["Done"]); XCTAssertTrue(element("ledgerListOptions").exists)
    }

    func testFirstPickupCanStartFromDinnersAndReviewAnEditablePattern() {
        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"])
        tap(element("dinnerStartPickup"))
        fill("First dinner pickup", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(app.buttons["Review a dinner idea"])
        choose("Starting meal", value: "Bean and cabbage wraps")
        tap(app.buttons["Prepare editable idea"])
        tap(app.buttons["Review prepared idea"])
        tap(element("ledgerReviewDinner"))
        assertText("Bean and cabbage wraps")
        assertText("Shredded cabbage")
        assertText("Usable yield is unconfirmed")
        capture("First-pickup-editable-dinner-pattern")
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
