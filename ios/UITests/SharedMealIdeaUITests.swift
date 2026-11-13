#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Actual household UI/client against the isolated .invalid fixture; no live account or private stores.
@MainActor final class SharedMealIdeaUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("S26-household-idea-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "S26-household-idea-failure-accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        app.terminate()
    }
    func testAdultFractionalIdeaCancelApproveThenSeparateProposalAndShopperReview() {
        app.launchArguments = ["--ui-testing", "--shared-idea-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(element("fixture.s26.open").waitForExistence(timeout: 25))
        tap(element("fixture.s26.open"))
        tap(app.buttons["Use editable household idea template"])
        fill("Cancelled household idea", into: "Meal name", replacing: true)
        tap(app.navigationBars.buttons.element(boundBy: 0))
        waitCounter("ideas", "Fixture idea writes: 0")
        waitCounter("proposals", "Fixture meal proposals: 0")
        waitCounter("basket", "Fixture basket writes: 0")

        tap(element("fixture.s26.open"))
        tap(app.buttons["Use editable household idea template"])
        enterValue("Fractional chickpea supper", into: "Meal name", replacing: true)
        fill("Peanuts\nMilk", into: "Shared household exclusions, one per line")
        // Start with the real editable template, then retain and correct one ingredient.
        tap(app.buttons.matching(identifier: "Remove ingredient").firstMatch)
        // The retained ingredient is above the removed row's scroll position.
        for _ in 0..<3 { scrollContent(upward: false) }
        fill("Chickpeas", into: "Ingredient name", replacing: true)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ingredient unit")).firstMatch)
        tap(app.buttons["Cups"])
        enterValue("1/2", into: "Required quantity", replacing: true)
        enterValue("1/4", into: "Household stock in this unit", replacing: true)
        let addReservation = app.buttons["Add named reservation"]
        reveal(addReservation, fullyVisible: true)
        XCTAssertTrue(addReservation.isHittable)
        addReservation.tap()
        enterValue("Protected lunch", into: "Named reservation", replacing: true)
        enterValue("1/8", into: "Reserved quantity", replacing: true)
        enterValue("1", into: "Whole package quantity", replacing: true)
        enterValue("1", into: "Usable yield numerator", replacing: true)
        fill("2", into: "Usable yield denominator", replacing: true)
        fill("Household measured cup and reviewed drained yield", into: "household-idea-evidence", replacing: true)
        XCTAssertEqual(app.textFields["household-idea-evidence"].value as? String, "Household measured cup and reviewed drained yield")
        tap(element("household-idea-save"))
        waitCounter("ideas", "Fixture idea writes: 1")
        assertVisibleSupplyPreview()
        capture("S26-exact-fraction-household-supply-preview")
        enableSwitch("I reviewed these household quantities, exclusions, reservations, and usable packs")
        openAdultApproval()
        tap(element("household-idea-cancel-approval"))
        waitCounter("ideas", "Fixture idea writes: 1")
        waitCounter("proposals", "Fixture meal proposals: 0")
        openAdultApproval()
        tap(app.buttons["Approve meal and quantities"])
        waitCounter("ideas", "Fixture idea writes: 2")
        waitCounter("proposals", "Fixture meal proposals: 0")
        waitCounter("basket", "Fixture basket writes: 0")
        assertText("Approved idea only")
        capture("S26-adult-approved-without-proposal-or-basket-write")

        tap(element("household-idea-propose"))
        assertProposalReady()
        tap(element("household-idea-prepare-proposal"))
        assertText("1/2")
        tap(app.buttons["Cancel proposal review"])
        waitCounter("proposals", "Fixture meal proposals: 0")
        tap(element("household-idea-prepare-proposal"))
        tap(element("household-idea-send-proposal"))
        waitCounter("proposals", "Fixture meal proposals: 1")
        waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-separate-proposal-received-without-basket-write")

        tap(element("fixture.s26.switch"))
        tap(app.buttons["Guest, ingredient, and serving-group proposals"])
        tap(app.buttons["Fractional chickpea supper"])
        assertText("1/2")
        capture("S26-shopper-visible-approved-fractional-proposal")
        tap(element("meal-change-shopper-review"))
        assertText("Entered soup packs")
        // The approved idea does not silently turn unrelated soup packs into
        // chickpeas. Add its own actual pack, leaving its unquoted price unknown.
        tap(app.buttons["Add shared line"])
        let item = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND identifier != %@", "sharedShop.line.", ".item", "sharedShop.line.66666666-6666-4666-8666-666666666666.item")).firstMatch
        // The new row is inserted above Add; keep its identity stable after typing.
        reveal(item, fullyVisible: true, searchTowardEndFirst: false); item.tap(); item.typeText("Chickpeas\n")
        XCTAssertEqual(item.value as? String, "Chickpeas")
        let prices = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "sharedShop.line.", ".price"))
        let chickpeaPrice = prices.allElementsBoundByIndex.first { $0.identifier != "sharedShop.line.66666666-6666-4666-8666-666666666666.price" }
        XCTAssertNotNil(chickpeaPrice)
        guard let chickpeaPrice else { return }
        let chickpeaID = String(chickpeaPrice.identifier.dropFirst("sharedShop.line.".count).dropLast(".price".count))
        XCTAssertNotNil(UUID(uuidString: chickpeaID))
        XCTAssertTrue((chickpeaPrice.value as? String ?? "").isEmpty || chickpeaPrice.value as? String == chickpeaPrice.placeholderValue)
        tap(app.buttons["Review entered shared shop"])
        XCTAssertTrue(app.navigationBars["Food quantities and sources"].waitForExistence(timeout: 12))
        assertText("Represent every basket item with an explicit source")
        waitCounter("basket", "Fixture basket writes: 0")
        tap(app.buttons["sharedTracking.cancel"])
        waitCounter("basket", "Fixture basket writes: 0")
        waitCounter("ideas", "Fixture idea writes: 2"); waitCounter("proposals", "Fixture meal proposals: 1")
        capture("S26-first-adoption-Cancel-preserves-approved-proposal-and-basket")
        tap(app.buttons["Review entered shared shop"])
        XCTAssertTrue(app.navigationBars["Food quantities and sources"].waitForExistence(timeout: 12))
        enterFirstAdoption(chickpeaID: chickpeaID)
        tap(app.buttons["sharedTracking.preview"])
        // The preview begins with basket and checkout facts; the proposed
        // meal facts follow those sections.
        assertText("Fractional chickpea supper")
        assertText("1/2 cups")
        assertText("Peanuts"); assertText("Milk")
        assertText("Unpriced basket items")
        let publish = app.buttons["sharedTracking.apply"]
        reveal(publish); XCTAssertFalse(publish.isEnabled)
        waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-separate-shopper-review-requires-explicit-approval")
        enableSwitch("sharedTracking.ackChanges")
        enableSwitch("sharedTracking.ackPickup")
        reveal(publish); XCTAssertFalse(publish.isEnabled, "The new pack's unknown price still requires explicit review")
        enableSwitch("sharedTracking.acceptUnknown")
        reveal(publish); XCTAssertTrue(publish.isEnabled)
        tap(publish)
        waitCounter("basket", "Fixture basket writes: 1")
        assertText("Shared shop change confirmed")
        assertText("Fixture shared soup")
        assertText("Fractional chickpea supper")
        assertText("1/2 cup")
        assertMealFact("shared-meal-exclusions", contains: "Peanuts, Milk")
        assertMealFact("shared-meal-preparation-minutes", contains: "25")
        waitCounter("ideas", "Fixture idea writes: 2")
        waitCounter("proposals", "Fixture meal proposals: 1")
        waitCounter("basket", "Fixture basket writes: 1")
        capture("S26-shopper-applied-once-original-and-half-cup-meals-retained")
    }
    func testApprovedProposalStaysReadyAfterParentDisappearsAndOnReturn() {
        app.launchArguments = ["--ui-testing", "--shared-idea-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); XCTAssertTrue(element("fixture.s26.open").waitForExistence(timeout: 25))
        tap(element("fixture.s26.open")); tap(app.buttons["Use editable household idea template"])
        fill("Route lifecycle beans", into: "Meal name", replacing: true)
        tap(app.buttons.matching(identifier: "Remove ingredient").firstMatch)
        for _ in 0..<3 { scrollContent(upward: false) }
        enterValue("250", into: "Household stock in this unit", replacing: true)
        enterValue("1", into: "Whole package quantity", replacing: true)
        enterValue("1", into: "Usable yield numerator", replacing: true)
        fill("1", into: "Usable yield denominator", replacing: true)
        fill("Household measured beans and package", into: "household-idea-evidence", replacing: true)
        tap(element("household-idea-save")); waitCounter("ideas", "Fixture idea writes: 1")
        enableSwitch("I reviewed these household quantities, exclusions, reservations, and usable packs")
        openAdultApproval(); tap(app.buttons["Approve meal and quantities"])
        waitCounter("ideas", "Fixture idea writes: 2")
        tap(element("household-idea-propose"))
        assertProposalReady()
        tap(element("household-idea-prepare-proposal"))
        // Preparing inserts the reviewed meal facts above the send action in the Form.
        assertMealFact("shared-meal-preparation-minutes", contains: "25")
        assertText("Ingredient quantity, 250 grams")
        let send = element("household-idea-send-proposal")
        reveal(send, fullyVisible: true)
        XCTAssertTrue(send.isEnabled, "The approved meal must be ready to send after reviewing its facts")
        capture("S26-reviewed-proposal-action-before-cancellation")
        tap(app.buttons["Cancel proposal review"])
        assertProposalReady()
        waitCounter("proposals", "Fixture meal proposals: 0"); waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-approved-proposal-enabled-after-parent-disappearance")
        tap(app.navigationBars.buttons.element(boundBy: 0))
        XCTAssertTrue(app.navigationBars["Household dinner ideas"].waitForExistence(timeout: 5))
        // On return the editor may retain its scroll position at the approved
        // idea detail. Its saved-ideas list is at the top of this same Form.
        let savedIdea = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
                                                         "Route lifecycle beans", "Adult approved")).firstMatch
        reveal(savedIdea, fullyVisible: true, searchTowardEndFirst: false)
        savedIdea.tap()
        tap(element("household-idea-propose")); assertProposalReady()
        waitCounter("ideas", "Fixture idea writes: 2")
        waitCounter("proposals", "Fixture meal proposals: 0"); waitCounter("basket", "Fixture basket writes: 0")
        capture("S26-approved-proposal-reopens-after-authorized-parent-refresh")
    }
    private func enterFirstAdoption(chickpeaID: String) {
        guard let soup = revealManualSource(named: "Entered soup packs") else { return }
        let add = soup.switches["Add a manual need"]
        let manualID = soup.identifier
        if add.value as? String == "0" { add.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(add.value as? String, "1")
        enterTrackingText("Entered soup packs", field: app.textFields[manualID + ".name"])
        enterTrackingText("Entered soup packs", field: app.textFields[manualID + ".original"])
        let unknown = soup.switches["Quantity unknown"]
        reveal(unknown, fullyVisible: true); XCTAssertEqual(unknown.value as? String, "1", "Whole packs do not establish a food amount")
        let matched = soup.switches["I confirm this source matches the selected food"]
        reveal(matched, fullyVisible: true)
        if matched.value as? String == "0" { matched.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(matched.value as? String, "1")
        // The authoritative half-cup meal source has its own explicit basket
        // selection; it must not be matched to the unrelated soup pack.
        let basket = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Basket item", "Choose an item")).firstMatch
        tap(basket); tap(app.buttons["Chickpeas"])
        guard let confirm = revealUnconfirmedSourceMatch() else { return }
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(confirm.value as? String, "1")
        // Resolve the identifier after changing its value, rather than keeping a
        // query that deliberately stops matching once the switch is on.
        // The source's quantity precedes its basket picker and confirmation.
        assertText("1/2 cups", searchTowardEndFirst: false)
        enableSwitch("sharedTracking.pack.66666666-6666-4666-8666-666666666666")
        let unit = app.buttons["sharedTracking.pack." + chickpeaID + ".unit"]
        tap(unit); tap(app.buttons["cups"])
        enableSwitch("sharedTracking.pack." + chickpeaID)
        capture("S26-first-adoption-explicit-soup-unknown-and-half-cup-meal-source")
    }
    private func revealManualSource(named name: String) -> XCUIElement? {
        // A compound ancestor/descendant query can stall while this lazy Form
        // row is offscreen. Find its exact identity in one snapshot before
        // querying the live switch; retain the original 24-scroll budget.
        for attempt in 0...24 {
            guard let snapshot = try? app.snapshot() else {
                XCTFail("Could not inspect manual food sources")
                return nil
            }
            var pending = snapshot.children
            var matches: [(group: XCUIElementSnapshot, toggle: XCUIElementSnapshot)] = []
            while let node = pending.popLast() {
                pending.append(contentsOf: node.children)
                guard node.identifier.hasPrefix("sharedTracking.manual.") else { continue }
                var children = node.children
                var hasName = false
                var toggle: XCUIElementSnapshot?
                while let child = children.popLast() {
                    children.append(contentsOf: child.children)
                    if child.elementType == .staticText && (child.label == name || child.identifier == name) { hasName = true }
                    if child.elementType == .switch && (child.label == "Add a manual need" || child.identifier == "Add a manual need") { toggle = child }
                }
                if hasName, let toggle { matches.append((node, toggle)) }
            }
            guard matches.count <= 1 else {
                XCTFail("Ambiguous manual food source: " + name)
                return nil
            }
            let area = scrollableArea()
            var frame = matches.first?.toggle.frame ?? .zero
            if let match = matches.first, !frame.isEmpty,
               frame.minY >= area.minY, frame.maxY <= area.maxY {
                let group = app.descendants(matching: match.group.elementType).matching(identifier: match.group.identifier).firstMatch
                let add = group.switches["Add a manual need"]
                if add.exists {
                    frame = add.frame
                    if add.isHittable && frame.minY >= area.minY && frame.maxY <= area.maxY { return group }
                }
            }
            guard attempt < 24 else { break }
            let upward = frame.isEmpty ? attempt < 16 : frame.midY > area.midY
            let overflow = upward ? frame.maxY - area.maxY : area.minY - frame.minY
            let distance = !frame.isEmpty && overflow > 0 ? max(24, overflow + 16) : nil
            scrollContent(upward: upward, area: area, distance: distance)
        }
        XCTFail("Missing fully actionable manual food source: " + name)
        return nil
    }
    private func revealUnconfirmedSourceMatch() -> XCUIElement? {
        // Dismissing the basket picker can scroll back to the last edited field.
        // Re-enumerate the named switches after each scroll; the lazy meal row
        // may not exist yet, and index-bound controls can change as rows appear.
        for attempt in 0...24 {
            let target = app.switches.matching(identifier: "I confirm this source matches the selected food")
                .allElementsBoundByIndex.first { $0.value as? String == "0" }
            let area = scrollableArea()
            let frame = target?.frame ?? .zero
            if let target, target.isHittable, !frame.isEmpty,
               frame.minY >= area.minY, frame.maxY <= area.maxY { return target }
            guard attempt < 24 else { break }
            let upward = frame.isEmpty ? attempt < 16 : frame.midY > area.midY
            let overflow = upward ? frame.maxY - area.maxY : area.minY - frame.minY
            let distance = !frame.isEmpty && overflow > 0 ? max(24, overflow + 16) : nil
            scrollContent(upward: upward, area: area, distance: distance)
        }
        XCTFail("The meal source must still require explicit matching and be fully actionable")
        return nil
    }
    private func enterTrackingText(_ text: String, field: XCUIElement) {
        reveal(field, fullyVisible: true); field.tap(); field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists && keyboard.frame.intersects(app.frame) {
            // Scroll the production tracking Form to dismiss its keyboard.
            let area = scrollableArea(), origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: area.midX - app.frame.minX, dy: area.minY + area.height * 0.25 - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: area.midX - app.frame.minX, dy: area.maxY - 8 - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
            // UIKit can retain a keyboard preview below the screen after dismissal.
            // Require an unobscured app, not removal of that offscreen AX element.
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !keyboard.exists || !keyboard.frame.intersects(self.app.frame)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
    }
    private func assertProposalReady() {
        let prepare = element("household-idea-prepare-proposal")
        reveal(prepare, fullyVisible: true)
        XCTAssertTrue(prepare.exists)
        XCTAssertTrue(prepare.isEnabled, "The scoped approved proposal must remain actionable after navigation")
    }
    private func openAdultApproval() {
        let review = element("household-idea-approve")
        reveal(review, fullyVisible: true)
        XCTAssertTrue(review.isEnabled, "The reviewed complete draft must enable adult approval")
        review.tap()
        XCTAssertTrue(app.buttons["Approve meal and quantities"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("household-idea-cancel-approval").waitForExistence(timeout: 5))
    }
    private func waitCounter(_ id: String, _ label: String) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element("fixture.s26." + id))
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 12), .completed)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control, fullyVisible: true)
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func enterValue(_ text: String, into id: String, replacing: Bool = false) {
        let field = app.textFields.matching(identifier: id).firstMatch
        if app.keyboards.firstMatch.exists {
            reveal(field, fullyVisible: true)
            XCTAssertTrue(field.isHittable)
            field.tap()
        } else { tap(field) }
        if replacing, let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            if id == "household-idea-evidence" {
                // This multiline TextField initially places the caret at the
                // start. Use the observed native edit menu to replace all text.
                // Focusing can move the field behind the keyboard; reveal it
                // before the long press rather than scrolling for a menu item.
                reveal(field, fullyVisible: true)
                field.press(forDuration: 1.2)
                let selectAll = app.menuItems["Select All"]
                XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
                XCTAssertTrue(selectAll.isHittable)
                selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            } else { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, id)
        if id == "Shared household exclusions, one per line" {
            XCTAssertEqual(field.label, id)
        }
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        enterValue(text, into: id, replacing: replacing)
        if app.keyboards.firstMatch.exists {
            let done = app.buttons["household-idea-keyboard-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            tap(done)
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false, searchTowardEndFirst: Bool = true) {
        for attempt in 0..<24 {
            let exists = target.exists
            let hittable = exists && target.isHittable
            // Most controls are already actionable. Do not query every keyboard
            // and navigation bar unless a viewport check or scroll is needed.
            if hittable && !fullyVisible { return }
            let area = scrollableArea()
            let frame = exists ? target.frame : .zero
            // A partly visible multiline switch can be hittable while its
            // trailing control is still behind the software keyboard.
            if hittable && frame.minY >= area.minY && frame.maxY <= area.maxY { return }
            let upward: Bool
            if exists && !frame.isEmpty {
                upward = frame.midY > area.midY
            } else { upward = attempt < 16 ? searchTowardEndFirst : !searchTowardEndFirst }
            // A full-height drag can alternate past a nearly visible row.
            // Preserve the full-visibility check and move only its overflow.
            let overflow = upward ? frame.maxY - area.maxY : area.minY - frame.minY
            let distance = exists && !frame.isEmpty && overflow > 0 ? max(24, overflow + 16) : nil
            scrollContent(upward: upward, area: area, distance: distance)
        }
        let area = scrollableArea()
        XCTAssertTrue(target.exists && target.isHittable &&
                      (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)),
                      "Missing fully actionable UI element: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        let bounds = app.frame
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY }.min() ?? bounds.maxY
        let barBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame.maxY }.max() ?? bounds.minY + 88
        // The Form ends above its Done bar. A field behind the bar can still
        // report hittable while a tap leaves the preceding input focused.
        let done = app.buttons["household-idea-keyboard-done"]
        let inputTop = keyboardTop < bounds.maxY && done.exists ? min(keyboardTop, done.frame.minY) : keyboardTop
        let top = max(bounds.minY + 88, min(barBottom + 12, inputTop - 140))
        let bottom = min(bounds.maxY - 100, inputTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool, area observedArea: CGRect? = nil, distance: CGFloat? = nil) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = observedArea ?? scrollableArea(), bounds = app.frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let travel = min(distance ?? (low - high), low - high)
        let startY = upward ? low : high
        let endY = startY + (upward ? -travel : travel)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: startY - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: endY - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertVisibleSupplyPreview() {
        let expected = [
            "Remaining household stock, 1/8",
            "Uncovered quantity, 3/8",
            "Price unresolved. The shopper must separately review shared packs and budget.",
        ]
        for attempt in 0...3 {
            let viewport = scrollableArea()
            let missing = expected.filter { text in
                !app.staticTexts.matching(NSPredicate(format: "label == %@", text)).allElementsBoundByIndex.contains {
                    guard $0.exists else { return false }
                    let frame = $0.frame
                    return viewport.intersects(frame) && frame.minY >= viewport.minY && frame.maxY <= viewport.maxY
                }
            }
            if missing.isEmpty { return }
            guard attempt < 3 else {
                XCTFail("Missing visible household supply text: \(missing.joined(separator: ", "))")
                return
            }
            // The passive supply rows follow the editor. Scan forward without
            // reversing when a visible label does not expose an actionable hit point.
            scrollContent(upward: true)
        }
    }
    private func assertMealFact(_ identifier: String, contains expected: String) {
        let fact = element(identifier)
        reveal(fact)
        XCTAssertTrue((fact.label + " " + (fact.value as? String ?? "")).contains(expected), fact.debugDescription)
    }
    private func assertText(_ text: String, searchTowardEndFirst: Bool = true) {
        let matches = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text))
        if matches.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) { return }
        reveal(matches.firstMatch, searchTowardEndFirst: searchTowardEndFirst)
        XCTAssertTrue(matches.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }), "Missing visible text: \(text)")
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
