#if DEBUG && targetEnvironment(simulator)
import XCTest

/// Uses the normal empty local workspace and production pantry setup. No seeded
/// recipe or selected shop hides the no-shop composition requirement.
@MainActor final class TonightUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            let state = XCTAttachment(string: app.debugDescription); state.lifetime = .keepAlways; add(state)
            let screen = XCTAttachment(screenshot: app.screenshot()); screen.lifetime = .keepAlways; add(screen)
        }
        app.terminate()
    }
    func testDinnersCanSaveAndReopenRecipeBeforeStartingPickupOrPantry() throws {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.saveFirstRecipe"])
        fill(app.textFields["tonight.recipe.title"], "Corn and beans")
        fill(app.textFields["tonight.recipe.servings"], "2")
        fill(app.textFields["tonight.recipe.minutes"], "10")
        fill(app.textFields["tonight.recipe.ingredient"], "Corn")
        let cornSwitches = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "tonight.recipe.manual.", "Corn"))
        XCTAssertEqual(cornSwitches.count, 1)
        let corn = cornSwitches.firstMatch
        tap(corn, at: CGVector(dx: 0.15, dy: 0.5))
        XCTAssertEqual(corn.value as? String, "1", "Tapping the words must select the unmeasured option.")
        tap(corn, at: CGVector(dx: 0.92, dy: 0.5))
        XCTAssertEqual(corn.value as? String, "0", "The native thumb must switch it off once.")
        let amount = app.textFields["Amount (required)"]
        XCTAssertTrue(amount.exists)
        tap(app.buttons["tonight.recipe.review"])
        let error = app.staticTexts["tonight.recipe.amountError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Enter an amount greater than zero for Corn.")
        XCTAssertTrue(amount.isHittable)
        amount.typeText("1")  // Validation focuses the ingredient needing correction.
        dismissRecipeKeyboard()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        let correctedAmount = XCTAttachment(screenshot: app.screenshot())
        correctedAmount.name = "Corrected recipe ingredient with a persistent amount label"
        correctedAmount.lifetime = .keepAlways
        add(correctedAmount)
        tap(app.buttons["tonight.recipe.review"])
        let time = app.descendants(matching: .any).matching(identifier: "tonight.recipe.reviewedMinutes").firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        XCTAssertTrue([time.label, time.value as? String ?? ""].joined(separator: " ").contains("10"))
        tap(app.buttons["tonight.recipe.save"])
        XCTAssertTrue(app.descendants(matching: .any)["tonight.recipe.saved"].waitForExistence(timeout: 8))
        tap(app.buttons["tonight.recipe.done"])
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinner.savedRecipe.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertEqual(saved.label, "Edit saved recipe, Corn and beans")
        tap(saved)
        XCTAssertEqual(app.textFields["tonight.recipe.title"].value as? String, "Corn and beans")
        tap(app.buttons["Cancel"])
        XCTAssertEqual(app.buttons["dinner.saveFirstRecipe"].label, "Replace Free reusable dinner")
        XCTAssertTrue(saved.exists)
        XCTAssertTrue(app.buttons["dinnerStartPickup"].exists)
    }

    func testSpanishLargeTypeKeyboardAdvancesFromTitleThroughIngredientAmount() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(es)", "-AppleLocale", "es_MX",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        tap(app.tabBars.buttons["Cenas"])
        tap(app.buttons["dinner.saveFirstRecipe"])
        XCTAssertTrue(app.navigationBars["Escribir una receta"].waitForExistence(timeout: 5))
        // The caption occupies the upper portion of the field’s advertised
        // accessibility frame on the small device at this text size.
        tap(app.textFields["tonight.recipe.title"], at: CGVector(dx: 0.22, dy: 0.22))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.typeText("Sopa")
        let next = app.buttons["tonight.recipe.keyboardNext"]
        for value in ["8", "10", "Limón", "1"] {
            tap(next)
            app.typeText(value)
        }
        dismissRecipeKeyboard()
        tap(app.buttons["tonight.recipe.review"])
        let minutes = app.descendants(matching: .any).matching(identifier: "tonight.recipe.reviewedMinutes").firstMatch
        XCTAssertTrue(minutes.waitForExistence(timeout: 5))
        XCTAssertTrue([minutes.label, minutes.value as? String ?? ""].joined(separator: " ").contains("10"))
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Limón", "1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let servings = app.buttons["tonight.recipe.review.servings"]
        tap(servings)
        let field = app.textFields["tonight.recipe.servings"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "8")
        XCTAssertGreaterThan(field.frame.midY, app.navigationBars.firstMatch.frame.maxY)
        app.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        XCTAssertEqual(field.value as? String, "2")
        tap(app.buttons["tonight.recipe.reviewChanges"])
        XCTAssertTrue(servings.waitForExistence(timeout: 5))
        XCTAssertTrue(servings.label.contains("2"))
        XCTAssertTrue(minutes.label.contains("10"))
        XCTAssertTrue(row.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Spanish accessibility-sized recipe facts after keyboard entry"
        shot.lifetime = .keepAlways
        add(shot)
        tap(app.buttons["tonight.recipe.save"])
        tap(app.buttons["tonight.recipe.done"])
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-workspace" }
        app.launch()
        tap(app.tabBars.buttons["Cenas"])
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinner.savedRecipe.")).firstMatch
        tap(saved)
        XCTAssertTrue(app.navigationBars["Editar receta"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "2")
        XCTAssertEqual(app.textFields["tonight.recipe.title"].value as? String, "Sopa")
    }

    func testPlanSavedEggsForTwoInNamedPickupAndReopenDinner() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.saveFirstRecipe"])
        fill(app.textFields["tonight.recipe.title"], "Scrambled eggs")
        fill(app.textFields["tonight.recipe.servings"], "2")
        fill(app.textFields["tonight.recipe.minutes"], "10")
        fill(app.textFields["tonight.recipe.ingredient"], "Eggs")
        fill(app.textFields["Amount (required)"], "4")
        tap(app.buttons["tonight.recipe.review"])
        XCTAssertTrue(app.descendants(matching: .any)["tonight.recipe.reviewedMinutes"].exists)
        tap(app.buttons["tonight.recipe.save"])
        tap(app.buttons["dinner.planSaved"].firstMatch)
        let namePickup = app.buttons["dinner.handoff.startPickup"]
        XCTAssertTrue(namePickup.waitForExistence(timeout: 5))
        XCTAssertEqual(namePickup.label, "Name your pickup")
        tap(namePickup)
        let createPickup = app.buttons["ledgerCreateShop"]
        XCTAssertTrue(createPickup.waitForExistence(timeout: 5))
        XCTAssertEqual(createPickup.label, "Start pickup")
        tap(createPickup)
        let confirm = app.buttons["dinner.handoff.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertEqual(confirm.label, "Plan for tonight")
        XCTAssertTrue(app.descendants(matching: .any)["dinner.handoff.destination"].label.contains("Groceries for Scrambled eggs"))
        tap(app.buttons["dinner.handoff.confirm"])
        XCTAssertTrue(app.descendants(matching: .any)["dinner.handoff.saved"].waitForExistence(timeout: 10))
        tap(app.buttons["dinner.handoff.done"])
        tap(app.buttons["tonight.recipe.done"])
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-workspace" }
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        XCTAssertTrue(app.staticTexts["Scrambled eggs"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["No dinner planned"].exists)
    }

    func testFirstSavedDinnerCarriesIntoNewPickupAndAddsOnlySelectedIngredient() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.saveFirstRecipe"])
        fill(app.textFields["tonight.recipe.title"], "Lemon chickpeas")
        fill(app.textFields["tonight.recipe.servings"], "2")
        fill(app.textFields["tonight.recipe.ingredient"], "Lemon")
        fill(app.textFields["Amount (required)"], "1")
        tap(app.buttons["Add ingredient"])
        fill(app.textFields.matching(identifier: "tonight.recipe.ingredient").element(boundBy: 1), "Chickpeas")
        let manual = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Chickpeas")).firstMatch
        tap(manual, at: CGVector(dx: 0.92, dy: 0.5))
        XCTAssertEqual(manual.value as? String, "1", "The chickpeas must be explicitly marked unmeasured.")
        tap(app.buttons["tonight.recipe.review"])
        tap(app.buttons["tonight.recipe.save"])
        tap(app.buttons["dinner.shopSaved"].firstMatch)
        tap(app.buttons["dinner.handoff.startPickup"])
        tap(app.buttons["ledgerCreateShop"])
        XCTAssertTrue(app.navigationBars["Shop for ingredients only"].waitForExistence(timeout: 5))
        let select = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'dinner.handoff.ingredient.' AND label CONTAINS %@", "Lemon")).firstMatch
        let chickpeas = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'dinner.handoff.ingredient.' AND label CONTAINS %@", "Chickpeas")).firstMatch
        tap(select, at: CGVector(dx: 0.22, dy: 0.5))
        XCTAssertEqual(select.value as? String, "1", "The visible ingredient label selects only this row.")
        XCTAssertEqual(chickpeas.value as? String, "0")
        tap(select, at: CGVector(dx: 0.92, dy: 0.5))
        XCTAssertEqual(select.value as? String, "0", "One thumb tap deselects once.")
        tap(select, at: CGVector(dx: 0.22, dy: 0.5))
        XCTAssertEqual(select.value as? String, "1")
        XCTAssertEqual(chickpeas.value as? String, "0")
        tap(app.buttons["dinner.handoff.review"])
        let confirm = app.buttons["dinner.handoff.confirm"]
        XCTAssertEqual(confirm.label, "Add 1 ingredient to Groceries for Lemon chickpeas")
        tap(confirm)
        XCTAssertTrue(app.descendants(matching: .any)["dinner.handoff.saved"].waitForExistence(timeout: 10))
        tap(app.buttons["dinner.handoff.openList"])
        XCTAssertTrue(app.buttons["Check Lemon"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["Check Chickpeas"].exists)
    }

    func testBothPrivateTonightEntriesWorkWithoutShopAndCancelCreatesNothing() throws {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if #unavailable(iOS 18) { app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable" }
        app.launch()
        tap(app.shopToolButton("shop.myPantry"))
        tap(app.buttons["pantry.setup.apply"])
        tap(app.buttons["pantry.tonight"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 12))
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No reviewed recipes are available.")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 12))
        tap(app.buttons["tonight.addRecipe"])
        XCTAssertTrue(app.navigationBars["Enter a recipe"].waitForExistence(timeout: 8))
        tap(app.buttons["Cancel"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 8))
        // A real reviewed recipe can be saved before any shop exists. Canceling
        // earlier must not have filled the reusable slot or created a pickup.
        tap(app.buttons["tonight.addRecipe"])
        fill(app.textFields["tonight.recipe.title"], "No-shop rice dinner")
        fill(app.textFields["tonight.recipe.servings"], "1")
        fill(app.textFields["tonight.recipe.ingredient"], "Rice")
        fill(app.textFields["Amount (required)"], "1")
        tap(app.buttons["tonight.recipe.review"])
        tap(app.buttons["tonight.recipe.save"])
        tap(app.buttons["tonight.recipe.done"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 10))
        let recipe = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "No-shop rice dinner")).firstMatch
        tap(recipe)
        let unresolvedPrice = app.staticTexts.matching(NSPredicate(format: "label == %@", "Some amounts or package prices still need review.")).firstMatch
        revealInList(unresolvedPrice)
        XCTAssertTrue(unresolvedPrice.exists, app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tonight.choose.")).firstMatch.isEnabled,
                       "No stock match cannot be offered as a pantry-based dinner")
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.tonight"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 8))
        // This tab starts at the top of its own list. The saved recipe is below
        // the preferences and optional-help sections when it needs a pantry match.
        revealInList(recipe)
        XCTAssertTrue(recipe.isHittable, recipe.debugDescription)
        tap(app.navigationBars["Tonight"].buttons.firstMatch)
        XCTAssertTrue(app.buttons["dinnerStartPickup"].waitForExistence(timeout: 8), "Browse and canceled recipe review must leave the workspace without a pickup")
        XCTAssertFalse(app.buttons["tonight.apply"].exists)
    }
    func testImportedSeasoningAndCookSoonInPrivateChooserEnglishAndSpanish() throws {
        for spanish in [false, true] {
            app.launchArguments = ["--ui-testing", "--reset-test-workspace", "--shopper-recipe-sources",
                                   "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_US" : "en_US"]
            app.launch()
            tap(app.tabBars.buttons[spanish ? "Despensa" : "Pantry"])
            tap(app.buttons["pantry.setup.apply"])
            let products = ["Red lentils", "Green lentils"]
            for product in products {
                tap(app.buttons["pantry.add"])
                let name = app.textFields["pantry.foodName"], amount = app.textFields["pantry.amount"]
                tap(name)
                name.typeText(product)
                XCTAssertEqual(name.value as? String, product)
                let stockAmount = product == products[0] ? "2" : "1/2"
                tapPantryRowBelowName(amount)
                amount.typeText(stockAmount)
                XCTAssertEqual(amount.value as? String, stockAmount)
                amount.typeText("\n")
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
                let unit = app.buttons["pantry.foodUnit"], cups = spanish ? "tazas" : "cups"
                tapPantryRowBelowName(unit)
                tap(app.buttons[cups])
                XCTAssertTrue(unit.label.contains(cups))
                tap(app.buttons["pantry.review"])
                let confirm = app.buttons["pantry.confirm"]
                tap(confirm)
                XCTAssertTrue(confirm.waitForNonExistence(timeout: 8))
            }
            tap(app.buttons["pantry.tonight"])
            let search = app.textFields["dinner.recipeSearch"]
            tap(search)
            search.typeText("cilantrox")
            let noMatch = app.staticTexts["tonight.recipeNoMatch"]
            XCTAssertTrue(noMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts.matching(identifier: "tonight.recipeNoMatch").count, 1)
            search.typeText(XCUIKeyboardKey.delete.rawValue + "\n")
            let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "tonight.source.", "Sopa de lentejas")).firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable, "An ingredient search should put its matching import directly below the search field.")
            XCTAssertFalse(noMatch.exists)
            let addRecipe = app.navigationBars.buttons["tonight.addRecipe"]
            XCTAssertTrue(addRecipe.isHittable, "Adding a recipe must also be reachable from the filtered library.")
            XCTAssertEqual(addRecipe.label, spanish ? "Añadir receta" : "Add recipe")
            XCTAssertEqual(app.buttons.matching(identifier: "tonight.addRecipe").count, 1)
            tap(source)
            let servings = app.textFields["tonight.recipe.servings"]
            XCTAssertTrue(servings.waitForExistence(timeout: 5))
            XCTAssertEqual(servings.value as? String, "4", "The imported wording ‘4 porciones’ supplies the serving count in either language.")
            let handCheck = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "tonight.recipe.manual.", "cilantro al gusto")).firstMatch
            tap(handCheck, at: CGVector(dx: 0.92, dy: 0.5))
            XCTAssertEqual(handCheck.value as? String, "1")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = spanish ? "Cilantro al gusto revisado" : "Hand-reviewed seasoning and imported measure"
            shot.lifetime = .keepAlways; add(shot)
            tap(app.buttons["tonight.recipe.review"])
            let handStatus = spanish ? "Revisado sin medir" : "Checked by hand · unmeasured"
            let reviewed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", handStatus, handStatus)).firstMatch
            XCTAssertTrue(reviewed.waitForExistence(timeout: 5))
            tap(app.buttons["tonight.recipe.save"])
            tap(app.buttons["tonight.recipe.done"])
            // iOS 17 exposes the label and disclosure chevron separately. Both are inside this row's frame.
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "tonight.result.", "Sopa de lentejas")).firstMatch
            let chevron = CGVector(dx: 0.94, dy: 0.5)
            tap(row, at: chevron)
            let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinner.cookSoon.reviewed.")).firstMatch
            tap(pin)
            let pinned = NSPredicate(format: "label == %@", spanish ? "Quitar de Cocinar pronto" : "Remove from Cook soon")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pinned, object: pin)], timeout: 8), .completed)
            XCTAssertTrue(pin.isHittable, "Pinning must leave the reviewed recipe open and in view.")
            let picker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tonight.match.")).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            let ingredient = String(picker.identifier.dropFirst("tonight.match.".count))
            let remember = app.buttons["tonight.remember." + ingredient]
            let forget = app.buttons["tonight.forget." + ingredient]
            func assertVisibleTarget(_ button: XCUIElement) {
                XCTAssertTrue(button.waitForExistence(timeout: 8), button.debugDescription)
                XCTAssertTrue(button.isHittable, "Updating a match must keep the same reviewed ingredient visible.")
                // XCTest subtracts floating-point screen coordinates to derive each dimension.
                let coordinateTolerance: CGFloat = 1e-9
                XCTAssertGreaterThanOrEqual(button.frame.height + coordinateTolerance, 44)
                XCTAssertGreaterThanOrEqual(button.frame.width + coordinateTolerance, 44)
            }
            tap(picker)
            tap(app.buttons[products[0]])
            assertVisibleTarget(remember)
            remember.tap()
            assertVisibleTarget(forget)
            XCTAssertTrue(picker.isHittable)
            picker.tap()
            tap(app.buttons[products[1]])
            assertVisibleTarget(remember)
            XCTAssertEqual(remember.label, spanish ? "Cambiar el producto guardado" : "Change remembered product")
            remember.tap()
            XCTAssertTrue(remember.waitForNonExistence(timeout: 8))
            assertVisibleTarget(forget)
            forget.tap()
            XCTAssertTrue(forget.waitForNonExistence(timeout: 8))
            XCTAssertTrue(picker.isHittable)
            XCTAssertFalse(picker.label.contains(products[1]))
            picker.tap()
            tap(app.buttons[products[1]])
            let shortfall = app.staticTexts["tonight.shortfall." + ingredient]
            revealInList(shortfall)
            XCTAssertTrue(shortfall.label.hasSuffix(spanish ? " · 1 taza estadounidense" : " · 1 US cup"), shortfall.label)
            revealInList(row, towardEnd: false)
            tap(row, at: chevron)
            revealInList(app.staticTexts["tonight.section.matches"], towardEnd: false)
            XCTAssertFalse(picker.exists, "The closed recipe should now appear under current pantry matches.")
            revealInList(search, towardEnd: false)
            tap(search)
            XCTAssertEqual(search.value as? String, "cilantro")
            app.terminate()
        }
    }

    func testMealExplanationOfflineFallbackInEnglishAndSpanishDoesNotRequireAccount() throws {
        for spanish in [false, true] {
            app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_US" : "en_US"]
            app.launch()
            tap(app.shopToolButton("shop.myPantry"))
            tap(app.buttons["pantry.setup.apply"])
            tap(app.buttons["pantry.tonight"])
            let text = spanish ? "La ayuda en línea requiere una cuenta de adulto autorizada. Puedes seguir revisando coincidencias locales sin iniciar sesión." : "Online help requires an authorized adult account. Keep reviewing local matches without signing in."
            let fallback = app.staticTexts[text]
            revealInList(fallback)
            XCTAssertTrue(fallback.exists, app.debugDescription)
            XCTAssertFalse(app.buttons["tonight.explanations.send"].exists)
            XCTAssertFalse(app.buttons["tonight.explanations.open"].exists)
            XCTAssertFalse(app.buttons["tonight.apply"].exists)
            app.terminate()
        }
    }
    private func revealInList(_ element: XCUIElement, towardEnd: Bool = true) {
        for _ in 0..<12 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            let area = CGRect(x: app.frame.minX + 12, y: top, width: app.frame.width - 24, height: bottom - top)
            if element.exists, area.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let upward = element.exists ? element.frame.midY > area.midY : towardEnd
            app.scrollForm(in: area, upward: upward, besideFields: true)
        }
        XCTFail("Expected the requested row in the visible list: " + app.debugDescription)
    }
    private func tapPantryRowBelowName(_ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        let accessory = app.otherElements["SystemInputAssistantView"].firstMatch
        for _ in 0..<8 {
            let bottom = min(keyboard.exists ? keyboard.frame.minY : app.frame.maxY,
                             accessory.exists ? accessory.frame.minY : app.frame.maxY)
            let top = app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? app.frame.minY
            let area = CGRect(x: app.frame.minX + 12, y: top, width: app.frame.width - 24, height: bottom - top)
            // A partly exposed row can report hittable with its center behind the prediction bar on iOS 17.
            if row.exists, row.isHittable, row.frame.minY >= top, row.frame.maxY <= bottom {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            app.scrollForm(in: area, upward: !row.exists || row.frame.midY > area.midY, besideFields: true)
        }
        XCTFail("Expected the pantry row to be visible above the keyboard: " + row.debugDescription, file: file, line: line)
    }
    private func fill(_ element: XCUIElement, _ value: String) {
        tap(element)
        element.typeText(value)
        dismissRecipeKeyboard()
    }
    private func dismissRecipeKeyboard() {
        let done = app.buttons["tonight.recipe.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: "tonight.recipe.keyboardDone"))
    }
    private func tap(_ element: XCUIElement, at offset: CGVector? = nil) {
        _ = element.waitForExistence(timeout: 3)
        for index in 0..<16 {
            if element.exists && element.isHittable { break }
            let moveDown = element.exists ? element.frame.midY > app.frame.midY : index < 8
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: moveDown ? 0.65 : 0.36))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: moveDown ? 0.38 : 0.63))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
        if let offset { element.coordinate(withNormalizedOffset: offset).tap() }
        else { element.tap() }
    }
}
#endif
