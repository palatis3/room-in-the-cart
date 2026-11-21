import XCTest

/// Uses ordinary private pantry records, the shipping review controls and the system keyboard.
@MainActor final class PantryVoiceUITests: XCTestCase {
    private var app: XCUIApplication!
    private let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }

    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Pantry-voice-failure") }
        if app.state != .notRunning { app.terminate() }
    }

    func testEnglishMultiItemUseClarifiesTheBreadAndAmountAndSavesOnlyAfterReview() {
        openPantry(reset: true)
        let eggs = addLot("Eggs", amount: "6")
        let wheat = addLot("Wheat bread", amount: "7")
        let white = addLot("White bread", amount: "8")
        let flour = addLot("Flour", amount: "5")

        enterCommand("Hey I just used two eggs and two pieces of bread and some flour")
        XCTAssertFalse(app.buttons["pantry.voiceConfirm"].exists)
        tap(element("pantry.voiceLot.1"))
        let chooseWheat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Wheat bread")).firstMatch
        let chooseWhite = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "White bread")).firstMatch
        XCTAssertTrue(chooseWheat.exists && chooseWhite.exists)
        capture("Pantry-voice-01-choose-bread")
        tap(chooseWheat)
        tap(element("pantry.voiceUnit.1"))
        tap(app.buttons["units"])
        tap(element("pantry.voiceUseAmount.2"))
        fill("1", into: "pantry.voiceAmount.2")
        dismissVoiceKeyboard()
        tap(element("pantry.voiceUnit.2"))
        tap(app.buttons["units"])
        tap(app.buttons["pantry.voicePreview"])
        let expectedReview: [(food: String, remaining: String)] = [("Eggs", "4 units"), ("Wheat bread", "5 units"), ("Flour", "4 units")]
        for (index, expected) in expectedReview.enumerated() {
            let summary = element("pantry.voiceSummary.\(index)")
            reveal(summary)
            XCTAssertTrue(summary.label.contains(expected.food) && summary.label.contains(expected.remaining), summary.label)
        }
        capture("Pantry-voice-02-reviewed-uses")
        tap(app.buttons["pantry.voiceConfirm"])
        XCTAssertTrue(element("pantry.voiceSaved").waitForExistence(timeout: 10))
        app.terminate()
        openPantry(reset: false)
        assertLot(eggs, contains: "4 units")
        assertLot(wheat, contains: "5 units")
        assertLot(white, contains: "8 units")
        assertLot(flour, contains: "4 units")

        enterCommand("Delete the bread, I used it all")
        tap(element("pantry.voiceLot.0"))
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "White bread")).firstMatch)
        tap(app.buttons["pantry.voicePreview"])
        let removal = element("pantry.voiceSummary.0")
        reveal(removal)
        XCTAssertTrue(removal.label.contains("0 units"), removal.label)
        tap(app.buttons["pantry.voiceCancel"])
        assertLot(white, contains: "8 units")
        assertLot(wheat, contains: "5 units")
    }

    func testSpanishDateQuestionDistinguishesThePrintedWordingFromMissingEvidence() {
        openPantry(reset: true, spanish: true)
        let recorded = addLot("Salsa de tomate clásica", amount: "2")
        let unrecorded = addLot("Salsa de tomate picante", amount: "3")
        tap(app.buttons[recorded])
        tap(app.buttons["pantry.packageDate"])
        let wording = "CONSUMIR PREFERENTEMENTE ANTES DE 03/04"
        fill(wording, into: "packageDate.wording")
        let done = app.buttons["packageDate.done"]
        if done.exists { tap(done) }
        // Leave both possible interpretations unselected. Only the literal label should survive reopening.
        reveal(app.buttons["4 de marzo"])
        reveal(app.buttons["3 de abril"])
        XCTAssertFalse(app.textFields["packageDate.year"].exists)
        tap(app.buttons["packageDate.save"])
        let original = "Texto impreso original"
        let printedWording = app.descendants(matching: .any).matching(NSPredicate(format:
            "label == %@ OR (label == %@ AND value == %@)", original + ", " + wording, original, wording)).firstMatch
        reveal(printedWording)
        app.terminate()
        openPantry(reset: false, spanish: true)
        for (id, name) in [(recorded, "Salsa de tomate clásica"), (unrecorded, "Salsa de tomate picante")] {
            let question = "¿Está vencida mi salsa de tomate?"
            enterCommand(question)
            XCTAssertTrue(app.navigationBars["Dictar o escribir"].exists)
            assertTranscript(question)
            XCTAssertFalse(element("pantry.voiceOriginal.0").exists)
            XCTAssertFalse(element("pantry.voiceDateResult").exists)
            let picker = app.buttons["pantry.voiceLot.0"]
            reveal(picker)
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[cd] %@", name + " · ")).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
            tap(choice)
            XCTAssertTrue(picker.label.localizedCaseInsensitiveContains(name), picker.label)
            tap(app.buttons["pantry.voiceDate"])
            let result = element("pantry.voiceDateResult")
            XCTAssertTrue(result.waitForExistence(timeout: 10))
            reveal(result)
            let noQuality = app.staticTexts["No hay un periodo de calidad verificado de FoodKeeper para este lote."]
            reveal(noQuality)
            if id == recorded {
                XCTAssertTrue(printedWording.exists, app.debugDescription)
                capture("Pantry-voice-03-fecha-impresa")
            } else {
                XCTAssertFalse(printedWording.exists)
                XCTAssertTrue(app.staticTexts["No hay una fecha impresa verificada para este envase."].exists, app.debugDescription)
            }
            XCTAssertFalse(app.buttons["pantry.voiceConfirm"].exists)
            app.terminate()
            openPantry(reset: false, spanish: true)
        }
        assertLot(recorded, contains: "2 unidades")
        assertLot(unrecorded, contains: "3 unidades")
    }

    func testEnglishLowStockKeepsItsWordingAndOffersRestockingSeparately() {
        checkLowStock(spanish: false)
    }

    func testSpanishLowStockKeepsItsWordingAndOffersRestockingSeparately() {
        checkLowStock(spanish: true)
    }

    private func checkLowStock(spanish: Bool) {
        let name = spanish ? "Kétchup" : "Ketchup"
        let used = spanish ? "Usé como la mitad de la botella de kétchup" : "I used about half the bottle of ketchup"
        let low = spanish ? "Me queda poco kétchup, me queda menos de media botella"
                          : "I'm running low on ketchup, I have less than half a bottle left"
        openPantry(reset: true, spanish: spanish)
        let id = addLot(name, amount: "3")

        // A fraction used tells the app nothing about the stock still present.
        enterCommand(used)
        XCTAssertFalse(app.buttons["pantry.voiceConfirm"].exists)
        let remaining = app.buttons["pantry.voiceRemaining.0"]
        reveal(remaining)
        remaining.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        tapRemainingChoice(spanish ? "No lo sé" : "Not sure", spanish: spanish)
        let unchanged = element("pantry.voiceStatus")
        reveal(unchanged)
        XCTAssertEqual(unchanged.label, spanish ? "No seleccionaste ningún cambio para la despensa." : "No pantry changes selected.")
        XCTAssertFalse(app.buttons["pantry.voicePreview"].exists)
        XCTAssertFalse(app.buttons["pantry.voiceConfirm"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        capture(spanish ? "Pantry-voice-sin-cambios" : "Pantry-voice-no-changes")
        tap(app.buttons["pantry.voiceCancel"])
        assertLot(id, contains: spanish ? "3 unidades" : "3 units")
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)

        let about = spanish ? "Me queda como media botella de kétchup" : "I have about half a bottle of ketchup left"
        enterCommand(about)
        assertTranscript(about)
        if !spanish {
            tap(element("pantry.voiceTranscript"))
            let input = element("pantry.voiceText")
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            XCTAssertEqual(input.value as? String, about)
            dismissVoiceKeyboard()
            tap(app.buttons["pantry.voiceReview"])
        }
        tap(app.buttons["pantry.voicePreview"])
        XCTAssertTrue(element("pantry.voiceSummary.0").waitForExistence(timeout: 8))
        tap(app.buttons["pantry.voiceCancel"])
        assertLot(id, contains: spanish ? "3 unidades" : "3 units")

        enterCommand(low)
        assertTranscript(low)
        tap(app.buttons["pantry.voicePreview"])
        let summary = element("pantry.voiceSummary.0")
        reveal(summary)
        capture(spanish ? "Pantry-voice-05-poco-ketchup" : "Pantry-voice-04-low-ketchup")
        tap(app.buttons["pantry.voiceConfirm"])
        XCTAssertTrue(element("pantry.voiceSaved").waitForExistence(timeout: 10))
        let saved = element("pantry.voiceSavedWording.0")
        reveal(saved)
        let observation = spanish ? "menos de media botella" : "less than half a bottle left"
        XCTAssertTrue(saved.label.localizedCaseInsensitiveContains(observation), saved.label)
        reveal(element("pantry.restock.review"))
        reveal(element("pantry.restock.checkDate"))
        XCTAssertFalse(system.alerts.firstMatch.exists)
        if !spanish {
            tap(app.buttons["pantry.restock.review"])
            let proposed = element("ledgerImportText")
            XCTAssertTrue(proposed.waitForExistence(timeout: 10))
            XCTAssertEqual(proposed.value as? String, name)
            tap(app.navigationBars.buttons["Close"])
            XCTAssertTrue(proposed.waitForNonExistence(timeout: 8))
            tap(app.buttons["pantry.restock.checkDate"])
            XCTAssertTrue(app.buttons["pantry.digest.saveDate"].waitForExistence(timeout: 8))
            XCTAssertFalse(system.alerts.firstMatch.exists)
        }

        app.terminate()
        openPantry(reset: false, spanish: spanish, expectEmptyShop: true)
        assertLot(id, contains: spanish ? "(estimación)" : "(estimate)")
        assertLot(id, contains: observation)
    }

    func testEnglishSavedUseCanOpenCloseAndReopenItsPersonalCheckDay() {
        checkSavedUseDate(spanish: false)
    }

    func testSpanishSavedUseCanOpenCloseAndReopenItsPersonalCheckDay() {
        checkSavedUseDate(spanish: true)
    }

    private func checkSavedUseDate(spanish: Bool) {
        let name = spanish ? "Arroz integral" : "Brown rice"
        let words = spanish ? "Usé arroz integral, creo que queda un poco." : "I used some brown rice."
        openPantry(reset: true, spanish: spanish)
        let lotID = addLot(name, amount: "2")
        tapPantryEntry(app.buttons["pantry.voiceEntry"])
        fill(words, into: "pantry.voiceText")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let reviewWords = app.buttons["pantry.voiceReview"]
        XCTAssertTrue(reviewWords.isHittable)
        XCTAssertLessThanOrEqual(reviewWords.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        reviewWords.tap()
        let picker = app.buttons["pantry.voiceRemaining.0"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8))
        assertTranscript(words)
        reveal(picker)
        picker.tap()
        tapRemainingChoice(spanish ? "Queda menos de la mitad" : "Less than half left", spanish: spanish)
        tap(app.buttons["pantry.voicePreview"])
        assertTranscript(words)
        tap(app.buttons["pantry.voiceConfirm"])
        let saved = element("pantry.voiceSaved")
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        let checkDay = app.buttons["pantry.restock.checkDate"]
        reveal(checkDay)
        tap(checkDay)
        let saveDate = app.buttons["pantry.digest.saveDate"]
        XCTAssertTrue(saveDate.waitForExistence(timeout: 8), app.debugDescription)
        tap(app.buttons["pantry.restock.closeDigest"])
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        reveal(checkDay)
        tap(checkDay)
        XCTAssertTrue(saveDate.waitForExistence(timeout: 8))
        tap(saveDate)
        XCTAssertTrue(element("pantry.digest.dateStatus").waitForExistence(timeout: 8))
        XCTAssertFalse(system.alerts.firstMatch.exists)
        tap(app.buttons["pantry.restock.closeDigest"])
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        app.terminate()
        openPantry(reset: false, spanish: spanish)
        tap(app.buttons[lotID])
        tap(app.buttons["pantry.usageHistory"])
        let count = element("pantry.usageCount")
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        XCTAssertTrue(count.label.contains("1") || (count.value as? String) == "1", count.debugDescription)
        XCTAssertTrue(element("pantry.usageEvent.0").exists)
        XCTAssertFalse(element("pantry.usageEvent.1").exists)
    }

    func testSpanishFirstFoodRecordsOneUnmeasuredUseAndKeepsMonthOnlyLabel() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(es)", "-AppleLocale", "es_MX"]
        app.launch()
        tap(app.tabBars.buttons["Despensa"])
        tap(app.buttons["pantry.setup.firstFood"])
        let name = app.textFields["pantry.foodName"]
        tap(name)
        name.typeText("Lentejas\n")
        tap(app.buttons["pantry.review"])
        tap(app.buttons["pantry.confirm"])
        let row = lot("Lentejas")
        tap(row)
        tap(app.buttons["pantry.voiceUsedSome"])
        tap(app.buttons["pantry.recordOneUse"])
        let history = app.buttons["pantry.usageHistory"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        let latest = NSPredicate(format: "label CONTAINS %@", "Usé un poco")
        expectation(for: latest, evaluatedWith: history)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(element("pantry.lotSummary").label.localizedCaseInsensitiveContains("cantidad desconocida"))
        tap(history)
        XCTAssertTrue(element("pantry.usageCount").label.contains("1") || element("pantry.usageCount").value as? String == "1")
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["pantry.packageDate"])
        let wording = "Consumo preferente: noviembre de 2026"
        fill(wording, into: "packageDate.wording")
        if app.buttons["packageDate.done"].exists { tap(app.buttons["packageDate.done"]) }
        XCTAssertEqual(app.switches["packageDate.hasDay"].value as? String, "0")
        tap(app.buttons["packageDate.save"])
        XCTAssertTrue(app.navigationBars["Lentejas"].waitForExistence(timeout: 8))
        app.terminate()
        openPantry(reset: false, spanish: true)
        tap(lot("Lentejas"))
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        expectation(for: latest, evaluatedWith: history)
        waitForExpectations(timeout: 8)
        tap(app.buttons["pantry.packageDate"])
        XCTAssertEqual(element("packageDate.wording").value as? String, wording)
        XCTAssertEqual(app.switches["packageDate.hasDay"].value as? String, "0")
    }

    func testUsedSomeFromBatchAndTypedUseProduceTwoPrivateHistoryEntries() {
        openPantry(reset: true)
        let id = addLot("Ketchup", amount: "3")
        tap(app.buttons[id])
        tap(app.buttons["pantry.voiceUsedSome"])
        XCTAssertTrue(app.navigationBars["Record use"].waitForExistence(timeout: 8))
        XCTAssertFalse(element("pantry.voiceOriginal.0").exists)
        tap(app.buttons["pantry.voiceHalf.0"])
        tap(app.buttons["pantry.voicePreview"])
        let preview = element("pantry.voiceSummary.0")
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertTrue(preview.label.contains("After this change, About half left (estimate)"), preview.label)
        tap(app.buttons["pantry.voiceConfirm"])
        XCTAssertTrue(element("pantry.voiceSaved").waitForExistence(timeout: 10))
        XCTAssertTrue(element("pantry.voiceSavedWording.0").label.contains("About half left"))
        tap(app.buttons["Done"])
        let detail = element("pantry.lotSummary")
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        XCTAssertTrue(detail.label.hasPrefix("Ketchup, About half left (estimate)"), detail.label)
        XCTAssertTrue(detail.label.contains("Available for other meals, Recount to check"), detail.label)
        app.terminate()

        openPantry(reset: false, expectEmptyShop: true)
        assertLot(id, contains: "About half left (estimate)")
        enterCommand("I used some ketchup")
        assertTranscript("I used some ketchup")
        let explanation = app.staticTexts["Record one use. The amount remaining will be unknown."]
        reveal(explanation)
        tap(app.buttons["pantry.voicePreview"])
        tap(app.buttons["pantry.voiceConfirm"])
        XCTAssertTrue(element("pantry.voiceSaved").waitForExistence(timeout: 10))
        app.terminate()

        openPantry(reset: false, expectEmptyShop: true)
        assertLot(id, contains: "amount unknown")
        tap(app.buttons[id])
        tap(app.buttons["pantry.usageHistory"])
        let count = element("pantry.usageCount")
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(count.label.contains("2") || (count.value as? String)?.contains("2") == true, count.debugDescription)
        let recent = element("pantry.usageCount30Days")
        XCTAssertTrue(recent.label.contains("2") || (recent.value as? String)?.contains("2") == true, recent.debugDescription)
        XCTAssertTrue(element("pantry.usageEvent.0").exists)
        XCTAssertTrue(element("pantry.usageEvent.1").exists)
        XCTAssertFalse(element("pantry.usageEvent.2").exists)
        capture("Pantry-voice-06-private-use-history")
    }

    func testSpanishContextualRemainingAnswerKeepsTheSelectedCustomFoodWithoutOfferingRestock() {
        openPantry(reset: true, spanish: true)
        let id = addLot("Caldo de la casa", amount: "4")
        enterCommand("Usé un poco de caldo de la casa")
        let lot = element("pantry.voiceLot.0")
        XCTAssertTrue(lot.label.localizedCaseInsensitiveContains("Caldo de la casa"), lot.label)
        let remaining = app.buttons["pantry.voiceRemaining.0"]
        reveal(remaining)
        remaining.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        tapRemainingChoice("Describir cuánto queda", spanish: true)
        let reply = "más de la mitad"
        fill(reply, into: "pantry.voiceRemainingText.0")
        dismissVoiceKeyboard()
        tap(app.buttons["pantry.voiceApplyRemaining.0"])
        XCTAssertTrue(lot.label.localizedCaseInsensitiveContains("Caldo de la casa"), lot.label)
        tap(app.buttons["pantry.voicePreview"])
        let summary = element("pantry.voiceSummary.0")
        reveal(summary)
        XCTAssertTrue(summary.label.localizedCaseInsensitiveContains(reply), summary.label)
        capture("Pantry-voice-08-estimacion-caldo")
        tap(app.buttons["pantry.voiceConfirm"])
        XCTAssertTrue(element("pantry.voiceSaved").waitForExistence(timeout: 8))
        XCTAssertFalse(element("pantry.restock.review").exists)
        app.terminate()
        openPantry(reset: false, spanish: true, expectEmptyShop: true)
        assertLot(id, contains: reply)
        assertLot(id, contains: "(estimación)")
    }

    func testOnDeviceDictationOffersTypingWhenRecognitionOrPermissionIsUnavailable() {
        app.resetAuthorizationStatus(for: .microphone)
        defer { app.resetAuthorizationStatus(for: .microphone) }
        openPantry(reset: true)
        tapPantryEntry(app.buttons["pantry.voiceEntry"])
        assertDictationIdle()
        let typed = "Is my ketchup expired"
        fill(typed, into: "pantry.voiceText")
        dismissVoiceKeyboard()
        tap(app.buttons["pantry.voice.start"])
        let alert = system.alerts.firstMatch
        if alert.waitForExistence(timeout: 4) {
            let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
            XCTAssertTrue(deny.waitForExistence(timeout: 4), alert.debugDescription)
            deny.tap()
        }
        let fallback = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@",
                                                            "pantry.voice.status", "you can type")).firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 10), app.debugDescription)
        capture("Pantry-voice-07-dictation-fallback")
        XCTAssertFalse(element("pantry.voice.listening").exists)
        XCTAssertFalse(element("pantry.voice.transcript").exists)
        XCTAssertEqual(element("pantry.voiceText").value as? String, typed)
        fill("?", into: "pantry.voiceText")
        dismissVoiceKeyboard()
        tap(app.buttons["pantry.voiceReview"])
        XCTAssertTrue(app.buttons["pantry.voiceDate"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(element("pantry.voiceConfirm").exists)
    }

    private func tapRemainingChoice(_ label: String, spanish: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let title = spanish ? "Indicar cuánto queda" : "Choose how much is left"
        let named = NSPredicate(format: "label == %@", label)
        XCTAssertTrue(app.buttons.matching(named).firstMatch.waitForExistence(timeout: 6),
                      app.debugDescription, file: file, line: line)
        // The same native confirmation dialog appears as a named Sheet on iOS 27 and Other on iOS 17.
        let sheet = app.sheets[title]
        let dialog = sheet.exists ? sheet : app.otherElements[title]
        XCTAssertTrue(dialog.exists, app.debugDescription, file: file, line: line)
        let choices = dialog.buttons.matching(named)
        XCTAssertEqual(choices.count, 1, dialog.debugDescription, file: file, line: line)
        XCTAssertTrue(choices.element.isHittable, dialog.debugDescription, file: file, line: line)
        choices.element.tap()
    }

    private func tapPantryEntry(_ entry: XCUIElement) {
        let list = app.collectionViews.firstMatch
        // After a lot is saved, the form may scroll to its status or last focused row.
        // Wait for an unobscured, settled row before using its center hit point.
        let area = app.frame.insetBy(dx: 12, dy: 130)
        for _ in 0..<5 {
            if entry.exists, entry.isHittable, area.contains(CGPoint(x: entry.frame.midX, y: entry.frame.midY)) { break }
            list.swipeDown()
        }
        var prior: CGRect?
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard entry.exists, entry.isHittable else { return false }
            let frame = entry.frame
            defer { prior = frame }
            return frame == prior && area.contains(CGPoint(x: frame.midX, y: frame.midY))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed, app.debugDescription)
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func assertDictationIdle() {
        XCTAssertTrue(app.buttons["pantry.voice.start"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(element("pantry.voice.listening").exists)
        XCTAssertFalse(element("pantry.voice.stop").exists)
        XCTAssertFalse(system.alerts.firstMatch.exists)
    }

    private func dismissVoiceKeyboard() {
        let done = app.buttons["pantry.voiceKeyboardDone"]
        if done.exists { tap(done) }
    }

    private func enterCommand(_ wording: String) {
        tapPantryEntry(app.buttons["pantry.voiceEntry"])
        assertDictationIdle()
        fill(wording, into: "pantry.voiceText")
        dismissVoiceKeyboard()
        tap(app.buttons["pantry.voiceReview"])
        XCTAssertFalse(element("pantry.voice.listening").exists)
        XCTAssertFalse(system.alerts.firstMatch.exists)
    }

    private func openPantry(reset: Bool, spanish: Bool = false, expectEmptyShop: Bool = false) {
        app.launchArguments = [
            "--ui-testing", "-AppleLanguages", spanish ? "(es)" : "(en)",
            "-AppleLocale", spanish ? "es_US" : "en_US"
        ]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        if expectEmptyShop {
            tap(app.tabBars.buttons[spanish ? "Compras" : "Shop"])
            XCTAssertTrue(app.buttons["shop.addFirstList"].waitForExistence(timeout: 12), app.debugDescription)
        }
        tap(app.tabBars.buttons[spanish ? "Despensa" : "Pantry"])
        if reset { tap(app.buttons["pantry.setup.apply"]) }
        XCTAssertTrue(app.buttons["pantry.add"].waitForExistence(timeout: 10))
    }

    private func assertTranscript(_ expected: String) {
        let original = element("pantry.voiceTranscript")
        reveal(original)
        XCTAssertEqual(original.value as? String, expected)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ control: XCUIElement, needsTap: Bool = true) {
        let tabBar = app.tabBars.firstMatch
        for attempt in 0..<16 {
            if !needsTap && control.exists { return }
            // A dismissing sheet can remove a navigation bar between indexed queries.
            let snapshot = try? app.snapshot()
            var nodes = snapshot.map { [$0] } ?? []
            var top = snapshot?.frame.minY ?? app.frame.minY
            while let node = nodes.popLast() {
                if node.elementType == .navigationBar, !node.frame.isEmpty {
                    top = node.frame.maxY
                    break
                }
                nodes.append(contentsOf: node.children)
            }
            let bottom = tabBar.exists && tabBar.isHittable ? tabBar.frame.minY : app.frame.maxY
            let area = CGRect(x: app.frame.minX + 12, y: top, width: app.frame.width - 24, height: bottom - top)
            if control.exists, control.isHittable, area.contains(CGPoint(x: control.frame.midX, y: control.frame.midY)) { return }
            let upward = control.exists ? control.frame.midY > area.midY : attempt < 8
            // Drag the displayed form without flicking past a short row or scrolling the list behind a sheet.
            app.scrollForm(in: area, upward: upward, besideFields: true)
        }
        XCTAssertTrue(control.waitForExistence(timeout: 8) && (!needsTap || control.isHittable), app.debugDescription)
    }

    private func tap(_ control: XCUIElement) {
        if (!control.exists && !control.waitForExistence(timeout: 2)) || !control.isHittable { reveal(control) }
        control.tap()
    }

    private func fill(_ value: String, into id: String) {
        let field = element(id)
        tap(field)
        field.typeText(value)
    }

    private func lot(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                        "pantry.lot.", name)).firstMatch
    }

    @discardableResult private func addLot(_ name: String, amount: String) -> String {
        tapPantryEntry(app.buttons["pantry.add"])
        let nameField = app.textFields["pantry.foodName"], amountField = app.textFields["pantry.amount"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), app.debugDescription)
        tap(nameField)
        nameField.typeText(name)
        XCTAssertEqual(nameField.value as? String, name)
        nameField.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tap(amountField)
        amountField.typeText(amount)
        XCTAssertEqual(amountField.value as? String, amount)
        amountField.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tap(app.buttons["pantry.review"])
        tap(app.buttons["pantry.confirm"])
        let row = lot(name)
        reveal(row)
        return row.identifier
    }

    private func assertLot(_ id: String, contains expected: String) {
        let row = app.buttons[id]
        reveal(row, needsTap: false)
        XCTAssertTrue(row.label.localizedCaseInsensitiveContains(expected), row.label)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
