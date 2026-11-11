import XCTest

/// Real typed entry through the shipping screens. The DEBUG launch switch only
/// isolates/clears the test database; it does not prefill or seed comparisons.
@MainActor
final class RoomInTheCartUITests: XCTestCase {
    private var app: XCUIApplication!
    private var doneIdentifier = "Done"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0 { screenshot("Failure") }
        app.terminate()
    }

    func testAccountDeletionSettingsExplainsScopeInEnglishAndSpanishBeforeSignIn() {
        for language in ["en", "es"] {
            launch(language: language)
            tap(app.buttons["settings"])
            tap(app.buttons[language == "en" ? "Household requests" : "Solicitudes del hogar"])
            let configured = !app.staticTexts[language == "en" ? "Household service is not configured" : "El servicio del hogar no está configurado"].exists
            tap(app.buttons["household.accountDeletion"])
            let title = language == "en" ? "Account deletion" : "Eliminación de la cuenta"
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let unavailable = language == "en" ? "This iPhone has no household service connection configured. Account deletion is unavailable." :
                "Este iPhone no tiene configurada una conexión al servicio del hogar. La eliminación de cuentas no está disponible."
            let signIn = language == "en" ? "Sign in to your adult account to review deletion. Saved receipts can be checked after sign-out." :
                "Inicia sesión con tu cuenta de adulto para revisar la eliminación. Puedes consultar los comprobantes guardados después de cerrar sesión."
            reveal(app.staticTexts.matching(NSPredicate(format: "label == %@", configured ? signIn : unavailable)).firstMatch)
            let renewal = language == "en" ? "An App Store subscription can continue to renew after account deletion." :
                "Tu suscripción del App Store puede seguir renovándose después de eliminar la cuenta."
            reveal(app.staticTexts[renewal])
            XCTAssertFalse(app.buttons[language == "en" ? "Request permanent deletion" : "Solicitar la eliminación permanente"].exists)
            screenshot("Account-deletion-scope-" + language)
            app.terminate()
        }
    }

    func testOwnerExportReviewAndCancelledDeletionPreserveComparisonAfterRestart() throws {
        let title = "Fictional recovery rice"
        launch()
        openEmptyComparison()
        enterComparison(item: title, firstQuantity: "8", cap: "30")
        compare()
        saveAndAssertDurableStatus()
        tap(app.tabBars.buttons["Records"])
        tap(app.buttons["Recovery, exports and saved records"])
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 5))

        tap(app.buttons["Delete this source"])
        let confirmation = app.alerts[title]
        XCTAssertTrue(confirmation.buttons["Delete from this iPhone"].waitForExistence(timeout: 5))
        let cancel = confirmation.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable, "A destructive confirmation must offer an explicit, reachable Cancel action")
        screenshot("Local-deletion-confirmation-with-cancel")
        cancel.tap()
        XCTAssertTrue(app.switches[title].exists, "Cancelling deletion must retain the source")
        tap(app.buttons["Select all readable records"])

        let ownerExport = app.buttons["Prepare readable owner export"]
        reveal(ownerExport)
        XCTAssertFalse(ownerExport.isEnabled, "Private export requires an explicit acknowledgement")
        let acknowledgement = app.switches["I understand a readable owner export includes private record data."]
        reveal(acknowledgement)
        XCTAssertEqual(acknowledgement.value as? String, "0")
        // On iOS 17 the switch accessibility frame spans the entire labeled row.
        let nativeSwitch = acknowledgement.switches.firstMatch
        (nativeSwitch.exists ? nativeSwitch : acknowledgement).tap()
        XCTAssertEqual(acknowledgement.value as? String, "1")
        XCTAssertTrue(ownerExport.isEnabled)
        tap(ownerExport)
        assertContains("Private owner file ready")
        let previewRow = app.cells.containing(.staticText, identifier: "Preview readable copy").firstMatch
        tap(previewRow)
        let preview = app.staticTexts.containing(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@", title, "Source:", "Revision:")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "The reviewed file must contain the selected source and revision")
        screenshot("Private-owner-export-reviewed-with-fictional-data")
        tap(app.buttons["Discard prepared file"])
        XCTAssertFalse(app.buttons["Save file…"].exists, "Discard must remove the prepared export")
        app.terminate()
        launch(reset: false)
        reopenSavedRecord(recordsLabel: "Records", item: title)
        assertKnownTotals()
    }

    func testConfirmedComparisonDeletionSurvivesRestart() throws {
        launch()
        openEmptyComparison()
        enterComparison(item: "Fictional record to delete", firstQuantity: "8")
        compare()
        saveAndAssertDurableStatus()
        tap(app.tabBars.buttons["Records"])
        tap(app.buttons["Recovery, exports and saved records"])
        tap(app.buttons["Delete this source"])
        tap(app.buttons["Delete from this iPhone"])
        assertContains("The selected source was deleted from this iPhone.")
        screenshot("Confirmed-fictional-source-deletion")
        app.terminate()
        launch(reset: false)
        tap(app.tabBars.buttons["Records"])
        assertContains("Your comparisons live here")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "savedComparison").count, 0)
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
        // iOS 17 gives both the decorative Label image and its text this identifier.
        // Inspect the readable warning, not the non-interactive image.
        let unknown = app.staticTexts.matching(identifier: "aIssue_usableQuantityUnknown").firstMatch
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
        reveal(app.staticTexts.matching(identifier: "aIssue_usableQuantityUnknown").firstMatch)
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
        let save = element("saveComparison")
        revealFullyInComparison(save)
        XCTAssertTrue(save.isEnabled)
        captureComparisonFrames("Spanish-save-ready")
        screenshot("Spanish-save-ready")
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

    func testLargestTextEditActionGrowsInContentAndReturnsToEntry() throws {
        launch(largeDark: true)
        openEmptyComparison()
        enterComparison(item: "Accessible edit wraps", firstQuantity: "8", cap: "30")
        compare()
        let edit = element("editComparison")
        revealFullyInComparison(edit)
        XCTAssertFalse(app.navigationBars.buttons["editComparison"].exists,
                       "Accessibility-sized Edit must use the expandable content row")
        XCTAssertGreaterThan(edit.frame.height, 44, "The large text label must grow beyond the compact toolbar height")
        captureComparisonFrames("Largest-text-Edit")
        screenshot("Largest-text-Edit-fully-visible")
        edit.tap()
        let name = element("itemName")
        reveal(name)
        XCTAssertEqual(name.value as? String, "Accessible edit wraps")
        compare()
        assertKnownTotals()
    }

    func testLargestTextSourceAndSavedDetailsAreFullyReadableAboveTabs() throws {
        launch(largeDark: true)
        openEmptyComparison()
        enterComparison(item: "Complete large text wraps", firstQuantity: "8", cap: "30")
        compare()
        for id in ["aHeader", "bHeader", "comparisonSourceNote", "saveComparison"] {
            let target = element(id)
            revealFullyInComparison(target)
            XCTAssertGreaterThan(target.frame.height, 0)
            captureComparisonFrames("Largest-text-complete-" + id)
            screenshot("Largest-text-complete-" + id)
        }
        saveAndAssertDurableStatus()
        let saved = element("comparisonSavedDetails")
        revealFullyInComparison(saved)
        XCTAssertTrue(saved.label.contains("Saved on this iPhone"))
        XCTAssertGreaterThan(saved.label.count, "Saved on this iPhone".count,
                             "The combined confirmation must include the saved date")
        captureComparisonFrames("Largest-text-complete-saved-details")
        screenshot("Largest-text-complete-saved-details")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.exists && back.isHittable)
        back.tap()
        XCTAssertTrue(element("newComparison").waitForExistence(timeout: 5))
    }

    func testShopPhoneShortcutsHaveACompleteTouchTargetAndReturnToShop() {
        launch()
        let shortcuts = app.buttons["deviceShortcuts"]
        XCTAssertTrue(shortcuts.waitForExistence(timeout: 5))
        let compare = app.buttons["newComparison"]
        let startPickup = app.buttons["openPickupList"]
        XCTAssertTrue(shopViewport.contains(compare.frame))
        XCTAssertTrue(shopViewport.contains(startPickup.frame))
        XCTAssertLessThan(compare.frame.midY, shortcuts.frame.minY)
        XCTAssertLessThan(startPickup.frame.midY, shortcuts.frame.minY)
        XCTAssertGreaterThanOrEqual(shortcuts.frame.height, 44)
        XCTAssertTrue(shopViewport.contains(shortcuts.frame))
        shortcuts.tap()
        let destination = app.navigationBars["Device shortcuts"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["newComparison"].waitForExistence(timeout: 5))
    }

    func testShopRepairShortcutRemainsInsideViewportAndOpens() throws {
        verifyShopRepairShortcut(largeDark: false)
    }

    func testLargestTextShopRepairShortcutRemainsInsideViewportAndOpens() throws {
        verifyShopRepairShortcut(largeDark: true)
    }

    private func verifyShopRepairShortcut(largeDark: Bool) {
        launch(largeDark: largeDark)
        let shortcut = element("urgentRepairShortcut")
        revealFullyInShop(shortcut)
        let scroll = app.scrollViews["shopContentScroll"]
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.exists)
        XCTAssertLessThanOrEqual(scroll.frame.maxY, tabs.frame.minY,
                                 "Shop scrolling content must end above the tabs")
        XCTAssertTrue(shopViewport.contains(shortcut.frame), "The entire repair shortcut must be visible")
        XCTAssertTrue(shortcut.isHittable)
        captureShopFrames(largeDark ? "Largest-Shop-repair-visible" : "Default-Shop-repair-visible")
        screenshot(largeDark ? "Largest-Shop-repair-visible" : "Default-Shop-repair-visible")
        shortcut.tap()
        XCTAssertTrue(app.navigationBars["Something is missing"].waitForExistence(timeout: 5),
                      "The visible shortcut must open the real repair screen")
        screenshot(largeDark ? "Largest-urgent-repair-opened" : "Default-urgent-repair-opened")
    }

    func testComparisonSaveStaysInsideViewportAboveTabBar() throws {
        launch()
        openEmptyComparison()
        enterComparison(item: "Viewport wraps", firstQuantity: "8", cap: "30")
        compare()
        let list = element("comparisonResultsScroll")
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(list.exists)
        XCTAssertTrue(tabs.exists)
        XCTAssertLessThanOrEqual(list.frame.maxY, tabs.frame.minY,
                                 "The results viewport must end above the tab bar")
        let save = element("saveComparison")
        for _ in 0..<18 {
            if save.exists && list.frame.contains(save.frame) { break }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(save.exists && save.isHittable)
        XCTAssertTrue(list.frame.contains(save.frame), "The whole Save control must be visible")
        XCTAssertLessThanOrEqual(save.frame.maxY, tabs.frame.minY)
        screenshot("Save-fully-visible-above-tabs")
        saveAndAssertDurableStatus()
    }

    func testAutomatedAccessibilityAuditOnShopAndKnownResults() throws {
        // Collect failures from every viewport in this audit-only test.
        continueAfterFailure = true
        launch()
        captureShopFrames("Initial-Shop-before-audit")
        screenshot("Initial-Shop-before-audit")
        XCTAssertNoThrow(try auditAccessibility())
        // Retain the initial audit; add full-category coverage after the
        // complete repair shortcut is visible above bottom navigation.
        revealFullyInShop(element("urgentRepairShortcut"))
        captureShopFrames("Complete-repair-shortcut-before-audit")
        screenshot("Complete-repair-shortcut-before-audit")
        XCTAssertNoThrow(try auditAccessibility())
        openEmptyComparison()
        enterComparison(item: "Audit wraps", firstQuantity: "8", cap: "30")
        compare()
        // Cover both the initial viewport and the lower results after scrolling.
        screenshot("Initial-result-before-audit")
        captureComparisonFrames("Initial-result-before-audit")
        // Keep audit failures separate from persistence so every functional
        // restart check still runs. No issue categories/elements are filtered.
        XCTAssertNoThrow(try auditAccessibility())
        assertKnownTotals()
        assertContains("Room within the item limit: $26.00")
        screenshot("Scrolled-result-before-audit")
        captureComparisonFrames("Scrolled-result-before-audit")
        XCTAssertNoThrow(try auditAccessibility())
        // Additional coverage: retain both earlier audits, then audit the complete
        // Save control in the visible content area. No issue is suppressed.
        revealFullyInComparison(element("saveComparison"))
        captureComparisonFrames("Complete-Save-before-audit")
        screenshot("Complete-Save-before-audit")
        XCTAssertNoThrow(try auditAccessibility())
    }

    private var shopViewport: CGRect {
        let scroll = app.scrollViews["shopContentScroll"].frame
        let window = app.windows.firstMatch.frame
        let navigation = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        let top = max(scroll.minY, window.minY, navigation.exists ? navigation.frame.maxY : window.minY)
        let bottom = min(scroll.maxY, window.maxY, tabs.exists ? tabs.frame.minY : window.maxY)
        return CGRect(x: max(scroll.minX, window.minX), y: top,
                      width: max(0, min(scroll.maxX, window.maxX) - max(scroll.minX, window.minX)),
                      height: max(0, bottom - top))
    }

    private func revealFullyInShop(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let scroll = app.scrollViews["shopContentScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<36 {
            let viewport = shopViewport
            guard viewport.height > 0 else { break }
            if !target.exists { scroll.swipeUp(velocity: .slow); continue }
            let frame = target.frame
            if target.isHittable && viewport.contains(frame) { return }
            guard frame.height <= viewport.height, frame.width <= viewport.width else { break }
            if frame.minY > viewport.maxY + viewport.height { scroll.swipeUp(velocity: .slow); continue }
            if frame.maxY < viewport.minY - viewport.height { scroll.swipeDown(velocity: .slow); continue }
            let limit = viewport.height * 0.3
            let correction = min(limit, max(-limit, viewport.midY - frame.midY))
            guard correction != 0 else { break }
            let window = app.windows.firstMatch
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX, dy: viewport.midY - window.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX, dy: viewport.midY - window.frame.minY + correction))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        captureShopFrames("Shop-full-visibility-failure")
        XCTFail("The complete shortcut must be reachable inside the Shop viewport: \(target)", file: file, line: line)
    }

    private func captureShopFrames(_ name: String) {
        let scroll = app.scrollViews["shopContentScroll"]
        let target = element("urgentRepairShortcut")
        let rows = ["Window: \(app.windows.firstMatch.frame)", "Shop scroll: \(scroll.frame)",
                    "Navigation: \(app.navigationBars.firstMatch.frame)", "Tabs: \(app.tabBars.firstMatch.frame)",
                    "Visible Shop: \(shopViewport)",
                    target.exists ? "Repair shortcut: \(target.frame); hittable=\(target.isHittable); \(target.label)" : "Repair shortcut: absent"]
        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.name = name + " — exact frames"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private var comparisonViewport: CGRect {
        let list = element("comparisonResultsScroll").frame
        let window = app.windows.firstMatch.frame
        let navigation = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        let top = max(list.minY, window.minY, navigation.exists ? navigation.frame.maxY : window.minY)
        let bottom = min(list.maxY, window.maxY, tabs.exists ? tabs.frame.minY : window.maxY)
        return CGRect(x: max(list.minX, window.minX), y: top,
                      width: min(list.maxX, window.maxX) - max(list.minX, window.minX), height: max(0, bottom - top))
    }

    private func revealFullyInComparison(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let list = element("comparisonResultsScroll")
        XCTAssertTrue(list.exists, file: file, line: line)
        // First use native scrolling to bring the lazy row into the hierarchy.
        reveal(target, file: file, line: line)
        for _ in 0..<20 {
            let viewport = comparisonViewport
            guard target.exists, viewport.height > 0 else { break }
            let frame = target.frame
            if target.isHittable && viewport.contains(frame) { return }
            guard frame.height <= viewport.height, frame.width <= viewport.width else { break }
            // Center the measured row and hold before lifting to stop momentum.
            // Default-velocity drags oscillated past this tall row in the first run.
            let limit = viewport.height * 0.3
            let correction = min(limit, max(-limit, viewport.midY - frame.midY))
            guard correction != 0 else { break }
            let window = app.windows.firstMatch
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX,
                                                  dy: viewport.midY - window.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX,
                                                dy: viewport.midY - window.frame.minY + correction))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        captureComparisonFrames("Full-visibility-failure")
        XCTFail("The complete control must fit in the visible results area: \(target)", file: file, line: line)
    }

    private func captureComparisonFrames(_ name: String) {
        var rows = ["Window: \(app.windows.firstMatch.frame)", "List: \(element("comparisonResultsScroll").frame)",
                    "Navigation: \(app.navigationBars.firstMatch.frame)", "Tabs: \(app.tabBars.firstMatch.frame)",
                    "Visible results: \(comparisonViewport)"]
        for id in ["editComparison", "aHeader", "bHeader", "comparisonSourceNote", "saveComparison", "savedStatus", "comparisonSavedDetails"] {
            let target = element(id)
            rows.append(target.exists ? "\(id): \(target.frame); hittable=\(target.isHittable); \(target.label)" : "\(id): absent from current hierarchy")
        }
        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.name = name + " — exact frames"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func auditAccessibility() throws {
        try app.performAccessibilityAudit { issue in
            let details = XCTAttachment(string: "\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element supplied")")
            details.name = "Accessibility issue details"
            details.lifetime = .keepAlways
            self.add(details)
            return false // Record every issue as a failure; never suppress it.
        }
    }

    private func launch(language: String = "en", reset: Bool = true, largeDark: Bool = false) {
        doneIdentifier = language == "es" ? "Listo" : "Done"
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_US",
                               "-appearance", largeDark ? "dark" : "light"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        if largeDark {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                    "-UIUserInterfaceStyle", "Dark"]
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons[language == "es" ? "Compras" : "Shop"].waitForExistence(timeout: 15))
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
        // The shipping action is a button. A broad Any query traverses text-field
        // placeholder snapshots while this large-text Form is scrolling.
        tap(app.buttons["compare"])
        XCTAssertTrue(app.buttons["editComparison"].waitForExistence(timeout: 5))
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
        // Persistence checks intentionally reopen from the records list. A
        // restored comparison remains open until the person uses native Back.
        for _ in 0..<4 {
            if app.navigationBars[recordsLabel].exists { break }
            let destinationLabel = app.navigationBars.buttons[recordsLabel].firstMatch
            let back = destinationLabel.exists ? destinationLabel : app.navigationBars.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Return from the restored destination through its native Back control")
            tap(back)
        }
        XCTAssertTrue(app.navigationBars[recordsLabel].waitForExistence(timeout: 5))
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
        let field = app.textFields[id]
        tap(field)
        // keyboardDoneAction uses the localized title as its identifier.
        // Avoid a label-predicate snapshot and a redundant second readiness query.
        let done = app.buttons[doneIdentifier]
        // Form scrolling can recycle the row after the first tap. Reacquire it
        // once before entering any text, and require the focus-driven Done control.
        var focused = done.waitForExistence(timeout: 3)
        if !focused { tap(field); focused = done.waitForExistence(timeout: 3) }
        XCTAssertTrue(focused, "Input must expose its keyboard dismissal control before typing")
        // Once focus is ready, typing through the app avoids querying a row
        // that the keyboard may have scrolled out of the current snapshot.
        app.typeText(text)
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
