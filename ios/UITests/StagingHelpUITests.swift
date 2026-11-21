#if STAGING
import XCTest

final class StagingHelpUITests: XCTestCase {
    private let app = XCUIApplication()
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")

    private func openSettings(language: String) {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_US"]
        app.launch()
        let shopTitle = language == "es" ? "Compras" : "Shop"
        let shop = app.tabBars.buttons[shopTitle]
        XCTAssertTrue(shop.waitForExistence(timeout: 20))
        shop.tap()
        let settings = app.navigationBars[shopTitle].buttons["settings"]
        for _ in 0..<4 {
            if settings.exists && settings.isHittable { break }
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(settings.wait(for: \.isHittable, toEqual: true, timeout: 5))
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

    func testConfiguredSpanishFamilyGuideReturnsFromSafariToNativeHelp() {
        openSettings(language: "es")
        tapInList(app.buttons["guardian.familyGuide"])
        let guide = app.navigationBars["Permisos de menores"]
        XCTAssertTrue(guide.waitForExistence(timeout: 8))
        let online = app.descendants(matching: .any).matching(identifier: "guardian.familyGuide.online").firstMatch
        tapInList(online)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        let heading = web.staticTexts["Menores y permiso del tutor"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        // The contents menu repeats the section heading. Only the section itself has its scope paragraph.
        let scope = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Con el permiso del tutor y un dispositivo vinculado")).firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 12))
        XCTAssertTrue(scope.isHittable, "The configured Spanish family section should open at its own anchor.")
        let done = app.buttons.matching(NSPredicate(format: "label IN %@ AND NOT (identifier IN %@)",
                                                     ["Done", "Listo", "OK"], ["guardian.familyGuide.done", "settings.done"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        done.tap()
        XCTAssertTrue(web.waitForNonExistence(timeout: 8))
        let settings = app.navigationBars["Configuración"]
        let guideDone = guide.buttons["guardian.familyGuide.done"]
        let settingsDone = settings.buttons["settings.done"]
        func canTap(_ button: XCUIElement) -> Bool {
            guard button.exists && button.isHittable else { return false }
            let frame = button.frame
            return !frame.isEmpty && app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        // Safari can close the guide sheet as well. A dismissing guide can
        // remain in the hierarchy below the screen while Settings is active.
        let nativeReturn = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            canTap(guideDone) || canTap(settingsDone)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [nativeReturn], timeout: 8), .completed,
                       "Safari must return to the native family guide or Settings.")
        let nativeDone = canTap(guideDone) ? guideDone : settingsDone
        XCTAssertTrue(canTap(nativeDone))
        nativeDone.tap()
        XCTAssertTrue(guide.waitForNonExistence(timeout: 8))
        XCTAssertTrue(settings.waitForNonExistence(timeout: 8))
        let originalShop = app.navigationBars["Compras"]
        XCTAssertTrue(originalShop.waitForExistence(timeout: 8))
        XCTAssertTrue(originalShop.buttons["settings"].wait(for: \.isHittable, toEqual: true, timeout: 8))
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
