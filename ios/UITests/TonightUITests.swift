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
    func testNewManualRecipeWarnsBeforeDiscardAndKeepsTheEnteredFields() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        let open = app.buttons["dinner.saveFirstRecipe"]
        let editor = app.navigationBars["Enter a recipe"]
        let cancel = editor.buttons["tonight.recipe.cancel"]
        tap(open)
        let notice = app.staticTexts["tonight.recipe.saveNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertTrue(notice.label.contains("restarting the app clears unsaved entries"))
        tap(cancel)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))

        tap(open)
        let servings = app.textFields["tonight.recipe.servings"]
        let ingredient = app.textFields["tonight.recipe.ingredient"]
        fill(servings, "2")
        fill(ingredient, "Bread")
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(cancel.isHittable, "The sheet must remain open after a dismissal gesture.")

        tap(cancel)
        let alert = app.alerts["Discard this unsaved recipe?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Keep editing"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        reveal(servings)
        XCTAssertEqual(servings.value as? String, "2")
        reveal(ingredient)
        XCTAssertEqual(ingredient.value as? String, "Bread")
        tap(cancel)
        alert.buttons["Discard recipe"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))
        tap(open)
        XCTAssertTrue(servings.waitForExistence(timeout: 8))
        XCTAssertEqual(servings.value as? String ?? "", "")
        reveal(ingredient)
        XCTAssertEqual(ingredient.value as? String ?? "", "")
        tap(cancel)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))
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
        tap(app.buttons["cooking.openReusableDinner"])
        XCTAssertTrue(app.buttons["cooking.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["tonight.recipe.title"].exists)
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
        let reviewedTitle = app.buttons["tonight.recipe.review.title"]
        XCTAssertTrue(reviewedTitle.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertTrue(reviewedTitle.label.contains("Sopa"))
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

    func testJustPlannedDinnerKeepsAllocationReviewWhenMissingListAmountsAreSaved() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_CA"]
        app.launch()
        for name in ["Milk", "Oats"] {
            let grocery = app.textFields["quickGrocery.name"]
            tap(grocery)
            grocery.typeText(name)
            tap(app.buttons["quickGrocery.add"])
            XCTAssertTrue(app.buttons["quickGrocery.undo"].waitForExistence(timeout: 8))
        }
        tap(app.tabBars.buttons["Pantry"])
        tap(app.buttons["pantry.setup.apply"])
        tap(app.buttons["pantry.add"])
        for (id, value) in [("pantry.foodName", "Bread"), ("pantry.amount", "1")] {
            let field = app.textFields[id]
            tap(field)
            field.typeText(value + "\n")
        }
        tap(app.buttons["pantry.review"])
        tap(app.buttons["pantry.confirm"])
        XCTAssertTrue(app.buttons["pantry.confirm"].waitForNonExistence(timeout: 8))
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.tonight"])
        tap(app.buttons["tonight.addRecipe"])
        fill(app.textFields["tonight.recipe.title"], "Cheese toast")
        fill(app.textFields["tonight.recipe.servings"], "1")
        let ingredients = app.textFields.matching(identifier: "tonight.recipe.ingredient")
        let amounts = app.textFields.matching(NSPredicate(format: "label == %@", "Amount (required)"))
        fill(ingredients.firstMatch, "Bread")
        fill(amounts.firstMatch, "1")
        tap(app.buttons["Add ingredient"])
        fill(ingredients.element(boundBy: 1), "Cheese")
        fill(amounts.element(boundBy: 1), "1")
        tap(app.buttons["tonight.recipe.review"])
        tap(app.buttons["tonight.recipe.save"])
        tap(app.buttons["dinner.planSaved"])
        tap(app.buttons["dinner.handoff.matchPantry"])
        let bread = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                     "dinner.handoff.pantryProduct.", "Bread")).firstMatch
        tap(bread)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Bread · ")).firstMatch)
        tap(app.buttons["Use these product matches"])
        tap(app.buttons["dinner.handoff.confirm"])
        XCTAssertTrue(app.descendants(matching: .any)["dinner.handoff.saved"].waitForExistence(timeout: 10))
        tap(app.buttons["dinner.checkShopping"])
        let review = app.buttons["Review shopping allocations"]
        tap(review)
        let screen = app.navigationBars["Check what to buy"]
        for name in ["Milk", "Oats"] {
            tap(app.buttons["Set amount for " + name])
            let field = app.textFields["Quantity (optional)"]
            tap(field)
            field.typeText("1")
            tap(app.buttons["ledgerSaveContributionChanges"])
            XCTAssertTrue(app.navigationBars["Quantity and notes"].waitForNonExistence(timeout: 8))
            XCTAssertTrue(screen.exists && screen.isHittable, "Saving must return to this dinner's allocation review.")
            XCTAssertFalse(app.buttons["Set amount for " + name].exists)
        }
        tap(review)
        XCTAssertTrue(app.buttons["Save meal allocations"].waitForExistence(timeout: 8))
    }

    func testPlanSavedEggsForTwoInNamedPickupAndReopenDinner() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Pantry"])
        tap(app.buttons["pantry.setup.apply"])
        tap(app.buttons["pantry.add"])
        for (field, wording) in [("pantry.foodName", "Eggs"), ("pantry.amount", "4")] {
            let input = app.textFields[field]
            tap(input)
            input.typeText(wording + "\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        tap(app.buttons["pantry.review"])
        tap(app.buttons["pantry.confirm"])
        XCTAssertTrue(app.buttons["pantry.confirm"].waitForNonExistence(timeout: 8))
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
        XCTAssertEqual(namePickup.label, "Name your shopping list")
        tap(namePickup)
        let createPickup = app.buttons["ledgerCreateShop"]
        XCTAssertTrue(createPickup.waitForExistence(timeout: 5))
        XCTAssertEqual(createPickup.label, "Create shopping list")
        tap(createPickup)
        let confirm = app.buttons["dinner.handoff.confirm"]
        let destination = app.descendants(matching: .any)["dinner.handoff.destination"]
        reveal(destination)
        XCTAssertTrue(destination.label.contains("Groceries for Scrambled eggs"))
        let match = app.buttons["dinner.handoff.matchPantry"]
        reveal(match)
        let choices = app.buttons["dinner.handoff.chooseIngredients"]
        XCTAssertTrue(choices.waitForExistence(timeout: 5))
        XCTAssertLessThan(match.frame.maxY, choices.frame.midY)
        match.tap()
        let picker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinner.handoff.pantryProduct.")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        let useMatches = app.buttons["Use these product matches"]
        XCTAssertFalse(useMatches.isEnabled)
        tap(picker)
        let food = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Eggs · ")).firstMatch
        tap(food)
        XCTAssertTrue(useMatches.isEnabled)
        tap(app.navigationBars["Match food at home"].buttons["Cancel"])
        XCTAssertTrue(app.navigationBars["Match food at home"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Clear product matches"].exists)
        let quantities = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Shopping list quantities for Groceries for Scrambled eggs")).firstMatch
        XCTAssertTrue(quantities.exists)
        revealFollowingAction(confirm)
        XCTAssertEqual(confirm.label, "Plan for tonight")
        confirm.tap()
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

    func testSecondNightKeepsOptionalFoodOffReceiptInEnglish() {
        checkSecondNightReceipt(spanish: false)
    }

    func testSecondNightKeepsOptionalFoodOffReceiptInMexicanSpanish() {
        checkSecondNightReceipt(spanish: true)
    }

    private func checkSecondNightReceipt(spanish: Bool) {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", spanish ? "(es)" : "(en)",
                               "-AppleLocale", spanish ? "es_MX" : "en_US"]
        app.launch()
        let dinners = app.tabBars.buttons[spanish ? "Cenas" : "Dinners"]
        let staple = spanish ? "Huevos" : "Eggs"
        let pairing = spanish ? "Vino (opcional)" : "Wine (optional)"
        let amounts = app.textFields.matching(NSPredicate(format: "label == %@", spanish ? "Cantidad (obligatoria)" : "Amount (required)"))
        let ingredients = app.textFields.matching(identifier: "tonight.recipe.ingredient")
        tap(dinners)
        tap(app.buttons["dinner.saveFirstRecipe"])
        fill(app.textFields["tonight.recipe.title"], spanish ? "Tacos de huevo" : "Egg tacos")
        fill(app.textFields["tonight.recipe.servings"], "2")
        fill(ingredients.firstMatch, staple)
        fill(amounts.firstMatch, "2")
        tap(app.buttons[spanish ? "Añadir ingrediente" : "Add ingredient"])
        fill(ingredients.element(boundBy: 1), pairing)
        fill(amounts.element(boundBy: 1), "1")
        tap(app.buttons["tonight.recipe.review"])
        tap(app.buttons["tonight.recipe.save"])
        tap(app.buttons["dinner.planSaved"].firstMatch)
        tap(app.buttons["dinner.handoff.startPickup"])
        tap(app.buttons["ledgerCreateShop"])

        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinner.handoff.amount."))
        let stapleRows = rows.matching(NSPredicate(format: "label CONTAINS %@", staple))
        let pairingRows = rows.matching(NSPredicate(format: "label CONTAINS %@", pairing))
        func assertQuantities(_ expected: [Int], includesPairing: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
            let item = stapleRows.firstMatch
            reveal(item)
            let numbers = item.label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            XCTAssertEqual(numbers, expected, item.label, file: file, line: line)
            XCTAssertEqual(pairingRows.firstMatch.exists, includesPairing, "Grocery demand must use this night's choice", file: file, line: line)
        }
        assertQuantities([0, 2, 2])
        let choices = app.buttons["dinner.handoff.chooseIngredients"]
        reveal(choices)
        XCTAssertEqual(choices.label, spanish ? "Elegir ingredientes para esta cena" : "Choose ingredients for this dinner")
        XCTAssertGreaterThanOrEqual(choices.frame.height, 44)
        XCTAssertGreaterThan(choices.frame.width, app.frame.width / 2)
        let wine = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                     "dinner.handoff.planIngredient.", pairing)).firstMatch
        reveal(wine)
        XCTAssertEqual(wine.value as? String, "0")
        tap(wine, at: CGVector(dx: 0.92, dy: 0.5))
        assertQuantities([0, 2, 2], includesPairing: true)
        let confirm = app.buttons["dinner.handoff.confirm"]
        tap(confirm)
        let saved = app.descendants(matching: .any).matching(identifier: "dinner.handoff.saved").firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        assertQuantities([0, 2, 2], includesPairing: true)
        tap(app.buttons["dinner.handoff.anotherNight"])
        tap(app.buttons["dinner.plan.reviewFacts"])
        assertQuantities([2, 2, 4])
        tap(confirm)
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        assertQuantities([2, 2, 4])

        // Reopening must preserve the two accepted nights. A third preview remains read-only.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-workspace" }
        app.launch()
        tap(dinners)
        tap(app.buttons["dinner.planSaved"].firstMatch)
        assertQuantities([4, 2, 6])
    }

    func testPastedFamilyNotePlansTomorrowAndChangesOccurrenceBeforeColdReturn() {
        checkFamilyPlanEdit(maximumText: false)
    }

    func testLargestTextKeepsScheduleOnlyConfirmationAheadOfOptionalPriceReview() {
        checkFamilyPlanEdit(maximumText: true)
    }

    private func checkFamilyPlanEdit(maximumText: Bool) {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if maximumText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["dinner.pasteRecipe"])
        let source = app.textViews["dinner.recipe.sourceText"]
        fill(source, "Family pita supper\nServes 4\nPrep time: 25 minutes\n2 sweet potatoes\n4 pitas\nRoast the potatoes.")
        tap(app.buttons["dinner.recipe.reviewPaste"])
        XCTAssertTrue(app.buttons["tonight.recipe.reviewedMinutes"].exists)
        // At accessibility sizes the final Save row enters the Form's accessibility tree only after scrolling.
        let saveRecipe = app.buttons["tonight.recipe.save"]
        revealFollowingAction(saveRecipe)
        saveRecipe.tap()
        tap(app.buttons["dinner.planSaved"].firstMatch)
        tap(app.buttons["dinner.handoff.editPlan"])
        tap(app.buttons["dinner.plan.tomorrow"])
        tap(app.buttons["dinner.plan.reviewFacts"])
        tap(app.buttons["dinner.handoff.startPickup"])
        tap(app.buttons["ledgerCreateShop"])
        let confirm = app.buttons["dinner.handoff.confirm"]
        revealFollowingAction(confirm)
        XCTAssertEqual(confirm.label, "Plan for this day")
        confirm.tap()
        tap(app.buttons["dinner.handoff.openPlan"])
        tap(app.buttons["dinner.occurrence.editPlan"])
        tap(app.buttons["dinner.plan.today"])
        let less = app.buttons["dinner.occurrence.servings.less"]
        tap(less)
        tap(less)
        XCTAssertEqual(app.textFields["dinner.occurrence.servings"].value as? String, "2")
        tap(app.buttons["dinner.occurrence.review"])
        let stableGroceries = app.descendants(matching: .any)["dinner.schedule.groceries"]
        XCTAssertTrue(stableGroceries.waitForExistence(timeout: 8))
        XCTAssertTrue(stableGroceries.label.contains("sweet potatoes") && stableGroceries.label.contains("pitas"))
        let preview = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dinnerPreviewMeal-")).firstMatch
        XCTAssertTrue(preview.label.contains("Family pita supper") && preview.label.contains("Servings: 2"))
        XCTAssertFalse(app.staticTexts["guestFeeImpact"].exists)
        XCTAssertFalse(app.staticTexts["guestCheckoutImpact"].exists)
        let confirmChanges = app.buttons["dinnerApply"]
        if maximumText && !(confirmChanges.exists && confirmChanges.isHittable) { app.swipeUp() }
        XCTAssertTrue(confirmChanges.isHittable, "Saving should take at most one scroll after reviewing this meal.")
        XCTAssertEqual(confirmChanges.label, "Save dinner plan")
        XCTAssertTrue(app.navigationBars["Dinner preview"].exists)
        XCTAssertTrue(app.buttons["dinnerDecisionCancel"].exists)
        tap(confirmChanges)
        XCTAssertTrue(app.buttons["dinnerApply"].waitForNonExistence(timeout: 12))
        let saved = app.descendants(matching: .any).matching(identifier: "dinner.schedule.saved")
            .matching(NSPredicate(format: "label == %@", "Dinner changes saved.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 6))
        XCTAssertTrue(app.navigationBars["Dinner"].waitForExistence(timeout: 6))
        let closeReceipt = app.buttons["dinner.schedule.closeReceipt"]
        XCTAssertTrue(closeReceipt.waitForExistence(timeout: 6))
        XCTAssertEqual(closeReceipt.label, "Done")
        XCTAssertFalse(app.buttons["dinnerDecisionCancel"].exists)
        XCTAssertTrue(preview.label.contains("Servings: 2"))
        closeReceipt.tap()
        XCTAssertTrue(saved.waitForNonExistence(timeout: 6))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-workspace" }
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        let occurrence = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Family pita supper", "Servings: 2")).firstMatch
        XCTAssertTrue(occurrence.waitForExistence(timeout: 12), app.debugDescription)
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
        let nameList = app.buttons["dinner.handoff.startPickup"]
        XCTAssertEqual(nameList.label, "Name your shopping list")
        tap(nameList)
        let createList = app.buttons["ledgerCreateShop"]
        XCTAssertTrue(createList.waitForExistence(timeout: 5))
        XCTAssertEqual(createList.label, "Create shopping list")
        XCTAssertEqual(app.descendants(matching: .any)["ledgerShopName"].label, "Shopping list name (required)")
        tap(createList)
        XCTAssertTrue(app.navigationBars["Shop for ingredients only"].waitForExistence(timeout: 5))
        let changeList = app.descendants(matching: .any).matching(identifier: "dinner.handoff.pickup").firstMatch
        XCTAssertTrue(changeList.waitForExistence(timeout: 5))
        XCTAssertEqual(changeList.label, "Change list")
        tap(changeList, at: CGVector(dx: 0.8, dy: 0.5))
        let createAnotherList = app.buttons["Create shopping list"]
        XCTAssertTrue(createAnotherList.waitForExistence(timeout: 5), "The trailing area of Change list must open its menu.")
        tap(createAnotherList)
        tap(app.navigationBars["Create shopping list"].buttons["Cancel"])
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
        XCTAssertTrue(app.fullListCheck(labeled: "Check Lemon").waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.fullListCheck(labeled: "Check Chickpeas").exists)
    }

    func testBothPrivateTonightEntriesWorkWithoutShopAndCancelCreatesNothing() throws {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if #unavailable(iOS 18) { app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable" }
        app.launch()
        tap(app.shopToolButton("shop.myPantry"))
        tap(app.buttons["pantry.setup.apply"])
        tap(app.buttons["pantry.tonight"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 12))
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Save a recipe you cook.")).firstMatch
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
        let recipe = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "tonight.result.", "No-shop rice dinner")).firstMatch
        revealInList(recipe)
        // iOS 17 exposes the disclosure chevron separately from its named recipe row.
        tap(recipe, at: CGVector(dx: 0.94, dy: 0.5))
        let unresolvedPrice = app.staticTexts.matching(NSPredicate(format: "label == %@", "Some amounts or package prices still need review.")).firstMatch
        revealInList(unresolvedPrice)
        XCTAssertTrue(unresolvedPrice.exists, app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tonight.choose.")).firstMatch.isEnabled,
                       "No stock match cannot be offered as a pantry-based dinner")
        tap(app.navigationBars["Tonight"].buttons["My Pantry"])
        let pantryClose = app.navigationBars["My Pantry"].buttons["Close"]
        if pantryClose.exists { tap(pantryClose) }
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
        reveal(element)
        if let offset { element.coordinate(withNormalizedOffset: offset).tap() }
        else { element.tap() }
    }

    private func revealFollowingAction(_ action: XCUIElement) {
        for _ in 0..<8 {
            if action.exists && action.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(action.exists && action.isHittable, app.debugDescription)
    }

    private func reveal(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 3)
        for index in 0..<16 {
            if element.exists && element.isHittable { break }
            let moveDown = element.exists ? element.frame.midY > app.frame.midY : index < 8
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: moveDown ? 0.65 : 0.36))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: moveDown ? 0.38 : 0.63))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
    }
}
#endif
