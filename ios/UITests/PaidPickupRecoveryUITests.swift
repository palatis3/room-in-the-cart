#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class PaidPickupRecoveryUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Paid pickup recovery failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        app.terminate()
    }

    func testNamedSeatCanApplyAcceptedRecipeAndExpiredSeatCanReadSavedCookCopy() throws {
        launch(fresh: true)
        tap(app.buttons["Repair a meal"])
        let accepted = app.buttons["Choose an accepted dinner for Wednesday quesadillas"]
        show(accepted)
        let target = String(accepted.identifier.dropFirst("mealRecovery.accepted.".count))
        accepted.tap()
        tap(app.buttons["Accepted bean stew"])
        let prep = app.staticTexts["Required advance preparation (minutes): 20"]
        show(prep)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reviewed matching food")).firstMatch)
        tap(app.buttons["Beans"])
        confirm("I reviewed every food identity, usable unit and inherited exclusion")
        tap(app.buttons["mealRecovery.preview"])
        let changed = app.descendants(matching: .any)["mealRecovery.previewMeal." + target]
        show(changed, down: false)
        XCTAssertTrue(changed.label.contains("Accepted bean stew") && changed.label.contains("Still short: 0"), changed.label)
        let tuesday = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "mealRecovery.previewMeal.", "Tuesday tacos")).firstMatch
        show(tuesday, down: false)
        XCTAssertTrue(tuesday.label.contains("Still short: 2"), tuesday.label)
        confirm("I reviewed the replacement and every other meal’s remaining shortage")
        let apply = app.buttons["mealRecovery.apply"]
        show(apply)
        XCTAssertFalse(apply.isEnabled)
        confirm("I accept that unresolved food or timing remains open")
        tap(apply)
        XCTAssertTrue(app.staticTexts["mealRecovery.saved"].waitForExistence(timeout: 10))
        app.terminate()
        launch(fresh: false)
        tap(app.buttons["Tell the cook"])
        tap(app.buttons["Prepare complete dated instruction"])
        let editor = app.textViews["Editable cook instruction"]
        show(editor)
        let copy = try XCTUnwrap(editor.value as? String)
        for expected in ["Accepted bean stew", "Simmer in a covered pot", "Rinse the beans", "4 units", "Tuesday tacos", "Lunch", "garlic", "sesame", "peanut", "20"] {
            XCTAssertTrue(copy.localizedCaseInsensitiveContains(expected), expected)
        }
        XCTAssertFalse(copy.contains("Wednesday quesadillas"))
        tap(app.buttons["Save dated copy"])
        show(app.buttons["Share saved dated copy"])
        app.terminate()
        launch(fresh: false, expired: true)
        tap(app.buttons["Repair a meal"])
        let manual = app.buttons["Replace Accepted bean stew"]
        show(manual)
        XCTAssertFalse(app.buttons["mealRecovery.accepted." + target].exists)
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["Tell the cook"])
        tap(app.buttons["Review this saved copy"])
        show(editor, down: false)
        XCTAssertEqual(try XCTUnwrap(editor.value as? String), copy)
    }

    private func launch(fresh: Bool, expired: Bool = false) {
        app.launchArguments = ["--ui-testing", "--paid-pickup-recovery", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if fresh { app.launchArguments += ["--reset-test-workspace", "--seed-private-recovery"] }
        if expired { app.launchArguments.append("--expired-recovery-seat") }
        app.launch()
        XCTAssertTrue(app.buttons["Repair a meal"].waitForExistence(timeout: 20))
    }

    private func tap(_ target: XCUIElement) {
        show(target)
        target.tap()
    }
    private func confirm(_ label: String) {
        let toggle = app.switches[label]
        show(toggle)
        if toggle.value as? String == "0" {
            let nativeSwitch = toggle.switches.firstMatch
            let control = nativeSwitch.exists ? nativeSwitch : toggle
            show(control)
            control.tap()
        }
        XCTAssertEqual(toggle.value as? String, "1")
    }
    private func show(_ target: XCUIElement, down: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let surface = app.collectionViews.firstMatch
        for index in 0..<24 {
            if target.exists && target.isHittable { return }
            guard surface.exists else { break }
            let below = (index < 14) == down
            if below { surface.swipeUp() } else { surface.swipeDown() }
        }
        XCTAssertTrue(target.exists && target.isHittable, "Missing control: \(target)", file: file, line: line)
    }
}
#endif
