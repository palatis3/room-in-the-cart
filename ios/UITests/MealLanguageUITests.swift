import XCTest

#if DEBUG && targetEnvironment(simulator)
@MainActor final class MealLanguageUITests: XCTestCase {
    func testCustomerWordsSelectOnlyAReviewedReplacementInTheOrdinarySwapEditor() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--meal-language-fixture", "--meal-choice-fixture",
            "-AppleLanguages", "(es)", "-AppleLocale", "es_US"]
        app.launch()
        let swap = app.buttons["mealFixture.swap"]
        XCTAssertTrue(swap.waitForExistence(timeout: 12))
        swap.tap()
        let open = app.buttons["mealChoice.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()
        let field = app.textFields["mealChoice.words"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap(); field.typeText("Prefiero el arroz" + XCUIKeyboardKey.return.rawValue)
        let send = app.buttons["mealChoice.send"]
        XCTAssertFalse(send.isEnabled)
        let title = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mealChoice.title.")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.coordinate(withNormalizedOffset: CGVector(dx:0.93,dy:0.5)).tap()
        XCTAssertTrue(send.isEnabled); send.tap()
        let proposal = app.staticTexts["mealChoice.proposed"]
        XCTAssertTrue(proposal.waitForExistence(timeout: 8)); XCTAssertEqual(proposal.label, "Arroz con tomates")
        app.buttons["mealChoice.use"].tap()
        let option = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "swap.option.")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8)); XCTAssertTrue(option.isSelected)
        XCTAssertTrue(app.buttons["swap.preview"].exists, "The ordinary local preview is still required.")
        XCTAssertTrue(app.staticTexts["Original dinner"].exists)
    }

    func testOptedInAdultReviewsSoftPreferenceAndFeedbackInBothLanguagesBeforeSaving() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"dev.roominthecart.app.debug")
        defer { app.terminate() }
        func reach(_ element: XCUIElement) {
            if element.isHittable { return }
            for _ in 0..<7 {
                app.swipeUp()
                if element.isHittable { return }
            }
            for _ in 0..<7 {
                app.swipeDown()
                if element.isHittable { return }
            }
            XCTAssertTrue(element.isHittable, element.debugDescription)
        }
        func tap(_ element: XCUIElement) { reach(element); element.tap() }
        for spanish in [false, true] {
            app.launchArguments = ["--ui-testing","--meal-language-fixture","-AppleLanguages",spanish ? "(es)" : "(en)",
                "-AppleLocale",spanish ? "es_US" : "en_US"]
            app.launch()
            for feedback in [false, true] {
                let entry = feedback ? "mealFixture.feedback" : "mealFixture.preferences"
                XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 15))
                app.buttons[entry].tap()
                tap(app.buttons["mealLanguage.open"])
                let note = app.textFields["mealLanguage.note"]
                XCTAssertTrue(note.waitForExistence(timeout: 8))
                let wording = feedback ? (spanish ? "Repetir la cena" : "Make it again") : (spanish ? "No me gustan los guisantes" : "I dislike peas")
                note.tap(); note.typeText(wording + XCUIKeyboardKey.return.rawValue)
                tap(app.buttons["mealLanguage.send"])
                let quote = feedback ? wording : (spanish ? "guisantes" : "peas")
                let proposed = app.buttons["mealLanguage.use"]
                XCTAssertTrue(proposed.waitForExistence(timeout: 8))
                XCTAssertTrue(app.staticTexts[quote].exists)
                let strength = feedback ? (spanish ? "Opinión de la comida · volver a prepararla" : "Meal feedback · make again") :
                    (spanish ? "Preferencia opcional · ingrediente que no me gusta" : "Soft preference · disliked ingredient")
                XCTAssertTrue(app.staticTexts[strength].exists)
                if !feedback {
                    tap(app.buttons[spanish ? "Cancelar" : "Cancel"])
                    tap(app.buttons["mealLanguage.open"])
                    XCTAssertTrue(note.waitForExistence(timeout: 8))
                    note.tap(); note.typeText(wording + XCUIKeyboardKey.return.rawValue)
                    tap(app.buttons["mealLanguage.send"])
                    XCTAssertTrue(proposed.waitForExistence(timeout: 8))
                }
                tap(proposed)
                if feedback {
                    let again = app.switches["mealFeedback.makeAgain"]
                    reach(again); XCTAssertEqual(again.value as? String, "1")
                    tap(app.buttons["mealFeedback.save"])
                } else {
                    tap(app.buttons["preferences.review"])
                    tap(app.buttons["preferences.save"])
                }
                XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 10))
                app.buttons[entry].tap()
                if feedback {
                    let again = app.switches["mealFeedback.makeAgain"]
                    reach(again); XCTAssertEqual(again.value as? String,"1")
                } else {
                    let terms = app.textFields.matching(NSPredicate(format:"value == %@",quote)).firstMatch
                    reach(terms); XCTAssertTrue(terms.exists)
                }
                app.navigationBars.buttons.element(boundBy:0).tap()
            }
            app.terminate()
        }
    }
}
#endif
