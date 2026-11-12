#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Actual shared-shop screens with fixed synthetic HTTP facts and a real private
/// outbox. This journey does not stand in for real-service transaction acceptance.
@MainActor final class SharedOperationUndoUITests: XCTestCase {
    private var app: XCUIApplication!
    private var capturedFailureHierarchy = false
    private let target = "00000000-0000-4000-8000-000000000006"
    private let wraps = "00000000-0000-4000-8000-000000000003"
    private let apples = "00000000-0000-4000-8000-000000000011"
    override func setUpWithError() throws {
        continueAfterFailure = false; app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
        app.launchEnvironment["RITC_OPERATION_UNDO_WORKSPACE"] = UUID().uuidString
        app.launchEnvironment["RITC_OPERATION_UNDO_RESET"] = "1"
        app.launchEnvironment["RITC_OPERATION_UNDO_MEAL"] = "0"
        app.launchEnvironment["RITC_OPERATION_UNDO_STORE"] = "0"
    }
    override func tearDownWithError() throws { if testRun?.failureCount ?? 0 > 0 { captureFailureHierarchy(); capture("Operation-Undo-failure") }; app.terminate() }
    func testSavedChangeCancelApplyRelaunchExactRetryAndLaterFoodSurvives() { journey(spanish: false); sameStoreCopy(spanish: false) }
    func testSpanishSavedChangeCancelApplyRelaunchExactRetryAndLaterFoodSurvives() { journey(spanish: true); sameStoreCopy(spanish: true) }
    func testSkippedDinnerUndoCancelRelaunchRetryKeepsProtectedLunchAndLaterStaple() { mealJourney(spanish: false) }
    func testSpanishSkippedDinnerUndoCancelRelaunchRetryKeepsProtectedLunchAndLaterStaple() { mealJourney(spanish: true) }
    // Append one short read-only observation after the original no-store
    // journey. A fresh workspace resets synthetic counters; no new CI shard.
    private func sameStoreCopy(spanish: Bool) {
        app.terminate()
        app.launchEnvironment["RITC_OPERATION_UNDO_WORKSPACE"] = UUID().uuidString
        app.launchEnvironment["RITC_OPERATION_UNDO_RESET"] = "1"
        app.launchEnvironment["RITC_OPERATION_UNDO_STORE"] = "1"
        app.launch(); waitForShop(spanish: spanish)
        counts(previews: 0, posts: 0, writes: 0, retries: 0)
        openHistory(); openCandidate(spanish: spanish)
        let value = app.staticTexts["sharedUndo.store.unchanged"]
        reveal(value, initialSearchDirection: .towardStart)
        XCTAssertEqual(value.label, spanish ? "Se mantendrá la tienda seleccionada." : "The selected store will stay the same.")
        XCTAssertTrue(app.frame.contains(value.frame)); XCTAssertGreaterThan(value.frame.height, 0)
        XCTAssertTrue(value.isHittable)
        capture("Same-Store-Undo-\(spanish ? "es" : "en")-unchanged-store-copy")
        tap(app.buttons["sharedUndo.cancel"]); waitForShop(spanish: spanish)
        counts(previews: 0, posts: 0, writes: 0, retries: 0)
        app.launchEnvironment["RITC_OPERATION_UNDO_STORE"] = "0"
    }
    private func mealJourney(spanish: Bool) {
        let language = spanish ? "es" : "en"
        app.launchEnvironment["RITC_OPERATION_UNDO_MEAL"] = "1"
        app.launchArguments = ["--ui-testing", "--shared-operation-undo-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", spanish ? "es_US" : "en_US", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch(); waitForShop(spanish: spanish); counts(previews: 0, posts: 0, writes: 0, retries: 0)
        assertText("Protected lunch"); assertText("Later apples", initialSearchDirection: .towardStart)
        openHistory(); openCandidate(spanish: spanish)
        assertText(spanish ? "Esta comida está omitida actualmente." : "This meal is currently skipped.")
        assertText("Original taco dinner"); enterPacks(amount: "8")
        tap(app.buttons["sharedUndo.preview"]); assertMealReview(spanish: spanish)
        capture("Meal-Undo-\(language)-before-Cancel")
        tap(app.buttons["sharedUndo.cancel"]); waitForShop(spanish: spanish)
        counts(previews: 1, posts: 0, writes: 0, retries: 0)
        openHistory(); openCandidate(spanish: spanish)
        assertText(spanish ? "Esta comida está omitida actualmente." : "This meal is currently skipped.")
        enterPacks(amount: "8"); tap(app.buttons["sharedUndo.preview"]); assertMealReview(spanish: spanish)
        setSwitch("sharedUndo.acknowledged", on: true); tap(app.buttons["sharedUndo.apply"])
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        tap(app.buttons["sharedUndo.return"]); reveal(app.buttons["sharedShop.retry"])
        capture("Meal-Undo-\(language)-lost-reply")
        app.terminate(); app.launchEnvironment["RITC_OPERATION_UNDO_RESET"] = "0"; app.launch(); waitForShop(spanish: spanish)
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        tap(app.buttons["sharedShop.retry"]); counts(previews: 2, posts: 2, writes: 1, retries: 1)
        XCTAssertTrue(app.buttons["sharedShop.retry"].waitForNonExistence(timeout: 12))
        assertText(spanish ? "Cambio de compra compartida confirmado" : "Shared shop change confirmed")
        assertText("Original taco dinner", initialSearchDirection: .towardEnd)
        assertText("Protected lunch", initialSearchDirection: .towardStart); assertText("Later apples", initialSearchDirection: .towardStart)
        openHistory()
        let already = app.staticTexts["sharedUndo.unavailable." + target]
        reveal(already); XCTAssertEqual(already.label, spanish ? "Este cambio ya se deshizo." : "This change was already undone.")
        tap(app.buttons["sharedUndo.cancel"]); tap(app.buttons["sharedShop.foodQuantities"], initialSearchDirection: .towardStart)
        assertUnknownTotal(spanish: spanish)
        assertText("Six original taco wraps"); assertText("Two wraps held for lunch", initialSearchDirection: .towardStart)
        assertText("Later apples — amount unknown")
        counts(previews: 2, posts: 2, writes: 1, retries: 1)
        capture("Meal-Undo-\(language)-restored-dinner-and-survivors")
    }
    private func assertMealReview(spanish: Bool) {
        let apply = app.buttons["sharedUndo.apply"]; reveal(apply); XCTAssertFalse(apply.isEnabled)
        // SwiftUI propagates the source VStack identifier to its Text rows.
        // Select the exact wording on that source, not children of its first Text.
        let lunch = app.staticTexts.matching(identifier: "sharedUndo.after.source.00000000-0000-4000-8000-000000000022")
            .matching(NSPredicate(format: "label == %@", "Two lunch wraps")).firstMatch
        reveal(lunch, initialSearchDirection: .towardStart)
        XCTAssertEqual(lunch.label, "Two lunch wraps")
        let meal = app.staticTexts.matching(identifier: "sharedUndo.after.source.00000000-0000-4000-8000-000000000021")
            .matching(NSPredicate(format: "label == %@", "Six original taco wraps")).firstMatch
        reveal(meal); XCTAssertEqual(meal.label, "Six original taco wraps")
        let survivor = element("sharedUndo.after.source.00000000-0000-4000-8000-000000000012")
        reveal(survivor); XCTAssertTrue(survivor.exists && survivor.isHittable)
        for (amount, direction) in [("$5.00", SearchDirection.towardStart), ("$7.00", .towardEnd)] {
            let money = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", amount)).firstMatch
            reveal(money, initialSearchDirection: direction); XCTAssertTrue(money.isHittable, amount)
        }
        assertText(spanish ? "Esta comida está omitida actualmente." : "This meal is currently skipped.", initialSearchDirection: .towardStart)
        assertText("Original taco dinner")
        assertText(spanish ? "Recuperar la comida omitida" : "Restore the skipped meal")
    }
    private func journey(spanish: Bool) {
        let language = spanish ? "es" : "en"
        app.launchArguments = ["--ui-testing", "--shared-operation-undo-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", spanish ? "es_US" : "en_US", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch(); waitForShop(spanish: spanish); counts(previews: 0, posts: 0, writes: 0, retries: 0)
        openHistory()
        let unsupported = app.staticTexts["sharedUndo.unavailable.00000000-0000-4000-8000-000000000030"]
        reveal(unsupported); XCTAssertTrue(unsupported.label.contains(spanish ? "Este cambio de comida" : "This meal change"), unsupported.label)
        openCandidate(spanish: spanish); enterPacks()
        tap(app.buttons["sharedUndo.preview"]); assertReview(spanish: spanish)
        capture("Operation-Undo-\(language)-before-Cancel")
        tap(app.buttons["sharedUndo.cancel"]); waitForShop(spanish: spanish)
        counts(previews: 1, posts: 0, writes: 0, retries: 0)
        openHistory(); openCandidate(spanish: spanish); enterPacks()
        tap(app.buttons["sharedUndo.preview"]); assertReview(spanish: spanish)
        setSwitch("sharedUndo.acknowledged", on: true); tap(app.buttons["sharedUndo.apply"])
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        tap(app.buttons["sharedUndo.return"]); reveal(app.buttons["sharedShop.retry"])
        capture("Operation-Undo-\(language)-lost-reply")
        app.terminate(); app.launchEnvironment["RITC_OPERATION_UNDO_RESET"] = "0"; app.launch(); waitForShop(spanish: spanish)
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        tap(app.buttons["sharedShop.retry"]); counts(previews: 2, posts: 2, writes: 1, retries: 1)
        XCTAssertTrue(app.buttons["sharedShop.retry"].waitForNonExistence(timeout: 12))
        assertText(spanish ? "Cambio de compra compartida confirmado" : "Shared shop change confirmed")
        assertText("Later apples")
        openHistory()
        let already = app.staticTexts["sharedUndo.unavailable." + target]
        reveal(already); XCTAssertEqual(already.label, spanish ? "Este cambio ya se deshizo." : "This change was already undone.")
        tap(app.buttons["sharedUndo.cancel"]); tap(app.buttons["sharedShop.foodQuantities"], initialSearchDirection: .towardStart)
        assertUnknownTotal(spanish: spanish)
        assertText("Original source wording"); assertText("Later apples — amount unknown")
        counts(previews: 2, posts: 2, writes: 1, retries: 1)
        capture("Operation-Undo-\(language)-exact-retry-and-survivors")
    }
    private func assertUnknownTotal(spanish: Bool) {
        let expected = spanish ? "Cantidad desconocida (unidades)" : "Unknown amount (count)"
        // LabeledContent can expose its value on the row instead of as a
        // standalone StaticText. Match complete wording, never a substring.
        let exactCopy = NSPredicate(format:
            "label == %@ OR (label == %@ AND value == %@) OR label == %@ OR label == %@",
            expected, "Later apples", expected, "Later apples, " + expected, "Later apples\n" + expected)
        let total = app.descendants(matching: .any).matching(exactCopy).firstMatch
        // Current tracking puts basket and checkout before these subtotals.
        reveal(total, initialSearchDirection: .towardEnd)
        XCTAssertTrue(exactCopy.evaluate(with: total), "Complete localized unknown-total wording must match")
        XCTAssertTrue(app.frame.contains(total.frame), "Complete unknown-total value must fit the app")
        XCTAssertGreaterThan(total.frame.height, 0)
        capture("Operation-Undo-\(spanish ? "es" : "en")-unknown-total-copy")
    }
    private func waitForShop(spanish: Bool) {
        XCTAssertTrue(app.navigationBars[spanish ? "Compra compartida del hogar" : "Shared household shop"].waitForExistence(timeout: 25), app.debugDescription)
    }
    private func openHistory() {
        tap(app.buttons["sharedShop.savedChanges"])
        XCTAssertTrue(app.staticTexts["sharedUndo.loaded"].waitForExistence(timeout: 20), app.debugDescription)
    }
    private func openCandidate(spanish: Bool) {
        tap(app.buttons["sharedUndo.history." + target])
        XCTAssertTrue(app.navigationBars[spanish ? "Revisar lo que se deshará" : "Review undo"].waitForExistence(timeout: 20), app.debugDescription)
    }
    private func enterPacks(amount: String = "4") {
        setSwitch("sharedUndo.pack." + wraps + ".unknown", on: false)
        fill(amount, id: "sharedUndo.pack." + wraps + ".amount")
        tap(app.buttons["sharedUndo.done"]); XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        setSwitch("sharedUndo.pack." + apples + ".acceptUnknown", on: true)
    }
    private func assertReview(spanish: Bool) {
        let apply = app.buttons["sharedUndo.apply"]; reveal(apply); XCTAssertFalse(apply.isEnabled)
        let survivor = element("sharedUndo.after.source.00000000-0000-4000-8000-000000000012")
        reveal(survivor, initialSearchDirection: .towardStart); XCTAssertTrue(survivor.exists && survivor.isHittable)
        assertText(spanish ? "Cantidades utilizables revisadas" : "Reviewed usable amounts")
        assertText(spanish ? "Se aceptaron las cantidades o restricciones desconocidas de este artículo." : "Unknown quantities or restrictions accepted for this item.")
        // Both complete checkout values are rendered from the reviewed server facts.
        for (amount, direction) in [("$9.00", SearchDirection.towardStart), ("$7.00", .towardEnd)] {
            let money = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", amount)).firstMatch
            reveal(money, initialSearchDirection: direction); XCTAssertTrue(money.isHittable, amount)
        }
    }
    private func counts(previews: Int, posts: Int, writes: Int, retries: Int) {
        let value = "Previews: \(previews); POSTs: \(posts); Writes: \(writes); Exact retries: \(retries)"
        let predicate = NSPredicate(format: "exists == true AND label == %@", value)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app.staticTexts["fixture.operationUndo.counts"])], timeout: 15), .completed)
        XCTAssertFalse(app.staticTexts["fixture.operationUndo.rejected"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["fixture.failure"].exists, app.debugDescription)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private enum SearchDirection { case towardStart, towardEnd }
    private func tap(_ target: XCUIElement, initialSearchDirection: SearchDirection = .towardEnd) {
        reveal(target, initialSearchDirection: initialSearchDirection)
        XCTAssertTrue(target.isHittable)
        target.tap()
    }
    private func assertText(_ text: String, initialSearchDirection: SearchDirection = .towardEnd) {
        let target = app.staticTexts.matching(identifier: text).firstMatch
        reveal(target, initialSearchDirection: initialSearchDirection)
        XCTAssertTrue(target.isHittable, text)
    }
    private func assertField(_ id: String, value: String, initialSearchDirection: SearchDirection = .towardEnd) {
        let field = app.textFields[id]
        reveal(field, initialSearchDirection: initialSearchDirection)
        XCTAssertEqual(field.value as? String, value)
    }
    private func fill(_ value: String, id: String, initialSearchDirection: SearchDirection = .towardEnd) {
        let field = app.textFields[id]
        tap(field, initialSearchDirection: initialSearchDirection)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        if let old = field.value as? String, old != field.placeholderValue, !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(value); XCTAssertEqual(field.value as? String, value)
    }
    private func setSwitch(_ id: String, on: Bool) {
        let toggle = app.switches[id]; reveal(toggle)
        let expected = on ? "1" : "0"
        if toggle.value as? String != expected {
            // Target the native thumb. A rightward drag can also start a
            // navigation gesture in this form.
            XCTAssertEqual(toggle.switches.count, 1, id)
            let control = toggle.switches.firstMatch
            XCTAssertTrue(control.isEnabled && control.isHittable, id)
            XCTAssertEqual(control.value as? String, on ? "0" : "1", id)
            let left = control.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            let right = control.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            if on {
                left.tap()
            } else {
                right.press(forDuration: 0.1, thenDragTo: left)
            }
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, id)
        }
        XCTAssertEqual(toggle.value as? String, expected, id)
    }
    private func reveal(_ target: XCUIElement, initialSearchDirection: SearchDirection = .towardEnd) {
        let startsBySwipingUp = initialSearchDirection == .towardEnd
        for _ in 0..<30 {
            let area = scrollableArea(), exists = target.exists
            let frame = exists ? target.frame : .zero
            if !frame.isEmpty && frame.minY >= area.minY && frame.maxY <= area.maxY {
                if target.isHittable { return }
            } else if !frame.isEmpty && target.elementType == .button,
                      ["sharedUndo.cancel", "sharedUndo.done"].contains(target.identifier),
                      app.frame.contains(frame), target.isHittable {
                // Toolbar buttons sit outside the scrolling viewport.
                return
            }
            // Virtualized rows may be more than six swipes away. Keep the
            // journey's requested direction until a target frame is available.
            let upward = exists && !frame.isEmpty ? frame.midY > area.midY : startsBySwipingUp
            let origin = app.coordinate(withNormalizedOffset: .zero), bounds = app.frame
            let high = area.minY + area.height * 0.18, low = area.minY + area.height * 0.82
            origin.withOffset(CGVector(dx: area.minX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: area.minX - bounds.minX, dy: (upward ? high : low) - bounds.minY)))
        }
        captureFailureHierarchy()
        XCTFail("Missing fully visible control: " + target.debugDescription)
    }
    private func scrollableArea() -> CGRect {
        let snapshot = try? app.snapshot(), bounds = snapshot?.frame ?? app.frame
        var bottom = bounds.maxY - 30, top = bounds.minY + 95, nodes = snapshot.map { [$0] } ?? []
        while let node = nodes.popLast() {
            if !node.frame.isEmpty && node.frame.intersects(bounds) {
                if node.elementType == .navigationBar { top = max(top, node.frame.maxY + 8) }
                if node.elementType == .keyboard { bottom = min(bottom, node.frame.minY - 12) }
                if node.identifier == "sharedUndo.done" { bottom = min(bottom, node.frame.minY - 8) }
            }
            nodes.append(contentsOf: node.children)
        }
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func captureFailureHierarchy() {
        guard !capturedFailureHierarchy else { return }
        capturedFailureHierarchy = true
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "Operation-Undo-first-failure-hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
