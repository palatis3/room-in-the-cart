#if DEBUG && STOCK_REVIEW_UI_FIXTURE
import XCTest

@MainActor final class StockReviewUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("E06-stock-review-failure")
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "E06-stock-review-accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        app.terminate()
    }
    func testPreviewCancelThenConfirmShowsEveryMealAndFreshCookInstructionAfterRestart() {
        launch(reset: true)
        XCTAssertTrue(element("fixture.stock.savedUnits").waitForExistence(timeout: 20))
        let initialRevision = element("fixture.stock.revision").label
        XCTAssertEqual(element("fixture.stock.savedUnits").label, "Saved batch units: 5")
        openBatchAndPreview()
        assertText("Before this change: Allocated: 3 units · Still short: 1 unit")
        assertText("After this change: Allocated: 1 unit · Still short: 3 units")
        assertText("Protected lunch")
        assertText("Allocation change: −2 units")
        let apply = element("stockReview.apply"); reveal(apply); XCTAssertFalse(apply.isEnabled)
        XCTAssertEqual(element("fixture.stock.savedUnits").label, "Saved batch units: 5")
        XCTAssertEqual(element("fixture.stock.revision").label, initialRevision)
        capture("E06-dependent-meals-reviewed-before-commit")
        tap(element("stockReview.cancel"))
        XCTAssertEqual(element("fixture.stock.savedUnits").label, "Saved batch units: 5")
        XCTAssertEqual(element("fixture.stock.revision").label, initialRevision)
        tap(element("stockReview.preview"))
        enableSwitch("stockReview.effectsChecked")
        tap(element("stockReview.apply"))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Saved batch units: 3"), object: element("fixture.stock.savedUnits"))
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        XCTAssertEqual(element("fixture.stock.shortfall").label, "Dinner shortfall: 3")
        capture("E06-corrected-stock-protects-lunch")
        app.terminate(); launch(reset: false)
        XCTAssertTrue(element("fixture.stock.cook").waitForExistence(timeout: 20))
        XCTAssertEqual(element("fixture.stock.savedUnits").label, "Saved batch units: 3")
        XCTAssertEqual(element("fixture.stock.shortfall").label, "Dinner shortfall: 3")
        tap(element("fixture.stock.cook"))
        tap(app.buttons["Prepare complete dated instruction"])
        let editor = app.textViews["Editable cook instruction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let currentText = editor.value as? String ?? ""
        XCTAssertTrue(currentText.contains("Allocated: 1 unit"), currentText)
        XCTAssertTrue(currentText.contains("Still short: 3 units"), currentText)
        XCTAssertTrue(currentText.contains("Protected lunch: 2 units — set aside first"), currentText)
        XCTAssertTrue(currentText.contains("Initially observed available: 0 units"), currentText)
        XCTAssertFalse(currentText.contains("Confirmed available: 0"), currentText)
        // Production readback displays the exact current projection beside its playback control.
        let readback = app.staticTexts.matching(NSPredicate(format: "label == %@", currentText)).firstMatch
        reveal(readback); XCTAssertEqual(readback.label, currentText)
        reveal(element("capture.readback.play")); XCTAssertTrue(element("capture.readback.play").exists)
        capture("D12-N03-current-cook-text-and-readback-after-correction")
    }
    func testChangedMealRevisionDisablesPreviewWithoutApplyingBatch() {
        launch(reset: true)
        XCTAssertTrue(element("fixture.stock.savedUnits").waitForExistence(timeout: 20))
        openBatchAndPreview()
        enableSwitch("stockReview.effectsChecked")
        tap(element("fixture.stock.changeMeals"))
        assertText("The batch or meal commitments changed. Review the effects again before saving.")
        let apply = element("stockReview.apply"); reveal(apply); XCTAssertFalse(apply.isEnabled)
        XCTAssertEqual(element("fixture.stock.savedUnits").label, "Saved batch units: 5")
        capture("E06-stale-dependent-meal-review-blocked")
    }
    func testNewBatchRetryPreservesDraftThenAllowsAnotherDistinctBatchAfterRestart() throws {
        launch(reset: true, retryControls: true)
        XCTAssertTrue(element("fixture.stock.newBatch").waitForExistence(timeout: 20))
        XCTAssertEqual(try stockLotRecords().count, 1, "Begin with an existing pickup and its seeded batch")
        tap(element("fixture.stock.newBatch"))
        enterNewBatch(name: "Retry batch A", amount: "3")
        tap(element("fixture.stock.lock"))
        XCTAssertFalse(element("fixture.stock.lockFailure").exists)
        waitForStockWriteState("Database lock: held · Pending: no · Saving: no")
        tap(app.buttons["Confirm this separate stock lot"])
        waitForBlockedStockSaveCount(1)
        waitForStockWriteState("Database lock: held · Pending: yes · Saving: no")
        XCTAssertEqual(try stockLotRecords().count, 1)

        // Retry the same pending operation while the real SQLite writer is still blocked.
        // Both failures must leave the submitted form and saved pickup intact.
        tap(app.buttons["Retry save"])
        waitForBlockedStockSaveCount(2)
        waitForStockWriteState("Database lock: held · Pending: yes · Saving: no")
        let name = app.textFields["Actual food or freezer batch"]
        let amount = app.textFields["Confirmed usable amount"]
        reveal(name); XCTAssertEqual(name.value as? String, "Retry batch A")
        reveal(amount); XCTAssertEqual(amount.value as? String, "3")
        let pendingNameDisabled = !name.isEnabled
        let pendingAmountDisabled = !amount.isEnabled
        let confirmation = app.switches["I reviewed identity, exclusions and usable quantity"]
        reveal(confirmation)
        let pendingConfirmationDisabled = !confirmation.isEnabled
        XCTAssertEqual(try stockLotRecords().count, 1)
        capture("stock-entry-failed-retry-preserves-submitted-draft")

        tap(element("fixture.stock.release"))
        tap(app.buttons["Retry save"])
        waitForStockWriteState("Database lock: released · Pending: no · Saving: no")
        let firstSaved = try stockLotRecords()
        let first = try XCTUnwrap(firstSaved.first { $0["name"] == "Retry batch A" })
        XCTAssertEqual(firstSaved.count, 2)
        XCTAssertEqual(first["amount"], "3")
        XCTAssertEqual(first["unit"], "count")
        reveal(name)
        let clearedName = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == nil OR value == %@ OR value == %@", "", "Actual food or freezer batch"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [clearedName], timeout: 5), .completed,
                       "Successful retry must finish the new-batch draft, including rotating its ID")
        // Assert the captured pending state after the reset assertion so an unfixed
        // baseline first demonstrates the stale-draft defect rather than its guard.
        XCTAssertTrue(pendingNameDisabled && pendingAmountDisabled && pendingConfirmationDisabled,
                      "Submitted stock fields must stay disabled while the failed write is pending")
        reveal(amount)
        let clearedAmount = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == nil OR value == %@ OR value == %@", "", "Confirmed usable amount"), object: amount)
        XCTAssertEqual(XCTWaiter.wait(for: [clearedAmount], timeout: 5), .completed)
        XCTAssertTrue(name.isEnabled && amount.isEnabled)
        let reviewed = app.switches["I reviewed identity, exclusions and usable quantity"]
        reveal(reviewed); XCTAssertEqual(reviewed.value as? String, "0")

        enterNewBatch(name: "Retry batch B", amount: "7")
        tap(app.buttons["Confirm this separate stock lot"])
        let records = element("fixture.stock.lotRecords")
        let secondSaved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Retry batch B"), object: records)
        XCTAssertEqual(XCTWaiter.wait(for: [secondSaved], timeout: 15), .completed)
        let beforeRestart = try stockLotRecords()
        assertTwoNewStockBatches(beforeRestart)
        XCTAssertEqual(beforeRestart.first { $0["name"] == "Retry batch A" }?["id"], first["id"])
        capture("stock-entry-retry-then-second-distinct-batch")

        app.terminate(); launch(reset: false, retryControls: true)
        XCTAssertTrue(element("fixture.stock.lotRecords").waitForExistence(timeout: 20))
        let reloaded = try stockLotRecords()
        assertTwoNewStockBatches(reloaded)
        XCTAssertEqual(reloaded, beforeRestart, "Both IDs and exact quantities must survive real SQLite reload")
        let evidence = XCTAttachment(string: element("fixture.stock.lotRecords").label)
        evidence.name = "stock-entry-retry-persisted-lot-ids-and-quantities"
        evidence.lifetime = .keepAlways; add(evidence)
        capture("stock-entry-retry-distinct-batches-after-restart")
    }

    private func enterNewBatch(name: String, amount: String) {
        let nameField = app.textFields["Actual food or freezer batch"]
        tap(nameField); nameField.typeText(name)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        done.tap()
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: "Done"))
        let amountField = app.textFields["Confirmed usable amount"]
        tap(amountField); amountField.typeText(amount)
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        done.tap()
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: "Done"))
        XCTAssertEqual(nameField.value as? String, name)
        XCTAssertEqual(amountField.value as? String, amount)
        enableSwitch("I reviewed identity, exclusions and usable quantity")
    }
    private func waitForBlockedStockSaveCount(_ expected: Int) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Blocked saves completed: \(expected)"),
            object: element("fixture.stock.blockedSaveCount"))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
    private func waitForStockWriteState(_ expected: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected),
                                                   object: element("fixture.stock.writeState"))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
    private func stockLotRecords() throws -> [[String: String]] {
        let data = try XCTUnwrap(element("fixture.stock.lotRecords").label.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
    }
    private func assertTwoNewStockBatches(_ records: [[String: String]]) {
        XCTAssertEqual(records.count, 3, "Seeded freezer batch plus exactly two new batches")
        XCTAssertEqual(Set(records.compactMap { $0["id"] }).count, 3)
        for (name, quantity) in [("Freezer wraps", "5"), ("Retry batch A", "3"), ("Retry batch B", "7")] {
            let matches = records.filter { $0["name"] == name }
            XCTAssertEqual(matches.count, 1, name)
            XCTAssertEqual(matches.first?["amount"], quantity, name)
            XCTAssertEqual(matches.first?["unit"], "count", name)
            let id = matches.first?["id"]
            XCTAssertNotNil(id.flatMap { UUID(uuidString: $0) }, name)
        }
    }

    // Each point gets a fresh form and one tap within the comfortable 44-point target.
    func testKeyboardDoneAcceptsCenterAndTargetMargins() throws {
        var results: [[String: Any]] = []
        let probes: [(String, CGFloat, CGFloat)] = [
            ("center", 0, 0), ("topLeft", -18, -18), ("topRight", 18, -18),
            ("bottomLeft", -18, 18), ("bottomRight", 18, 18)
        ]
        for (name, dx, dy) in probes {
            app.terminate(); launch(reset: true)
            XCTAssertTrue(element("fixture.stock.savedUnits").waitForExistence(timeout: 20))
            tap(element("stockBatch-77777777-7777-4777-8777-777777777777"))
            enterReviewAmount()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
            let before = try keyboardState()
            XCTAssertTrue(before.keyboardVisible)
            XCTAssertEqual(before.amount, "3")
            let frame = try XCTUnwrap(before.doneFrame)
            XCTAssertGreaterThanOrEqual(frame.width, 44, "Done target width")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "Done target height")
            let bounds = before.bounds
            let point = CGPoint(x: frame.midX + dx, y: frame.midY + dy)
            let started = Date().timeIntervalSince1970
            print("RITC_DONE_POINT \(name) \(started) x=\(point.x) y=\(point.y)")
            capture("Done-target-\(name)-before")
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - bounds.minX, dy: point.y - bounds.minY)).tap()
            // The tap waits for the app to idle. Judge the same editor, keyboard,
            // and toolbar together from one accessibility tree after that single tap.
            let after = try keyboardState()
            let dismissed = after.amount == "3" && !after.keyboardVisible && after.doneFrame == nil
            let record: [String: Any] = ["probe": name, "epoch": started,
                "point": [Double(point.x), Double(point.y)],
                "exposedFrame": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
                "keyboardVisibleAfter": after.keyboardVisible, "doneVisibleAfter": after.doneFrame != nil,
                "amountAfter": after.amount ?? "", "keyboardDismissed": dismissed]
            results.append(record)
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Done-target-\(name)-result"; attachment.lifetime = .keepAlways; add(attachment)
            capture("Done-target-\(name)-after")
            app.terminate()
        }
        XCTAssertTrue(results.allSatisfy { $0["keyboardDismissed"] as? Bool == true }, "Each independently focused probe must dismiss on its single tap: \(results)")
    }

    private func keyboardState() throws -> (bounds: CGRect, amount: String?, keyboardVisible: Bool, doneFrame: CGRect?) {
        let root = try app.snapshot()
        var nodes = [root]
        var amount: String?
        var keyboardVisible = false
        var doneFrame: CGRect?
        while let node = nodes.popLast() {
            nodes.append(contentsOf: node.children)
            guard !node.frame.isEmpty, node.frame.intersects(root.frame) else { continue }
            if node.elementType == .keyboard { keyboardVisible = true }
            if node.elementType == .button, node.identifier == "Done" { doneFrame = node.frame }
            if node.elementType == .textField, node.identifier == "stockReview.amount" { amount = node.value as? String }
        }
        return (root.frame, amount, keyboardVisible, doneFrame)
    }

    private func launch(reset: Bool, retryControls: Bool = false) {
        app.launchArguments = ["--ui-testing", "--stock-review-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-stock-review-fixture") }
        if retryControls { app.launchArguments.append("--stock-entry-retry-controls") }
        app.launch()
    }
    private func enterReviewAmount() {
        let amount = app.textFields["stockReview.amount"]
        tap(amount)
        // Enter the digit on the presented keyboard before operating its Done bar.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let three = keyboard.keys["3"]
        XCTAssertTrue(three.waitForExistence(timeout: 5) && three.isHittable)
        three.tap()
        XCTAssertEqual(amount.value as? String, "3")
    }
    private func openBatchAndPreview() {
        tap(element("stockBatch-77777777-7777-4777-8777-777777777777"))
        enterReviewAmount()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThanOrEqual(done.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        done.tap()
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: "Done"))
        enableSwitch("stockReview.identityChecked")
        tap(element("stockReview.preview"))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable); target.tap() }
    private func enableSwitch(_ id: String) {
        let control = app.switches[id]; reveal(control)
        for _ in 0..<20 {
            let area = scrollableArea(), frame = control.frame
            let center = CGPoint(x: frame.minX + frame.width * 0.92, y: frame.midY)
            if control.isHittable && area.insetBy(dx: 0, dy: 8).contains(center) { break }
            scroll(upward: center.y > area.maxY)
        }
        XCTAssertTrue(control.isHittable)
        if control.value as? String == "0" { control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(control.value as? String, "1")
    }
    private func assertText(_ text: String) {
        let target = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists)
    }
    private func reveal(_ target: XCUIElement) {
        for attempt in 0..<24 {
            if target.exists && target.isHittable { return }
            let upward = target.exists && !target.frame.isEmpty ? target.frame.midY > scrollableArea().midY : attempt < 16
            scroll(upward: upward)
        }
        XCTAssertTrue(target.exists && target.isHittable, target.debugDescription)
    }
    private func scrollableArea() -> CGRect {
        let bounds = app.frame
        let keyboard = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY }.min() ?? bounds.maxY
        let bar = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame.maxY }.max() ?? bounds.minY + 200
        let top = max(bounds.minY + 200, min(bar + 12, keyboard - 140)), bottom = min(bounds.maxY - 70, keyboard - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scroll(upward: Bool) {
        let area = scrollableArea(), origin = app.coordinate(withNormalizedOffset: .zero), bounds = app.frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY)))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
