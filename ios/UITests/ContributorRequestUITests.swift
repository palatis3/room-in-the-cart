#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Dedicated fixture build only; shipping app models/views/client, intercepted fictional endpoints.
@MainActor final class ContributorRequestUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Contributor-request-failure") }
        app.terminate()
    }
    func testHelperSeesCurrentInstructionRevisionAndDateAfterRefreshInBothLanguages() {
        for (language, entry, label, refresh) in [
            ("en", "Cook instructions", "Current instruction revision", "Refresh instructions"),
            ("es", "Instrucciones para cocinar", "Versión actual de las instrucciones", "Actualizar instrucciones")
        ] {
            app.launchArguments = ["--ui-testing", "--helper-revision-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", language + "_US"]
            app.launch()
            // The helper link can be below the visible rows of the settings Form.
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 30))
            XCTAssertFalse(app.buttons["household.priceBudgetHistory"].exists)
            tap(app.buttons[entry])
            func read(_ number: Int, _ action: String) {
                let instruction = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", action)).firstMatch
                XCTAssertTrue(instruction.waitForExistence(timeout: 10))
                let revision = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND (value == %@ OR label CONTAINS %@)", label, String(number), String(number))).firstMatch
                XCTAssertTrue(revision.exists, app.debugDescription)
            }
            read(12, "Save two")
            let updated = element("helper.instructions.asOf")
            func timestamp() -> String { updated.label + (updated.value as? String ?? "") }
            let before = timestamp()
            XCTAssertTrue(before.contains("2026"), before)
            tap(app.buttons[refresh])
            read(13, "Save three")
            XCTAssertNotEqual(timestamp(), before)
            app.terminate()
        }
    }

    func testSpanishContributorReadsOnlyExplicitPurchaseStatusOnTheirOwnRequests() {
        app.launchArguments = ["--ui-testing", "--own-purchases-fixture", "-AppleLanguages", "(es)", "-AppleLocale", "es_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hogar"].waitForExistence(timeout: 20))
        let bought = element("household.ownRequest.aaaaaaaa-1111-4111-8111-111111111111")
        let unconfirmed = element("household.ownRequest.bbbbbbbb-1111-4111-8111-111111111111")
        reveal(bought)
        XCTAssertTrue(bought.label.contains("Arroz"), bought.label)
        XCTAssertTrue(bought.label.contains("La persona que hizo la compra confirm\u{00f3} que se compr\u{00f3}"), bought.label)
        reveal(unconfirmed)
        XCTAssertTrue(unconfirmed.label.contains("Fruta"), unconfirmed.label)
        XCTAssertFalse(unconfirmed.label.contains("se compr\u{00f3}"), unconfirmed.label)
        XCTAssertFalse(element("delivery.requestPurchases").exists)
        XCTAssertFalse(element("household.decision.after-total").exists)
        XCTAssertFalse(app.buttons["household.decision.checkoutDetails"].exists)
        XCTAssertFalse(app.buttons["household.decision.includedCharges"].exists)
    }

    func testSpanishLargeTextReviewStartsAtTheOriginalWording() {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 {
            app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        }
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(es)", "-AppleLocale", "es_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hogar"].waitForExistence(timeout: 30))
        tap(element("household.request.capture"))
        let captureBar = app.navigationBars["Capturar una solicitud"]
        XCTAssertTrue(captureBar.waitForExistence(timeout: 10))
        let original = "2 paquetes de 8 tortillas para almuerzo sin leche"
        fill(original, into: "capture.editor", replacing: true)
        enableSwitch("Revisé el texto, las cantidades, las unidades y las exclusiones.")
        tap(element("capture.reviewFields"))

        let atTop = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let text = object as? XCUIElement, text.exists, text.isHittable else { return false }
            return text.frame.minY >= captureBar.frame.maxY && text.frame.minY < self.app.frame.midY
        }, object: element("capture.structured.original"))
        XCTAssertEqual(XCTWaiter.wait(for: [atTop], timeout: 12), .completed)
        XCTAssertEqual(element("capture.structured.original").label, original)
        capture("Spanish-large-text-original-at-top")
    }

    func testTypedAndStructuredReviewCancelThenSendOnlyOwnRequest() throws {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForHousehold(timeout: 20)
        fill("Rice", into: "Item")
        fill("2 packs", into: "Quantity, optional")
        tap(element("household.request.review"))
        assertText("Request the household will receive")
        assertText("Rice")
        tap(app.buttons["Cancel"])
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 0")
        openStructuredReview()
        capture("Contributor-original-and-corrected-request-preview")
        tap(app.buttons["Cancel"])
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 0")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 0")
        openStructuredReview()
        let approval = element("household.request.approve")
        reveal(approval, fullyVisible: true)
        approval.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(approval.value as? String, "1")
        tap(element("household.request.sendReviewed"))
        waitForHousehold(timeout: 10)
        let posts = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Fixture request POSTs: 1"), object: element("fixture.requestPosts"))
        let rows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Fixture saved requests: 1"), object: element("fixture.requestRows"))
        XCTAssertEqual(XCTWaiter.wait(for: [posts, rows], timeout: 10), .completed)
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 1")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 1")
        assertText("Wholemeal wraps")
        assertText("2 packs of 8 wraps for lunch without sesame")
        assertText("Received, waiting for review")
        capture("Contributor-reviewed-own-request-received")
    }
    private func waitForHousehold(timeout: TimeInterval) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let bar = object as? XCUIElement else { return false }
            return bar.exists && bar.isHittable
        }, object: app.navigationBars["Household"])
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: timeout), .completed)
    }
    private func openStructuredReview() {
        tap(element("household.request.capture"))
        fill("2 packs of 8 wraps for lunch without sesame", into: "capture.editor", replacing: true)
        enableSwitch("I checked the wording, amounts, units and exclusions.")
        tap(element("capture.reviewFields"))
        fill("Wholemeal wraps", into: "Item name", replacing: true)
        let packs = element("Number of packs, unknown if blank")
        reveal(packs); XCTAssertEqual(packs.value as? String, "2")
        let perPack = element("Usable amount in each pack, unknown if blank")
        reveal(perPack); XCTAssertEqual(perPack.value as? String, "8")
        enableSwitch("I reviewed this item, amounts, packs, purpose, destination and exclusions, including any unknowns.")
        tap(element("capture.continue"))
        assertText("Original wording")
        assertText("Wholemeal wraps")
        assertText("lunch")
        assertText("sesame")
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        for attempt in 0..<24 {
            var area = scrollableArea()
            let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo"])).firstMatch
            if app.keyboards.firstMatch.exists && done.exists {
                area.size.height = max(0, min(area.maxY, done.frame.minY) - area.minY)
            }
            XCTAssertGreaterThanOrEqual(area.height, 80, "Need visible form content before acknowledging \(label)")
            if control.exists && !control.frame.isEmpty {
                // The accessibility row includes a multiline label. Its actual
                // trailing switch can be visible while part of that label is not.
                let coordinate = control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
                let point = coordinate.screenPoint
                if control.isEnabled && control.isHittable && area.contains(point) {
                    print("CONTRIBUTOR_SWITCH_TAP label=\(label) point=\(point) area=\(area)")
                    if control.value as? String == "0" { coordinate.tap() }
                    XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
                    return
                }
                scrollContent(upward: point.y > area.midY, distance: abs(point.y - area.midY))
            } else {
                scrollContent(upward: attempt < 16)
            }
        }
        XCTFail("No visible switch tap point after 24 reveal attempts: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        // A Form can expose both its StaticText label and its input with the
        // same name. Never let a label become the typing target.
        let field = id == "capture.editor" ? app.textViews[id] : app.textFields[id]
        tap(field)
        dismissBilingualKeyboardCardIfPresent()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The input must have a software keyboard before typing")
        if replacing, let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            // Tapping a multiline editor does not put the caret at its end.
            // Select the whole value through the real edit menu before replacing it.
            field.press(forDuration: 1.2)
            let labels = ["Select All", "Seleccionar todo"]
            let menuItem = app.menuItems.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            let button = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            let selectAll = menuItem.exists ? menuItem : button
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(selectAll.isHittable)
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            let cleared = field.value as? String
            XCTAssertTrue(cleared == "" || cleared == field.placeholderValue, "The entire input must be cleared: \(cleared ?? "nil")")
        }
        field.typeText(text)
        dismissBilingualKeyboardCardIfPresent()
        XCTAssertEqual(field.value as? String, text, "Typed input must exactly replace the draft before review")
        if id == "capture.editor" {
            dismissCaptureKeyboard()
            // Large text can move this Form row offscreen during dismissal.
            // Reveal it again before reading the virtualized editor's value.
            reveal(field)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Revealing the editor must not reopen the keyboard")
            XCTAssertEqual(field.value as? String, text, "Dismissing the keyboard must preserve the draft")
        }
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func dismissCaptureKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        // End editing through the same explicit control available to a person;
        // a Form swipe can leave keyboard dismissal dependent on its scroll state.
        let done = app.buttons["capture.sourceDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The source editor must offer Done")
        XCTAssertTrue(done.isHittable)
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    private func dismissBilingualKeyboardCardIfPresent() {
        let title = app.staticTexts["Type español e inglés"]
        guard title.waitForExistence(timeout: 2) else {
            XCTContext.runActivity(named: "Bilingual keyboard onboarding absent") { _ in }
            return
        }
        // This is the observed iOS keyboard onboarding card, not an arbitrary
        // Continue button or a product consent dialog.
        XCTAssertTrue(app.staticTexts["Type both languages on the same keyboard. Customize in Settings."].exists)
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.exists && next.isHittable)
        XCTContext.runActivity(named: "Dismiss the identified bilingual keyboard onboarding card") { _ in
            capture("Bilingual-keyboard-card-before-dismissal")
            next.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            capture("Bilingual-keyboard-card-dismissed")
        }
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false) {
        for attempt in 0..<24 {
            let area = scrollableArea()
            // A partly visible multiline switch can be hittable while its
            // trailing control is still behind the software keyboard.
            if target.exists && target.isHittable,
               !fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY) { return }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            // A tall accessibility row may fit the viewport but not tolerate
            // another full swipe. Center it with a measured, bounded drag.
            let distance = fullyVisible && target.exists && !target.frame.isEmpty
                ? abs(target.frame.midY - area.midY) : nil
            scrollContent(upward: upward, distance: distance)
        }
        let area = scrollableArea()
        XCTAssertTrue(target.exists && target.isHittable &&
            (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)),
            "Missing actionable UI element: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        // Review can dismiss the keyboard between separate live exists/frame queries.
        // Measure the keyboard and navigation bars from the same immutable tree.
        guard let snapshot = try? app.snapshot() else {
            XCTFail("Could not snapshot the app while measuring the content viewport")
            return .zero
        }
        let bounds = snapshot.frame
        var keyboardTop = bounds.maxY
        var barBottom = bounds.minY + 88
        var elements = [snapshot]
        while let element = elements.popLast() {
            let frame = element.frame
            if !frame.isEmpty && frame.intersects(bounds) {
                if element.elementType == .keyboard { keyboardTop = min(keyboardTop, frame.minY) }
                if element.elementType == .navigationBar { barBottom = max(barBottom, frame.maxY) }
            }
            elements.append(contentsOf: element.children)
        }
        let top = max(bounds.minY + 88, min(barBottom + 12, keyboardTop - 140))
        let bottom = min(bounds.maxY - 100, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool, distance: CGFloat? = nil) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = scrollableArea(), bounds = app.frame
        let travel = min(area.height * 0.6, max(20, distance ?? area.height * 0.6))
        let high = area.midY - travel / 2, low = area.midY + travel / 2
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertText(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists && target.isHittable, "Missing visible text: \(text)")
    }
    private func assertElementContains(_ id: String, _ text: String) {
        let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text), target.label)
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        tap(app.buttons[value])
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

#endif
