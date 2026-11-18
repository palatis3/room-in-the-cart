#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Dedicated fixture build only; shipping app models/views/client, intercepted fictional endpoints.
@MainActor final class ContributorRequestUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Contributor-request-failure") }
        app.terminate()
    }
    func testHouseholdMealPreferencesOrganizerReviewsAndAdultReads() {
        app.launchArguments = ["--ui-testing", "--household-meal-organizer", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        func open() { tap(app.buttons["household.mealPreferences"]) }
        open()
        let edit = app.buttons["household.preferences.edit"]
        tap(edit)
        let field = element("preferences.exclusions")
        tap(field)
        field.typeText("peanut")
        let done = app.buttons["preferences.keyboardDone"]
        tap(done)
        XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: "preferences.keyboardDone"))
        tap(element("preferences.review"))
        tap(element("preferences.save"))
        let rule = NSPredicate(format: "label CONTAINS %@", "peanut")
        XCTAssertTrue(app.staticTexts.matching(rule).firstMatch.waitForExistence(timeout: 10))
        let grant = app.switches["Alex"]
        reveal(grant, fullyVisible: true)
        grant.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let granted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: grant)
        XCTAssertEqual(XCTWaiter.wait(for: [granted], timeout: 8), .completed)
        tap(app.navigationBars.buttons.firstMatch)
        open()
        XCTAssertTrue(grant.waitForExistence(timeout: 10))
        XCTAssertEqual(grant.value as? String, "1")
        app.terminate()

        app.launchArguments = ["--ui-testing", "--household-meal-reader", "-AppleLanguages", "(es)", "-AppleLocale", "es_US"]
        app.launch()
        open()
        XCTAssertTrue(app.staticTexts.matching(rule).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Exigir que las comidas estén listas dentro de este tiempo"].exists)
        XCTAssertFalse(edit.exists)
        XCTAssertFalse(app.switches["Alex"].exists)
    }

    func testAdultReviewsHouseholdStaplePurchaseAndAnswersQuestionAcrossReopen() {
        app.launchArguments = ["--ui-testing", "--household-staple-reminders", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.buttons["household.pantry"])
        let entry = app.buttons["householdPantry.staples"]
        tap(entry)
        let have = app.buttons["householdStaple.stillHave"]
        tap(have)
        XCTAssertFalse(have.exists)
        tap(app.buttons["householdStaple.purchase"])
        tap(element("householdStaple.delivery"))
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Oats")).firstMatch)
        fill("Oats", into: "householdStaple.name")
        tap(app.buttons["householdStaple.review"])
        XCTAssertTrue(app.staticTexts["Received usable quantity"].waitForExistence(timeout: 10))
        tap(app.buttons["householdStaple.confirmPurchase"])
        XCTAssertTrue(app.staticTexts["1 reviewed purchase"].waitForExistence(timeout: 10))
        tap(app.buttons["Done"])
        tap(entry)
        XCTAssertTrue(app.staticTexts["1 reviewed purchase"].waitForExistence(timeout: 10))
        XCTAssertFalse(have.exists)
        XCTAssertTrue(app.staticTexts["3 reviewed purchases"].exists)
    }

    func testHouseholdTonightReviewsARecipeWithoutAShopAndCancelKeepsItUnscheduled() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "--household-tonight-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.buttons["settings"])
        tap(app.buttons["household.pantry"])
        tap(app.buttons["household.tonight"])
        XCTAssertTrue(app.staticTexts["No household recipes are available for tonight."].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["householdTonight.recipe.new"])
        fill("Family rice", into: "householdTonight.recipe.title")
        fill("2", into: "householdTonight.recipe.servings")
        fill("Rice", into: "householdTonight.recipe.ingredient")
        fill("3", into: "householdTonight.recipe.amount")
        tap(app.buttons["Match household batches"])
        let lot = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdTonight.recipe.lot.")).firstMatch
        XCTAssertTrue(lot.waitForExistence(timeout: 5), app.debugDescription)
        enableSwitch(lot.identifier)
        tap(app.buttons["householdTonight.recipe.review"])
        tap(app.buttons["householdTonight.recipe.save"])
        XCTAssertTrue(app.staticTexts["Family rice"].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["Edit household recipe"])
        fill("Family rice bowls", into: "householdTonight.recipe.title", replacing: true)
        tap(app.buttons["householdTonight.recipe.review"])
        tap(app.buttons["householdTonight.recipe.save"])
        let title = app.staticTexts["Family rice bowls"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdTonight.choose.")).firstMatch)
        XCTAssertTrue(app.buttons["Review a new shared shop"].exists)
        XCTAssertFalse(app.buttons["householdTonight.confirm"].exists)
        tap(app.buttons["householdTonight.cancel"])
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        tap(app.navigationBars["Household Tonight"].buttons.element(boundBy: 0))
        tap(app.navigationBars["Household pantry"].buttons.element(boundBy: 0))
        tap(app.navigationBars["Settings"].buttons["Done"])
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["household.tonight"])
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdTonight.choose.")).firstMatch)
        XCTAssertTrue(app.buttons["Review a new shared shop"].exists)
        XCTAssertFalse(app.buttons["householdTonight.destination"].exists)
    }

    func testAssignedShopperChoosesOneHouseholdDinnerAfterCancelingPreview() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "--household-tonight-fixture", "--tonight-assigned-shop",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["household.tonight"])
        let choose = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdTonight.choose.")).firstMatch
        tap(choose)
        tap(app.buttons["householdTonight.destination"])
        XCTAssertTrue(app.buttons["householdTonight.confirm"].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["householdTonight.cancel"])
        tap(choose)
        tap(app.buttons["householdTonight.destination"])
        tap(app.buttons["householdTonight.confirm"])
        let saved = app.staticTexts["householdTonight.notice"]
        XCTAssertTrue(saved.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(saved.label, "Dinner added to the shared shop.")
        tap(app.navigationBars["Household Tonight"].buttons.element(boundBy: 0))
        tap(app.tabBars.buttons["Shop"])
        tap(app.buttons["settings"])
        tap(app.buttons["Household requests"])
        tap(app.buttons["Open shared household shop"])
        reveal(app.staticTexts["Household bean bowls"], fullyVisible: true)
        XCTAssertTrue(app.staticTexts["Household bean bowls"].exists, app.debugDescription)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Household bean bowls").count, 1)
    }

    func testHouseholdTonightRefusesConfirmationAfterStockChanges() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "--household-tonight-fixture", "--tonight-assigned-shop",
                               "--tonight-stock-changed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.tabBars.buttons["Dinners"])
        tap(app.buttons["household.tonight"])
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdTonight.choose.")).firstMatch)
        tap(app.buttons["householdTonight.destination"])
        tap(app.buttons["householdTonight.confirm"])
        let notice = app.staticTexts["householdTonight.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(notice.label, "Household stock, the recipe or planning access changed. Refresh before choosing again.")
        XCTAssertFalse(app.buttons["householdTonight.confirm"].exists)
    }

    func testOrganizerReviewsAProductLabelFromMyPantryWithoutStartingPrivateSetup() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "--household-tonight-fixture", "--tonight-package-review",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.buttons["shop.myPantry"])
        tap(app.buttons["household.tonight"])
        let choose = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdTonight.choose.")).firstMatch
        XCTAssertTrue(app.staticTexts["Reviewed rice supper"].waitForExistence(timeout: 8))
        XCTAssertFalse(choose.exists)
        tap(app.buttons["Edit household recipe"])
        let label = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdTonight.label.")).firstMatch
        tap(label)
        XCTAssertFalse(app.buttons["householdTonight.label.apply"].isEnabled)
        enableSwitch("Package ingredients reviewed")
        tap(app.navigationBars["Review this package label"].buttons["Cancel"])
        tap(label)
        XCTAssertFalse(app.buttons["householdTonight.label.apply"].isEnabled)
        enableSwitch("Package ingredients reviewed")
        enableSwitch("Package brands reviewed")
        let brandID = "householdTonight.label.brands"
        let brandInput = app.textViews[brandID]
        XCTAssertTrue(brandInput.waitForExistence(timeout: 5), app.debugDescription)
        fill("North Farm", into: brandID, input: brandInput)
        tap(app.buttons["householdTonight.label.apply"])
        tap(app.buttons["householdTonight.recipe.review"])
        assertText("North Farm")
        tap(app.buttons["householdTonight.recipe.save"])
        reveal(choose)
        XCTAssertTrue(choose.exists, app.debugDescription)
        tap(app.buttons["Edit household recipe"])
        tap(label)
        XCTAssertEqual(app.switches["Package ingredients reviewed"].value as? String, "1")
        XCTAssertEqual(brandInput.value as? String, "North Farm")
    }

    func testEnrolledAdultReviewsTwoReceiptLinesAndReopensOnlyHouseholdEvidence() {
        app.launchArguments = ["--ui-testing", "--reset-test-workspace", "--household-receipt-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let shop = app.tabBars.buttons["Shop"]
        XCTAssertTrue(shop.waitForExistence(timeout: 30), app.debugDescription)
        func dismissReceiptKeyboard(_ identifier: String) {
            let tip = app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."]
            if tip.exists {
                tap(app.buttons["Continue"])
                XCTAssertTrue(tip.waitForNonExistence(timeout: 5))
            }
            tap(app.buttons[identifier])
            XCTAssertTrue(app.waitForKeyboardDismissal(doneIdentifier: identifier), app.debugDescription)
        }
        func allBatchIDs(prefix: String) -> Set<String> {
            // SwiftUI creates the remaining stock and correction rows as the list scrolls.
            let list = app.collectionViews.firstMatch
            let batches = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            list.swipeDown()
            list.swipeDown()
            var ids = Set(batches.allElementsBoundByIndex.map(\.identifier))
            for _ in 0..<3 {
                list.swipeUp()
                ids.formUnion(batches.allElementsBoundByIndex.map(\.identifier))
            }
            return ids
        }
        func back(from title: String) { tap(app.navigationBars[title].buttons.element(boundBy: 0)) }
        func privateHistoryIsEmpty() {
            tap(app.buttons["pantry.receiptHistory"])
            XCTAssertTrue(app.staticTexts["No confirmed receipt lines yet."].waitForExistence(timeout: 8), app.debugDescription)
            tap(app.buttons["Done"])
        }
        tap(app.buttons["shop.myPantry"])
        tap(app.buttons["pantry.setup.apply"])
        tap(app.buttons["pantry.add"])
        fill("Private lentils", into: "pantry.foodName")
        fill("7", into: "pantry.amount")
        tap(app.buttons["pantry.review"])
        tap(app.buttons["pantry.confirm"])
        let privateLot = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                         "pantry.lot.", "Private lentils")).firstMatch
        reveal(privateLot)
        let privateID = privateLot.identifier, privateLabel = privateLot.label
        privateHistoryIsEmpty()
        back(from: "My Pantry")
        tap(app.buttons["settings"])
        let entry = app.buttons["household.pantry"]
        tap(entry)
        XCTAssertTrue(app.staticTexts["No household batches recorded."].waitForExistence(timeout: 8))
        tap(app.buttons["householdPantry.receipt"])
        tap(app.buttons["householdReceipt.scan"])
        let wording = app.textViews["scan.sourceEditor"]
        tap(wording)
        wording.typeText("Oats 3 count USD 4.20\nBeans 5 count USD 6.10\nPaper bag fee")
        dismissReceiptKeyboard("scan.sourceDone")
        let merchant = app.textFields["Source reference label"]
        tap(merchant)
        merchant.typeText("Corner Market")
        dismissReceiptKeyboard("scan.sourceDone")
        tap(app.buttons["Review printed lines"])
        enableSwitch("I reviewed these lines as source evidence only.")
        tap(app.buttons["scan.receipt.review"])
        enableSwitch("I checked the purchase date.")
        for (ordinal, usable) in [(0, "2"), (1, "4")] {
            tap(app.buttons["receipt.action.\(ordinal)"])
            tap(app.buttons["Add a separate physical batch"])
            tap(app.buttons["receipt.printedQuantity.\(ordinal)"])
            fill(usable, into: "receipt.usable.\(ordinal)")
            if ordinal == 0 {
                let paid = app.buttons["receipt.printedPrice.0"]
                reveal(paid, fullyVisible: true)
                paid.tap()
                let entered = app.textFields["Confirmed paid line total in USD, optional"].firstMatch
                reveal(entered, fullyVisible: true)
                XCTAssertEqual(entered.value as? String, "4.20", app.debugDescription)
            }
        }
        tap(app.buttons["householdReceipt.review"])
        let confirm = app.buttons["householdReceipt.confirm"]
        tap(confirm)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), app.debugDescription)
        back(from: "Household pantry")
        tap(entry)
        for (original, received, usable, price) in [
            ("Oats 3 count USD 4.20", "3 units", "2 units", "$4.20"),
            ("Beans 5 count USD 6.10", "5 units", "4 units", "Paid price unknown")
        ] {
            let lot = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                                           original, "Corner Market")).firstMatch
            reveal(lot)
            XCTAssertTrue(lot.label.contains("Received " + received), lot.label)
            XCTAssertTrue(lot.label.contains("Usable " + usable), lot.label)
            XCTAssertTrue(lot.label.contains(price), lot.label)
        }
        XCTAssertEqual(allBatchIDs(prefix: "householdPantry.correct.").count, 2)
        back(from: "Household pantry")
        tap(app.navigationBars["Settings"].buttons["Done"])
        tap(app.buttons["shop.myPantry"])
        let samePrivateLot = app.buttons[privateID]
        reveal(samePrivateLot)
        XCTAssertEqual(samePrivateLot.label, privateLabel)
        XCTAssertEqual(allBatchIDs(prefix: "pantry.lot."), [privateID])
        privateHistoryIsEmpty()
    }

    func testOrganizerCorrectsNewPantryCountAndRecoversLostReceiptOnReopen() {
        app.launchArguments = ["--ui-testing", "--household-pantry-correction", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let entry = app.buttons["household.pantry"]
        tap(entry)
        tap(app.buttons["householdPantry.add"])
        fill("Limes", into: "householdPantry.name")
        fill("2", into: "householdPantry.quantity")
        tap(app.buttons["householdPantry.review"])
        tap(app.buttons["householdPantry.confirm"])
        let correct = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "householdPantry.correct.")).firstMatch
        tap(correct)
        fill("0", into: "householdPantry.correctedQuantity", replacing: true)
        tap(app.buttons["householdPantry.reviewCount"])
        tap(app.buttons["householdPantry.confirmCount"])
        XCTAssertTrue(element("householdPantry.notice").waitForExistence(timeout: 10))
        tap(app.navigationBars.buttons.firstMatch)
        tap(entry)
        let retry = app.buttons["householdPantry.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        tap(retry)
        XCTAssertTrue(correct.waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        tap(app.navigationBars.buttons.firstMatch)
        tap(entry)
        tap(correct)
        XCTAssertEqual(element("householdPantry.correctedQuantity").value as? String, "0")
    }

    func testEditableCookReportPreservesCorrectionDraftAndReadOnlyGrantCannotWriteStock() {
        app.launchArguments = ["--ui-testing", "--cook-report-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 30))
        tap(app.buttons["Cook instructions"])
        let correction = element("helper.correction")
        reveal(correction, fullyVisible: true)
        XCTAssertEqual(correction.value as? String, "Keep the original correction draft", app.debugDescription)
        XCTAssertEqual(element("fixture.reportPosts").label, "Report POSTs: 0")
        tap(app.buttons["Report what you cooked"])
        fill("3", into: "helper.cookingReport.servings")
        let ingredients = "Used 2 wraps; substituted rice for the remaining wrap. Salt amount unknown."
        let leftovers = "1 portion in the fridge. No freezer portions."
        fill(ingredients, into: "helper.cookingReport.ingredients")
        fill(leftovers, into: "helper.cookingReport.leftovers")
        let done = app.buttons["helper.cookingReport.done"]
        if done.exists && done.isHittable { done.tap() }
        XCTAssertFalse(app.buttons["helper.cookingReport.send"].exists)
        tap(app.buttons["helper.cookingReport.review"])
        let expected = "Cooking report\n\nServings made\n3\n\nIngredients used and substitutions\n" + ingredients +
            "\n\nLeftovers and storage location\n" + leftovers
        let preview = element("helper.cookingReport.preview")
        reveal(preview)
        XCTAssertEqual(preview.label, expected, app.debugDescription)
        XCTAssertEqual(element("fixture.reportPosts").label, "Report POSTs: 0", "Review cannot send the report")
        XCTAssertEqual(element("fixture.reportOtherWrites").label, "Other writes: 0")
        tap(app.buttons["helper.cookingReport.send"])
        let received = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Report POSTs: 1"), object: element("fixture.reportPosts"))
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 10), .completed, app.debugDescription)
        XCTAssertEqual(element("fixture.reportText").label, expected, "Only the explicitly reviewed report should be sent")
        reveal(correction, fullyVisible: true)
        XCTAssertEqual(correction.value as? String, "Keep the original correction draft", "Sending a report must not overwrite another draft")
        XCTAssertEqual(element("fixture.reportOtherWrites").label, "Other writes: 0", "Cook-only reporting cannot call basket or pantry mutation routes")
        tap(app.buttons["fixture.reportReadOnly"])
        let downgraded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Fixture grant is read-only"), object: app.buttons["fixture.reportReadOnly"])
        XCTAssertEqual(XCTWaiter.wait(for: [downgraded], timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["Report what you cooked"].exists)
        XCTAssertFalse(app.buttons["helper.cookingReport.send"].exists)
        XCTAssertFalse(element("helper.correction").exists)
        let instruction = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Save two")).firstMatch
        XCTAssertTrue(instruction.exists, "The report and grant change must not alter the shared instructions")
        XCTAssertEqual(element("fixture.reportPosts").label, "Report POSTs: 1")
        XCTAssertEqual(element("fixture.reportOtherWrites").label, "Other writes: 0")
        capture("Cook-only-report-explicit-send-preserved-draft-read-only")
    }

    func testHelperSeesCurrentInstructionRevisionAndDateAfterRefreshInBothLanguages() {
        for (language, entry, label, refresh) in [
            ("en", "Cook instructions", "Current instruction revision", "Refresh instructions"),
            ("es", "Instrucciones para cocinar", "Versión actual de las instrucciones", "Actualizar instrucciones")
        ] {
            app.launchArguments = ["--ui-testing", "--helper-revision-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", language + "_US"]
            app.launch()
            // The helper link can be below the visible rows of the settings Form.
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 30))
            XCTAssertFalse(app.buttons["household.priceBudgetHistory"].exists)
            tap(app.buttons[entry])
            func read(_ number: Int, _ action: String) {
                let instruction = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", action)).firstMatch
                XCTAssertTrue(instruction.waitForExistence(timeout: 10))
                let revision = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND (value == %@ OR label CONTAINS %@)", label, String(number), String(number))).firstMatch
                XCTAssertTrue(revision.exists, app.debugDescription)
            }
            read(12, "Save two")
            let updated = element("helper.instructions.asOf")
            func timestamp() -> String { updated.label + (updated.value as? String ?? "") }
            let before = timestamp()
            XCTAssertTrue(before.contains("2026"), before)
            tap(app.buttons[refresh])
            read(13, "Save three")
            XCTAssertNotEqual(timestamp(), before)
            app.terminate()
        }
    }

    func testGuardianChildChoosesPickupAndReviewsNextShopRequest() {
        app.launchArguments = ["--ui-testing", "--guardian-request-pickups-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["My requests"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["guardian.childHousehold"].label, "Fixture home")
        fill("Tortillas", into: "guardian.childRequestItem")
        let review = app.buttons["guardian.childRequestReview"]
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let returnKey = keyboard.buttons["Return"]
            XCTAssertTrue(returnKey.isEnabled)
            XCTAssertTrue(returnKey.isHittable)
            returnKey.tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        }
        XCTAssertEqual(app.textFields["guardian.childRequestItem"].value as? String, "Tortillas")
        XCTAssertTrue(review.exists)
        XCTAssertFalse(review.isEnabled)

        tap(app.buttons["guardian.childRequestMorePickups"])
        tap(app.buttons["guardian.childRequestPickup"])
        let secondPickup = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "22222222")).firstMatch
        XCTAssertTrue(secondPickup.waitForExistence(timeout: 8), app.debugDescription)
        secondPickup.tap()
        tap(app.buttons["guardian.childRequestsRefresh"])
        tap(review)
        XCTAssertTrue(app.navigationBars["Review your request"].waitForExistence(timeout: 10))
        let reviewedPickup = element("guardian.childReviewedPickup")
        let destination = reviewedPickup.label + (reviewedPickup.value as? String ?? "")
        XCTAssertTrue(destination.contains("22222222"), destination)
        XCTAssertTrue(destination.contains("2026"), destination)
        let route = element("household.request.reviewDestination")
        XCTAssertTrue((route.label + (route.value as? String ?? "")).contains("Request for next shop"))
        enableSwitch("I reviewed the original wording, item, quantity, packs, exclusions and destination.")
        tap(app.buttons["household.request.sendReviewed"])
        let saved = app.staticTexts["fixture.requestRows"]
        let received = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Fixture saved requests: 1"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 12), .completed, app.debugDescription)

        let withdraw = app.buttons["household.withdrawRequest"]
        tap(withdraw)
        let dialog = app.alerts["Withdraw this request?"]
        XCTAssertTrue(dialog.staticTexts["Withdraw this request?"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(dialog.staticTexts["Tortillas"].exists)
        dialog.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["fixture.requestPosts"].label, "Fixture request POSTs: 1")

        tap(withdraw)
        dialog.buttons["Withdraw request"].tap()
        XCTAssertTrue(app.staticTexts["Withdrawn"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(withdraw.exists)
        XCTAssertEqual(app.staticTexts["fixture.requestPosts"].label, "Fixture request POSTs: 2")
    }

    func testSpanishContributorReadsOnlyExplicitPurchaseStatusOnTheirOwnRequests() {
        app.launchArguments = ["--ui-testing", "--own-purchases-fixture", "-AppleLanguages", "(es)", "-AppleLocale", "es_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hogar"].waitForExistence(timeout: 20))
        let bought = element("household.ownRequest.aaaaaaaa-1111-4111-8111-111111111111")
        let unconfirmed = element("household.ownRequest.bbbbbbbb-1111-4111-8111-111111111111")
        reveal(bought)
        XCTAssertTrue(bought.label.contains("Arroz"), bought.label)
        XCTAssertTrue(bought.label.contains("La persona que hizo la compra confirm\u{00f3} que se compr\u{00f3}"), bought.label)
        reveal(unconfirmed)
        XCTAssertTrue(unconfirmed.label.contains("Fruta"), unconfirmed.label)
        XCTAssertFalse(unconfirmed.label.contains("se compr\u{00f3}"), unconfirmed.label)
        XCTAssertFalse(element("delivery.requestPurchases").exists)
        XCTAssertFalse(element("household.decision.after-total").exists)
        XCTAssertFalse(app.buttons["household.decision.checkoutDetails"].exists)
        XCTAssertFalse(app.buttons["household.decision.includedCharges"].exists)
    }

    func testSpanishLargeTextReviewStartsAtTheOriginalWording() {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17 {
            app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        }
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(es)", "-AppleLocale", "es_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hogar"].waitForExistence(timeout: 30))
        tap(element("household.request.capture"))
        let captureBar = app.navigationBars["Capturar una solicitud"]
        XCTAssertTrue(captureBar.waitForExistence(timeout: 10))
        let original = "2 paquetes de 8 tortillas para almuerzo sin leche"
        fill(original, into: "capture.editor", replacing: true)
        enableSwitch("Revisé el texto, las cantidades, las unidades y las exclusiones.")
        tap(element("capture.reviewFields"))

        let atTop = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let app = object as? XCUIApplication, let screen = try? app.snapshot() else { return false }
            // Read the original wording and its viewport together. Separate live
            // descendant queries can spend the entire deadline resolving one row.
            var pending = screen.children
            var wording: (any XCUIElementSnapshot)?
            var bar: (any XCUIElementSnapshot)?
            while let node = pending.popLast() {
                if node.elementType == .staticText && node.identifier == "capture.structured.original" { wording = node }
                if node.elementType == .navigationBar && (node.identifier == "Capturar una solicitud" || node.label == "Capturar una solicitud") { bar = node }
                pending.append(contentsOf: node.children)
            }
            guard let wording, let bar, wording.label == original, !wording.frame.isEmpty else { return false }
            return wording.frame.minY >= bar.frame.maxY && wording.frame.minY < screen.frame.midY
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [atTop], timeout: 12), .completed)
        let wording = app.staticTexts["capture.structured.original"]
        XCTAssertTrue(wording.isHittable)
        XCTAssertEqual(wording.label, original)
        capture("Spanish-large-text-original-at-top")
    }

    func testCancellingCorrectionReplacementPreservesDraftUntilConfirmed() {
        app.launchArguments = ["--ui-testing", "--rejected-correction-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForHousehold(timeout: 20)
        let item = app.textFields["Item"]
        let amount = app.textFields["Quantity, optional"]
        let review = app.buttons["Review my correction"]
        reveal(item)
        XCTAssertEqual(item.value as? String, "Rice")
        reveal(amount)
        XCTAssertEqual(amount.value as? String, "3 bags")
        tap(review)
        let dialog = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND elementType != %d",
            "Replace your current draft with the saved correction?", XCUIElement.ElementType.staticText.rawValue)).firstMatch
        XCTAssertTrue(dialog.buttons["Replace draft"].waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        if cancel.isHittable {
            cancel.tap()
        } else {
            let dismiss = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismiss.exists)
            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        reveal(item)
        XCTAssertEqual(item.value as? String, "Rice")
        reveal(amount)
        XCTAssertEqual(amount.value as? String, "3 bags")

        tap(review)
        dialog.buttons["Replace draft"].tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 10))
        reveal(item)
        XCTAssertEqual(item.value as? String, "Cereal")
        reveal(amount)
        XCTAssertEqual(amount.value as? String, "2 boxes")
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 2")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 1")
    }

    func testTypedAndStructuredReviewCancelThenSendOnlyOwnRequest() throws {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForHousehold(timeout: 20)
        fill("Rice", into: "Item")
        fill("2 packs", into: "Quantity, optional")
        tap(element("household.request.review"))
        assertText("Request the household will receive")
        assertText("Rice")
        tap(app.buttons["Cancel"])
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 0")
        openStructuredReview()
        capture("Contributor-original-and-corrected-request-preview")
        tap(app.buttons["Cancel"])
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 0")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 0")
        openStructuredReview()
        let approval = element("household.request.approve")
        reveal(approval, fullyVisible: true)
        approval.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(approval.value as? String, "1")
        tap(element("household.request.sendReviewed"))
        waitForHousehold(timeout: 10)
        let posts = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Fixture request POSTs: 1"), object: element("fixture.requestPosts"))
        let rows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Fixture saved requests: 1"), object: element("fixture.requestRows"))
        XCTAssertEqual(XCTWaiter.wait(for: [posts, rows], timeout: 10), .completed)
        XCTAssertEqual(element("fixture.requestPosts").label, "Fixture request POSTs: 1")
        XCTAssertEqual(element("fixture.requestRows").label, "Fixture saved requests: 1")
        assertText("Wholemeal wraps")
        assertText("2 packs of 8 wraps for lunch without sesame")
        assertText("Received, waiting for review")
        capture("Contributor-reviewed-own-request-received")
    }
    private func waitForHousehold(timeout: TimeInterval) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let bar = object as? XCUIElement else { return false }
            return bar.exists && bar.isHittable
        }, object: app.navigationBars["Household"])
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: timeout), .completed)
    }
    private func openStructuredReview() {
        tap(element("household.request.capture"))
        fill("2 packs of 8 wraps for lunch without sesame", into: "capture.editor", replacing: true)
        enableSwitch("I checked the wording, amounts, units and exclusions.")
        tap(element("capture.reviewFields"))
        fill("Wholemeal wraps", into: "Item name", replacing: true)
        let packs = element("Number of packs, unknown if blank")
        reveal(packs); XCTAssertEqual(packs.value as? String, "2")
        let perPack = element("Usable amount in each pack, unknown if blank")
        reveal(perPack); XCTAssertEqual(perPack.value as? String, "8")
        enableSwitch("I reviewed this item, amounts, packs, purpose, destination and exclusions, including any unknowns.")
        tap(element("capture.continue"))
        assertText("Original wording")
        assertText("Wholemeal wraps")
        assertText("lunch")
        assertText("sesame")
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        for attempt in 0..<24 {
            var area = scrollableArea()
            let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Listo"])).firstMatch
            if app.keyboards.firstMatch.exists && done.exists {
                area.size.height = max(0, min(area.maxY, done.frame.minY) - area.minY)
            }
            XCTAssertGreaterThanOrEqual(area.height, 80, "Need visible form content before acknowledging \(label)")
            if control.exists && !control.frame.isEmpty {
                // The row includes a multiline label. Target its native off thumb.
                XCTAssertEqual(control.switches.count, 1, label)
                let native = control.switches.firstMatch
                let coordinate = native.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
                let point = coordinate.screenPoint
                if control.isEnabled && control.isHittable && native.isEnabled && native.isHittable && area.contains(point) {
                    print("CONTRIBUTOR_SWITCH_TAP label=\(label) point=\(point) area=\(area)")
                    if control.value as? String == "0" {
                        XCTAssertEqual(native.value as? String, "0", label)
                        coordinate.tap()
                    }
                    XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
                    return
                }
                scrollContent(upward: point.y > area.midY, distance: abs(point.y - area.midY))
            } else {
                scrollContent(upward: attempt < 16)
            }
        }
        XCTFail("No visible switch tap point after 24 reveal attempts: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false, input: XCUIElement? = nil) {
        // A Form can expose both its StaticText label and its input with the
        // same name. Never let a label become the typing target.
        let field = input ?? (id == "capture.editor" ? app.textViews[id] : app.textFields[id])
        tap(field)
        dismissBilingualKeyboardCardIfPresent()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The input must have a software keyboard before typing")
        if replacing, let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            // Tapping a multiline editor does not put the caret at its end.
            // Select the whole value through the real edit menu before replacing it.
            field.press(forDuration: 1.2)
            let labels = ["Select All", "Seleccionar todo"]
            let menuItem = app.menuItems.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            let button = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            let selectAll = menuItem.exists ? menuItem : button
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(selectAll.isHittable)
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            let cleared = field.value as? String
            XCTAssertTrue(cleared == "" || cleared == field.placeholderValue, "The entire input must be cleared: \(cleared ?? "nil")")
        }
        field.typeText(text)
        dismissBilingualKeyboardCardIfPresent()
        XCTAssertEqual(field.value as? String, text, "Typed input must exactly replace the draft before review")
        if id == "capture.editor" {
            dismissCaptureKeyboard()
            // Large text can move this Form row offscreen during dismissal.
            // Reveal it again before reading the virtualized editor's value.
            reveal(field)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Revealing the editor must not reopen the keyboard")
            XCTAssertEqual(field.value as? String, text, "Dismissing the keyboard must preserve the draft")
        }
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func dismissCaptureKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        // End editing through the same explicit control available to a person;
        // a Form swipe can leave keyboard dismissal dependent on its scroll state.
        let done = app.buttons["capture.sourceDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The source editor must offer Done")
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Done must dismiss the capture keyboard")
    }
    private func dismissBilingualKeyboardCardIfPresent() {
        let title = app.staticTexts["Type español e inglés"]
        guard title.waitForExistence(timeout: 2) else {
            XCTContext.runActivity(named: "Bilingual keyboard onboarding absent") { _ in }
            return
        }
        // This is the observed iOS keyboard onboarding card, not an arbitrary
        // Continue button or a product consent dialog.
        XCTAssertTrue(app.staticTexts["Type both languages on the same keyboard. Customize in Settings."].exists)
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.exists && next.isHittable)
        XCTContext.runActivity(named: "Dismiss the identified bilingual keyboard onboarding card") { _ in
            capture("Bilingual-keyboard-card-before-dismissal")
            next.tap()
            XCTAssertTrue(title.waitForNonExistence(timeout: 5), "The identified keyboard onboarding card must dismiss")
            capture("Bilingual-keyboard-card-dismissed")
        }
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false) {
        for attempt in 0..<24 {
            let area = scrollableArea()
            // A partly visible multiline switch can be hittable while its
            // trailing control is still behind the software keyboard.
            if target.exists && target.isHittable,
               !fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY) { return }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            // A tall accessibility row may fit the viewport but not tolerate
            // another full swipe. Center it with a measured, bounded drag.
            let distance = fullyVisible && target.exists && !target.frame.isEmpty
                ? abs(target.frame.midY - area.midY) : nil
            scrollContent(upward: upward, distance: distance)
        }
        let area = scrollableArea()
        XCTAssertTrue(target.exists && target.isHittable &&
            (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)),
            "Missing actionable UI element: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        // Review can dismiss the keyboard between separate live exists/frame queries.
        // Measure the keyboard and navigation bars from the same immutable tree.
        guard let snapshot = try? app.snapshot() else {
            XCTFail("Could not snapshot the app while measuring the content viewport")
            return .zero
        }
        let bounds = snapshot.frame
        var keyboardTop = bounds.maxY
        var barBottom = bounds.minY + 88
        var elements = [snapshot]
        while let element = elements.popLast() {
            let frame = element.frame
            if !frame.isEmpty && frame.intersects(bounds) {
                if element.elementType == .keyboard { keyboardTop = min(keyboardTop, frame.minY) }
                if element.elementType == .navigationBar { barBottom = max(barBottom, frame.maxY) }
            }
            elements.append(contentsOf: element.children)
        }
        let top = max(bounds.minY + 88, min(barBottom + 12, keyboardTop - 140))
        let bottom = min(bounds.maxY - 100, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool, distance: CGFloat? = nil) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = scrollableArea(), bounds = app.frame
        let travel = min(area.height * 0.6, max(20, distance ?? area.height * 0.6))
        let high = area.midY - travel / 2, low = area.midY + travel / 2
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertText(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists && target.isHittable, "Missing visible text: \(text)")
    }
    private func assertElementContains(_ id: String, _ text: String) {
        let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text), target.label)
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        tap(app.buttons[value])
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

#endif
