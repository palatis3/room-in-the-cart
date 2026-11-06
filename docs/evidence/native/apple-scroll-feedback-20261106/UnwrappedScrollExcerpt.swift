// Verbatim method excerpts from ios/UITests/ReleasePerformanceUITests.swift
// Same file bytes at all three commits in evidence-map.json.
// Context required: enclosing XCTestCase, XCUIApplication app, native 500-item importFixture(), screenshot().
// This is not a standalone reproduction project; no new test was created or run.

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

    private func measurementOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }
