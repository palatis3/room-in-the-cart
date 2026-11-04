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

    func testCancellingSystemShareKeepsTheFrozenPickupUnplaced() {
        launch(reset: true)
        openShoppingList()
        tap(element("ledgerStartShop"))
        fill("Test market pickup", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(element("ledgerImport"))
        fill("2 Wraps", into: "ledgerImportText")
        tap(element("ledgerReviewImport"))
        tap(element("ledgerCommitImport"))
        shopRoot()
        tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"])
        let apply = app.buttons["Apply reviewed checkout copy"]
        reveal(apply)
        if apply.frame.midY > scrollableArea().maxY { scrollContent(upward: true) }
        tap(apply)
        tap(app.buttons["Review whole checkout"])
        fill("Test market", into: "Store", replacing: true)
        fill("Main branch", into: "Branch", replacing: true)
        fill("Tuesday 5 PM", into: "Pickup or delivery slot", replacing: true)
        fill("Test checkout", into: "Source of these prices", replacing: true)
        enableSwitch("Retailer total already includes all charges")
        fill("3.00", into: "Inclusive total", requireDone: true)
        tap(app.buttons["Save and evaluate checkout"])
        back(to: "Prepare retailer handoff")
        tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["Freeze reviewed basket"])
        tap(app.buttons["Share dated list"])
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "header.closeButton", "Close")).firstMatch
        let closeReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closeReady], timeout: 15), .completed, app.debugDescription)
        close.tap()
        // The system sheet can expose Close while presentation is still settling.
        if !close.waitForNonExistence(timeout: 4) {
            XCTAssertTrue(close.isHittable, app.debugDescription)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 8), "The system share sheet stayed open after Close.")
        }
        assertText("Share cancelled")
        restart()
        shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        assertText("Frozen · placement unconfirmed")
        tap(app.buttons["Prepare retailer handoff"])
        assertText("Wraps")
        assertText("Share cancelled")
        capture("Retailer-share-cancelled-unplaced-after-relaunch")
    }

    func testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop() throws {
        avoidIOS17SnapshotLoggingCrash()
        func verifyChosenDinnerInWeek() {
            dinnerRoot()
            openMealWeek()
            let occurrence = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                               "dinnerOccurrence-", "Wrap dinner")).firstMatch
            reveal(occurrence)
        }
        launch(reset: true)
        tap(element("settings"))
        let consent = app.switches["Offer optional feedback after a pickup"]
        reveal(consent)
        XCTAssertEqual(consent.value as? String, "0")
        enableSwitch("Offer optional feedback after a pickup")
        tap(app.buttons["Done"])
        openShoppingList()
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
        verifyChosenDinnerInWeek()
        assertText("Unscheduled")
        capture("Free-dinner-and-protected-lunch")
        restart()
        tap(app.tabBars.buttons["Dinners"])
        verifyChosenDinnerInWeek()
        assertText("Unscheduled")

        shopRoot()
        openShoppingList()
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
        verifyChosenDinnerInWeek()
        capture("Free-one-dinner-reused-for-next-shop")
        restart()
        tap(app.tabBars.buttons["Dinners"])
        verifyChosenDinnerInWeek()
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
        fill("Peppers", into: "Ingredient name"); fill("3", into: "Amount, optional", requireDone: true)
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

    func testNextShopCanCancelThenOpenOneFreshShoppingList() {
        launch(reset: true)
        tap(element("urgentRepairShortcut"))
        fill("Rice", into: "Food that is short")
        fill("Dinner", into: "Meal or purpose")
        fill("3", into: "Required amount")
        fill("1", into: "Usable amount available now")
        enableSwitch("I checked this food’s identity and usable amount")
        tap(app.buttons["Save need and repair meal"])
        assertText("Open meal need")
        restart()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Start the next shop"])
        tap(app.buttons["Cancel"])
        XCTAssertTrue(app.navigationBars["Pickup"].exists)
        tap(app.buttons["Start the next shop"])
        tap(app.buttons["Create fresh next-shop draft"])
        tap(element("pickupOpenCreatedNextList"))
        assertText("Store not set")
        capture("Next-shop-reviewed-draft-opened")
        tap(app.tabBars.buttons["Records"])
        XCTAssertTrue(app.tabBars.buttons["Records"].isSelected)
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
        choose("Reviewed matching food need", value: "Wraps")
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
        tap(element("stockReview.preview"))
        enableSwitch("stockReview.effectsChecked")
        tap(element("stockReview.apply"))
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
        openShoppingList()
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
        openShoppingList()
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
        openShoppingList()
        XCTAssertFalse(element(id).exists)
        tap(element("ledgerHistory"))
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restore ")).firstMatch)
        tap(app.buttons["Done"])
        reveal(element(id))
    }

    func testManualListOrderSurvivesRestartAndOpensLargePrint() throws {
        func chooseListOption(_ label: String) {
            let menu = app.buttons.matching(identifier: "ledgerListOptions").firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 8))
            // iOS 17 can expose a nested Menu button with no computed XCTest hit point.
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            tap(app.buttons[label])
        }
        launch(reset: true)
        openShoppingList(); tap(element("ledgerStartShop"))
        fill("Market walk", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport")); fill("Apples\nMilk", into: "ledgerImportText")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        chooseListOption("List order and aisles")
        choose("List order", value: "Manual item order")
        tap(app.buttons["Move Milk up"]); tap(element("saveListOrder"))
        restart(); openShoppingList()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(items.firstMatch.label.contains("Milk"))
        chooseListOption("Large-print list")
        XCTAssertTrue(element("printShoppingList").waitForExistence(timeout: 8))
        XCTAssertTrue(element("printShoppingList").isEnabled)
        assertText("Milk"); assertText("Apples")
        capture("Large-print-shopping-list")
        tap(element("printShoppingList"))
        let cancelPrint = app.buttons["Cancel"]
        XCTAssertTrue(cancelPrint.waitForExistence(timeout: 12), app.debugDescription)
        tap(cancelPrint)
        XCTAssertTrue(cancelPrint.waitForNonExistence(timeout: 8), app.debugDescription)
        tap(app.buttons["Done"]); XCTAssertTrue(element("ledgerListOptions").exists)
    }

    func testFirstPickupCanStartFromDinnersAndReviewAnEditablePattern() {
        reviewAndApprovePattern(spanish: false)
    }

    func testMealWeekReservationDraftCannotFollowAnotherPickup() {
        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"]); tap(element("dinnerStartPickup"))
        fill("Original reservation pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        openMealWeek(); tapWeekRow(app.buttons["Protect a lunch or side"])
        fill("Fictional original lunch", into: "Food name", requireDone: true)
        fill("2", into: "Protected amount", requireDone: true)
        fill("Original pickup only", into: "Purpose, such as lunch", requireDone: true)
        openShoppingList(); tap(element("ledgerShopPicker")); tap(app.buttons["Start another pickup"])
        fill("Different reservation pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(app.tabBars.buttons["Dinners"])
        capture("S25-open-reservation-after-pickup-switch")
        XCTAssertTrue(app.staticTexts["Pickup selection changed"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["Review protected need"].exists)
        XCTAssertFalse(element("Food name").exists)
        dinnerRoot(); openMealWeek(); tapWeekRow(app.buttons["Protect a lunch or side"])
        let name = element("Food name")
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertNotEqual(name.value as? String, "Fictional original lunch")
        capture("S25-fresh-reservation-for-new-pickup")
    }

    func testMealWeekKeepsOriginalPickupWhenShopSelectionChanges() {
        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"]); tap(element("dinnerStartPickup"))
        fill("First fictional pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        openMealWeek()
        tap(element("dinnerWeekDisplay").buttons["Grid"])
        openShoppingList()
        tap(element("ledgerShopPicker")); tap(app.buttons["Start another pickup"])
        fill("Second fictional pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(app.tabBars.buttons["Dinners"])
        XCTAssertTrue(app.navigationBars["This week"].waitForExistence(timeout: 8))
        assertText("Pickup selection changed")
        XCTAssertFalse(element("dinnerWeekDisplay").exists)
        capture("S25-pickup-selection-change-keeps-original-week-scope")
        app.navigationBars["This week"].buttons.firstMatch.tap()
        openMealWeek()
        assertText("Second fictional pickup")
        XCTAssertTrue(element("dinnerWeekDisplay").exists)
    }

    func testEnglishMealWeekListAndGridShowDatedProtectedLunch() { verifyDatedMealWeek(spanish: false) }
    func testSpanishMealWeekListAndGridShowDatedProtectedLunch() { verifyDatedMealWeek(spanish: true) }
    func testDinnerMoveAcrossDisplayedWeeksKeepsLunchAndOccurrence() { verifyDatedMealWeek(spanish: false, moveAcrossWeek: true) }

    private func verifyDatedMealWeek(spanish: Bool, moveAcrossWeek: Bool = false) {
        func copy(_ english: String, _ translation: String) -> String { spanish ? translation : english }
        avoidIOS17SnapshotLoggingCrash()
        let dinner = copy("Roasted veggie tacos", "Tacos de verduras asadas")
        let food = copy("Flour tortillas", "Tortillas de harina")
        let purpose = copy("School lunch", "Almuerzo escolar")
        let tab = copy("Dinners", "Cenas")
        let assignDate = copy("Assign a date", "Asignar fecha")
        let weekTitle = copy("This week", "Esta semana")
        func applyFrom(_ editor: String, returnToPlan: Bool = true) {
            let apply = element("dinnerApply")
            tap(apply)
            XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
            let back = app.navigationBars[editor].buttons.firstMatch
            let backReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: back)
            XCTAssertEqual(XCTWaiter.wait(for: [backReady], timeout: 10), .completed)
            back.tap()
            if returnToPlan { dinnerRoot() }
        }
        launch(reset: true, spanish: spanish)
        tap(app.tabBars.buttons[tab]); tap(element("dinnerStartPickup"))
        fill(copy("Family grocery pickup", "Compra familiar"), into: "ledgerShopName")
        tap(element("ledgerCreateShop")); tap(element("dinnerManual"))
        fill(dinner, into: "ledgerDinnerTitle")
        fill("4", into: "ledgerDinnerServings", replacing: true)
        fill(copy("Corn tortillas", "Tortillas"), into: copy("Ingredient name", "Nombre del ingrediente"))
        fill("8", into: copy("Amount, optional", "Cantidad, opcional"))
        if !moveAcrossWeek { enableSwitch(assignDate) }
        tap(element("ledgerReviewDinner")); applyFrom(copy("Manual dinner", "Cena manual"))
        openMealWeek(title: weekTitle)
        if moveAcrossWeek {
            assertText("Unscheduled")
            let meal = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerOccurrence-")).firstMatch
            tapWeekRow(meal)
            enableSwitch(assignDate)
            tap(element("dinnerMoveReview"))
            assertText("Before: Unscheduled")
            applyFrom("Chosen dinner", returnToPlan: false)
            XCTAssertTrue(app.navigationBars[weekTitle].waitForExistence(timeout: 8))
            let protect = app.buttons["Protect a lunch or side"]
            for _ in 0..<16 {
                if protect.exists && protect.isHittable { break }
                scrollContent(upward: false)
            }
        }

        tapWeekRow(app.buttons[copy("Protect a lunch or side", "Proteger un almuerzo o acompañamiento")])
        XCTAssertTrue(app.navigationBars[copy("Protect food", "Proteger alimentos")].waitForExistence(timeout: 8))
        fill(food, into: copy("Food name", "Nombre del alimento"), requireDone: true)
        fill("2", into: copy("Protected amount", "Cantidad protegida"), requireDone: true)
        fill(purpose, into: copy("Purpose, such as lunch", "Finalidad, por ejemplo almuerzo"), requireDone: true)
        enableSwitch(assignDate)
        tap(app.buttons[copy("Review protected need", "Revisar necesidad protegida")])
        let reviewed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerPreviewNeed-")).firstMatch
        reveal(reviewed)
        XCTAssertTrue(reviewed.label.contains(copy("Purpose: ", "Finalidad: ") + purpose), reviewed.label)
        let date = DateFormatter(); date.locale = Locale(identifier: spanish ? "es_US" : "en_US"); date.dateStyle = .full
        XCTAssertTrue(reviewed.label.contains(date.string(from: Date())), reviewed.label)
        applyFrom(copy("Protect food", "Proteger alimentos"))
        openMealWeek(title: weekTitle)

        let chosen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerOccurrence-")).firstMatch
        let protected = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerProtected-")).firstMatch
        let display = element("dinnerWeekDisplay")
        reveal(protected)
        let dinnerID = chosen.identifier, lunchID = protected.identifier
        XCTAssertTrue(dinnerID.hasPrefix("dinnerOccurrence-") && lunchID.hasPrefix("dinnerProtected-"))
        for mode in [copy("List", "Lista"), copy("Grid", "Cuadrícula")] {
            let control = display.buttons[mode]
            tap(control)
            XCTAssertTrue(control.isSelected)
            reveal(protected)
            if !chosen.isHittable { reveal(chosen) }
            XCTAssertTrue(chosen.isHittable && protected.isHittable, "Meal and lunch should both be visible")
            XCTAssertEqual(chosen.identifier, dinnerID)
            XCTAssertEqual(protected.identifier, lunchID)
            XCTAssertTrue(chosen.label.contains(dinner), chosen.label)
            XCTAssertTrue(protected.label.contains(food) && protected.label.contains(purpose), protected.label)
            XCTAssertTrue(protected.label.contains(copy("2 units", "2 unidades")), protected.label)
            capture((spanish ? "es-US" : "en-US") + "-meal-week-" + mode)
        }
        // Native Back and each tab's navigation stack retain the week context.
        tap(app.tabBars.buttons[copy("Shop", "Compras")])
        tap(app.tabBars.buttons[tab])
        XCTAssertTrue(app.navigationBars[weekTitle].waitForExistence(timeout: 8))
        XCTAssertTrue(display.buttons[copy("Grid", "Cuadrícula")].isSelected)
        app.navigationBars[weekTitle].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 8))
        XCTAssertTrue(element("dinnerWeekEntry").isHittable)
        XCTAssertFalse(element("dinnerWeekDisplay").exists)
        capture((spanish ? "es-US" : "en-US") + "-Dinners-stable-return")
        openMealWeek(title: weekTitle)
        XCTAssertTrue(display.buttons[copy("Grid", "Cuadrícula")].isSelected)
        tapWeekRow(element(dinnerID))
        XCTAssertTrue(app.navigationBars[copy("Chosen dinner", "Cena elegida")].waitForExistence(timeout: 8), app.debugDescription)
        app.navigationBars[copy("Chosen dinner", "Cena elegida")].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[weekTitle].waitForExistence(timeout: 8))
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        tapWeekRow(element("dinnerDayNote-\(today.year!)-\(today.month!)-\(today.day!)"))
        let noteTitle = copy("Day note", "Nota del día")
        XCTAssertTrue(app.navigationBars[noteTitle].waitForExistence(timeout: 8))
        assertText(date.string(from: Date()))
        capture((spanish ? "es-US" : "en-US") + "-exact-day-note-from-grid")
        app.navigationBars[noteTitle].buttons.firstMatch.tap()
        reveal(element(lunchID))
        app.terminate(); launch(reset: false, spanish: spanish)
        tap(app.tabBars.buttons[tab]); dinnerRoot(); openMealWeek(title: weekTitle)
        reveal(element(lunchID)); reveal(element(dinnerID))
        if moveAcrossWeek {
            moveMealToLaterWeek(dinnerID: dinnerID, lunchID: lunchID, dateFormatter: date)
        }
    }

    private func moveMealToLaterWeek(dinnerID: String, lunchID: String, dateFormatter: DateFormatter) {
        let movedReview = element("dinnerMoveReview")
        let apply = element("dinnerApply")
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let month = calendar.dateInterval(of: .month, for: today)!.start
        let futureMonth = calendar.date(byAdding: .month, value: 2, to: month)!
        let moved = calendar.date(byAdding: .day, value: 14, to: futureMonth)!
        tapWeekRow(element(dinnerID))
        chooseTwoMonthsAhead(moved, pickerID: "dinnerMoveDate")
        tap(movedReview)
        assertText("Before: " + dateFormatter.string(from: today))
        assertText("After: " + dateFormatter.string(from: moved))
        assertText("Grocery quantities and separate protected reservations stay as saved.")
        tap(element("dinnerCancelPreview"))
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
        assertText(dateFormatter.string(from: today))
        tap(movedReview)
        assertText("After: " + dateFormatter.string(from: moved))
        tap(apply)
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
        assertText(dateFormatter.string(from: moved))
        app.terminate(); launch(reset: false)
        tap(app.tabBars.buttons["Dinners"]); dinnerRoot(); openMealWeek()
        reveal(element(lunchID))
        XCTAssertFalse(element(dinnerID).exists)
        capture("Meal-week-original-lunch-after-move")
        chooseTwoMonthsAhead(moved, pickerID: "dinnerWeekStart")
        reveal(element(dinnerID))
        XCTAssertFalse(element(lunchID).exists)
        capture("Meal-week-same-dinner-on-new-date")
        let selectedWeek = element("dinnerWeekStart").buttons.firstMatch.label
        XCTAssertFalse(selectedWeek.isEmpty)
        app.navigationBars["This week"].buttons.firstMatch.tap()
        openMealWeek()
        XCTAssertEqual(element("dinnerWeekStart").buttons.firstMatch.label, selectedWeek)
        reveal(element(dinnerID))
        XCTAssertFalse(element(lunchID).exists)
    }

    private func openMealWeek(title: String = "This week") {
        tapWeekRow(element("dinnerWeekEntry"))
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars[title].buttons.firstMatch.isHittable, "The pushed week must have a native Back control")
    }

    private func tapWeekRow(_ row: XCUIElement) {
        // XCUI's default activation point can lie above the scrolled content.
        // Use the visible row center, clear of navigation and tab bars.
        for _ in 0..<24 {
            let area = scrollableArea().insetBy(dx: 0, dy: 12)
            if row.exists && row.isHittable && area.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) {
                print("S25_ROW_TAP id=\(row.identifier) frame=\(row.frame) area=\(area)")
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            scrollContent(upward: row.exists ? row.frame.midY > area.midY : true)
        }
        XCTFail("No visible center for week row: \(row.debugDescription)")
    }

    private func chooseTwoMonthsAhead(_ date: Date, pickerID: String) {
        let picker = element(pickerID)
        reveal(picker)
        tap(picker.buttons.firstMatch)
        let next = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", "Next Month", "NextMonth")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), app.debugDescription)
        next.tap()
        next.tap()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.dateFormat = "EEEE, MMMM d"
        let day = app.datePickers.collectionViews.buttons[format.string(from: date)]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed, app.debugDescription)
        day.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
    }

    func testListCaptureOpensWithTypedDraftAndReopensAfterCancel() {
        launch(reset: true)
        openShoppingList()
        tap(element("ledgerStartShop"))
        fill("List capture pickup", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(element("ledgerImport"))
        fill("2 Wraps", into: "ledgerImportText")

        let review = app.navigationBars["Capture a list"]
        let editor = app.textViews["capture.editor"]
        for _ in 0..<2 {
            tap(element("ledger.capture"))
            XCTAssertTrue(review.waitForExistence(timeout: 8))
            reveal(editor)
            XCTAssertEqual(editor.value as? String, "2 Wraps")
            tap(review.buttons["Cancel"])
            XCTAssertTrue(review.waitForNonExistence(timeout: 8))
        }
        XCTAssertEqual(app.textViews["ledgerImportText"].value as? String, "2 Wraps")
    }

    func testRecipeCaptureOpensOnFirstAttemptAndReopensAfterCancel() {
        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"])
        tap(element("dinnerStartPickup"))
        fill("Recipe review pickup", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(element("dinner.scanRecipe"))

        let start = element("dinner.beginRecipeReview")
        let review = app.navigationBars["Photo and scan review"]
        for _ in 0..<2 {
            tap(start)
            XCTAssertTrue(review.waitForExistence(timeout: 8))
            let picker = app.buttons["Choose one photo for review"]
            reveal(picker)
            XCTAssertFalse(picker.isEnabled)
            enableSwitch("Allow on-device photo processing for this review")
            XCTAssertTrue(picker.isEnabled)
            tap(app.buttons["Cancel"])
            XCTAssertTrue(review.waitForNonExistence(timeout: 8))
        }
    }

    func testTypedBarcodeNeedsACodeAndFreshMatchConfirmation() {
        launch(reset: true)
        openShoppingList()
        tap(element("ledgerStartShop"))
        fill("Barcode review pickup", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(element("ledgerImport"))
        fill("2 Wraps", into: "ledgerImportText")
        tap(element("ledgerReviewImport"))
        tap(element("ledgerCommitImport"))
        openShoppingList()
        tap(app.buttons["Inspect Wraps"])
        tap(element("ledger.scanReferences"))
        tap(app.buttons["Scan a code and match it manually"])

        let matched = "I matched this source to the displayed product myself."
        let reviewed = "I reviewed the source and want to keep this reference."
        let save = app.buttons["scan.reference.review"]
        enableSwitch(matched)
        enableSwitch(reviewed)
        reveal(save)
        XCTAssertFalse(save.isEnabled)

        fill("SUPPLIER-TEST-2", into: "scan.manualCode", requireDone: true)
        reveal(save)
        XCTAssertFalse(save.isEnabled)
        enableSwitch(matched)
        enableSwitch(reviewed)
        tap(save)
        assertText("Manually matched code: SUPPLIER-TEST-2")
    }

    func testSpanishDinnerIdeaReviewsPacksAndLeavesListEmptyAfterApproval() {
        reviewAndApprovePattern(spanish: true)
    }
    private func reviewAndApprovePattern(spanish: Bool) {
        func copy(_ english: String, _ translation: String) -> String { spanish ? translation : english }
        launch(reset: true, spanish: spanish)
        tap(app.tabBars.buttons[copy("Dinners", "Cenas")])
        tap(element("dinnerStartPickup"))
        fill(copy("First dinner pickup", "Primera compra para la cena"), into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(app.buttons[copy("Review a dinner idea", "Revisar una idea para cenar")])
        choose(copy("Starting meal", "Comida que usarás como base"), value: copy("Bean and cabbage wraps", "Tortillas rellenas de frijoles y repollo"))
        tap(app.buttons[copy("Prepare editable idea", "Preparar idea editable")])
        tap(app.buttons[copy("Review prepared idea", "Revisar idea preparada")])
        tap(element("ledgerReviewDinner"))
        assertText(copy("Bean and cabbage wraps", "Tortillas rellenas de frijoles y repollo"))
        assertText(copy("Shredded cabbage", "Repollo rallado"))
        assertText(copy("Usable yield is unconfirmed", "El rendimiento aprovechable no está confirmado"))
        capture("First-pickup-editable-dinner-pattern")
        tap(app.buttons[copy("Review stock and pack for Tortillas", "Revisar existencias y paquete de Tortillas")])
        fill("8", into: "ideaSupplyYield")
        fill("2.50", into: "ideaSupplyPrice")
        fill("Bag label", into: "ideaSupplySource")
        tap(element("ideaSupplyConfirm"))
        assertText(copy("Usable in one pack: 8 units", "Cantidad aprovechable en un paquete: 8 unidades"))
        assertText(copy("Whole packs for the remainder: 1", "Paquetes enteros para lo que falta: 1"))
        assertText(copy("Estimated item cost: $2.50", "Costo estimado del artículo: $2.50"))
        capture(spanish ? "Primera-compra-paquete-revisado" : "First-pickup-reviewed-tortilla-pack")
        assertText(copy("Recipe needs: 1 cup", "La receta necesita: 1 taza"))
        tap(element("dinnerAcceptIdea"))
        assertText(copy("Dinner saved. Choose it separately to add grocery needs.", "Cena guardada. Elígela por separado para agregar sus necesidades de compra."))
        app.terminate(); launch(reset: false, spanish: spanish)
        openShoppingList()
        assertText(copy("Add the groceries you need for this pickup.", "Añade los alimentos que necesitas para esta compra."))
    }

    private func launch(reset: Bool, spanish: Bool = false) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_US" : "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons[spanish ? "Compras" : "Shop"].waitForExistence(timeout: 15))
    }
    private func restart() { app.terminate(); launch(reset: false) }
    private func avoidIOS17SnapshotLoggingCrash() {
        // High-volume accessibility snapshots can crash XCTAutomationSupport
        // during iOS 17 logging quarantine. Keep XCTest action logs available.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 {
            app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        }
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control)
        let area = scrollableArea()
        if control.frame.midY > area.maxY { scrollContent(upward: true) }
        else if control.frame.midY < area.minY { scrollContent(upward: false) }
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false, requireDone: Bool = false) {
        let field = element(id); tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo"])).firstMatch
        if requireDone { XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable, "Done must be reachable from \(id)") }
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
        // Navigation and sheet transitions can replace a bar between separate
        // XCUI queries. Measure the keyboard and bars from one captured tree.
        let snapshot = try? app.snapshot()
        let bounds = snapshot?.frame ?? app.frame
        var keyboardTop = bounds.maxY
        var barBottom = bounds.minY + 88
        var elements = snapshot.map { [$0] } ?? []
        while let element = elements.popLast() {
            let frame = element.frame
            if frame.height > 0 && frame.intersects(bounds) {
                if element.elementType == .keyboard { keyboardTop = min(keyboardTop, frame.minY) }
                if element.elementType == .navigationBar { barBottom = max(barBottom, frame.maxY) }
            }
            elements.append(contentsOf: element.children)
        }
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
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Shop", "Compras"])).firstMatch
        tap(tab)
        returnToVisibleAnchor(element("newComparison"))
    }
    private func openShoppingList() {
        // The caller requests this source through Shop. A restart may already
        // have restored a detail, so use the native Back controls to the root.
        shopRoot()
        tap(element("openPickupList"))
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
