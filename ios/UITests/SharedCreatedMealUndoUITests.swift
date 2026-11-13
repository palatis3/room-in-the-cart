#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Creation-specific synthetic HTTP journey through real app screens and the
/// durable outbox. Real service / PG acceptance belongs to the wire suite.
@MainActor final class SharedCreatedMealUndoUITests: XCTestCase {
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
        app.launchEnvironment["RITC_OPERATION_UNDO_CREATION"] = "1"
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { captureFailureHierarchy(); capture("Created-Meal-Undo-failure") }
        app.terminate()
    }
    func testCreatedDinnerUndoCancelRelaunchExactRetryKeepsLunchLaterMealAndStaple() { journey(spanish: false) }
    func testSpanishCreatedDinnerUndoCancelRelaunchExactRetryKeepsLunchLaterMealAndStaple() { journey(spanish: true) }
    private func journey(spanish: Bool) {
        let language = spanish ? "es" : "en"
        app.launchArguments = ["--ui-testing", "--shared-operation-undo-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", spanish ? "es_US" : "en_US", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch(); waitForShop(spanish: spanish); counts(previews: 0, posts: 0, writes: 0, retries: 0)
        assertText("Protected lunch"); assertText("Added taco dinner"); assertText("Later independent soup")
        assertText("Later apples", initialSearchDirection: .towardStart)
        openHistory()
        assertText(spanish ? "Cada cambio guardado indica si se puede deshacer." : "Each saved change shows whether it can be undone.", initialSearchDirection: .towardStart)
        openCandidate(spanish: spanish); assertRemovalCopy(spanish: spanish)
        enterPacks(amount: "8"); tap(element("sharedUndo.preview")); assertCreationReview(spanish: spanish)
        capture("Created-Meal-Undo-\(language)-before-Cancel")
        tap(element("sharedUndo.cancel")); waitForShop(spanish: spanish)
        counts(previews: 1, posts: 0, writes: 0, retries: 0)
        // Cancel returns near the entry link below the meal section.
        assertText("Added taco dinner", initialSearchDirection: .towardStart)
        assertText("Protected lunch", initialSearchDirection: .towardStart)
        assertText("Later independent soup")
        openHistory(); openCandidate(spanish: spanish); assertRemovalCopy(spanish: spanish)
        enterPacks(amount: "8"); tap(element("sharedUndo.preview")); assertCreationReview(spanish: spanish)
        setSwitch("sharedUndo.acknowledged", on: true); tap(element("sharedUndo.apply"))
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        tap(element("sharedUndo.return")); reveal(element("sharedShop.retry"))
        capture("Created-Meal-Undo-\(language)-lost-reply")
        app.terminate(); app.launchEnvironment["RITC_OPERATION_UNDO_RESET"] = "0"; app.launch(); waitForShop(spanish: spanish)
        counts(previews: 2, posts: 1, writes: 1, retries: 0)
        tap(element("sharedShop.retry")); counts(previews: 2, posts: 2, writes: 1, retries: 1)
        XCTAssertTrue(element("sharedShop.retry").waitForNonExistence(timeout: 12))
        assertText(spanish ? "Cambio de compra compartida confirmado" : "Shared shop change confirmed")
        // Confirmation is at the top; basket and then meals follow it.
        assertText("Later apples"); assertText("Protected lunch"); assertText("Later independent soup")
        XCTAssertFalse(app.staticTexts.matching(identifier: "Added taco dinner").firstMatch.exists)
        capture("Created-Meal-Undo-\(language)-surviving-meals")
        openHistory()
        let already = element("sharedUndo.unavailable." + target)
        reveal(already); XCTAssertEqual(already.label, spanish ? "Este cambio ya se deshizo." : "This change was already undone.")
        tap(element("sharedUndo.cancel")); tap(element("sharedShop.foodQuantities"), initialSearchDirection: .towardStart)
        assertUnknownTotal(spanish: spanish)
        assertText("Two wraps held for lunch"); assertText("Later apples — amount unknown")
        counts(previews: 2, posts: 2, writes: 1, retries: 1)
        capture("Created-Meal-Undo-\(language)-exact-retry-and-survivors")
    }
    private func assertRemovalCopy(spanish: Bool) {
        assertText("Added taco dinner", initialSearchDirection: .towardStart)
        let removed = element("sharedUndo.meal.after.removed")
        reveal(removed); XCTAssertEqual(removed.label, spanish ? "Quitar la comida añadida" : "Remove the added meal")
        assertText(spanish ? "Esta comida no estaba planificada antes." : "This meal was not previously planned.")
    }
    private func assertCreationReview(spanish: Bool) {
        let apply = element("sharedUndo.apply"); reveal(apply); XCTAssertFalse(apply.isEnabled)
        source("00000000-0000-4000-8000-000000000022", exact: "Two lunch wraps", direction: .towardStart)
        source("00000000-0000-4000-8000-000000000021", exact: spanish ? "Retirado" : "Removed", direction: .towardEnd)
        source("00000000-0000-4000-8000-000000000012", exact: "Later apples — amount unknown", direction: .towardEnd)
        assertText(spanish ? "Cantidades utilizables revisadas" : "Reviewed usable amounts")
        assertText(spanish ? "Se aceptaron las cantidades o restricciones desconocidas de este artículo." : "Unknown quantities or restrictions accepted for this item.")
        for (amount, direction) in [("$7.00", SearchDirection.towardStart), ("$5.00", .towardEnd)] {
            let money = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", amount)).firstMatch
            reveal(money, initialSearchDirection: direction); XCTAssertTrue(money.isHittable, amount)
        }
        assertRemovalCopy(spanish: spanish)
    }
    private func source(_ id: String, exact: String, direction: SearchDirection) {
        let row = app.staticTexts.matching(identifier: "sharedUndo.after.source." + id)
            .matching(NSPredicate(format: "label == %@", exact)).firstMatch
        reveal(row, initialSearchDirection: direction); XCTAssertEqual(row.label, exact)
    }
    private func assertUnknownTotal(spanish: Bool) {
        let expected = spanish ? "Cantidad desconocida (unidades)" : "Unknown amount (count)"
        // LabeledContent can expose its value on the row instead of as a
        // standalone StaticText. Match complete wording, never a substring.
        let exactCopy = NSPredicate(format:
            "label == %@ OR (label == %@ AND value == %@) OR label == %@ OR label == %@",
            expected, "Later apples", expected, "Later apples, " + expected, "Later apples\n" + expected)
        let total = app.descendants(matching: .any).matching(exactCopy).firstMatch
        // The current tracking screen opens at its top: basket and checkout
        // precede the tracked subtotals, so reveal the complete value below.
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
        tap(element("sharedShop.savedChanges"))
        XCTAssertTrue(element("sharedUndo.loaded").waitForExistence(timeout: 20), app.debugDescription)
    }
    private func openCandidate(spanish: Bool) {
        tap(element("sharedUndo.history." + target))
        XCTAssertTrue(app.navigationBars[spanish ? "Revisar lo que se deshará" : "Review undo"].waitForExistence(timeout: 20), app.debugDescription)
    }
    private func enterPacks(amount: String = "4") {
        setSwitch("sharedUndo.pack." + wraps + ".unknown", on: false)
        fill(amount, id: "sharedUndo.pack." + wraps + ".amount")
        tap(element("sharedUndo.done")); XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        setSwitch("sharedUndo.pack." + apples + ".acceptUnknown", on: true)
    }
    private func counts(previews: Int, posts: Int, writes: Int, retries: Int) {
        let value = "Previews: \(previews); POSTs: \(posts); Writes: \(writes); Exact retries: \(retries)"
        let predicate = NSPredicate(format: "exists == true AND label == %@", value)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element("fixture.operationUndo.counts"))], timeout: 15), .completed)
        XCTAssertFalse(element("fixture.operationUndo.rejected").exists, app.debugDescription)
        XCTAssertFalse(element("fixture.failure").exists, app.debugDescription)
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
        if toggle.value as? String != (on ? "1" : "0") {
            // SwiftUI includes the label in this frame; operate the trailing switch.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", id)
    }
    private func reveal(_ target: XCUIElement, initialSearchDirection: SearchDirection = .towardEnd) {
        let startsBySwipingUp = initialSearchDirection == .towardEnd
        for _ in 0..<30 {
            let area = scrollableArea(), exists = target.exists
            let frame = exists ? target.frame : .zero
            if exists && target.isHittable && !frame.isEmpty && frame.minY >= area.minY && frame.maxY <= area.maxY { return }
            // Toolbars lie outside the content viewport, but their complete
            // button frame still has to fit the app and be directly actionable.
            if exists && target.isHittable && app.frame.contains(frame) && target.elementType == .button && (target.identifier == "sharedUndo.cancel" || target.identifier == "sharedUndo.done") { return }
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
