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

        app.terminate()
        app.launch()
        openPickupList()
        tap(field)
        app.typeText("m499x\n")
        XCTAssertTrue(app.staticTexts[noSearchResults].waitForExistence(timeout: 8))
        tap(element("ledgerHistory"))
        XCTAssertTrue(app.navigationBars["List history"].waitForExistence(timeout: 8))
        let recent = app.buttons.matching(NSPredicate(format: "label == %@", "Reopen frozen corn market label m499x")).firstMatch
        // History follows original line order, so the final item is below the viewport.
        reveal(recent)
        screenshot("Recently checked row after Release relaunch")

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
        let metrics: [any XCTMetric] = [
            XCTOSSignpostMetric.scrollingAndDecelerationMetric,
            XCTMemoryMetric(application: app),
        ]
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
        XCTAssertTrue(review.exists && review.isHittable && review.isEnabled)
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
