#if CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

final class SharedFallbackUITests: XCTestCase {
    private let app = XCUIApplication()
    private var capture = [String: Any]()
    private var target: String { ((capture["source"] as! [String: Any])["occurrenceId"] as! String).uppercased() }
    private var candidates: [[String: Any]] { capture["options"] as! [[String: Any]] }
    private func candidateID(_ index: Int) -> String { (candidates[index]["candidateId"] as! String).uppercased() }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SharedFallbackShop", withExtension: "json"))
        let bytes = try Data(contentsOf: file)
        capture = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        app.launchEnvironment["RITC_FALLBACK_SHOP"] = String(decoding: try JSONSerialization.data(withJSONObject: capture), as: UTF8.self)
    }

    private func launch(_ flags: String...) {
        app.launchArguments = ["--ui-testing","--shared-delivery-fixture","--shared-pantry-fixture","--shared-recovery-fixture",
                               "--shared-fallback-fixture","-AppleLanguages","(en)","-AppleLocale","en_US"] + flags
        app.launch()
        tap(app.buttons["sharedShop.deliveryEvidence"])
        tap(app.buttons["recovery.open"])
        tap(app.buttons["recovery.fallbackLibrary"])
    }

    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: 2), element.isHittable { return }
        for step in 0..<14 {
            if element.exists && element.isHittable { return }
            if element.exists && !element.frame.isEmpty {
                if element.frame.midY > app.frame.midY { app.swipeUp() } else { app.swipeDown() }
            } else if (step / 5).isMultiple(of: 2) { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not reveal \(element)\n\(app.debugDescription)",file:file,line:line)
    }
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(element,file:file,line:line); element.tap()
    }
    private func toggle(_ element: XCUIElement, to value: String = "1", file: StaticString = #filePath, line: UInt = #line) {
        reveal(element,file:file,line:line)
        element.coordinate(withNormalizedOffset: CGVector(dx:0.92,dy:0.5)).tap()
        XCTAssertEqual(element.value as? String,value,file:file,line:line)
    }
    private func enter(_ value: String, _ field: String, done: String) {
        let element = app.textFields[field]
        tap(element); element.typeText(value); tap(app.buttons[done])
    }
    private func back(_ title: String) { tap(app.navigationBars[title].buttons.firstMatch) }
    private func captureScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
    private func has(_ fragments: String...) -> XCUIElement {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: fragments.map { fragment in
            NSPredicate(format:"label CONTAINS %@ OR value CONTAINS %@",fragment,fragment)
        })
        return app.descendants(matching:.any).matching(predicate).firstMatch
    }

    func testExplicitRecipeReviewCanBeRefusedThenSavedOnceAfterLostReply() {
        launch("--fallback-drop-first-accept")
        tap(app.buttons["fallback.library"])
        tap(app.buttons["Review a scheduled meal or approved idea"])
        tap(app.buttons["fallback.meal." + target])
        reveal(app.staticTexts["Protected lunch"])
        reveal(has("Portions","2"))
        reveal(has("Portions","4"))
        tap(app.buttons["Cancel"])
        tap(app.buttons["fallback.disclose"])
        enter("Bean bowl for four","fallback.recipe.title",done:"fallback.recipe.done")
        enter("4","fallback.recipe.portions",done:"fallback.recipe.done")
        enter("Kidney beans","fallback.recipe.ingredient",done:"fallback.recipe.done")
        enter("4","fallback.recipe.quantity",done:"fallback.recipe.done")
        tap(app.buttons["fallback.recipe.review"])
        reveal(app.staticTexts["Bean bowl for four"])
        reveal(has("Kidney beans"))
        tap(app.buttons["fallback.accept"])
        XCTAssertTrue(app.staticTexts.matching(identifier: "Refresh the household recipe list and review the current record.").firstMatch.waitForExistence(timeout: 6))
        tap(app.buttons["Cancel"])
        captureScreen("Lost approval receipt and exact retry")
        tap(app.buttons["fallback.retry"])
        let entry = app.buttons["Bean bowl for four"]
        reveal(entry)
        XCTAssertEqual(app.buttons.matching(identifier:"Bean bowl for four").count,1)
        XCTAssertFalse(app.buttons["fallback.retry"].exists)
        tap(entry)
        reveal(has("Kidney beans"))
        app.terminate()
        verifyRetainedAccessAfterExpiry()
    }

    func testFiveUsableWrapsProtectLunchAndCompareUsualDinnerWithTwoPackTrip() {
        launch()
        tap(app.buttons["fallback.target." + target])
        let usual = candidateID(0), larger = candidateID(1)
        toggle(app.switches["fallback.select." + larger])
        tap(app.buttons["fallback.food." + larger])
        let stock = app.switches.matching(NSPredicate(format:"label CONTAINS %@ AND label CONTAINS %@","Wraps","5")).firstMatch
        toggle(stock)
        back("Review ingredients, food and time")
        tap(app.buttons["fallback.compare"])
        reveal(has("No reviewed recipe meets all requirements"))
        captureScreen("No fit leaves the original dinner open")
        XCTAssertFalse(app.buttons["fallback.choose." + larger].exists)
        reveal(has("Meal deadline","2098"))
        toggle(app.switches["fallback.trip.include"])
        enter("8","Round-trip minutes",done:"fallback.trip.done")
        enter("5","Whole-trip spending limit (USD)",done:"fallback.trip.done")
        enter("0.50","Extra charges and travel cost (USD)",done:"fallback.trip.done")
        tap(app.buttons["fallback.food." + larger])
        toggle(app.switches["Enter a reviewed pack offer"])
        enter("Two wraps","Pack name",done:"fallback.food.done")
        enter("2","Usable food per pack",done:"fallback.food.done")
        enter("2","Price per pack (USD)",done:"fallback.food.done")
        enter("2","Packs available",done:"fallback.food.done")
        back("Review ingredients, food and time")
        toggle(app.switches["fallback.select." + usual])
        tap(app.buttons["fallback.food." + usual]); toggle(stock); back("Review ingredients, food and time")
        tap(app.buttons["fallback.compare"])
        reveal(has("Usual accepted option (minutes)","10"))
        reveal(has("Minutes longer than usual","6"))
        reveal(has("Extra charges and travel cost (USD)","0.50"))
        reveal(has("Whole-trip extra cash","4.50"))
        reveal(has("Two wraps","Packs required 2","4.00"))
        captureScreen("Usual fallback and smallest two-pack trip")
        tap(app.buttons["fallback.choose." + larger])
        reveal(has("Food coverage","Still unresolved"))
        reveal(app.switches["recovery.agreeRepeat"])
        // The ranking remains behind the sheet. Check the facts in the foreground confirmation.
        for label in ["Whole-trip extra cash, $4.50", "Minutes longer than usual, 6"] {
            let rows = app.staticTexts.matching(NSPredicate(format: "label == %@", label))
            XCTAssertTrue(rows.allElementsBoundByIndex.contains(where: { $0.isHittable }), label)
        }
        captureScreen("Confirmed trip price and comparison alongside separate agreements")
        toggle(app.switches["recovery.agreeRepeat"])
        toggle(app.switches["recovery.agreeTrip"])
        toggle(app.switches["recovery.agreeUnresolved"])
        tap(app.buttons["recovery.reviewAgreements"])
        tap(app.buttons["recovery.apply"])
        tap(app.buttons["recovery.currentCoverage"])
        tap(app.buttons["recovery.cook." + target])
        let copy = app.staticTexts["delivery.cook.preview"]
        reveal(copy)
        captureScreen("Published dinner with protected lunch and remaining shortage")
        for fragment in ["Protected lunch","Dinner group","Warm before serving","Still needed: 3 units"] {
            XCTAssertTrue(copy.label.contains(fragment),copy.label)
        }
    }

    private func verifyRetainedAccessAfterExpiry() {
        launch("--expired-recovery-seat")
        XCTAssertFalse(app.buttons["fallback.target." + target].exists)
        tap(app.buttons["fallback.library"])
        XCTAssertFalse(app.buttons["fallback.disclose"].exists)
        let title = "Three warm wraps"
        tap(app.buttons.matching(NSPredicate(format:"label CONTAINS %@",title)).firstMatch)
        reveal(has("Warm before serving"))
        tap(app.buttons["fallback.withdraw"])
        let action = app.sheets.buttons.matching(identifier: "fallback.withdrawConfirm").firstMatch
        if action.waitForExistence(timeout: 2) { tap(action) }
        else {
            // UIKit may expose a system confirmation action under its visible label only.
            let system = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                "Withdraw household approval", "fallback.withdraw")).firstMatch
            tap(system)
        }
        let retained = app.buttons["Reviewed supper"]
        reveal(retained)
        captureScreen("Expired shopper retained the other recipe after withdrawal")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:"label CONTAINS %@",title)).firstMatch.exists)
    }
}

#endif
