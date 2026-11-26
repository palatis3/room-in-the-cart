#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE && targetEnvironment(simulator)
import XCTest

@MainActor final class HouseholdCheckUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Household question hierarchy"
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Household question failure"
            add(screenshot)
        }
        app.terminate()
    }

    func testNamedAdultAnswersDinnerAndShopperReviews() {
        launch(spanish: false)
        openPage()
        XCTAssertTrue(contains("Dani Rivera").exists)
        choose("Dinner", option: "Tacos de frijoles")
        XCTAssertTrue(contains("The question expires in 24 hours.").exists)
        tap(app.buttons["adultChecks.send"])
        counts("1/0/1/0")
        XCTAssertTrue(contains("Waiting for a reply").exists)

        switchTo("dani")
        openPage()
        XCTAssertFalse(app.buttons["adultChecks.send"].exists)
        XCTAssertTrue(contains("Tacos de frijoles").exists)
        tap(app.buttons["Save me a plate"])
        XCTAssertTrue(app.navigationBars["Review reply"].waitForExistence(timeout: 5))
        tap(app.buttons["Cancel"])
        counts("1/0/1/0")
        tap(app.buttons["Save me a plate"])
        tap(app.buttons["Send reply"])
        counts("1/1/2/0")

        switchTo("shopper")
        openPage()
        XCTAssertTrue(contains("Save me a plate").exists)
        XCTAssertTrue(contains("Set aside a dinner portion for later.").exists)
        tap(app.buttons["Review this dinner"])
        let occurrence = app.buttons["meal-change-occurrence"]
        XCTAssertTrue(occurrence.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(occurrence.label.contains("Tacos de frijoles") || (occurrence.value as? String)?.contains("Tacos de frijoles") == true)
        XCTAssertFalse(occurrence.isEnabled)
        let portions = app.steppers.firstMatch
        XCTAssertTrue(portions.exists && portions.isEnabled, app.debugDescription)
        tap(app.buttons["Cancel"])
        counts("1/1/2/0")
        tap(app.buttons["Mark reply reviewed"])
        counts("1/1/3/0")
        XCTAssertTrue(contains("Reply reviewed").exists)
    }

    func testSpanishCupboardAnswerRequiresNamedSeat() {
        launch(spanish: true)
        openPage()
        XCTAssertTrue(contains("Dani Rivera").exists)
        choose("Pregunta", option: "Revisar un ingrediente")
        choose("Artículo", option: "Arroz integral")
        XCTAssertTrue(contains("Paquetes en la lista de compras").exists)
        tap(app.buttons["adultChecks.send"])
        counts("1/0/1/0")

        switchTo("contributor")
        XCTAssertTrue(app.textFields["Artículo"].waitForExistence(timeout: 10) || app.buttons["household.request.review"].exists)
        XCTAssertFalse(app.buttons["household.adultChecks"].exists)
        XCTAssertFalse(contains("Arroz integral").exists)
        counts("1/0/1/0")

        switchTo("dani")
        openPage()
        XCTAssertTrue(contains("Arroz integral").exists)
        XCTAssertFalse(contains("Tacos de frijoles").exists)
        tap(app.buttons["Queda poco"])
        XCTAssertTrue(app.navigationBars["Revisar respuesta"].waitForExistence(timeout: 5))
        XCTAssertTrue(contains("Solo se comparte tu respuesta").exists)
        tap(app.buttons["Enviar respuesta"])
        counts("1/1/2/0")

        switchTo("shopper")
        openPage()
        XCTAssertTrue(contains("Queda poco").exists)
        XCTAssertTrue(contains("Revisa si los paquetes de la lista alcanzan para lo que necesitas.").exists)
        tap(app.buttons["adultChecks.openGrocery"])
        let name = app.staticTexts["sharedGrocery.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(name.label, "Arroz integral")
        XCTAssertFalse(contains("Arroz blanco").exists)
        XCTAssertTrue(contains("Queda poco").exists)
        let current = app.descendants(matching: .any).matching(identifier: "sharedGrocery.currentPacks").firstMatch
        XCTAssertTrue(current.label.contains("2") || (current.value as? String)?.contains("2") == true, app.debugDescription)
        XCTAssertFalse(app.buttons["sharedGrocery.review"].exists)
        counts("1/1/2/0")
        tap(app.buttons["sharedGrocery.keep"])
        counts("1/1/2/0")
        tap(app.buttons["Marcar como revisada"])
        counts("1/1/3/0")
        XCTAssertTrue(contains("Respuesta revisada").exists)
    }

    private func launch(spanish: Bool) {
        app.launchArguments = ["--ui-testing", "--adult-checks-fixture", "-AppleLanguages", spanish ? "(es)" : "(en)",
                               "-AppleLocale", spanish ? "es_MX" : "en_US"]
        app.launch()
    }
    private func switchTo(_ actor: String) {
        tap(app.buttons["fixture.checks." + actor])
    }
    private func counts(_ expected: String) {
        let count = app.staticTexts["fixture.checks.counts"]
        XCTAssertTrue(count.wait(for: \.label, toEqual: expected, timeout: 8), app.debugDescription)
    }
    private func openPage() {
        tap(app.buttons["household.adultChecks"])
        let refresh = app.buttons.matching(NSPredicate(format: "label IN %@", ["Refresh questions", "Actualizar preguntas"])).firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 12), app.debugDescription)
    }
    private func contains(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }
    private func choose(_ name: String, option: String) {
        let picker = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        tap(picker)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", option)).firstMatch)
    }
    private func tap(_ element: XCUIElement) {
        for _ in 0..<4 {
            if element.waitForExistence(timeout: 2), element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("Control unavailable: " + element.description + "\n" + app.debugDescription)
    }
}
#endif
