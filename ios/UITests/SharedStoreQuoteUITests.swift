#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Real fields, normal household entry, review, persistence, and shopper controls against a guarded
/// contract fixture. The companion Swift/PostgreSQL wire suite verifies the service transaction.
@MainActor final class SharedStoreQuoteUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workspace = UUID().uuidString
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier:"dev.roominthecart.app.debug")
        app.launchArguments = ["--ui-testing","--shared-store-quotes-fixture","-AppleLanguages","(en)","-AppleLocale","en_US","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryL"]
        app.launchEnvironment["RITC_QUOTES_FIXTURE_WORKSPACE"] = workspace
        app.launchEnvironment["RITC_QUOTES_FIXTURE_RESET"] = "1"
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("S27-screen-failure") }; app.terminate()
    }
    func testKnownTripUnknownBreakEvenPrivateProposalAndExplicitShopperAdoption() {
        openAdult()
        enterKnownQuotes()
        tap(element("sharedQuotes.reviewSave"))
        assertLabel("sharedQuotes.firstFacts",contains:"$38.00")
        assertLabel("sharedQuotes.secondFacts",contains:"$39.00")
        assertLabel("sharedQuotes.cashDelta",contains:"$1.00")
        capture("S27-known-checkout-trip-and-time-review")
        tap(app.buttons["Cancel"])
        counter("saves",0); counter("proposals",0); counter("adoptions",0)
        tap(element("sharedQuotes.reviewSave")); confirm()
        counter("saves",1); counter("proposals",0); counter("adoptions",0)

        tap(element("sharedQuotes.enter"))
        fill("East unknown",into:"sharedQuotes.first.label",replacing:true)
        fill("West unknown",into:"sharedQuotes.second.label",replacing:true)
        fill("",into:"sharedQuotes.second.tripCash",replacing:true)
        tap(element("sharedQuotes.reviewSave"))
        assertLabel("sharedQuotes.breakEven",contains:"$3.00")
        capture("S27-unknown-trip-three-dollar-break-even")
        confirm(); counter("saves",2); counter("proposals",0)

        tap(app.buttons["East / West"])
        tap(element("sharedQuotes.select.second"))
        counter("adoptions",0)
        confirm(); counter("proposals",1); counter("adoptions",0)
        capture("S27-private-save-separated-from-explicit-proposal")

        tap(element("fixture.s27.switch"))
        openComparison()
        XCTAssertFalse(app.buttons["East unknown / West unknown"].exists,"The shopper must not see another adult's unproposed private quote")
        tap(app.buttons["East / West"])
        tap(element("sharedQuotes.reviewProposal"))
        let apply = element("sharedQuotes.confirm"); reveal(apply)
        XCTAssertFalse(apply.isEnabled,"Shopper must acknowledge exact adoption")
        counter("adoptions",0)
        capture("S27-assigned-shopper-explicit-adoption-review")
        confirm(); counter("adoptions",1)
        assertText("Prices from the former store are invalid")
        assertText("Earlier revision or shopper assignment")
        capture("S27-adopted-draft-requires-fresh-checkout-prices")
        fixture("Freeze shared shop")
        tap(element("sharedQuotes.refresh"))
        assertText("Saved proof is read-only")
        XCTAssertFalse(element("sharedQuotes.enter").exists)
        counter("adoptions",1)
        capture("S27-frozen-proof-cannot-adopt")
    }
    func testLostReplyRelaunchRestoresExactRetryWithoutDuplicatingPrivateSave() {
        openAdult(); fixture("Lose next save reply")
        enterKnownQuotes(); tap(element("sharedQuotes.reviewSave")); confirm()
        counter("saves",1); counter("posts",1)
        XCTAssertTrue(element("sharedQuotes.retry").waitForExistence(timeout:10))
        capture("S27-lost-reply-preserves-exact-retry")
        app.terminate(); app.launchEnvironment["RITC_QUOTES_FIXTURE_RESET"] = "0"; app.launch()
        openComparison()
        XCTAssertTrue(element("sharedQuotes.retry").waitForExistence(timeout:20))
        tap(element("sharedQuotes.retry"))
        counter("saves",1); counter("posts",2)
        XCTAssertFalse(element("sharedQuotes.retry").exists)
        capture("S27-relaunched-exact-retry-applies-once")
    }
    func testStaleReviewedSaveCannotBeRebasedAndLockedShopHasNoNewComparisonAction() {
        openAdult(); enterKnownQuotes(); tap(element("sharedQuotes.reviewSave"))
        fixture("Advance shared revision"); confirm()
        counter("saves",0); counter("adoptions",0)
        assertText("Changed revisions need a new review")
        capture("S27-stale-action-preserved-without-rebase")
        XCTAssertTrue(element("sharedQuotes.retry").exists)
        tap(app.buttons["Refresh and clear local retry"])
        // The first tap opens a confirmation dialog. Resolve its action in
        // that current state, without scrolling or retaining an indexed match.
        let dialog = app.sheets.containing(.staticText,identifier:"Clear local retry?").firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout:8),app.debugDescription)
        XCTAssertTrue(dialog.staticTexts["Clearing cannot undo a comparison, proposal, grant, or store adoption already received. Review the refreshed household result."].exists)
        let clearRetry = dialog.buttons["Refresh and clear local retry"]
        XCTAssertTrue(clearRetry.exists && clearRetry.isHittable)
        capture("S27-confirm-exact-local-retry-clear")
        clearRetry.tap()
        let cleared = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == true AND label == %@","Local retry cleared after refreshing. A change already received by the household is preserved."),object:element("sharedQuotes.notice"))
        XCTAssertEqual(XCTWaiter.wait(for:[cleared],timeout:12),.completed)
        XCTAssertFalse(element("sharedQuotes.retry").exists)
        XCTAssertFalse(app.buttons["Refresh and clear local retry"].exists)
        XCTAssertTrue(element("sharedQuotes.enter").waitForExistence(timeout:8))
        XCTAssertTrue(element("sharedQuotes.enter").isEnabled)
        counter("saves",0); counter("proposals",0); counter("adoptions",0)
        capture("S27-local-retry-cleared-without-shared-write")
        fixture("Freeze shared shop"); tap(element("sharedQuotes.refresh"))
        assertText("Saved proof is read-only")
        XCTAssertFalse(element("sharedQuotes.enter").exists)
        counter("saves",0)
        counter("proposals",0); counter("adoptions",0)
        // Freeze republishes the fixture counters, including the rejected
        // stale POST. Clearing the retry must not send another command.
        counter("posts",1)
    }
    func testSpanishLargestTextKeepsRealQuoteEntryDiscoverable() {
        app.launchArguments = ["--ui-testing","--shared-store-quotes-fixture","-AppleLanguages","(es)","-AppleLocale","es_US","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        openAdult(); tap(element("sharedQuotes.enter"))
        fill("Tienda del barrio",into:"sharedQuotes.first.label",requireDone:true)
        fill("Sucursal del barrio",into:"sharedQuotes.first.branch",requireDone:true)
        reveal(element("sharedQuotes.first.source"))
        XCTAssertTrue(element("sharedQuotes.first.source").exists)
        capture("S27-spanish-largest-text-native-fields")
        counter("saves",0); counter("proposals",0); counter("adoptions",0)
    }
    func testFilledFinancialFieldsRetainVisibleMeaningAndGrantActionNamesAdult() {
        openAdult(); tap(element("sharedQuotes.enter"))
        inputMeaning("38.00", id:"sharedQuotes.first.itemSubtotal", title:"Items before fees and discounts in USD, optional")
        inputMeaning("38.00", id:"sharedQuotes.first.total", title:"Whole checkout total in USD, optional")
        capture("S27-filled-subtotal-checkout-persistent-labels")
        inputMeaning("4.00", id:"sharedQuotes.first.tripCash", title:"Incremental trip cash in USD, optional")
        inputMeaning("18", id:"sharedQuotes.first.extraMinutes", title:"Extra minutes, optional")
        inputMeaning("40.00", id:"sharedQuotes.first.cap", title:"Applicable cap in USD, optional")
        capture("S27-filled-trip-time-cap-persistent-labels")
        counter("saves",0); counter("proposals",0); counter("adoptions",0)
        tap(element("fixture.s27.switch")); openComparison()
        let named = element("sharedQuotes.grant.33333333-3333-4333-8333-333333333333")
        reveal(named)
        XCTAssertEqual(named.label,"Review revoking budget access from Second adult")
        capture("S27-named-adult-budget-grant-accessibility-label")
    }
    private func inputMeaning(_ value: String, id: String, title: String) {
        fill(value,into:id,requireDone:true)
        let label = app.staticTexts.matching(identifier:title).firstMatch
        reveal(label)
        XCTAssertTrue(label.isHittable,title)
        XCTAssertEqual(app.textFields.matching(identifier:id).firstMatch.value as? String,value)
    }
    private func openAdult() { app.launch(); openComparison() }
    private func openComparison() {
        let link = element("sharedShop.storeQuotes")
        if !link.waitForExistence(timeout:8) { reveal(link) }
        tap(link)
        let ready = app.descendants(matching:.any).matching(NSPredicate(format:"identifier IN %@",["sharedQuotes.scope","sharedQuotes.retry"])).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout:15))
    }
    private func enterKnownQuotes() {
        tap(element("sharedQuotes.enter"))
        enter(prefix:"sharedQuotes.first.",label:"East",checkout:"38.00",trip:"0",minutes:"0")
        enableSwitch("sharedQuotes.first.eligibility")
        enter(prefix:"sharedQuotes.second.",label:"West",checkout:"35.00",trip:"4.00",minutes:"18")
        enableSwitch("sharedQuotes.second.eligibility")
    }
    private func enter(prefix: String, label: String, checkout: String, trip: String, minutes: String) {
        fill(label,into:prefix+"label")
        fill(label+" store",into:prefix+"storeID")
        fill(label+" branch",into:prefix+"branch")
        fill("Entered retailer checkout",into:prefix+"source")
        fill(checkout,into:prefix+"itemSubtotal")
        fill(checkout,into:prefix+"total")
        enableSwitch(prefix+"allChargesIncluded")
        enableSwitch(prefix+"quantitiesMatched")
        enableSwitch(prefix+"singleStore")
        tap(element(prefix+"availability")); tap(app.buttons["Reviewed available"])
        fill(trip,into:prefix+"tripCash")
        fill(minutes,into:prefix+"extraMinutes")
    }
    private func confirm() { enableSwitch("sharedQuotes.acknowledged"); tap(element("sharedQuotes.confirm")) }
    private func fixture(_ label: String) { tap(element("fixture.s27.controls")); tap(app.buttons[label]) }
    private func counter(_ id: String, _ n: Int) {
        let label = id == "saves" ? "Saves":id == "proposals" ? "Proposals":id == "adoptions" ? "Adoptions":"POSTs"
        let expectation = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == true AND label == %@","\(label): \(n)"),object:element("fixture.s27."+id))
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:12),.completed)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable,target.debugDescription); target.tap() }
    private func enableSwitch(_ id: String) {
        let target = app.switches.matching(identifier:id).firstMatch; reveal(target,fullyVisible:true)
        if target.value as? String == "0" { target.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap() }
        XCTAssertEqual(target.value as? String,"1",id)
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false, requireDone: Bool = false) {
        let field = app.textFields.matching(identifier:id).firstMatch
        tap(field)
        dismissBilingualKeyboardCardIfPresent()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5), "Show the keyboard for \(id)")
        // Targeted typing requires this field to have keyboard focus.
        if replacing, let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:old.count))
            assertFieldValue(field,text:"")
        }
        if !text.isEmpty { field.typeText(text) }
        dismissBilingualKeyboardCardIfPresent()
        assertFieldValue(app.textFields.matching(identifier:id).firstMatch,text:text)
        let done = app.buttons.matching(NSPredicate(format:"identifier IN %@",["Done","Listo"])).firstMatch
        if requireDone { XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable, "Done must be reachable from \(id)") }
        if done.exists && done.isHittable { done.tap() }
        assertFieldValue(app.textFields.matching(identifier:id).firstMatch,text:text)
    }
    private func assertFieldValue(_ field: XCUIElement, text: String) {
        guard let value = field.value as? String else {
            XCTFail("The input must expose its value: \(field.identifier)")
            return
        }
        if text.isEmpty {
            XCTAssertTrue(value == "" || value == field.placeholderValue,"The input must be empty: \(field.identifier)")
        } else {
            XCTAssertEqual(value,text,"The input must retain the exact entered value: \(field.identifier)")
        }
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
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            capture("Bilingual-keyboard-card-dismissed")
        }
    }
    private func assertLabel(_ id: String, contains text: String) { let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text),target.label) }
    private func assertText(_ text: String) {
        let target = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@",text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists && target.isHittable,"Missing visible text: "+text)
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false) {
        for attempt in 0..<30 {
            let exists = target.exists
            let hittable = exists && target.isHittable
            if hittable && !fullyVisible { return }
            let area = scrollableArea()
            let frame = exists ? target.frame : .zero
            if hittable && frame.minY >= area.minY && frame.maxY <= area.maxY { return }
            let up: Bool
            if exists && !frame.isEmpty { up = frame.midY > area.midY }
            else { up = (attempt / 6) % 2 == 0 }
            scrollContent(upward:up,area:area)
        }
        let exists = target.exists
        let hittable = exists && target.isHittable
        if fullyVisible {
            let area = scrollableArea(), frame = exists ? target.frame : .zero
            XCTAssertTrue(hittable && frame.minY >= area.minY && frame.maxY <= area.maxY,
                          "Missing fully visible UI element: "+target.debugDescription)
        } else {
            XCTAssertTrue(hittable,"Missing actionable UI element: "+target.debugDescription)
        }
    }
    private func scrollableArea() -> CGRect {
        // Measure bars and keyboard from one tree so transitions cannot replace
        // an element between separate live existence, hittability and frame queries.
        let snapshot = try? app.snapshot()
        let bounds = snapshot?.frame ?? app.frame
        var keyboardTop = bounds.maxY
        var barBottom = bounds.minY+90
        var elements = snapshot.map { [$0] } ?? []
        while let element = elements.popLast() {
            let frame = element.frame
            if frame.height > 0 && frame.intersects(bounds) {
                if element.elementType == .keyboard { keyboardTop = min(keyboardTop,frame.minY) }
                if element.elementType == .navigationBar { barBottom = max(barBottom,frame.maxY) }
            }
            elements.append(contentsOf:element.children)
        }
        let top = max(bounds.minY+95,min(barBottom+12,keyboardTop-140)), bottom = min(bounds.maxY-70,keyboardTop-16)
        return CGRect(x:bounds.minX+24,y:top,width:bounds.width-48,height:max(80,bottom-top))
    }
    private func scrollContent(upward: Bool, area: CGRect) {
        let bounds = app.frame, high = area.minY+area.height*0.18, low = area.minY+area.height*0.82
        let origin = app.coordinate(withNormalizedOffset:.zero)
        let start = origin.withOffset(CGVector(dx:area.midX-bounds.minX,dy:(upward ? low:high)-bounds.minY))
        let end = origin.withOffset(CGVector(dx:area.midX-bounds.minX,dy:(upward ? high:low)-bounds.minY))
        start.press(forDuration:0.05,thenDragTo:end)
    }
    private func capture(_ name: String) { let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}
#endif
