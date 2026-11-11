#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class SharedDeliveryUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            capture.name = "Shared delivery failure"; capture.lifetime = .keepAlways; add(capture)
        }
        app.terminate()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testConfirmedOrderCancelAndLostReplyRecoverOnceAfterRestart() {
        exerciseConfirmedOrderRecovery(spanishLargestText: false)
    }

    func testSpanishLargestTextConfirmedOrderCancelAndLostReplyRecoverOnceAfterRestart() {
        exerciseConfirmedOrderRecovery(spanishLargestText: true)
    }

    private func exerciseConfirmedOrderRecovery(spanishLargestText: Bool) {
        let language = spanishLargestText ? "es" : "en"
        let done = spanishLargestText ? "Listo" : "Done"
        let cancel = spanishLargestText ? "Cancelar" : "Cancel"
        let packsLabel = spanishLargestText ? "Paquetes:" : "Packs:"
        func open(reset: Bool) {
            app.launchArguments = ["--ui-testing", "--shared-delivery-fixture", "--confirmed-order-fixture", "--confirmed-order-drop-reply", "-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_US"]
            if spanishLargestText {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            if reset { app.launchArguments.append("--reset-confirmed-order-fixture") }
            app.launch()
            tap(app.buttons["sharedShop.confirmedOrder"])
        }
        func row(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: prefix + ".66666666-6666-4666-8666-666666666666").firstMatch
        }
        func prepare() {
            tap(app.buttons["sharedOrder.amend"])
            tap(app.buttons[spanishLargestText ? "Editar Entered soup packs" : "Edit Entered soup packs"])
            let packs=app.textFields["sharedOrder.packs"]
            tap(packs); packs.typeText(XCUIKeyboardKey.delete.rawValue + "3")
            tap(app.buttons[done])
            tap(app.buttons["sharedOrder.keepLine"])
            let reference=app.textFields["sharedOrder.reference"]
            tap(reference); reference.typeText("Native market ABC-51")
            tap(app.buttons[done])
            if spanishLargestText {
                let date = app.datePickers["sharedOrder.date"]
                let time = app.datePickers["sharedOrder.time"]
                reveal(date); XCTAssertTrue(date.isEnabled)
                reveal(time); XCTAssertTrue(time.isEnabled)
                let capture = XCTAttachment(screenshot: app.screenshot())
                capture.name = "Shared-confirmation-date-Spanish-largest-text"
                capture.lifetime = .keepAlways; add(capture)
            }
            tap(app.buttons["sharedOrder.review"])
        }
        open(reset:true)
        reveal(row("sharedOrder.original"));XCTAssertTrue(row("sharedOrder.original").label.contains("\(packsLabel) 1"))
        prepare();tap(app.buttons[cancel])
        XCTAssertFalse(app.staticTexts["Native market ABC-51"].exists)
        XCTAssertFalse(row("sharedOrder.current").exists)
        prepare();tap(app.buttons["sharedOrder.confirm"])
        let retry=app.buttons[spanishLargestText ? "Reintentar la misma acción de compra compartida" : "Retry the same shared shop action"]
        XCTAssertTrue(retry.waitForExistence(timeout:10), "A lost reply must retain the original durable operation")
        app.terminate();open(reset:false)
        XCTAssertTrue(retry.waitForExistence(timeout:10))
        tap(retry)
        XCTAssertTrue(retry.waitForNonExistence(timeout:10))
        reveal(row("sharedOrder.original"));XCTAssertTrue(row("sharedOrder.original").label.contains("\(packsLabel) 1"))
        reveal(row("sharedOrder.current"));XCTAssertTrue(row("sharedOrder.current").label.contains("\(packsLabel) 3"))
        let reference=app.staticTexts["Native market ABC-51"]
        reveal(reference);XCTAssertEqual(app.staticTexts.matching(identifier: "Native market ABC-51").count,1)
        let capture=XCTAttachment(screenshot:app.screenshot());capture.name=spanishLargestText ? "Shared-confirmed-amendment-Spanish-largest-text" : "Shared-confirmed-amendment-after-lost-reply";capture.lifetime = .keepAlways;add(capture)
    }

    private func launch(_ language: String, locale: String, cookCopies: Bool = false, pantry: Bool = false, recovery: Bool = false, financial: Bool = false) {
        app.launchArguments = ["--ui-testing", "--shared-delivery-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if financial { app.launchArguments += ["--financial-closeout-fixture", "--expired-recovery-seat"] }
        if pantry || recovery { app.launchArguments.append("--shared-pantry-fixture") }
        if recovery { app.launchArguments.append("--shared-recovery-fixture") }
        if cookCopies { app.launchArguments.append("--shared-cook-copies-fixture") }
        app.launch()
        tap(app.buttons["sharedShop.deliveryEvidence"])
    }
    private func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if target.waitForExistence(timeout: 3), target.isHittable { return }
        for step in 0..<16 {
            let exists = target.exists
            if exists && target.isHittable { return }
            if exists && !target.frame.isEmpty {
                if target.frame.midY > app.frame.midY { app.swipeUp() } else { app.swipeDown() }
            } else if (step / 4).isMultiple(of: 2) { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(target.exists && target.isHittable, "Unable to reveal \(target)", file: file, line: line)
    }
    private func tap(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(target, file: file, line: line)
        target.tap()
    }
    private func assertFact(_ label: String, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS %@ AND (label CONTAINS %@ OR value CONTAINS %@)", label, value, value)).firstMatch
        reveal(row, file: file, line: line)
    }
    private func checkCookCopy(in title: String, fragments: [String], openShare: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) {
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "delivery.cook.")).firstMatch
        tap(link, file: file, line: line)
        let preview = app.staticTexts["delivery.cook.preview"]
        reveal(preview, file: file, line: line)
        let copy = preview.label
        for fragment in fragments {
            XCTAssertTrue(copy.contains(fragment), "Missing cook instruction: \(fragment)", file: file, line: line)
        }
        if openShare {
            tap(app.buttons["delivery.cook.share"], file: file, line: line)
            guard let close = readySystemShareClose(in: app, file: file, line: line) else { return }
            close.tap()
            reveal(preview, file: file, line: line)
            XCTAssertEqual(preview.label, copy, file: file, line: line)
        }
        tap(app.navigationBars[title].buttons.firstMatch, file: file, line: line)
    }
    private func enter(_ input: String, in field: XCUIElement) {
        tap(field)
        field.typeText(input)
    }
    private func hasUsable(_ text: String) -> Bool {
        let row = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "delivery.confirmed.", text, text)).firstMatch
        return row.waitForExistence(timeout: 8)
    }
    private func enterRecovery(_ text: String, field: String) {
        enter(text, in: app.textFields["recovery." + field])
        tap(app.buttons["recovery.finishEditing"])
    }

    func testShopperReviewsExactEditedCookWordingBeforeReadback() {
        app.launchEnvironment["RITC_COOK_READBACK_TRACE"] = "1"
        launch("en", locale: "en_US")
        tap(app.buttons["Delivered food by meal"])
        tap(app.buttons["delivery.cook.AAAAAAA1-AAAA-4AAA-8AAA-AAAAAAAAAAAA"])
        let preview = app.staticTexts["delivery.cook.preview"]
        let prepare = app.buttons["delivery.cook.prepareReadback"]
        let confirm = app.buttons["delivery.cook.confirmReadback"]
        let play = app.buttons["capture.readback.play"]
        let edit = app.buttons["Edit cook wording"]
        let field = app.textViews["Editable cook instruction"]
        let marker = "Warm the wraps."
        let addition = " Pack separately."

        tap(edit)
        tap(field)
        field.typeText(marker)
        tap(app.buttons["delivery.cook.finishEditing"])
        reveal(preview)
        let edited = preview.label
        XCTAssertTrue(edited.contains(marker))
        tap(prepare)
        reveal(confirm)
        XCTAssertFalse(play.exists)
        tap(app.buttons["delivery.cook.cancelReadback"])
        XCTAssertFalse(confirm.exists)
        XCTAssertFalse(play.exists)
        XCTAssertEqual(preview.label, edited)

        tap(prepare)
        tap(confirm)
        reveal(play)
        XCTAssertTrue(play.isEnabled)
        let stop = app.buttons["Stop readback"]
        XCTAssertFalse(stop.isEnabled, "Privacy confirmation alone must not start speech")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", edited)).firstMatch.exists)

        tap(play)
        let pause = app.buttons["Pause readback"]
        let unavailable = app.staticTexts["A local voice is unavailable. The complete instruction remains readable."]
        // The real audio session activates asynchronously after an explicit Play.
        let playbackReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pause.exists || unavailable.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playbackReady], timeout: 8), .completed,
                       "Expected playback controls or the readable local-voice fallback after Play")
        if pause.exists {
            tap(pause)
            tap(app.buttons["Resume readback"])
            tap(stop)
        } else {
            XCTAssertTrue(unavailable.exists)
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", edited)).firstMatch.exists)
        tap(edit)
        tap(field)
        field.typeText(addition)
        tap(app.buttons["delivery.cook.finishEditing"])
        reveal(preview)
        let revised = preview.label
        XCTAssertNotEqual(revised, edited)
        XCTAssertTrue(revised.contains(addition))
        tap(prepare)
        reveal(confirm)
        XCTAssertFalse(play.exists)
        tap(app.buttons["delivery.cook.cancelReadback"])
        XCTAssertEqual(preview.label, revised)
        XCTAssertFalse(play.exists)
    }

    func testShopperConfirmsCorrectsAndClearsTheLinkedFamilyPurchase() {
        app.launchArguments = ["--ui-testing", "--shared-delivery-fixture", "--request-purchase-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        tap(app.buttons["sharedShop.deliveryEvidence"])
        tap(app.buttons["delivery.requestPurchases"])
        let row = app.buttons["purchase.request.aaaaaaaa-1111-4111-8111-111111111111"]
        reveal(row)
        XCTAssertTrue(row.label.contains("Purchase unconfirmed"))
        XCTAssertFalse(app.buttons["purchase.request.bbbbbbbb-1111-4111-8111-111111111111"].exists)
        tap(row)
        let received = app.staticTexts["purchase.review.original"]
        reveal(received)
        XCTAssertEqual(received.label, "Wraps for lunches")
        assertFact("Requested by", "Sam")
        assertFact("Quantity", "four wraps")
        reveal(app.staticTexts["Ordered wraps"])
        assertFact("Whole packs", "2")
        tap(app.buttons["purchase.choice.bought"])
        tap(app.buttons["Cancel"])
        reveal(row)
        XCTAssertTrue(row.label.contains("Purchase unconfirmed"))
        for (choice, expected) in [("bought", "Shopper confirmed bought"),
                                   ("notBought", "Shopper confirmed not bought"), ("unknown", "Purchase unconfirmed")] {
            tap(row)
            tap(app.buttons["purchase.choice." + choice])
            tap(app.buttons["purchase.save"])
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", expected), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 8), .completed)
        }
    }

    func testShopperLeavesOriginalDinnerOpenAfterAnUnresolvedReplacementPreview() {
        launch("en", locale: "en_US", recovery: true)
        let wednesday = "EEEEEEEE-EEEE-4EEE-8EEE-000000000002"
        tap(app.buttons["recovery.open"])
        tap(app.buttons["recovery.meal." + wednesday])
        enterRecovery("Rice alternative", field: "title")
        enterRecovery("Rice", field: "ingredient")
        enterRecovery("4", field: "quantity")
        tap(app.buttons["recovery.preview"])
        assertFact("Food coverage", "Still unresolved")
        tap(app.buttons["recovery.keepCurrent"])
        tap(app.buttons["recovery.currentCoverage"])
        tap(app.buttons["recovery.cook." + wednesday])
        let original = app.staticTexts["delivery.cook.preview"]
        reveal(original)
        for fact in ["Wednesday dinner", "Wednesday beans", "Dinner plates", "Still needed: 4 units", "No sesame", "America/New_York (UTC−05:00)"] {
            XCTAssertTrue(original.label.contains(fact), original.label)
        }
        XCTAssertFalse(original.label.contains("Rice alternative"))
    }

    func testShopperReplacesWednesdayAfterPickupAndKeepsTuesdaysShortage() {
        launch("en", locale: "en_US", cookCopies: true, recovery: true)
        let tuesday = "EEEEEEEE-EEEE-4EEE-8EEE-000000000001"
        let wednesday = "EEEEEEEE-EEEE-4EEE-8EEE-000000000002"
        func enable(_ identifier: String) {
            let control = app.switches[identifier]
            reveal(control)
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(control.value as? String, "1")
        }
        tap(app.buttons["recovery.open"])
        tap(app.buttons["recovery.meal." + wednesday])
        enterRecovery("Wednesday rice", field: "title")
        enterRecovery("Cooked rice", field: "ingredient")
        enterRecovery("4", field: "quantity")
        enable("recovery.extraTrip")
        tap(app.buttons["recovery.preview"])
        reveal(app.staticTexts["Tuesday tortillas · Protected lunch"])
        assertFact("Still needed", "2 units")
        reveal(app.staticTexts["Cooked rice · Dinner plates"])
        assertFact("Still needed", "4 units")
        let review = app.buttons["recovery.reviewAgreements"]
        reveal(review)
        XCTAssertFalse(review.isEnabled)
        enable("recovery.agreeTrip")
        XCTAssertFalse(review.isEnabled)
        enable("recovery.agreeUnresolved")
        tap(review)
        tap(app.buttons["recovery.apply"])
        reveal(app.staticTexts["recovery.saved"])
        tap(app.buttons["recovery.currentCoverage"])
        tap(app.buttons["recovery.cook." + wednesday])
        let copy = app.staticTexts["delivery.cook.preview"]
        reveal(copy)
        for fact in ["Wednesday rice", "Cooked rice", "Dinner plates", "Still needed: 4 units", "No sesame", "America/New_York (UTC−05:00)"] {
            XCTAssertTrue(copy.label.contains(fact), copy.label)
        }
        XCTAssertFalse(copy.label.contains("Wednesday beans"))
        XCTAssertFalse(copy.label.contains("Tuesday tortillas"))
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recipient language")).firstMatch)
        tap(app.buttons["Español (EE. UU.)"])
        reveal(copy)
        XCTAssertTrue(copy.label.contains("Aún falta: 4 unidades"), copy.label)
        XCTAssertTrue(copy.label.contains("America/New_York (UTC−05:00)"), copy.label)
        let revisedSpanish = copy.label
        tap(app.buttons["delivery.cook.save"])
        reveal(app.staticTexts["Dated copy saved"])
        tap(app.buttons["delivery.cook.history"])
        tap(app.buttons["delivery.cook.saved.1"])
        let saved = app.staticTexts["delivery.cook.savedText"]
        reveal(saved)
        XCTAssertEqual(saved.label, revisedSpanish)
        tap(app.navigationBars["Dated copy"].buttons.firstMatch)
        tap(app.navigationBars["Saved cook notes"].buttons.firstMatch)
        tap(app.navigationBars["Tell the cook"].buttons.firstMatch)
        tap(app.buttons["recovery.cook." + tuesday])
        reveal(copy)
        XCTAssertTrue(copy.label.contains("Tuesday tortillas"), copy.label)
        XCTAssertTrue(copy.label.contains("Protected lunch"), copy.label)
        XCTAssertTrue(copy.label.contains("Still needed: 2 units") || copy.label.contains("Aún falta: 2 unidades"), copy.label)
        XCTAssertFalse(copy.label.contains("Cooked rice"))
        XCTAssertTrue(copy.label.contains("America/Los_Angeles (UTC−08:00)"), copy.label)
        let unchangedLunch = copy.label
        tap(app.buttons["delivery.cook.save"])
        reveal(app.staticTexts["Dated copy saved"])
        tap(app.buttons["delivery.cook.history"])
        tap(app.buttons["delivery.cook.saved.1"])
        reveal(saved)
        XCTAssertEqual(saved.label, unchangedLunch)
    }

    func testShopperReviewsFreezerBatchCoverageBeforeCorrectingFiveToThree() {
        launch("en", locale: "en_US", pantry: true)
        let lunch = "AAAAAAA1-AAAA-4AAA-8AAA-AAAAAAAAAAAA", dinner = "BBBBBBB1-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let lunchIngredient = "AAAAAAA2-AAAA-4AAA-8AAA-AAAAAAAAAAAA", dinnerIngredient = "BBBBBBB2-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let lunchGroup = "AAAAAAA3-AAAA-4AAA-8AAA-AAAAAAAAAAAA", dinnerGroup = "BBBBBBB3-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let name = "Freezer tortillas"
        let observe = app.buttons["pantry.observe"], preview = app.buttons["pantry.preview"]
        let confirm = app.buttons["pantry.confirmObservation"]
        let batch = app.buttons.matching(NSPredicate(format:"label CONTAINS %@",name)).firstMatch
        func back(from title: String) { tap(app.navigationBars[title].buttons.firstMatch) }
        func enterObservation(_ number: String) {
            tap(observe)
            let field = app.textFields["pantry.amount"]
            tap(field)
            if let value = field.value as? String, value == "5" {
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            field.typeText(number)
            tap(preview)
        }
        func assertFields(_ identifier: String, _ fields: [(String,String)], line: UInt = #line) {
            let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            reveal(row, line: line)
            for (label, value) in fields {
                let text = "(?s).*" + NSRegularExpression.escapedPattern(for: label) + "[\\s,:]+"
                    + NSRegularExpression.escapedPattern(for: value) + "(?:$|[^\\p{L}\\p{N}].*)"
                let predicate = NSPredicate(format: "(label CONTAINS %@ AND value == %@) OR label MATCHES %@", label, value, text)
                let fact = row.descendants(matching: .any).matching(predicate).firstMatch
                XCTAssertTrue(fact.exists, "Missing \(label) \(value) in \(identifier)", line: line)
            }
        }
        func checkCoverage(dinnerCovered: String, dinnerMissing: String, checkCook: Bool = false) {
            tap(app.buttons["pantry.coverage"])
            assertFields("pantry.coverage.need." + lunch + ".0", [
                ("Covered by freezer stock","2 units"), ("Still needed","0 units"),
                ("Amount set aside","2 units"), ("Still backed by this source","2 units")
            ])
            assertFields("pantry.coverage.need." + dinner + ".0", [
                ("Covered by deliveries","0 units"), ("Covered by pantry stock","0 units"),
                ("Covered by freezer stock",dinnerCovered), ("Still needed",dinnerMissing)
            ])
            if checkCook {
                tap(app.buttons["pantry.coverage.cook." + dinner])
                let copy = app.staticTexts["delivery.cook.preview"]
                reveal(copy)
                for fragment in [name, "Dinner wraps", "Covered by freezer stock: 1 unit", "Still needed: 3 units"] {
                    XCTAssertTrue(copy.label.contains(fragment), copy.label)
                }
                tap(app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "Recipient language")).firstMatch)
                tap(app.buttons["Español (EE. UU.)"])
                reveal(copy)
                for fragment in [name, "Dinner wraps", "Cubierto por el congelador: 1 unidad", "Aún falta: 3 unidades"] {
                    XCTAssertTrue(copy.label.contains(fragment), copy.label)
                }
                back(from: "Tell the cook")
            }
            back(from: "Food coverage by meal")
        }

        tap(app.buttons["delivery.openPantry"])
        tap(app.buttons["pantry.create"])
        enter(name, in: app.textFields["pantry.name"])
        tap(app.buttons["pantry.location"])
        tap(app.buttons["Freezer"])
        tap(app.buttons["pantry.saveBatch"])
        tap(batch)
        tap(app.buttons["pantry.select"])
        reveal(app.buttons["pantry.matches"])
        XCTAssertEqual(app.buttons["pantry.select"].label, "Remove from this shop")
        enterObservation("5")
        tap(confirm)

        tap(app.buttons["pantry.matches"])
        tap(app.buttons["pantry.ingredient." + lunch + "." + lunchIngredient])
        tap(app.buttons["pantry.match"])
        reveal(app.buttons["pantry.group." + lunchGroup])
        back(from: "Tortillas")
        tap(app.buttons["pantry.ingredient." + dinner + "." + dinnerIngredient])
        tap(app.buttons["pantry.match"])
        reveal(app.buttons["pantry.group." + dinnerGroup])
        back(from: "Tortillas")
        tap(app.buttons["pantry.ingredient." + lunch + "." + lunchIngredient])
        tap(app.buttons["pantry.group." + lunchGroup])
        enter("2", in: app.textFields["pantry.reserveAmount"])
        tap(app.buttons["pantry.saveReservation"])
        back(from: "Tortillas")
        back(from: "Meal ingredient matches")
        back(from: name)
        checkCoverage(dinnerCovered: "3 units", dinnerMissing: "1 unit")

        tap(batch)
        enterObservation("3")
        let lunchImpact = ["pantry.impact", lunch, lunchIngredient, lunchGroup].joined(separator: ".")
        let dinnerImpact = ["pantry.impact", dinner, dinnerIngredient, dinnerGroup].joined(separator: ".")
        assertFields(lunchImpact, [("Covered before","2 units"),("Covered after","2 units"),("Missing after","0 units")])
        assertFields(dinnerImpact, [("Covered before","3 units"),("Covered after","1 unit"),
                                    ("Missing before","1 unit"),("Missing after","3 units")])
        tap(app.buttons["Cancel"])
        back(from: name)
        checkCoverage(dinnerCovered: "3 units", dinnerMissing: "1 unit")

        tap(batch)
        enterObservation("3")
        assertFields(dinnerImpact, [("Covered after","1 unit"),("Missing after","3 units")])
        tap(confirm)
        back(from: name)
        checkCoverage(dinnerCovered: "1 unit", dinnerMissing: "3 units", checkCook: true)
    }

    func testShopperSavesDatedCookCopyAndReopensRecipientSendRecord() {
        app.launchEnvironment["S24_COOK_DESTINATION_TRACE_SCOPE"] = "SharedDeliveryUITests/testShopperSavesDatedCookCopyAndReopensRecipientSendRecord"
        launch("en", locale: "en_US", cookCopies: true)
        tap(app.buttons["Delivered food by meal"])
        let occurrence = "AAAAAAA1-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        tap(app.buttons["delivery.cook." + occurrence])
        let preview = app.staticTexts["delivery.cook.preview"]
        reveal(preview)
        let reviewed = preview.label
        for fact in ["Lunch wraps", "School lunch", "Uncovered by deliveries: 2 units", "Beans soaked"] {
            XCTAssertTrue(reviewed.contains(fact), "Missing no-delivery meal fact: \(fact)")
        }
        tap(app.buttons["delivery.cook.save"])
        reveal(app.staticTexts["Dated copy saved"])

        let savedText = app.staticTexts["delivery.cook.savedText"]
        func openSavedCopy() {
            let history = app.buttons["delivery.cook.history"]
            reveal(history)
            if history.frame.midY > app.frame.maxY - 64 { app.swipeUp() }
            let center = CGPoint(x: history.frame.midX, y: history.frame.midY)
            XCTAssertTrue(history.isHittable && app.frame.insetBy(dx: 0, dy: 12).contains(center))
            history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.navigationBars["Saved cook notes"].waitForExistence(timeout: 5))
            capture("Shared saved cook history")
            tap(app.buttons["delivery.cook.saved.1"])
            reveal(savedText)
            XCTAssertEqual(savedText.label, reviewed)
            capture("Shared dated cook copy")
        }
        openSavedCopy()
        tap(app.buttons["delivery.cook.savedShare"])
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "header.closeButton", "Close")).firstMatch
        func dismissReviewedShare() -> Bool {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
            guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
                XCTFail("The system share Close control did not become ready")
                return false
            }
            close.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
            guard XCTWaiter.wait(for: [dismissed], timeout: 15) == .completed else {
                let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screen.name = "Shared cook share did not dismiss after Close"; screen.lifetime = .keepAlways; add(screen)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Shared cook post-Close hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
                XCTFail("The system share sheet remained after its Close tap")
                return false
            }
            return true
        }
        guard dismissReviewedShare() else { return }

        let recipient = app.textFields["delivery.cook.recipient"]
        let check = app.buttons["delivery.cook.checkRecipient"], mark = app.buttons["delivery.cook.markSent"]
        let last = app.descendants(matching: .any).matching(identifier: "delivery.cook.lastSent").firstMatch
        func assertFirstVersionSent() {
            reveal(last)
            let text = [last.label, last.value as? String ?? ""].joined(separator: " ")
            XCTAssertNotNil(text.range(of: #"\b1\b"#, options: .regularExpression), text)
            XCTAssertFalse(mark.exists)
        }
        enter("Fixture cook", in: recipient)
        recipient.typeText("\n")
        tap(check)
        reveal(app.staticTexts["No previous send recorded for this recipient."])
        XCTAssertFalse(last.exists)
        tap(mark)
        assertFirstVersionSent()

        tap(app.navigationBars["Dated copy"].buttons.firstMatch)
        tap(app.navigationBars["Saved cook notes"].buttons.firstMatch)
        openSavedCopy()
        enter("Fixture cook", in: recipient)
        recipient.typeText("\n")
        tap(check)
        assertFirstVersionSent()
        let reviewCorrection = app.buttons["delivery.cook.reviewCorrection"]
        tap(reviewCorrection)
        let manual = app.descendants(matching: .any).matching(identifier: "delivery.cook.fullCorrection").firstMatch
        reveal(manual)
        XCTAssertTrue(manual.elementType == .textField || manual.elementType == .textView)
        XCTAssertEqual(manual.value as? String, reviewed)
        capture("Shared full correction editor")
        let shareCorrection = app.buttons["delivery.cook.shareCorrection"]
        for _ in 0..<4 where !shareCorrection.exists { app.swipeUp() }
        XCTAssertTrue(shareCorrection.exists)
        XCTAssertFalse(shareCorrection.isEnabled)
        let confirmation = app.switches["delivery.cook.confirmDestination"]
        reveal(confirmation)
        let control = confirmation.switches.firstMatch
        XCTAssertTrue(control.exists && control.isHittable)
        control.tap()
        XCTAssertEqual(confirmation.value as? String, "1")
        tap(reviewCorrection)
        let correction = app.staticTexts["delivery.cook.correctionText"]
        reveal(correction)
        XCTAssertTrue(correction.label.contains("Add\n\nNone"))
        XCTAssertTrue(correction.label.contains("Remove\n\nNone"))
        XCTAssertTrue(correction.label.contains("Still to confirm"))
        XCTAssertTrue(correction.label.contains("Uncovered by deliveries: 2 units"))
        XCTAssertFalse(mark.exists)
        tap(shareCorrection)
        guard dismissReviewedShare() else { return }
        tap(check)
        assertFirstVersionSent()
    }
    func testShopperRecordsAndCorrectsDeliveryThenReopensIt() {
        launch("en", locale: "en_US")
        let save = app.buttons["Save to shared shop"]
        tap(app.buttons["Add a delivery"])
        tap(app.buttons["Ordered wraps"])
        enter("Kitchen wraps", in: app.textFields["Food that came home"])
        tap(save)
        tap(app.buttons["Record arrival"])
        app.switches["Arrival time known"].coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.5)).tap()
        enter("8", in: app.textFields["delivery.amount"])
        tap(save)
        tap(app.buttons["Record usable quantity"])
        enter("6", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("6 units"))
        tap(app.buttons["Record usable quantity"])
        enter(XCUIKeyboardKey.delete.rawValue + "7", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("7 units"))
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["sharedShop.deliveryEvidence"])
        XCTAssertTrue(hasUsable("7 units"))
        XCTAssertEqual(app.buttons.matching(identifier: "Record arrival").count, 1)
        let openMatches = app.buttons["Meal ingredient matches"], ingredient = app.buttons.containing(.staticText, identifier: "Tortillas").firstMatch
        tap(openMatches)
        tap(ingredient)
        let exclusions = app.descendants(matching: .any).matching(NSPredicate(format:
            "(label CONTAINS %@ OR value CONTAINS %@)", "sesame", "sesame")).firstMatch
        XCTAssertTrue(exclusions.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "School lunch")).firstMatch.exists)
        tap(app.buttons["Match this ingredient"])
        tap(app.buttons["Delivered food by meal"])
        let covered = app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "Covered by deliveries", "2 units", "2 units")).firstMatch
        XCTAssertTrue(covered.waitForExistence(timeout: 8))
        let missing = app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "Uncovered by deliveries", "0 units", "0 units")).firstMatch
        XCTAssertTrue(missing.exists)
        tap(app.buttons["Done"])
        let reviewReservation = app.buttons["Review amount to set aside for School lunch"]
        tap(openMatches)
        tap(ingredient)
        tap(reviewReservation)
        enter("2", in: app.textFields["delivery.reservation.amount"])
        tap(app.buttons["Save amount set aside"])
        tap(app.buttons["Record usable quantity"])
        enter(XCUIKeyboardKey.delete.rawValue + "1", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("1 unit"))
        tap(app.buttons["Delivered food by meal"])
        assertFact("Amount set aside", "2 units")
        assertFact("Still backed by this delivery", "1 unit")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Set-aside lunch after a delivery correction"; evidence.lifetime = .keepAlways; add(evidence)
        checkCookCopy(in: "Tell the cook", fragments: ["Lunch wraps", "School lunch", "peanuts", "sesame", "Beans soaked", "Kitchen wraps",
                       "Amount set aside: 2 units", "Still backed by this delivery: 1 unit"], openShare: true)
        tap(app.buttons["Done"])
        tap(openMatches)
        tap(ingredient)
        reveal(app.buttons["Remove ingredient match"])
        XCTAssertFalse(app.buttons["Remove ingredient match"].isEnabled)
        tap(reviewReservation)
        tap(app.buttons["Release this reservation"])
        tap(app.buttons["Release amount set aside"])
        tap(openMatches)
        tap(ingredient)
        tap(app.buttons["Remove ingredient match"])
        tap(openMatches)
        tap(ingredient)
        reveal(app.buttons["Match this ingredient"])
    }
    func testShopperClosesWithPendingCreditThenLinksItToTheOriginalNetCharge() {
        launch("en", locale: "en_US", financial: true)
        tap(app.buttons["delivery.financial"])
        func record(_ kind: String?, amount: String, evidence: String, settled: Bool = false) {
            tap(app.buttons["financial.add"])
            if let kind {
                tap(app.buttons["financial.kind"]); tap(app.buttons[kind])
                tap(app.buttons["financial.link"]); tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Net receipt · $37.20")).firstMatch)
                if settled {
                    tap(app.buttons["financial.credit"]); tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Promised refund · $2.40")).firstMatch)
                }
            }
            enter(amount, in: app.textFields["financial.amount"])
            tap(app.buttons["financial.doneTyping"])
            enter(evidence, in: app.textFields["financial.evidence"])
            if app.buttons["financial.doneTyping"].isHittable { app.buttons["financial.doneTyping"].tap() }
            tap(app.buttons["financial.save"])
        }
        record(nil, amount: "37.20", evidence: "Net receipt")
        // Server saved the evidence but the first response was lost. Re-enter from the shop.
        XCTAssertTrue(app.buttons["financial.retry"].waitForExistence(timeout: 8))
        tap(app.navigationBars["Shared financial evidence"].buttons.firstMatch)
        tap(app.buttons["delivery.financial"])
        tap(app.buttons["financial.retry"])
        assertFact("Paid so far", "$37.20")
        record("Pending credit", amount: "2.40", evidence: "Promised refund")
        assertFact("Paid so far", "$37.20"); assertFact("Pending credits", "$2.40")
        tap(app.buttons["financial.close"])
        let closeAction = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
            "Close this pickup", "financial.close")).firstMatch
        tap(closeAction)
        XCTAssertTrue(app.staticTexts["Closed"].waitForExistence(timeout: 6))
        assertFact("Pending credits", "$2.40")
        record("Credit already included in net charge", amount: "2.40", evidence: "Included on statement", settled: true)
        assertFact("Paid so far", "$37.20"); assertFact("Pending credits", "$0.00")
        assertFact("Credits already included in charges", "$2.40")
        tap(app.navigationBars["Shared financial evidence"].buttons.firstMatch)
        tap(app.buttons["Refresh deliveries"])
        tap(app.buttons["Delivered food by meal"])
        assertFact("Uncovered by deliveries", "2 units")
        tap(app.buttons["Done"])
        let addDelivery = app.buttons["Add a delivery"]
        XCTAssertTrue(addDelivery.waitForExistence(timeout: 5), "Closing with unresolved food must preserve later physical correction")
        tap(addDelivery)
        tap(app.buttons["Ordered wraps"])
        enter("Late kitchen wraps", in: app.textFields["Food that came home"])
        let save = app.buttons["Save to shared shop"]
        tap(save)
        tap(app.buttons["Record arrival"])
        app.switches["Arrival time known"].coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.5)).tap()
        enter("8", in: app.textFields["delivery.amount"])
        tap(save)
        tap(app.buttons["Record usable quantity"])
        enter("1", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("1 unit"))
        let matches = app.buttons["Meal ingredient matches"]
        let ingredient = app.buttons.containing(.staticText, identifier: "Tortillas").firstMatch
        tap(matches); tap(ingredient); tap(app.buttons["Match this ingredient"])
        tap(app.buttons["Delivered food by meal"])
        assertFact("Covered by deliveries", "1 unit")
        assertFact("Uncovered by deliveries", "1 unit")
        tap(app.buttons["Done"])
        tap(app.buttons["Record usable quantity"])
        enter(XCUIKeyboardKey.delete.rawValue + "2", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("2 units"))
        let reserve = app.buttons["Review amount to set aside for School lunch"]
        tap(matches); tap(ingredient); tap(reserve)
        enter("2", in: app.textFields["delivery.reservation.amount"])
        tap(app.buttons["Save amount set aside"])
        tap(matches); tap(ingredient); tap(reserve)
        enter(XCUIKeyboardKey.delete.rawValue + "1", in: app.textFields["delivery.reservation.amount"])
        tap(app.buttons["Save amount set aside"])
        tap(app.buttons["Delivered food by meal"])
        assertFact("Uncovered by deliveries", "0 units")
        assertFact("Amount set aside", "1 unit")
        assertFact("Still backed by this delivery", "1 unit")
        tap(app.buttons["Done"])
        tap(app.buttons["delivery.financial"])
        XCTAssertTrue(app.staticTexts["Closed"].waitForExistence(timeout: 6))
        assertFact("Paid so far", "$37.20")
        assertFact("Pending credits", "$0.00")
        assertFact("Credits already included in charges", "$2.40")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Closed-pickup-after-late-delivery-correction"
        capture.lifetime = .keepAlways; add(capture)
    }

    func testSpanishShopperDistinguishesFractionalUsableFoodZeroAndUnknown() {
        launch("es", locale: "es_US")
        tap(app.buttons["Alimentos entregados por comida"])
        for (label, value) in [("Exclusiones de la comida", "peanuts"), ("Tiempo de preparación en minutos", "120"),
                               ("Pasos de preparación completados", "Beans soaked")] {
            assertFact(label, value)
        }
        reveal(app.staticTexts["Ninguna entrega está vinculada a este ingrediente."])
        tap(app.buttons["Listo"])
        let save = app.buttons["Guardar en la compra compartida"], record = app.buttons["Registrar cantidad utilizable"]
        let amount = app.textFields["delivery.amount"]
        tap(app.buttons["Agregar una entrega"])
        tap(app.buttons["Ordered wraps"])
        enter("Tortillas de maíz", in: app.textFields["Alimento que llegó"])
        tap(save)
        tap(app.buttons["Registrar llegada"])
        app.switches["Se conoce la hora de llegada"].coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.5)).tap()
        enter("1,5", in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("Cantidad sin resolver"))
        tap(record)
        enter("0,5", in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("1/2 unidades"))
        let matches = app.buttons["Correspondencias con ingredientes de las comidas"]
        let ingredient = app.buttons.containing(.staticText, identifier: "Tortillas").firstMatch
        tap(matches); tap(ingredient); tap(app.buttons["Vincular este ingrediente"])
        tap(matches); tap(ingredient)
        tap(app.buttons["Revisar cuánto apartar para School lunch"])
        enter("0,25", in: app.textFields["delivery.reservation.amount"])
        tap(app.buttons["Guardar cantidad apartada"])
        tap(record)
        enter(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "0", in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("0 unidades"))
        tap(app.buttons["Alimentos entregados por comida"])
        assertFact("Cantidad apartada", "1/4 unidades")
        assertFact("Cantidad que aún cubre esta entrega", "0 unidades")
        checkCookCopy(in: "Avisar a quien cocina", fragments: ["Lunch wraps", "School lunch", "Tortillas de maíz", "Cantidad apartada: 1/4 unidades",
                       "Cantidad que aún cubre esta entrega: 0 unidades", "peanuts", "sesame"])
        tap(app.buttons["Listo"])
        tap(record)
        enter(XCUIKeyboardKey.delete.rawValue, in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("Cantidad sin resolver"))
    }
}
#endif
