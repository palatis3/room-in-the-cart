import UIKit
import XCTest

extension XCTestCase {
    @MainActor func readySystemShareClose(in app: XCUIApplication,
                                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "header.closeButton", "Close")).firstMatch
        let activityHost = app.otherElements["ActivityListView"].firstMatch
        let remoteContent = activityHost.descendants(matching: .other)["ShareSheet.RemoteContainerView"].firstMatch
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
        guard waitForShareState("The system share sheet did not begin presenting", timeout: 15, until: {
            remoteContent.exists || (close.exists && close.isEnabled && close.isHittable)
        }) else { return nil }
        // UIKit presents the remote container before the system activity service
        // supplies its controls. Only a usable Close permits cancellation.
        guard waitForShareState("The presented system share sheet did not load its Close control", timeout: 45, until: {
            close.exists && close.isEnabled && close.isHittable
        }) else { return nil }
        return close
    }
}
