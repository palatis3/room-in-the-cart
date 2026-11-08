#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Dedicated isolated fixture build only; normal full-suite builds contain no S24 fixture test.
@MainActor final class HouseholdRequestPackUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
        app.launchEnvironment["S24_PACK_TRACE_SCOPE"] = name
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("S24-request-pack-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "S24-failure-accessibility-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let diagnostics = element("fixture.s24.preview-diagnostics")
            let snapshot = XCTAttachment(string: diagnostics.exists ? diagnostics.label : "S24 fixture diagnostics unavailable")
            snapshot.name = "S24-failure-preview-diagnostics"; snapshot.lifetime = .keepAlways; add(snapshot)
        }
        app.terminate()
    }
    func testShopperCarriesEarlierRequestOnceAndReviewsCurrentPackPrice() throws {
        app.launchArguments = ["--ui-testing", "--request-pack-fixture", "--deferred-request-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let open = element("household.deferred.open")
        let source = element("household.deferred.88888888-5555-4555-8555-555555555555")
        let successor = element("household.request.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertFalse(successor.exists)
        tap(open)
        tap(source)
        assertText("8 wraps")
        tap(element("household.deferred.keep"))
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")

        tap(source)
        tap(element("household.deferred.confirm"))
        let retry = app.buttons["Retry the same decision"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(retry.isEnabled)
        tap(app.buttons["Refresh current requests"])
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 1")
        let eligible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [eligible], timeout: 12), .completed)
        tap(retry)
        reveal(successor)
        XCTAssertTrue(successor.waitForExistence(timeout: 8))
        XCTAssertTrue(successor.label.contains("From an earlier pickup"))
        XCTAssertEqual(element("household.request.outcome.44444444-4444-4444-8444-444444444444").label, "Received, waiting for review")
        XCTAssertEqual(app.buttons.matching(identifier: successor.identifier).count, 1)
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 2")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
        tap(open)
        assertText("No earlier requests are waiting for this pickup.")
        tap(app.navigationBars["Saved from earlier pickups"].buttons.firstMatch)

        func openAddDecision() {
            tap(successor)
            tap(element("household.decision.choice"))
            tap(app.buttons["Add packs to this shop"])
        }
        openAddDecision()
        let price = element("household.decision.price")
        reveal(price)
        XCTAssertTrue((price.value as? String ?? "").isEmpty || price.value as? String == price.placeholderValue)
        reveal(price, fullyVisible: true)
        let promptImage = XCTAttachment(screenshot: price.screenshot())
        promptImage.name = "S24-empty-price-prompt"; promptImage.lifetime = .keepAlways; add(promptImage)
        let promptFrame = XCTAttachment(string: price.debugDescription)
        promptFrame.name = "S24-empty-price-prompt-frame"; promptFrame.lifetime = .keepAlways; add(promptFrame)
        try assertReadableContrast(price)
        tap(element("household.decision.review"))
        let apply = element("household.decision.apply")
        let missingPrice = app.staticTexts["At least one line price is unknown."]
        reveal(missingPrice, fullyVisible: true)
        XCTAssertTrue(missingPrice.isHittable)
        capture("S24-unknown-price-visible-without-expanding-details")
        let details = app.buttons["household.decision.checkoutDetails"]
        reveal(details)
        XCTAssertEqual(details.value as? String, "Collapsed")
        reveal(apply)
        XCTAssertFalse(apply.isEnabled)
        try assertDisabledApplyRejectsActivation(apply, name: "S24-unknown-price-disabled-apply")
        tap(element("household.decision.cancel"))
        XCTAssertTrue(successor.waitForExistence(timeout: 5))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 2")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
        openAddDecision()
        reveal(price, fullyVisible: true)
        price.tap()
        price.typeText("4.25")
        dismissKeyboardIfPresent()
        tap(element("household.decision.review"))
        assertElementContains("household.decision.after-total", "$4.25")
        reveal(apply); XCTAssertTrue(apply.isEnabled)
        tap(apply)
        assertReturnedToConfirmedRequest()
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 1")
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 3")
    }

    func testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite() throws {
        openCerealReview()
        let sam = element("household.decision.meal.88888888-8888-4888-8888-888888888888")
        let mia = element("household.decision.meal.99999999-9999-4999-8999-999999999999")
        // Require one actual viewport with both current/proposed checkout and
        // the two named commitments, rather than finding each after scrolling.
        let feeBasis = element("household.decision.feeBasis")
        let context = [element("household.decision.after-total"), element("household.decision.over-cap"), element("household.decision.before-total"), feeBasis, sam, mia]
        revealTogether(context)
        for target in context {
            XCTAssertTrue(target.exists && target.isHittable, target.debugDescription)
        }
        XCTAssertEqual(feeBasis.label, "Fixed retailer fee: $1.99.")
        XCTAssertTrue(element("household.decision.before-total").label.contains("$37.20"))
        XCTAssertTrue(element("household.decision.after-total").label.contains("$40.69"))
        XCTAssertTrue(element("household.decision.over-cap").label.contains("$2.69"))
        XCTAssertTrue(sam.label.contains("Sam’s wrap lunch") && sam.label.contains("Protected portions") && sam.label.contains("1"))
        XCTAssertTrue(mia.label.contains("Mia’s wrap lunch") && mia.label.contains("Protected portions") && mia.label.contains("1"))
        capture("S24-cereal-checkout-with-two-named-protected-lunches")
        let total = element("household.decision.after-total").staticTexts["$40.69"]
        centerForReading(total)
        try assertReadableContrast(total)
        let guidance = app.staticTexts["Check usable food separately; this review does not confirm meal coverage."]
        centerForReading(guidance)
        try assertReadableContrast(guidance)
        tap(element("household.decision.cancel"))
        let request = element("household.request.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertEqual(element("household.request.outcome.44444444-4444-4444-8444-444444444444").label, "Received, waiting for review")
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
        tap(element("fixture.s24.end-access"))
        XCTAssertTrue(app.staticTexts["Shopper access has ended. Return to household settings."].waitForExistence(timeout: 10))
        XCTAssertFalse(request.exists); XCTAssertFalse(sam.exists); XCTAssertFalse(mia.exists)
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        capture("S24-shopper-access-ended-clears-private-context")
    }
    func testShopperOpensCheckoutCalculationsAndIncludedChargesWithNoDecisionWrite() {
        if #unavailable(iOS 18) { app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable" }
        openCerealReview()
        XCTAssertTrue(element("household.decision.after-total").label.contains("$40.69"))
        let outer = app.buttons["household.decision.checkoutDetails"]
        let inner = app.buttons["household.decision.includedCharges"]
        func open(_ button: XCUIElement, label: String) {
            reveal(button, fullyVisible: true)
            XCTAssertEqual(button.label, label)
            XCTAssertEqual(button.value as? String, "Collapsed")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThan(button.frame.width, app.frame.width / 2)
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            XCTAssertEqual(button.value as? String, "Expanded")
        }
        XCTAssertFalse(inner.exists)
        open(outer, label: "Checkout calculation details")
        let revision = app.staticTexts["Shop revision, 1"]
        reveal(revision)
        XCTAssertTrue(revision.isHittable)
        open(inner, label: "Included charges and discounts")
        let charges = ["Retailer fee, $1.99", "Tax, $0.75", "Deposits, $0.10", "Discounts, $0.49"]
        for charge in charges {
            let row = app.staticTexts[charge]
            centerForReading(row)
            XCTAssertTrue(row.isHittable)
            XCTAssertEqual(row.label, charge)
        }
        capture("S23-shopper-itemized-checkout-details")
        let apply = element("household.decision.apply")
        reveal(apply)
        XCTAssertFalse(apply.isEnabled, "Opening the calculation cannot accept the overage")
        tap(element("household.decision.cancel"))
        XCTAssertTrue(element("household.request.44444444-4444-4444-8444-444444444444").waitForExistence(timeout: 5))
        tap(element("fixture.s24.end-access"))
        XCTAssertTrue(app.staticTexts["Shopper access has ended. Return to household settings."].waitForExistence(timeout: 10))
        XCTAssertFalse(outer.exists); XCTAssertFalse(inner.exists)
        for charge in charges { XCTAssertFalse(app.staticTexts[charge].exists) }
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
    }

    func testLargestTextShowsCompleteProtectedLunchNamesAndDates() throws {
        openCerealReview(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let dates = ["Lunch · November 4, 2026", "Lunch · November 5, 2026"]
        let meals = [("88888888-8888-4888-8888-888888888888", "Sam’s wrap lunch"),
                     ("99999999-9999-4999-8999-999999999999", "Mia’s wrap lunch")]
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        for ((id, name), date) in zip(meals, dates) {
            let row = element("household.decision.meal." + id)
            centerForReading(row)
            XCTAssertTrue(row.label.contains(name) && row.label.contains(date) && row.label.contains("Protected portions, 1"))
            for (label, style) in [(name, UIFont.TextStyle.subheadline), (date, .caption1)] {
                let text = row.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
                XCTAssertTrue(text.exists, label)
                let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
                let needed = (label as NSString).boundingRect(with: CGSize(width: row.frame.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
                XCTAssertGreaterThanOrEqual(text.frame.height + 2, needed.height, label)
            }
            capture("Largest text " + name)
        }
        try assertDisabledApplyRejectsActivation(element("household.decision.apply"), name: "S24-largest-disabled-apply")
        centerForReading(app.buttons["Cancel preview"])
        capture("Largest text review actions")
        tap(element("household.decision.cancel"))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
    }

    // Measure the ink and background of this visible, single-color text element.
    // Ignore the outermost 1% of values so individual antialiasing pixels cannot pass it.
    private func assertReadableContrast(_ text: XCUIElement) throws {
        try assertReadableContrast(try XCTUnwrap(text.screenshot().image.cgImage), label: text.label)
    }

    private func assertReadableContrast(_ image: CGImage, label: String) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        let linear = (0...255).map { byte -> Double in
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = (0..<(image.width * image.height)).map { pixel in
            let index = pixel * 4
            return 0.2126 * linear[Int(bytes[index])] + 0.7152 * linear[Int(bytes[index + 1])]
                + 0.0722 * linear[Int(bytes[index + 2])]
        }.sorted()
        let trim = luminance.count / 100
        let contrast = (luminance[luminance.count - 1 - trim] + 0.05) / (luminance[trim] + 0.05)
        XCTAssertGreaterThanOrEqual(contrast, 4.5, label)
    }

    private func assertDisabledApplyRejectsActivation(_ button: XCUIElement, name: String) throws {
        reveal(button, fullyVisible: true)
        XCTAssertEqual(button.elementType, .button)
        XCTAssertEqual(button.label, "Apply reviewed decision")
        XCTAssertFalse(button.isEnabled)
        let full = button.screenshot()
        let image = try XCTUnwrap(full.image.cgImage)
        let frame = button.frame
        // The native Form can include horizontal row padding in the button frame.
        // Remove that padding plus the rounded outline; measure only central label ink/surface.
        XCTAssertGreaterThan(frame.width, 64)
        XCTAssertGreaterThan(frame.height, 32)
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height
        let crop = CGRect(x: ceil(32 * scaleX), y: ceil(16 * scaleY),
                          width: floor((frame.width - 64) * scaleX), height: floor((frame.height - 32) * scaleY))
        let interior = try XCTUnwrap(image.cropping(to: crop))
        let fullAttachment = XCTAttachment(screenshot: full)
        fullAttachment.name = name + "-whole-button"; fullAttachment.lifetime = .keepAlways; add(fullAttachment)
        let labelAttachment = XCTAttachment(image: UIImage(cgImage: interior))
        labelAttachment.name = name + "-label-interior"; labelAttachment.lifetime = .keepAlways; add(labelAttachment)
        let state = XCTAttachment(string: "\(button.debugDescription)\nlabelInteriorPixels=\(crop); sourcePixels=\(image.width)x\(image.height)")
        state.name = name + "-disabled-state-and-crop"; state.lifetime = .keepAlways; add(state)
        try assertReadableContrast(interior, label: button.label)
        // Send a physical tap rather than asking XCTest to activate a disabled AX element.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(button.exists)
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(element("household.decision.cancel").exists)
    }

    func testUnavailableMealFactsRemainUnknownInRequestDecision() {
        openCerealReview(extraArguments: ["--request-meals-unknown"])
        let unknown = element("household.decision.meals.unknown")
        reveal(unknown)
        XCTAssertTrue(unknown.label.contains("Meal commitments are unavailable"))
        XCTAssertFalse(element("household.decision.meal.88888888-8888-4888-8888-888888888888").exists)
        XCTAssertFalse(element("household.decision.meal.99999999-9999-4999-8999-999999999999").exists)
        capture("S24-unavailable-meal-commitments-stay-unknown")
        tap(element("household.decision.cancel"))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
    }
    private func openCerealReview(extraArguments: [String] = []) {
        app.launchArguments = ["--ui-testing", "--request-pack-fixture", "--request-meal-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        app.launch()
        let request = element("household.request.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 20))
        for _ in 0..<8 where !request.exists { app.collectionViews.firstMatch.swipeUp() }
        tap(request)
        tap(element("household.decision.choice"))
        let add = app.buttons["Add packs to this shop"]
        // At AX5 the native menu opens scrolled to its selected option.
        let selected = app.buttons["Save for next shop"]
        if add.exists && !add.isHittable && selected.isHittable {
            let start = selected.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)))
        }
        tap(add)
        fill("3.49", into: "household.decision.price", replacing: true)
        dismissKeyboardIfPresent()
        let review = element("household.decision.review")
        centerForReading(review)
        review.tap()
        reveal(element("household.decision.after-total"))
    }
    func testReviewedCheapestAvailablePackUsesActualDecisionAndCancelHasNoWrite() throws {
        app.launchArguments = ["--ui-testing", "--request-pack-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let request = element("household.request.44444444-4444-4444-8444-444444444444")
        XCTAssertTrue(request.waitForExistence(timeout: 20)); tap(request)
        let cancel = element("household.decision.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); tap(cancel)
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 0")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 0")
        tap(request)
        tap(element("household.decision.choice")); tap(app.buttons["Add packs to this shop"])
        let comparePacks = app.buttons["household.pack.open"]
        reveal(comparePacks, fullyVisible: true)
        XCTAssertEqual(comparePacks.label, "Compare available packs for this request")
        XCTAssertEqual(comparePacks.value as? String, "Collapsed")
        XCTAssertGreaterThanOrEqual(comparePacks.frame.height, 44)
        XCTAssertGreaterThan(comparePacks.frame.width, app.frame.width / 2)
        comparePacks.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertEqual(comparePacks.value as? String, "Expanded")
        fill("8", into: "household.pack.need", replacing: true)
        for (id, yield, price) in [("a", "4", "3.00"), ("b", "6", "4.00")] {
            fill("Reviewed pack " + id, into: "household.pack.\(id).label", replacing: true)
            fill(yield, into: "household.pack.\(id).usable", replacing: true)
            fill(price, into: "household.pack.\(id).price", replacing: true)
            tap(element("household.pack.\(id).availability")); tap(app.buttons["Available"])
            fill("Reviewed shelf " + id, into: "household.pack.\(id).source", replacing: true)
            enableSwitch("household.pack.\(id).matched")
        }
        tap(element("household.pack.compare"))
        assertText("Cheapest sufficient option among reviewed available packs with known prices")
        capture("S24-reviewed-available-pack-result")
        let use = element("household.pack.use.a"); reveal(use); XCTAssertTrue(use.isEnabled); tap(use)
        tap(element("household.decision.review"))
        let apply = element("household.decision.apply"); reveal(apply); XCTAssertFalse(apply.isEnabled)
        try assertDisabledApplyRejectsActivation(apply, name: "S24-overage-disabled-apply")
        assertText("Reviewed shelf a")
        assertText("After this decision")
        capture("S24-actual-household-preview-before-overage-approval")
        enableSwitch("household.decision.overage")
        reveal(apply); XCTAssertTrue(apply.isEnabled); tap(apply)
        assertReturnedToConfirmedRequest()
        capture("S23-updated-original-request-after-confirmed-apply")
        XCTAssertEqual(element("fixture.s24.posts").label, "Fixture applied decisions: 1")
        XCTAssertEqual(element("fixture.s24.lines").label, "Fixture saved lines: 1")
        capture("S23-request-returned-once-without-manual-dismissal")
    }
    private func assertReturnedToConfirmedRequest(file: StaticString = #filePath, line: UInt = #line) {
        let cancel = element("household.decision.cancel")
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
                       "Confirmed Apply must return without another Cancel tap", file: file, line: line)
        let request = element("household.request.44444444-4444-4444-8444-444444444444")
        let outcome = element("household.request.outcome.44444444-4444-4444-8444-444444444444")
        // Do not scroll here: returning from the sheet must expose the original row.
        XCTAssertTrue(request.exists && request.isHittable, file: file, line: line)
        XCTAssertTrue(outcome.exists && outcome.isHittable, file: file, line: line)
        XCTAssertEqual(outcome.label, "Added to the plan", file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: request.identifier).count, 1, file: file, line: line)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        dismissKeyboardIfPresent()
        reveal(control, fullyVisible: true)
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        let field = app.textFields.matching(NSPredicate(format: "identifier == %@", id)).firstMatch
        // A partially clipped field can report hittable on the smaller iOS 17 screen.
        reveal(field, fullyVisible: true); tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func dismissKeyboardIfPresent() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let bounds = app.frame, area = scrollableArea()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 8, dy: area.minY + area.height * 0.25 - bounds.minY))
        let end = origin.withOffset(CGVector(dx: 8, dy: bounds.height - 30))
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    private func reveal(_ target: XCUIElement, fullyVisible: Bool = false) {
        for attempt in 0..<24 {
            let area = scrollableArea()
            // The gesture safety margin is not an obstruction over visible content.
            let visibleArea = fullyVisible ? scrollableArea(bottomInset: 16) : area
            if target.exists && target.isHittable &&
                (!fullyVisible || (target.frame.minY >= visibleArea.minY && target.frame.maxY <= visibleArea.maxY)) { return }
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            scrollContent(upward: upward)
        }
        let area = scrollableArea(bottomInset: fullyVisible ? 16 : 100)
        XCTAssertTrue(target.exists && target.isHittable &&
            (!fullyVisible || (target.frame.minY >= area.minY && target.frame.maxY <= area.maxY)),
            "Missing fully actionable UI element: \(target.debugDescription)")
    }
    private func centerForReading(_ target: XCUIElement) {
        reveal(target)
        let area = scrollableArea()
        let center = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: area.midX - app.frame.minX, dy: area.midY - app.frame.minY))
        for _ in 0..<12 {
            let frame = target.frame
            if frame.minY >= area.minY && frame.maxY <= area.maxY { return }
            let offset = max(-area.height * 0.4, min(frame.midY - area.midY, area.height * 0.4))
            center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -offset)),
                         withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        XCTFail("Could not show the whole reading target: " + target.debugDescription)
    }
    private func revealTogether(_ targets: [XCUIElement]) {
        guard let first = targets.first, let last = targets.last else { return }
        reveal(last)
        for _ in 0..<16 {
            if targets.allSatisfy({ $0.exists && $0.isHittable }) { return }
            // Fine positioning avoids a whole-cell scroll hiding the first
            // amount after the second lunch becomes visible.
            scrollContent(upward: first.exists && first.isHittable, amount: 0.12)
        }
    }
    private func scrollableArea(bottomInset: CGFloat = 100) -> CGRect {
        let bounds = app.frame
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY }.min() ?? bounds.maxY
        let barBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame.maxY }.max() ?? bounds.minY + 88
        let top = max(bounds.minY + 88, min(barBottom + 12, keyboardTop - 140))
        let bottom = min(bounds.maxY - bottomInset, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool, amount: CGFloat = 0.6) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = scrollableArea(), bounds = app.frame
        let high = area.midY - area.height * amount / 2, low = area.midY + area.height * amount / 2
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY))
        let end = origin.withOffset(CGVector(dx: area.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func assertText(_ text: String) {
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reveal(target); XCTAssertTrue(target.exists && target.isHittable, "Missing visible text: \(text)")
    }
    private func assertElementContains(_ id: String, _ text: String) {
        let target = element(id); reveal(target); XCTAssertTrue(target.label.contains(text), target.label)
    }
    private func choose(_ label: String, value: String) {
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch)
        tap(app.buttons[value])
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
