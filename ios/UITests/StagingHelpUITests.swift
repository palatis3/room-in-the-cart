#if STAGING
import XCTest

final class StagingHelpUITests: XCTestCase {
    private let app = XCUIApplication()
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")

    private func openSettings(language: String) {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_US"]
        app.launch()
        let shop = app.tabBars.buttons[language == "es" ? "Compras" : "Shop"]
        XCTAssertTrue(shop.waitForExistence(timeout: 20))
        shop.tap()
        let settings = app.buttons["settings"]
        for _ in 0..<4 {
            if settings.exists { break }
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
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
        let web = safari.webViews.firstMatch
        let pageHeading = web.staticTexts[heading].firstMatch
        #if targetEnvironment(simulator)
        // Safari can dismiss its first-run sheet as the requested page opens.
        // Give the page priority and avoid asking XCTest to re-find a vanished button during the tap.
        if !pageHeading.waitForExistence(timeout: 5) || !pageHeading.isHittable {
            for name in ["Continue", "Start Browsing", "Not Now"] {
                let button = safari.buttons[name]
                guard button.exists, button.isHittable, let snapshot = try? button.snapshot() else { continue }
                if pageHeading.exists && pageHeading.isHittable { break }
                let frame = snapshot.frame
                let point = CGPoint(x: frame.midX, y: frame.midY)
                let bounds = safari.frame
                guard !frame.isEmpty, bounds.contains(point) else { continue }
                safari.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x - bounds.minX, dy: point.y - bounds.minY)).tap()
            }
        }
        #endif
        XCTAssertTrue(web.waitForExistence(timeout: 30), file: file, line: line)
        XCTAssertTrue(web.links["Room in the Cart"].firstMatch.waitForExistence(timeout: 20), file: file, line: line)
        let capture = XCTAttachment(screenshot: safari.screenshot())
        capture.name = "Staging " + heading
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertTrue(pageHeading.exists, file: file, line: line)
    }
}
#endif
