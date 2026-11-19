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
        fill(app.textFields["tonight.recipe.ingredient"], "Corn")
        let amount = app.textFields["Amount (required)"]
        XCTAssertTrue(amount.exists)
        tap(app.buttons["tonight.recipe.review"])
        let error = app.staticTexts["tonight.recipe.amountError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Enter an amount greater than zero for Corn.")
        XCTAssertTrue(amount.isHittable)
        amount.typeText("1")  // Validation focuses the ingredient needing correction.
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        tap(app.buttons["tonight.recipe.review"])
        tap(app.buttons["tonight.recipe.save"])
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
        tap(app.buttons["Review a recipe by hand"])
        XCTAssertTrue(app.navigationBars["Review a recipe"].waitForExistence(timeout: 8))
        tap(app.buttons["Cancel"])
        XCTAssertTrue(app.navigationBars["Tonight"].waitForExistence(timeout: 8))
        // A real reviewed recipe can be saved before any shop exists. Canceling
        // earlier must not have filled the reusable slot or created a pickup.
        tap(app.buttons["Review a recipe by hand"])
        fill(app.textFields["tonight.recipe.title"], "No-shop rice dinner")
        fill(app.textFields["tonight.recipe.servings"], "1")
        fill(app.textFields["tonight.recipe.ingredient"], "Rice")
        fill(app.textFields["Amount (required)"], "1")
        tap(app.buttons["tonight.recipe.review"])
        tap(app.buttons["tonight.recipe.save"])
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
    private func revealInList(_ element: XCUIElement) {
        for _ in 0..<12 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            if element.exists, element.frame.midY > top, element.frame.midY < bottom { return }
            app.swipeUp()
        }
        XCTFail("Expected the requested row in the visible list: " + app.debugDescription)
    }
    private func fill(_ element: XCUIElement, _ value: String) {
        tap(element); element.typeText(value)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
    }
    private func tap(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<14 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
        element.tap()
    }
}
#endif
