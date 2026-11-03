#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class HouseholdDevicesUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    private let current = "30000000-0000-4000-8000-000000000004"
    private let target = "30000000-0000-4000-8000-000000000005"
    private let sibling = "30000000-0000-4000-8000-000000000006"
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app.terminate() }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func launch(spanish: Bool = false) {
        app.launchArguments = ["--ui-testing", "--household-devices-fixture", "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_US" : "en_US"]
        if spanish { app.launchArguments.append("--device-fixture-largest-text") }
        app.launch(); XCTAssertTrue(element("household.devices.refresh").waitForExistence(timeout: 15))
        XCTAssertTrue(element("household.devices.alias.\(current)").waitForExistence(timeout: 10))
    }
    private func reveal(_ value: XCUIElement) {
        for attempt in 0..<40 {
            if value.exists && value.isHittable && value.frame.midY > app.navigationBars.firstMatch.frame.maxY && value.frame.midY < app.frame.maxY - 100 { return }
            if value.exists && value.frame.midY < app.frame.midY { app.swipeDown() }
            else if attempt < 28 { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(value.exists && value.isHittable, value.debugDescription)
    }
    private func tap(_ id: String) { let value = element(id); reveal(value); value.tap() }
    private func summary(_ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element("household.devices.fixtureSummary"))], timeout: 8), .completed)
    }
    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    func testDeviceManagementCancelThenPreciseRevokePreservesOtherAccess() { journey(spanish: false) }
    func testSpanishDeviceManagementLargestTextPaginationAndPreciseRevoke() { journey(spanish: true) }
    private func journey(spanish: Bool) {
        launch(spanish: spanish)
        XCTAssertFalse(element("household.devices.revoke.\(current)").exists)
        tap("household.devices.revoke.\(target)")
        XCTAssertTrue(element("household.devices.cancel").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Alex")).count > 0)
        capture(spanish ? "Spanish largest text device revoke review" : "Device revoke review")
        element("household.devices.cancel").tap()
        summary("writes=0;current=active;target=active;sibling=active;membership=active;shopper=Mia")
        tap("household.devices.more")
        let siblingRow = element("household.devices.active.\(sibling)"); reveal(siblingRow); XCTAssertTrue(siblingRow.exists)
        capture(spanish ? "Spanish largest text device page" : "Device page")
        tap("household.devices.revoke.\(target)")
        let confirm = element("household.devices.confirm"); XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(element("household.devices.result").waitForExistence(timeout: 10))
        summary("writes=1;current=active;target=revoked;sibling=active;membership=active;shopper=Mia")
        tap("household.devices.refresh")
        let revoked = element("household.devices.revoked.\(target)"); reveal(revoked); XCTAssertTrue(revoked.exists)
        XCTAssertFalse(element("household.devices.revoke.\(target)").exists)
        tap("household.devices.more"); reveal(siblingRow); XCTAssertTrue(siblingRow.exists)
        capture(spanish ? "Spanish largest text precise device revocation" : "Precise device revocation")
    }
}
#endif
