import XCTest

/// Ordinary visible Shop navigation on the isolated UI-test workspace.
@MainActor final class ContextualReminderUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Contextual-reminder-failure") }
        app.terminate()
    }

    func testNextShopDeferralRequestsReminderOnlyAfterExplicitScheduleAndCanCancel() throws {
        launch(reset: true)
        tap(element("openPickupList"))
        tap(element("ledgerImport")); fill("1 coffee\n2 wraps", into: app.textViews["ledgerImportText"])
        tap(app.buttons["ledgerReviewImport"]); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"]); tap(app.buttons["Apply reviewed checkout copy"])
        tap(app.buttons["Review whole checkout"])
        fill("Family market", into: app.textFields["Store"], replacing: true)
        fill("Main branch", into: app.textFields["Branch"], replacing: true)
        fill("Tuesday 5 PM", into: app.textFields["Pickup or delivery slot"], replacing: true)
        fill("Retailer preview", into: app.textFields["Source of these prices"], replacing: true)
        fill("4.00", into: app.textFields["coffee"]); fill("3.00", into: app.textFields["wraps"])
        for label in ["Fee below threshold or fixed fee", "Eligible discount", "Tax", "Deposits and other charges"] { fill("0", into: app.textFields[label]) }
        tap(app.buttons["Save and evaluate checkout"])
        enableSwitch("coffee"); enableSwitch("Include in deferral preview")
        tap(app.buttons["Preview deferrals together"]); tap(app.buttons["Apply reviewed deferral"])
        back(to: "Start the next shop"); tap(app.buttons["Start the next shop"])
        tap(app.buttons["Request a reminder for this deferral"])
        XCTAssertEqual(element("reminder.subject").label, "coffee")
        assertText("Pickup last saved")
        assertText("Opening or reviewing this reminder does not schedule a notification.")
        XCTAssertFalse(element("reminder.schedule").exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let expiryPicker = app.datePickers["reminder.expiry"]
        let chosenExpiry = try chooseFutureDay(in: expiryPicker, navigationTitle: "Reminder")
        let expiryDay = DateFormatter()
        expiryDay.locale = Locale(identifier: "en_US")
        expiryDay.dateStyle = .full
        let savedDay = expiryDay.string(from: chosenExpiry)
        enableSwitch("reminder.expiry.confirm"); tap(element("reminder.openEditor"))
        assertElementContains("reminder.status", "Nothing is scheduled")
        for id in ["reminder.quietStart", "reminder.quietEnd"] {
            let picker = app.datePickers[id]
            reveal(picker)
            XCTAssertTrue(picker.isHittable)
        }
        let quiet = element("reminder.quietHours"); reveal(quiet)
        if quiet.value as? String == "1" { quiet.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        tap(element("reminder.review"))
        assertText("Nothing is scheduled until you confirm")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("S12-deferral-reminder-reviewed-unscheduled")
        tap(element("reminder.schedule"))
        assertElementContains("reminder.status", "Reminder not scheduled. Notifications are off")
        tap(element("reminder.close"))
        tap(app.buttons["Request a reminder for this deferral"])
        reveal(expiryPicker)
        XCTAssertFalse(element("reminder.openEditor").isEnabled)
        enableSwitch("reminder.expiry.confirm"); tap(element("reminder.openEditor"))
        assertText(savedDay)
        tap(element("reminder.turnOff"))
        assertElementContains("reminder.status", "Nothing is scheduled")
        tap(element("reminder.close"))
        XCTAssertTrue(app.navigationBars["Next shop"].waitForExistence(timeout: 8))
        choose("For this trip", value: "Already handled · no new purchase")
        XCTAssertFalse(app.buttons["Request a reminder for this deferral"].exists)
        tap(app.buttons["Cancel"])
        tap(app.buttons["Start the next shop"])
        reveal(app.buttons["Request a reminder for this deferral"])
        capture("S12-reminder-off-and-cancel-keeps-deferral")
        tap(app.buttons["Cancel"])
    }

    func testSavedOfferRequestsDeadlineReminderFromThatOfferAndCancelKeepsDecisionPending() throws {
        launch(reset: true)
        tap(element("openPickupList"))
        tap(element("ledgerImport")); fill("2 wraps", into: app.textViews["ledgerImportText"])
        tap(app.buttons["ledgerReviewImport"]); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"]); tap(app.buttons["Apply reviewed checkout copy"])
        tap(app.buttons["Review whole checkout"])
        // These adjacent checkout fields share one keyboard session.
        for (label, value) in [("Store", "Family market"), ("Branch", "Main branch"),
                               ("Pickup or delivery slot", "Tuesday 5 PM"), ("Source of these prices", "Retailer preview")] {
            let field = app.textFields[label]
            tap(field)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            if let old = field.value as? String, old != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            field.typeText(value)
            XCTAssertEqual(field.value as? String, value, label)
        }
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3) && done.isHittable)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        enableSwitch("Retailer total already includes all charges")
        let total = app.textFields["Inclusive total"]
        fill("3.00", into: total)
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: "Done"))
        XCTAssertEqual(try total.snapshot().value as? String, "3.00")
        tap(app.buttons["Save and evaluate checkout"])
        assertText("Saved checkout result")
        back(to: "Prepare retailer handoff"); tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["Freeze reviewed basket"]); tap(app.buttons["I placed this order"])
        back(to: "Review a store offer"); tap(app.buttons["Review a store offer"])
        tap(element("pickup.offer.new")); choose("Original line", value: "wraps")
        fill("Large wrap pack", into: app.textFields["pickup.offer.replacement"])
        fill("2", into: app.textFields["pickup.offer.required"]); fill("0", into: app.textFields["pickup.offer.remaining"])
        fill("4.00", into: app.textFields["pickup.offer.price"])
        let forecast = element("pickup.offer.forecast.enabled"); reveal(forecast)
        if forecast.value as? String == "1" { forecast.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        let chosenCutoffDay = try chooseFutureDay(in: app.datePickers["pickup.offer.cutoff"], navigationTitle: "New store offer")
        tap(element("pickup.offer.review")); enableSwitch("pickup.offer.approve"); tap(element("pickup.offer.save"))
        tap(app.buttons["Request an offer deadline reminder"])
        XCTAssertEqual(element("reminder.subject").label, "Large wrap pack")
        assertText("Offer cutoff")
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US")
        date.calendar = Calendar(identifier: .gregorian)
        date.timeZone = .current
        date.dateStyle = .full
        // This is the saved offer's cutoff in the actual reminder context,
        // not merely the date that happened to be visible in the popover.
        reveal(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", date.string(from: chosenCutoffDay))).firstMatch)
        XCTAssertGreaterThan(chosenCutoffDay, Date())
        tap(element("reminder.openEditor"))
        assertElementContains("reminder.status", "Nothing is scheduled")
        XCTAssertTrue(element("reminder.time").exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("S07-offer-deadline-reminder-unscheduled")
        tap(element("reminder.close"))
        XCTAssertTrue(app.navigationBars["Review store offer"].waitForExistence(timeout: 8))
        assertText("Retailer response: Pending")
        reveal(app.buttons["Request an offer deadline reminder"])
        capture("S07-cancel-reminder-keeps-pending-store-offer")
    }

    private func chooseFutureDay(in picker: XCUIElement, navigationTitle: String) throws -> Date {
        reveal(picker)
        // Compact native date controls expose the date and time as separate buttons.
        let dateButton = picker.buttons.firstMatch
        XCTAssertTrue(dateButton.exists, app.debugDescription)
        dateButton.tap()
        let monthHeader = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "DatePicker.Show", "Month")).firstMatch
        XCTAssertTrue(monthHeader.waitForExistence(timeout: 8), app.debugDescription)
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.calendar = Calendar(identifier: .gregorian)
        month.timeZone = .current
        month.dateFormat = "MMMM yyyy"
        let displayedMonth = try XCTUnwrap(monthHeader.value as? String)
        let displayedDate = try XCTUnwrap(month.date(from: displayedMonth), displayedMonth)
        let calendar = month.calendar!
        let start = try XCTUnwrap(calendar.dateInterval(of: .month, for: displayedDate)?.start)
        let nextMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: start))
        // Mid-month stays safely future even if this journey spans midnight
        // on the last day of the current month. Calendar handles year rollover.
        let target = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: nextMonth))
        XCTAssertGreaterThan(target, Date())
        let next = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", "Next Month", "NextMonth")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), app.debugDescription)
        next.tap()
        let spoken = DateFormatter()
        spoken.locale = Locale(identifier: "en_US")
        spoken.calendar = calendar
        spoken.timeZone = .current
        spoken.dateFormat = "EEEE, MMMM d"
        // The Month header's accessibility value is not a reliable completion
        // signal on every runtime. Wait for the exact actionable date instead;
        // the caller also verifies the saved cutoff in the
        // reminder context after the offer is committed.
        let days = app.buttons.matching(NSPredicate(format: "label == %@", spoken.string(from: target)))
        let day = days.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        XCTAssertEqual(days.count, 1)
        day.tap()
        app.navigationBars[navigationTitle].tap()
        // Dismissing the calendar can restore the prior text field's keyboard
        // and scroll the compact picker out of the lazy Form hierarchy.
        reveal(picker)
        let evidence = XCTAttachment(string: "Target day: \(spoken.string(from: target)); target month: \(month.string(from: nextMonth))\nCompact date label: \(dateButton.label)\nCompact date value: \(String(describing: dateButton.value))\nPicker value: \(String(describing: picker.value))")
        evidence.name = "\(picker.identifier)-future-date-selection"; evidence.lifetime = .keepAlways; add(evidence)
        return target
    }

    private func launch(reset: Bool) {
        // Xcode's newer snapshot instrumentation floods iOS 17 unified logging
        // and crashes inside its logging-quarantine callback. Preserve XCTest
        // action/assertion logs while suppressing this app-process log transport.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 {
            app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        }
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(element("newComparison").waitForExistence(timeout: 15))
    }
    private func restart() { app.terminate(); launch(reset: false) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control)
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        reveal(control)
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func fill(_ text: String, into field: XCUIElement, replacing: Bool = false) {
        tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func reveal(_ target: XCUIElement, requiresHitTarget: Bool = true) {
        for attempt in 0..<64 {
            let area = scrollableArea()
            if target.exists && (!requiresHitTarget || target.isHittable) {
                let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
                // Native Form rows can be partially tappable while their center
                // lies underneath the tab bar. Scroll the actual touch point into
                // the visible content before tapping a row or its trailing switch.
                if touchableArea().contains(center) { return }
                if ["Cancel", "Done"].contains(target.label) { return }
            }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 32 }
            scrollContent(upward: upward)
        }
        let area = touchableArea()
        XCTAssertTrue(target.exists && (!requiresHitTarget || target.isHittable) && area.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)),
            "Missing a visible touch point in \(area) for UI element: \(target.debugDescription)")
    }
    private func touchableArea() -> CGRect {
        let viewport = viewportBoundaries()
        return CGRect(x: viewport.bounds.minX, y: viewport.navigationBottom, width: viewport.bounds.width,
                      height: max(0, min(viewport.keyboardTop, viewport.tabTop) - 4 - viewport.navigationBottom))
    }
    private func scrollableArea() -> CGRect {
        let viewport = viewportBoundaries()
        let top = max(viewport.bounds.minY + 88, min(viewport.navigationBottom + 12, viewport.keyboardTop - 140))
        let bottom = min(viewport.bounds.maxY - 100, viewport.keyboardTop - 16)
        return CGRect(x: viewport.bounds.minX + 24, y: top, width: viewport.bounds.width - 48, height: max(80, bottom - top))
    }
    private func viewportBoundaries() -> (bounds: CGRect, navigationBottom: CGFloat, keyboardTop: CGFloat, tabTop: CGFloat) {
        // A sheet transition can remove a bar between separate accessibility queries.
        let snapshot = try? app.snapshot()
        let bounds = snapshot?.frame ?? app.frame
        var navigationBottom = bounds.minY + 88
        var keyboardTop = bounds.maxY
        var tabTop = bounds.maxY
        var elements = snapshot.map { [$0] } ?? []
        while let element = elements.popLast() {
            elements.append(contentsOf: element.children)
            let frame = element.frame
            guard !frame.isEmpty, frame.intersects(bounds) else { continue }
            switch element.elementType {
            case .navigationBar: navigationBottom = max(navigationBottom, frame.maxY)
            case .keyboard: keyboardTop = min(keyboardTop, frame.minY)
            case .tabBar: tabTop = min(tabTop, frame.minY)
            default: break
            }
        }
        return (bounds, navigationBottom, keyboardTop, tabTop)
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
        // Passive labels need to be rendered inside the visible viewport. They
        // do not need to receive a tap; all action helpers still require hittability.
        reveal(target, requiresHitTarget: false); XCTAssertTrue(target.exists, "Missing visible text: \(text)")
    }
    private func assertElementContains(_ id: String, _ text: String) {
        let target = element(id); reveal(target, requiresHitTarget: false); XCTAssertTrue(target.label.contains(text), target.label)
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        tap(app.buttons[value])
    }
    private func dinnerRoot() { returnToVisibleAnchor(element("dinnerLibrary")) }
    private func shopRoot() {
        app.tabBars.buttons["Shop"].tap()
        returnToVisibleAnchor(element("newComparison"))
    }
    private func back(to label: String) {
        returnToVisibleAnchor(app.buttons.matching(identifier: label).firstMatch)
    }
    private func returnToVisibleAnchor(_ target: XCUIElement) {
        for _ in 0..<8 {
            if target.exists {
                // A covered parent can still exist in the accessibility tree.
                // Scroll only to reveal it, and return only if it is actionable.
                for _ in 0..<2 {
                    if target.isHittable { return }
                    scrollContent(upward: true)
                }
                for _ in 0..<4 {
                    if target.isHittable { return }
                    scrollContent(upward: false)
                }
                if target.isHittable { return }
            }
            let leading = app.navigationBars.buttons.allElementsBoundByAccessibilityElement.filter {
                $0.exists && $0.isHittable && $0.identifier != "settings" && $0.frame.midX < app.frame.midX
            }.sorted { $0.frame.minX < $1.frame.minX }
            guard let button = leading.first else {
                XCTFail("No visible back control while returning to \(target)")
                return
            }
            button.tap()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Root or destination is not visible: \(target)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
