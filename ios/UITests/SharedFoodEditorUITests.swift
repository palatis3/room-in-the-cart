#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Original editor route against a fixed, rejecting HTTP fixture. This is native
/// interaction/outbox evidence; real-service conservation is qualified separately.
@MainActor final class SharedFoodEditorUITests: XCTestCase {
    private var app: XCUIApplication!
    private let line = "66666666-6666-4666-8666-666666666666"
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
        app.launchEnvironment["RITC_FOOD_EDITOR_WORKSPACE"] = UUID().uuidString
        app.launchEnvironment["RITC_FOOD_EDITOR_RESET"] = "1"
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Shared-food-editor-failure") }
        app.terminate()
    }
    func testExpiredQuoteCancelApplyAndRelaunchRetryPreserveExactFoodAndMoney() { journey(spanish: false) }
    func testSpanishExpiredQuoteCancelApplyAndRelaunchRetryPreserveExactFoodAndMoney() { journey(spanish: true) }

    private func journey(spanish: Bool) {
        checkCalendarSelectorBoundaries()
        let language = spanish ? "es" : "en", locale = spanish ? "es_US" : "en_US"
        app.launchArguments = ["--ui-testing", "--shared-food-editor-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        waitForShop(spanish: spanish)
        counts(previews: 0, posts: 0, writes: 0, retries: 0)
        let targetExpiry = element("fixture.foodEditor.targetExpiry").label
        let originalExpiry = element("fixture.foodEditor.originalExpiry").label
        tap(element("sharedShop.edit"))
        // The expired original must fail before a graph preview or command.
        tap(element("sharedShop.reviewEditor"))
        let notice = element("household.shop.notice")
        reveal(notice)
        XCTAssertTrue(notice.label.contains(spanish ? "vencimiento" : "future quote expiry"), notice.label)
        counts(previews: 0, posts: 0, writes: 0, retries: 0)
        fill("4.25", id: "sharedShop.line." + line + ".price", initialSearchDirection: .towardStart)
        fill("35.00", id: "sharedShop.cost.Cap in USD, blank if unknown")
        chooseExpiry(targetExpiry, originalExpiry: originalExpiry, spanish: spanish)
        capture("Food-editor-\(language)-fresh-quote-entered")
        openFoodReview(spanish: spanish)
        enterCoverage()
        tap(element("sharedFood.preview"))
        assertReviewedFacts(spanish: spanish)
        capture("Food-editor-\(language)-review-before-cancel")
        tap(element("sharedFood.cancel"))
        XCTAssertTrue(element("sharedFood.apply").waitForNonExistence(timeout: 8))
        assertField("sharedShop.line." + line + ".price", value: "4.25", initialSearchDirection: .towardStart)
        assertField("sharedShop.cost.Cap in USD, blank if unknown", value: "35.00")
        counts(previews: 1, posts: 0, writes: 0, retries: 0)
        capture("Food-editor-\(language)-cancel-preserves-outer-draft")

        openFoodReview(spanish: spanish)
        enterCoverage()
        tap(element("sharedFood.preview"))
        assertReviewedFacts(spanish: spanish)
        setSwitch("sharedFood.acknowledged", on: true)
        tap(element("sharedFood.apply"))
        // The fixed server commits once and deliberately loses this reply.
        // Dismissing the finished sheet must not cancel the durable pending action.
        let pending = element("sharedFood.notice")
        XCTAssertTrue(pending.waitForExistence(timeout: 12))
        reveal(pending)
        XCTAssertTrue(pending.label.contains(spanish ? "reintentar" : "retry"), pending.label)
        tap(element("sharedFood.cancel"))
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        reveal(element("sharedShop.retry"))
        capture("Food-editor-\(language)-lost-reply-durable-pending")
        app.terminate()
        app.launchEnvironment["RITC_FOOD_EDITOR_RESET"] = "0"
        app.launch()
        waitForShop(spanish: spanish)
        reveal(element("sharedShop.retry"))
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        tap(element("sharedShop.retry"))
        counts(previews: 2, posts: 2, writes: 1, retries: 1)
        XCTAssertTrue(element("sharedShop.retry").waitForNonExistence(timeout: 12))
        let confirmed = app.staticTexts[spanish ? "Cambio de compra compartida confirmado" : "Shared shop change confirmed"]
        reveal(confirmed)
        XCTAssertTrue(confirmed.isHittable)
        // Read the actual refreshed editor values, then inspect the preserved
        // sources through the original food destination after the exact retry.
        tap(element("sharedShop.edit"))
        assertField("sharedShop.line." + line + ".price", value: "4.25")
        assertField("sharedShop.cost.Cap in USD, blank if unknown", value: "35.00")
        tap(app.buttons[spanish ? "Cancelar edición de la compra compartida" : "Cancel shared shop edit"])
        tap(element("sharedShop.foodQuantities"))
        assertText("Twelve wraps — no salt")
        assertText("Extra wraps — amount unknown")
        counts(previews: 2, posts: 2, writes: 1, retries: 1)
        capture("Food-editor-\(language)-relaunch-exact-retry-preserved-sources")
    }
    private func waitForShop(spanish: Bool) {
        // List rows below the viewport may not exist until scrolled into view.
        // Wait for the loaded destination; tap/reveal owns finding each row.
        XCTAssertTrue(app.navigationBars[spanish ? "Compra compartida del hogar" : "Shared household shop"].waitForExistence(timeout: 25), app.debugDescription)
    }
    private func openFoodReview(spanish: Bool) {
        tap(element("sharedShop.reviewEditor"))
        XCTAssertTrue(app.navigationBars[spanish ? "Cantidades y orígenes" : "Amounts and sources"].waitForExistence(timeout: 15), app.debugDescription)
        assertText("Twelve wraps — no salt")
        assertText("Extra wraps — amount unknown")
    }
    private func enterCoverage() {
        setSwitch("sharedFood.pack." + line + ".unknown", on: false)
        fill("8", id: "sharedFood.pack." + line + ".literal")
        let done = element("sharedFood.done")
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        tap(done)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        setSwitch("sharedFood.line." + line + ".acceptUnresolved", on: true)
    }
    private func assertReviewedFacts(spanish: Bool) {
        let apply = element("sharedFood.apply")
        reveal(apply); XCTAssertFalse(apply.isEnabled)
        assertText("Twelve wraps — no salt", initialSearchDirection: .towardStart)
        assertText("Extra wraps — amount unknown")
        for amount in ["$4.25", "$35.00"] {
            let money = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", amount)).firstMatch
            reveal(money); XCTAssertTrue(money.isHittable, amount)
        }
        let unknown = app.staticTexts[spanish ? "Cantidades o restricciones sin resolver aceptadas para este artículo" : "Unresolved quantities or restrictions accepted for this item"]
        reveal(unknown); XCTAssertTrue(unknown.isHittable)
    }
    private func chooseExpiry(_ value: String, originalExpiry: String, spanish: Bool) {
        let parser = ISO8601DateFormatter()
        guard let target = parser.date(from: value), let original = parser.date(from: originalExpiry) else {
            XCTFail("Invalid fixture expiry evidence"); return
        }
        let picker = app.datePickers["sharedShop.quote.expires"]
        reveal(picker)
        // The existing compact date button belongs to the original expiry's
        // year. The target may be in the next year (December → January).
        let currentYearPattern = FoodEditorCalendarSelection.yearPattern(original, calendar: .current)
        let dateButton = picker.buttons.matching(NSPredicate(format: "label MATCHES %@", currentYearPattern))
        XCTAssertEqual(dateButton.count, 1, picker.debugDescription)
        tap(dateButton.firstMatch)
        let pattern = FoodEditorCalendarSelection.dayPattern(target, spanish: spanish, timeZone: .current)
        let days = app.datePickers.collectionViews.buttons.matching(NSPredicate(format: "label MATCHES %@", pattern))
        if !days.firstMatch.waitForExistence(timeout: 3) || !days.firstMatch.isEnabled {
            // Two calendar days ahead can cross at most one month boundary.
            let next = app.buttons[spanish ? "Mes siguiente" : "Next Month"]
            XCTAssertTrue(next.exists && next.isHittable, "Expected next-month control for " + value)
            next.tap()
        }
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 5), "Expected native calendar date " + value)
        XCTAssertEqual(days.count, 1, "The native date must have exactly one matching calendar cell")
        let day = days.firstMatch
        tap(day)
        if day.exists {
            // The compact calendar can overlap the navigation bar. Use the
            // visible margin beside the actual calendar instead of asking
            // XCTest to scroll an obscured navigation bar into view.
            let calendar = app.datePickers.containing(.button, identifier: "DatePicker.NextMonth").firstMatch
            XCTAssertTrue(calendar.exists)
            let bounds = app.frame, calendarFrame = calendar.frame
            let point = CGPoint(x: bounds.maxX - 12, y: calendarFrame.midY)
            XCTAssertTrue(bounds.contains(point))
            XCTAssertFalse(calendarFrame.insetBy(dx: -8, dy: -8).contains(point), "Expected a clear margin beside the calendar")
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - bounds.minX, dy: point.y - bounds.minY)).tap()
        }
        XCTAssertTrue(day.waitForNonExistence(timeout: 5))
    }
    /// Pure Foundation controls run before either UI journey. They exercise the
    /// actual selector builder without launching an app or changing fixture data.
    private func checkCalendarSelectorBoundaries() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let parser = ISO8601DateFormatter()
        func date(_ iso: String) -> Date { parser.date(from: iso)! }
        func matches(_ pattern: String, _ label: String) -> Bool {
            NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: label)
        }
        let original = date("2026-12-31T00:00:00Z")
        let year = FoodEditorCalendarSelection.yearPattern(original, calendar: calendar)
        XCTAssertTrue(matches(year, "Dec 31, 2026"))
        XCTAssertTrue(matches(year, "31 dic 2026"))
        XCTAssertFalse(matches(year, "Jan 1, 2027"))
        XCTAssertFalse(matches(year, "20260"))
        XCTAssertGreaterThan(date("2027-01-02T00:00:00Z").timeIntervalSince(date("2026-12-31T23:59:59Z")), 86_400)
        let enFirst = FoodEditorCalendarSelection.dayPattern(date("2026-11-01T00:00:00Z"), spanish: false, timeZone: utc)
        XCTAssertTrue(matches(enFirst, "Sunday, November 1"))
        for label in ["November 10", "November 11", "November 12", "November 21"] { XCTAssertFalse(matches(enFirst, label), label) }
        let esFirst = FoodEditorCalendarSelection.dayPattern(date("2026-11-01T00:00:00Z"), spanish: true, timeZone: utc)
        XCTAssertTrue(matches(esFirst, "domingo, 1 de noviembre"))
        for label in ["10 de noviembre", "11 de noviembre", "21 de noviembre"] { XCTAssertFalse(matches(esFirst, label), label) }
        let enTenth = FoodEditorCalendarSelection.dayPattern(date("2026-11-10T00:00:00Z"), spanish: false, timeZone: utc)
        XCTAssertTrue(matches(enTenth, "Tuesday, November 10"))
        XCTAssertFalse(matches(enTenth, "November 1"))
        for (start, end, english, spanish) in [
            ("2026-12-30T00:00:00Z", "2027-01-01T00:00:00Z", "January 1", "1 de enero"),
            ("2026-12-31T00:00:00Z", "2027-01-02T00:00:00Z", "January 2", "2 de enero"),
            ("2027-01-31T00:00:00Z", "2027-02-02T00:00:00Z", "February 2", "2 de febrero"),
            ("2028-02-28T00:00:00Z", "2028-03-01T00:00:00Z", "March 1", "1 de marzo")
        ] {
            let target = date(end)
            XCTAssertEqual(calendar.date(byAdding: .day, value: 2, to: date(start)), target)
            XCTAssertTrue(matches(FoodEditorCalendarSelection.dayPattern(target, spanish: false, timeZone: utc), english))
            XCTAssertTrue(matches(FoodEditorCalendarSelection.dayPattern(target, spanish: true, timeZone: utc), spanish))
        }
    }
    private func counts(previews: Int, posts: Int, writes: Int, retries: Int) {
        let value = "Previews: \(previews); POSTs: \(posts); Writes: \(writes); Exact retries: \(retries)"
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", value), object: element("fixture.foodEditor.counts"))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed)
        XCTAssertFalse(element("fixture.foodEditor.rejected").exists, app.debugDescription)
        XCTAssertFalse(element("fixture.failure").exists, app.debugDescription)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private enum SearchDirection { case towardStart, towardEnd }
    private func tap(_ target: XCUIElement, initialSearchDirection: SearchDirection = .towardEnd) {
        reveal(target, initialSearchDirection: initialSearchDirection)
        XCTAssertTrue(target.isHittable)
        target.tap()
    }
    private func assertText(_ text: String, initialSearchDirection: SearchDirection = .towardEnd) {
        let target = app.staticTexts.matching(identifier: text).firstMatch
        reveal(target, initialSearchDirection: initialSearchDirection)
        XCTAssertTrue(target.isHittable, text)
    }
    private func assertField(_ id: String, value: String, initialSearchDirection: SearchDirection = .towardEnd) {
        let field = app.textFields[id]
        reveal(field, initialSearchDirection: initialSearchDirection)
        XCTAssertEqual(field.value as? String, value)
    }
    private func fill(_ value: String, id: String, initialSearchDirection: SearchDirection = .towardEnd) {
        let field = app.textFields[id]
        tap(field, initialSearchDirection: initialSearchDirection)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        if let old = field.value as? String, old != field.placeholderValue, !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(value); XCTAssertEqual(field.value as? String, value)
    }
    private func setSwitch(_ id: String, on: Bool) {
        let toggle = app.switches[id]; reveal(toggle)
        if toggle.value as? String != (on ? "1" : "0") {
            // SwiftUI includes the label in this frame; operate the trailing switch.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", id)
    }
    private func reveal(_ target: XCUIElement, initialSearchDirection: SearchDirection = .towardEnd) {
        let startsBySwipingUp = initialSearchDirection == .towardEnd
        for attempt in 0..<30 {
            let area = scrollableArea(), exists = target.exists
            let frame = exists ? target.frame : .zero
            if exists && target.isHittable && !frame.isEmpty && frame.minY >= area.minY && frame.maxY <= area.maxY { return }
            // Toolbars lie outside the content viewport, but their complete
            // button frame still has to fit the app and be directly actionable.
            if exists && target.isHittable && app.frame.contains(frame) && target.elementType == .button && (target.identifier == "sharedFood.cancel" || target.identifier == "sharedFood.done") { return }
            let fallbackUpward = (attempt / 6) % 2 == 0 ? startsBySwipingUp : !startsBySwipingUp
            let upward = exists && !frame.isEmpty ? frame.midY > area.midY : fallbackUpward
            let origin = app.coordinate(withNormalizedOffset: .zero), bounds = app.frame
            let high = area.minY + area.height * 0.18, low = area.minY + area.height * 0.82
            origin.withOffset(CGVector(dx: area.minX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: area.minX - bounds.minX, dy: (upward ? high : low) - bounds.minY)))
        }
        XCTFail("Missing fully visible control: " + target.debugDescription)
    }
    private func scrollableArea() -> CGRect {
        let snapshot = try? app.snapshot(), bounds = snapshot?.frame ?? app.frame
        var bottom = bounds.maxY - 30, top = bounds.minY + 95, nodes = snapshot.map { [$0] } ?? []
        while let node = nodes.popLast() {
            if !node.frame.isEmpty && node.frame.intersects(bounds) {
                if node.elementType == .navigationBar { top = max(top, node.frame.maxY + 8) }
                if node.elementType == .keyboard { bottom = min(bottom, node.frame.minY - 12) }
                if node.identifier == "sharedFood.done" { bottom = min(bottom, node.frame.minY - 8) }
            }
            nodes.append(contentsOf: node.children)
        }
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
private enum FoodEditorCalendarSelection {
    static func yearPattern(_ original: Date, calendar: Calendar) -> String {
        bounded(String(calendar.component(.year, from: original)))
    }
    static func dayPattern(_ target: Date, spanish: Bool, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: spanish ? "es_US" : "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = spanish ? "d 'de' MMMM" : "MMMM d"
        return bounded(formatter.string(from: target))
    }
    private static func bounded(_ value: String) -> String {
        // Native labels can include weekday, year or selected-state wording.
        // Preserve that flexibility while excluding neighboring day numbers.
        "(?i).*(?<![0-9A-Za-z])" + NSRegularExpression.escapedPattern(for: value) + "(?![0-9A-Za-z]).*"
    }
}
#endif
