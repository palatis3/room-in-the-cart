#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Actual household UI/client against the isolated .invalid fixture; no live account or private stores.
@MainActor final class SharedMealIdeaUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("S26-household-idea-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "S26-household-idea-failure-accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        app.terminate()
    }
    func testAdultFractionalIdeaCancelApproveThenSeparateProposalAndShopperReview() {
        app.launchArguments = ["--ui-testing", "--shared-idea-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(element("fixture.s26.open").waitForExistence(timeout: 25))
        tap(element("fixture.s26.open"))
        tap(app.buttons["Use editable household idea template"])
        fill("Cancelled household idea", into: "Meal name", replacing: true)
        tap(app.navigationBars.buttons.element(boundBy: 0))
        waitCounter("ideas", "Fixture idea writes: 0")
        waitCounter("proposals", "Fixture meal proposals: 0")
        waitCounter("basket", "Fixture basket writes: 0")

        tap(element("fixture.s26.open"))
        tap(app.buttons["Use editable household idea template"])
        fill("Fractional chickpea supper", into: "Meal name", replacing: true)
        // Start with the real editable template, then retain and correct one ingredient.
        tap(app.buttons.matching(identifier: "Remove ingredient").firstMatch)
        // The retained ingredient is above the removed row's scroll position.
        for _ in 0..<3 { scrollContent(upward: false) }
        fill("Chickpeas", into: "Ingredient name", replacing: true)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ingredient unit")).firstMatch)
        tap(app.buttons["Cups"])
        fill("1/2", into: "Required quantity", replacing: true)
        fill("1/4", into: "Household stock in this unit", replacing: true)
        tap(app.buttons["Add named reservation"])
        fill("Protected lunch", into: "Named reservation", replacing: true)
        fill("1/8", into: "Reserved quantity", replacing: true)
        fill("1", into: "Whole package quantity", replacing: true)
        fill("1", into: "Usable yield numerator", replacing: true)
        fill("2", into: "Usable yield denominator", replacing: true)
        fill("Household measured cup and reviewed drained yield", into: "household-idea-evidence", replacing: true)
        XCTAssertEqual(app.textFields["household-idea-evidence"].value as? String, "Household measured cup and reviewed drained yield")
        tap(element("household-idea-save"))
        waitCounter("ideas", "Fixture idea writes: 1")
        assertText("Remaining household stock")
        assertText("1/8"); assertText("3/8")
        assertText("Price unresolved")
        capture("S26-exact-fraction-household-supply-preview")
        enableSwitch("I reviewed these household quantities, exclusions, reservations, and usable packs")
        openAdultApproval()
        tap(element("household-idea-cancel-approval"))
        waitCounter("ideas", "Fixture idea writes: 1")
        waitCounter("proposals", "Fixture meal proposals: 0")
        openAdultApproval()
        tap(app.buttons["Approve meal and quantities"])
        waitCounter("ideas", "Fixture idea writes: 2")
        waitCounter("proposals", "Fixture meal proposals: 0")
        waitCounter("basket", "Fixture basket writes: 0")
        assertText("Approved idea only")
        capture("S26-adult-approved-without-proposal-or-basket-write")

        tap(element("household-idea-propose"))
        assertProposalReady()
        tap(element("household-idea-prepare-proposal"))
        assertText("1/2")
        tap(app.buttons["Cancel proposal review"])
        waitCounter("proposals", "Fixture meal proposals: 0")
        tap(element("household-idea-prepare-proposal"))
        tap(element("household-idea-send-proposal"))
        waitCounter("proposals", "Fixture meal proposals: 1")
        waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-separate-proposal-received-without-basket-write")

        tap(element("fixture.s26.switch"))
        tap(app.buttons["Guest, ingredient, and serving-group proposals"])
        tap(app.buttons["Fractional chickpea supper"])
        assertText("1/2")
        capture("S26-shopper-visible-approved-fractional-proposal")
        tap(element("meal-change-shopper-review"))
        assertText("Entered soup packs")
        tap(app.buttons["Review entered shared shop"])
        assertText("Fractional chickpea supper")
        let publish = app.buttons["Publish reviewed items and quote"]
        reveal(publish); XCTAssertFalse(publish.isEnabled)
        waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-separate-shopper-review-requires-explicit-approval")
        enableSwitch("I reviewed these exact shared fields and this action")
        tap(publish)
        waitCounter("basket", "Fixture basket writes: 1")
        assertText("Shared shop change confirmed")
        assertText("Fixture shared soup")
        assertText("Fractional chickpea supper")
        assertText("1/2 cup")
        waitCounter("ideas", "Fixture idea writes: 2")
        waitCounter("proposals", "Fixture meal proposals: 1")
        waitCounter("basket", "Fixture basket writes: 1")
        capture("S26-shopper-applied-once-original-and-half-cup-meals-retained")
    }
    func testApprovedProposalStaysReadyAfterParentDisappearsAndOnReturn() {
        app.launchArguments = ["--ui-testing", "--shared-idea-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); XCTAssertTrue(element("fixture.s26.open").waitForExistence(timeout: 25))
        tap(element("fixture.s26.open")); tap(app.buttons["Use editable household idea template"])
        fill("Route lifecycle beans", into: "Meal name", replacing: true)
        tap(app.buttons.matching(identifier: "Remove ingredient").firstMatch)
        for _ in 0..<3 { scrollContent(upward: false) }
        fill("250", into: "Household stock in this unit", replacing: true)
        fill("1", into: "Whole package quantity", replacing: true)
        fill("1", into: "Usable yield numerator", replacing: true)
        fill("1", into: "Usable yield denominator", replacing: true)
        fill("Household measured beans and package", into: "household-idea-evidence", replacing: true)
        tap(element("household-idea-save")); waitCounter("ideas", "Fixture idea writes: 1")
        enableSwitch("I reviewed these household quantities, exclusions, reservations, and usable packs")
        openAdultApproval(); tap(app.buttons["Approve meal and quantities"])
        waitCounter("ideas", "Fixture idea writes: 2")
        tap(element("household-idea-propose"))
        assertProposalReady()
        tap(element("household-idea-prepare-proposal"))
        XCTAssertTrue(element("household-idea-send-proposal").waitForExistence(timeout: 10))
        tap(app.buttons["Cancel proposal review"])
        waitCounter("proposals", "Fixture meal proposals: 0"); waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-approved-proposal-enabled-after-parent-disappearance")
        tap(app.navigationBars.buttons.element(boundBy: 0))
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Route lifecycle beans")).firstMatch)
        tap(element("household-idea-propose")); assertProposalReady()
        waitCounter("ideas", "Fixture idea writes: 2")
        waitCounter("proposals", "Fixture meal proposals: 0"); waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-approved-proposal-reopens-after-authorized-parent-refresh")
    }
    private func assertProposalReady() {
        let prepare = element("household-idea-prepare-proposal")
        reveal(prepare, fullyVisible: true)
        XCTAssertTrue(prepare.exists)
        XCTAssertTrue(prepare.isEnabled, "The scoped approved proposal must remain actionable after navigation")
    }
    private func openAdultApproval() {
        let review = element("household-idea-approve")
        reveal(review, fullyVisible: true)
        XCTAssertTrue(review.isEnabled, "The reviewed complete draft must enable adult approval")
        review.tap()
        XCTAssertTrue(app.buttons["Approve meal and quantities"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("household-idea-cancel-approval").waitForExistence(timeout: 5))
    }
    private func waitCounter(_ id: String, _ label: String) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element("fixture.s26." + id))
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 12), .completed)
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
        let field = app.textFields.matching(identifier: id).firstMatch
        tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue {
            if id == "household-idea-evidence", !old.isEmpty {
                // This multiline TextField initially places the caret at the
                // start. Use the observed native edit menu to replace all text.
                field.press(forDuration: 1.2)
                tap(app.menuItems["Select All"])
                app.typeText(XCUIKeyboardKey.delete.rawValue)
            } else { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        }
        app.typeText(text)
        if app.keyboards.firstMatch.exists {
            let done = element("household-idea-keyboard-done")
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            tap(done)
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
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
            scrollContent(upward: upward)
        }
        let area = scrollableArea()
        XCTAssertTrue(target.exists && target.isHittable &&
                      (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)),
                      "Missing fully actionable UI element: \(target.debugDescription)")
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
        let matches = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text))
        if matches.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) { return }
        reveal(matches.firstMatch)
        XCTAssertTrue(matches.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }), "Missing visible text: \(text)")
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
