#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Isolated fixture target only. Normal full-suite builds contain no shared-meal fixture tests.
/// Shopper Apply starts with one explicitly tracked, unknown-quantity manual
/// soup item. These journeys cover proposal editing, not initial adoption.
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
    private func launch(shopperSeed: Bool = false, deadline: Bool = false, ingredientRemoval: Bool = false) {
        app.launchArguments = ["--ui-testing", "--shared-meal-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (shopperSeed ? ["--shopper-meal-seed"] : []) + (deadline ? ["--shared-meal-deadline-fixture"] : [])
        if ingredientRemoval { app.launchArguments += ["--shared-meal-group-amount-fixture", "--shared-meal-removal-fixture"] }
        app.launch()
        let ready = deadline ? app.navigationBars["Shared household shop"] : app.buttons["meal-change-occurrence"]
        XCTAssertTrue(ready.waitForExistence(timeout: 25))
    }
    private func chooseOccurrence() {
        tap(app.buttons["meal-change-occurrence"])
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
    private func openFoodReview() {
        tap(app.buttons["Review entered shared shop"])
        XCTAssertTrue(app.buttons["sharedFood.cancel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Amounts and sources"].exists)
    }
    private func reviewFoodAmounts() {
        enableSwitch("I reviewed the changed meal and all retained food commitments")
        enableSwitch("I accept unresolved quantities or restrictions for this item")
        tap(app.buttons["sharedFood.preview"])
        reveal(app.buttons["sharedFood.apply"]); XCTAssertFalse(app.buttons["sharedFood.apply"].isEnabled)
    }
    private func approveSharedDraft() {
        assertText("Entered soup packs")
        openFoodReview()
        assertText("Fixture guest soup")
        reviewFoodAmounts()
        assertText("Entered soup packs")
        assertText("Unresolved quantities or restrictions accepted for this item")
        capture("S17-actual-shared-pack-and-checkout-review")
        acknowledgeFoodReview()
        tap(app.buttons["sharedFood.apply"])
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Fixture shared applications: 1"), object: element("fixture.s17.applications"))
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["sharedFood.apply"].waitForNonExistence(timeout: 10))
        capture("S17-actual-shared-apply-confirmed-once")
    }
    func testPlannerCancelThenSendAndSeparateShopperCancelThenApplyExactlyOnce() {
        launch(); chooseOccurrence()
        enterReasonAndPrepare("Two guests; reviewed local ingredients")
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
        let enteredMeal = app.textFields["Meal name"]
        reveal(enteredMeal); XCTAssertEqual(enteredMeal.value as? String, "Fixture guest soup")
        tap(app.buttons["Cancel shared shop edit"])
        XCTAssertEqual(element("fixture.s17.proposals").label, "Fixture shared proposals: 0")
        XCTAssertEqual(element("fixture.s17.applications").label, "Fixture shared applications: 0")
        tap(element("fixture.s17.seed")); chooseOccurrence(); tap(element("meal-change-shopper-seed"))
        approveSharedDraft()
        XCTAssertEqual(element("fixture.s17.proposals").label, "Fixture shared proposals: 0")
    }
    func testRemovingBoundSideReachesProposalReviewAndCancelMakesNoSharedWrite() {
        launch(ingredientRemoval: true); chooseOccurrence()
        tap(app.buttons["Tomato side"])
        tap(app.buttons["Remove proposed ingredient"])
        XCTAssertFalse(app.buttons["Tomato side"].exists)
        enterReasonAndPrepare("Remove only the tomato side; keep the protected lunch")
        reveal(app.buttons["meal-change-send"])
        XCTAssertTrue(app.buttons["meal-change-send"].isEnabled)
        capture("S17-bound-side-removed-review-keeps-other-allocations")
        tap(app.buttons["Cancel proposal review"])
        XCTAssertEqual(element("fixture.s17.proposals").label, "Fixture shared proposals: 0")
        XCTAssertEqual(element("fixture.s17.applications").label, "Fixture shared applications: 0")
        tap(app.buttons["Lunch"])
        tap(app.buttons["Refresh shared changes"])
        chooseOccurrence()
        let restoredSide = app.buttons["Tomato side"]
        reveal(restoredSide, fullyVisible: true)
        XCTAssertTrue(restoredSide.isHittable)
        capture("S17-cancelled-side-removal-original-draft-reopened")
    }
    func testShopperReviewsRepeatedClockTimeThenMovesDayWithoutExtendingDeadline() {
        launch(deadline: true)
        tap(app.buttons["Edit shared items and quote"])
        tap(app.buttons["Edit this meal"])
        tap(element("sharedMeal.editDeadline"))
        let preview = element("sharedMeal.deadlinePreview")
        assertElementContains("sharedMeal.deadlinePreview", "November 1, 2026")
        XCTAssertTrue(preview.label.contains("1:30"))
        XCTAssertTrue(preview.label.contains("America/New_York (UTC−04:00)"))
        tap(element("sharedMeal.deadlineZone"))
        XCTAssertTrue(app.navigationBars["Scheduled time zone"].waitForExistence(timeout: 8))
        let zoneSearch = app.searchFields.firstMatch
        if !zoneSearch.exists { app.swipeDown() }
        tap(zoneSearch)
        zoneSearch.typeText("America/New_York")
        tap(app.buttons["America/New_York"])
        assertElementContains("sharedMeal.deadlinePreview", "America/New_York (UTC−04:00)")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeated clock time")).firstMatch)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UTC−05:00")).firstMatch)
        assertElementContains("sharedMeal.deadlinePreview", "1:30")
        XCTAssertTrue(preview.label.contains("America/New_York (UTC−05:00)"))
        tap(element("sharedMeal.useDeadline"))
        openFoodReview()
        assertText("Before"); assertText("After")
        assertDeadline(contains: "America/New_York (UTC−04:00)")
        assertDeadline(contains: "America/New_York (UTC−05:00)")
        reviewFoodAmounts()
        assertDeadline(contains: "America/New_York (UTC−04:00)")
        assertDeadline(contains: "America/New_York (UTC−05:00)")
        acknowledgeFoodReview()
        tap(app.buttons["sharedFood.apply"])
        let count = element("fixture.s17.applications")
        let published = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Fixture shared applications: 1"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["sharedFood.apply"].waitForNonExistence(timeout: 10))

        tap(app.buttons["Edit shared items and quote"])
        tap(app.buttons["Edit this meal"])
        let picker = element("sharedMeal.day")
        tap(picker)
        XCTAssertEqual(element("sharedMeal.dayPreview").label, "November 1, 2026")
        let nextDay = element("sharedMeal.dayCalendar").collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", "November 2")).firstMatch
        XCTAssertTrue(nextDay.waitForExistence(timeout: 5))
        tap(nextDay)
        XCTAssertEqual(element("sharedMeal.dayPreview").label, "November 2, 2026")
        tap(element("sharedMeal.cancelDay"))
        XCTAssertEqual(picker.value as? String, "November 1, 2026")
        assertText("America/New_York (UTC−05:00)")
        tap(picker)
        // Confirming the unchanged date must also preserve the reviewed deadline.
        tap(element("sharedMeal.useDay"))
        assertText("America/New_York (UTC−05:00)")
        tap(picker)
        tap(nextDay)
        tap(element("sharedMeal.useDay"))
        XCTAssertTrue(element("sharedMeal.dayCalendar").waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "November 2, 2026")
        assertText("The new day has no deadline until you set one.")
        openFoodReview()
        assertText("Before"); assertText("After")
        assertDeadline(contains: "America/New_York (UTC−05:00)")
        assertText("November 2, 2026")
        assertDeadline(contains: "Unknown")
        reviewFoodAmounts()
        assertDeadline(contains: "America/New_York (UTC−05:00)")
        assertDeadline(contains: "Unknown")
        XCTAssertEqual(count.label, "Fixture shared applications: 1")
        capture("S09-shopper-reviewed-day-move-without-deadline")
    }

    private func assertDeadline(contains expected: String) {
        // The editor behind the sheet also exposes deadline facts. Limit the
        // lookup to the form containing this review's Before and After values.
        // Reviewing packs ends at the bottom; the lazy section header must be
        // visible again before it can identify the review's collection.
        reveal(app.staticTexts["Reviewed meal change"], fullyVisible: true, searchTowardEndFirst: false)
        let forms = app.collectionViews.containing(.staticText, identifier: "Reviewed meal change")
        XCTAssertEqual(forms.count, 1, "The active meal review must have one form")
        let row = forms.firstMatch.staticTexts.matching(identifier: "sharedMeal.deadlineFact")
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected)).firstMatch
        reveal(row, fullyVisible: true, searchTowardEndFirst: false)
        XCTAssertTrue((row.label + " " + (row.value as? String ?? "")).contains(expected), row.debugDescription)
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
    private func acknowledgeFoodReview() {
        let id = "sharedFood.acknowledged"
        let control = app.switches[id]
        reveal(control, fullyVisible: true)
        XCTAssertEqual(control.value as? String, "0")
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        // The hosted failure's hierarchy already showed value 1 while XCTest
        // repeatedly stalled resolving the live switch after the tap. Read
        // its stable identifier from a fresh tree, keeping the state assertion.
        func value() -> String? {
            guard let snapshot = try? app.snapshot() else { return nil }
            var nodes = [snapshot]
            while let node = nodes.popLast() {
                if node.elementType == .switch && node.identifier == id {
                    return node.value as? String
                }
                nodes.append(contentsOf: node.children)
            }
            return nil
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in value() == "1" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertEqual(value(), "1", "The reviewed switch must be on")
    }
    private func enterReasonAndPrepare(_ reason: String) {
        let field = element("meal-change-reason")
        tap(field)
        field.typeText(reason)
        XCTAssertEqual(field.value as? String, reason)
        let review = app.buttons["meal-change-prepare"]
        reveal(review, fullyVisible: true)
        review.tap()
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false, searchTowardEndFirst: Bool = true) {
        for attempt in 0..<24 {
            let area = scrollableArea()
            if target.exists && target.isHittable,
               !fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY) { return }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 ? searchTowardEndFirst : !searchTowardEndFirst }
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
