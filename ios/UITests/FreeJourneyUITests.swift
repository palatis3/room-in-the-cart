import UIKit
import XCTest

/// Shopper journeys use the isolated Debug workspace. Pickup recovery cases seed a placed order.
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

#if DEBUG && targetEnvironment(simulator)
    func testReceiptUsableCorrectionShowsProtectedMealEffectsBeforeSaving() {
        launch(reset: true, privateRecovery: true)
        func arrivals() {
            shopRoot()
            tap(app.buttons["Pickup, repairs and handoffs"])
            tap(app.buttons["Record what came home"])
            XCTAssertTrue(app.navigationBars["What came home"].waitForExistence(timeout: 8))
        }
        arrivals()
        tap(app.buttons["Correct usable amount"])
        XCTAssertTrue(app.navigationBars["Usable food"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Usable: 6 units"].waitForExistence(timeout: 5))
        fill("7", into: "Correct confirmed usable amount")
        enableSwitch("I checked the identity, units and meal constraints")
        tap(app.buttons["Preview corrected usable amount"])
        func checkMeal(_ name: String, before: String, after: String) {
            let row = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "receiptCorrection.meal.", name)).firstMatch
            reveal(row)
            XCTAssertTrue(row.label.contains(before), row.label)
            XCTAssertTrue(row.label.contains(after), row.label)
        }
        checkMeal("Lunch", before: "Before this change: Allocated: 2 units", after: "After this change: Allocated: 2 units")
        checkMeal("Tuesday tacos", before: "Before this change: Allocated: 4 units", after: "After this change: Allocated: 5 units")
        checkMeal("Wednesday quesadillas", before: "Before this change: Allocated: 0 units", after: "After this change: Allocated: 0 units")
        capture("S08-corrected-receipt-dependent-meals")
        tap(app.buttons["Save correction and recheck meals"])
        XCTAssertTrue(app.navigationBars["What came home"].waitForExistence(timeout: 8))
        restart()
        arrivals()
        assertText("Usable: 7 units")
        XCTAssertEqual(app.buttons.matching(identifier: "Correct usable amount").count, 1)
    }

    private func createReplacementFromPrivatePickup() {
        launch(reset: true, privateRecovery: true)
        shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Repair a meal"])
        tap(element("pickup.mealRecovery"))
        let replace = app.buttons["Replace Wednesday quesadillas"]
        reveal(replace)
        let mealID = String(replace.identifier.dropFirst("mealRecovery.target.".count))
        tap(replace)
        fill("Wednesday bean bowls", into: "mealRecovery.title", useVisibleCenter: true)
        fill("Heat the beans for dinner", into: "mealRecovery.notes", useVisibleCenter: true)
        let name = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "mealRecovery.", ".name")).firstMatch
        reveal(name)
        let ingredientID = String(name.identifier.dropLast(".name".count))
        fill("Beans", into: ingredientID + ".name", useVisibleCenter: true)
        choose("Reviewed matching food", value: "Beans")
        fill("4", into: ingredientID + ".amount", useVisibleCenter: true)
        enableSwitch("I reviewed every food identity, usable unit and inherited exclusion")
        let preview = element("mealRecovery.preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 5) && preview.isHittable && preview.isEnabled)
        XCTAssertLessThanOrEqual(preview.frame.maxY, app.tabBars.buttons["Shop"].frame.minY,
            "The recovery action must stay above the floating tab bar.")
        preview.tap()
        let changed = element("mealRecovery.previewMeal." + mealID)
        reveal(changed, initiallyUpward: false)
        XCTAssertTrue(changed.label.contains("Wednesday bean bowls") && changed.label.contains("Still short: 0"), changed.label)
        let tuesday = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "mealRecovery.previewMeal.", "Tuesday tacos")).firstMatch
        reveal(tuesday, initiallyUpward: false)
        XCTAssertTrue(tuesday.label.contains("Still short: 2"), tuesday.label)
        let protected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Protected · unchanged")).firstMatch
        reveal(protected)
        capture("Manual-recovery-preview")
        enableSwitch("I reviewed the replacement and every other meal’s remaining shortage")
        XCTAssertFalse(element("mealRecovery.apply").isEnabled)
        enableSwitch("I accept that unresolved food or timing remains open")
        tap(element("mealRecovery.apply"))
        XCTAssertTrue(element("mealRecovery.saved").waitForExistence(timeout: 8))
        capture("Manual-recovery-saved")
    }

    func testCarryRecoveredDinnerFoodToAnotherNightAndReopenTheDatedTarget() {
        createReplacementFromPrivatePickup()
        tap(app.tabBars.buttons["Dinners"])
        dinnerRoot()
        tap(app.buttons["All chosen dinners, including earlier dates"])
        let dinner = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerOccurrence-' AND label CONTAINS %@", "Wednesday bean bowls")).firstMatch
        reveal(dinner)
        let originalID = dinner.identifier
        tap(dinner)
        tap(element("awayCarryover.open"))
        tap(element("awayCarryover.need"))
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wednesday bean bowls ·")).firstMatch)
        tap(element("awayCarryover.supply"))
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Beans")).firstMatch)
        fill("4", into: "awayCarryover.counted", useVisibleCenter: true)
        fill("2", into: "awayCarryover.reserved", useVisibleCenter: true)
        fill("2", into: "awayCarryover.servings", useVisibleCenter: true)
        if app.keyboards.firstMatch.exists { app.typeText(XCUIKeyboardKey.return.rawValue) }
        enableSwitch("awayCarryover.checked")
        tap(element("awayCarryover.review"))
        let source = app.staticTexts["Physical source: Beans"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        // Wait for the new review to settle, then scroll to its approval control.
        // A disabled button can briefly leave the lazy Form’s accessibility tree.
        let approval = app.switches["awayCarryover.approve"]
        reveal(approval)
        let apply = app.buttons["awayCarryover.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        enableSwitch("awayCarryover.approve")
        tap(apply)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "awayCarryover.saved.")).firstMatch
        reveal(saved)
        tap(saved)
        let target = app.navigationBars["Dated physical carryover"]
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        restart()
        tap(app.tabBars.buttons["Dinners"])
        dinnerRoot()
        tap(app.buttons["All chosen dinners, including earlier dates"])
        let matches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerOccurrence-' AND label CONTAINS %@", "Wednesday bean bowls"))
        XCTAssertEqual(matches.count, 2)
        tap(matches.matching(NSPredicate(format: "identifier != %@", originalID)).firstMatch)
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        let reserved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reserved quantity: 2")).firstMatch
        reveal(reserved)
        XCTAssertTrue(reserved.exists)
    }

    func testCreateReplacementFromPrivatePickupAndReopenForCook() throws {
        createReplacementFromPrivatePickup()
        restart()
        shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Tell the cook"])
        tap(app.buttons["Prepare complete dated instruction"])
        let instruction = app.textViews["Editable cook instruction"]
        reveal(instruction)
        let copy = try XCTUnwrap(instruction.value as? String)
        for expected in ["Wednesday bean bowls", "Heat the beans for dinner", "Tuesday tacos", "Lunch", "garlic"] {
            XCTAssertTrue(copy.localizedCaseInsensitiveContains(expected), expected)
        }
        XCTAssertFalse(copy.contains("Wednesday quesadillas"))
        tap(app.buttons["Save dated copy"])
        let share = app.buttons["Share saved dated copy"]
        reveal(share)
        XCTAssertTrue(share.isEnabled)
        restart()
        shopRoot()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Tell the cook"])
        tap(app.buttons["Review this saved copy"])
        let reopenedInstruction = app.textViews["Editable cook instruction"]
        reveal(reopenedInstruction, initiallyUpward: false)
        let saved = try XCTUnwrap(reopenedInstruction.value as? String)
        XCTAssertEqual(saved, copy)
    }

#endif

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
        app.renameSelectedPickup("Fictional microphone pickup")
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
        addTeardownBlock { [weak self] in
            // Restoring the system setting opens Settings before tearDownWithError.
            // Preserve the failed app screen while it is still on display.
            if let self {
                await MainActor.run {
                    if (self.testRun?.failureCount ?? 0) > 0 {
                        self.captureSystemScreen("Reduce-Motion-failure-before-settings-restoration")
                    }
                }
            }
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
        guard let close = readySystemShareClose(in: app) else { return }
        captureSystemScreen("Retailer-share-sheet-ready-to-cancel")
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
                let field = editableElement(name)
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
        // The saved pack price belongs to the earlier retailer terms. Enter
        // the new terms before reviewing and replacing their pricing evidence.
        for (name, value) in [("Store", "Family market"), ("Branch", "Main branch"),
                              ("Pickup or delivery slot", "Tuesday 5 PM")] {
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
        assertText("Pricing details to preserve")
        assertText("Wraps")
        assertText("$3.00")
        assertText("These prices belong to different checkout terms. Review them and enter fresh evidence.")
        let saveCheckout = app.buttons["Save and evaluate checkout"]
        reveal(saveCheckout)
        XCTAssertFalse(saveCheckout.isEnabled, "Changed retailer terms require reviewed replacement pricing")
        tap(app.buttons["Replace pricing after review"])
        tap(app.buttons["Start replacement pricing"])
        let source = app.textFields["Source of these prices"]
        reveal(source, initiallyUpward: false)
        XCTAssertEqual(source.value as? String, source.placeholderValue, "Replacement pricing starts with a blank source")
        source.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Show the keyboard for Source of these prices")
        source.typeText("Retailer preview reviewed by shopper")
        XCTAssertEqual(source.value as? String, "Retailer preview reviewed by shopper", "Source of these prices")
        tap(app.buttons["Done"])
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        enableSwitch("Retailer total already includes all charges")
        fill("3.00", into: "Inclusive total")
        tap(app.buttons["Save and evaluate checkout"])
        let checkoutReview = app.navigationBars["Review checkout changes"]
        XCTAssertTrue(checkoutReview.waitForExistence(timeout: 5))
        assertText("Proposed checkout quote")
        assertText("Family market · Main branch")
        assertText("Pickup · Tuesday 5 PM")
        assertText("Retailer preview reviewed by shopper")
        assertText("$3.00")
        let saveReviewed = app.buttons["Save reviewed checkout"]
        reveal(saveReviewed)
        XCTAssertTrue(saveReviewed.isEnabled, "The reviewed replacement must be eligible to save")
        saveReviewed.tap()
        XCTAssertTrue(checkoutReview.waitForNonExistence(timeout: 8))
        assertText("Saved checkout result")
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
        let placeOrder = app.buttons["I placed this order"]
        reveal(placeOrder)
        // A sliver above the floating tab bar can report hittable. Bring the
        // complete control into the content area before the single native tap.
        for _ in 0..<12 {
            let area = scrollableArea(), frame = placeOrder.frame
            if placeOrder.isHittable && frame.minY >= area.minY && frame.maxY <= area.maxY { break }
            scrollContent(upward: frame.midY > area.midY, area: area)
        }
        let placementArea = scrollableArea(), placementFrame = placeOrder.frame
        XCTAssertTrue(placeOrder.isHittable && placeOrder.isEnabled)
        XCTAssertGreaterThanOrEqual(placementFrame.minY, placementArea.minY)
        XCTAssertLessThanOrEqual(placementFrame.maxY, placementArea.maxY)
        XCTAssertGreaterThanOrEqual(placementFrame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(placementFrame.maxX, app.frame.maxX)
        capture("Free-order-report-control-fully-visible")
        placeOrder.tap()
        // Return only from this destination. Never keep popping because an
        // asynchronously created arrival action is not in the hierarchy yet.
        let handoff = app.navigationBars["Retailer handoff"]
        if handoff.exists { handoff.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(app.navigationBars["Pickup"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Placement reported · original order locked"].waitForExistence(timeout: 10))
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

    /// S14.01: the source URL is evidence, not a prerequisite for local planning.
    /// Uses ordinary UI and an empty isolated workspace; no seeded dinner fixture.
    func testUnavailableRecipeSourceLeavesServingsAndPortionAllocationEditableAfterRestart() {
        let title = "Unavailable-source lentil wraps"
        let source = "https://vanished-recipe.invalid/lentil-wraps"
        let notes = "Warm the wraps and serve the lentils separately."
        func field(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: name)
                .matching(NSPredicate(format: "elementType IN %@",
                    [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue])).firstMatch
        }
        func assertField(_ name: String, _ expected: String) {
            let target = field(name)
            reveal(target)
            do {
                // All input has finished or the saved editor is open. Read the actual
                // field once so a slow accessibility query cannot outlive a predicate timer.
                let snapshot = try target.snapshot()
                let value = snapshot.value as? String
                if value != expected {
                    let facts = [
                        "Field: \(name); expected: \(expected)",
                        "Value: \(String(reflecting: snapshot.value)); placeholder: \(String(reflecting: snapshot.placeholderValue))",
                        "Label: \(snapshot.label); identifier: \(snapshot.identifier)",
                        "Enabled: \(snapshot.isEnabled); frame: \(snapshot.frame)"
                    ]
                    let attachment = XCTAttachment(string: facts.joined(separator: "\n"))
                    attachment.name = "S14-failed-field-value-boundary"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(value, expected, "Persisted or entered value for \(name)")
            } catch {
                XCTFail("Could not read \(name): \(error)")
            }
        }
        func enter(_ value: String, _ name: String, replacing: Bool = false) {
            fill(value, into: name, replacing: replacing)
            assertField(name, value)
        }
        func openChosen(expectedID: String? = nil) -> String {
            dinnerRoot()
            tap(app.buttons["All chosen dinners, including earlier dates"])
            XCTAssertTrue(app.navigationBars["All chosen dinners"].waitForExistence(timeout: 8))
            let matches = app.buttons.matching(NSPredicate(format:
                "identifier BEGINSWITH 'dinnerOccurrence-' AND label CONTAINS %@", title))
            let occurrence = matches.firstMatch
            reveal(occurrence)
            XCTAssertEqual(matches.count, 1, "Editing must not duplicate the chosen dinner")
            let identifier = occurrence.identifier
            if let expectedID { XCTAssertEqual(identifier, expectedID) }
            tap(occurrence)
            XCTAssertTrue(app.navigationBars["Chosen dinner"].waitForExistence(timeout: 8))
            return identifier
        }
        func openBindings() {
            tap(element("dinnerGuests"))
            XCTAssertTrue(app.navigationBars["Guests and protected portions"].waitForExistence(timeout: 8))
        }
        func saveBindings() {
            let save = app.buttons["Save reviewed ingredient bindings"]
            tap(save)
            let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
            XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 8), .completed)
            XCTAssertFalse(element("dinnerError").exists)
            tap(element("dinnerDecisionCancel"))
            XCTAssertTrue(element("dinnerDecisionCancel").waitForNonExistence(timeout: 8))
        }

        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"])
        tap(element("dinnerStartPickup"))
        enter("Unavailable-source pickup", "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(element("dinnerLibrary"))
        tap(element("ledgerNewTemplate"))
        enter(title, "ledgerDinnerTitle")
        enter("3", "ledgerDinnerServings")
        enter(notes, "Notes")
        enter(source, "Source URL, optional")
        enter("Wraps", "Ingredient name")
        enter("6", "Amount, optional")
        tap(app.buttons["Add serving group"])
        enter("Dinner", "Group name")
        enter("3", "Group servings")
        capture("S14-unavailable-source-remains-editable")
        tap(element("ledgerReviewDinner"))
        tap(element("ledgerSaveDinner"))
        tap(app.buttons["Done"])
        tap(element("ledgerChooseTemplate"))
        XCTAssertTrue(app.navigationBars["Dinner preview"].waitForExistence(timeout: 8))
        let previewMeals = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerPreviewMeal-"))
        let previewNeeds = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerPreviewNeed-"))
        XCTAssertEqual(previewMeals.firstMatch.label, "\(title), Servings: 3, Unscheduled")
        XCTAssertEqual(previewNeeds.firstMatch.label, "Wraps, New need, After: 6 units")
        let apply = app.buttons["dinnerApply"]
        XCTAssertTrue(apply.isEnabled)
        tap(apply)
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
        let occurrenceID = openChosen()
        assertText("Servings: 3")
        openBindings()
        enter("6", "Current amount for this group")
        saveBindings()
        openBindings()
        assertField("Current amount for this group", "6")
        tap(element("dinnerDecisionCancel"))
        XCTAssertTrue(element("dinnerDecisionCancel").waitForNonExistence(timeout: 8))

        tap(app.buttons["Edit quantities manually"])
        XCTAssertTrue(app.navigationBars["Manual quantities"].waitForExistence(timeout: 8))
        enter("4", "Total servings", replacing: true)
        enter("4", "Group servings", replacing: true)
        enter("8", "Amount, optional", replacing: true)
        tap(app.buttons["Review"])
        tap(element("dinnerApply"))
        XCTAssertTrue(element("dinnerApply").waitForNonExistence(timeout: 10))
        XCTAssertFalse(element("dinnerError").exists)
        app.navigationBars["Manual quantities"].buttons.firstMatch.tap()
        assertText("Servings: 4")
        openBindings()
        // Manual amount changes intentionally discard stale bindings. Review the
        // new allocation explicitly; never assume the previous amount was scaled.
        enter("8", "Current amount for this group", replacing: true)
        saveBindings()
        openBindings()
        assertField("Current amount for this group", "8")
        capture("S14-edited-serving-allocation-before-restart")
        tap(element("dinnerDecisionCancel"))
        XCTAssertTrue(element("dinnerDecisionCancel").waitForNonExistence(timeout: 8))

        restart()
        tap(app.tabBars.buttons["Dinners"])
        _ = openChosen(expectedID: occurrenceID)
        assertText("Servings: 4")
        assertText(notes)
        openBindings()
        assertField("Current amount for this group", "8")
        capture("S14-allocation-persisted-after-restart")
        tap(element("dinnerDecisionCancel"))
        XCTAssertTrue(element("dinnerDecisionCancel").waitForNonExistence(timeout: 8))
        tap(app.buttons["Edit quantities manually"])
        assertField("Total servings", "4")
        assertField("Group name", "Dinner")
        assertField("Group servings", "4")
        assertField("Amount, optional", "8")
        capture("S14-weekly-amounts-persisted-after-restart")

        // Inspect the original reusable dinner without saving a new version.
        // Weekly edits must not rewrite its original servings, recipe or source.
        dinnerRoot()
        tap(element("dinnerLibrary"))
        tap(app.buttons["Review as a new dinner version"])
        assertField("ledgerDinnerTitle", title)
        assertField("ledgerDinnerServings", "3")
        assertField("Notes", notes)
        assertField("Source URL, optional", source)
        assertField("Ingredient name", "Wraps")
        assertField("Amount, optional", "6")
        assertField("Group name", "Dinner")
        assertField("Group servings", "3")
        capture("S14-original-recipe-and-source-preserved")
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
        choose("Affected meal need", value: "Wednesday rice")
        fill("Use the remaining peppers in rice.", into: "Exact food, portions, exclusions and instructions")
        let trip = "I agree to an extra top-up trip for this repair"
        let repeated = "I agree to repeat a meal for this repair"
        enableSwitch(trip)
        enableSwitch(repeated)
        fill("20", into: "Remaining elapsed preparation minutes (optional)")
        for label in [trip, repeated] {
            let control = app.switches[label]
            reveal(control)
            XCTAssertEqual(control.value as? String, "0")
        }
        enableSwitch(repeated)
        tap(app.buttons["Save reviewed repair instructions"])
        assertText("Use the remaining peppers in rice.")
        let nextRepeat = app.switches[repeated]
        reveal(nextRepeat, initiallyUpward: false)
        XCTAssertEqual(nextRepeat.value as? String, "0")
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
        func enterNeed(food: String, meal: String, required: String, available: String) {
            // Enter a need in one editing session, then dismiss the keyboard for review.
            for (label, value) in [("Food that is short", food), ("Meal or purpose", meal),
                                   ("Required amount", required), ("Usable amount available now", available)] {
                let field = app.textFields[label]
                tap(field)
                field.typeText(value)
                XCTAssertEqual(field.value as? String, value, "Review the entered value for \(label)")
            }
            let done = app.buttons.matching(NSPredicate(format: "identifier == %@", "Done")).firstMatch
            tap(done)
            XCTAssertTrue(done.waitForNonExistence(timeout: 5), "End amount entry before confirming the need")
        }

        launch(reset: true)
        tap(element("urgentRepairShortcut"))
        enterNeed(food: "Tortillas", meal: "Wednesday supper", required: "6", available: "2")
        enableSwitch("I checked this food’s identity and usable amount")
        fill("3", into: "Usable amount available now", replacing: true)
        XCTAssertFalse(app.buttons["Save need and repair meal"].isEnabled)
        enableSwitch("I checked this food’s identity and usable amount")
        tap(app.buttons["Save need and repair meal"])
        assertText("Open meal need")
        assertText("Wednesday supper")
        capture("Free-urgent-need-before-shopping")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        enterNeed(food: "Beans", meal: "Thursday lunch", required: "4", available: "1")
        let save = app.buttons["Save need and repair meal"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "The second need requires its own confirmation")
        enableSwitch("I checked this food’s identity and usable amount")
        tap(save)
        assertText("Thursday lunch")
        restart()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Repair a meal"])
        assertText("Open meal need")
        assertText("Wednesday supper")
        assertText("Tortillas")
        assertText("Required: 6")
        assertText("Confirmed available: 3")
        capture("Free-urgent-Wednesday-after-restart")
        assertText("Thursday lunch")
        assertText("Beans")
        assertText("Required: 4")
        assertText("Confirmed available: 1")
        capture("Free-urgent-Thursday-after-restart")
    }

    func testStagedListCanReturnToOriginalAndMergeADuplicateAfterRestart() throws {
        launch(reset: true)
        let pickup = element("openPickupList")
        XCTAssertTrue(pickup.waitForExistence(timeout: 10))
        XCTAssertTrue(pickup.label.contains("Start pickup"), pickup.label)
        tap(pickup)
        XCTAssertTrue(app.textFields["ledgerSearch"].waitForExistence(timeout: 10))
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
        shopRoot()
        XCTAssertTrue(pickup.label.contains("Shopping list"), pickup.label)
        tap(pickup)
        reveal(element(id))
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

    func testDuplicateImportChoicesFollowReviewedAmountsAndCheckedLines() {
        let commit = element("ledgerCommitImport")
        let separate = app.buttons["Add as a separate line"]
        let mergeSaved = app.buttons["Merge same need: Item 1: wraps"]
        let addSaved = app.buttons["Add amount to: Item 1: wraps"]
        let mergePreview = app.buttons["Merge same need: Preview line 1: wraps"]
        let addPreview = app.buttons["Add amount to: Preview line 1: wraps"]
        func stage(_ text: String) {
            tap(element("ledgerImport"))
            fill(text, into: "ledgerImportText")
            tap(element("ledgerReviewImport"))
            XCTAssertTrue(commit.waitForExistence(timeout: 8))
        }
        func revealPreviewControl(_ control: XCUIElement, upward: Bool) {
            let form = app.collectionViews["ledgerImportForm"]
            let top = app.navigationBars["Bring the list"].frame.maxY
            for _ in 0..<8 {
                let bottom = commit.frame.minY
                if control.exists && control.isHittable && control.frame.midY > top + 8 && control.frame.midY < bottom - 8 { return }
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let x = form.frame.maxX - 12
                let high = origin.withOffset(CGVector(dx: x, dy: top + (bottom - top) * 0.25))
                let low = origin.withOffset(CGVector(dx: x, dy: top + (bottom - top) * 0.75))
                (upward ? low : high).press(forDuration: 0.05, thenDragTo: upward ? high : low)
            }
            XCTFail("Review control did not reach the visible area above Add reviewed list: " + control.debugDescription)
        }
        func openChoices(_ number: Int) {
            let picker = app.buttons["ledgerImportResolution-\(number)"]
            revealPreviewControl(picker, upward: true)
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(separate.waitForExistence(timeout: 5), app.debugDescription)
        }
        launch(reset: true)
        openShoppingList()
        stage("2 wraps")
        tap(commit)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-")).firstMatch
        reveal(first)
        let checkFirst = first.identifier.replacingOccurrences(of: "ledgerInspect-", with: "ledgerCheck-")

        stage("3 wraps\n3 wraps")
        openChoices(1)
        XCTAssertTrue(addSaved.exists)
        XCTAssertFalse(mergeSaved.exists)
        separate.tap()
        openChoices(2)
        XCTAssertTrue(addSaved.exists && addPreview.exists)
        XCTAssertFalse(mergeSaved.exists)
        tap(mergePreview)
        XCTAssertTrue(commit.isEnabled)
        let earlierAmount = element("ledgerImportAmount-1")
        revealPreviewControl(earlierAmount, upward: false)
        fill("4", into: "ledgerImportAmount-1", replacing: true)
        XCTAssertFalse(commit.isEnabled, "Changing the earlier supply must invalidate the later same-need choice")
        openChoices(2)
        XCTAssertFalse(mergePreview.exists || mergeSaved.exists)
        tap(addPreview)
        XCTAssertTrue(commit.isEnabled, "The earlier explicit separate choice must survive its amount edit")
        tap(commit)
        reveal(element(checkFirst))
        tap(element(checkFirst))

        stage("2 wraps")
        openChoices(1)
        XCTAssertTrue(mergeSaved.exists, "An exact original need can be identified after check-off")
        XCTAssertFalse(addSaved.exists, "A checked line cannot receive a new purchase need")
        XCTAssertTrue(app.buttons["Add amount to: Item 2: wraps"].exists)
        XCTAssertFalse(app.buttons["Merge same need: Item 2: wraps"].exists)
        tap(mergeSaved)
        tap(commit)
        restart()
        openShoppingList()
        let active = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-"))
        XCTAssertEqual(active.count, 1, "Reviewing the duplicate must leave the original purchase checked")
        tap(active.firstMatch)
        let total = element("ledgerIngredientTotal")
        XCTAssertTrue(total.waitForExistence(timeout: 8))
        XCTAssertEqual(total.label, "7 items")
    }

    func testCancelledImportAndIngredientReturnPreserveLongFilteredListContext() {
        launch(reset: true)
        openShoppingList()
        tap(element("ledgerImport"))
        let lines = Array("abcdefghijklmnopqrstuvwx").enumerated().flatMap { index, letter in
            var rows = ["2 Wrap \(letter)"]
            if index.isMultiple(of: 4) { rows.append("1 Soap \(letter)") }
            return rows
        }.joined(separator: "\n")
        fill(lines, into: "ledgerImportText", requireDone: true)
        tap(element("ledgerReviewImport"))
        let commit = element("ledgerCommitImport")
        for _ in 0..<40 {
            if commit.exists && commit.isHittable { break }
            app.collectionViews.firstMatch.swipeUp(velocity: 6_000)
        }
        tap(commit)
        XCTAssertTrue(commit.waitForNonExistence(timeout: 10))

        let search = app.textFields["ledgerSearch"]
        tap(search); search.typeText("Wrap\n")
        XCTAssertEqual(search.value as? String, "Wrap")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let row = app.buttons["Inspect Wrap n"]
        XCTAssertFalse(row.exists && row.isHittable, "The anchor must start beyond the filtered viewport")
        reveal(row)
        let rowID = row.identifier
        let originalY = row.frame.minY
        XCTAssertTrue(rowID.hasPrefix("ledgerInspect-"))
        capture("long-filtered-list-before-leaving")

        // Cancelling an ordinary import preview must not insert its new line
        // or reset the list behind the sheet. System share has separate proof.
        tap(element("ledgerImport"))
        fill("1 Wrap cancelled", into: "ledgerImportText", requireDone: true)
        tap(element("ledgerReviewImport"))
        tap(app.navigationBars["Bring the list"].buttons["Cancel"])
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        XCTAssertEqual(search.value as? String, "Wrap")
        XCTAssertTrue(element(rowID).isHittable)
        XCTAssertEqual(element(rowID).frame.minY, originalY, accuracy: 4)
        XCTAssertFalse(app.buttons["Inspect Wrap cancelled"].exists)

        tap(element(rowID))
        XCTAssertTrue(app.navigationBars["Inspect ingredient"].waitForExistence(timeout: 8))
        XCTAssertEqual(element("ledgerIngredientTotal").label, "2 items")
        tap(app.navigationBars["Inspect ingredient"].buttons.element(boundBy: 0))
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        XCTAssertEqual(search.value as? String, "Wrap")
        XCTAssertTrue(element(rowID).isHittable)
        XCTAssertEqual(element(rowID).frame.minY, originalY, accuracy: 4)
        capture("long-filtered-list-after-import-cancel-and-detail-return")

        // Search the complete list for the cancelled row; absence from a lazy
        // offscreen accessibility tree alone would not prove cancellation.
        tap(search); search.press(forDuration: 1.2)
        let menuItem = app.menuItems["Select All"]
        let selectAll = menuItem.exists ? menuItem : app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap(); search.typeText("cancelled\n")
        XCTAssertEqual(search.value as? String, "cancelled")
        XCTAssertTrue(app.staticTexts["No active items match your search."].waitForExistence(timeout: 8))
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
        openShoppingList()
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

    func testFirstPickupCanStartFromDinnersAndReviewAnEditablePattern() throws {
        try reviewAndApprovePattern(spanish: false)
    }

    func testMealWeekReservationDraftCannotFollowAnotherPickup() {
        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"]); tap(element("dinnerStartPickup"))
        fill("Original reservation pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        openMealWeek(); tapVisibleFormRow(app.buttons["Protect a lunch or side"])
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
        dinnerRoot(); openMealWeek(); tapVisibleFormRow(app.buttons["Protect a lunch or side"])
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
                let field = editableElement(identifier)
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
            tapVisibleFormRow(meal)
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

        tapVisibleFormRow(app.buttons[copy("Protect a lunch or side", "Proteger un almuerzo o acompañamiento")])
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
        tapVisibleFormRow(element(dinnerID))
        XCTAssertTrue(app.navigationBars[copy("Chosen dinner", "Cena elegida")].waitForExistence(timeout: 8), app.debugDescription)
        assertText(dateFormatter.string(from: originalDay))
        app.navigationBars[copy("Chosen dinner", "Cena elegida")].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[weekTitle].waitForExistence(timeout: 8))
        tapVisibleFormRow(element(dayNoteID))
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
        tapVisibleFormRow(element(dinnerID))
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
        tapVisibleFormRow(element("dinnerWeekEntry"))
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars[title].buttons.firstMatch.isHittable, "The pushed week must have a native Back control")
    }

    private func tapVisibleFormRow(_ row: XCUIElement, marker: String = "S25_ROW_TAP") {
        // XCUI's default activation point can lie above the scrolled content.
        // Use the visible row center, clear of navigation and tab bars.
        for attempt in 0...24 {
            let area = scrollableArea().insetBy(dx: 0, dy: 12)
            let exists = row.exists
            let frame = exists ? row.frame : .zero
            if exists && row.isHittable && area.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                print("\(marker) id=\(row.identifier) frame=\(frame) area=\(area)")
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            // Observe the result of the final allowed drag before failing.
            // There are still at most 24 gestures, not 25.
            if attempt == 24 { break }
            // A lazy row outside the viewport can be above or below the current position.
            scrollContent(upward: exists ? frame.midY > area.midY : attempt < 12)
        }
        XCTFail("No visible center for form row: \(row.debugDescription)")
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

    func testSpanishDinnerIdeaReviewsPacksAndLeavesListEmptyAfterApproval() throws {
        try reviewAndApprovePattern(spanish: true)
    }
    private func reviewAndApprovePattern(spanish: Bool) throws {
        func copy(_ english: String, _ translation: String) -> String { spanish ? translation : english }
        func assertReviewedText(_ text: String, initiallyUpward: Bool = true) {
            let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            revealScrollableContent(target, initiallyUpward: initiallyUpward)
        }
        func tapDinnerControl(_ target: XCUIElement, initiallyUpward: Bool = true) {
            revealScrollableContent(target, initiallyUpward: initiallyUpward)
            target.tap()
        }
        launch(reset: true, spanish: spanish)
        tap(app.tabBars.buttons[copy("Dinners", "Cenas")])
        tap(element("dinnerStartPickup"))
        fill(copy("First dinner pickup", "Primera compra para la cena"), into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        tap(app.buttons[copy("Review a dinner idea", "Revisar una idea para cenar")])
        choose(copy("Starting meal", "Comida que usarás como base"), value: copy("Bean and cabbage wraps", "Tortillas rellenas de frijoles y repollo"))
        tap(app.buttons[copy("Prepare editable idea", "Preparar idea editable")])
        tap(app.buttons[copy("Review prepared idea", "Revisar idea preparada")])
        let amountLabel = copy("Amount, optional", "Cantidad, opcional")
        let amount = editableElement(amountLabel)
        reveal(amount)
        // Lazy ingredient rows share a localized Amount label. Retain the same
        // ingredient identity across scrolling and the review/edit transition.
        let amountID = amount.identifier
        XCTAssertTrue(amountID.hasPrefix("ingredient.") && amountID.hasSuffix(".amount"))
        let originalAmount = amount.value as? String ?? ""
        XCTAssertFalse(originalAmount.isEmpty || originalAmount == amount.placeholderValue)
        // An unknown ingredient quantity is reviewable, but the domain forbids acceptance.
        fill(" ", into: amountID, replacing: true, requireDone: true, useVisibleCenter: true, expectedPriorValue: originalAmount,
             focusedDoneEvidence: (copy("Dinner idea", "Idea para cenar"), copy("Done", "Listo"), "Dinner-idea-Done-cleared-amount", copy("Dinner ideas", "Ideas para cenar"), .center))
        tapDinnerControl(element("ledgerReviewDinner"))
        let unknownQuantity = copy("Review unknown ingredient quantities", "Revisa las cantidades de ingredientes desconocidas")
        assertReviewedText(unknownQuantity, initiallyUpward: false)
        let accept = element("dinnerAcceptIdea")
        revealDinnerAcceptanceRow(accept)
        XCTAssertEqual(accept.elementType, .button)
        XCTAssertFalse(accept.isEnabled)
        let disabledState = XCTAttachment(string: accept.debugDescription)
        disabledState.name = "Dinner-unknown-quantity-disabled-accept"; disabledState.lifetime = .keepAlways; add(disabledState)
        capture("Dinner-unknown-quantity-disabled-accept")
        try assertReadableDinnerAcceptance(accept, name: "Dinner-disabled-accept")
        tapVisibleFormRow(accept, marker: "DISABLED_DINNER_ACCEPT_TAP")
        XCTAssertTrue(accept.exists)
        XCTAssertFalse(accept.isEnabled)
        tapDinnerAcceptancePadding(accept, topEdge: spanish)
        XCTAssertTrue(accept.exists)
        XCTAssertFalse(accept.isEnabled)
        XCTAssertFalse(app.staticTexts[copy("Dinner saved. Choose it separately to add grocery needs.", "Cena guardada. Elígela por separado para agregar sus necesidades de compra.")].exists)
        assertReviewedText(unknownQuantity, initiallyUpward: false)
        // Long reviews keep the same editing action available in the navigation bar.
        let editReview = app.navigationBars[copy("Dinner idea", "Idea para cenar")].buttons["dinnerReviewEdit"]
        XCTAssertTrue(editReview.exists && editReview.isHittable)
        XCTAssertEqual(editReview.label, copy("Edit", "Editar"))
        XCTAssertEqual(editReview.elementType, .button)
        capture("Dinner-review-visible-edit-action")
        editReview.tap()
        XCTAssertFalse(editReview.exists)
        fill(originalAmount, into: amountID, replacing: true, requireDone: true, useVisibleCenter: true, initiallyUpward: false, expectedPriorValue: " ",
             focusedDoneEvidence: (copy("Dinner idea", "Idea para cenar"), copy("Done", "Listo"), "Dinner-idea-Done-restored-amount", copy("Dinner ideas", "Ideas para cenar"), .top))
        tapDinnerControl(element("ledgerReviewDinner"))
        // Check the upper review facts before descending to the acceptance row.
        assertReviewedText(copy("Bean and cabbage wraps", "Tortillas rellenas de frijoles y repollo"), initiallyUpward: false)
        assertReviewedText(copy("Shredded cabbage", "Repollo rallado"))
        assertReviewedText(copy("Usable yield is unconfirmed", "El rendimiento aprovechable no está confirmado"))
        capture("First-pickup-editable-dinner-pattern")
        revealDinnerAcceptanceRow(accept); XCTAssertTrue(accept.isEnabled)
        XCTAssertTrue(editReview.exists && editReview.isHittable)
        // Supply rows precede Accept; start toward them without visiting the title again.
        tapDinnerControl(app.buttons[copy("Review stock and pack for Tortillas", "Revisar existencias y paquete de Tortillas")], initiallyUpward: false)
        let supplyHeading = app.staticTexts["ideaSupplyHeading"]
        revealScrollableContent(supplyHeading, entireRow: true)
        XCTAssertEqual(supplyHeading.label, copy("Review ingredient supply", "Revisar el abastecimiento del ingrediente"))
        capture("Dinner-supply-full-heading")
        let selectedFood = app.staticTexts["ideaSupplySelectedFood"]
        revealScrollableContent(selectedFood, entireRow: true)
        XCTAssertEqual(selectedFood.label, copy("No confirmed match", "Sin coincidencia confirmada"))
        capture("Dinner-supply-selected-food")
        func fillSupply(_ text: String, into id: String, sample: FocusedDoneSample) {
            let field = editableElement(id)
            tap(field)
            field.typeText(text)
            XCTAssertEqual(field.value as? String, text, "Entered supply value before Done: " + id)
            XCTAssertTrue(app.keyboards.firstMatch.exists, "Supply entry must show the keyboard: " + id)
            let bar = app.navigationBars[copy("Review ingredient supply", "Revisar el abastecimiento del ingrediente")]
            XCTAssertTrue(bar.exists)
            let doneLabel = copy("Done", "Listo")
            let doneBar = app.otherElements["dinnerFocusedKeyboardDoneBar"]
            XCTAssertTrue(doneBar.exists)
            let doneButtons = doneBar.buttons.matching(identifier: "dinnerFocusedKeyboardDone")
            let done = doneButtons.firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5), "The sheet must offer a top-content Done: " + id)
            XCTAssertEqual(doneButtons.count, 1)
            XCTAssertEqual(done.label, doneLabel)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", doneLabel)).count, 1)
            XCTAssertTrue(done.isEnabled && done.isHittable)
            let cancel = bar.buttons[copy("Cancel", "Cancelar")]
            XCTAssertTrue(cancel.exists && cancel.isHittable)
            guard let target = focusedDoneTarget(done, in: doneBar, below: bar, avoiding: cancel, sample: sample,
                                                    name: "Dinner-supply-Done-" + id) else { return }
            let frame = target.frame
            XCTAssertEqual(done.frame, frame, "Done geometry must remain stable before the coordinate tap")
            target.coordinate.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Done must hide the keyboard: " + id)
            XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Unfocused supply must have no Done: " + id)
            XCTAssertTrue(doneBar.waitForNonExistence(timeout: 5), "No empty Done row after dismissal")
            XCTAssertTrue(bar.exists && cancel.exists, "Done must retain this unsaved supply editor")
            XCTAssertEqual(field.value as? String, text, "Retained supply value after Done: " + id)
            capture("Dinner-supply-Done-" + id + "-after")
            let evidence = XCTAttachment(string: "field=\(id); valueBefore=\(text); valueAfter=\(field.value as? String ?? ""); doneFrame=\(frame); \(target.details); keyboardGone=\(!app.keyboards.firstMatch.exists); doneGone=\(!done.exists); sheetRetained=\(bar.exists)")
            evidence.name = "Dinner-supply-Done-" + id + "-geometry"
            evidence.lifetime = .keepAlways; add(evidence)
        }
        fillSupply("8", into: "ideaSupplyYield", sample: .bottom)
        fillSupply("2.50", into: "ideaSupplyPrice", sample: .left)
        fillSupply("Bag label", into: "ideaSupplySource", sample: .right)
        // Query the known native control by its explicit identifier. A broad
        // Any query also fetches unrelated labels across the stacked forms.
        let reviewedDetailButtons = app.buttons.matching(NSPredicate(format: "identifier == %@", "ideaSupplyConfirm"))
        let reviewedDetails = reviewedDetailButtons.firstMatch
        reveal(reviewedDetails)
        XCTAssertEqual(reviewedDetails.elementType, .button)
        XCTAssertEqual(reviewedDetails.label, copy("Use these reviewed details", "Usar estos datos revisados"))
        XCTAssertEqual(reviewedDetailButtons.count, 1)
        reviewedDetails.tap()
        assertReviewedText(copy("Usable in one pack: 8 units", "Cantidad aprovechable en un paquete: 8 unidades"), initiallyUpward: false)
        assertReviewedText(copy("Whole packs for the remainder: 1", "Paquetes enteros para lo que falta: 1"))
        assertReviewedText(copy("Estimated item cost: $2.50", "Costo estimado del artículo: $2.50"))
        capture(spanish ? "Primera-compra-paquete-revisado" : "First-pickup-reviewed-tortilla-pack")
        assertReviewedText(copy("Recipe needs: 1 cup", "La receta necesita: 1 taza"))
        try assertReadableDinnerAcceptance(accept, name: "Dinner-enabled-accept")
        XCTAssertTrue(accept.isEnabled)
        tapDinnerAcceptancePadding(accept, topEdge: spanish)
        assertText(copy("Dinner saved. Choose it separately to add grocery needs.", "Cena guardada. Elígela por separado para agregar sus necesidades de compra."))
        XCTAssertFalse(editReview.exists)
        app.terminate(); launch(reset: false, spanish: spanish)
        tap(app.tabBars.buttons[copy("Dinners", "Cenas")])
        dinnerRoot()
        tap(element("dinnerLibrary"))
        assertText(copy("Bean and cabbage wraps", "Tortillas rellenas de frijoles y repollo"))
        revealScrollableContent(app.buttons["ledgerChooseTemplate"])
        XCTAssertTrue(app.buttons["ledgerChooseTemplate"].isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "ledgerChooseTemplate").count, 1)
        openShoppingList()
        assertText(copy("Add the groceries you need for this pickup.", "Añade los alimentos que necesitas para esta compra."))
    }

    private func dinnerAcceptanceViewport(for gestureArea: CGRect, bounds measuredBounds: CGRect? = nil) -> CGRect {
        // Horizontal gesture safety margins are not obstructions over a native Form row.
        let bounds = measuredBounds ?? app.frame
        return CGRect(x: bounds.minX, y: gestureArea.minY + 12, width: bounds.width,
                      height: max(0, gestureArea.height - 24))
    }

    /// Dinner review can span many screens at accessibility sizes. Keep moving
    /// through observed content; a gesture count alone does not mean we reached an end.
    private func revealScrollableContent(_ target: XCUIElement, initiallyUpward: Bool = true, entireRow: Bool = false) {
        var upward = initiallyUpward
        var previous: [String] = []
        var previousArea: CGRect?
        var unchanged = 0
        var reversed = false
        var trace: [String] = []
        defer {
            let evidence = XCTAttachment(string: trace.joined(separator: "\n"))
            evidence.name = "Dinner-review-scroll-progress"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        for attempt in 0..<24 {
            let exists = target.exists
            let frame = exists ? target.frame : .zero
            let hittable = exists && target.isHittable
            // A live actionable target needs no whole-screen geometry unless
            // this caller also requires its complete row inside the viewport.
            if hittable && !entireRow {
                trace.append("found after \(attempt) gestures; target=\(target.identifier); frame=\(frame)")
                return
            }
            let snapshot = try? app.snapshot()
            let area = scrollableArea(from: snapshot)
            let viewport = dinnerAcceptanceViewport(for: area, bounds: snapshot?.frame)
            if hittable && viewport.contains(frame) {
                trace.append("found after \(attempt) gestures; target=\(target.identifier); frame=\(frame)")
                return
            }
            var visible: [String] = []
            var elements = snapshot.map { [$0] } ?? []
            while let element = elements.popLast() {
                if [.navigationBar, .tabBar, .keyboard].contains(element.elementType) { continue }
                let frame = element.frame
                if [.staticText, .button].contains(element.elementType), !frame.isEmpty, frame.intersects(area) {
                    // Keep full frames: clipping a tall label to the viewport hides movement.
                    let geometry = [frame.minX, frame.minY, frame.width, frame.height].map { $0.rounded() }
                    visible.append("\(element.elementType.rawValue)|\(element.identifier)|\(element.label)|\(geometry)")
                }
                elements.append(contentsOf: element.children)
            }
            visible.sort()
            let stable = !visible.isEmpty && visible == previous && previousArea == area
            unchanged = stable ? unchanged + 1 : 0
            if exists && !frame.isEmpty {
                upward = frame.midY > area.midY
            } else if unchanged >= 2 && !reversed {
                // Repeated no progress can be an end or an intercepted gesture.
                // It justifies one bounded search in the other direction, not a pass.
                upward.toggle(); reversed = true; unchanged = 0
            }
            trace.append("gesture=\(attempt + 1); upward=\(upward); exists=\(exists); frame=\(frame); area=\(area); unchanged=\(unchanged); reversed=\(reversed); visible=\(visible)")
            previous = visible; previousArea = area
            scrollContent(upward: upward, area: area, bounds: snapshot?.frame)
        }
        let viewport = dinnerAcceptanceViewport(for: scrollableArea())
        XCTAssertTrue(target.exists && target.isHittable && (!entireRow || viewport.contains(target.frame)),
                      "Dinner review target not reached within 24 gestures")
    }

    private func revealDinnerAcceptanceRow(_ button: XCUIElement) {
        revealScrollableContent(button, entireRow: true)
        let viewport = dinnerAcceptanceViewport(for: scrollableArea())
        XCTAssertTrue(button.exists && button.isHittable && viewport.contains(button.frame))
        XCTAssertEqual(button.elementType, .button)
        XCTAssertEqual(app.buttons.matching(identifier: "dinnerAcceptIdea").count, 1)
        let cell = app.cells.containing(.button, identifier: "dinnerAcceptIdea").firstMatch
        XCTAssertTrue(cell.exists)
        // Compare to the actual native row, not a screen-width assumption.
        for (actual, expected) in [(button.frame.minX, cell.frame.minX), (button.frame.minY, cell.frame.minY),
                                   (button.frame.width, cell.frame.width), (button.frame.height, cell.frame.height)] {
            XCTAssertEqual(actual, expected, accuracy: 1, "Accept must own the complete native Form row")
        }
    }

    private func tapDinnerAcceptancePadding(_ button: XCUIElement, topEdge: Bool) {
        revealDinnerAcceptanceRow(button)
        let frame = button.frame
        let point = topEdge ? CGPoint(x: frame.midX, y: frame.minY + 4) : CGPoint(x: frame.minX + 4, y: frame.midY)
        XCTAssertTrue(dinnerAcceptanceViewport(for: scrollableArea()).contains(point) && frame.contains(point))
        XCTAssertFalse(frame.insetBy(dx: 16, dy: 15).contains(point), "Exercise native row padding outside the painted shape")
        let evidence = XCTAttachment(string: "\(button.debugDescription)\nrowPaddingTap=\(point); topEdge=\(topEdge)")
        evidence.name = "Dinner-accept-row-padding-target"; evidence.lifetime = .keepAlways; add(evidence)
        button.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)).tap()
    }

    private func assertReadableDinnerAcceptance(_ button: XCUIElement, name: String) throws {
        revealDinnerAcceptanceRow(button)
        let full = button.screenshot()
        let image = try XCTUnwrap(full.image.cgImage)
        let frame = button.frame
        XCTAssertGreaterThan(frame.width, 66); XCTAssertGreaterThan(frame.height, 34)
        let scaleX = CGFloat(image.width) / frame.width, scaleY = CGFloat(image.height) / frame.height
        // Remove native row padding and the entire outline, including corner antialiasing.
        let crop = CGRect(x: ceil(33 * scaleX), y: ceil(17 * scaleY),
                          width: floor((frame.width - 66) * scaleX), height: floor((frame.height - 34) * scaleY))
        let interior = try XCTUnwrap(image.cropping(to: crop))
        let whole = XCTAttachment(screenshot: full)
        whole.name = name + "-whole-button"; whole.lifetime = .keepAlways; add(whole)
        let label = XCTAttachment(image: UIImage(cgImage: interior))
        label.name = name + "-label-interior"; label.lifetime = .keepAlways; add(label)
        let state = XCTAttachment(string: "\(button.debugDescription)\nlabelInteriorPixels=\(crop); sourcePixels=\(image.width)x\(image.height)")
        state.name = name + "-state-and-crop"; state.lifetime = .keepAlways; add(state)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: interior.width, height: interior.height, bitsPerComponent: 8,
            bytesPerRow: interior.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.draw(interior, in: CGRect(x: 0, y: 0, width: interior.width, height: interior.height))
        let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        let linear = (0...255).map { byte -> Double in
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = (0..<(interior.width * interior.height)).map { pixel in
            let index = pixel * 4
            return 0.2126 * linear[Int(bytes[index])] + 0.7152 * linear[Int(bytes[index + 1])]
                + 0.0722 * linear[Int(bytes[index + 2])]
        }.sorted()
        let trim = luminance.count / 100
        let contrast = (luminance[luminance.count - 1 - trim] + 0.05) / (luminance[trim] + 0.05)
        XCTAssertGreaterThanOrEqual(contrast, 4.5, button.label)
    }

    private func launch(reset: Bool, spanish: Bool = false, privateRecovery: Bool = false) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_US" : "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        if privateRecovery { app.launchArguments.append("--seed-private-recovery") }
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
    private func editableElement(_ id: String) -> XCUIElement {
        let editableTypes: [XCUIElement.ElementType] = [.textField, .textView, .secureTextField, .searchField]
        return app.descendants(matching: .any).matching(identifier: id)
            .matching(NSPredicate(format: "elementType IN %@", editableTypes.map { $0.rawValue })).firstMatch
    }

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
    private enum FocusedDoneSample: String { case center, top, bottom, left, right }
    private struct FocusedDoneTarget {
        let coordinate: XCUICoordinate
        let frame: CGRect
        let details: String
    }
    /// One sampled coordinate is exercised per existing interaction; this is not a hit-region map.
    private func focusedDoneTarget(_ done: XCUIElement, in bar: XCUIElement, below navigationBar: XCUIElement,
                                      avoiding other: XCUIElement, sample: FocusedDoneSample,
                                      name: String) -> FocusedDoneTarget? {
        let frame = done.frame, barFrame = bar.frame, otherFrame = other.frame, appFrame = app.frame
        let navigationFrame = navigationBar.frame, keyboardFrame = app.keyboards.firstMatch.frame
        let region = CGRect(x: frame.midX - 22, y: frame.midY - 22, width: 44, height: 44)
        // Reuse the existing before capture to measure rendered pixels per UI-test point.
        let screenshot = app.screenshot()
        let before = XCTAttachment(screenshot: screenshot)
        before.name = name + "-before"; before.lifetime = .keepAlways; add(before)
        guard let image = screenshot.image.cgImage,
              image.width > 0, image.height > 0, appFrame.width > 0, appFrame.height > 0 else {
            XCTFail("Cannot establish screenshot pixel/point conversion for Done"); return nil
        }
        let pixelX = appFrame.width / CGFloat(image.width)
        let pixelY = appFrame.height / CGFloat(image.height)
        guard pixelX.isFinite, pixelY.isFinite, pixelX > 0, pixelY > 0,
              pixelX <= 1, pixelY <= 1, abs(pixelX - pixelY) < 0.000001 else {
            XCTFail("Unexpected screenshot/app coordinate scale for Done"); return nil
        }
        var point = CGPoint(x: region.midX, y: region.midY)
        // Predeclared symmetric interior-edge policy: half a captured pixel inside every edge.
        switch sample {
        case .center: break
        case .top: point.y = region.minY + pixelY / 2
        case .bottom: point.y = region.maxY - pixelY / 2
        case .left: point.x = region.minX + pixelX / 2
        case .right: point.x = region.maxX - pixelX / 2
        }
        let coordinate = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - appFrame.minX, dy: point.y - appFrame.minY))
        // This measures raster-edge alignment; it does not assert touch-event quantization.
        let edgePixels = [(region.minX - appFrame.minX) / pixelX, (region.maxX - appFrame.minX) / pixelX,
                          (region.minY - appFrame.minY) / pixelY, (region.maxY - appFrame.minY) / pixelY]
        let edgePixelResiduals = edgePixels.map { $0 - $0.rounded() }
        let details = "policy=symmetric-half-rendered-pixel-inset-v1; edgePixelResiduals=minX,maxX,minY,maxY:\(edgePixelResiduals); sample=\(sample.rawValue); AXFrame=\(frame); region44=\(region); plannedPoint=\(point); coordinatePoint=\(coordinate.screenPoint); pixelX=\(pixelX); pixelY=\(pixelY); barFrame=\(barFrame); navigationFrame=\(navigationFrame); keyboardFrame=\(keyboardFrame); otherButtonFrame=\(otherFrame); sparseSampleOnly=true"
        let geometry = XCTAttachment(string: details)
        geometry.name = name + "-target-before"; geometry.lifetime = .keepAlways; add(geometry)
        XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height, barFrame.minX, barFrame.minY,
                       barFrame.width, barFrame.height, navigationFrame.minY, navigationFrame.maxY,
                       keyboardFrame.minY, keyboardFrame.maxY, otherFrame.minX, otherFrame.minY,
                       otherFrame.width, otherFrame.height, point.x, point.y].allSatisfy(\.isFinite))
        // Millipoint tolerance covers CGFloat roundoff, not a smaller target or shifted tap.
        XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(frame.height, 44 - 0.001)
        XCTAssertTrue(frame.insetBy(dx: -0.001, dy: -0.001).contains(region))
        XCTAssertTrue(barFrame.contains(region), "The planned 44-point region must stay inside the owned Done row")
        XCTAssertGreaterThanOrEqual(region.minY, navigationFrame.maxY + 8 - 0.001)
        XCTAssertGreaterThanOrEqual(region.minY, barFrame.minY + 8 - 0.001)
        XCTAssertLessThanOrEqual(region.maxY, barFrame.maxY - 8 + 0.001)
        XCTAssertFalse(keyboardFrame.intersects(region))
        XCTAssertTrue(appFrame.contains(region))
        XCTAssertFalse(otherFrame.intersects(region), "The planned region must avoid the separate Back/Cancel target")
        XCTAssertTrue(region.contains(point) && barFrame.contains(point))
        XCTAssertEqual(coordinate.screenPoint.x, point.x, accuracy: 0.000001)
        XCTAssertEqual(coordinate.screenPoint.y, point.y, accuracy: 0.000001)
        return FocusedDoneTarget(coordinate: coordinate, frame: frame, details: details)
    }

    private func fill(_ text: String, into id: String, replacing: Bool = false, requireDone: Bool = false, useVisibleCenter: Bool = false, initiallyUpward: Bool = true, expectedPriorValue: String? = nil,
                      focusedDoneEvidence: (title: String, label: String, name: String, back: String, sample: FocusedDoneSample)? = nil) {
        // Persistent labels can share the field's accessible name. Match only
        // editable controls, including lazily materialized Form rows.
        let field = editableElement(id)
        if useVisibleCenter {
            if focusedDoneEvidence != nil {
                // This scoped dinner editor can retain a deep review offset.
                // Find the original field using observed progress, then tap the
                // same visible center without granting another scroll budget.
                revealScrollableContent(field, initiallyUpward: initiallyUpward, entireRow: true)
                let frame = field.frame, area = scrollableArea().insetBy(dx: 0, dy: 12)
                XCTAssertTrue(field.isHittable && area.contains(CGPoint(x: frame.midX, y: frame.midY)))
                print("RECOVERY_FIELD_TAP id=\(field.identifier) frame=\(frame) area=\(area)")
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                tapVisibleFormRow(field, marker: "RECOVERY_FIELD_TAP")
            }
        } else { tap(field) }
        if let expectedPriorValue {
            XCTAssertEqual(field.identifier, id, "Keep the originally selected ingredient field")
            XCTAssertEqual(field.value as? String, expectedPriorValue, "Verify the same ingredient before replacing its amount")
        }
        if replacing, let old = field.value as? String, old != field.placeholderValue { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        field.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo"])).firstMatch
        if requireDone { XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable, "Done must be reachable from \(id)") }
        var evidenceFrame: CGRect?
        var focusedTarget: FocusedDoneTarget?
        if let evidence = focusedDoneEvidence {
            XCTAssertEqual(field.value as? String, text, "Entered amount before Done")
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            let bar = app.navigationBars[evidence.title]
            XCTAssertTrue(bar.exists)
            let doneBar = app.otherElements["dinnerFocusedKeyboardDoneBar"]
            XCTAssertTrue(doneBar.exists)
            let barDone = doneBar.buttons.matching(identifier: "dinnerFocusedKeyboardDone")
            XCTAssertEqual(barDone.count, 1)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo"])).count, 1)
            XCTAssertEqual(done.label, evidence.label)
            XCTAssertTrue(done.isEnabled && done.isHittable)
            let back = bar.buttons[evidence.back]
            XCTAssertTrue(back.exists && back.isHittable)
            guard let target = focusedDoneTarget(done, in: doneBar, below: bar, avoiding: back,
                                                    sample: evidence.sample, name: evidence.name) else { return }
            evidenceFrame = target.frame
            focusedTarget = target
        }
        var doneTapped = false
        if let target = focusedTarget {
            XCTAssertEqual(done.frame, target.frame, "Done geometry must remain stable before the coordinate tap")
            target.coordinate.tap(); doneTapped = true
        } else if done.exists && done.isHittable { done.tap(); doneTapped = true }
        if let evidence = focusedDoneEvidence {
            XCTAssertTrue(doneTapped, "The original Done action must execute exactly once")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(done.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["dinnerFocusedKeyboardDoneBar"].waitForNonExistence(timeout: 5))
            let bar = app.navigationBars[evidence.title]
            XCTAssertTrue(bar.exists, "Done must retain the editable idea before Review")
            XCTAssertEqual(field.value as? String, text, "Exact entered amount must survive Done")
            capture(evidence.name + "-after")
            let geometry = XCTAttachment(string: "field=\(id); valueBefore=\(String(reflecting: text)); valueAfter=\(String(reflecting: field.value as? String ?? "<missing>")); doneFrame=\(String(describing: evidenceFrame)); \(focusedTarget?.details ?? "<missing>"); keyboardGone=\(!app.keyboards.firstMatch.exists); doneGone=\(!done.exists); editorRetained=\(bar.exists); doneTapped=\(doneTapped)")
            geometry.name = evidence.name + "-geometry"; geometry.lifetime = .keepAlways; add(geometry)
        }
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
    private func scrollableArea(from suppliedSnapshot: (any XCUIElementSnapshot)? = nil) -> CGRect {
        // Navigation and sheet transitions can replace a bar between separate
        // XCUI queries. Measure the keyboard and bars from one captured tree.
        let snapshot = suppliedSnapshot ?? (try? app.snapshot())
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
    private func scrollContent(upward: Bool, area measuredArea: CGRect? = nil, bounds measuredBounds: CGRect? = nil) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = measuredArea ?? scrollableArea(), bounds = measuredBounds ?? app.frame
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
    private func dinnerRoot() { returnToVisibleAnchor(element("dinnerLibrary"), rootTitles: ["Dinners", "Cenas"]) }
    private func shopRoot() {
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Shop", "Compras"])).firstMatch
        tap(tab)
        returnToVisibleAnchor(element("newComparison"), rootTitles: ["Shop", "Compras"])
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
    private func returnToVisibleAnchor(_ target: XCUIElement, rootTitles: [String] = []) {
        for _ in 0..<8 {
            let leading = app.navigationBars.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && $0.identifier != "settings" && $0.frame.midX < app.frame.midX
            }.sorted { $0.frame.minX < $1.frame.minX }
            if !rootTitles.isEmpty {
                let rootBar = app.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", rootTitles, rootTitles)).firstMatch
                let rootTab = app.tabBars.buttons.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", rootTitles, rootTitles)).firstMatch
                if leading.isEmpty && rootTab.exists && rootTab.isSelected && rootBar.exists && rootBar.isHittable &&
                    !rootBar.frame.isEmpty && rootBar.frame.intersects(app.frame) {
                    // A root's lazy links may be below large introductory text.
                    // A user-named detail can share the root title. Require
                    // the selected tab and no actionable Back control as well.
                    print("ROOT_ANCHOR_SCROLL root=\(rootBar.identifier)")
                    revealScrollableContent(target)
                    return
                }
            }
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
