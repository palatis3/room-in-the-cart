#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Runs the ordinary Settings, household consent and closed-shop feedback views.
/// Only the fixture's .invalid transport is substituted; no production auth bypass.
@MainActor final class MeasurementUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workspace = UUID().uuidString
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("F09-measurement-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "F09-accessibility-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        app.terminate()
    }
    func testLocalSettingsConsentIgnoresLegacyBooleanPersistsRestartAndStaysWorkspaceScoped() {
        launch(reset: true)
        setLocalConsent(false, change: false)
        setLocalConsent(true)
        assertCounter("grants", "Consents: 0"); assertCounter("sends", "Sends: 0")
        capture("F09-local-explicit-choice-no-household-send")
        app.terminate(); launch(reset: false)
        setLocalConsent(true, change: false)
        tap(app.tabBars.buttons["Other workspace"])
        setLocalConsent(false, change: false)
        setLocalConsent(true)
        tap(app.tabBars.buttons["Settings"])
        setLocalConsent(true, change: false)
        setLocalConsent(false)
        app.terminate(); launch(reset: false)
        setLocalConsent(false, change: false)
        tap(app.tabBars.buttons["Other workspace"])
        setLocalConsent(true, change: false)
        assertCounter("grants", "Consents: 0"); assertCounter("sends", "Sends: 0")
        capture("F09-local-scopes-reopened-independently")
    }
    func testAuthenticatedNoticeConsentExplicitClosedShopSendDeleteAndWithdrawal() {
        launch(reset: true)
        setLocalConsent(false, change: false)
        tap(app.buttons["Optional household measurement"])
        assertResultVisible("measurement.consent.result", text: "Household measurement is off")
        assertText("If you choose to participate")
        assertText("Grocery text, prices, member names and existing local responses are not sent")
        assertCounter("grants", "Consents: 0")
        capture("F09-current-optional-notice-before-consent")
        tap(app.buttons["I agree to optional household measurement"])
        waitCounter("grants", "Consents: 1")
        assertResultVisible("measurement.consent.result", text: "Household measurement is enabled")
        assertText("Household measurement is enabled")
        capture("F09-actual-notice-and-explicit-household-consent")
        // Status is freshly fetched through HouseholdService after app recreation;
        // persistence must not send another consent or any previous local response.
        app.terminate()
        app.launchEnvironment["RITC_MEASUREMENT_FAIL_SECOND_STATUS_READ"] = "1"
        launch(reset: false)
        app.launchEnvironment.removeValue(forKey: "RITC_MEASUREMENT_FAIL_SECOND_STATUS_READ")
        tap(app.buttons["Optional household measurement"])
        assertText("Household measurement is enabled")
        tap(app.buttons["Refresh measurement consent"])
        assertText("The service result is unconfirmed.")
        XCTAssertFalse(element("measurement.consent.result").exists)
        XCTAssertFalse(app.buttons["Withdraw household measurement consent"].exists)
        XCTAssertFalse(app.buttons["I agree to optional household measurement"].exists)
        tap(app.buttons["Refresh measurement consent"])
        assertResultVisible("measurement.consent.result", text: "Household measurement is enabled")
        assertCounter("grants", "Consents: 1"); assertCounter("sends", "Sends: 0")
        tap(app.tabBars.buttons["Shared shop"])
        tap(app.buttons["Optional pickup feedback"])
        assertText("Only the choices entered here are sent")
        assertText("2026-W45")
        let send = app.buttons["Send this coded household response"]
        reveal(send); XCTAssertFalse(send.isEnabled)
        choose("What happened?", value: "I found out too late")
        choose("Usual workflow", value: "My usual list or notes")
        choose("Compared with your usual workflow", value: "Different result")
        assertCounter("sends", "Sends: 0")
        capture("F09-three-codes-reviewed-before-explicit-send")
        tap(send)
        waitCounter("sends", "Sends: 1")
        assertResultVisible("measurement.feedback.result", text: "Household response recorded")
        assertText("Household response recorded")
        assertText("I found out too late")
        assertText("This response counts as zero additional benefit")
        capture("F09-late-result-zero-benefit-recorded")
        tap(app.buttons["Remove household response"])
        waitCounter("deletes", "Deletes: 1")
        assertResultVisible("measurement.feedback.result", text: "Household response removed.")
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Household response recorded"])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        for field in ["What happened?", "Usual workflow", "Compared with your usual workflow"] {
            let emptyPicker = app.buttons[field + ", Choose a response"]
            reveal(emptyPicker)
            XCTAssertTrue(emptyPicker.isHittable, field)
        }
        reveal(send)
        XCTAssertFalse(send.isEnabled)
        assertCounter("sends", "Sends: 1")
        tap(app.tabBars.buttons["Settings"])
        tap(app.buttons["Withdraw household measurement consent"])
        waitCounter("withdrawals", "Withdrawals: 1")
        assertResultVisible("measurement.consent.result", text: "Household measurement consent was withdrawn.")
        XCTAssertTrue(app.buttons["I agree to optional household measurement"].waitForExistence(timeout: 10))
        reveal(app.buttons["I agree to optional household measurement"])
        XCTAssertTrue(app.buttons["I agree to optional household measurement"].isHittable)
        tap(app.tabBars.buttons["Shared shop"])
        tap(app.buttons["Refresh household response"])
        reveal(app.buttons["Review optional household measurement"])
        XCTAssertTrue(app.buttons["Review optional household measurement"].isHittable)
        XCTAssertFalse(app.buttons["Send this coded household response"].exists)
        capture("F09-withdrawal-removes-send-authority")
        app.terminate(); launch(reset: false)
        tap(app.buttons["Optional household measurement"])
        reveal(app.buttons["I agree to optional household measurement"])
        XCTAssertTrue(app.buttons["I agree to optional household measurement"].isHittable)
        XCTAssertFalse(app.staticTexts["Household measurement is enabled"].exists)
        assertCounter("grants", "Consents: 1"); assertCounter("sends", "Sends: 1")
        assertCounter("deletes", "Deletes: 1"); assertCounter("withdrawals", "Withdrawals: 1")
        exerciseUnconfirmedFeedbackReplies()
    }
    private func exerciseUnconfirmedFeedbackReplies() {
        app.terminate()
        app.launchEnvironment["RITC_MEASUREMENT_FAIL_FEEDBACK_REPLIES"] = "1"
        launch(reset: true)
        tap(app.buttons["Optional household measurement"])
        tap(app.buttons["I agree to optional household measurement"])
        assertResultVisible("measurement.consent.result", text: "Household measurement is enabled")
        tap(app.tabBars.buttons["Shared shop"])
        tap(app.buttons["Optional pickup feedback"])
        let send = app.buttons["Send this coded household response"]
        let remove = app.buttons["Remove household response"]
        let refresh = app.buttons["Refresh household response"]
        func assertUnread() {
            assertText("The service result is unconfirmed.")
            XCTAssertFalse(send.exists)
            XCTAssertFalse(remove.exists)
            XCTAssertFalse(app.buttons["Review optional household measurement"].exists)
            XCTAssertFalse(app.staticTexts["Household response recorded"].exists)
        }
        choose("What happened?", value: "I already knew")
        choose("Usual workflow", value: "My usual list or notes")
        choose("Compared with your usual workflow", value: "Same result")
        tap(refresh)
        assertUnread()
        tap(refresh)
        reveal(send)
        XCTAssertTrue(send.isEnabled, "Refreshing the same consent should preserve the unsent choices")
        assertCounter("sends", "Sends: 0")
        tap(send)
        waitCounter("sends", "Sends: 1")
        assertUnread()
        tap(refresh)
        assertText("I already knew")
        assertText("This response counts as zero additional benefit")
        assertCounter("sends", "Sends: 1")
        tap(remove)
        waitCounter("deletes", "Deletes: 1")
        assertUnread()
        tap(refresh)
        reveal(send)
        XCTAssertFalse(send.isEnabled)
        XCTAssertFalse(remove.exists)
        assertCounter("sends", "Sends: 1")
        assertCounter("deletes", "Deletes: 1")
    }
    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "--measurement-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RITC_MEASUREMENT_FIXTURE_WORKSPACE"] = workspace
        app.launchEnvironment["RITC_MEASUREMENT_FIXTURE_RESET"] = reset ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 25))
        reveal(app.switches["Offer optional feedback after a pickup"])
    }
    private func setLocalConsent(_ enabled: Bool, change: Bool = true) {
        let control = app.switches["Offer optional feedback after a pickup"]
        reveal(control)
        for _ in 0..<16 {
            let area = scrollableArea(), point = CGPoint(x: control.frame.minX + control.frame.width * 0.92, y: control.frame.midY)
            if control.isHittable && area.insetBy(dx: 0, dy: 8).contains(point) { break }
            scrollContent(upward: point.y > area.maxY)
        }
        if change, control.value as? String != (enabled ? "1" : "0") {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, enabled ? "1" : "0")
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        let option = app.buttons[value]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); tap(option)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func assertCounter(_ key: String, _ text: String) { XCTAssertEqual(element("fixture.measurement." + key).label, text) }
    private func waitCounter(_ key: String, _ text: String) {
        let predicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: element("fixture.measurement." + key))
        XCTAssertEqual(XCTWaiter.wait(for: [predicate], timeout: 10), .completed)
    }
    private func assertResultVisible(_ id: String, text: String) {
        // Do not scroll the test to the result. The successful production action
        // must expose its durable anchor before VoiceOver is routed there.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.snapshotContainsVisibleText(text, identifier: id)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed)
    }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func reveal(_ target: XCUIElement) {
        for attempt in 0..<24 {
            if target.exists && target.isHittable { return }
            let area = scrollableArea()
            let upward = target.exists && !target.frame.isEmpty ? target.frame.midY > area.midY : attempt < 16
            scrollContent(upward: upward)
        }
        XCTAssertTrue(target.exists && target.isHittable, "Missing actionable control: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        let bounds = app.frame
        let barBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame.maxY }.max() ?? bounds.minY + 88
        let top = max(bounds.minY + 88, barBottom + 8), bottom = bounds.maxY - 100
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool) {
        let area = scrollableArea(), bounds = app.frame, origin = app.coordinate(withNormalizedOffset: .zero)
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertText(_ text: String) {
        let matches = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text))
        for attempt in 0..<24 {
            if snapshotContainsVisibleText(text) { return }
            let area = scrollableArea()
            let match = matches.firstMatch
            scrollContent(upward: match.exists && !match.frame.isEmpty ? match.frame.midY > area.midY : attempt < 16)
        }
        XCTFail("Missing visible text: \(text)")
    }
    private func snapshotContainsVisibleText(_ text: String, identifier: String? = nil) -> Bool {
        // One AX snapshot prevents several synchronous frame/label queries from
        // outrunning the result waiter, and keeps viewport and result geometry
        // from different navigation-layout frames from being compared.
        guard let root = try? app.snapshot() else { return false }
        let bounds = root.frame
        var barBottom = bounds.minY + 88
        var nodes = [root]
        var candidates: [CGRect] = []
        while let node = nodes.popLast() {
            let frame = node.frame
            if !frame.isEmpty, frame.intersects(bounds) {
                if node.elementType == .navigationBar { barBottom = max(barBottom, frame.maxY) }
                if node.elementType == .staticText, node.label.contains(text), identifier == nil || node.identifier == identifier {
                    candidates.append(frame)
                }
            }
            nodes.append(contentsOf: node.children)
        }
        let top = max(bounds.minY + 88, barBottom)
        let area = CGRect(x: bounds.minX + 16, y: top, width: bounds.width - 32, height: max(0, bounds.maxY - 100 - top))
        return candidates.contains { $0.intersects(area) }
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
