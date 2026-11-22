import XCTest

/// Shipping app, ordinary typed entry and native navigation. Relaunch uses the
/// same durable workspace with no prefilled model or replacement app root.
@MainActor final class NavigationRestorationUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app.terminate() }

    func testFourAdultDestinationsAndPantryRestoreWithoutEnablingInventory() {
        launch(reset: true)
        let tabs = app.tabBars.buttons
        XCTAssertEqual(tabs.allElementsBoundByIndex.map(\.label), ["Shop", "Pantry", "Dinners", "Records"])
        XCTAssertTrue(tabs["Shop"].isSelected)
        tap(tabs["Pantry"])
        XCTAssertTrue(app.buttons["pantry.setup.apply"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["pantry.setup.firstFood"].label, "Add my first food")
        capture("Market Journal - Pantry first use")
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(tabs["Pantry"].isSelected)
        XCTAssertTrue(app.buttons["pantry.setup.apply"].waitForExistence(timeout: 10))
        tap(tabs["Shop"])
        XCTAssertTrue(element("quickGrocery.name").waitForExistence(timeout: 10))
        capture("Market Journal - Shop")
        tap(tabs["Dinners"])
        XCTAssertTrue(app.staticTexts["No dinner planned"].waitForExistence(timeout: 8))
        capture("Market Journal - Dinners")
        tap(tabs["Records"])
        XCTAssertTrue(app.buttons["records.startComparison"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["records.sharedPlacementReports"].exists)
        XCTAssertFalse(app.buttons["records.priceBudgetHistory"].exists)
        XCTAssertFalse(app.buttons["Family decision history"].exists)
        capture("Market Journal - Records")
    }

    func testShopPreviewOpensQuantityWithoutCheckingAndRestoresOnlyTheCheckedGrocery() {
        launch(reset: true)
        let entry = element("quickGrocery.name")
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        capture("Market Journal - Shop first use")
        tap(entry)
        for name in ["Pears", "Eggs"] {
            entry.typeText(name + "\n")
            let receipt = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                          "quickGrocery.undo", name)).firstMatch
            XCTAssertTrue(receipt.waitForExistence(timeout: 8))
        }
        tap(app.buttons["quickGrocery.dismissKeyboard"])
        let check = app.buttons["Check Pears"]
        let otherCheck = app.buttons["Check Eggs"]
        reveal(check)
        let id = check.identifier.replacingOccurrences(of: "shop.check-", with: "")
        let inspect = app.buttons["shop.inspect-" + id]
        XCTAssertTrue(inspect.isHittable)
        XCTAssertGreaterThanOrEqual(check.frame.width, 44)
        XCTAssertGreaterThanOrEqual(inspect.frame.height, 44)
        XCTAssertFalse(check.frame.intersects(inspect.frame))
        capture("Market Journal - Shop with two groceries")
        tap(inspect)
        let details = app.navigationBars["Item details"]
        XCTAssertTrue(details.waitForExistence(timeout: 8))
        tap(app.buttons["ledgerEditQuantityAndNotes"])
        let editor = app.navigationBars["Quantity and notes"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        capture("Market Journal - Grocery quantity and notes")
        tap(editor.buttons["Cancel"])
        tap(details.buttons["Close"])
        XCTAssertTrue(check.waitForExistence(timeout: 8))
        let before = otherCheck.frame.midY
        tap(check)
        let undo = app.buttons["shop.undoCheck"]
        XCTAssertTrue(undo.waitForExistence(timeout: 8))
        XCTAssertTrue(undo.label.contains("Pears"))
        let checked = app.buttons["shop.check-" + id]
        XCTAssertTrue(checked.isSelected)
        XCTAssertTrue(checked.label.contains("Pears"))
        XCTAssertTrue(otherCheck.isHittable)
        let after = otherCheck.frame.midY
        XCTAssertEqual(before, after, accuracy: 2, "Checking Pears must leave the center of the Eggs target in place.")
        let geometry = XCTAttachment(string: "Eggs center before: \(before) pt. After: \(after) pt.")
        geometry.name = "Shop neighbor tap center"; geometry.lifetime = .keepAlways; add(geometry)
        capture("Market Journal - Checked pears beside eggs")
        app.terminate()
        launch(reset: false)
        XCTAssertFalse(check.exists)
        XCTAssertTrue(otherCheck.exists)
        XCTAssertTrue(undo.waitForExistence(timeout: 8))
        XCTAssertTrue(undo.label.contains("Pears"))
        tap(undo)
        XCTAssertTrue(check.waitForExistence(timeout: 8))
        XCTAssertTrue(otherCheck.exists)
    }

    func testShopShowsRemainingQuantityAfterAPartialPick() {
        launch(reset: true)
        let entry = element("quickGrocery.name")
        tap(entry)
        entry.typeText("Pears\n")
        XCTAssertTrue(app.buttons["quickGrocery.undo"].waitForExistence(timeout: 8))
        tap(app.buttons["quickGrocery.dismissKeyboard"])
        let inspect = app.buttons["Inspect Pears"]
        tap(inspect)
        let details = app.navigationBars["Item details"]
        tap(app.buttons["ledgerEditQuantityAndNotes"])
        let quantity = app.textFields["Quantity (optional)"]
        quantity.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        app.typeText("4")
        tap(app.buttons["ledgerContributionDone"])
        tap(app.buttons["ledgerSaveContributionChanges"])
        XCTAssertTrue(details.waitForExistence(timeout: 8))
        tap(details.buttons["Close"])
        XCTAssertTrue(inspect.waitForExistence(timeout: 8))
        XCTAssertTrue((inspect.value as? String)?.contains("4") == true)
        let amountID = inspect.identifier.replacingOccurrences(of: "shop.inspect-", with: "shop.editAmount-")
        let directAmount = app.buttons[amountID]
        XCTAssertTrue(directAmount.isHittable)
        XCTAssertFalse(directAmount.frame.intersects(inspect.frame))
        capture("Market Journal - Four pears in Shop")
        tap(directAmount)
        XCTAssertTrue(app.navigationBars["Quantity and notes"].waitForExistence(timeout: 8))
        XCTAssertEqual(quantity.value as? String, "4")
        tap(app.buttons["Cancel"])
        XCTAssertTrue(app.buttons["Check Pears"].waitForExistence(timeout: 8))
        tap(app.buttons["openPickupList"])
        tap(app.buttons["ledgerInStore"])
        let tripRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "tripDetails-", "Pears")).firstMatch
        tap(tripRow)
        tap(app.buttons["tripPickPart"])
        let picked = app.textFields["tripPartialAmount"]
        tap(picked)
        picked.typeText("1")
        tap(app.buttons["tripPartKeyboardDone"])
        tap(app.buttons["tripSavePart"])
        let store = app.navigationBars["Shop in store"]
        tap(store.buttons["Done"])
        tap(app.navigationBars["Shopping list"].buttons.firstMatch)
        XCTAssertTrue(inspect.waitForExistence(timeout: 8))
        reveal(inspect)
        let amount = inspect.value as? String ?? ""
        XCTAssertTrue(amount.contains("1") && amount.contains("3"), amount)
        XCTAssertTrue(app.buttons["Check Pears"].exists)
        capture("Market Journal - Shop after picking one of four pears")
    }

    func testNamedCheckUndoSurvivesRelaunchAndRestoresOnlyTheCheckedRow() {
        launch(reset: true)
        let entry = element("quickGrocery.name")
        tap(entry)
        entry.typeText("milk\n")
        XCTAssertTrue(app.buttons["quickGrocery.undo"].waitForExistence(timeout: 10))
        entry.typeText("eggs\n")
        let eggsAdded = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "quickGrocery.undo", "eggs")).firstMatch
        XCTAssertTrue(eggsAdded.waitForExistence(timeout: 10))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let viewList = app.buttons["openPickupList"]
        XCTAssertTrue(viewList.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "openPickupList").count, 1)
        XCTAssertEqual(viewList.label, "View shopping list")
        XCTAssertLessThanOrEqual(viewList.frame.maxY, keyboard.frame.minY)
        capture("Quick entry with View shopping list and Undo")
        viewList.tap()
        let milk = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "ledgerCheck-", "milk")).firstMatch
        let eggs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "ledgerCheck-", "eggs")).firstMatch
        XCTAssertTrue(milk.waitForExistence(timeout: 10))
        let milkID = milk.identifier, eggsID = eggs.identifier
        let inspect = app.fullListGrocery(labeled: "Inspect milk")
        XCTAssertTrue(inspect.wait(for: \.isHittable, toEqual: true, timeout: 8))
        XCTAssertGreaterThanOrEqual(inspect.frame.height, 44)
        inspect.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        let detail = app.navigationBars["Item details"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["milk"].exists)
        tap(detail.buttons.firstMatch)
        XCTAssertTrue(detail.waitForNonExistence(timeout: 8))
        let department = app.buttons["Department for milk"]
        XCTAssertTrue(department.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        XCTAssertGreaterThanOrEqual(department.frame.width, 44)
        XCTAssertGreaterThanOrEqual(department.frame.height, 44)
        department.tap()
        tap(app.buttons["Bakery"])
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Bakery"), object: department)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        tap(milk)
        let undo = app.buttons["ledgerUndoCheck"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.label.contains("milk"))
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        tap(undo)
        XCTAssertTrue(app.buttons[milkID].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[eggsID].exists)
        XCTAssertFalse(undo.exists)
    }

    func testInListPickupCreationAndSwitchRestoreTheChosenList() {
        launch(reset: true)
        tap(app.buttons["openPickupList"])
        let picker = app.buttons["ledgerShopPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        let firstName = picker.label
        let secondName = "Second pickup"
        let search = app.textFields["ledgerSearch"]
        tap(search)
        search.typeText("rice")
        XCTAssertEqual(search.value as? String, "rice")
        tap(picker)
        tap(app.buttons["Start another pickup"])
        let name = element("ledgerShopName")
        tap(name)
        name.typeText(secondName)
        tap(app.buttons["ledgerCreateShop"])
        app.assertSelectedShoppingList(named: secondName)
        XCTAssertTrue(search.exists && search.value as? String == search.placeholderValue)
        app.terminate(); launch(reset: false)
        app.assertSelectedShoppingList(named: secondName)
        capture("Second pickup restored after process relaunch")
        tap(picker)
        tap(app.buttons[firstName])
        app.assertSelectedShoppingList(named: firstName)
        app.terminate(); launch(reset: false)
        app.assertSelectedShoppingList(named: firstName)
    }

    func testKillRelaunchRestoresRecordsDetailAndIndependentShoppingList() {
        launch(reset: true)
        tap(element("openPickupList"))
        let pickupName = "Restoration Saturday pickup"
        app.renameSelectedPickup(pickupName)
        app.assertSelectedShoppingList(named: pickupName)
        tap(app.tabBars.buttons["Records"])
        tap(app.tabBars.buttons["Shop"])
        app.assertSelectedShoppingList(named: pickupName)
        tap(app.navigationBars["Shopping list"].buttons["Shop"])
        tap(element("newComparison"))
        fillComparisonField("Restoration family wraps", into: "itemName")
        fillComparisonField("12", into: "needed"); fillComparisonField("8", into: "aQuantity"); fillComparisonField("3", into: "aPrice")
        fillComparisonField("6", into: "bQuantity"); fillComparisonField("2", into: "bPrice")
        tap(element("compare")); tap(element("saveComparison"))
        tap(app.tabBars.buttons["Records"]); tap(element("savedComparison"))
        XCTAssertTrue(app.buttons["editComparison"].waitForExistence(timeout: 8))
        capture("Records detail before process termination")
        app.terminate(); launch(reset: false)
        XCTAssertTrue(app.tabBars.buttons["Records"].isSelected)
        XCTAssertTrue(app.buttons["editComparison"].waitForExistence(timeout: 10), "The same saved comparison should reopen without selecting its row again")
        XCTAssertTrue(app.staticTexts["Restoration family wraps"].exists)
        capture("Records detail restored after process relaunch")
        // Open the independent shop route, then kill there too.
        tap(app.tabBars.buttons["Shop"])
        let back = app.navigationBars.buttons["Shop"]
        if back.exists { tap(back) }
        tap(element("openPickupList"))
        app.assertSelectedShoppingList(named: pickupName)
        app.terminate(); launch(reset: false)
        XCTAssertTrue(app.tabBars.buttons["Shop"].isSelected)
        app.assertSelectedShoppingList(named: pickupName)
        tap(app.tabBars.buttons["Records"])
        XCTAssertTrue(app.buttons["editComparison"].waitForExistence(timeout: 8), "Both explicit stacks survive the second process death")
        XCTAssertTrue(app.staticTexts["Restoration family wraps"].exists)
        capture("Independent Shop and Records stacks restored")
    }
    func testKillRelaunchRestoresSelectedDinnersTabWithoutRestoringUnsavedComparison() {
        launch(reset: true)
        tap(element("newComparison")); fillComparisonField("Unsaved draft", into: "itemName")
        tap(app.tabBars.buttons["Dinners"])
        app.terminate(); launch(reset: false)
        XCTAssertTrue(app.tabBars.buttons["Dinners"].isSelected)
        tap(app.tabBars.buttons["Shop"])
        XCTAssertTrue(element("newComparison").waitForExistence(timeout: 8))
        XCTAssertFalse(element("itemName").exists, "Transient unsaved forms do not become restored records")
        capture("Selected Dinners tab restored")
    }
    func testColdCaptureShortcutOpensEntryForTheCurrentPickup() throws {
        launch(reset: true)
        tap(app.buttons["openPickupList"])
        XCTAssertTrue(app.buttons["ledgerShopPicker"].waitForExistence(timeout: 8))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-workspace" }
        let shortcut = try XCTUnwrap(URL(string: "roominthecart-debug://surface/capture"))
        app.open(shortcut)
        XCTAssertTrue(app.textViews["ledgerImportText"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["ledgerCommitImport"].exists)
    }

    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Shop"].waitForExistence(timeout: 15))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ element: XCUIElement) { reveal(element); XCTAssertTrue(element.isHittable, element.debugDescription); element.tap() }
    private func fillComparisonField(_ text: String, into id: String) {
        let field: XCUIElement
        let bar = app.navigationBars["Compare packs"]
        if id == "itemName" {
            XCTAssertTrue(bar.waitForExistence(timeout: 8), "The comparison editor must open after the Shop tap")
            // The multiline name is a TextView on iOS 17 and a TextField on newer iOS.
            // It starts at the top. Swiping before the push settles scrolls it out of view.
            let inputTypes: [XCUIElement.ElementType] = [.textField, .textView]
            field = app.descendants(matching: .any).matching(identifier: id)
                .matching(NSPredicate(format: "elementType IN %@", inputTypes.map(\.rawValue))).firstMatch
            XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 8),
                          "The new comparison must start with the accessible item name showing")
        } else {
            field = app.textFields[id]
            reveal(field)
        }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let doneID = "comparison.done." + id
        let done = bar.buttons[doneID]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable, "Expected Done in the comparison toolbar for " + id)
        app.typeText(text)
        XCTAssertEqual(field.value as? String, text)
        XCTAssertTrue(app.waitForDoneAboveKeyboard(identifier: doneID))
        done.tap()
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: doneID))
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let bounds = app.frame
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.midX, dy: bounds.height * 0.68))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.midX, dy: bounds.height * 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, element.debugDescription)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor
extension XCUIApplication {
    /// The history footer retains its scroll position while a restored grocery returns to the active section above.
    func revealRestoredGrocery(_ grocery: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(navigationBars["List history"].waitForNonExistence(timeout: 8), file: file, line: line)
        let list = collectionViews.firstMatch
        for _ in 0..<8 {
            if grocery.exists && grocery.isHittable { return }
            list.swipeDown()
        }
        XCTAssertTrue(grocery.exists && grocery.isHittable, "The restored grocery must return to the active list.", file: file, line: line)
    }

    /// The fresh Shop exposes infrequent shortcuts through its disclosure.
    /// Existing pickups already show those actions with the named trip.
    func shopToolButton(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let tool = buttons[identifier]
        let collapsed = buttons.matching(NSPredicate(format: "identifier == %@ AND value IN %@",
            "shop.moreTools", ["Collapsed", "Contraído"])).firstMatch
        if collapsed.exists {
            let scroll = scrollViews["shopContentScroll"]
            for _ in 0..<12 {
                if collapsed.isHittable && scroll.frame.contains(collapsed.frame) { break }
                if collapsed.frame.midY < scroll.frame.minY { scroll.swipeDown() }
                else { scroll.swipeUp() }
            }
            XCTAssertTrue(collapsed.isHittable, "More shopping tools should open from Shop.", file: file, line: line)
            collapsed.tap()
        }
        return tool
    }

    func scrollForm(in area: CGRect, upward: Bool, besideFields: Bool = false) {
        let bounds = frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let origin = coordinate(withNormalizedOffset: .zero)
        let x = besideFields ? area.minX : area.midX
        let start = origin.withOffset(CGVector(dx: x - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: x - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        if besideFields {
            // Drag beside the inputs to avoid selecting text. Stop before lifting
            // the finger so the next field cannot coast behind the navigation bar.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        } else {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    func waitForDoneAboveKeyboard(identifier: String) -> Bool {
        var lastButton: CGRect?
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let screen = try? self.snapshot() else { return false }
            var elements = screen.children
            var keyboard = CGRect.null
            var button = CGRect.null
            while let element = elements.popLast() {
                if element.elementType == .keyboard { keyboard = element.frame }
                if element.elementType == .button && element.identifier == identifier { button = element.frame }
                elements.append(contentsOf: element.children)
            }
            guard !keyboard.isEmpty, screen.frame.intersects(keyboard), !button.isEmpty,
                  button.maxY <= keyboard.minY + 1 else {
                lastButton = nil
                return false
            }
            defer { lastButton = button }
            return lastButton == button
        }, object: nil)
        return XCTWaiter.wait(for: [settled], timeout: 8) == .completed
    }

    /// UIKit may retain a dismissed keyboard below the viewport. Measure one
    /// snapshot instead of waiting for that offscreen accessibility node to vanish.
    func waitForKeyboardDismissal(doneIdentifier: String, timeout: TimeInterval = 5,
                                  checking screenIsReady: @escaping (any XCUIElementSnapshot) -> Bool = { _ in true }) -> Bool {
        let dismissed = NSPredicate { _, _ in
            guard let root = try? self.snapshot(), !root.frame.isEmpty else { return false }
            var nodes = [root]
            while let node = nodes.popLast() {
                nodes.append(contentsOf: node.children)
                guard !node.frame.isEmpty, node.frame.intersects(root.frame) else { continue }
                if node.elementType == .keyboard { return false }
                if node.elementType == .button && node.identifier == doneIdentifier { return false }
            }
            return screenIsReady(root)
        }
        if dismissed.evaluate(with: nil) { return true }
        let ready = XCTNSPredicateExpectation(predicate: dismissed, object: nil)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    func fullListGrocery(labeled label: String) -> XCUIElement {
        collectionViews.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "ledgerInspect-", label
        )).element
    }

    func fullListCheck(labeled label: String) -> XCUIElement {
        collectionViews.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "ledgerCheck-", label
        )).element
    }

    func assertSelectedShoppingList(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(navigationBars["Shopping list"].waitForExistence(timeout: 8), file: file, line: line)
        let selectedPickup = buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "ledgerShopPicker", name
        )).firstMatch
        XCTAssertTrue(selectedPickup.waitForExistence(timeout: 8), "Expected the selected pickup to be \(name)", file: file, line: line)
    }

    func renameSelectedPickup(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = buttons["ledgerShopPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), file: file, line: line)
        picker.tap()
        let rename = buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "ledgerRenameShop", "Rename pickup")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 8), file: file, line: line)
        rename.tap()

        let field = descendants(matching: .any).matching(identifier: "ledgerShopName").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), file: file, line: line)
        field.tap()
        field.press(forDuration: 1.2)
        let selectAll = descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", "Select All",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), file: file, line: line)
        selectAll.tap()
        field.typeText(title)
        XCTAssertEqual(field.value as? String, title, file: file, line: line)
        let done = keyboards.buttons["Done"]
        if done.isHittable { done.tap() }
        buttons["ledgerSaveShopName"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 8), file: file, line: line)
    }
}
