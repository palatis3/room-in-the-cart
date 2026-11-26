#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Dedicated fixture build only. The fixture supplies fictional starting records
/// and system-picker input; production screens own review/cancel/apply/undo and
/// spelling changes. Viewport assertions do not establish spoken VoiceOver focus.
@MainActor class LibraryPrivacyUITestCase: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Library privacy acceptance failure") }
        app.terminate()
    }
    func launch(_ mode: String, reset: Bool = true, arguments: [String] = []) {
        // Keep the XCTest runtime-logging crash workaround limited to iOS 17.
        if #unavailable(iOS 18) { app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable" }
        app.launchArguments = ["--ui-testing", mode, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        if reset { app.launchArguments.append("--reset-library-privacy-fixture") }
        app.launch()
    }
    func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    func button(_ id: String) -> XCUIElement { app.buttons.matching(identifier: id).firstMatch }
    func waitForLabel(_ id: String, _ expected: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element(id))], timeout: 15) == .completed
    }
    func assertText(_ text: String, in container: XCUIElement? = nil) {
        let value = (container ?? app).staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(value, requiresHitTarget: false)
        XCTAssertTrue(value.exists, text)
    }
    func tap(_ value: XCUIElement, upward: Bool = false) {
        reveal(value, upward: upward)
        XCTAssertTrue(value.isHittable, value.debugDescription)
        value.tap()
    }
    func setSwitch(_ value: XCUIElement, enabled: Bool) {
        reveal(value)
        if value.value as? String != (enabled ? "1" : "0") {
            value.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }
    func assertResultVisible(_ id: String, _ text: String) {
        XCTAssertTrue(waitForLabel(id, text))
        let result = element(id)
        // Do not scroll: the production action must bring its own durable result
        // into the viewport, including when the last focused rule disappears.
        XCTAssertTrue(viewport().contains(CGPoint(x: result.frame.midX, y: result.frame.midY)), "The action result was not brought into view: " + result.debugDescription)
    }
    func back(to title: String) {
        for _ in 0..<12 {
            if app.navigationBars[title].exists { return }
            let back = app.navigationBars.buttons.allElementsBoundByIndex.first {
                $0.exists && $0.isHittable && $0.frame.midX < app.frame.midX
            }
            guard let back else { break }
            back.tap()
        }
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8), app.debugDescription)
    }
    func reveal(_ value: XCUIElement, upward: Bool = false, requiresHitTarget: Bool = true) {
        for attempt in 0..<48 {
            let area = viewport()
            if value.exists && (!requiresHitTarget || value.isHittable),
               area.contains(CGPoint(x: value.frame.midX, y: value.frame.midY)) { return }
            let contentUp: Bool
            if value.exists && !value.frame.isEmpty { contentUp = value.frame.midY > area.midY }
            else { contentUp = attempt < 24 ? !upward : upward }
            scrollContent(upward: contentUp)
        }
        XCTAssertTrue(value.exists && (!requiresHitTarget || value.isHittable) && viewport().contains(CGPoint(x: value.frame.midX, y: value.frame.midY)), value.debugDescription)
    }
    func viewport() -> CGRect {
        let bounds = app.frame, keyboard = app.keyboards.firstMatch, tabs = app.tabBars.firstMatch
        let keyboardTop = keyboard.exists ? keyboard.frame.minY : bounds.maxY
        let tabTop = tabs.exists && tabs.isHittable && !tabs.frame.isEmpty ? tabs.frame.minY : bounds.maxY
        let navigation = app.navigationBars.firstMatch
        let top = navigation.exists && navigation.isHittable ? navigation.frame.maxY : bounds.minY + 88
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, min(keyboardTop, tabTop) - top - 4))
    }
    func scrollContent(upward: Bool) {
        let area = viewport().insetBy(dx: 24, dy: 16), bounds = app.frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY)))
    }
    func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}

@MainActor final class RecipeLibraryAcceptanceUITests: LibraryPrivacyUITestCase {
    func testPrivateStepNoteReopensOnNextCookAndCanBeDeleted() {
        launch("--recipe-library-fixture", arguments: ["--recipe-full-screen"])
        tap(button("records.recovered.Existing family soup"))
        tap(button("records.openSavedRecipe"))
        tap(button("cooking.openRecipe"))
        tap(button("cooking.stepNote.add"))
        let field = element("cooking.stepNote.text")
        tap(field)
        field.typeText("Use half the lime.")
        let save = button("cooking.stepNote.save")
        XCTAssertTrue(save.isHittable)
        save.tap()
        assertText("Use half the lime.")
        tap(button("cooking.end"))
        tap(button("cooking.confirmEnd"))
        tap(button("cooking.openRecipe"))
        assertText("Keep the existing instructions.")
        assertText("Use half the lime.")
        tap(app.buttons["Edit note"])
        tap(app.buttons["Delete note"])
        reveal(button("cooking.stepNote.add"))
        XCTAssertFalse(app.staticTexts["Use half the lime."].exists)
    }

    func testNotesOnlyRecipeReviewsOnlySelectedWordsBeforePlayback() {
        launch("--recipe-library-fixture", arguments: ["--recipe-notes-only", "--recipe-full-screen"])
        tap(button("records.recovered.Notes-only soup"))
        tap(button("records.openSavedRecipe"))
        tap(button("cooking.openRecipe"))
        assertText("Private family note.")
        let play = button("capture.readback.play")
        XCTAssertFalse(play.exists)
        tap(button("cooking.chooseNotes"))
        tap(app.buttons["Simmer for 10 minutes."])
        let excerpt = element("cooking.noteExcerpt")
        XCTAssertEqual(excerpt.value as? String, "Simmer for 10 minutes.")
        XCTAssertFalse(play.exists)
        let prepare = app.buttons["Prepare selected words for read-aloud"]
        tap(excerpt)
        excerpt.typeText("x")
        XCTAssertFalse(prepare.isEnabled)
        excerpt.press(forDuration: 1.2)
        let menuItem = app.menuItems["Select All"]
        let selectAll = menuItem.exists ? menuItem : app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        excerpt.typeText("10 minutes")
        tap(button("cooking.noteDone"))
        XCTAssertEqual(excerpt.value as? String, "10 minutes")
        tap(prepare)
        reveal(play)
        XCTAssertTrue(app.staticTexts["10 minutes"].exists)
        XCTAssertTrue(app.buttons["Stop readback"].exists)
        XCTAssertFalse(app.buttons["Stop readback"].isEnabled)
        capture("Notes-only recipe with selected instruction ready and playback stopped")
    }

    func testCookingTimersRestoreInSpanishAtLargestTextAndEndOnRequest() throws {
        launch("--recipe-library-fixture")
        tap(button("records.recovered.Existing family soup"))
        tap(app.buttons["Open saved recipe"])
        tap(button("cooking.openRecipe"))
        assertText("Keep the existing instructions.")
        assertText("2 cups beans")
        tap(button("cooking.prepareReadback"))
        reveal(button("capture.readback.play"))
        tap(button("cooking.start"))
        tap(button("cooking.start"))
        tap(button("cooking.pause.0"), upward: true)
        XCTAssertTrue(element("cooking.paused.0").exists)
        app.terminate()
        // The diagnostic fixture toolbar is outside the app's navigation stack.
        // Give the production Records and cooking screens the whole large-text viewport.
        app.launchArguments = ["--ui-testing", "--recipe-library-fixture", "--recipe-full-screen", "-AppleLanguages", "(es)",
            "-AppleLocale", "es_US", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        tap(button("records.recovered.Existing family soup"))
        tap(button("records.openSavedRecipe"))
        tap(button("cooking.openRecipe"))
        XCTAssertTrue(app.navigationBars["Modo de cocina"].waitForExistence(timeout: 8))
        // The underlying Records form repeats the recipe text. Keep scrolling and
        // assertions on the presented cooking form, even as its step goes offscreen.
        let cooking = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.first {
            $0.staticTexts["Paso 1 de 1"].exists
        })
        assertText("Keep the existing instructions.", in: cooking)
        assertText("2 cups beans", in: cooking)
        reveal(element("cooking.paused.0"), requiresHitTarget: false)
        XCTAssertEqual(element("cooking.paused.0").label, "En pausa")
        let resume = button("cooking.resume.0")
        reveal(resume)
        XCTAssertEqual(resume.label, "Temporizador 1, Reanudar temporizador")
        let remove = button("cooking.remove.0")
        XCTAssertGreaterThanOrEqual(remove.frame.minY, resume.frame.maxY)
        capture("Reanudar temporizador completo y separado de eliminar")
        reveal(element("cooking.timer.1"), requiresHitTarget: false)
        XCTAssertEqual(element("cooking.timer.1").label, "Temporizador 2")
        capture("Dos temporizadores guardados con texto grande")
        tap(button("cooking.end"))
        tap(button("cooking.confirmEnd"))
        tap(button("cooking.openRecipe"))
        reveal(button("cooking.start"))
        XCTAssertFalse(element("cooking.timer.0").exists)
    }

    func testFailedRecipeLinkCanBeSavedOfflineAndSupplementedAfterRelaunch() {
        launch("--recipe-library-fixture")
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 25))
        tap(button("records.recipeLink"))
        let address = app.textFields["HTTPS recipe link"]
        tap(address)
        address.typeText("https://example.org/frijoles")
        tap(app.buttons["Read recipe"])
        assertText("Could not read this recipe.")
        tap(button("records.keepPartialLink"))
        assertText("Missing ingredients")
        tap(button("records.saveRecipeDraft"))
        assertResultVisible("records.status", "File saved.")
        assertSavedRecipes(1)
        app.terminate()
        launch("--recipe-library-fixture", reset: false)
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 25))
        chooseRecipeFile()
        tap(app.buttons["Edit recipe, example.org"])
        tap(app.buttons["Add missing text from a screenshot or paste"])
        let supplement = app.textFields["Review or paste the missing text"]
        tap(supplement)
        supplement.typeText("250 g de frijoles")
        dismissRecipeKeyboard("records.recipeEditorDone")
        tap(app.buttons["Append to ingredients"])
        tap(app.buttons["Review recipe"])
        tap(element("records.applyImport"))
        assertSavedRecipes(2)
        tap(button("records.recovered.example.org"))
        tap(app.buttons["Open saved recipe"])
        assertText("250 g de frijoles")
        assertText("https://example.org/frijoles")
    }

    func testRecipeLinkAllowsMissingYieldCorrectionBeforeSaving() {
        launch("--recipe-library-fixture")
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 25))
        tap(button("records.recipeLink"))
        let address = app.textFields["HTTPS recipe link"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("https://example.org/soup")
        app.buttons["Read recipe"].tap()
        assertText("Missing servings or yield")
        tap(button("records.cancelImport"))
        assertSavedRecipes(1)

        tap(button("records.recipeLink"))
        tap(app.buttons["Choose a shared recipe link"])
        tap(app.buttons["https://example.org/soup"])
        XCTAssertEqual(address.value as? String, "https://example.org/soup")
        app.buttons["Read recipe"].tap()
        assertText("Missing servings or yield")
        assertSavedRecipes(1)
        tap(app.buttons["Edit recipe, Weeknight soup"])
        let yield = app.textFields["Servings or yield, in your words"]
        XCTAssertTrue(yield.waitForExistence(timeout: 10))
        yield.tap()
        yield.typeText("Two bowls")
        dismissRecipeKeyboard("records.recipeEditorDone")
        tap(app.buttons["Review ingredients and timers by step"])
        tap(button("records.cookingStep.0"))
        setSwitch(app.switches["records.stepIngredient.0"], enabled: true)
        let timer = app.textFields["Suggested timer in minutes (optional)"]
        tap(timer)
        timer.typeText("7")
        dismissRecipeKeyboard("records.stepTimerDone")
        tap(button("records.saveStepDetails"))
        back(to: "Edit recipe")
        tap(app.buttons["Review recipe"])
        tap(button("records.saveRecipeDraft"))
        assertResultVisible("records.status", "File saved.")
        assertSavedRecipes(1)
        app.terminate()
        launch("--recipe-library-fixture", reset: false)
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 25))
        chooseRecipeFile()
        assertText("Weeknight soup")
        tap(element("records.applyImport"))
        assertSavedRecipes(2)
        tap(button("records.recovered.Weeknight soup"))
        tap(app.buttons["Open saved recipe"])
        XCTAssertTrue(app.navigationBars["Saved recipe"].waitForExistence(timeout: 10))
        assertText("Two bowls")
        assertText("Simmer.")
        tap(app.buttons["Cooking steps"])
        tap(button("records.cookingStep.0"))
        assertText("Ingredients for this step")
        assertText("1 onion")
        assertText("Suggested timer: 7 min")
        capture("Recipe page corrected and saved")
    }

    func testImportedRecipeQuantityDismissesKeyboardAndRequiresExplicitPickupChoice() {
        launch("--recipe-library-fixture")
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 25))
        chooseRecipeFile()
        assertLibraryPreview()
        tap(element("records.applyImport"))
        assertSavedRecipes(3)

        tap(button("records.recovered.Arroz sin cambiar"))
        tap(app.buttons["Open saved recipe"])
        XCTAssertTrue(app.navigationBars["Saved recipe"].waitForExistence(timeout: 10))
        assertText("three plates + lunch")
        assertText("2 cans (15 oz) tomatoes")
        tap(app.buttons["Review for this pickup"])
        XCTAssertTrue(app.navigationBars["Dinner for this pickup"].waitForExistence(timeout: 10))
        enterMealAmount("3", in: app.textFields["ledgerDinnerServings"])
        enterMealAmount("2", in: app.textFields["Amount, unknown if blank"].firstMatch)
        tap(element("ledgerReviewDinner"))
        assertText("Servings: 3")
        assertText("2 items")
        XCTAssertTrue(waitForLabel("fixture.library.sourceUnchanged", "E01 local source unchanged: yes"))

        tap(element("ledgerSaveDinner"))
        XCTAssertTrue(app.navigationBars["Saved recipe"].waitForExistence(timeout: 10))
        assertText("three plates + lunch")
        assertText("2 cans (15 oz) tomatoes")
        XCTAssertTrue(waitForLabel("fixture.library.sourceUnchanged", "E01 local source unchanged: no"))
        XCTAssertTrue(waitForLabel("fixture.library.recipeCount", "E01 saved recipes: 3"))
        capture("E01 original recipe after explicit pickup choice")
    }

    private func dismissRecipeKeyboard(_ identifier: String) {
        let tip = app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."]
        if tip.exists {
            app.buttons["Continue"].tap()
            XCTAssertTrue(tip.waitForNonExistence(timeout: 5))
        }
        let done = app.buttons[identifier]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    private func enterMealAmount(_ value: String, in field: XCUIElement) {
        tap(field)
        XCTAssertTrue(field.value as? String == field.placeholderValue || field.value as? String == "", field.debugDescription)
        app.typeText(value)
        XCTAssertEqual(field.value as? String, value)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        let done = app.buttons["ledgerMealKeyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    func testDocumentedLibraryPreviewCancelCorruptPreservationApplyAndWholeBatchUndo() {
        launch("--recipe-library-fixture")
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 25))
        assertSavedRecipes(1)
        chooseRecipeFile()
        assertLibraryPreview()
        XCTAssertTrue(waitForLabel("fixture.library.fileSelections", "E01 picker selections: 1"))
        capture("E01 documented library review duplicate matches skips and unsupported fields")
        tap(element("records.cancelImport"))
        assertSavedRecipes(1)
        assertResultVisible("records.status", "Import cancelled. Your records are unchanged.")
        XCTAssertFalse(element("records.applyImport").exists)
        capture("E01 cancelled library review preserves saved recipe and local source")

        // These fixture buttons replace only the next operating-system picker
        // selection. They do not invoke the importer, its confirmation or undo.
        app.buttons["fixture.library.selectCorrupt"].tap()
        chooseRecipeFile(upward: true)
        reveal(element("records.error"), upward: true, requiresHitTarget: false)
        XCTAssertTrue(element("records.error").exists)
        XCTAssertFalse(element("records.applyImport").exists)
        assertSavedRecipes(1, allowsError: true)
        XCTAssertTrue(waitForLabel("fixture.library.fileSelections", "E01 picker selections: 2"))
        capture("E01 corrupt Recipe JSON-LD preserves existing records")

        app.buttons["fixture.library.selectLibrary"].tap()
        chooseRecipeFile(upward: true)
        assertLibraryPreview()
        tap(element("records.applyImport"))
        assertSavedRecipes(3)
        assertResultVisible("records.status", "Saved separate recovered copies. Your current work is unchanged.")
        capture("E01 reviewed whole recipe batch applied as separate saved copies")
        let rice = button("records.recovered.Arroz sin cambiar")
        tap(rice)
        assertText("three plates + lunch")
        assertText("2 cans (15 oz) tomatoes")
        assertText("Keep the original words.")
        assertText("https://recipe-import.invalid/arroz")
        capture("E01 imported original yield ingredients instructions and inert source preserved")
        tap(app.buttons["Undo imported batch"], upward: true)
        assertSavedRecipes(1)
        assertResultVisible("records.status", "The imported batch was undone.")
        XCTAssertFalse(button("records.recovered.Arroz sin cambiar").exists)
        XCTAssertFalse(button("records.recovered.Lemon pasta").exists)
        XCTAssertTrue(waitForLabel("fixture.library.fileSelections", "E01 picker selections: 3"))
        capture("E01 whole-batch undo keeps pre-existing recipe and current pickup")
    }

    private func chooseRecipeFile(upward: Bool = false) {
        tap(button("records.chooseRecipeFile"), upward: upward)
    }
    private func assertLibraryPreview() {
        reveal(element("records.applyImport"), requiresHitTarget: false)
        XCTAssertTrue(element("records.applyImport").exists)
        assertText("2 recipes ready · 2 duplicates · 2 rows skipped")
        assertText("Unsupported fields: nutrition")
        assertText("Arroz sin cambiar")
        assertText("Lemon pasta")
        assertText("Ready to recover a separate copy")
        assertSavedRecipes(1)
    }
    private func assertSavedRecipes(_ count: Int, allowsError: Bool = false) {
        XCTAssertTrue(waitForLabel("fixture.library.recipeCount", "E01 saved recipes: \(count)"))
        XCTAssertTrue(waitForLabel("fixture.library.existingPreserved", "E01 original recipe preserved: yes"))
        XCTAssertTrue(waitForLabel("fixture.library.sourceUnchanged", "E01 local source unchanged: yes"))
        XCTAssertFalse(element("fixture.library.failure").exists)
        if !allowsError { XCTAssertFalse(element("records.error").exists) }
    }
}

@MainActor final class CorrectionPrivacyAcceptanceUITests: LibraryPrivacyUITestCase {
    func testSettingsNamedForgetLastEntryOutcomeConfirmedOptOutAndDisconnectedHelp() {
        launch("--correction-privacy-fixture")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 25))
        assertSpellingEvidence(english: 2, enabled: true)
        tap(element("settings.corrections"))
        XCTAssertTrue(element("corrections.enabled").waitForExistence(timeout: 12))
        let first = app.buttons["Forget spelling from tortiyas to tortillas"]
        let last = app.buttons["Forget spelling from frijolles to frijoles"]
        tap(first)
        assertResultVisible("corrections.result", "Forgot the spelling from tortiyas to tortillas.")
        assertSpellingEvidence(english: 1, enabled: true)
        XCTAssertFalse(first.exists)
        capture("N04 named spelling forget leaves durable scoped outcome")
        reveal(last)
        XCTAssertTrue(last.exists, "Forgetting one named rule must retain the other rule")
        tap(last)
        assertResultVisible("corrections.result", "Forgot the spelling from frijolles to frijoles.")
        assertSpellingEvidence(english: 0, enabled: true)
        XCTAssertFalse(last.exists)
        capture("N04 last saved spelling removed with visible action result")

        // A second explicit isolated install seed exercises opt-out with actual
        // saved entries. The fixture never repopulates an existing opted-out scope.
        app.terminate()
        launch("--correction-privacy-fixture")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 25))
        tap(element("settings.corrections"))
        XCTAssertTrue(element("corrections.enabled").waitForExistence(timeout: 12))
        setSwitch(element("corrections.enabled"), enabled: false)
        XCTAssertTrue(app.buttons["Turn off and delete these spellings"].waitForExistence(timeout: 8))
        let cancel = button("corrections.cancelDisable")
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        tap(cancel)
        assertSpellingEvidence(english: 2, enabled: true)
        XCTAssertFalse(element("corrections.result").exists, "Cancel must not report a deletion")
        setSwitch(element("corrections.enabled"), enabled: false)
        app.buttons["Turn off and delete these spellings"].tap()
        assertResultVisible("corrections.result", "Spelling memory is off. Saved spellings for this workspace and language were deleted.")
        assertSpellingEvidence(english: 0, enabled: false)
        capture("N04 confirmed opt-out deletes only selected workspace language")
        tap(element("corrections.language"))
        let spanishButton = app.buttons["Spanish spellings"]
        let spanish = spanishButton.waitForExistence(timeout: 3) ? spanishButton : app.staticTexts["Spanish spellings"]
        tap(spanish)
        XCTAssertTrue(app.buttons["Forget spelling from yogurth to yogur"].waitForExistence(timeout: 10))
        XCTAssertEqual(element("corrections.enabled").value as? String, "1")
        assertSpellingEvidence(english: 0, enabled: false)
        capture("N04 separate Spanish spelling memory survives English opt-out")

        back(to: "Settings")
        tap(element("settings.privacy"), upward: true)
        assertText("Venture House Group LLC")
        capture("Native privacy and terms identify supplied operator offline")
        back(to: "Settings")
        tap(element("settings.support"), upward: true)
        let email = element("help.support.email")
        reveal(email)
        XCTAssertTrue((email.label + String(describing: email.value ?? "")).contains("hello@roominthecart.com"))
        let summary = element("help.support.summary")
        reveal(summary, requiresHitTarget: false)
        XCTAssertTrue(summary.label.contains("diagnostic-format: 1"))
        for privateValue in ["tortiyas", "frijolles", "yogurth", "Private fixture beans", "N04 unchanged local pickup"] {
            XCTAssertFalse(summary.label.contains(privateValue), "Support summary must not contain private fixture content")
        }
        capture("Native support shows supplied contact and redacted metadata without sending")
        back(to: "Settings")
        tap(element("settings.help"), upward: true)
        tap(element("help.topic.comparison"))
        assertText("Open Compare packs in Shop.")
        capture("Native offline pack comparison help in disconnected fixture")
        assertSpellingEvidence(english: 0, enabled: false)
    }

    private func assertSpellingEvidence(english: Int, enabled: Bool) {
        XCTAssertTrue(waitForLabel("fixture.corrections.english", "N04 English entries: \(english) · enabled: \(enabled ? "yes" : "no")"))
        XCTAssertTrue(waitForLabel("fixture.corrections.spanish", "N04 Spanish entries: 1 · enabled: yes"))
        XCTAssertTrue(waitForLabel("fixture.corrections.sourceUnchanged", "N04 local source unchanged: yes"))
        XCTAssertFalse(element("fixture.corrections.failure").exists)
    }
}
#endif
