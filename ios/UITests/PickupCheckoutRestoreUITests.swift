import XCTest

/// Uses the ordinary local checkout route and existing public control labels.
@MainActor final class PickupCheckoutRestoreUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Checkout-restoration-failure"; attachment.lifetime = .keepAlways; add(attachment)
        }
        app.terminate()
    }

    func testInclusiveCheckoutFieldsAndResultSurviveRestartAndUnchangedSave() {
        launch(reset: true)
        tap(app.buttons["openPickupList"]); tap(app.buttons["ledgerImport"])
        enter("2 wraps", field: app.textViews["ledgerImportText"])
        finishEditing()
        tap(app.buttons["ledgerReviewImport"])
        let addReviewedList = app.buttons["ledgerCommitImport"]
        XCTAssertTrue(addReviewedList.waitForExistence(timeout: 8))
        XCTAssertTrue(addReviewedList.isHittable)
        addReviewedList.tap()
        shopRoot()
        tap(app.buttons["Review checkout"]); tap(app.buttons["Continue to checkout review"])
        tap(app.buttons["Apply reviewed checkout copy"]); tap(app.buttons["Review whole checkout"])
        // Move between checkout fields in one editing session. Repeatedly dismissing
        // and reopening the keyboard left XCTest waiting for keyboard animations.
        for (label, value) in [("Store", "Hydration market"), ("Branch", "Main branch"),
                               ("Pickup or delivery slot", "Tuesday 5 PM"), ("Source of these prices", "Reviewed checkout snapshot"),
                               ("Spending cap", "10.00")] {
            enter(value, field: app.textFields[label], replacing: true)
        }
        let inclusive = app.switches["Retailer total already includes all charges"]
        let thumb = inclusive.switches.firstMatch
        reveal(thumb, reserveKeyboardSpace: false)
        XCTAssertEqual(inclusive.switches.count, 1)
        if inclusive.value as? String == "0" {
            thumb.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        }
        XCTAssertEqual(thumb.value as? String, "1")
        XCTAssertEqual(inclusive.value as? String, "1")
        enter("3.00", field: app.textFields["Inclusive total"])
        finishEditing()
        saveCheckout()
        restartAndOpenCheckout()
        assertRestoredCheckout()
        saveCheckout() // No field or toggle is changed after restoration.
        restartAndOpenCheckout()
        assertRestoredCheckout()
    }

    private func assertRestoredCheckout() {
        for (label, expected) in [("Store", "Hydration market"),
                                  ("Branch", "Main branch"), ("Pickup or delivery slot", "Tuesday 5 PM"),
                                  ("Source of these prices", "Reviewed checkout snapshot"), ("Spending cap", "10")] {
            let field = app.textFields[label]; reveal(field)
            XCTAssertEqual(field.value as? String, expected, "Restored checkout field: " + label)
        }
        let inclusive = app.switches["Retailer total already includes all charges"]
        reveal(inclusive)
        // This is the original defect: the old app still shows the saved result
        // below, while this switch has reset and its saved total field is gone.
        XCTAssertEqual(inclusive.value as? String, "1", "The saved inclusive pricing mode must reopen unchanged")
        let total = app.textFields["Inclusive total"]
        reveal(total)
        XCTAssertEqual(total.value as? String, "3")
        reveal(app.staticTexts.matching(NSPredicate(format: "label == %@", "$3.00")).firstMatch)
        reveal(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "room remaining")).firstMatch)
        XCTAssertFalse(app.staticTexts["Whether this fits the cap is unresolved"].exists)
    }
    private func saveCheckout() {
        let save = app.buttons["Save and evaluate checkout"]
        tap(save)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        reveal(app.staticTexts.matching(NSPredicate(format: "label == %@", "$3.00")).firstMatch)
    }
    private func restartAndOpenCheckout() {
        app.terminate(); launch(reset: false)
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Review whole checkout"])
    }
    private func launch(reset: Bool) {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 { app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable" }
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(app.buttons["newComparison"].waitForExistence(timeout: 15))
    }
    private func enter(_ text: String, field: XCUIElement, replacing: Bool = false) {
        tap(field)
        if replacing, let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }
    private func finishEditing() {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }
    private func tap(_ target: XCUIElement) {
        reveal(target)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func reveal(_ target: XCUIElement, reserveKeyboardSpace: Bool = true) {
        for attempt in 0..<48 {
            let area = contentArea(reserveKeyboardSpace: reserveKeyboardSpace), exists = target.exists
            if exists && target.isHittable && area.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) { return }
            let frame = exists ? target.frame : .zero
            let upward = !frame.isEmpty ? frame.midY > area.midY : attempt < 24
            let bounds = app.frame, origin = app.coordinate(withNormalizedOffset: .zero)
            let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
            origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("Missing visible checkout control: " + target.debugDescription)
    }
    private func contentArea(reserveKeyboardSpace: Bool) -> CGRect {
        let snapshot = try? app.snapshot(), bounds = snapshot?.frame ?? app.frame
        var top = bounds.minY + 88, bottom = bounds.maxY - 30
        var elements = snapshot.map { [$0] } ?? []
        while let value = elements.popLast() {
            elements.append(contentsOf: value.children)
            let frame = value.frame
            guard !frame.isEmpty, frame.intersects(bounds) else { continue }
            if value.elementType == .navigationBar { top = max(top, frame.maxY) }
            if value.elementType == .keyboard || value.elementType == .tabBar { bottom = min(bottom, frame.minY) }
            if value.elementType == .button && value.label == "Done" {
                // XCTest can briefly hide the keyboard during typeText. While editing,
                // reveal the next control above the space the keyboard will reclaim.
                bottom = min(bottom, frame.minY)
                if reserveKeyboardSpace { bottom = min(bottom, bounds.midY) }
            }
        }
        return CGRect(x: bounds.minX + 16, y: top + 8, width: bounds.width - 32, height: max(0, bottom - top - 16))
    }
    private func shopRoot() {
        app.tabBars.buttons["Shop"].tap()
        for _ in 0..<8 {
            if app.buttons["newComparison"].exists && app.buttons["newComparison"].isHittable { return }
            let leading = app.navigationBars.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && $0.identifier != "settings" && $0.frame.midX < app.frame.midX
            }.sorted { $0.frame.minX < $1.frame.minX }
            guard let back = leading.first else { return XCTFail("No visible Back control while returning to Shop") }
            back.tap()
        }
        XCTFail("Shop root did not reopen")
    }
}
