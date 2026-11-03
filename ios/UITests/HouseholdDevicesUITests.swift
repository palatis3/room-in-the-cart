#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class HouseholdDevicesUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    private let current = "30000000-0000-4000-8000-000000000004"
    private let target = "30000000-0000-4000-8000-000000000005"
    private let sibling = "30000000-0000-4000-8000-000000000006"
    private var capturingIssue = false
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        capture((testRun?.failureCount ?? 0) > 0 ? "S21-device-failure-before-termination" : "S21-device-completed")
        app.terminate()
    }
    override func record(_ issue: XCTIssue) {
        if !capturingIssue {
            capturingIssue = true
            capture("S21-device-issue-\(issue.type.rawValue)")
            capturingIssue = false
        }
        super.record(issue)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func launch(spanish: Bool = false) {
        // iOS 17 XCTest snapshot logging crashed in its log-quarantine callback
        // in the retained unmuted FinalDevices baseline. This applies only to
        // the fixture app process; runner actions/assertions and crash reports
        // remain available. This run cannot establish absence of runtime warnings.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["--ui-testing", "--household-devices-fixture", "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_US" : "en_US"]
        if spanish { app.launchArguments.append("--device-fixture-largest-text") }
        app.launch()
        // This fixture-owned footer is outside the lazy Form. At the largest
        // text size, Refresh and the first enrollment are initially unmaterialized.
        XCTAssertTrue(element("household.devices.fixtureSummary").waitForExistence(timeout: 15))
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10), "The household device Form must be mounted")
        XCTAssertTrue(form.cells.firstMatch.waitForExistence(timeout: 5), "The mounted Form must contain its initial content")
        reveal("household.devices.refresh")
        reveal("household.devices.alias.\(current)")
        XCTAssertEqual(element("household.devices.alias.\(current)").label, "Mia")
        capture(spanish ? "S21-Spanish-largest-text-launched" : "S21-English-launched")
    }
    private func reveal(_ id: String) { reveal(element(id), named: id) }
    private func reveal(_ value: XCUIElement, named id: String) {
        var forward = true, reversed = false, previousSignature = "", unmoved = 0
        for attempt in 0..<48 {
            guard let container = activeScrollableContent() else {
                capture("S21-no-active-scroll-container"); XCTFail("No active Form collection while revealing \(id)"); return
            }
            let area = unobscuredArea(in: container)
            guard area.height >= 80, area.width >= 80 else {
                capture("S21-no-safe-scroll-area"); XCTFail("No unobscured Form area"); return
            }
            if value.exists, value.isHittable, value.frame.minY >= area.minY, value.frame.maxY <= area.maxY { return }
            if value.exists, !value.frame.isEmpty {
                if value.frame.minY < area.minY { forward = false }
                else if value.frame.maxY > area.maxY { forward = true }
            }
            let position = scrollPosition(in: container)
            if forward && position.map({ $0 >= 100 }) == true {
                if reversed { break }; forward = false; reversed = true
            } else if !forward && position.map({ $0 <= 0 }) == true { break }
            let signature = visibleSignature(in: container, area: area)
            unmoved = signature == previousSignature ? unmoved + 1 : 0; previousSignature = signature
            if unmoved >= 2 {
                if !forward || reversed { break }
                forward = false; reversed = true; unmoved = 0
            }
            if attempt == 0 || attempt % 8 == 0 { capture("S21-reveal-\(attempt)-\(id)") }
            scroll(in: container, area: area, forward: forward)
        }
        capture("S21-reveal-exhausted-\(id)")
        XCTFail("Could not fully reveal the requested control in the active Form: \(id)")
    }
    private func activeScrollableContent() -> XCUIElement? {
        guard !app.alerts.firstMatch.exists, !app.sheets.firstMatch.exists else { return nil }
        for candidates in [app.collectionViews.allElementsBoundByIndex, app.tables.allElementsBoundByIndex, app.scrollViews.allElementsBoundByIndex] {
            // XCTest gives this noninteractive Form container the {-1,-1}
            // hit-point sentinel even while its rows are visible and actionable.
            // Select the exposed content by bounds and real children; individual
            // rows and action buttons must still be fully visible and hittable.
            if let active = candidates.last(where: {
                $0.exists && $0.frame.intersection(app.frame).height >= 80 && $0.frame.intersection(app.frame).width >= 80 &&
                    ($0.cells.firstMatch.exists || $0.staticTexts.firstMatch.exists)
            }) { return active }
        }
        return nil
    }
    private func unobscuredArea(in container: XCUIElement) -> CGRect {
        let bounds = container.frame.intersection(app.frame)
        let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.frame.intersects(bounds) }.map { $0.frame.maxY }.max() ?? bounds.minY
        let summary = element("household.devices.fixtureSummary")
        let footerTop = summary.exists && summary.frame.intersects(bounds) ? summary.frame.minY - 8 : bounds.maxY
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter(\.exists).map { $0.frame.minY }.min() ?? bounds.maxY
        let top = max(bounds.minY, navigationBottom) + 12, bottom = min(bounds.maxY, footerTop, keyboardTop) - 12
        return CGRect(x: bounds.minX + 24, y: top, width: max(0, bounds.width - 48), height: max(0, bottom - top))
    }
    private func scrollPosition(in container: XCUIElement) -> Double? {
        for value in container.descendants(matching: .other).allElementsBoundByIndex.reversed() {
            guard value.exists else { continue }
            let label = value.label.lowercased()
            guard label.contains("vertical"), label.contains("scroll") || label.contains("desplazamiento"), let text = value.value as? String, text.hasSuffix("%"),
                  let percentage = Double(text.dropLast().replacingOccurrences(of: ",", with: ".")) else { continue }
            return percentage
        }
        return nil
    }
    private func visibleSignature(in container: XCUIElement, area: CGRect) -> String {
        container.staticTexts.allElementsBoundByIndex.filter { $0.exists && $0.frame.intersects(area) }
            .map { "\($0.label)@\(Int($0.frame.minY))" }.joined(separator: "|")
    }
    private func scroll(in container: XCUIElement, area: CGRect, forward: Bool) {
        let distance = min(240, area.height * 0.42), high = area.midY - distance / 2, low = area.midY + distance / 2
        let origin = container.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - container.frame.minX, dy: (forward ? low : high) - container.frame.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - container.frame.minX, dy: (forward ? high : low) - container.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func tap(_ id: String) {
        let value = element(id); reveal(value, named: id)
        XCTAssertTrue(value.isHittable && value.isEnabled, "The requested action must be visible, enabled and actionable: \(id)")
        value.tap()
    }
    private func summary(_ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element("household.devices.fixtureSummary"))], timeout: 8), .completed)
    }
    private func capture(_ name: String) {
        let state = app.state
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let status = XCTAttachment(string: "Application state at capture: \(state.rawValue). Full-screen evidence is retained even when the app process is absent. No restart or recovery was attempted.")
        status.name = name + " application state"; status.lifetime = .keepAlways; add(status)
        guard state == .runningForeground || state == .runningBackground else { return }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    private func reviewedRevocationAlert(spanish: Bool) -> XCUIElement {
        let title = spanish ? "¿Revocar este dispositivo registrado?" : "Revoke this enrolled device?"
        let alert = app.alerts[title]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "The explicit revocation review must be a native alert")
        let message = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Alex", String(target.suffix(8)))).firstMatch
        XCTAssertTrue(message.exists, "The active review must name Alex and the exact target reference")
        let cancel = alert.buttons[spanish ? "Cancelar" : "Cancel"].firstMatch
        let confirm = alert.buttons[spanish ? "Revocar este dispositivo" : "Revoke this device"].firstMatch
        XCTAssertTrue(cancel.exists && cancel.isHittable, "The review must expose its real explicit Cancel action")
        XCTAssertTrue(confirm.exists && confirm.isHittable)
        return alert
    }
    private func waitForDismissal(_ alert: XCUIElement) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    func testDeviceManagementCancelThenPreciseRevokePreservesOtherAccess() { journey(spanish: false) }
    func testSpanishDeviceManagementLargestTextPaginationAndPreciseRevoke() { journey(spanish: true) }
    private func journey(spanish: Bool) {
        launch(spanish: spanish)
        XCTAssertFalse(element("household.devices.revoke.\(current)").exists)
        tap("household.devices.revoke.\(target)")
        let cancelReview = reviewedRevocationAlert(spanish: spanish)
        capture(spanish ? "Spanish largest text device revoke review" : "Device revoke review")
        cancelReview.buttons[spanish ? "Cancelar" : "Cancel"].firstMatch.tap()
        waitForDismissal(cancelReview)
        summary("writes=0;current=active;target=active;sibling=active;membership=active;shopper=Mia")
        tap("household.devices.more")
        let siblingRow = element("household.devices.active.\(sibling)"); reveal(siblingRow, named: "household.devices.active.\(sibling)"); XCTAssertTrue(siblingRow.exists)
        capture(spanish ? "Spanish largest text device page" : "Device page")
        tap("household.devices.revoke.\(target)")
        let confirmReview = reviewedRevocationAlert(spanish: spanish)
        confirmReview.buttons[spanish ? "Revocar este dispositivo" : "Revoke this device"].firstMatch.tap()
        waitForDismissal(confirmReview)
        summary("writes=1;current=active;target=revoked;sibling=active;membership=active;shopper=Mia")
        reveal("household.devices.result")
        tap("household.devices.refresh")
        let currentRow = element("household.devices.active.\(current)"); reveal(currentRow, named: "household.devices.active.\(current)"); XCTAssertTrue(currentRow.exists)
        let revoked = element("household.devices.revoked.\(target)"); reveal(revoked, named: "household.devices.revoked.\(target)"); XCTAssertTrue(revoked.exists)
        XCTAssertFalse(element("household.devices.revoke.\(target)").exists)
        tap("household.devices.more"); reveal(siblingRow, named: "household.devices.active.\(sibling)"); XCTAssertTrue(siblingRow.exists)
        capture(spanish ? "Spanish largest text precise device revocation" : "Precise device revocation")
    }
}
#endif
