#if RELEASE
import XCTest

/// Each case uses a fresh Release installation. The pickup cases take the
/// bundled fictional fixture from the simulator pasteboard through native Paste.
@MainActor
final class ReleasePerformanceUITests: XCTestCase {
    private let fixtureCount = 500
    private let inspectPrefix = "ledgerInspect-"
    private let noSearchResults = "No active items match your search."
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0, app.state == .runningForeground {
            screenshot("Release performance failure")
        }
        if app.state != .notRunning { app.terminate() }
    }

    func testColdLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: measurementOptions()) {
            if app.state != .notRunning { app.terminate() }
            startMeasuring()
            app.launch()
            // Let the responsive-frame signpost arrive before closing the
            // collection window. The signpost defines the reported duration.
            XCTAssertTrue(app.tabBars.buttons["Shop"].waitForExistence(timeout: 10))
            stopMeasuring()
        }
    }

    func testRenderedFiveHundredItemPickup() throws {
        try importFixture()
        let field = app.textFields["ledgerSearch"]
        var searchSamples: [Double] = []
        var checkSamples: [Double] = []
        var checkedRowIDs: [String] = []

        for index in (fixtureCount - 20)..<fixtureCount {
            let token = "m\(index)x"
            let previous = searchSamples.isEmpty ? "" : String(repeating: XCUIKeyboardKey.delete.rawValue, count: token.count)
            let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ENDSWITH %@", inspectPrefix, " " + token))
            let result = results.firstMatch

            tap(field)
            let searchStart = ProcessInfo.processInfo.systemUptime
            app.typeText(previous + token + "\n")
            XCTAssertTrue(result.waitForExistence(timeout: 8), "Expected a result for \(token)")
            searchSamples.append(milliseconds(since: searchStart))
            XCTAssertEqual(results.count, 1)
            XCTAssertTrue(result.isHittable)

            let rowID = try XCTUnwrap(UUID(uuidString: String(result.identifier.dropFirst(inspectPrefix.count))))
            checkedRowIDs.append(rowID.uuidString)
            let check = app.buttons["ledgerCheck-\(rowID.uuidString)"]
            XCTAssertTrue(check.isHittable && check.isEnabled)
            let checkStart = ProcessInfo.processInfo.systemUptime
            check.tap()
            XCTAssertTrue(result.waitForNonExistence(timeout: 8))
            checkSamples.append(milliseconds(since: checkStart))
            XCTAssertTrue(app.staticTexts[noSearchResults].exists)
        }
        XCTAssertEqual(Set(checkedRowIDs).count, 20)
        screenshot("Filtered list after twenty saved checkoffs")

        // Exercise search recovery after the timed samples so these extra
        // queries do not warm up or change the measured search/checkoff loop.
        let unmatched = "zz-no-such-fixture-item-987654321"
        func replaceQuery(_ old: String, with new: String) {
            tap(field)
            if !old.isEmpty {
                XCTAssertEqual(field.value as? String, old, "Replace the complete preceding query")
                // A middle tap can place the caret inside a long query. Use
                // the native edit menu instead of assuming an end position.
                field.press(forDuration: 1.2)
                let item = app.menuItems["Select All"]
                let selectAll = item.exists ? item : app.buttons["Select All"]
                XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
                selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            let cleared = field.value as? String
            XCTAssertTrue(cleared == "" || (cleared != nil && cleared == field.placeholderValue),
                          "Search must be completely cleared before replacement")
            field.typeText(new + "\n")
            let entered = field.value as? String
            XCTAssertTrue(entered == new || (new.isEmpty && entered != nil && entered == field.placeholderValue),
                          "The search field must contain exactly the requested query")
        }
        func fixtureResult(_ token: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ENDSWITH %@", inspectPrefix, " " + token)).firstMatch
        }
        func requireNoResults() {
            XCTAssertTrue(app.staticTexts[noSearchResults].waitForExistence(timeout: 8))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", inspectPrefix)).count, 0,
                           "An unmatched query must not retain a stale item")
        }
        replaceQuery("m499x", with: unmatched)
        requireNoResults()
        replaceQuery(unmatched, with: "m000x")
        XCTAssertTrue(fixtureResult("m000x").waitForExistence(timeout: 8))
        let uncheckedRowID = try XCTUnwrap(UUID(uuidString: String(fixtureResult("m000x").identifier.dropFirst(inspectPrefix.count))))
        XCTAssertFalse(checkedRowIDs.contains(uncheckedRowID.uuidString))
        replaceQuery("m000x", with: "")
        XCTAssertTrue(fixtureResult("m000x").waitForExistence(timeout: 8))
        XCTAssertTrue(fixtureResult("m001x").waitForExistence(timeout: 8), "Clearing must restore more than the previous single result")
        XCTAssertFalse(app.staticTexts[noSearchResults].exists)

        app.terminate()
        app.launch()
        openPickupList()
        replaceQuery("", with: unmatched)
        requireNoResults()
        replaceQuery(unmatched, with: "m000x")
        XCTAssertTrue(fixtureResult("m000x").waitForExistence(timeout: 8))
        XCTAssertEqual(fixtureResult("m000x").identifier, inspectPrefix + uncheckedRowID.uuidString,
                       "Query replacement and relaunch must preserve the unchecked item identity")
        replaceQuery("m000x", with: "m499x")
        requireNoResults()
        tap(element("ledgerHistory"))
        XCTAssertTrue(app.navigationBars["List history"].waitForExistence(timeout: 8))
        let recent = app.buttons.matching(NSPredicate(format: "label == %@", "Reopen frozen corn market label m499x")).firstMatch
        // History follows original line order, so the final item is below the viewport.
        reveal(recent)
        screenshot("Recently checked row after Release relaunch")

        try attachJSON([
            "fixtureLineCount": fixtureCount,
            "unmatchedQuery": unmatched,
            "uncheckedRowID": uncheckedRowID.uuidString,
            "beforeRelaunch": ["unmatchedEmpty": true, "replacementFoundUncheckedRow": true, "clearedListRestored": true],
            "afterRelaunch": ["unmatchedEmpty": true, "sameUncheckedRowFound": true, "checkedRowAbsent": true],
        ], name: "functional-search-500-item-pickup")

        try attachJSON([
            "fixtureLineCount": fixtureCount,
            "sampleCount": searchSamples.count,
            "searchToAccessibleResultMilliseconds": searchSamples,
            "searchP95Milliseconds": p95(searchSamples),
            "checkToResultRemovalMilliseconds": checkSamples,
            "checkP95Milliseconds": p95(checkSamples),
            "checkedRowIDs": checkedRowIDs,
            "limits": "Simulator XCTest round trips include input synthesis, keyboard dismissal, idle waits and accessibility polling.",
        ], name: "rendered-500-item-pickup")
    }

    func testScrollingPerformanceOnFiveHundredItemPickup() throws {
        try importFixture()
        let list = app.collectionViews.firstMatch
        let top = list.staticTexts["Saved on this iPhone"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        var metrics: [any XCTMetric] = [
            XCTOSSignpostMetric.scrollingAndDecelerationMetric,
            XCTMemoryMetric(application: app),
        ]
        if #available(iOS 26.0, *) {
            metrics.append(XCTHitchMetric(application: app))
        }
        var restingY: CGFloat?
        measure(metrics: metrics, options: measurementOptions()) {
            // Reset before each iteration. XCTest waits for the swipe to settle.
            list.swipeDown(velocity: 6_000)
            XCTAssertTrue(top.exists && list.frame.intersects(top.frame))
            let startY = top.frame.midY
            if let restingY {
                XCTAssertEqual(startY, restingY, accuracy: 2, "Start every sample at the same scroll position")
            } else {
                restingY = startY
            }

            startMeasuring()
            list.swipeUp(velocity: .fast)
            stopMeasuring()

            XCTAssertTrue(!top.exists || top.frame.midY < startY, "The measured gesture must scroll the list")
        }
        screenshot("Populated pickup list after measured scroll")
    }

    private func importFixture() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReleaseLedger500", withExtension: "txt"))
        let fixture = try String(contentsOf: file, encoding: .utf8)
        let lines = fixture.split(separator: "\n")
        XCTAssertEqual(lines.count, fixtureCount)
        XCTAssertEqual(Set(lines).count, fixtureCount)
        let firstLine = try XCTUnwrap(lines.first)

        app.launch()
        openPickupList()
        let startShop = element("ledgerStartShop")
        XCTAssertTrue(startShop.waitForExistence(timeout: 10), "Install the Release app on a fresh simulator for each pickup test")
        tap(startShop)
        tap(element("ledgerShopName"))
        app.typeText("Fictional weekly pickup")
        tap(element("ledgerCreateShop"))
        tap(element("ledgerImport"))

        let paste = app.buttons["Paste list"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        XCTAssertTrue(paste.isEnabled, "Copy the ReleaseLedger500 fixture to this simulator before running the test")
        // iOS 17 can expose the entire Form row for the leading Paste control.
        paste.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.5)).tap()
        let editor = element("ledgerImportText")
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", String(firstLine)), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 12), .completed)
        XCTAssertTrue((editor.value as? String) == fixture, "Native Paste must preserve the complete 500-line fixture")

        let review = element("ledgerReviewImport")
        let form = app.collectionViews.firstMatch
        // Begin below the expanded editor so the drag scrolls the form.
        let formBottom = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.91))
        let formMiddle = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        for _ in 0..<4 {
            if review.exists && review.isHittable { break }
            formBottom.press(forDuration: 0.05, thenDragTo: formMiddle, withVelocity: .slow, thenHoldForDuration: 0)
        }
        // On newer runtimes the editor can expand to fit the entire fixture.
        for _ in 0..<32 {
            if review.exists && review.isHittable { break }
            form.swipeUp(velocity: 6_000)
        }
        XCTAssertTrue(review.exists && review.isHittable && review.isEnabled, "Reach Review list after the pasted editor")
        review.tap()
        let commit = element("ledgerCommitImport")
        for _ in 0..<120 {
            if commit.exists && commit.isHittable { break }
            form.swipeUp(velocity: 6_000)
        }
        XCTAssertTrue(commit.exists && commit.isHittable, "Reach the action after all reviewed lines")
        XCTAssertTrue(commit.isEnabled, "Distinct fixture lines require no duplicate decisions")
        commit.tap()
        XCTAssertTrue(commit.waitForNonExistence(timeout: 20), "The reviewed import must save and dismiss")
        XCTAssertTrue(app.textFields["ledgerSearch"].waitForExistence(timeout: 10))
    }

    private func openPickupList() {
        tap(app.tabBars.buttons["Shop"])
        if !element("ledgerSearch").exists { tap(element("openPickupList")) }
    }

    private func measurementOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    private func milliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private func p95(_ samples: [Double]) -> Double {
        samples.sorted()[Int(ceil(Double(samples.count) * 0.95)) - 1]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(target, file: file, line: line)
        target.tap()
    }

    private func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if target.exists && target.isHittable { return }
        let list = app.collectionViews.firstMatch
        let scroll = list.exists ? list : app.scrollViews.firstMatch
        for _ in 0..<18 {
            scroll.swipeUp(velocity: .slow)
            if target.exists && target.isHittable { return }
        }
        XCTFail("Could not reveal \(target)", file: file, line: line)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachJSON(_ report: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
