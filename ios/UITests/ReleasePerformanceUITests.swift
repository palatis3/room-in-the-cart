#if RELEASE
import XCTest
import MachO
import Darwin

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
        let emptyState = app.staticTexts[noSearchResults]
        func replaceQuery(_ old: String, with new: String, showing result: XCUIElement,
                          file: StaticString = #filePath, line: UInt = #line) {
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
            // Return dismisses the keyboard while SwiftUI filters the list. Observe
            // the exact field value and its rendered result within the same budget.
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard result.exists, let value = field.value as? String else { return false }
                return value == new || (new.isEmpty && value == field.placeholderValue)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed,
                           "Expected query \(new.debugDescription) and its result. Field value: \(String(describing: field.value))",
                           file: file, line: line)
        }
        func fixtureResult(_ token: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ENDSWITH %@", inspectPrefix, " " + token)).firstMatch
        }
        func requireNoResults() {
            XCTAssertTrue(emptyState.exists)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", inspectPrefix)).count, 0,
                           "An unmatched query must not retain a stale item")
        }
        replaceQuery("m499x", with: unmatched, showing: emptyState)
        requireNoResults()
        replaceQuery(unmatched, with: "m000x", showing: fixtureResult("m000x"))
        let uncheckedRowID = try XCTUnwrap(UUID(uuidString: String(fixtureResult("m000x").identifier.dropFirst(inspectPrefix.count))))
        XCTAssertFalse(checkedRowIDs.contains(uncheckedRowID.uuidString))
        replaceQuery("m000x", with: "", showing: fixtureResult("m001x"))
        XCTAssertTrue(fixtureResult("m000x").exists && fixtureResult("m001x").exists,
                      "Clearing must restore more than the previous single result")
        XCTAssertFalse(app.staticTexts[noSearchResults].exists)

        app.terminate()
        app.launch()
        openPickupList()
        replaceQuery("", with: unmatched, showing: emptyState)
        requireNoResults()
        replaceQuery(unmatched, with: "m000x", showing: fixtureResult("m000x"))
        XCTAssertEqual(fixtureResult("m000x").identifier, inspectPrefix + uncheckedRowID.uuidString,
                       "Query replacement and relaunch must preserve the unchecked item identity")
        replaceQuery("m000x", with: "m499x", showing: emptyState)
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
        #if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
        let captureProbe = try RITCCaptureRunner(app: app)
        defer { captureProbe.close() }
        #endif
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
        #if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
        try captureProbe.awaitCollector()
        #endif
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

            #if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
            guard captureProbe.begin() else { return }
            #endif
            startMeasuring()
            list.swipeUp(velocity: .fast)
            stopMeasuring()
            #if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
            guard captureProbe.end() else { return }
            #endif

            XCTAssertTrue(!top.exists || top.frame.midY < startY, "The measured gesture must scroll the list")
        }
        screenshot("Populated pickup list after measured scroll")
        try attachJSON(PerformanceLoadedImages.report(), name: "post-measure-loaded-images")
        #if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
        try captureProbe.finish()
        try attachJSON(captureProbe.report(), name: "app-capture-runner-control")
        #endif
    }

    private func importFixture() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReleaseLedger500", withExtension: "txt"))
        let fixture = try String(contentsOf: file, encoding: .utf8)
        let lines = fixture.split(separator: "\n")
        XCTAssertEqual(lines.count, fixtureCount)
        XCTAssertEqual(Set(lines).count, fixtureCount)
        let firstLine = try XCTUnwrap(lines.first)

        app.launch()
        let startShop = element("openPickupList")
        XCTAssertTrue(startShop.waitForExistence(timeout: 10))
        XCTAssertTrue(startShop.label.contains("Start pickup"), "Install the Release app on a fresh simulator for each pickup test")
        tap(startShop)
        app.renameSelectedPickup("Fictional weekly pickup")
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
// MARK: - Post-measure loaded-image diagnostic (not performance acceptance)
// dyld has no public unregister operation. The callback and its fixed storage
// stay alive for the process lifetime; after capture the callback is a no-op.
private struct PerformanceImageRecord {
    var kind = 0 // 0 = unrelated, 1 = MainThreadChecker, 2 = RPAC
    var malformed = false
    var cpu: UInt32 = 0
    var cpuSubtype: UInt32 = 0
    var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum PerformanceImageParser {
    static let maxCommands = 512
    static let maxCommandBytes = 65_536

    static func word(_ bytes: UnsafeRawPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    // All parsing is bounded by the dyld-owned Mach-O load-command region.
    // No dyld lookups, strings, JSON, Foundation or allocating collections here.
    static func parse(_ bytes: UnsafeRawPointer, available: Int) -> PerformanceImageRecord {
        var result = PerformanceImageRecord()
        guard available >= 32, word(bytes, 0) == 0xfeedfacf else {
            result.malformed = true; return result
        }
        guard word(bytes, 12) == 6 else { return result } // MH_DYLIB only
        result.cpu = word(bytes, 4)
        result.cpuSubtype = word(bytes, 8)
        let count = Int(word(bytes, 16)), size = Int(word(bytes, 20))
        guard count <= maxCommands, size <= maxCommandBytes, size <= available - 32 else {
            result.malformed = true; return result
        }
        let end = 32 + size
        var offset = 32, hasID = false, hasUUID = false
        for _ in 0..<count {
            guard offset <= end - 8 else { result.malformed = true; return result }
            let command = word(bytes, offset), length = Int(word(bytes, offset + 4))
            guard length >= 8, length % 8 == 0, length <= end - offset else {
                result.malformed = true; return result
            }
            if command == 0xD { // LC_ID_DYLIB
                guard !hasID, length >= 24 else { result.malformed = true; return result }
                hasID = true
                let nameOffset = Int(word(bytes, offset + 8))
                guard nameOffset >= 24, nameOffset < length, length - nameOffset <= 4096 else {
                    result.malformed = true; return result
                }
                var cursor = offset + nameOffset, basename = cursor
                while cursor < offset + length && bytes.load(fromByteOffset: cursor, as: UInt8.self) != 0 {
                    if bytes.load(fromByteOffset: cursor, as: UInt8.self) == 47 { basename = cursor + 1 }
                    cursor += 1
                }
                guard cursor < offset + length else { result.malformed = true; return result }
                if matches(bytes, start: basename, end: cursor, name: "libMainThreadChecker.dylib") { result.kind = 1 }
                if matches(bytes, start: basename, end: cursor, name: "libRPAC.dylib") { result.kind = 2 }
            } else if command == 0x1B { // LC_UUID
                guard !hasUUID, length == 24 else { result.malformed = true; return result }
                hasUUID = true
                result.uuid = bytes.loadUnaligned(fromByteOffset: offset + 8, as: uuid_t.self)
                var nonzero: UInt8 = 0
                for index in 0..<16 { nonzero |= bytes.load(fromByteOffset: offset + 8 + index, as: UInt8.self) }
                guard nonzero != 0 else { result.malformed = true; return result }
            }
            offset += length
        }
        guard offset == end, hasID else { result.malformed = true; return result }
        if result.kind != 0 && (!hasUUID || (result.cpu != 0x0100000c && result.cpu != 0x01000007)) {
            result.malformed = true
        }
        return result
    }

    private static func matches(_ bytes: UnsafeRawPointer, start: Int, end: Int, name: StaticString) -> Bool {
        guard end - start == name.utf8CodeUnitCount else { return false }
        for index in 0..<name.utf8CodeUnitCount {
            if bytes.load(fromByteOffset: start + index, as: UInt8.self) != name.utf8Start[index] { return false }
        }
        return true
    }
}

private final class PerformanceImageStorage: @unchecked Sendable {
    // Only immutable fields are accessed without this dedicated mutex. No dyld
    // calls or attachment/JSON work occur while it is held, avoiding lock inversion.
    let mutex: UnsafeMutablePointer<pthread_mutex_t>
    let initializationError: Int32
    var registered = false
    var active = false
    var callbacks = 0
    var parsedBytes = 0
    var deadline: UInt64 = 0
    var capped = false
    var malformed = false
    var checker = PerformanceImageRecord()
    var rpac = PerformanceImageRecord()
    var checkerCount = 0
    var rpacCount = 0

    init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        initializationError = pthread_mutex_init(mutex, nil)
    }
    // Intentionally process lifetime: freeing/destroying this mutex while dyld
    // still retains the C callback would be unsafe. There is exactly one instance.
    static let shared = PerformanceImageStorage()
}

private func performanceImageAdded(_ header: UnsafePointer<mach_header>?, _ slide: Int) {
    let storage = PerformanceImageStorage.shared // initialized before registration
    guard storage.initializationError == 0 else { return }
    pthread_mutex_lock(storage.mutex)
    defer { pthread_mutex_unlock(storage.mutex) }
    guard storage.active else { return }
    guard storage.callbacks < 2048, mach_absolute_time() < storage.deadline else {
        storage.capped = true; return
    }
    storage.callbacks += 1
    guard let header else { storage.malformed = true; return }
    let bytes = UnsafeRawPointer(header)
    let size = Int(PerformanceImageParser.word(bytes, 20))
    guard size <= PerformanceImageParser.maxCommandBytes,
          storage.parsedBytes <= 64 * 1024 * 1024 - size - 32 else {
        storage.capped = true; return
    }
    storage.parsedBytes += size + 32
    let image = PerformanceImageParser.parse(bytes, available: size + 32)
    if image.malformed { storage.malformed = true; return }
    if image.kind == 1 {
        storage.checkerCount += 1
        if storage.checkerCount == 1 { storage.checker = image }
    } else if image.kind == 2 {
        storage.rpacCount += 1
        if storage.rpacCount == 1 { storage.rpac = image }
    }
}

private enum PerformanceLoadedImages {
    static func report() -> [String: Any] {
        let storage = PerformanceImageStorage.shared
        var report: [String: Any] = [
            "schemaVersion": 1, "diagnosticOnly": true, "releaseAcceptance": false,
            "processRole": "xctest-runner", "processID": getpid(), "phase": "post-measure",
            "scope": "Images observed during post-measure dyld registration; not proof of loading, initialization or metric transport during measurement.",
            "status": "error", "collectionComplete": false,
        ]
        guard storage.initializationError == 0 else { report["error"] = "mutex_initialization"; return report }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0 else {
            report["error"] = "clock_timebase"; return report
        }
        let started = mach_absolute_time()
        let budget = UInt64(2_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer))
        pthread_mutex_lock(storage.mutex)
        guard !storage.registered else {
            pthread_mutex_unlock(storage.mutex)
            report["error"] = "already_registered"; return report
        }
        storage.registered = true
        storage.deadline = started &+ budget
        storage.active = true
        pthread_mutex_unlock(storage.mutex)
        // Synchronously reports existing images. Registration itself can wait
        // for dyld's lock: the 2-second limit is cooperative, never a hard timeout.
        _dyld_register_func_for_add_image(performanceImageAdded)
        pthread_mutex_lock(storage.mutex)
        storage.active = false
        let capped = storage.capped || mach_absolute_time() >= storage.deadline
        let malformed = storage.malformed
        let checker = storage.checker, rpac = storage.rpac
        let checkerCount = storage.checkerCount, rpacCount = storage.rpacCount
        let callbacks = storage.callbacks, parsedBytes = storage.parsedBytes
        pthread_mutex_unlock(storage.mutex)
        // All allocation/string formatting happens after the callback window.
        func entry(_ name: String, _ image: PerformanceImageRecord, _ count: Int) -> [String: Any] {
            var value: [String: Any] = ["name": name, "matchCount": count]
            if capped { value["status"] = "error" }
            else if malformed { value["status"] = "malformed" }
            else if count == 0 { value["status"] = "no-match" }
            else if count > 1 { value["status"] = "ambiguous" }
            else {
                value["status"] = "complete"
                value["uuid"] = UUID(uuid: image.uuid).uuidString
                value["architecture"] = image.cpu == 0x0100000c ? "arm64" : "x86_64"
                value["cpuType"] = image.cpu
                value["cpuSubtype"] = image.cpuSubtype
            }
            return value
        }
        report["status"] = capped ? "error" : malformed ? "malformed" :
            (checkerCount > 1 || rpacCount > 1) ? "ambiguous" :
            (checkerCount == 0 || rpacCount == 0) ? "no-match" : "complete"
        report["collectionComplete"] = !capped && !malformed
        report["callbacks"] = callbacks
        report["parsedBytes"] = parsedBytes
        report["budgetExceeded"] = capped
        report["libraries"] = [entry("libMainThreadChecker.dylib", checker, checkerCount), entry("libRPAC.dylib", rpac, rpacCount)]
        return report
    }
}
#endif

#if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
import notify
// Control handshakes sit outside the original three-call measurement block.
@MainActor private final class RITCCaptureRunner {
    private let nonce: String
    private var commandToken: Int32 = -1
    private var ackToken: Int32 = -1
    private var sequence: UInt64 = 0
    private var currentCommand: UInt64 = 0
    private var finished = false
    private(set) var invocations = 0
    private var acknowledgements: [UInt64] = []

    init(app: XCUIApplication) throws {
        let env = ProcessInfo.processInfo.environment
        guard let nonce = env["RITC_CAPTURE_NONCE"], nonce.count == 32,
              nonce.allSatisfy({ $0.isHexDigit }), let device = env["RITC_CAPTURE_DEVICE"],
              UUID(uuidString: device)?.uuidString == device,
              env["SIMULATOR_UDID"]?.uppercased() == device else {
            throw NSError(domain: "RITCCapture.missing_reviewed_run_environment", code: 1)
        }
        self.nonce = nonce
        guard notify_register_check("dev.roominthecart.capture.\(nonce).command", &commandToken) == 0,
              notify_register_check("dev.roominthecart.capture.\(nonce).ack", &ackToken) == 0,
              notify_set_state(commandToken, 0) == 0 else {
            if commandToken >= 0 { notify_cancel(commandToken) }
            if ackToken >= 0 { notify_cancel(ackToken) }
            throw NSError(domain: "RITCCapture.notification_registration", code: 2)
        }
        app.launchEnvironment["RITC_CAPTURE_NONCE"] = nonce
        app.launchEnvironment["RITC_CAPTURE_DEVICE"] = device
        app.launchEnvironment["RITC_CAPTURE_RUNNER_PID"] = String(getpid())
    }

    private func exchange(_ phase: UInt64, ordinal: Int = 0, seconds: Double) throws {
        guard sequence < 0x00ff_ffff, (0...16).contains(ordinal) else {
            throw NSError(domain: "RITCCapture.protocol_bound", code: 3)
        }
        sequence += 1
        let command = phase | (sequence << 8) | (UInt64(ordinal) << 32)
        currentCommand = command
        guard notify_set_state(commandToken, command) == 0,
              notify_post("dev.roominthecart.capture.\(nonce).command") == 0 else {
            throw NSError(domain: "RITCCapture.command_send", code: 4)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            var ack: UInt64 = 0
            guard notify_get_state(ackToken, &ack) == 0 else {
                throw NSError(domain: "RITCCapture.ack_read", code: 5)
            }
            if ack >> 56 == 2 { throw NSError(domain: "RITCCapture.app_reported_failure", code: 6) }
            if ack == (command | (UInt64(1) << 56)) {
                acknowledgements.append(ack); return
            }
            if ack >> 56 > 2 { throw NSError(domain: "RITCCapture.ack_encoding", code: 7) }
            usleep(10_000)
        }
        abort()
        throw NSError(domain: "RITCCapture.ack_deadline", code: 8)
    }

    func awaitCollector() throws { try exchange(1, seconds: 35) }
    func begin() -> Bool {
        do {
            invocations += 1
            try exchange(2, ordinal: invocations, seconds: 2)
            return true
        } catch { abort(); XCTFail("App capture BEGIN failed: \(error)"); return false }
    }
    func end() -> Bool {
        do { try exchange(3, ordinal: invocations, seconds: 2); return true }
        catch { abort(); XCTFail("App capture END failed: \(error)"); return false }
    }
    func finish() throws {
        try exchange(4, ordinal: invocations, seconds: 105)
        finished = true
    }
    func report() -> [String: Any] {
        ["diagnosticOnly": true, "releaseAcceptance": false, "nonce": nonce,
         "runnerPID": getpid(), "invocations": invocations, "acknowledgements": acknowledgements,
         "finished": finished, "scope": "Outer app coverage envelopes, not XCTest sample durations or indexes"]
    }
    private func abort() {
        guard commandToken >= 0, !finished else { return }
        // A pending host gate re-reads this changed command and emits an explicit failure ACK.
        let abortCommand = (currentCommand & ~UInt64(0xff)) | 5
        _ = notify_set_state(commandToken, abortCommand)
        _ = notify_post("dev.roominthecart.capture.\(nonce).command")
    }
    func close() {
        if !finished { abort() }
        if commandToken >= 0 { notify_cancel(commandToken); commandToken = -1 }
        if ackToken >= 0 { notify_cancel(ackToken); ackToken = -1 }
    }
}
#endif
