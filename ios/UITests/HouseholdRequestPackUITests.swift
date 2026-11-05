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
        if testRun?.failureCount ?? 0 > 0 {
            capture("S24-request-pack-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "S24-failure-accessibility-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let diagnostics = element("fixture.s24.preview-diagnostics")
            let snapshot = XCTAttachment(string: diagnostics.exists ? diagnostics.label : "S24 fixture diagnostics unavailable")
            snapshot.name = "S24-failure-preview-diagnostics"; snapshot.lifetime = .keepAlways; add(snapshot)
        }
        app.terminate()
    }
    func testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite() {
        openCerealReview()
        let sam = element("household.decision.meal.88888888-8888-4888-8888-888888888888")
        let mia = element("household.decision.meal.99999999-9999-4999-8999-999999999999")
        // Require one actual viewport with both current/proposed checkout and
        // the two named commitments, rather than finding each after scrolling.
        let context = [element("household.decision.after-total"), element("household.decision.over-cap"), element("household.decision.before-total"), sam, mia]
        revealTogether(context)
        for target in context {
            XCTAssertTrue(target.exists && target.isHittable, target.debugDescription)
        }
        XCTAssertTrue(element("household.decision.before-total").label.contains("$37.20"))
        XCTAssertTrue(element("household.decision.after-total").label.contains("$40.69"))
        XCTAssertTrue(element("household.decision.over-cap").label.contains("$2.69"))
        XCTAssertTrue(sam.label.contains("Sam’s wrap lunch") && sam.label.contains("Protected portions") && sam.label.contains("1"))
        XCTAssertTrue(mia.label.contains("Mia’s wrap lunch") && mia.label.contains("Protected portions") && mia.label.contains("1"))
        capture("S24-cereal-checkout-with-two-named-protected-lunches")
        tap(element("household.decision.cancel"))
        let request = element("household.request.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(request.waitForExistence(timeout: 5)); XCTAssertTrue(request.label.contains("Received, waiting for review"))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
        tap(element("fixture.s24.end-access"))
        XCTAssertTrue(app.staticTexts["Shopper access has ended. Return to household settings."].waitForExistence(timeout: 10))
        XCTAssertFalse(request.exists); XCTAssertFalse(sam.exists); XCTAssertFalse(mia.exists)
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        capture("S24-shopper-access-ended-clears-private-context")
    }
    func testUnavailableMealFactsRemainUnknownInRequestDecision() {
        openCerealReview(extraArguments: ["--request-meals-unknown"])
        let unknown = element("household.decision.meals.unknown")
        reveal(unknown)
        XCTAssertTrue(unknown.label.contains("Meal commitments are unavailable"))
        XCTAssertFalse(element("household.decision.meal.88888888-8888-4888-8888-888888888888").exists)
        XCTAssertFalse(element("household.decision.meal.99999999-9999-4999-8999-999999999999").exists)
        capture("S24-unavailable-meal-commitments-stay-unknown")
        tap(element("household.decision.cancel"))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
    }
    private func openCerealReview(extraArguments: [String] = []) {
        app.launchArguments = ["--ui-testing", "--request-pack-fixture", "--request-meal-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        app.launch()
        let request = element("household.request.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(request.waitForExistence(timeout: 20)); tap(request)
        tap(element("household.decision.choice")); tap(app.buttons["Add packs to this shop"])
        fill("3.49", into: "household.decision.price", replacing: true)
        tap(element("household.decision.review"))
        XCTAssertTrue(element("household.decision.after-total").waitForExistence(timeout: 10))
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
        dismissKeyboardIfPresent()
        reveal(control, fullyVisible: true)
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
    private func dismissKeyboardIfPresent() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let bounds = app.frame, area = scrollableArea()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 8, dy: area.minY + area.height * 0.25 - bounds.minY))
        let end = origin.withOffset(CGVector(dx: 8, dy: bounds.height - 30))
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false) {
        for attempt in 0..<24 {
            let area = scrollableArea()
            if target.exists && target.isHittable &&
                (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)) { return }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            scrollContent(upward: upward)
        }
        let area = scrollableArea()
        XCTAssertTrue(target.exists && target.isHittable &&
            (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)),
            "Missing fully actionable UI element: \(target.debugDescription)")
    }
    private func revealTogether(_ targets: [XCUIElement]) {
        guard let first = targets.first, let last = targets.last else { return }
        reveal(last)
        for _ in 0..<16 {
            if targets.allSatisfy({ $0.exists && $0.isHittable }) { return }
            // Fine positioning avoids a whole-cell scroll hiding the first
            // amount after the second lunch becomes visible.
            scrollContent(upward: first.exists && first.isHittable, amount: 0.12)
        }
    }
    private func scrollableArea() -> CGRect {
        let bounds = app.frame
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY }.min() ?? bounds.maxY
        let barBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame.maxY }.max() ?? bounds.minY + 88
        let top = max(bounds.minY + 88, min(barBottom + 12, keyboardTop - 140))
        let bottom = min(bounds.maxY - 100, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool, amount: CGFloat = 0.6) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = scrollableArea(), bounds = app.frame
        let high = area.midY - area.height * amount / 2, low = area.midY + area.height * amount / 2
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
