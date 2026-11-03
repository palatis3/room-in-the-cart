#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Isolated fixture target only. Normal full-suite builds contain no shared-meal fixture tests.
@MainActor final class SharedMealChangeUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("S17-shared-meal-failure") }
        app.terminate()
    }
    private func launch(shopperSeed: Bool = false) {
        app.launchArguments = ["--ui-testing", "--shared-meal-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (shopperSeed ? ["--shopper-meal-seed"] : [])
        app.launch()
        XCTAssertTrue(element("meal-change-occurrence").waitForExistence(timeout: 25))
    }
    private func chooseOccurrence() {
        tap(element("meal-change-occurrence"))
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture shared soup")).firstMatch)
    }
    private func proposalFromShopper() {
        if !app.buttons["Guest, ingredient, and serving-group proposals"].isHittable {
            tap(app.navigationBars.buttons.element(boundBy: 0))
        }
        tap(app.buttons["Guest, ingredient, and serving-group proposals"])
        tap(app.buttons["Fixture guest soup"])
        tap(element("meal-change-shopper-review"))
    }
    private func approveSharedDraft() {
        assertText("Entered soup packs")
        tap(app.buttons["Review entered shared shop"])
        let apply = app.buttons["Publish reviewed items and quote"]
        reveal(apply); XCTAssertFalse(apply.isEnabled)
        assertText("Fixture guest soup")
        capture("S17-actual-shared-pack-and-checkout-review")
        enableSwitch("I reviewed these exact shared fields and this action")
        tap(apply)
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Fixture shared applications: 1"), object: element("fixture.s17.applications"))
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 10), .completed)
        capture("S17-actual-shared-apply-confirmed-once")
    }
    func testPlannerCancelThenSendAndSeparateShopperCancelThenApplyExactlyOnce() {
        launch(); chooseOccurrence()
        fill("Two guests; reviewed local ingredients", into: "meal-change-reason", replacing: true)
        tap(element("meal-change-prepare"))
        assertText("Fixture guest soup")
        capture("S17-planner-original-and-proposed-review")
        tap(app.buttons["Cancel proposal review"])
        XCTAssertEqual(element("fixture.s17.proposals").label, "Fixture shared proposals: 0")
        XCTAssertEqual(element("fixture.s17.applications").label, "Fixture shared applications: 0")
        tap(element("meal-change-prepare")); tap(element("meal-change-send"))
        let received = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Fixture shared proposals: 1"), object: element("fixture.s17.proposals"))
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 10), .completed)
        XCTAssertEqual(element("fixture.s17.applications").label, "Fixture shared applications: 0")
        capture("S17-proposal-received-without-basket-write")
        tap(element("fixture.s17.switch")); proposalFromShopper()
        tap(app.buttons["Cancel shared shop edit"])
        XCTAssertEqual(element("fixture.s17.applications").label, "Fixture shared applications: 0")
        proposalFromShopper(); approveSharedDraft()
        XCTAssertEqual(element("fixture.s17.proposals").label, "Fixture shared proposals: 1")
    }
    func testAssignedShopperMapsLocalSeedWithoutPlannerPostAndCanCancel() {
        launch(shopperSeed: true); chooseOccurrence()
        tap(element("meal-change-shopper-seed"))
        assertText("Fixture guest soup"); tap(app.buttons["Cancel shared shop edit"])
        XCTAssertEqual(element("fixture.s17.proposals").label, "Fixture shared proposals: 0")
        XCTAssertEqual(element("fixture.s17.applications").label, "Fixture shared applications: 0")
        tap(element("fixture.s17.seed")); chooseOccurrence(); tap(element("meal-change-shopper-seed"))
        approveSharedDraft()
        XCTAssertEqual(element("fixture.s17.proposals").label, "Fixture shared proposals: 0")
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
