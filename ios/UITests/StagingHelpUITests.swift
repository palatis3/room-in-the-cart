#if STAGING
import XCTest

final class StagingHelpUITests: XCTestCase {
    private let app = XCUIApplication()
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")

    private func openSettings(language: String) {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_US"]
        app.launch()
        let settings = app.buttons["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
    }

    func testOnlineHelpOpensItsPageInSafari() {
        openSettings(language: "es")
        tapInList(app.buttons["settings.help"])
        tapInList(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Ayuda en línea")).firstMatch)
        verifyPublicPage("Ayuda")
    }

    func testOnlineSupportOpensItsPageInSafari() {
        openSettings(language: "en")
        tapInList(app.buttons["settings.support"])
        tapInList(app.descendants(matching: .any).matching(identifier: "help.support.open").firstMatch)
        verifyPublicPage("Support")
    }

    private func tapInList(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<9 {
            if target.exists && target.isHittable {
                let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
                if app.frame.insetBy(dx: 0, dy: 38).contains(point) {
                    target.tap()
                    return
                }
            }
            app.swipeUp()
        }
        XCTFail("Could not reach the requested row", file: file, line: line)
    }

    private func verifyPublicPage(_ heading: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), file: file, line: line)
        #if targetEnvironment(simulator)
        for name in ["Continue", "Start Browsing", "Not Now"] {
            let button = safari.buttons[name]
            if button.exists && button.isHittable { button.tap() }
        }
        #endif
        let web = safari.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30), file: file, line: line)
        XCTAssertTrue(web.links["Room in the Cart"].firstMatch.waitForExistence(timeout: 20), file: file, line: line)
        let capture = XCTAttachment(screenshot: safari.screenshot())
        capture.name = "Staging " + heading
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertTrue(web.staticTexts[heading].firstMatch.exists, file: file, line: line)
    }
}
#endif
