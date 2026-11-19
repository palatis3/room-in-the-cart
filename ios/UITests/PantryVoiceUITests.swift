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
        let first = element("pantry.voiceSummary.0")
        reveal(first)
        XCTAssertTrue(first.label.localizedCaseInsensitiveContains("eggs"), first.label)
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
        XCTAssertEqual(app.switches["packageDate.hasDay"].value as? String, "0")
        tap(app.buttons["packageDate.save"])
        XCTAssertTrue(app.staticTexts[wording].waitForExistence(timeout: 8))
        app.terminate()
        openPantry(reset: false, spanish: true)
        for (id, name) in [(recorded, "Salsa de tomate clásica"), (unrecorded, "Salsa de tomate picante")] {
            let question = "¿Está vencida mi salsa de tomate?"
            enterCommand(question)
            XCTAssertTrue(app.navigationBars["Dictar o escribir"].exists)
            XCTAssertEqual(element("pantry.voiceText").value as? String, question)
            XCTAssertFalse(element("pantry.voiceOriginal.0").exists)
            XCTAssertFalse(element("pantry.voiceDateResult").exists)
            tap(element("pantry.voiceLot.0"))
            let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            tap(choice)
            tap(app.buttons["pantry.voiceDate"])
            let result = element("pantry.voiceDateResult")
            XCTAssertTrue(result.waitForExistence(timeout: 10))
            reveal(result)
            let noQuality = app.staticTexts["No hay un periodo de calidad verificado de FoodKeeper para este lote."]
            reveal(noQuality)
            if id == recorded {
                XCTAssertTrue(app.staticTexts[wording].exists, app.debugDescription)
                capture("Pantry-voice-03-fecha-impresa")
            } else {
                XCTAssertFalse(app.staticTexts[wording].exists)
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
        let unsure = app.buttons["pantry.voiceNotSure.0"]
        XCTAssertTrue(unsure.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertEqual(unsure.label, spanish ? "No lo sé" : "Not sure")
        unsure.tap()
        tap(app.buttons["pantry.voicePreview"])
        XCTAssertTrue(element("pantry.voiceStatus").waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["pantry.voiceConfirm"].exists)
        tap(app.buttons["pantry.voiceCancel"])
        assertLot(id, contains: spanish ? "3 unidades" : "3 units")

        let about = spanish ? "Me queda como media botella de kétchup" : "I have about half a bottle of ketchup left"
        enterCommand(about)
        XCTAssertEqual(element("pantry.voiceText").value as? String, about)
        tap(app.buttons["pantry.voicePreview"])
        XCTAssertTrue(element("pantry.voiceSummary.0").waitForExistence(timeout: 8))
        tap(app.buttons["pantry.voiceCancel"])
        assertLot(id, contains: spanish ? "3 unidades" : "3 units")

        enterCommand(low)
        XCTAssertEqual(element("pantry.voiceText").value as? String, low)
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
        XCTAssertTrue(element("pantry.voiceOriginal.0").label.localizedCaseInsensitiveContains("ketchup"))
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
        tap(app.buttons["pantry.voiceDescribe.0"])
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
        openVoiceEntry()
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

    private func openVoiceEntry() {
        let entry = app.buttons["pantry.voiceEntry"]
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
        openVoiceEntry()
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
            XCTAssertTrue(app.buttons["shop.addFirstList"].waitForExistence(timeout: 12), app.debugDescription)
        }
        tap(app.shopToolButton("shop.myPantry"))
        if reset { tap(app.buttons["pantry.setup.apply"]) }
        XCTAssertTrue(app.buttons["pantry.add"].waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ control: XCUIElement) {
        for attempt in 0..<10 {
            if control.exists && control.isHittable { return }
            let list = app.collectionViews.firstMatch
            let view = list.exists ? list : app.scrollViews.firstMatch
            guard view.exists else { break }
            let upward = control.exists ? control.frame.midY > app.frame.midY : attempt < 6
            if upward { view.swipeUp() } else { view.swipeDown() }
        }
        XCTAssertTrue(control.waitForExistence(timeout: 8) && control.isHittable, app.debugDescription)
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
        tap(app.buttons["pantry.add"])
        fill(name, into: "pantry.foodName")
        fill(amount, into: "pantry.amount")
        tap(app.buttons["pantry.review"])
        tap(app.buttons["pantry.confirm"])
        let row = lot(name)
        reveal(row)
        return row.identifier
    }

    private func assertLot(_ id: String, contains expected: String) {
        let row = app.buttons[id]
        reveal(row)
        XCTAssertTrue(row.label.localizedCaseInsensitiveContains(expected), row.label)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
