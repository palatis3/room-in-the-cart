#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Dedicated isolated fixture build only; normal full-suite builds contain no S24 fixture test.
@MainActor final class HouseholdRequestPackUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("S24-request-pack-failure") }
        app.terminate()
    }
    func testReviewedCheapestAvailablePackUsesActualDecisionAndCancelHasNoWrite() {
        app.launchArguments = ["--ui-testing", "--request-pack-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let request = element("household.request.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(request.waitForExistence(timeout: 20)); tap(request)
        let cancel = element("household.decision.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); tap(cancel)
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
        tap(request)
        tap(element("household.decision.choice")); tap(app.buttons["Add packs to this shop"])
        tap(app.buttons["Compare available packs for this request"])
        fill("8", into: "household.pack.need", replacing: true)
        for (id, yield, price) in [("a", "4", "3.00"), ("b", "6", "4.00")] {
            fill("Reviewed pack " + id, into: "household.pack.\(id).label", replacing: true)
            fill(yield, into: "household.pack.\(id).usable", replacing: true)
            fill(price, into: "household.pack.\(id).price", replacing: true)
            tap(element("household.pack.\(id).availability")); tap(app.buttons["Available"])
            fill("Reviewed shelf " + id, into: "household.pack.\(id).source", replacing: true)
            enableSwitch("household.pack.\(id).matched")
        }
        tap(element("household.pack.compare"))
        assertText("Cheapest sufficient option among reviewed available packs with known prices")
        capture("S24-reviewed-available-pack-result")
        let use = element("household.pack.use.a"); reveal(use); XCTAssertTrue(use.isEnabled); tap(use)
        tap(element("household.decision.review"))
        let apply = element("household.decision.apply"); reveal(apply); XCTAssertFalse(apply.isEnabled)
        assertText("Reviewed shelf a")
        assertText("After this decision")
        capture("S24-actual-household-preview-before-overage-approval")
        enableSwitch("household.decision.overage")
        reveal(apply); XCTAssertTrue(apply.isEnabled); tap(apply)
        let confirmations = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Decision confirmed by the household"))
        // The inbox behind the sheet displays the same receipt. Require the
        // visible sheet receipt, rather than the covered parent's first match.
        let visibleReceipt = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            confirmations.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleReceipt], timeout: 10), .completed)
        capture("S24-actual-decision-receipt")
        tap(element("household.decision.cancel"))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 1")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 1")
        capture("S24-request-returned-once-after-sheet-dismissal")
    }
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
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
