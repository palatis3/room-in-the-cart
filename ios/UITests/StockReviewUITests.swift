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
    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "--stock-review-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-stock-review-fixture") }
        app.launch()
    }
    private func openBatchAndPreview() {
        tap(element("stockBatch-77777777-7777-4777-8777-777777777777"))
        let amount = element("stockReview.amount"); tap(amount); app.typeText("3")
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
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
