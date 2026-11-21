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

    func testLargestTextQuickGroceryFitsAndSubmitsWithReturn() {
        launch(language: "es", largeDark: true)
        let field = element("quickGrocery.name")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(shopViewport.contains(CGPoint(x: field.frame.midX, y: field.frame.midY)),
                      "The first grocery should be reachable before scrolling past privacy information.")
        revealFullyInShop(field)
        let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let lineHeight = UIFont.preferredFont(forTextStyle: .body, compatibleWith: largest).lineHeight
        XCTAssertGreaterThanOrEqual(field.frame.height, floor(lineHeight))
        let label = app.staticTexts["Nombre del producto"]
        XCTAssertTrue(label.exists && shopViewport.contains(label.frame))
        XCTAssertEqual(field.label, label.label)
        screenshot("Largest-text-Spanish-grocery-name")
        let emptyHeight = field.frame.height
        let name = "aceite de oliva virgen extra"
        field.tap()
        field.typeText(name)
        XCTAssertEqual(field.value as? String, name)
        XCTAssertGreaterThan(field.frame.height, emptyHeight, "A long entry should wrap at this text size.")
        field.typeText("\n")
        let undo = app.buttons["quickGrocery.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.label.contains(name))
        XCTAssertEqual(field.frame.height, emptyHeight, accuracy: 1, "Submitting should restore the empty line.")
        let viewList = app.buttons["quickGrocery.viewList"]
        XCTAssertTrue(viewList.waitForExistence(timeout: 5))
        XCTAssertEqual(viewList.label, "Ver lista de compras")
        XCTAssertLessThanOrEqual(undo.frame.maxY, viewList.frame.minY, "Accessibility text sizes should stack the receipt actions.")
        XCTAssertGreaterThanOrEqual(viewList.frame.height, 44)
    }

    func testPrivateQuickEntrySurvivesAnOrdinaryBackgroundInterruption() {
        launch()
        let field = element("quickGrocery.name")
        tap(field)
        field.typeText("Oats")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Oats")
        tap(app.buttons["quickGrocery.add"])
        let added = app.buttons["quickGrocery.undo"]
        XCTAssertTrue(added.waitForExistence(timeout: 10))
        XCTAssertTrue(added.label.contains("Oats"))
        XCTAssertTrue(app.staticTexts["Added Oats to Pickup on this iPhone."].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        tap(app.buttons["quickGrocery.viewList"])
        let originalRow = app.buttons["Inspect Oats"]
        XCTAssertTrue(originalRow.waitForExistence(timeout: 8))
        let editID = originalRow.identifier.replacingOccurrences(of: "ledgerInspect-", with: "ledgerEditRow-")
        originalRow.swipeLeft()
        tap(app.buttons[editID])
        let itemName = element("ledgerEditItemName")
        XCTAssertEqual(itemName.label, "Item name")
        tap(itemName)
        itemName.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        itemName.typeText(" (rolled)\n")
        XCTAssertTrue(element("ledgerUnsavedItem").exists)
        tap(app.buttons["Save item"])
        tap(app.buttons["Inspect Oats (rolled)"])
        let edit = app.buttons["ledgerEditItemDetails"]
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        XCTAssertEqual(edit.label, "Edit name, notes and department")
        XCTAssertTrue(app.staticTexts["Oats"].exists)
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["Check Oats (rolled)"])
        tap(element("ledgerRecentlyChecked"))
        XCTAssertTrue(app.buttons["Reopen Oats (rolled)"].waitForExistence(timeout: 8))
    }

    func testReviewedQuickGroceryClearsOnlyAfterSavingToExistingPickup() {
        launch()
        let field = element("quickGrocery.name")
        tap(field)
        field.typeText("Oats\n")
        XCTAssertTrue(element("quickGrocery.undo").waitForExistence(timeout: 10))
        let name = "Peppers / pimientos"
        field.typeText(name + "\n")
        let commit = element("ledgerCommitImport")
        XCTAssertTrue(commit.waitForExistence(timeout: 10))
        tap(app.buttons["Cancel"])
        XCTAssertEqual(field.value as? String, name)
        tap(element("quickGrocery.add"))
        let amount = element("ledgerImportAmount-1")
        tap(amount)
        amount.typeText("2")
        tap(app.buttons.matching(identifier: "Done").firstMatch)
        tap(commit)
        XCTAssertTrue(commit.waitForNonExistence(timeout: 10))
        tap(field)
        field.typeText("Milk")
        XCTAssertEqual(field.value as? String, "Milk")
    }

    func testQuickGroceryReturnUndoAndDuplicateReviewInSpanish() {
        launch(language: "es")
        let field = element("quickGrocery.name")
        tap(field)
        field.typeText("huevos\n")
        let undo = app.buttons["quickGrocery.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.label.contains("huevos"))
        field.typeText("1 limón\n")
        let lemonUndo = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                        "quickGrocery.undo", "limón")).firstMatch
        XCTAssertTrue(lemonUndo.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(lemonUndo.frame.width, 44)
        XCTAssertGreaterThanOrEqual(lemonUndo.frame.height, 44)
        lemonUndo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(lemonUndo.waitForNonExistence(timeout: 10))
        tap(field)
        field.typeText("huevos\n")
        XCTAssertTrue(element("ledgerImportForm").waitForExistence(timeout: 10))
        app.terminate()
        launch(language: "es", reset: false)
        tap(element("openPickupList"))
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.firstMatch.label.contains("huevos"))
    }

    func testColdAddItemShortcutOpensEditableFirstDraftWithoutCreatingPickup() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "--test-shopping-add-intent",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let editor = app.textViews["ledgerImportText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        XCTAssertEqual(editor.value as? String, "2 kg rice")
        tap(app.buttons["Close"])
        XCTAssertTrue(app.buttons["shop.addFirstList"].waitForExistence(timeout: 12))
        app.terminate()
        launch(reset: false)
        tap(app.buttons["shop.addFirstList"])
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "", "Closing untouched Shortcut wording must not save it in a seven-day draft")
        tap(app.buttons["Close"])
        app.terminate()

        app.launchArguments.append("--test-shopping-add-intent")
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        XCTAssertEqual(editor.value as? String, "2 kg rice")
        tap(editor)
        editor.typeText(" noodles")
        let edited = editor.value as? String
        XCTAssertTrue(edited?.contains("noodles") == true)
        XCTAssertTrue(edited?.contains("2 kg rice") == true)
        let done = app.buttons["Done"]
        if done.exists, done.isHittable { done.tap() }
        tap(app.buttons["Close"])
        XCTAssertTrue(app.buttons["shop.addFirstList"].waitForExistence(timeout: 12))
        tap(app.buttons["shop.addFirstList"])
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, edited)
    }

    func testEditingReviewedGroceryKeepsCommitAwayFromKeyboardAndPreservesBothRows() {
        launch()
        tap(app.buttons["shop.addFirstList"])
        let original = app.textViews["ledgerImportText"]
        tap(original)
        let misspelling = "scalllions"
        original.typeText(misspelling + "\ncorn tortillas")
        let done = app.buttons["Done"]
        tap(done)
        tap(app.buttons["ledgerReviewImport"])
        let commit = app.buttons["ledgerCommitImport"]
        XCTAssertTrue(commit.waitForExistence(timeout: 8))
        // SwiftUI exposes its vertically growing name input differently across supported iOS versions.
        let name = element("ledgerImportName-1")
        revealReviewAction(name, above: commit)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(commit.waitForNonExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThanOrEqual(name.frame.maxY, done.frame.minY)
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: misspelling.count) + "scallions")
        XCTAssertEqual(name.value as? String, "scallions")
        tap(done)
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: "Done"))
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        tap(commit)
        let corrected = app.buttons["Inspect scallions"]
        XCTAssertTrue(corrected.waitForExistence(timeout: 8))
        app.terminate()
        launch(reset: false)
        if !corrected.waitForExistence(timeout: 3) { tap(app.buttons["quickGrocery.viewList"]) }
        XCTAssertTrue(corrected.waitForExistence(timeout: 8))
        let tortillas = app.buttons["Inspect corn tortillas"]
        reveal(tortillas)
        XCTAssertTrue(tortillas.exists)
        tap(corrected)
        let optional = app.staticTexts["Quantity optional"]
        reveal(optional)
        XCTAssertTrue(optional.exists)
        XCTAssertTrue(app.staticTexts["scalllions"].exists)
        XCTAssertFalse(app.staticTexts["Review the quantity and unit."].exists)
    }

    func testFirstListResumesAfterRelaunchAndCreatesOneUndoablePickupOnConfirmation() {
        for language in ["en", "es"] {
            launch(language: language, largeDark: language == "es")
            let add = app.buttons["shop.addFirstList"]
            let destination = language == "en" ? "Pickup" : "Recogida"
            let firstDestination = app.staticTexts["quickGrocery.firstDestination"]
            XCTAssertTrue(firstDestination.waitForExistence(timeout: 10))
            XCTAssertTrue(firstDestination.label.contains(destination))
            XCTAssertEqual(add.label, language == "en" ? "Add several items" : "Añadir varios artículos")
            tap(add)
            let close = app.buttons[language == "en" ? "Close" : "Cerrar"]
            tap(close)
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            tap(add)
            let field = app.textViews["ledgerImportText"]
            let wording = language == "en" ? "2 apples\n2 apple" : "2 manzanas\n2 manzana"
            tap(field)
            field.typeText(wording)
            let done = language == "en" ? "Done" : "Listo"
            let doneButton = app.buttons[done]
            XCTAssertTrue(doneButton.waitForExistence(timeout: 5) && doneButton.isHittable)
            doneButton.tap()
            XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: done))
            let saved = app.staticTexts["firstList.draftStatus"]
            // At accessibility sizes the focused editor scrolls the status row
            // above the visible part of the Form. Bring it back before reading it.
            let form = app.collectionViews["ledgerImportForm"]
            for _ in 0..<5 {
                if saved.exists && saved.isHittable { break }
                form.swipeDown(velocity: .slow)
            }
            XCTAssertTrue(saved.exists && saved.isHittable)
            let label = language == "en" ? "Private draft saved on this device. It expires 7 days after your last edit." :
                "Borrador privado guardado en este dispositivo. Caduca 7 días después del último cambio."
            expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: saved)
            waitForExpectations(timeout: 10)
            app.terminate()
            launch(language: language, reset: false, largeDark: language == "es")
            tap(app.buttons["shop.addFirstList"])
            XCTAssertTrue(form.waitForExistence(timeout: 5))
            reveal(field)
            XCTAssertEqual(field.value as? String, wording)
            tap(app.buttons["ledgerReviewImport"])
            let compact = language == "es"
            let summary = compact ? app.buttons["ledgerImportSummary"] : app.staticTexts["ledgerImportSummary"]
            let confirm = app.buttons["ledgerCommitImport"]
            func assertSummary(_ expected: String, line: UInt = #line) {
                XCTAssertEqual(compact ? summary.value as? String : summary.label, expected, line: line)
            }
            let both = language == "en" ? "Pickup · Selected: 2 · Skipped: 0" : "Recogida · Incluidos: 2 · Omitidos: 0"
            let onlyOne = language == "en" ? "Pickup · Selected: 1 · Skipped: 1" : "Recogida · Incluidos: 1 · Omitidos: 1"
            XCTAssertTrue(summary.waitForExistence(timeout: 10))
            assertSummary(both)
            let jump = app.buttons["ledgerReviewRepeat"]
            tap(jump)
            // The shortcut scrolls to the decision, without changing the selection.
            assertSummary(both)
            let skipSecond = app.buttons["ledgerImportSkip-2"]
            revealReviewAction(skipSecond, above: compact ? confirm : summary)
            let advisory = app.staticTexts["ledgerImportRepeat-2"]
            XCTAssertTrue(advisory.waitForExistence(timeout: 5))
            XCTAssertFalse(advisory.frame.isEmpty)
            XCTAssertEqual(advisory.label, language == "en" ? "Similar to line 1: 2 apples" : "Se parece a la línea 1: 2 manzanas")
            tap(skipSecond)
            assertSummary(onlyOne)
            XCTAssertFalse(app.textFields["ledgerImportAmount-2"].exists)
            XCTAssertFalse(advisory.exists)
            tap(app.buttons["ledgerImportInclude-2"])
            assertSummary(both)
            XCTAssertEqual(app.textFields["ledgerImportAmount-2"].value as? String, "2")
            if compact {
                XCTAssertEqual(confirm.value as? String, both)
                XCTAssertTrue(confirm.isHittable && confirm.isEnabled)
                let amount = app.textFields["ledgerImportAmount-2"]
                revealReviewAction(amount, above: confirm)
                amount.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
                amount.typeText("..")
                XCTAssertTrue(doneButton.wait(for: \.isHittable, toEqual: true, timeout: 5))
                doneButton.tap()
                XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: done))
                XCTAssertFalse(confirm.isEnabled)
                tap(summary)
                let totals = app.alerts["Totales de la revisión"]
                XCTAssertTrue(totals.staticTexts[both].exists)
                let jump = totals.buttons["Revisar línea 2"]
                XCTAssertTrue(jump.isHittable)
                jump.tap()
                revealReviewAction(amount, above: confirm)
                amount.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
                amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "2")
                XCTAssertTrue(doneButton.wait(for: \.isHittable, toEqual: true, timeout: 5))
                doneButton.tap()
                XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: done))
                XCTAssertEqual(amount.value as? String, "2")
                XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
                screenshot("Spanish largest text compact review and reachable confirmation")
            }
            tap(confirm)
            let undo = app.buttons["ledgerUndoImport"]
            reveal(undo)
            XCTAssertEqual(undo.label, language == "en" ? "Undo last import · 2 entries" : "Deshacer la última importación · 2 entradas")
            tap(undo)
            XCTAssertTrue(undo.waitForNonExistence(timeout: 10))
            app.terminate()
        }
    }

    func testSharePreviewClosesToPrivateListWithoutSending() {
        launch()
        let name = "Roasted red peppers"
        let field = element("quickGrocery.name")
        tap(field)
        field.typeText(name)
        tap(app.buttons["quickGrocery.add"])
        tap(app.buttons["quickGrocery.viewList"])
        tap(app.buttons["ledgerListOptions"])
        let share = app.buttons["tripShare.previewCopy"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        XCTAssertEqual(share.label, "Preview list copy")
        tap(share)
        let row = app.switches.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        tap(app.buttons["Preview message"])
        let preview = app.staticTexts["tripShareBody"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertTrue(preview.label.contains(name))
        XCTAssertFalse(preview.label.contains("Quantity unresolved"))
        tap(app.buttons["tripShare.close"])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Inspect " + name].waitForExistence(timeout: 8))
    }

    func testHouseholdHelpShowsPrivateSharingBeforeDetailedPermissions() {
        launch(language: "es")
        tap(app.buttons["settings"])
        tap(app.buttons["settings.help"])
        tap(app.buttons["help.topic.household"])
        XCTAssertTrue(app.navigationBars["Compartir en el hogar"].waitForExistence(timeout: 8))
        let share = app.staticTexts["help.privateListSharing.instructions"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        XCTAssertTrue(share.label.contains("Vista previa de la lista"))
        let permissions = app.buttons["help.householdPermissions"]
        let rule = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "los presupuestos del hogar")).firstMatch
        XCTAssertFalse(rule.exists)
        tap(permissions)
        XCTAssertTrue(rule.waitForExistence(timeout: 8))
    }

    func testFamilyPermissionGuideExplainsChildScopeAndGuardianStartOffline() {
        launch(language: "es", largeDark: true)
        tap(app.buttons["settings"])
        tap(app.buttons["settings.help"])
        tap(app.buttons["guardian.familyGuide"])
        let scope = app.staticTexts["guardian.familyGuide.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 8))
        XCTAssertTrue(scope.label.contains("sus propias solicitudes"))
        XCTAssertTrue(scope.label.contains("presupuesto del hogar es privado"))
        let start = app.staticTexts["guardian.familyGuide.start"]
        reveal(start)
        XCTAssertTrue(start.label.contains("Solicitudes del hogar"))
        XCTAssertTrue(start.label.contains("Controles del tutor"))
        tap(app.buttons["guardian.familyGuide.support"])
        XCTAssertTrue(app.navigationBars["Soporte"].waitForExistence(timeout: 8))
    }

    func testAccountDeletionSettingsExplainsScopeInEnglishAndSpanishBeforeSignIn() {
        for language in ["en", "es"] {
            launch(language: language)
            tap(app.buttons["settings"])
            tap(app.buttons[language == "en" ? "Household requests" : "Solicitudes del hogar"])
            let configured = !app.staticTexts[language == "en" ? "Household sign-in is unavailable" : "No se puede iniciar sesión en el hogar"].exists
            tap(app.buttons["household.accountDeletion"])
            let title = language == "en" ? "Account deletion" : "Eliminación de la cuenta"
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let unavailable = language == "en" ? "Account deletion is unavailable on this iPhone. Open Support in Settings for help." :
                "La eliminación de cuentas no está disponible en este iPhone. Para obtener ayuda, abre Soporte en Configuración."
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
        tap(tabButton("Records", symbol: "clock.arrow.circlepath"))
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
        let previewRow = app.buttons["records.readablePreview"]
        let saveFile = app.buttons["records.saveFile"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: previewRow)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed, "Preparing a readable file must reveal its preview without scrolling")
        XCTAssertTrue(app.staticTexts["Private owner file ready"].exists)
        XCTAssertFalse(app.staticTexts["Redacted copy ready"].exists)
        XCTAssertTrue(saveFile.exists)
        XCTAssertLessThanOrEqual(previewRow.frame.maxY, saveFile.frame.minY + 1)
        previewRow.tap()
        let preview = app.staticTexts.containing(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@", title, "Source:", "Revision:")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "The reviewed file must contain the selected source and revision")
        let ownerText = preview.label
        for expected in ["Item-only comparison", "Item cost to buy enough: $6.00", "Item cost to buy enough: $4.00",
                         "Room within the item limit: $26.00", "Lower cost to buy enough for this item"] {
            XCTAssertTrue(ownerText.contains(expected), expected)
        }
        XCTAssertFalse(ownerText.contains("normalizedRequest"))
        screenshot("Private-owner-export-reviewed-with-fictional-data")
        tap(app.buttons["Discard prepared file"])
        XCTAssertFalse(app.buttons["Save file…"].exists, "Discard must remove the prepared export")
        XCTAssertFalse(app.staticTexts["Your file is ready to review and save."].exists)
        app.terminate()
        launch(reset: false)
        reopenSavedRecord(recordsLabel: "Records", item: title)
        assertKnownTotals()
    }

    func testConfirmedComparisonDeletionSurvivesRestart() throws {
        launch()
        openEmptyComparison()
        type([("itemName", "Fictional record to delete")])
        type([("needed", "2")])
        tap(app.buttons["comparisonStockDisclosure"])
        type([("stock", "3")])
        compare()
        assertContains("No packs needed for this item.")
        saveAndAssertDurableStatus()
        tap(tabButton("Records", symbol: "clock.arrow.circlepath"))
        tap(app.buttons["Recovery, exports and saved records"])
        tap(app.buttons["Delete this source"])
        tap(app.buttons["Delete from this iPhone"])
        let status = app.staticTexts["records.status"]
        let deletionCompleted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND label == %@",
                                   "The selected source was deleted from this iPhone."), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [deletionCompleted], timeout: 8), .completed)
        screenshot("Confirmed-fictional-source-deletion")
        app.terminate()
        launch(reset: false)
        tap(tabButton("Records", symbol: "clock.arrow.circlepath"))
        assertContains("Your comparisons live here")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "savedComparison").count, 0)
    }

    func testKnownComparisonSavesAndReopensWithItemOnlyLimit() throws {
        launch()
        XCTAssertEqual(app.buttons["newComparison"].label, "Compare packs")
        XCTAssertFalse(element("savedComparison").exists)
        openEmptyComparison()
        enterComparison(item: "Family wraps", firstQuantity: "7 1/2", cap: "30", omitPriceFor: "b")
        compare()
        let addPrice = app.buttons["bAddPrice"]
        XCTAssertEqual(addPrice.label, "Add Pack B price")
        XCTAssertFalse(app.buttons["aAddPrice"].exists)
        tap(addPrice)
        let price = app.textFields["bPrice"]
        XCTAssertTrue(price.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["comparison.done.bPrice"].waitForExistence(timeout: 5))
        price.typeText("2")
        tap(app.buttons["comparison.updatePrice"])
        XCTAssertTrue(price.waitForNonExistence(timeout: 5))
        let unitSummary = element("aCostSummary")
        revealFullyInComparison(unitSummary)
        XCTAssertTrue(unitSummary.label.contains("$0.40 per 1 item"))
        XCTAssertTrue(element("bCostSummary").label.contains("$0.3333 per 1 item"))
        let decision = app.descendants(matching: .any).matching(identifier: "comparisonDecision").firstMatch
        XCTAssertTrue(decision.waitForExistence(timeout: 5) && decision.isHittable)
        XCTAssertTrue(decision.label.contains("Pack B"))
        assertScope("Item-only comparison")
        assertContains("whole pickup fits your budget")
        assertContains("Confirmed at home for this need: Not entered")
        XCTAssertFalse(app.staticTexts["comparisonNeedAfterStock"].exists)
        screenshot("English-item-scope")
        assertContains("Usable amount in one pack: 7 1/2 items")
        assertContains("Price for one pack (USD): $3.00")
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
        editComparisonResult()
        let savedYield = app.textFields["aQuantity"]
        reveal(savedYield)
        XCTAssertEqual(savedYield.value as? String, "7 1/2")
        compare()
        revealFullyInComparison(element("comparisonSourceNote"))
        XCTAssertFalse(app.buttons["saveComparison"].exists, "Reviewing the same values must keep the saved result")
        assertSavedStatus("Saved on this iPhone")
    }

    func testUnknownPackAmountRemainsUnresolvedAfterSaveAndRestart() throws {
        launch()
        openEmptyComparison()
        enterComparison(item: "Unknown yield wraps", firstQuantity: nil, omitPriceFor: "a")
        compare()
        XCTAssertFalse(app.buttons["bAddPrice"].exists)
        tap(app.buttons["aAddPrice"])
        let price = app.textFields["aPrice"]
        XCTAssertTrue(app.buttons["comparison.done.aPrice"].waitForExistence(timeout: 5))
        price.typeText("3")
        tap(app.buttons["comparison.updatePrice"])
        XCTAssertTrue(price.waitForNonExistence(timeout: 5))
        assertScope("Item-only comparison")
        assertContains("Usable amount in one pack: Not entered")
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

    func testMissingPackAmountCanBeCorrectedFromResultWithItsUnitAndItemLimit() {
        launch()
        openEmptyComparison()
        type([("itemName", "Frozen shelled edamame"), ("needed", "300")])
        tap(app.buttons["neededUnit"])
        tap(app.buttons["grams"])
        type([("aQuantity", "300"), ("aPrice", "3.45")])
        tap(app.buttons["aUnit"])
        tap(app.buttons["grams"])
        type([("bPrice", "5.76"), ("itemCap", "5.50")])
        compare()

        let addAmount = app.buttons["bAddAmount"]
        XCTAssertEqual(addAmount.label, "Enter Pack B usable amount")
        XCTAssertFalse(app.buttons["aAddAmount"].exists)
        tap(addAmount)
        let amount = app.textFields["bQuantity"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        tap(app.buttons["Cancel"])
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))
        tap(addAmount)
        tap(amount)
        amount.typeText("0.6")
        dismissComparisonKeyboard("comparison.done.bQuantity")
        tap(app.buttons["bUnit"])
        tap(app.buttons["kilograms"])
        tap(app.buttons["comparison.updateAmount"])

        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))
        XCTAssertFalse(addAmount.exists)
        let cap = element("comparisonItemLimit")
        revealFullyInComparison(cap)
        XCTAssertTrue(cap.label.contains("$5.50"))
        XCTAssertTrue(element("aCostSummary").label.contains("$3.45"))
        XCTAssertTrue(element("bCostSummary").label.contains("$5.76"))
        assertContains("Usable amount in one pack: 0.6 kilograms")
        assertContains("Over the item limit: $0.26")
    }

    func testPackageLabelConversionResolvesOnlyAfterConfirmationAndReopens() {
        launch()
        openEmptyComparison()
        type([("itemName", "Measured oats"), ("needed", "3")])
        tap(app.buttons["neededUnit"]); tap(app.buttons["US cups"])
        type([("aQuantity", "180"), ("aPrice", "2.50")])
        tap(app.buttons["aUnit"]); tap(app.buttons["grams"])

        tap(app.buttons["aConversion"])
        let source = app.textFields["conversion.source"]
        tap(source); source.typeText("120")
        dismissComparisonKeyboard("conversion.done")
        let cancel = app.buttons["conversion.cancel"]
        tap(cancel)
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        compare()
        let unresolved = app.staticTexts["aIssue_usableConversionUnknown"].firstMatch
        reveal(unresolved)
        XCTAssertFalse(app.staticTexts["aTotal"].exists)

        editComparisonResult()
        tap(app.buttons["aConversion"])
        tap(source); source.typeText("120.0")
        let target = app.textFields["conversion.target"]
        tap(target); target.typeText("1")
        dismissComparisonKeyboard("conversion.done")
        tap(app.buttons["conversion.confirm"])
        compare()
        assertMoney("aTotal", amount: "5.00")
        let packs = app.staticTexts["aPacks"]
        reveal(packs); XCTAssertTrue(packs.label.contains("2"))
        let basis = app.staticTexts["aConversionBasis"]
        reveal(basis)
        let originalBasis = basis.label
        XCTAssertTrue(originalBasis.contains("120.0 grams"))
        XCTAssertTrue(originalBasis.contains("1 cup"))
        saveAndAssertDurableStatus()

        app.terminate()
        launch(reset: false)
        reopenSavedRecord(recordsLabel: "Records", item: "Measured oats")
        assertMoney("aTotal", amount: "5.00")
        reveal(basis); XCTAssertEqual(basis.label, originalBasis)
    }

    func testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer() throws {
        launch(language: "es")
        XCTAssertEqual(app.buttons["newComparison"].label, "Comparar paquetes")
        openEmptyComparison()
        // Use the existing displayed-key path for each whole-number input.
        // Grouped typeText followed by Done stalled XCTest's animation wait here.
        for entry in [("itemName", "Abuela’s tortillas"), ("needed", "12"), ("stock", "1 1/2"),
                      ("aQuantity", "8"), ("aPrice", "3"),
                      ("bQuantity", "6"), ("bPrice", "2")] {
            if entry.0 == "stock" { tap(app.buttons["comparisonStockDisclosure"]) }
            type([entry])
        }
        compare()
        assertScope("Comparación de un solo artículo")
        assertContains("Abuela’s tortillas")
        assertContains("Confirmado en casa para esta necesidad: 1 1/2 unidades")
        assertContains("Cantidad que falta tras descontar lo confirmado en casa: 10 1/2 unidades")
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
        assertContains("Confirmado en casa para esta necesidad: 1 1/2 unidades")
        assertContains("Cantidad que falta tras descontar lo confirmado en casa: 10 1/2 unidades")
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
        let totalFrame = app.staticTexts["aTotal"].frame
        XCTAssertGreaterThan(totalFrame.height, 0)
        XCTAssertLessThanOrEqual(totalFrame.width, app.windows.firstMatch.frame.width)
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
        // The visible control is a Button. Restrict resolution to that type;
        // the broad descendant query can stall before synthesizing this tap.
        let edit = app.buttons["editComparison"]
        revealFullyInComparison(edit)
        XCTAssertFalse(app.navigationBars.buttons["editComparison"].exists,
                       "Accessibility-sized Edit must use the expandable content row")
        XCTAssertGreaterThan(edit.frame.height, 44, "The large text label must grow beyond the compact toolbar height")
        captureComparisonFrames("Largest-text-Edit")
        screenshot("Largest-text-Edit-fully-visible")
        edit.tap()
        let name = comparisonInput("itemName")
        reveal(name)
        XCTAssertEqual(name.value as? String, "Accessible edit wraps")
        compare()
        assertKnownTotals()
    }

    func testLargestTextComparisonSavesFromNavigationAndReopensOneRecord() {
        launch(largeDark: true)
        openEmptyComparison()
        enterComparison(item: "Measured oats", firstQuantity: "8", cap: "30")
        compare()
        let bar = app.navigationBars.firstMatch
        let save = bar.buttons["comparison.toolbarSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 5) && save.isHittable)
        XCTAssertEqual(save.label, "Save comparison")
        save.doubleTap()
        let saved = bar.descendants(matching: .any).matching(identifier: "comparison.toolbarSaved").firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertEqual(saved.label, "Saved on this iPhone")
        XCTAssertFalse(save.exists)

        app.terminate()
        launch(reset: false, largeDark: true)
        reopenSavedRecord(recordsLabel: "Records", item: "Measured oats")
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertFalse(save.exists)
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
        let disclosure = app.buttons["shop.moreTools"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["deviceShortcuts"].exists)
        let compare = app.buttons["newComparison"]
        let startPickup = app.buttons["openPickupList"]
        XCTAssertTrue(shopViewport.contains(compare.frame))
        XCTAssertTrue(shopViewport.contains(startPickup.frame))
        let shortcuts = app.shopToolButton("deviceShortcuts")
        revealFullyInShop(shortcuts)
        XCTAssertLessThan(compare.frame.midY, shortcuts.frame.minY)
        XCTAssertLessThan(startPickup.frame.midY, shortcuts.frame.minY)
        // Accessibility can report the 44-point frame as 43.99999999999994.
        let frameRoundingTolerance: CGFloat = 1e-9
        XCTAssertGreaterThanOrEqual(shortcuts.frame.height, 44 - frameRoundingTolerance)
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
        let shortcut = app.shopToolButton("urgentRepairShortcut")
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
        let save = app.buttons["saveComparison"]
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
        let grocery = element("quickGrocery.name")
        let disclosure = app.buttons["shop.moreTools"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(grocery.waitForExistence(timeout: 5))
        let groceryBefore = grocery.frame
        let disclosureBefore = disclosure.frame
        captureShopFrames("Initial-Shop-before-audit")
        screenshot("Initial-Shop-before-audit")
        XCTAssertNoThrow(try auditAccessibility("Initial Shop"))
        let groceryAfter = grocery.frame
        XCTAssertEqual(groceryAfter.height, groceryBefore.height, accuracy: 1,
                       "The empty field should return to one line at the original text size.")
        XCTAssertEqual(disclosure.frame.minY - groceryAfter.minY, disclosureBefore.minY - groceryBefore.minY, accuracy: 1,
                       "The restored text size should preserve the distance between the field and tools disclosure.")
        // Retain the initial audit; add full-category coverage after the
        // complete repair shortcut is visible above bottom navigation.
        revealFullyInShop(app.shopToolButton("urgentRepairShortcut"))
        captureShopFrames("Complete-repair-shortcut-before-audit")
        screenshot("Complete-repair-shortcut-before-audit")
        XCTAssertNoThrow(try auditAccessibility("Complete repair shortcut"))
        openEmptyComparison()
        enterComparison(item: "Audit wraps", firstQuantity: "8", cap: "30", groupPackFields: true)
        compare()
        // Cover both the initial viewport and the lower results after scrolling.
        screenshot("Initial-result-before-audit")
        captureComparisonFrames("Initial-result-before-audit")
        // Keep audit failures separate from persistence so every functional
        // restart check still runs. No issue categories/elements are filtered.
        XCTAssertNoThrow(try auditAccessibility("Initial comparison results"))
        assertKnownTotals()
        let headroom = app.staticTexts["Room within the item limit: $26.00"]
        reveal(headroom)
        positionPackBForAudit(headroom: headroom)
        screenshot("Scrolled-result-before-audit")
        captureComparisonFrames("Scrolled-result-before-audit")
        XCTAssertNoThrow(try auditAccessibility("Scrolled comparison results"))
        // Additional coverage: retain both earlier audits, then audit the complete
        // Save control in the visible content area. No issue is suppressed.
        revealFullyInComparison(element("saveComparison"))
        captureComparisonFrames("Complete-Save-before-audit")
        screenshot("Complete-Save-before-audit")
        XCTAssertNoThrow(try auditAccessibility("Complete Save control"))
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
        let grocery = element("quickGrocery.name")
        let addButton = app.buttons["quickGrocery.add"]
        let rows = ["Window: \(app.windows.firstMatch.frame)", "Shop scroll: \(scroll.frame)",
                    grocery.exists ? "Grocery field: \(grocery.frame)" : "Grocery field: absent",
                    addButton.exists ? "Add grocery: \(addButton.frame)" : "Add grocery: absent",
                    "Navigation: \(app.navigationBars.firstMatch.frame)", "Tabs: \(tabFrameDescription)",
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

    private func positionPackBForAudit(headroom: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let header = app.staticTexts["bHeader"]
        let source = app.staticTexts["comparisonSourceNote"]
        let purchase = app.staticTexts["bPacks"]
        let total = app.staticTexts["bTotal"]
        // Keep the complete purchase, limit and source together in the middle viewport.
        // A hittable result can have ink behind the navigation bar or the following row
        // partly under the tab bar after a swipe. The other audits cover both ends.
        reveal(source, file: file, line: line)
        for _ in 0..<10 {
            let viewport = comparisonViewport
            guard header.exists, source.exists, viewport.height > 0 else { break }
            let group = header.frame.union(source.frame)
            // Align the final source row to the bottom content inset. The last
            // audit separately shows the full Save button on the following row.
            let offset = viewport.maxY - 12 - group.maxY
            if abs(offset) <= 12 && viewport.contains(group) {
                for row in [header, total, purchase, headroom, source] {
                    XCTAssertTrue(row.exists && row.isHittable && viewport.contains(row.frame),
                                  "Expected a complete Pack B result in the audit viewport: \(row)", file: file, line: line)
                }
                return
            }
            guard group.height <= viewport.height else { break }
            let window = app.windows.firstMatch
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX, dy: viewport.midY - window.frame.minY))
            let distance = min(viewport.height / 3, max(-viewport.height / 3, offset))
            let end = start.withOffset(CGVector(dx: 0, dy: distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        captureComparisonFrames("Pack-B-position-failure")
        XCTFail("Could not position the complete Pack B results and their source for the audit.", file: file, line: line)
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
                    "Navigation: \(app.navigationBars.firstMatch.frame)", "Tabs: \(tabFrameDescription)",
                    "Visible results: \(comparisonViewport)"]
        for id in ["editComparison", "aHeader", "bHeader", "comparisonSourceNote", "saveComparison", "savedStatus", "comparisonSavedDetails"] {
            let target = element(id)
            rows.append(target.exists ? "\(id): \(target.frame); hittable=\(target.isHittable); \(target.label)" : "\(id): absent from current hierarchy")
        }
        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.name = name + " — exact frames"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func auditAccessibility(_ viewport: String) throws {
        try XCTContext.runActivity(named: "Accessibility audit — " + viewport) { _ in
            try app.performAccessibilityAudit { issue in
                let context = "\(viewport); category=\(issue.auditType.rawValue); \(issue.compactDescription)"
                let element = issue.element
                if let element {
                    print("Accessibility audit [\(context)]: \(issue.detailedDescription), id=\(element.identifier), label=\(element.label), frame=\(element.frame)")
                } else {
                    print("Accessibility audit [\(context)]: \(issue.detailedDescription), no element supplied")
                }
                // XCTest can supply only a screenshot. Keep the hierarchy and public audit category.
                let hierarchy = element?.debugDescription ?? self.app.debugDescription
                let details = XCTAttachment(string: "\(context)\n\(issue.detailedDescription)\n\(hierarchy)")
                details.name = "Accessibility issue — " + context
                details.lifetime = .keepAlways
                self.add(details)
                return false // Record every issue as a failure; never suppress it.
            }
        }
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
        XCTAssertTrue(tabButton(language == "es" ? "Compras" : "Shop", symbol: "cart").waitForExistence(timeout: 15))
    }

    private func tabButton(_ label: String, symbol: String) -> XCUIElement {
        let tab = app.tabBars.buttons[label]
        if tab.exists { return tab }
        // iPhone Duo exposes native side tabs as labeled symbol buttons.
        return app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", label, symbol)).firstMatch
    }

    private var tabFrameDescription: String {
        let bar = app.tabBars.firstMatch
        return bar.exists ? String(describing: bar.frame) : "No bottom tab bar"
    }

    private func openEmptyComparison() {
        tap(element("newComparison"))
        let name = comparisonInput("itemName")
        reveal(name)
        XCTAssertTrue(name.exists)
        let value = name.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == "Item name" || value == "Nombre del artículo", "Fresh form must not contain seeded food: \(value)")
    }

    private func enterComparison(item: String, firstQuantity: String?, cap: String? = nil, groupPackFields: Bool = false, omitPriceFor: String? = nil) {
        type([("itemName", item)])
        type([("needed", "12")])
        for (prefix, quantity, price) in [("a", firstQuantity, "3"), ("b", "6", "2")] {
            var fields: [(id: String, text: String)] = []
            if let quantity { fields.append((prefix + "Quantity", quantity)) }
            if prefix != omitPriceFor { fields.append((prefix + "Price", price)) }
            if groupPackFields { type(fields) }
            else { for field in fields { type([field]) } }
        }
        if let cap { type([("itemCap", cap)]) }
    }

    private func compare() {
        // The shipping action is a button. A broad Any query traverses text-field
        // placeholder snapshots while this large-text Form is scrolling.
        tap(app.buttons["compare"])
        // At accessibility sizes the first result can fill the screen before List creates its Edit row.
        XCTAssertTrue(element("comparisonResultsScroll").waitForExistence(timeout: 5))
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
        let total = app.staticTexts[id]
        reveal(total)
        let label = total.label
        XCTAssertTrue(label.contains(amount), "Expected \(amount) in accessible cost: \(label)")
        XCTAssertTrue(label.contains("$") || label.contains("USD"))
        screenshot("Visible-\(id)-\(amount.replacingOccurrences(of: ".", with: "-"))")
    }

    private func assertScope(_ label: String) { assertContains(label) }

    private func assertContains(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target)
        XCTAssertTrue(target.exists, "Missing visible text: \(text)")
    }

    private func saveAndAssertDurableStatus(savedLabel: String = "Saved on this iPhone") {
        let save = app.buttons["saveComparison"]
        revealFullyInComparison(save)
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertSavedStatus(savedLabel)
        XCTAssertFalse(app.buttons["saveComparison"].exists)
    }

    private func assertSavedStatus(_ text: String) {
        // SwiftUI combines the saved label with its date; either the child ID or
        // the combined accessibility element may own the final accessible text.
        let status = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(status)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Save must publish success only after durable storage")
    }

    private func editComparisonResult() {
        let edit = app.buttons["editComparison"]
        let results = element("comparisonResultsScroll")
        // The entire visible Edit row, including the space beside the word, must activate.
        for _ in 0..<8 where !edit.exists { results.swipeDown(velocity: .slow) }
        revealFullyInComparison(edit)
        edit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(results.waitForNonExistence(timeout: 5), "Edit must open the comparison input form")
    }

    private func reopenSavedRecord(recordsLabel: String, item: String) {
        tap(tabButton(recordsLabel, symbol: "clock.arrow.circlepath"))
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
        let rows = app.buttons.matching(identifier: "savedComparison")
        let row = rows.firstMatch
        // Records creates offscreen rows lazily, especially at accessibility text sizes.
        reveal(row)
        XCTAssertTrue(row.exists && row.isHittable)
        XCTAssertEqual(rows.count, 1, "One save must produce one durable record")
        XCTAssertTrue(row.label.contains(item), "Original item name should survive restart: \(row.label)")
        row.tap()
        XCTAssertTrue(element("comparisonResultsScroll").waitForExistence(timeout: 5))
    }

    private func comparisonInput(_ id: String) -> XCUIElement {
        // SwiftUI's vertical item-name field is a TextView on iOS 17 and a TextField on iOS 27.
        id == "itemName" ? element(id) : app.textFields[id]
    }

    private func focusComparisonInput(_ field: XCUIElement, id: String) {
        reveal(field)
        if id == "itemName" {
            // Tap the center of the multiline name on both TextView and TextField runtimes.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            field.tap()
        }
    }

    private func dismissComparisonKeyboard(_ identifier: String) {
        // Sample the focused button and keyboard together. Separate live queries can
        // cross a keyboard transition or spend the entire wait resolving one element.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let root = try? self.app.snapshot() else { return false }
            var nodes = [root]
            var keyboard: CGRect?
            var button: CGRect?
            while let node = nodes.popLast() {
                nodes.append(contentsOf: node.children)
                guard !node.frame.isEmpty, root.frame.intersects(node.frame) else { continue }
                if node.elementType == .keyboard { keyboard = node.frame }
                if node.elementType == .button, node.identifier == identifier { button = node.frame }
            }
            guard let keyboard, let button else { return false }
            return button.maxY <= keyboard.minY + 1
        }, object: nil)
        guard XCTWaiter.wait(for: [visible], timeout: 10) == .completed else {
            XCTFail("Expected \(identifier) above the visible comparison keyboard")
            return
        }
        app.buttons[identifier].tap()
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: identifier))
    }

    private func type(_ fields: [(id: String, text: String)]) {
        var previousDone: String?
        for entry in fields {
            let (id, text) = entry
            let field = comparisonInput(id)
            // A partially exposed row can be hittable underneath the keyboard accessory.
            if let previousDone {
                let done = app.buttons[previousDone]
                if done.exists && (!field.exists || !field.isHittable || field.frame.midY >= done.frame.minY) {
                    dismissComparisonKeyboard(previousDone)
                }
            }
            focusComparisonInput(field, id: id)
            let fieldDone = app.buttons["comparison.done." + id]
            if !fieldDone.exists && !fieldDone.waitForExistence(timeout: 3) {
                if let previousDone, app.buttons[previousDone].exists { dismissComparisonKeyboard(previousDone) }
                focusComparisonInput(field, id: id)
                guard fieldDone.exists || fieldDone.waitForExistence(timeout: 3) else {
                    XCTFail("The comparison field must own keyboard focus before typing: " + id)
                    return
                }
            }
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.exists || keyboard.waitForExistence(timeout: 5))
            // For a standalone whole number, operate the displayed keys before
            // dismissing the numeric keyboard. The needed amount may have multiple digits.
            let numericFields = ["needed", "stock", "aQuantity", "aPrice", "bQuantity", "bPrice", "itemCap"]
            if fields.count == 1, numericFields.contains(id), !text.isEmpty,
               text.allSatisfy({ $0.isASCII && $0.isNumber }) {
                for digit in text {
                    let key = keyboard.keys[String(digit)]
                    XCTAssertTrue(key.waitForExistence(timeout: 5) && key.isHittable)
                    key.tap()
                }
            } else if field.exists {
                field.typeText(text)
            } else {
                // At accessibility sizes the focused row can scroll out of the snapshot.
                app.typeText(text)
            }
            previousDone = "comparison.done." + id
        }
        if let previousDone { dismissComparisonKeyboard(previousDone) }
        for (id, text) in fields {
            let field = comparisonInput(id)
            // UIKit exposes the value of an offscreen row while it is still in the hierarchy.
            if !field.exists { reveal(field) }
            XCTAssertEqual(field.value as? String, text, "Typed input must reach its intended field")
        }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func revealReviewAction(_ target: XCUIElement, above summary: XCUIElement,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let form = app.collectionViews["ledgerImportForm"]
        let top = max(form.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        let area = CGRect(x: form.frame.minX + 18, y: top, width: form.frame.width - 36,
                          height: summary.frame.minY - top)
        XCTAssertGreaterThan(area.height, 44, file: file, line: line)
        for _ in 0..<36 {
            let frame = target.exists ? target.frame : .zero
            if !frame.isEmpty && (area.minY...area.maxY).contains(frame.midY) && target.isHittable { return }
            app.scrollForm(in: area, upward: frame.isEmpty || frame.midY > area.minY, besideFields: true)
        }
        XCTFail("Could not reach the review action above the pinned totals: \(target)", file: file, line: line)
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
        // After keyboard dismissal, a previous row can sit above the visible form.
        if target.exists {
            let frame = target.frame
            if !frame.isEmpty && frame.midY < scroll.frame.midY {
                scroll.swipeDown(velocity: .slow)
                if target.exists && target.isHittable { return }
            }
        }
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
