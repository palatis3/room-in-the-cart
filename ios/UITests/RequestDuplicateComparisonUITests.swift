#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class RequestDuplicateComparisonUITests: XCTestCase {
    private var app: XCUIApplication!
    private var expectsDecisionSheet = false
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier:"dev.roominthecart.app.debug")
        expectsDecisionSheet = false
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("S23-duplicate-comparison-failure") }
        app.terminate()
    }
    func testSplitPageComparisonPreservesBothUsesAndCancelHasNoWriteThenDecidesOnlySam() {
        launch(language:"en",locale:"en_US")
        let sam = element("household.request.a4444444-4444-4444-8444-444444444441")
        openRequest(sam,step:"Sam-page-one")
        assertVisible("No matching name among the loaded requests yet. Other requests have not been checked.")
        XCTAssertFalse(app.staticTexts["2 boxes for the school snack drive"].exists)
        capture("S23-page-one-before-check-more")
        tap(element("household.duplicates.loadMore"))
        capture("S23-page-two-loaded-in-same-decision-sheet")
        assertVisible("Deciding this request")
        assertVisible("1 box for breakfasts")
        assertVisible("Lee")
        assertVisible("2 boxes for the school snack drive")
        assertVisible("Handled")
        capture("S23-original-authors-uses-and-separate-outcomes")
        closeDecision()
        XCTAssertEqual(element("fixture.s23.commands").label,"Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s23.lines").label,"Fixture saved lines: 1")
        XCTAssertEqual(element("fixture.s23.loaded").label,"Fixture loaded requests: 4")
        openRequest(sam,step:"Sam-before-individual-decision")
        tap(element("household.decision.review"))
        let apply = element("household.decision.apply")
        tap(apply)
        assertVisible("Decision confirmed by the household")
        closeDecision()
        XCTAssertEqual(element("fixture.s23.commands").label,"Fixture applied decisions: 1")
        XCTAssertEqual(element("fixture.s23.lines").label,"Fixture saved lines: 1")
        tap(app.buttons["Load more requests"])
        let lee = element("household.request.a4444444-4444-4444-8444-444444444443")
        openRequest(lee,step:"Lee-after-Sam-outcome")
        assertVisible("2 boxes for the school snack drive")
        assertVisible("Received, waiting for review")
        assertVisible("Saved for next shop")
        capture("S23-one-decision-keeps-other-request-pending")
    }
    func testSpanishLargeTypeKeepsOriginalRequestWordsAndReadOnlyComparison() {
        launch(language:"es",locale:"es_US",largeType:true)
        let sam = element("household.request.a4444444-4444-4444-8444-444444444441")
        openRequest(sam,step:"Spanish-Sam-page-one")
        tap(element("household.duplicates.loadMore"))
        capture("S23-Spanish-page-two-loaded-in-same-decision-sheet")
        assertVisible("Cantidad y uso, tal como se escribieron")
        assertVisible("1 box for breakfasts")
        assertVisible("2 boxes for the school snack drive")
        assertVisible("Cada solicitante conserva un resultado por separado.",contains:true)
        capture("S23-Spanish-large-type-original-request-words")
        closeDecision()
        XCTAssertEqual(element("fixture.s23.commands").label,"Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s23.lines").label,"Fixture saved lines: 1")
    }
    private func launch(language:String,locale:String,largeType:Bool=false) {
        app.launchArguments = ["--ui-testing","--request-duplicates-fixture","-AppleLanguages","(\(language))","-AppleLocale",locale]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(element("fixture.s23.loaded").waitForExistence(timeout:20))
        capture("S23-launched-\(language)")
    }
    private func openRequest(_ request:XCUIElement,step:String) {
        // Lazy collection rows do not exist until their portion is scrolled in.
        reveal(request)
        XCTAssertTrue(request.waitForExistence(timeout:5))
        tap(request)
        let cancel = element("household.decision.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout:5))
        XCTAssertTrue(cancel.isHittable)
        expectsDecisionSheet = true
        capture("S23-opened-\(step)")
    }
    private func closeDecision() {
        tap(element("household.decision.cancel"))
        expectsDecisionSheet = false
        let dismissed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:element("household.decision.cancel"))
        XCTAssertEqual(XCTWaiter.wait(for:[dismissed],timeout:5),.completed)
    }
    private func element(_ id:String)->XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    private func tap(_ target:XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable,target.debugDescription); target.tap() }
    private func assertVisible(_ text:String,contains:Bool=false) {
        let predicate = NSPredicate(format:contains ? "label CONTAINS %@" : "label == %@",text)
        let matches = app.staticTexts.matching(predicate)
        let found = scanForVisibleElement(description:text) {
            matches.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        } candidate: {
            // The covered inbox can contain the same text. Prefer the sheet's
            // last matching node, and recheck visible matches after each drag.
            matches.allElementsBoundByIndex.last ?? matches.firstMatch
        }
        XCTAssertTrue(found,"Missing visible text: \(text)")
    }
    private func reveal(_ target:XCUIElement) {
        let description = target.exists ? target.identifier : "unmaterialized-control"
        let found = scanForVisibleElement(description:description) {
            target.exists && target.isHittable ? target : nil
        } candidate: {
            target
        }
        XCTAssertTrue(found,"Missing actionable UI element: \(target.debugDescription)")
    }
    private func scanForVisibleElement(description:String,visible:()->XCUIElement?,candidate:()->XCUIElement)->Bool {
        var forward = true
        var reversed = false
        var previousSignature = ""
        var unmoved = 0
        for attempt in 0..<48 {
            let cancel = element("household.decision.cancel")
            if expectsDecisionSheet && (!cancel.exists || !cancel.isHittable) {
                capture("S23-unexpected-sheet-dismissal-\(attempt)")
                XCTFail("The decision sheet disappeared while revealing \(description)")
                return false
            }
            if visible() != nil { return true }
            guard let container = activeScrollableContent() else {
                capture("S23-no-active-scroll-container")
                return false
            }
            let area = unobscuredArea(in:container)
            guard area.height >= 80, area.width >= 80 else {
                capture("S23-no-unobscured-scroll-area")
                return false
            }
            let target = candidate()
            if target.exists, !target.frame.isEmpty {
                if target.frame.maxY <= area.minY { forward = false }
                else if target.frame.minY >= area.maxY { forward = true }
            }
            let position = scrollPosition(in:container)
            if forward && position.map({ $0 >= 100 }) == true {
                if reversed { break }
                forward = false; reversed = true
            } else if !forward && position.map({ $0 <= 0 }) == true {
                // A down-drag at the beginning of a modal list dismisses its
                // sheet. Stop at the observed boundary instead of doing that.
                break
            }
            let signature = visibleSignature(in:container,area:area)
            unmoved = signature == previousSignature ? unmoved + 1 : 0
            previousSignature = signature
            if unmoved >= 2 {
                if !forward || reversed { break }
                forward = false; reversed = true; unmoved = 0
            }
            if attempt == 0 || attempt % 8 == 0 { capture("S23-reveal-\(attempt)-\(description)") }
            scroll(in:container,area:area,forward:forward)
        }
        capture("S23-reveal-exhausted-\(description)")
        return false
    }
    private func activeScrollableContent()->XCUIElement? {
        for candidates in [app.collectionViews.allElementsBoundByIndex,app.tables.allElementsBoundByIndex,app.scrollViews.allElementsBoundByIndex] {
            if let active = candidates.last(where: { element in
                element.exists && element.isHittable && element.frame.intersection(app.frame).height >= 80
            }) { return active }
        }
        return nil
    }
    private func unobscuredArea(in container:XCUIElement)->CGRect {
        var area = container.frame.intersection(app.frame)
        let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && $0.frame.intersects(area) }
        var top = max(area.minY,bars.map { $0.frame.maxY }.max() ?? area.minY)
        if expectsDecisionSheet { top = max(top,element("household.decision.cancel").frame.maxY) }
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY }.min() ?? area.maxY
        let bottom = min(area.maxY,keyboardTop,app.frame.maxY-20)
        area = CGRect(x:area.minX+24,y:top+16,width:max(0,area.width-48),height:max(0,bottom-top-32))
        return area
    }
    private func scrollPosition(in container:XCUIElement)->Double? {
        for element in container.descendants(matching:.other).allElementsBoundByIndex.reversed() {
            let label = element.label.lowercased()
            guard label.contains("scroll") || label.contains("desplazamiento"),
                  let value = element.value as? String, value.hasSuffix("%"),
                  let percent = Double(value.dropLast().replacingOccurrences(of:",",with:".")) else { continue }
            return percent
        }
        return nil
    }
    private func visibleSignature(in container:XCUIElement,area:CGRect)->String {
        container.staticTexts.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.intersects(area)
        }.map { "\($0.label)@\(Int($0.frame.minY))" }.joined(separator:"|")
    }
    private func scroll(in container:XCUIElement,area:CGRect,forward:Bool) {
        let distance = min(240,area.height*0.42)
        let high = area.midY-distance/2, low = area.midY+distance/2
        let origin = container.coordinate(withNormalizedOffset:.zero)
        let start = origin.withOffset(CGVector(dx:area.midX-container.frame.minX,dy:(forward ? low : high)-container.frame.minY))
        let end = origin.withOffset(CGVector(dx:area.midX-container.frame.minX,dy:(forward ? high : low)-container.frame.minY))
        start.press(forDuration:0.05,thenDragTo:end)
    }
    private func capture(_ name:String) {
        let attachment = XCTAttachment(screenshot:app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string:app.debugDescription)
        hierarchy.name = name + "-accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
#endif
