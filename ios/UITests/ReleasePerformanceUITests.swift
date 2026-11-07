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
        let reportWindowRecorder = ScrollReportWindowRecorder()
        metrics.append(ScrollReportWindowWitness(recorder: reportWindowRecorder))
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
        // Serialize only after XCTest has returned from measurement.
        let witnessEncoder = JSONEncoder()
        witnessEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let witnessAttachment = XCTAttachment(
            data: try witnessEncoder.encode(reportWindowRecorder.snapshot()),
            uniformTypeIdentifier: "public.json")
        witnessAttachment.name = "scroll-report-window-witness"
        witnessAttachment.lifetime = .keepAlways
        add(witnessAttachment)
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
        // Launch can return before the root accessibility tree is available.
        // Establish readiness before reveal tries to scroll for a missing tab.
        XCTAssertTrue(app.tabBars.buttons["Shop"].waitForExistence(timeout: 10),
                      "The Shop tab must be available before opening the pickup list")
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

struct ScrollWitnessTimestamp: Encodable {
    let absoluteTime: String
    let absoluteTimeNanoSeconds: String
    let unixSeconds: Double?
    let invalidUnixSeconds: String?

    init(absoluteTime: UInt64, absoluteTimeNanoSeconds: UInt64, unixSeconds: Double) {
        self.absoluteTime = String(absoluteTime)
        self.absoluteTimeNanoSeconds = String(absoluteTimeNanoSeconds)
        self.unixSeconds = unixSeconds.isFinite ? unixSeconds : nil
        self.invalidUnixSeconds = unixSeconds.isFinite ? nil : String(describing: unixSeconds)
    }
}

struct ScrollWitnessEvent: Encodable {
    let sequence: Int
    let instanceOrdinal: String
    let kind: String
    let callbackUptime: Double
    let callbackUnixUTC: Double
    let suppliedStart: ScrollWitnessTimestamp?
    let suppliedEnd: ScrollWitnessTimestamp?
}

struct ScrollWitnessSnapshot: Encodable {
    let schemaVersion = 1
    let diagnosticOnly = true
    let maximumRetainedEvents: Int
    let totalEvents: Int
    let omittedEvents: Int
    let totalInstances: String
    let reportCallbacks: Int
    let status: String
    let events: [ScrollWitnessEvent]
}

/// Per-test scalar storage only. No framework object survives a callback.
final class ScrollReportWindowRecorder {
    private let lock = NSLock()
    private let capacity: Int
    private var nextInstance: UInt64 = 0
    private var totalEvents = 0
    private var reportCallbacks = 0
    private var events: [ScrollWitnessEvent] = []

    init(capacity: Int = 128) {
        precondition((0...128).contains(capacity))
        self.capacity = capacity
        events.reserveCapacity(capacity)
    }

    func allocateInstance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextInstance += 1
        appendLocked(kind: "created", instance: nextInstance, start: nil, end: nil)
        return nextInstance
    }

    func record(kind: String, instance: UInt64,
                start: ScrollWitnessTimestamp? = nil, end: ScrollWitnessTimestamp? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(kind: kind, instance: instance, start: start, end: end)
    }

    private func appendLocked(kind: String, instance: UInt64,
                              start: ScrollWitnessTimestamp?, end: ScrollWitnessTimestamp?) {
        totalEvents += 1
        if kind == "report" { reportCallbacks += 1 }
        guard events.count < capacity else { return }
        events.append(ScrollWitnessEvent(sequence: totalEvents, instanceOrdinal: String(instance), kind: kind,
            callbackUptime: ProcessInfo.processInfo.systemUptime, callbackUnixUTC: Date().timeIntervalSince1970,
            suppliedStart: start, suppliedEnd: end))
    }

    func snapshot() -> ScrollWitnessSnapshot {
        lock.lock(); defer { lock.unlock() }
        let omitted = totalEvents - events.count
        return ScrollWitnessSnapshot(maximumRetainedEvents: capacity, totalEvents: totalEvents,
            omittedEvents: omitted, totalInstances: String(nextInstance), reportCallbacks: reportCallbacks,
            status: omitted > 0 ? "truncated" : (reportCallbacks == 0 ? "no-report-callbacks" : "recorded"),
            events: events)
    }
}


/// Standalone witness. Never wraps or delegates to a built-in metric.
final class ScrollReportWindowWitness: NSObject, XCTMetric {
    private let recorder: ScrollReportWindowRecorder
    private let instance: UInt64

    init(recorder: ScrollReportWindowRecorder) {
        self.recorder = recorder
        self.instance = recorder.allocateInstance()
        super.init()
    }

    func copy(with zone: NSZone? = nil) -> Any {
        ScrollReportWindowWitness(recorder: recorder)
    }

    func willBeginMeasuring() { recorder.record(kind: "willBegin", instance: instance) }
    func didStopMeasuring() { recorder.record(kind: "didStop", instance: instance) }

    func reportMeasurements(from startTime: XCTPerformanceMeasurementTimestamp,
                            to endTime: XCTPerformanceMeasurementTimestamp) throws -> [XCTPerformanceMeasurement] {
        let start = ScrollWitnessTimestamp(absoluteTime: startTime.absoluteTime,
            absoluteTimeNanoSeconds: startTime.absoluteTimeNanoSeconds,
            unixSeconds: startTime.date.timeIntervalSince1970)
        let end = ScrollWitnessTimestamp(absoluteTime: endTime.absoluteTime,
            absoluteTimeNanoSeconds: endTime.absoluteTimeNanoSeconds,
            unixSeconds: endTime.date.timeIntervalSince1970)
        recorder.record(kind: "report", instance: instance, start: start, end: end)
        return [] // No invented metric, sample, or duration.
    }
}
#endif
