#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Dedicated fixture build only; shipping app models/views/client, intercepted fictional endpoints.
@MainActor final class ContributorRequestUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Contributor-request-failure") }
        app.terminate()
    }
    func testSpanishLargeTextReviewStartsAtTheOriginalWording() {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 {
            app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        }
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(es)", "-AppleLocale", "es_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hogar"].waitForExistence(timeout: 30))
        tap(element("household.request.capture"))
        let captureBar = app.navigationBars["Capturar una solicitud"]
        XCTAssertTrue(captureBar.waitForExistence(timeout: 10))
        let original = "2 paquetes de 8 tortillas para almuerzo sin leche"
        fill(original, into: "capture.editor", replacing: true)
        enableSwitch("Revisé el texto, las cantidades, las unidades y las exclusiones.")
        tap(element("capture.reviewFields"))

        let atTop = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let text = object as? XCUIElement, text.exists, text.isHittable else { return false }
            return text.frame.minY >= captureBar.frame.maxY && text.frame.minY < self.app.frame.midY
        }, object: element("capture.structured.original"))
        XCTAssertEqual(XCTWaiter.wait(for: [atTop], timeout: 12), .completed)
        XCTAssertEqual(element("capture.structured.original").label, original)
        capture("Spanish-large-text-original-at-top")
    }

    func testTypedAndStructuredReviewCancelThenSendOnlyOwnRequest() throws {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForHousehold(timeout: 20)
        fill("Rice", into: "Item")
        fill("2 packs", into: "Quantity, optional")
        tap(element("household.request.review"))
        assertText("Request the household will receive")
        assertText("Rice")
        tap(app.buttons["Cancel"])
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 0")
        openStructuredReview()
        capture("Contributor-original-and-corrected-request-preview")
        tap(app.buttons["Cancel"])
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 0")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 0")
        openStructuredReview()
        let approval = element("household.request.approve")
        reveal(approval, fullyVisible: true)
        approval.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(approval.value as? String, "1")
        tap(element("household.request.sendReviewed"))
        waitForHousehold(timeout: 10)
        let posts = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Fixture request POSTs: 1"), object: element("fixture.requestPosts"))
        let rows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Fixture saved requests: 1"), object: element("fixture.requestRows"))
        XCTAssertEqual(XCTWaiter.wait(for: [posts, rows], timeout: 10), .completed)
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 1")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 1")
        assertText("Wholemeal wraps")
        assertText("2 packs of 8 wraps for lunch without sesame")
        assertText("Received, waiting for review")
        capture("Contributor-reviewed-own-request-received")
    }
    private func waitForHousehold(timeout: TimeInterval) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let bar = object as? XCUIElement else { return false }
            return bar.exists && bar.isHittable
        }, object: app.navigationBars["Household"])
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: timeout), .completed)
    }
    private func openStructuredReview() {
        tap(element("household.request.capture"))
        fill("2 packs of 8 wraps for lunch without sesame", into: "capture.editor", replacing: true)
        enableSwitch("I checked the wording, amounts, units and exclusions.")
        tap(element("capture.reviewFields"))
        fill("Wholemeal wraps", into: "Item name", replacing: true)
        let packs = element("Number of packs, unknown if blank")
        reveal(packs); XCTAssertEqual(packs.value as? String, "2")
        let perPack = element("Usable amount in each pack, unknown if blank")
        reveal(perPack); XCTAssertEqual(perPack.value as? String, "8")
        enableSwitch("I reviewed this item, amounts, packs, purpose, destination and exclusions, including any unknowns.")
        tap(element("capture.continue"))
        assertText("Original wording")
        assertText("Wholemeal wraps")
        assertText("lunch")
        assertText("sesame")
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control, fullyVisible: true)
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        // A Form can expose both its StaticText label and its input with the
        // same name. Never let a label become the typing target.
        let field = id == "capture.editor" ? app.textViews[id] : app.textFields[id]
        tap(field)
        dismissBilingualKeyboardCardIfPresent()
        tap(field)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
        if replacing, let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            // Tapping a multiline editor does not put the caret at its end.
            // Select the whole value through the real edit menu before replacing it.
            field.press(forDuration: 1.2)
            let labels = ["Select All", "Seleccionar todo"]
            let menuItem = app.menuItems.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            let button = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            let selectAll = menuItem.exists ? menuItem : button
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(selectAll.isHittable)
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            let cleared = field.value as? String
            XCTAssertTrue(cleared == "" || cleared == field.placeholderValue, "The entire input must be cleared: \(cleared ?? "nil")")
        }
        field.typeText(text)
        dismissBilingualKeyboardCardIfPresent()
        XCTAssertEqual(field.value as? String, text, "Typed input must exactly replace the draft before review")
        if id == "capture.editor" {
            dismissCaptureKeyboard()
            XCTAssertEqual(field.value as? String, text, "Dismissing the keyboard must preserve the draft")
        }
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func dismissCaptureKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        // The source TextEditor has no Done action. Use the Form's existing
        // interactive dismissal, starting in its margin outside the editor.
        let bounds = app.frame, area = scrollableArea()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 8, dy: area.minY + area.height * 0.25 - bounds.minY))
        let end = origin.withOffset(CGVector(dx: 8, dy: bounds.height - 30))
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    private func dismissBilingualKeyboardCardIfPresent() {
        let title = app.staticTexts["Type español e inglés"]
        guard title.waitForExistence(timeout: 2) else {
            XCTContext.runActivity(named: "Bilingual keyboard onboarding absent") { _ in }
            return
        }
        // This is the observed iOS keyboard onboarding card, not an arbitrary
        // Continue button or a product consent dialog.
        XCTAssertTrue(app.staticTexts["Type both languages on the same keyboard. Customize in Settings."].exists)
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.exists && next.isHittable)
        XCTContext.runActivity(named: "Dismiss the identified bilingual keyboard onboarding card") { _ in
            capture("Bilingual-keyboard-card-before-dismissal")
            next.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            capture("Bilingual-keyboard-card-dismissed")
        }
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false) {
        for attempt in 0..<24 {
            let area = scrollableArea()
            // A partly visible multiline switch can be hittable while its
            // trailing control is still behind the software keyboard.
            if target.exists && target.isHittable,
               !fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY) { return }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            // A tall accessibility row may fit the viewport but not tolerate
            // another full swipe. Center it with a measured, bounded drag.
            let distance = fullyVisible && target.exists && !target.frame.isEmpty
                ? abs(target.frame.midY - area.midY) : nil
            scrollContent(upward: upward, distance: distance)
        }
        let area = scrollableArea()
        XCTAssertTrue(target.exists && target.isHittable &&
            (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)),
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
    private func scrollContent(upward: Bool, distance: CGFloat? = nil) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = scrollableArea(), bounds = app.frame
        let travel = min(area.height * 0.6, max(20, distance ?? area.height * 0.6))
        let high = area.midY - travel / 2, low = area.midY + travel / 2
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
