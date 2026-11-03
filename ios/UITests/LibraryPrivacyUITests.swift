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
    func launch(_ mode: String, reset: Bool = true) {
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["--ui-testing", mode, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-library-privacy-fixture") }
        app.launch()
    }
    func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    func button(_ id: String) -> XCUIElement { app.buttons.matching(identifier: id).firstMatch }
    func waitForLabel(_ id: String, _ expected: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element(id))], timeout: 15) == .completed
    }
    func assertText(_ text: String) {
        let value = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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
        XCTAssertTrue(element("records.error").waitForExistence(timeout: 12))
        reveal(element("records.error"), requiresHitTarget: false)
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
        tap(app.buttons["Choose Recipe JSON-LD file…"], upward: upward)
    }
    private func assertLibraryPreview() {
        reveal(element("records.applyImport"), requiresHitTarget: false)
        XCTAssertTrue(element("records.applyImport").exists)
        assertText("2 recipes ready · 2 duplicates · 2 rows skipped")
        assertText("Unsupported fields: nutrition")
        assertText("Arroz sin cambiar")
        assertText("Lemon pasta")
        assertText("Absent here — recover separately")
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
        app.buttons["Cancel"].tap()
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
