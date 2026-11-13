import XCTest

@MainActor final class CookRenderDiagnosticUITests: XCTestCase {
    func testRenderOneInstalledEnglishFixtureWithoutPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["render.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        let status = app.staticTexts["render.status"]
        let terminal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && !["ready", "rendering"].contains(status.label)
        }, object: nil)
        let wait = XCTWaiter.wait(for: [terminal], timeout: 35)
        let metadata = app.staticTexts["render.metadata"]
        let json = metadata.exists ? metadata.label : "{\"status\":\"metadata-unavailable\"}"
        let attachment = XCTAttachment(data: Data(json.utf8), uniformTypeIdentifier: "public.json")
        attachment.name = "CookRenderMetadata.json"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(wait, .completed, "The independent watchdog or render owner must report; timeout is failure")
        guard wait == .completed else { return }
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(receipt["status"] as? String, "observed-end")
        XCTAssertEqual(receipt["fixtureSHA256"] as? String,
                       "2704786f1a091e0ff325e09861304582ef3849ead4c47809e93629628a90c1ef")
        XCTAssertEqual(receipt["locale"] as? String, "en-US")
        XCTAssertEqual(receipt["requestedOwnerQoS"] as? String, "default")
        let events = try XCTUnwrap(receipt["events"] as? [[String: Any]])
        for name in ["owner-start", "write-call"] {
            let event = try XCTUnwrap(events.first { $0["event"] as? String == name })
            XCTAssertEqual(event["mainThread"] as? Bool, false)
            XCTAssertEqual(event["reportedQoSClass"] as? NSNumber, receipt["defaultQoSClass"] as? NSNumber)
        }
        XCTAssertEqual(receipt["completionIsObservationOnly"] as? Bool, true)
        XCTAssertEqual(receipt["playerOrEngineCreated"] as? Bool, false)
        XCTAssertEqual(receipt["audioSessionExplicitlyActivated"] as? Bool, false)
        XCTAssertEqual(receipt["matchingFinishObserved"] as? Bool, true)
        XCTAssertEqual(receipt["matchingCancelObserved"] as? Bool, false)
        XCTAssertEqual((receipt["terminalCount"] as? NSNumber)?.intValue, 1)
        XCTAssertGreaterThan((receipt["zeroBuffers"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertGreaterThan((receipt["writtenFrames"] as? NSNumber)?.uint64Value ?? 0, 0)
        XCTAssertEqual(receipt["callbackFrames"] as? NSNumber, receipt["writtenFrames"] as? NSNumber)
        XCTAssertEqual(receipt["callbackBytes"] as? NSNumber, receipt["writtenBytes"] as? NSNumber)
        XCTAssertEqual((receipt["pendingCopiesAtReport"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((receipt["lateCallbacksBeforeReport"] as? NSNumber)?.intValue, 0)
        XCTAssertLessThanOrEqual((receipt["peakCopies"] as? NSNumber)?.intValue ?? Int.max, 2)
        XCTAssertLessThanOrEqual((receipt["peakCopyBytes"] as? NSNumber)?.intValue ?? Int.max, 1_048_576)
        XCTAssertLessThanOrEqual((receipt["peakFileBytes"] as? NSNumber)?.intValue ?? Int.max, 33_554_432)
        XCTAssertEqual(receipt["fileRemoved"] as? Bool, true)
        XCTAssertEqual(receipt["nativeReferencesReleased"] as? Bool, true)
        XCTAssertTrue(receipt["error"] is NSNull)
        XCTAssertFalse(start.isEnabled, "A launch admits exactly one generation; there is no retry button")
        // This asserts finite observed rendering only. The unchanged strict checker independently
        // decides runtime-warning acceptance; neither this test nor a zero buffer grants EOF proof.
    }
}
