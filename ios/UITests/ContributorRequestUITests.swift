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
    func testTypedAndStructuredReviewCancelThenSendOnlyOwnRequest() throws {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(element("household.request.review").waitForExistence(timeout: 20))
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
        reveal(approval)
        approval.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(approval.value as? String, "1")
        tap(element("household.request.sendReviewed"))
        XCTAssertTrue(element("household.request.review").waitForExistence(timeout: 10))
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 1")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 1")
        assertText("Wholemeal wraps")
        assertText("2 packs of 8 wraps for lunch without sesame")
        assertText("Received, waiting for review")
        capture("Contributor-reviewed-own-request-received")
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
