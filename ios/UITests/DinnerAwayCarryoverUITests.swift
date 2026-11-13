#if DEBUG && AWAY_CARRYOVER_UI_FIXTURE
import XCTest

/// Production carryover screens backed by isolated real local stores.
@MainActor final class DinnerAwayCarryoverUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("S25-carryover-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "S25-carryover-failure-accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        app.terminate()
    }
    func testPhysicalCarryoverCancelApplyAndRestartKeepOriginalPurchase() {
        launch(reset: true)
        let need = app.buttons["awayCarryover.need"]
        XCTAssertTrue(need.waitForExistence(timeout: 20)); assertCounts(targets: 0)
        tap(need); tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dinner wraps")).firstMatch)
        tap(element("awayCarryover.supply"))
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Counted freezer wraps")).firstMatch)
        fill("6", into: "awayCarryover.counted")
        fill("2", into: "awayCarryover.reserved")
        fill("1", into: "awayCarryover.servings")
        // The focused single-line field has the observed Return key; submit it
        // before moving back to the physical-evidence confirmation above this field.
        if app.keyboards.firstMatch.exists {
            app.typeText(XCUIKeyboardKey.return.rawValue)
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
        confirm("awayCarryover.checked")
        tap(element("awayCarryover.review"))
        assertText("Reserved for carryover: 2")
        assertText("Protected lunch")
        let apply = element("awayCarryover.apply"); reveal(apply); XCTAssertFalse(apply.isEnabled)
        capture("S25-physical-reservation-reviewed-before-save")
        tap(element("awayCarryover.cancel")); assertCounts(targets: 0)
        XCTAssertFalse(element("awayCarryover.retry").exists)
        tap(element("awayCarryover.review")); confirm("awayCarryover.approve")
        tap(element("awayCarryover.apply"))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.element("fixture.away.targets").label == "Carryover targets: 1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        assertCounts(targets: 1)
        capture("S25-dated-target-and-original-purchase-retained")
        app.terminate(); launch(reset: false)
        XCTAssertTrue(app.buttons["awayCarryover.need"].waitForExistence(timeout: 20)); assertCounts(targets: 1)
        let savedTarget = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "awayCarryover.saved.")).firstMatch
        tap(savedTarget)
        assertText("Only this linked physical reservation is claimed.")
        assertText("Reserved quantity: 2")
        assertText("Original dinner: Away-night wraps")
        XCTAssertFalse(app.buttons["Preview calendar change"].exists)
        XCTAssertFalse(app.buttons["Edit quantities manually"].exists)
        capture("S25-real-dated-carryover-reopened-after-restart")
    }
    private func launch(reset: Bool) {
        app.launchArguments = ["--away-carryover-fixture", "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-away-carryover-fixture") }
        app.launch()
    }
    private func assertCounts(targets: Int) {
        XCTAssertEqual(element("fixture.away.targets").label, "Carryover targets: \(targets)")
        XCTAssertEqual(element("fixture.away.lots").label, "Physical lots: 1")
        XCTAssertEqual(element("fixture.away.receipts").label, "Original receipts: 1")
        XCTAssertEqual(element("fixture.away.charge").label, "Posted charge cents: 700")
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement, requireContentFrame: Bool = false) {
        reveal(target, requireContentFrame: requireContentFrame)
        XCTAssertTrue(target.isHittable, target.debugDescription); target.tap()
    }
    private func confirm(_ identifier: String) {
        let button = app.buttons[identifier]
        reveal(button)
        XCTAssertFalse(button.isSelected)
        button.tap()
        XCTAssertTrue(button.isSelected, identifier)
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        let field = app.textFields[id]; tap(field, requireContentFrame: true)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func reveal(_ target: XCUIElement, requireContentFrame: Bool = false) {
        for attempt in 0..<24 {
            let hittable = target.exists && target.isHittable
            if hittable && !requireContentFrame { return }
            let area = scrollableArea()
            // A field below the keyboard can briefly report hittable before
            // the tap. Require its full frame in the existing content viewport.
            if hittable {
                let frame = target.frame
                if !frame.isEmpty && area.contains(frame) { return }
            }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            scrollContent(upward: upward)
        }
        XCTAssertTrue(target.exists && target.isHittable &&
                      (!requireContentFrame || (!target.frame.isEmpty && scrollableArea().contains(target.frame))),
                      "Missing actionable UI element: \(target.debugDescription)")
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
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
