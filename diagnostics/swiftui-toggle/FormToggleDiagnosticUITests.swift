import XCTest

@MainActor
final class FormToggleDiagnosticUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }

    func testOneTapAfterInputDoneAndScroll() {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Whole checkout"].waitForExistence(timeout: 10))
        for (label, value) in [("Store", "Test market"), ("Branch", "Main branch"),
                               ("Pickup or delivery slot", "Tuesday 5 PM"), ("Source of these prices", "Test checkout")] {
            let input = app.textFields[label]
            reveal(input)
            input.tap()
            input.typeText(value)
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
            done.tap()
        }
        let control = app.switches["Retailer total already includes all charges"]
        XCTContext.runActivity(named: "Scroll Form after keyboard dismissal") { _ in
            XCTAssertTrue(control.exists, "The same switch must be measurable before the diagnostic drag")
            let before = control.frame
            scroll(upward: true, area: scrollableArea())
            XCTAssertTrue(control.exists, "The same switch must remain measurable after the diagnostic drag")
            let after = control.frame
            let evidence = XCTAttachment(string: "Before midpoint Y: \(before.midY)\nAfter midpoint Y: \(after.midY)")
            evidence.name = "Toggle-scroll-movement"; evidence.lifetime = .keepAlways; add(evidence)
            XCTAssertGreaterThan(abs(after.midY - before.midY), 1, "A requested drag without measured movement is inconclusive")
        }
        // Match the product helper's bounded, visible-content drag; no retries of the tap.
        reveal(control)
        let area = scrollableArea()
        if control.frame.midY > area.maxY { scroll(upward: true, area: area) }
        else if control.frame.midY < area.minY { scroll(upward: false, area: area) }
        capture(control, "before")
        XCTAssertEqual(control.value as? String, "0", "The control starts off")
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        capture(control, "after")
        XCTAssertEqual(control.value as? String, "1", "One tap must turn the control on")
    }

    private func reveal(_ target: XCUIElement) {
        for attempt in 0..<24 {
            if target.exists && target.isHittable { return }
            let area = scrollableArea()
            let upward = target.exists && !target.frame.isEmpty ? target.frame.midY > area.midY : attempt < 16
            scroll(upward: upward, area: area)
        }
        XCTFail("Control not hittable: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        let snapshot = try? app.snapshot()
        let bounds = snapshot?.frame ?? app.frame
        var keyboardTop = bounds.maxY, barBottom = bounds.minY + 88
        var elements = snapshot.map { [$0] } ?? []
        while let item = elements.popLast() {
            let frame = item.frame
            if frame.height > 0 && frame.intersects(bounds) {
                if item.elementType == .keyboard { keyboardTop = min(keyboardTop, frame.minY) }
                if item.elementType == .navigationBar { barBottom = max(barBottom, frame.maxY) }
            }
            elements.append(contentsOf: item.children)
        }
        let top = max(bounds.minY + 88, min(barBottom + 12, keyboardTop - 140))
        let bottom = min(bounds.maxY - 100, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scroll(upward: Bool, area: CGRect) {
        let bounds = app.frame, origin = app.coordinate(withNormalizedOffset: .zero)
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func capture(_ control: XCUIElement, _ phase: String) {
        let exists = control.exists
        var facts = ["Timestamp: \(Date().timeIntervalSince1970)", "Exists: \(exists)"]
        if exists {
            let frame = control.frame
            facts += ["Frame: \(frame)", "Requested point: \(CGPoint(x: frame.minX + frame.width * 0.92, y: frame.midY))", "Enabled: \(control.isEnabled)", "Hittable: \(control.isHittable)", "Value: \(String(describing: control.value))"]
        }
        facts += ["Keyboard: \(app.keyboards.firstMatch.exists)", "Content area: \(scrollableArea())"]
        let state = XCTAttachment(string: facts.joined(separator: "\n")); state.name = "Toggle-\(phase)-state"; state.lifetime = .keepAlways; add(state)
        let ax = XCTAttachment(string: app.debugDescription); ax.name = "Toggle-\(phase)-AX"; ax.lifetime = .keepAlways; add(ax)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Toggle-\(phase)-screen"; shot.lifetime = .keepAlways; add(shot)
    }
}
