#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Real production entry/models/client against a guarded transport. No physical VoiceOver claim.
@MainActor final class HistoryGrantReadUITests: XCTestCase {
    private var app: XCUIApplication!
    private let allowed = "90000000-0000-4000-8000-000000000005"
    private let foreign = "90000000-0000-4000-8000-000000000006"
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier:"dev.roominthecart.app.debug")
        app.launchArguments = ["--ui-testing","--history-grant-read-fixture","-AppleLanguages","(en)","-AppleLocale","en_US","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryL"]
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("E09-grant-read-failure") }; app.terminate()
    }
    func testFreeGrantDiscoversReadOnlyShopOpensRawRecordsAndRejectsPaidAndForeignAccess() {
        openGrantedHistory()
        let create = element("history.newObservation"); reveal(create); XCTAssertFalse(create.isEnabled)
        XCTAssertFalse(app.staticTexts[foreign].exists,"A remembered foreign source must not become a visible saved reference")
        openAllowedObservation()
        assertText("Grant-only oats"); assertText("12 oz dry pack"); assertText("$3.49")
        capture("E09-free-granted-observation-without-shopper-authority")
        tap(element("history.loadPrices")); atLeast("paid",1)
        assertText("Your authorized saved raw records remain available")
        XCTAssertFalse(app.staticTexts["Conditional minimum remaining"].exists)
        periodTab(); openRawPlan()
        assertText("Saved raw plan · no calculated balance"); assertText("Permitted saved November plan")
        capture("E09-free-saved-period-envelope-without-calculated-balance")
        tap(element("history.analyzePeriod")); atLeast("paid",2)
        XCTAssertFalse(app.staticTexts["Permitted saved November plan"].exists)
        XCTAssertFalse(app.staticTexts["Conditional maximum remaining"].exists)
        openRawPlan()
        tap(app.buttons["Edit this period plan"])
        tap(element("history.reviewPeriod"))
        enable("I reviewed these exact fields and their source")
        tap(element("history.applyReviewed")); atLeast("paid",3); counter("writes",0)
        assertText("Your authorized saved raw records remain available")
        capture("E09-free-paid-analysis-and-write-denied-without-mutation")
        pricesTab()
        let reference = app.textFields["Saved observation reference"]
        fill(foreign,field:reference)
        tap(element("history.openSavedObservation")); atLeast("denied",1)
        XCTAssertTrue(app.buttons["Check access again"].waitForExistence(timeout:12))
        XCTAssertFalse(app.staticTexts["Grant-only oats"].exists)
        XCTAssertFalse(app.staticTexts["Permitted saved November plan"].exists)
        counter("writes",0)
        capture("E09-foreign-reference-clears-protected-disclosure")
    }
    func testRevokedBudgetGrantClearsPreviouslyOpenedRawPeriodAndRememberedSource() {
        openGrantedHistory(); openAllowedObservation(); assertText("Grant-only oats")
        periodTab(); openRawPlan(); assertText("Permitted saved November plan")
        tap(element("fixture.h09.revoke"))
        tap(element("history.openRawPeriod")); atLeast("denied",1)
        XCTAssertTrue(app.buttons["Check access again"].waitForExistence(timeout:12))
        XCTAssertFalse(app.staticTexts["Permitted saved November plan"].exists)
        XCTAssertFalse(app.staticTexts["Grant-only oats"].exists)
        XCTAssertFalse(app.buttons.containing(NSPredicate(format:"label CONTAINS %@",allowed)).firstMatch.exists)
        tap(app.buttons["Check access again"])
        XCTAssertFalse(app.staticTexts["Permitted saved November plan"].exists)
        XCTAssertFalse(app.staticTexts["$100.00"].exists)
        counter("writes",0)
        capture("E09-revocation-clears-raw-envelope-and-saved-source")
    }
    private func openGrantedHistory() {
        app.launch()
        XCTAssertTrue(element("fixture.h09.openHistory").waitForExistence(timeout:20))
        tap(element("fixture.h09.openHistory"))
        XCTAssertTrue(element("history.newObservation").waitForExistence(timeout:15))
        XCTAssertFalse(element("history.newObservation").isEnabled)
        tap(app.buttons["Choose shared shop"])
        let granted = app.buttons.containing(NSPredicate(format:"label CONTAINS %@","00000003")).firstMatch
        XCTAssertTrue(granted.waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format:"label CONTAINS %@","00000004")).firstMatch.exists)
        tap(granted)
        if app.buttons["Check access again"].waitForExistence(timeout:3) { tap(app.buttons["Check access again"]) }
        XCTAssertTrue(element("history.newObservation").waitForExistence(timeout:15))
        XCTAssertFalse(element("history.newObservation").isEnabled)
        counter("writes",0)
        capture("E09-grant-only-shop-discovered-independently-of-owned-shops")
    }
    private func openAllowedObservation() {
        tap(app.buttons.containing(NSPredicate(format:"label CONTAINS %@",allowed)).firstMatch)
    }
    private func openRawPlan() { tap(element("history.openRawPeriod")) }
    private func periodTab() { tap(app.segmentedControls.buttons["Period budgets"]) }
    private func pricesTab() { tap(app.segmentedControls.buttons["Price records"]) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    private func tap(_ value: XCUIElement) { reveal(value); XCTAssertTrue(value.isHittable,value.debugDescription); value.tap() }
    private func fill(_ text: String, field: XCUIElement) { tap(field); app.typeText(text); let done = app.buttons.matching(identifier:"Done").firstMatch; if done.exists && done.isHittable { done.tap() } else { app.swipeDown() } }
    private func enable(_ label: String) {
        let toggle = app.switches[label]; reveal(toggle)
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap() }
        XCTAssertEqual(toggle.value as? String,"1")
    }
    private func assertText(_ text: String) { let value = app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@",text)).firstMatch; reveal(value); XCTAssertTrue(value.isHittable,text) }
    private func counter(_ id: String, _ count: Int) {
        let label = id == "writes" ? "Writes":id == "paid" ? "Paid denied":id == "denied" ? "Denied":"Reads"
        let e = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == true AND label == %@","\(label): \(count)"),object:element("fixture.h09."+id))
        XCTAssertEqual(XCTWaiter.wait(for:[e],timeout:10),.completed)
    }
    private func atLeast(_ id: String, _ minimum: Int) {
        let value = element("fixture.h09."+id)
        let e = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            guard value.exists, let number = Int(value.label.split(separator:":").last?.trimmingCharacters(in:.whitespaces) ?? "") else { return false }
            return number >= minimum
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[e],timeout:12),.completed)
    }
    private func reveal(_ value: XCUIElement) {
        for attempt in 0..<30 {
            if value.exists && value.isHittable { return }
            let bounds = app.frame
            let keyboard = app.keyboards.allElementsBoundByIndex.filter(\.exists).map { $0.frame.minY }.min() ?? bounds.maxY
            let bars = app.navigationBars.allElementsBoundByIndex.filter(\.exists).map { $0.frame.maxY }.max() ?? bounds.minY+110
            let top = max(bounds.minY+100,min(bars+16,keyboard-150)), bottom = min(bounds.maxY-70,keyboard-20)
            let middle = (top+bottom)/2, high = top+(bottom-top)*0.18, low = top+(bottom-top)*0.82
            let up = value.exists && !value.frame.isEmpty ? value.frame.midY > middle : (attempt/6)%2 == 0
            let origin = app.coordinate(withNormalizedOffset:.zero)
            origin.withOffset(CGVector(dx:bounds.midX-bounds.minX,dy:(up ? low:high)-bounds.minY))
                .press(forDuration:0.05,thenDragTo:origin.withOffset(CGVector(dx:bounds.midX-bounds.minX,dy:(up ? high:low)-bounds.minY)))
        }
        XCTAssertTrue(value.exists && value.isHittable,"Missing actual history control: "+value.debugDescription)
    }
    private func capture(_ name: String) { let a = XCTAttachment(screenshot:app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
}
#endif
