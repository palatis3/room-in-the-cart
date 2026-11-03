import XCTest

/// Real typed entry through the shipping screens. The DEBUG launch switch only
/// isolates/clears the test database; it does not prefill or seed comparisons.
@MainActor
final class RoomInTheCartUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0 { screenshot("Failure") }
        app.terminate()
    }

    func testKnownComparisonSavesAndReopensWithItemOnlyLimit() throws {
        launch()
        XCTAssertEqual(app.buttons["newComparison"].label, "Compare packs")
        XCTAssertFalse(element("savedComparison").exists)
        openEmptyComparison()
        enterComparison(item: "Family wraps", firstQuantity: "8", cap: "30")
        compare()
        assertScope("Item-only comparison")
        assertContains("whole pickup fits your budget")
        screenshot("English-item-scope")
        assertKnownTotals()
        assertContains("Room within the item limit: $26.00")
        screenshot("English-known-item-only-result")
        saveAndAssertDurableStatus()
        screenshot("English-saved-result")

        app.terminate()
        launch(reset: false)
        reopenSavedRecord(recordsLabel: "Records", item: "Family wraps")
        assertScope("Item-only comparison")
        assertKnownTotals()
        assertSavedStatus("Saved on this iPhone")
        XCTAssertFalse(element("saveComparison").exists)
        screenshot("English-reopened-same-result")
    }

    func testUnknownPackAmountRemainsUnresolvedAfterSaveAndRestart() throws {
        launch()
        openEmptyComparison()
        enterComparison(item: "Unknown yield wraps", firstQuantity: nil)
        compare()
        assertScope("Item-only comparison")
        let unknown = element("aIssue_usableQuantityUnknown")
        reveal(unknown)
        XCTAssertTrue(unknown.label.contains("How much usable food"))
        XCTAssertFalse(element("aTotal").exists)
        XCTAssertFalse(element("aPacks").exists)
        assertMoney("bTotal", amount: "4.00")
        screenshot("Unknown-pack-quantity-result")
        saveAndAssertDurableStatus()

        app.terminate()
        launch(reset: false)
        reopenSavedRecord(recordsLabel: "Records", item: "Unknown yield wraps")
        reveal(element("aIssue_usableQuantityUnknown"))
        XCTAssertFalse(element("aTotal").exists)
        XCTAssertFalse(element("aPacks").exists)
        assertMoney("bTotal", amount: "4.00")
        assertSavedStatus("Saved on this iPhone")
        screenshot("Unknown-pack-quantity-reopened")
    }

    func testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer() throws {
        launch(language: "es")
        XCTAssertEqual(app.buttons["newComparison"].label, "Comparar paquetes")
        openEmptyComparison()
        enterComparison(item: "Abuela’s tortillas", firstQuantity: "8")
        compare()
        assertScope("Comparación de un solo artículo")
        assertContains("Abuela’s tortillas")
        screenshot("Spanish-original-food-name-and-item-scope")
        assertKnownTotals()
        screenshot("Spanish-known-result-original-food-name")
        saveAndAssertDurableStatus(savedLabel: "Guardado en este iPhone")

        app.terminate()
        launch(language: "es", reset: false)
        reopenSavedRecord(recordsLabel: "Historial", item: "Abuela’s tortillas")
        assertScope("Comparación de un solo artículo")
        assertContains("Abuela’s tortillas")
        assertKnownTotals()
        assertSavedStatus("Guardado en este iPhone")
        screenshot("Spanish-reopened-result")
    }

    func testLargestDynamicTypeAndDarkAppearanceComparisonSmoke() throws {
        launch(largeDark: true)
        reveal(app.buttons["newComparison"])
        screenshot("Dark-largest-type-Shop")
        openEmptyComparison()
        enterComparison(item: "Large text wraps", firstQuantity: "8", cap: "30")
        screenshot("Dark-largest-type-entry")
        compare()
        assertScope("Item-only comparison")
        screenshot("Dark-largest-type-result-scope")
        assertMoney("aTotal", amount: "6.00")
        let total = element("aTotal")
        XCTAssertGreaterThan(total.frame.height, 0)
        XCTAssertLessThanOrEqual(total.frame.width, app.windows.firstMatch.frame.width)
        screenshot("Dark-largest-type-pack-A")
        assertMoney("bTotal", amount: "4.00")
        screenshot("Dark-largest-type-pack-B")
        saveAndAssertDurableStatus()
        screenshot("Dark-largest-type-saved")
    }

    func testAutomatedAccessibilityAuditOnShopAndKnownResults() throws {
        launch()
        try app.performAccessibilityAudit()
        openEmptyComparison()
        enterComparison(item: "Audit wraps", firstQuantity: "8", cap: "30")
        compare()
        // Audit the initial result before scrolling caches offscreen List rows
        // behind translucent system bars in the accessibility hierarchy.
        screenshot("Initial-result-before-audit")
        // Keep audit failures separate from persistence so every functional
        // restart check still runs. No issue categories/elements are filtered.
        try app.performAccessibilityAudit()
        assertKnownTotals()
        assertContains("Room within the item limit: $26.00")
    }

    private func launch(language: String = "en", reset: Bool = true, largeDark: Bool = false) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_US",
                               "-appearance", largeDark ? "dark" : "light"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        if largeDark {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                    "-UIUserInterfaceStyle", "Dark"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["newComparison"].waitForExistence(timeout: 15))
    }

    private func openEmptyComparison() {
        tap(element("newComparison"))
        let name = element("itemName")
        reveal(name)
        XCTAssertTrue(name.exists)
        let value = name.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == "Item name" || value == "Nombre del artículo", "Fresh form must not contain seeded food: \(value)")
    }

    private func enterComparison(item: String, firstQuantity: String?, cap: String? = nil) {
        type(item, into: "itemName")
        type("12", into: "needed")
        if let firstQuantity { type(firstQuantity, into: "aQuantity") }
        type("3", into: "aPrice")
        type("6", into: "bQuantity")
        type("2", into: "bPrice")
        if let cap { type(cap, into: "itemCap") }
    }

    private func compare() {
        tap(element("compare"))
        XCTAssertTrue(element("editComparison").waitForExistence(timeout: 5))
    }

    private func assertKnownTotals() {
        assertMoney("aTotal", amount: "6.00")
        reveal(element("aPacks"))
        XCTAssertTrue(element("aPacks").label.contains("2"))
        assertMoney("bTotal", amount: "4.00")
        reveal(element("bPacks"))
        XCTAssertTrue(element("bPacks").label.contains("2"))
    }

    private func assertMoney(_ id: String, amount: String) {
        let total = element(id)
        reveal(total)
        XCTAssertTrue(total.label.contains(amount), "Expected \(amount) in accessible cost: \(total.label)")
        XCTAssertTrue(total.label.contains("$") || total.label.contains("USD"))
        screenshot("Visible-\(id)-\(amount.replacingOccurrences(of: ".", with: "-"))")
    }

    private func assertScope(_ label: String) { assertContains(label) }

    private func assertContains(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target)
        XCTAssertTrue(target.exists, "Missing visible text: \(text)")
    }

    private func saveAndAssertDurableStatus(savedLabel: String = "Saved on this iPhone") {
        tap(element("saveComparison"))
        assertSavedStatus(savedLabel)
        XCTAssertFalse(element("saveComparison").exists)
    }

    private func assertSavedStatus(_ text: String) {
        // SwiftUI combines the saved label with its date; either the child ID or
        // the combined accessibility element may own the final accessible text.
        let status = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(status)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Save must publish success only after durable storage")
    }

    private func reopenSavedRecord(recordsLabel: String, item: String) {
        tap(app.tabBars.buttons[recordsLabel])
        let rows = app.descendants(matching: .any).matching(identifier: "savedComparison")
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 1, "One save must produce one durable record")
        reveal(row)
        XCTAssertTrue(row.label.contains(item), "Original item name should survive restart: \(row.label)")
        row.tap()
        XCTAssertTrue(element("editComparison").waitForExistence(timeout: 5))
    }

    private func type(_ text: String, into id: String) {
        let field = element(id)
        tap(field)
        // The keyboard can scroll a large-type Form row out of the snapshot.
        // Type into the focused field rather than requerying a recycled row.
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo", "Hecho"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Decimal input must have a keyboard dismissal control")
        done.tap()
        reveal(field)
        XCTAssertEqual(field.value as? String, text, "Typed input must reach its intended field")
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tap(_ target: XCUIElement) {
        reveal(target)
        target.tap()
    }

    /// Query by stable identifiers and scroll the native container. No screen
    /// coordinates, content seeding, or hardcoded screen-size assumptions.
    private func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if target.exists && target.isHittable { return }
        let scroll: XCUIElement
        if app.collectionViews.firstMatch.exists { scroll = app.collectionViews.firstMatch }
        else if app.tables.firstMatch.exists { scroll = app.tables.firstMatch }
        else if app.scrollViews.firstMatch.exists { scroll = app.scrollViews.firstMatch }
        else { scroll = app }
        for _ in 0..<18 {
            scroll.swipeUp(velocity: .slow)
            if target.exists && target.isHittable { return }
        }
        for _ in 0..<24 {
            scroll.swipeDown(velocity: .slow)
            if target.exists && target.isHittable { return }
        }
        XCTFail("Could not reveal \(target)", file: file, line: line)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
