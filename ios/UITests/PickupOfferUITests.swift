import XCTest

/// Real visible local journey; all data uses the isolated DEBUG UI-test workspace.
@MainActor final class PickupOfferUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Offer-review-failure") }
        app.terminate()
    }

    func testSavedOfferReopensAndUpdatesResponseAfterRestart() throws {
        launch(reset: true)
        tap(app.buttons["openPickupList"]); tap(app.buttons["ledgerStartShop"])
        fill("Offer review pickup", into: "ledgerShopName"); tap(app.buttons["ledgerCreateShop"])
        tap(app.buttons["ledgerImport"]); fill("2 wraps", into: "ledgerImportText", fieldType: .textView)
        tap(app.buttons["ledgerReviewImport"]); tap(app.buttons["ledgerCommitImport"])
        shopRoot()
        tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"])
        let apply = app.buttons["Apply reviewed checkout copy"]
        reveal(apply)
        // XCTest can report a partly clipped row as hittable and tap its edge.
        // Scroll the action's center above the bottom tab bar before applying.
        if apply.frame.midY > scrollableArea().maxY { scrollContent(upward: true) }
        let center = CGPoint(x: apply.frame.midX, y: apply.frame.midY)
        XCTAssertTrue(apply.isHittable && scrollableArea().contains(center), apply.debugDescription)
        apply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let checkout = app.buttons["Review whole checkout"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 8), "Applying the reviewed copy should open the pickup")
        tap(checkout)
        fill("Family market", into: "Store", replacing: true)
        fill("Main branch", into: "Branch", replacing: true)
        fill("Tuesday 5 PM", into: "Pickup or delivery slot", replacing: true)
        fill("Retailer preview", into: "Source of these prices", replacing: true)
        enableSwitch("Retailer total already includes all charges")
        fill("3.00", into: "Inclusive total")
        tap(app.buttons["Save and evaluate checkout"])
        back(to: "Prepare retailer handoff")
        tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["Freeze reviewed basket"])
        tap(app.buttons["I placed this order"])
        back(to: "Review a store offer")
        tap(app.buttons["Review a store offer"])
        tap(app.buttons["pickup.offer.new"])
        choose("Original line", value: "wraps")
        fill("Large wrap pack", into: "pickup.offer.replacement")
        fill("2", into: "pickup.offer.required")
        fill("0", into: "pickup.offer.remaining")
        fill("4.00", into: "pickup.offer.price")
        fill("3.00", into: "pickup.offer.ceiling")
        fill("1", into: "pickup.offer.usable")
        tap(app.buttons["pickup.offer.retained.kind"]); tap(app.buttons["Exact price"])
        fill("0.00", into: "pickup.offer.retained.lower")
        fill("3.00", into: "pickup.offer.lineAllowance")
        let dish = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pickup.offer.dish.")).firstMatch
        tap(dish); tap(app.buttons["Approved for this dish"])
        tap(app.buttons["pickup.offer.otherCost.kind"]); tap(app.buttons["Exact price"])
        fill("3.00", into: "pickup.offer.otherCost.lower")
        fill("6.00", into: "pickup.offer.wholeCap")
        fill("Reviewed retained checkout charges excluding replacement", into: "pickup.offer.checkoutSource", replacing: true)
        fill("Please leave unresolved", into: "pickup.offer.preference")
        tap(app.buttons["pickup.offer.review"])
        assertElementContains("pickup.offer.forecast.combined", "$7.00")
        assertElementContains("pickup.offer.forecast.checkout", "exceeds")
        assertElementContains("pickup.offer.forecast.overage", "$1.00")
        assertElementContains("pickup.offer.forecast.noteCeiling", "$3.00")
        capture("Offer-reviewed-joint-cost-overage")
        let shortfall = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pickup.offer.forecast.shortfall.")).firstMatch
        reveal(shortfall); XCTAssertTrue(shortfall.label.contains(": 1 "), shortfall.label)
        capture("Offer-reviewed-uncovered-quantity")
        approveOffer()
        tap(app.buttons["pickup.offer.save"])
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pickup.offer.edit.")).firstMatch
        reveal(edit)
        let editID = edit.identifier
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pickup.offer.edit.")).count, 1)
        capture("Offer-saved-with-price-warning")
        restart()
        // Current app snapshots expose the saved deadline on the normal Shop route.
        // The untouched editor cutoff is past by restart; arrival remains a separate review.
        assertElementContains("shop.resumeOfferStatus", "Await pickup")
        assertText("Large wrap pack")
        assertText("Cutoff:", hasPrefix: true)
        capture("Offer-expired-resume-card-after-restart")
        tap(app.buttons["shop.resumeOffer"])
        XCTAssertTrue(app.navigationBars["What came home"].waitForExistence(timeout: 8))
        capture("Offer-resume-opens-actual-arrival")
        tap(app.navigationBars["What came home"].buttons["BackButton"])
        XCTAssertTrue(app.navigationBars["Shop"].waitForExistence(timeout: 8))
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Review a store offer"])
        // Match each rendered fact directly. A containing query selects the
        // much taller saved-facts ancestor and tests the wrong visible frame.
        assertText("Combined expected cost: $7.00")
        assertText("Reviewed maximum in the retailer note: $3.00")
        tap(app.buttons[editID])
        XCTAssertEqual(app.textFields["pickup.offer.replacement"].value as? String, "Large wrap pack")
        fill("Retailer response still pending", into: "pickup.offer.response")
        tap(app.buttons["pickup.offer.review"])
        approveOffer()
        tap(app.buttons["pickup.offer.save"])
        reveal(app.buttons[editID])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pickup.offer.edit.")).count, 1)
        assertText("Retailer response: Retailer response still pending")
        tap(app.buttons["Copy retailer note without changing decision"])
        reveal(app.buttons[editID])
        capture("Offer-updated-after-restart-and-copied")
        restart()
        tap(app.buttons["Pickup, repairs and handoffs"])
        tap(app.buttons["Review a store offer"])
        tap(app.buttons[editID])
        reveal(app.textFields["pickup.offer.response"])
        XCTAssertEqual(app.textFields["pickup.offer.response"].value as? String, "Retailer response still pending")
        fill("Discard this edit", into: "pickup.offer.response", replacing: true)
        tap(app.buttons["pickup.offer.cancel"])
        tap(app.buttons[editID])
        reveal(app.textFields["pickup.offer.response"])
        XCTAssertEqual(app.textFields["pickup.offer.response"].value as? String, "Retailer response still pending")
        capture("Offer-cancel-keeps-saved-response")
    }

    private func approveOffer() {
        let control = app.switches["pickup.offer.approve"]
        reveal(control)
        if control.value as? String == "0" { control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(control.value as? String, "1")
    }
    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(element("newComparison").waitForExistence(timeout: 15))
    }
    private func restart() { app.terminate(); launch(reset: false) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control)
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false, fieldType: XCUIElement.ElementType = .textField) {
        let field = app.descendants(matching: fieldType).matching(identifier: id).firstMatch
        tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.isHittable { done.tap() }
    }
    private func reveal(_ target: XCUIElement) {
        for attempt in 0..<64 {
            // A lazy Form may not expose an offscreen row yet. Asking for
            // isHittable first makes XCTest retry a missing element before
            // every scroll. Resolve existence once, then test real visibility.
            let exists = target.exists
            if exists && target.isHittable { return }
            let area = scrollableArea()
            let upward: Bool
            if exists {
                let frame = target.frame
                upward = frame.isEmpty ? attempt < 32 : frame.midY > area.midY
            } else { upward = attempt < 32 }
            scrollContent(upward: upward, area: area)
        }
        XCTAssertTrue(target.isHittable, "Missing actionable UI element: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        // Navigation and sheet transitions can replace a bar between separate
        // XCUI queries. Measure the keyboard and bars from one captured tree.
        let snapshot = try? app.snapshot()
        let bounds = snapshot?.frame ?? app.frame
        var keyboardTop = bounds.maxY
        var barBottom = bounds.minY + 88
        var elements = snapshot.map { [$0] } ?? []
        while let element = elements.popLast() {
            let frame = element.frame
            if frame.height > 0 && frame.intersects(bounds) {
                if element.elementType == .keyboard { keyboardTop = min(keyboardTop, frame.minY) }
                if element.elementType == .navigationBar { barBottom = max(barBottom, frame.maxY) }
            }
            elements.append(contentsOf: element.children)
        }
        let top = max(bounds.minY + 88, min(barBottom + 12, keyboardTop - 140))
        let bottom = min(bounds.maxY - 100, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool, area: CGRect? = nil) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = area ?? scrollableArea(), bounds = app.frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertText(_ text: String, hasPrefix: Bool = false) {
        let predicate = NSPredicate(format: hasPrefix ? "label BEGINSWITH %@" : "label == %@", text)
        reveal(app.staticTexts.matching(predicate).firstMatch)
    }
    private func assertElementContains(_ id: String, _ text: String) {
        let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text), target.label)
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        tap(app.buttons[value])
    }
    private func dinnerRoot() { returnToVisibleAnchor(element("dinnerLibrary")) }
    private func shopRoot() {
        tap(app.tabBars.buttons["Shop"])
        returnToVisibleAnchor(element("newComparison"))
    }
    private func back(to label: String) {
        returnToVisibleAnchor(app.buttons.matching(identifier: label).firstMatch)
    }
    private func returnToVisibleAnchor(_ target: XCUIElement) {
        for _ in 0..<8 {
            if target.exists {
                // A covered parent can still exist in the accessibility tree.
                // Scroll only to reveal it, and return only if it is actionable.
                for _ in 0..<2 {
                    if target.isHittable { return }
                    scrollContent(upward: true)
                }
                for _ in 0..<4 {
                    if target.isHittable { return }
                    scrollContent(upward: false)
                }
                if target.isHittable { return }
            }
            let leading = app.navigationBars.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && $0.identifier != "settings" && $0.frame.midX < app.frame.midX
            }.sorted { $0.frame.minX < $1.frame.minX }
            guard let button = leading.first else {
                XCTFail("No visible back control while returning to \(target)")
                return
            }
            button.tap()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Root or destination is not visible: \(target)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
