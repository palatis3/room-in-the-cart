import UIKit
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
        if testRun?.failureCount ?? 0 > 0 {
            captureSystemScreen("Free-flow-failure")
        }
        if app.state != .notRunning { app.terminate() }
    }

#if DEBUG && NATIVE_MICROPHONE_PERMISSION_PROBE
    // Requires a fresh simulator with both app permissions undetermined.
    func testNativeMicrophoneRefusalLeavesTypedCaptureReviewable() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func permissionAlert(containing wording: String) -> XCUIElement? {
            let matches = NSPredicate(format: "label CONTAINS[c] %@", wording)
            for _ in 0..<30 {
                for owner in [app!, springboard] {
                    let alert = owner.alerts.firstMatch
                    if alert.exists && (alert.label.localizedCaseInsensitiveContains(wording)
                                        || alert.staticTexts.matching(matches).firstMatch.exists) {
                        return alert
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            evidence.name = "Missing native prompt: \(wording)"
            evidence.lifetime = .keepAlways
            add(evidence)
            return nil
        }
        func capturePermissionAlert(_ name: String) {
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            evidence.name = name
            evidence.lifetime = .keepAlways
            add(evidence)
        }

        launch(reset: true)
        openShoppingList()
        tap(element("ledgerStartShop"))
        fill("Fictional microphone pickup", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(element("ledgerImport"))
        fill("2 Wraps", into: "ledgerImportText")
        tap(element("ledger.capture"))
        let captureSheet = app.navigationBars["Capture a list"]
        XCTAssertTrue(captureSheet.waitForExistence(timeout: 8))
        let editor = app.textViews["capture.editor"]
        reveal(editor)
        XCTAssertEqual(editor.value as? String, "2 Wraps")

        tap(element("capture.startSpeech"))
        let speech = try XCTUnwrap(permissionAlert(containing: "speech recognition"), "Native Speech Recognition prompt did not appear")
        let allow = speech.buttons["Allow"]
        XCTAssertTrue(allow.exists && allow.isHittable)
        capturePermissionAlert("B09-native-speech-authorization")
        allow.tap()

        let microphone = try XCTUnwrap(permissionAlert(containing: "microphone"), "Native microphone prompt did not appear after allowing Speech Recognition")
        let refuse = microphone.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        XCTAssertTrue(refuse.exists && refuse.isHittable)
        capturePermissionAlert("B09-native-microphone-authorization")
        refuse.tap()

        let failure = app.staticTexts["capture.error"]
        reveal(failure)
        XCTAssertTrue(failure.label.contains("permission was not granted"), failure.label)
        XCTAssertFalse(element("capture.stopSpeech").exists)
        XCTAssertFalse(element("capture.useText").exists)
        reveal(editor)
        XCTAssertEqual(editor.value as? String, "2 Wraps")
        capture("B09-microphone-refusal-preserves-typed-draft")

        enableSwitch("I checked the wording, amounts, units and exclusions.")
        tap(element("capture.reviewFields"))
        assertText("Actual destination: Fictional microphone pickup")
        assertText("2 Wraps")
        let amount = app.textFields["Total amount, unknown if blank"]
        reveal(amount)
        XCTAssertEqual(amount.value as? String, "2")
        fill("3", into: "Total amount, unknown if blank", replacing: true)
        if app.keyboards.firstMatch.exists { scrollContent(upward: false) }
        enableSwitch("I reviewed this item, amounts, packs, purpose, destination and exclusions, including any unknowns.")
        tap(element("capture.continue"))
        XCTAssertTrue(captureSheet.waitForNonExistence(timeout: 10))
        tap(element("ledgerCommitImport"))
        restart()
        openShoppingList()
        reveal(app.buttons["Inspect Wraps"])
        assertText("3 items")
        capture("B09-typed-amount-reopened-after-microphone-refusal")
    }

#endif

    func testCancellingSystemShareKeepsTheFrozenPickupUnplaced() throws {
        try exerciseRetailerShareCancellation()
    }

    func testCancellingSystemShareWithReduceMotionKeepsTheFrozenPickupUnplaced() async throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let control = try Self.reduceMotionSwitch(in: settings)
        let original = try Self.switchValue(control)
        addTeardownBlock {
            try await FreeJourneyUITests.restoreReduceMotion(original)
        }
        try Self.setReduceMotion(true, using: control)
        try await Self.requireRunnerReduceMotion(true)
        captureSystemScreen("System Settings - Reduce Motion enabled")

        avoidIOS17SnapshotLoggingCrash()
        try exerciseRetailerShareCancellation()
        XCTAssertTrue(UIAccessibility.isReduceMotionEnabled, "Reduce Motion must stay enabled through relaunch")
    }

    private func exerciseRetailerShareCancellation() throws {
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
        enableSwitch("Retailer total already includes all charges", diagnosticName: "Checkout-inclusive-switch")
        fill("3.00", into: "Inclusive total", requireDone: true)
        tap(app.buttons["Save and evaluate checkout"])
        back(to: "Prepare retailer handoff")
        tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["Freeze reviewed basket"])
        let snapshot = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wraps — 2 units")).firstMatch
        reveal(snapshot)
        XCTAssertTrue(snapshot.exists && snapshot.isHittable, "Show the exact frozen snapshot before opening Share")
        let frozenText = snapshot.label
        tap(app.buttons["Share dated list"])
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "header.closeButton", "Close")).firstMatch
        let closeReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [closeReady], timeout: 15) == .completed ? close : nil,
            "The system share sheet Close control did not become ready. \(app.debugDescription)")
        func waitForShareDismissal(timeout: TimeInterval) -> Bool {
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (!close.exists || !close.isHittable)
                    && snapshot.exists && snapshot.isHittable && snapshot.label == frozenText
            }, object: nil)
            return XCTWaiter.wait(for: [dismissed], timeout: timeout) == .completed
        }
        close.tap()
        // Remote accessibility elements can remain after the sheet moves offscreen.
        // Require the exact underlying snapshot to be actionable again.
        if !waitForShareDismissal(timeout: 4) {
            _ = try XCTUnwrap(close.exists && close.isHittable ? close : nil,
                              "The share sheet did not return to the frozen snapshot. \(app.debugDescription)")
            close.tap()
            _ = try XCTUnwrap(waitForShareDismissal(timeout: 8) ? snapshot : nil,
                              "The share sheet did not return to the frozen snapshot after Close.")
        }
        let cancelled = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Share cancelled")).firstMatch
        reveal(cancelled)
        _ = try XCTUnwrap(cancelled.exists && cancelled.isHittable && (!close.exists || !close.isHittable) ? cancelled : nil,
                          "Show the saved Share cancelled history before relaunching.")
        restart()
        shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        XCTAssertTrue(app.navigationBars["Pickup"].waitForExistence(timeout: 8))
        assertText("Frozen · placement unconfirmed")
        tap(app.collectionViews.buttons["Prepare retailer handoff"])
        reveal(snapshot)
        XCTAssertEqual(snapshot.label, frozenText, "Cancellation must preserve the exact frozen snapshot")
        assertText("Share cancelled")
        capture("Retailer-share-cancelled-unplaced-after-relaunch")
    }

    private static func reduceMotionSwitch(in settings: XCUIApplication) throws -> XCUIElement {
        settings.activate()
        let control = settings.switches["Reduce Motion"]
        if !control.waitForExistence(timeout: 3) {
            let motion = settings.staticTexts["Motion"]
            if !motion.exists {
                let accessibility = settings.staticTexts["Accessibility"]
                for _ in 0..<6 {
                    if accessibility.exists && accessibility.isHittable { break }
                    settings.swipeUp()
                }
                try XCTUnwrap(accessibility.exists && accessibility.isHittable ? accessibility : nil,
                              "Find the native Accessibility settings").tap()
            }
            try XCTUnwrap(motion.waitForExistence(timeout: 8) && motion.isHittable ? motion : nil,
                          "Find the native Motion settings").tap()
        }
        return try XCTUnwrap(control.waitForExistence(timeout: 8) ? control : nil, "Find the native Reduce Motion switch")
    }

    private static func switchValue(_ control: XCUIElement) throws -> Bool {
        let value = control.value as? String ?? ""
        return try XCTUnwrap(["0": false, "1": true][value],
                             "Read the native Reduce Motion switch")
    }

    private static func setReduceMotion(_ enabled: Bool, using control: XCUIElement) throws {
        if try switchValue(control) != enabled {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let targetValue = enabled ? "1" : "0"
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", targetValue), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed, "Confirm native Reduce Motion switch state")
    }

    private static func requireRunnerReduceMotion(_ enabled: Bool) async throws {
        for _ in 0..<30 {
            if UIAccessibility.isReduceMotionEnabled == enabled { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(UIAccessibility.isReduceMotionEnabled, enabled, "Read the current OS preference from the XCTest runner")
    }

    private static func restoreReduceMotion(_ original: Bool) async throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let control = try reduceMotionSwitch(in: settings)
        try setReduceMotion(original, using: control)
        try await requireRunnerReduceMotion(original)
    }

    func testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop() throws {
        avoidIOS17SnapshotLoggingCrash()
        func verifyChosenDinnerInWeek(expectedShopTitle: String? = nil) {
            dinnerRoot()
            openMealWeek()
            if let expectedShopTitle {
                // The shop heading precedes the week and unscheduled dinners.
                // Verify the restored title before scrolling down to the meal.
                reveal(app.staticTexts.matching(NSPredicate(format: "label == %@", expectedShopTitle)).firstMatch,
                       initiallyUpward: false)
            }
            let occurrence = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                               "dinnerOccurrence-", "Wrap dinner")).firstMatch
            reveal(occurrence)
        }
        func fillAdjacentFields(_ fields: [(String, String)]) {
            // Keep the keyboard between adjacent fields in this journey only.
            // reveal still measures the unobscured content before any drag.
            for (name, value) in fields {
                let field = app.textFields[name]
                var tapped = false
                for attempt in 0..<24 {
                    var area = scrollableArea()
                    let done = app.buttons["Done"]
                    if app.keyboards.firstMatch.exists && done.exists {
                        // The Done strip is above the keyboard and can cover a
                        // field that XCTest still reports as hittable.
                        area.size.height = max(0, min(area.maxY, done.frame.minY) - area.minY)
                    }
                    XCTAssertGreaterThanOrEqual(area.height, 80, "Need visible form content before entering \(name)")
                    if field.exists && !field.frame.isEmpty {
                        let coordinate = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                        let point = coordinate.screenPoint
                        if field.isHittable && area.contains(point) {
                            print("ADJACENT_FIELD_TAP id=\(name) point=\(point) area=\(area)")
                            coordinate.tap()
                            tapped = true
                            break
                        }
                        scrollContent(upward: point.y > area.midY, area: area)
                    } else {
                        scrollContent(upward: attempt < 16, area: area)
                    }
                }
                XCTAssertTrue(tapped, "No visible field tap point for \(name)")
                field.typeText(value)
                // Hosted typing can finish before the last character reaches
                // the accessibility value. Wait for the exact input once;
                // never repair the value by typing again.
                let entered = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", value), object: field)
                XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed,
                               "Typed value must finish updating for \(name)")
                XCTAssertEqual(field.value as? String, value, name)
            }
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable,
                          "Done must remain reachable after adjacent form fields")
            done.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
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
        fillAdjacentFields([
            ("ledgerDinnerTitle", "Wrap dinner"), ("ledgerDinnerServings", "6"),
            ("Ingredient name", "Wraps"), ("Amount, optional", "6"),
            ("Ingredient exclusions, one per line", "No sesame"),
        ])
        tap(app.buttons["Add serving group"])
        fillAdjacentFields([("Group name", "Lunch"), ("Group servings", "2")])
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

        openShoppingList()
        tap(app.buttons["Inspect Wraps"])
        tap(element("ledgerPackChoice"))
        fillAdjacentFields([
            ("First pack label", "Four wraps"), ("First pack usable amount", "4"),
            ("First pack price, USD", "2"), ("Second pack label", "Three wraps"),
            ("Second pack usable amount", "3"), ("Second pack price, USD", "1.50"),
            ("Where you checked these packs and prices", "Retailer shelf checked today"),
        ])
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
        // These adjacent checkout fields share one keyboard. Type into each
        // field directly, then dismiss before moving to the charge controls.
        for (name, value) in [("Store", "Family market"), ("Branch", "Main branch"),
                              ("Pickup or delivery slot", "Tuesday 5 PM"),
                              ("Source of these prices", "Retailer preview reviewed by shopper")] {
            let field = app.textFields[name]
            tap(field)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Show the keyboard for \(name)")
            if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            field.typeText(value)
            XCTAssertEqual(field.value as? String, value, name)
        }
        tap(app.buttons["Done"])
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
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
        verifyChosenDinnerInWeek(expectedShopTitle: "Next shop")
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
        // The native print sheet can expose its dismiss action as Close or Cancel.
        let printOptions = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["Options", "Printer Options"])).firstMatch
        let dismissPrint = printOptions.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        let dismissReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: dismissPrint)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissReady], timeout: 12), .completed, app.debugDescription)
        dismissPrint.tap()
        XCTAssertTrue(printOptions.waitForNonExistence(timeout: 8), app.debugDescription)
        let largePrint = app.navigationBars["Large-print list"]
        tap(largePrint.buttons["Done"])
        XCTAssertTrue(largePrint.waitForNonExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(element("ledgerListOptions").exists)
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
        openShoppingList(); startAnotherPickupFromList()
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
        startAnotherPickupFromList()
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
        let locale = Locale(identifier: spanish ? "es_US" : "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let originalDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateStyle = .full
        let dayParts = calendar.dateComponents([.year, .month, .day], from: originalDay)
        let dayNoteID = "dinnerDayNote-\(dayParts.year!)-\(dayParts.month!)-\(dayParts.day!)"
        let weekPicker = element("dinnerWeekStart")
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
        let ingredient = copy("Corn tortillas", "Tortillas")
        let ingredientField = copy("Ingredient name", "Nombre del ingrediente")
        let amountField = copy("Amount, optional", "Cantidad, opcional")
        if moveAcrossWeek {
            // Start with a blank manual dinner. Enter each value directly,
            // then scroll to Review, as a person completing the form can.
            let fields = [("ledgerDinnerTitle", dinner), ("ledgerDinnerServings", "4"),
                          (ingredientField, ingredient), (amountField, "8")]
            for (identifier, value) in fields {
                let field = app.textFields[identifier]
                tap(field)
                field.typeText(value)
                XCTAssertEqual(field.value as? String, value, "Manual dinner field: \(identifier)")
            }
        } else {
            fill(dinner, into: "ledgerDinnerTitle")
            fill("4", into: "ledgerDinnerServings", replacing: true)
            fill(ingredient, into: ingredientField)
            fill("8", into: amountField)
            enableSwitch(assignDate)
            chooseMealWeekDate(originalDay, from: Date(), in: app.datePickers.firstMatch, formatter: dateFormatter)
        }
        tap(element("ledgerReviewDinner")); applyFrom(copy("Manual dinner", "Cena manual"))
        openMealWeek(title: weekTitle)
        chooseMealWeekDate(originalDay, from: Date(), in: weekPicker, formatter: dateFormatter)
        if moveAcrossWeek {
            assertText("Unscheduled")
            let meal = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerOccurrence-")).firstMatch
            tapWeekRow(meal)
            enableSwitch(assignDate)
            chooseMealWeekDate(originalDay, from: Date(), in: element("dinnerMoveDate"), formatter: dateFormatter)
            tap(element("dinnerMoveReview"))
            assertText("Before: Unscheduled")
            assertText("After: " + dateFormatter.string(from: originalDay))
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
        chooseMealWeekDate(originalDay, from: Date(), in: app.datePickers.firstMatch, formatter: dateFormatter)
        tap(app.buttons[copy("Review protected need", "Revisar necesidad protegida")])
        let reviewed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerPreviewNeed-")).firstMatch
        reveal(reviewed)
        XCTAssertTrue(reviewed.label.contains(copy("Purpose: ", "Finalidad: ") + purpose), reviewed.label)
        XCTAssertTrue(reviewed.label.contains(dateFormatter.string(from: originalDay)), reviewed.label)
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
        assertText(dateFormatter.string(from: originalDay))
        app.navigationBars[copy("Chosen dinner", "Cena elegida")].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[weekTitle].waitForExistence(timeout: 8))
        tapWeekRow(element(dayNoteID))
        let noteTitle = copy("Day note", "Nota del día")
        XCTAssertTrue(app.navigationBars[noteTitle].waitForExistence(timeout: 8))
        assertText(dateFormatter.string(from: originalDay))
        capture((spanish ? "es-US" : "en-US") + "-exact-day-note-from-grid")
        app.navigationBars[noteTitle].buttons.firstMatch.tap()
        let savedLunch = element(lunchID)
        let savedDinner = element(dinnerID)
        reveal(savedLunch)
        app.terminate(); launch(reset: false, spanish: spanish)
        tap(app.tabBars.buttons[tab]); dinnerRoot(); openMealWeek(title: weekTitle)
        // A fresh week starts today. Reselect the saved day before checking persistence.
        XCTAssertTrue(display.waitForExistence(timeout: 8))
        XCTAssertFalse(element(dayNoteID).exists)
        XCTAssertFalse(savedLunch.exists)
        XCTAssertFalse(savedDinner.exists)
        chooseMealWeekDate(originalDay, from: Date(), in: weekPicker, formatter: dateFormatter)
        reveal(savedLunch); reveal(savedDinner)
        XCTAssertTrue(savedDinner.label.contains(dinner), savedDinner.label)
        XCTAssertTrue(savedLunch.label.contains(food) && savedLunch.label.contains(purpose), savedLunch.label)
        XCTAssertTrue(savedLunch.label.contains(copy("2 units", "2 unidades")), savedLunch.label)
        capture((spanish ? "es-US" : "en-US") + "-meal-week-original-date-after-relaunch")
        if moveAcrossWeek {
            moveMealToLaterWeek(dinnerID: dinnerID, lunchID: lunchID, originalDay: originalDay, dateFormatter: dateFormatter)
        }
    }

    private func moveMealToLaterWeek(dinnerID: String, lunchID: String, originalDay: Date, dateFormatter: DateFormatter) {
        let movedReview = element("dinnerMoveReview")
        let apply = element("dinnerApply")
        let calendar = dateFormatter.calendar!
        let month = calendar.dateInterval(of: .month, for: originalDay)!.start
        let futureMonth = calendar.date(byAdding: .month, value: 2, to: month)!
        let moved = calendar.date(byAdding: .day, value: 14, to: futureMonth)!
        tapWeekRow(element(dinnerID))
        chooseMealWeekDate(moved, from: originalDay, in: element("dinnerMoveDate"), formatter: dateFormatter)
        tap(movedReview)
        assertText("Before: " + dateFormatter.string(from: originalDay))
        assertText("After: " + dateFormatter.string(from: moved))
        assertText("Grocery quantities and separate protected reservations stay as saved.")
        tap(element("dinnerCancelPreview"))
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
        assertText(dateFormatter.string(from: originalDay))
        tap(movedReview)
        assertText("After: " + dateFormatter.string(from: moved))
        tap(apply)
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
        assertText(dateFormatter.string(from: moved))
        app.terminate(); launch(reset: false)
        tap(app.tabBars.buttons["Dinners"]); dinnerRoot(); openMealWeek()
        let weekPicker = element("dinnerWeekStart")
        chooseMealWeekDate(originalDay, from: Date(), in: weekPicker, formatter: dateFormatter)
        reveal(element(lunchID))
        XCTAssertFalse(element(dinnerID).exists)
        capture("Meal-week-original-lunch-after-move")
        chooseMealWeekDate(moved, from: originalDay, in: weekPicker, formatter: dateFormatter)
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
        for attempt in 0..<24 {
            let area = scrollableArea().insetBy(dx: 0, dy: 12)
            let exists = row.exists
            let frame = exists ? row.frame : .zero
            if exists && row.isHittable && area.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                print("S25_ROW_TAP id=\(row.identifier) frame=\(frame) area=\(area)")
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            // A lazy row outside the viewport can be above or below the current position.
            scrollContent(upward: exists ? frame.midY > area.midY : attempt < 12)
        }
        XCTFail("No visible center for week row: \(row.debugDescription)")
    }

    private func chooseMealWeekDate(_ date: Date, from displayedDate: Date, in picker: XCUIElement,
                                    formatter: DateFormatter) {
        let calendar = formatter.calendar!
        let visibleMonth = calendar.dateInterval(of: .month, for: displayedDate)!.start
        let targetMonth = calendar.dateInterval(of: .month, for: date)!.start
        let offset = calendar.dateComponents([.month], from: visibleMonth, to: targetMonth).month!
        let monthIndex = calendar.component(.month, from: date) - 1
        let monthName = calendar.monthSymbols[monthIndex]
        var englishCalendar = calendar
        englishCalendar.locale = Locale(identifier: "en_US")
        let englishMonth = englishCalendar.monthSymbols[monthIndex]
        let dayNumber = calendar.component(.day, from: date)
        let day = app.datePickers.collectionViews.buttons.matching(NSPredicate(
            format: "(label CONTAINS[cd] %@ OR label CONTAINS[cd] %@) AND label MATCHES %@",
            monthName, englishMonth, ".*\\b\(dayNumber)\\b.*"
        )).firstMatch
        let previous = offset < 0
        let monthButton = app.buttons.matching(NSPredicate(
            format: "label IN[c] %@ OR identifier CONTAINS[c] %@",
            previous ? ["Previous Month", "Mes anterior"] : ["Next Month", "Mes siguiente", "Siguiente mes"],
            previous ? "PreviousMonth" : "NextMonth"
        )).firstMatch
        tap(picker.buttons.firstMatch)
        for _ in 0..<abs(offset) {
            if day.exists && day.isHittable && day.isEnabled { break }
            XCTAssertTrue(monthButton.waitForExistence(timeout: 5) && monthButton.isHittable)
            monthButton.tap()
        }
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed, formatter.string(from: date))
        day.tap()
        if day.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
            XCTAssertTrue(day.waitForNonExistence(timeout: 5))
        }
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
    private func tap(_ target: XCUIElement) { reveal(target); target.tap() }
    private func enableSwitch(_ label: String, diagnosticName: String? = nil) {
        let control = app.switches[label]
        reveal(control)
        let area = scrollableArea()
        if control.frame.midY > area.maxY { scrollContent(upward: true) }
        else if control.frame.midY < area.minY { scrollContent(upward: false) }
        if let diagnosticName { captureSwitchState(control, name: diagnosticName + "-before") }
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        if let diagnosticName { captureSwitchState(control, name: diagnosticName + "-after") }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func captureSwitchState(_ control: XCUIElement, name: String) {
        // Retain evidence for the hosted one-tap/animation-wait failure. These
        // reads never retry the tap, disable animations or change app state.
        let exists = control.exists
        var facts = ["Captured at: \(Date().timeIntervalSince1970)", "Exists: \(exists)"]
        if exists {
            let frame = control.frame
            let tapPoint = CGPoint(x: frame.minX + frame.width * 0.92, y: frame.midY)
            facts += ["Frame: \(frame)", "Requested tap point: \(tapPoint)", "Enabled: \(control.isEnabled)",
                      "Hittable: \(control.isHittable)", "Value: \(String(describing: control.value))"]
        }
        facts.append("Software keyboard present: \(app.keyboards.firstMatch.exists)")
        facts.append("Measured content area: \(scrollableArea())")
        let state = XCTAttachment(string: facts.joined(separator: "\n"))
        state.name = name + "-state"; state.lifetime = .keepAlways; add(state)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        captureSystemScreen(name)
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false, requireDone: Bool = false) {
        // Persistent labels can share the field's accessible name. Match only
        // editable controls, including lazily materialized Form rows.
        let editableTypes: [XCUIElement.ElementType] = [.textField, .textView, .secureTextField, .searchField]
        let field = app.descendants(matching: .any).matching(identifier: id)
            .matching(NSPredicate(format: "elementType IN %@", editableTypes.map { $0.rawValue })).firstMatch
        tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        field.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo"])).firstMatch
        if requireDone { XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable, "Done must be reachable from \(id)") }
        if done.exists && done.isHittable { done.tap() }
    }
    private func reveal(_ target: XCUIElement, initiallyUpward: Bool = true) {
        for attempt in 0..<24 {
            // Offscreen lazy rows can be absent from the accessibility tree.
            // Check once before asking for hittability, which otherwise makes
            // XCTest retry the missing element before each bounded scroll.
            let exists = target.exists
            if exists && target.isHittable { return }
            let area = scrollableArea()
            let upward: Bool
            if exists {
                let frame = target.frame
                upward = frame.isEmpty ? (attempt < 16 ? initiallyUpward : !initiallyUpward) : frame.midY > area.midY
            } else { upward = attempt < 16 ? initiallyUpward : !initiallyUpward }
            scrollContent(upward: upward, area: area)
        }
        XCTAssertTrue(target.isHittable, "Missing actionable UI element: \(target.debugDescription)")
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
    private func scrollContent(upward: Bool, area measuredArea: CGRect? = nil) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = measuredArea ?? scrollableArea(), bounds = app.frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertText(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        // The matching query checks the text; reveal requires it to be hittable.
        reveal(target)
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
    private func startAnotherPickupFromList() {
        let picker = app.buttons["ledgerShopPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8) && picker.isEnabled)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 && !picker.isHittable {
            // iOS 17 can report no hit point for this visible SwiftUI menu.
            let frame = picker.frame
            let navigation = app.navigationBars.firstMatch.frame
            let tabBar = app.tabBars.firstMatch.frame
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(app.frame.contains(frame) && frame.minY >= navigation.maxY && frame.maxY <= tabBar.minY)
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            tap(picker)
        }
        tap(app.buttons["Start another pickup"])
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
    private func captureSystemScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
