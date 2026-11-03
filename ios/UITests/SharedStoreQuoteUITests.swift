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
        app.launchArguments = ["--ui-testing","--shared-store-quotes-fixture","-AppleLanguages","(en)","-AppleLocale","en_US"]
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
        tap(app.buttons["Refresh and clear local retry"])
        tap(app.buttons.matching(identifier:"Refresh and clear local retry").allElementsBoundByIndex.last!)
        fixture("Freeze shared shop"); tap(element("sharedQuotes.refresh"))
        assertText("Saved proof is read-only")
        XCTAssertFalse(element("sharedQuotes.enter").exists)
        counter("saves",0)
    }
    func testSpanishLargestTextKeepsRealQuoteEntryDiscoverable() {
        app.launchArguments = ["--ui-testing","--shared-store-quotes-fixture","-AppleLanguages","(es)","-AppleLocale","es_US","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        openAdult(); tap(element("sharedQuotes.enter"))
        fill("Tienda del barrio",into:"sharedQuotes.first.label")
        fill("Sucursal del barrio",into:"sharedQuotes.first.branch")
        reveal(element("sharedQuotes.first.source"))
        XCTAssertTrue(element("sharedQuotes.first.source").exists)
        capture("S27-spanish-largest-text-native-fields")
        counter("saves",0); counter("proposals",0); counter("adoptions",0)
    }
    private func openAdult() { app.launch(); openComparison() }
    private func openComparison() {
        let link = element("sharedShop.storeQuotes")
        XCTAssertTrue(link.waitForExistence(timeout:25)); tap(link)
        XCTAssertTrue(element("sharedQuotes.scope").waitForExistence(timeout:15))
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
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        let field = app.textFields.matching(identifier:id).firstMatch; tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:old.count)) }
        if !text.isEmpty { app.typeText(text) }
        let done = app.buttons.matching(identifier:"Done").firstMatch; if done.exists && done.isHittable { done.tap() }
    }
    private func assertLabel(_ id: String, contains text: String) { let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text),target.label) }
    private func assertText(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@",text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists && target.isHittable,"Missing visible text: "+text)
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false) {
        for attempt in 0..<30 {
            let area = scrollableArea()
            if target.exists && target.isHittable, !fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY) { return }
            let up: Bool
            if target.exists && !target.frame.isEmpty { up = target.frame.midY > area.midY }
            else { up = attempt < 21 }
            scrollContent(upward:up)
        }
        XCTAssertTrue(target.exists && target.isHittable,"Missing actionable UI element: "+target.debugDescription)
    }
    private func scrollableArea() -> CGRect {
        let bounds = app.frame
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter(\.exists).map { $0.frame.minY }.min() ?? bounds.maxY
        let barBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame.maxY }.max() ?? bounds.minY+90
        let top = max(bounds.minY+95,min(barBottom+12,keyboardTop-140)), bottom = min(bounds.maxY-70,keyboardTop-16)
        return CGRect(x:bounds.minX+24,y:top,width:bounds.width-48,height:max(80,bottom-top))
    }
    private func scrollContent(upward: Bool) {
        let area = scrollableArea(), bounds = app.frame, high = area.minY+area.height*0.18, low = area.minY+area.height*0.82
        let origin = app.coordinate(withNormalizedOffset:.zero)
        let start = origin.withOffset(CGVector(dx:area.midX-bounds.minX,dy:(upward ? low:high)-bounds.minY))
        let end = origin.withOffset(CGVector(dx:area.midX-bounds.minX,dy:(upward ? high:low)-bounds.minY))
        start.press(forDuration:0.05,thenDragTo:end)
    }
    private func capture(_ name: String) { let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}
#endif
