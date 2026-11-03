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
        let need = element("awayCarryover.need")
        XCTAssertTrue(need.waitForExistence(timeout: 20)); assertCounts(targets: 0)
        tap(need); tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dinner wraps")).firstMatch)
        tap(element("awayCarryover.supply"))
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Counted freezer wraps")).firstMatch)
        fill("6", into: "awayCarryover.counted")
        fill("2", into: "awayCarryover.reserved")
        fill("1", into: "awayCarryover.servings")
        // The focused single-line field has the observed Return key; submit it
        // before moving back to the physical-evidence switch above this field.
        if app.keyboards.firstMatch.exists {
            app.typeText(XCUIKeyboardKey.return.rawValue)
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
        enableSwitch("awayCarryover.checked")
        tap(element("awayCarryover.review"))
        assertText("Reserved for carryover: 2")
        assertText("Protected lunch")
        let apply = element("awayCarryover.apply"); reveal(apply); XCTAssertFalse(apply.isEnabled)
        capture("S25-physical-reservation-reviewed-before-save")
        tap(element("awayCarryover.cancel")); assertCounts(targets: 0)
        XCTAssertFalse(element("awayCarryover.retry").exists)
        tap(element("awayCarryover.review")); enableSwitch("awayCarryover.approve")
        tap(element("awayCarryover.apply"))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.element("fixture.away.targets").label == "Carryover targets: 1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        assertCounts(targets: 1)
        capture("S25-dated-target-and-original-purchase-retained")
        app.terminate(); launch(reset: false)
        XCTAssertTrue(element("awayCarryover.need").waitForExistence(timeout: 20)); assertCounts(targets: 1)
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
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control)
        for _ in 0..<20 {
            let area = scrollableArea(), frame = control.frame
            let switchCenter = CGPoint(x: frame.minX + frame.width * 0.92, y: frame.midY)
            if control.isHittable && area.insetBy(dx: 0, dy: 8).contains(switchCenter) { break }
            scrollContent(upward: switchCenter.y > area.maxY)
        }
        let area = scrollableArea(), frame = control.frame
        let switchCenter = CGPoint(x: frame.minX + frame.width * 0.92, y: frame.midY)
        // Toggle's accessibility frame includes its multiline label. Its trailing
        // control must be clear of the keyboard; the whole label need not fit.
        XCTAssertTrue(control.isHittable && area.insetBy(dx: 0, dy: 8).contains(switchCenter),
                      "The switch tap point must be clear of the keyboard and toolbar")
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
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
