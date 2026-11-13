import UIKit
import XCTest

extension XCTestCase {
    @MainActor func readySystemShareClose(in app: XCUIApplication,
                                          requireStableFrame: Bool = false,
                                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        let activityClose = app.navigationBars["UIActivityContentView"].buttons["header.closeButton"]
        let systemClose = app.buttons["header.closeButton"].firstMatch
        let hostClose = app.otherElements["ActivityListView"].buttons["Close"].firstMatch
        var close: XCUIElement?
        func usableClose() -> Bool {
            // Resolve within the observed system activity header when available.
            // Keep the existing lookup for system versions with another hierarchy.
            let candidate: XCUIElement
            if activityClose.exists { candidate = activityClose }
            else if systemClose.exists { candidate = systemClose }
            else { candidate = hostClose }
            guard candidate.exists && candidate.isEnabled && candidate.isHittable else { return false }
            close = candidate
            return true
        }
        func waitForShareState(_ description: String, timeout: TimeInterval, until ready: @escaping () -> Bool) -> Bool {
            let started = Date()
            let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ready() }, object: nil)
            let result = XCTWaiter.wait(for: [condition], timeout: timeout)
            if result == .completed { return true }

            // Capture the system screen before a slow hierarchy query changes the evidence.
            let facts = XCTAttachment(string: "\(description); waiter: \(result); allowance: \(timeout)s; observed wait: \(Date().timeIntervalSince(started))s; Reduce Motion: \(UIAccessibility.isReduceMotionEnabled)")
            facts.name = "Share-readiness-failed-boundary"; facts.lifetime = .keepAlways; add(facts)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Share-readiness-failed-before-debug-hierarchy"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("\(description). \(app.debugDescription)", file: file, line: line)
            return false
        }
        // A cold activity service can take most of the existing minute to publish
        // its first accessibility tree. Wait directly for the control we will tap.
        var previous: (identifier: String, label: String, frame: CGRect)?
        guard waitForShareState("The system share sheet did not load its Close control", timeout: 60, until: {
            guard usableClose(), let close else { previous = nil; return false }
            guard requireStableFrame else { return true }
            // The remote header can be hittable while its presentation is still moving.
            guard let snapshot = try? close.snapshot(), !snapshot.frame.isEmpty else { previous = nil; return false }
            let current = (identifier: snapshot.identifier, label: snapshot.label, frame: snapshot.frame)
            defer { previous = current }
            return previous?.identifier == current.identifier && previous?.label == current.label && previous?.frame == current.frame
        }) else { return nil }
        return close
    }
}
