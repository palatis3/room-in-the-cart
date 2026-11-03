import XCTest

/// Visible navigation on an isolated Free workspace, without seeded account authority.
@MainActor final class ContextualNavigationUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("Contextual-navigation-failure") }
        app.terminate()
    }

    func testUnknownProduceWeightUsesSavedWholePickupCapAndBillingIncrement() {
        enterWeighedPickup(knownTax: true)
    }

    func testUnknownTaxKeepsWeighedPickupUnresolved() {
        enterWeighedPickup(knownTax: false)
    }

    private func enterWeighedPickup(knownTax: Bool) {
        launch(reset: true)
        shopRoot(); tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Weighed produce", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport")); fill("1 apples\n1 rice", into: "ledgerImportText")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"]); tap(app.buttons["Continue to checkout review"])
        tap(app.buttons["Apply reviewed checkout copy"]); tap(app.buttons["Review whole checkout"])
        fill("Family market", into: "Store", replacing: true)
        fill("Main branch", into: "Branch", replacing: true)
        fill("Tuesday 5 PM", into: "Pickup or delivery slot", replacing: true)
        fill("Retailer quote", into: "Source of these prices", replacing: true)
        fill("38", into: "Spending cap", replacing: true)
        fill("34", into: "rice")
        fill("0", into: "Fee below threshold or fixed fee")
        fill("0", into: "Eligible discount")
        fill("0", into: "Deposits and other charges")
        if knownTax { fill("0", into: "Tax") }
        tap(app.buttons["Save and evaluate checkout"])
        tap(element("checkout.weightReview"))
        tap(element("checkout.weightLine")); tap(app.buttons["apples"])
        fill("2", into: "checkout.weightRate"); fill("0.01", into: "checkout.weightIncrement")
        if !knownTax {
            reveal(element("checkout.weightUnresolved"))
            capture("S05-unknown-tax-keeps-weight-conditional")
            return
        }
        let result = element("checkout.maximumWeight")
        reveal(result)
        XCTAssertTrue(result.label.contains("2 pounds") || (result.value as? String)?.contains("2 pounds") == true, result.debugDescription)
        for (id, amount) in [("checkout.maximumLineCharge", "$4.00"), ("checkout.maximumTotal", "$38.00")] {
            let row = element(id)
            reveal(row)
            XCTAssertTrue(row.label.contains(amount) || (row.value as? String)?.contains(amount) == true, row.debugDescription)
        }
        capture("S05-billed-weight-under-saved-cap")
        tap(app.navigationBars["Check price by weight"].buttons["Whole checkout"])
        XCTAssertTrue(app.navigationBars["Whole checkout"].waitForExistence(timeout: 5))
        let price = app.textFields["apples"]
        reveal(price)
        XCTAssertTrue(price.value as? String == price.placeholderValue || price.value as? String == "", price.debugDescription)
    }

    func testFreeContextualRoutesKeepPrivateAndSharedWorkSeparate() throws {
        launch(reset: true)
        XCTAssertFalse(element("shop.familyInbox").exists)
        tap(app.tabBars.buttons["Records"])
        XCTAssertFalse(element("records.managedViews").exists)
        shopRoot()
        tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Context route pickup", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport")); fill("2 wraps", into: "ledgerImportText")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"]); tap(app.buttons["Apply reviewed checkout copy"])
        tap(app.buttons["Review whole checkout"])
        tap(element("checkout.twoStoreQuotes"))
        XCTAssertTrue(app.navigationBars["Two store trips"].waitForExistence(timeout: 8))
        assertText("Same commitments at both stores")
        capture("Checkout-direct-two-store-quotes")
        backOnce(from: "Two store trips", to: "Whole checkout")
        fill("Family market", into: "Store", replacing: true)
        fill("Main branch", into: "Branch", replacing: true)
        fill("Tuesday 5 PM", into: "Pickup or delivery slot", replacing: true)
        fill("Retailer preview", into: "Source of these prices", replacing: true)
        enableSwitch("Retailer total already includes all charges")
        fill("3.00", into: "Inclusive total")
        tap(app.buttons["Save and evaluate checkout"])
        backOnce(from: "Whole checkout", to: "Pickup")
        tap(app.buttons["Prepare retailer handoff"])
        tap(app.buttons["Freeze reviewed basket"]); tap(app.buttons["I placed this order"])
        backOnce(from: "Retailer handoff", to: "Pickup")
        tap(app.buttons["Tell the cook"])
        tap(element("cook.currentSharedView"))
        assertText("Your private cook note is not copied here")
        XCTAssertFalse(element("cook.openSharedComposer").exists)
        capture("Cook-distinct-private-copy-and-current-view")
        backOnce(from: "Current shared view", to: "Tell the cook")
        backOnce(from: "Tell the cook", to: "Pickup")
        tap(app.buttons["Start the next shop"])
        tap(app.buttons["Cancel"])
        XCTAssertTrue(app.buttons["Start the next shop"].waitForExistence(timeout: 8))
        tap(app.buttons["Start the next shop"])
        tap(app.buttons["Create fresh next-shop draft"])
        tap(element("nextShop.reuseDinner"))
        XCTAssertTrue(app.navigationBars["Dinner library"].waitForExistence(timeout: 10))
        assertText("One accepted dinner can be your Free reusable dinner")
        assertText("No accepted dinners yet.")
        XCTAssertTrue(element("ledgerNewTemplate").exists)
        capture("Next-shop-direct-Free-dinner-library")
    }

    func testEnteredStoreQuotesKeepTripCostsSeparateAndAdoptOnlyReviewedSavedProof() {
        launch(reset: true)
        tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Saturday quote review", into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(element("ledgerImport")); fill("2 wraps", into: "ledgerImportText")
        tap(element("ledgerReviewImport")); tap(element("ledgerCommitImport"))
        shopRoot(); tap(app.buttons["Review checkout"])
        tap(app.buttons["Continue to checkout review"]); tap(app.buttons["Apply reviewed checkout copy"])
        tap(app.buttons["Review whole checkout"]); tap(element("checkout.twoStoreQuotes"))

        fillQuote("Dinner and protected lunch", into: "Commitment name")
        fillQuote("3", into: "Required portions")
        func enterStore(_ slot: String, name: String, branch: String, items: String, total: String, terms: String, cash: String?, minutes: String) {
            let prefix = "quote." + slot + "."
            fillQuote(name, into: prefix + "label")
            fillQuote(name, into: prefix + "storeID")
            fillQuote(branch, into: prefix + "branch")
            fillQuote("Customer entered quote", into: prefix + "source")
            fillQuote(items, into: prefix + "itemSubtotal")
            fillQuote(terms, into: prefix + "eligibilityTerms")
            fillQuote(total, into: prefix + "total")
            enableSwitch(prefix + "allChargesIncluded")
            enableSwitch(prefix + "quantitiesMatched")
            enableSwitch(prefix + "singleStore")
            tap(element(prefix + "availability")); tap(app.buttons["Reviewed available"])
            if let cash { fillQuote(cash, into: prefix + "tripCash") }
            fillQuote(minutes, into: prefix + "extraMinutes")
            if slot == "first" { enableSwitch(prefix + "alreadyPlanned") }
        }
        enterStore("first",name: "Market A",branch: "North branch",items: "36",total: "38",terms: "Pickup price",cash: "0",minutes: "0")
        enterStore("second",name: "Market B",branch: "East branch",items: "32",total: "35",terms: "Card price",cash: nil,minutes: "18")
        tapQuoteRow("Review two complete trips")
        assertText("Second trip cash break-even: $3.00")
        assertText("Total trip cash is unresolved")
        XCTAssertFalse(app.buttons["Preview using Market B"].exists)
        capture("S27-unknown-trip-break-even")

        let edit = app.buttons["quoteEditReviewed"]
        tap(edit)
        XCTAssertFalse(edit.exists)
        let cashField = app.textFields["quote.second.tripCash"]
        for _ in 0..<6 {
            if cashField.exists && cashField.isHittable { break }
            app.collectionViews.firstMatch.swipeUp(velocity: .fast)
        }
        fillQuote("4",into: "quote.second.tripCash")
        tapQuoteRow("Review two complete trips")
        let first = element("quoteFirstResult"), second = element("quoteSecondResult")
        reveal(first)
        for part in ["North branch","Pickup price","Items before fees and discounts: $36.00","Checkout: $38.00","Incremental trip cash: $0.00","Checkout plus incremental trip cash: $38.00"] { XCTAssertTrue(first.label.contains(part),first.label) }
        reveal(second)
        let reviewedSecondStore = second.label
        for part in ["East branch","Store slot:","Card price","Items before fees and discounts: $32.00","Checkout: $35.00","Incremental trip cash: $4.00","Checkout plus incremental trip cash: $39.00"] { XCTAssertTrue(second.label.contains(part),second.label) }
        assertText("Items before fees and discounts, second minus first: -$4.00")
        assertText("Checkout change, second minus first: -$3.00")
        assertText("Checkout plus trip cash, second minus first: $1.00")
        assertText("Extra minutes change: 18")
        capture("S27-complete-store-differences")
        XCTAssertFalse(app.buttons["Preview using Market B"].exists)
        tapQuoteRow("Save reviewed comparison")
        tapQuoteRow("Preview using Market B")
        assertText("East branch")
        let adoptedSlot = element("quoteAdoptionSlot")
        reveal(adoptedSlot)
        XCTAssertTrue(adoptedSlot.label.hasPrefix("Store slot: ") && reviewedSecondStore.contains(adoptedSlot.label),adoptedSlot.label)
        tap(element("dinnerCancelPreview"))
        XCTAssertFalse(app.staticTexts["Current pickup branch: East branch"].exists)
        tapQuoteRow("Preview using Market B"); tap(element("dinnerApply"))
        assertText("Current pickup branch: East branch")
        assertText("This saved comparison uses an earlier pickup revision.")
        let adoptAgain = app.buttons["Preview using Market B"]
        reveal(adoptAgain); XCTAssertFalse(adoptAgain.isEnabled)
        restart(); tap(app.tabBars.buttons["Dinners"]); tap(app.buttons["Compare two store trips"])
        assertText("Current pickup branch: East branch")
        tap(app.buttons["Market A and Market B"])
        assertText("This saved comparison uses an earlier pickup revision.")
        capture("S27-reopened-adopted-branch-and-dated-comparison")
    }

    func testMissingStorePricesAndAvailabilityRemainConditionalAfterSaving() {
        launch(reset: true)
        tap(app.tabBars.buttons["Dinners"]); tap(element("dinnerStartPickup"))
        fill("Unpriced pickup",into: "ledgerShopName"); tap(element("ledgerCreateShop"))
        tap(app.buttons["Compare two store trips"])
        fillQuote("Two dinners",into: "Commitment name"); fillQuote("2",into: "Required portions")
        for (slot,name) in [("first","A"),("second","B")] {
            let prefix = "quote." + slot + "."
            fillQuote(name,into: prefix + "label")
            fillQuote(name,into: prefix + "storeID")
            fillQuote("Main",into: prefix + "branch")
            fillQuote("Shopper note",into: prefix + "source")
            enableSwitch(prefix + "quantitiesMatched"); enableSwitch(prefix + "singleStore")
        }
        tapQuoteRow("Review two complete trips")
        assertText("Checkout change, second minus first: Unresolved")
        assertText("Required product availability is unknown or unavailable")
        assertText("Checkout terms are incomplete")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Second trip cash break-even:")).firstMatch.exists)
        tapQuoteRow("Save reviewed comparison")
        let adopt = app.buttons["Preview using B"]
        reveal(adopt)
        XCTAssertFalse(adopt.isEnabled)
        capture("S27-saved-unknown-availability-and-prices")
    }

    private func tapQuoteRow(_ id: String) {
        let row = app.buttons[id]
        let table = app.collectionViews.firstMatch
        let bounds = app.frame
        let top = bounds.minY + 85
        let tab = app.tabBars.buttons["Shop"]
        let bottom = tab.exists ? min(bounds.maxY,tab.frame.minY) - 4 : bounds.maxY - 8
        let viewport = CGRect(x: bounds.minX,y: top,width: bounds.width,height: bottom - top)
        for attempt in 0..<20 {
            if row.exists {
                let rect = row.frame
                if !rect.isEmpty && viewport.contains(CGPoint(x: rect.midX, y: rect.midY)) && row.isHittable { row.tap(); return }
                if !rect.isEmpty && rect.midY < viewport.minY { table.swipeDown(); continue }
            }
            if attempt < 14 { table.swipeUp() } else { table.swipeDown() }
        }
        XCTFail("Quote action did not scroll above the tab bar: " + id)
    }
    private func fillQuote(_ text: String, into id: String) {
        let field = app.textFields[id]
        tap(field)
        field.typeText(text)
        XCTAssertEqual(field.value as? String,text,id)
        let done = app.buttons["quoteKeyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 3) && done.isHittable)
        done.tap()
    }

    private func launch(reset: Bool) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-workspace") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Shop"].waitForExistence(timeout: 15))
    }
    private func restart() { app.terminate(); launch(reset: false) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ target: XCUIElement) { reveal(target); XCTAssertTrue(target.isHittable, target.debugDescription); target.tap() }
    private func enableSwitch(_ label: String) {
        let control = app.switches[label]
        reveal(control)
        if control.value as? String == "0" {
            // The accessibility frame includes the Form label. Tap the trailing switch itself.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, "1", "The reviewed switch must be on: \(label)")
    }
    private func fill(_ text: String, into id: String, replacing: Bool = false) {
        let field = element(id); tap(field)
        if replacing, let old = field.value as? String, old != field.placeholderValue { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        app.typeText(text)
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.exists && done.isHittable { done.tap() }
    }
    private func reveal(_ target: XCUIElement) {
        for attempt in 0..<24 {
            if target.exists && target.isHittable { return }
            let area = scrollableArea()
            let upward: Bool
            if target.exists && !target.frame.isEmpty {
                upward = target.frame.midY > area.midY
            } else { upward = attempt < 16 }
            scrollContent(upward: upward)
        }
        XCTAssertTrue(target.exists && target.isHittable, "Missing actionable UI element: \(target.debugDescription)")
    }
    private func scrollableArea() -> CGRect {
        let bounds = app.frame
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY }.min() ?? bounds.maxY
        // Navigation bar containers do not have an activation point during a sheet dismissal.
        let top = max(bounds.minY + 88, min(bounds.minY + 140, keyboardTop - 140))
        let bottom = min(bounds.maxY - 100, keyboardTop - 16)
        return CGRect(x: bounds.minX + 24, y: top, width: bounds.width - 48, height: max(80, bottom - top))
    }
    private func scrollContent(upward: Bool) {
        // Whole-app swipes can start on the software keyboard. Drag only in
        // the observed unobscured content, and still require real hittability.
        let area = scrollableArea(), bounds = app.frame
        let high = area.minY + area.height * 0.2, low = area.minY + area.height * 0.8
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
    private func dinnerRoot() { returnToVisibleAnchor(element("dinnerLibrary")) }
    private func shopRoot() {
        tap(app.tabBars.buttons["Shop"])
        returnToVisibleAnchor(element("newComparison"))
    }
    private func backOnce(from source: String, to destination: String) {
        let sourceBar = app.navigationBars[source]
        XCTAssertTrue(sourceBar.waitForExistence(timeout: 8))
        let destinationLabel = sourceBar.buttons[destination]
        let back = destinationLabel.exists ? destinationLabel : sourceBar.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        XCTAssertTrue(back.isHittable, back.debugDescription)
        back.tap()
        // Assert the navigation destination itself. An offscreen form button is
        // not an anchor: absence from the lazy tree must never pop another screen.
        XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 8))
    }
    private func returnToVisibleAnchor(_ target: XCUIElement) {
        for _ in 0..<8 {
            if target.exists {
                // A covered parent can still exist in the accessibility tree.
                // Scroll only to reveal it, and return only if it is actionable.
                for _ in 0..<2 {
                    if target.isHittable { return }
                    scrollContent(upward: true)
                }
                for _ in 0..<4 {
                    if target.isHittable { return }
                    scrollContent(upward: false)
                }
                if target.isHittable { return }
            }
            let leading = app.navigationBars.buttons.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && $0.identifier != "settings" && $0.frame.midX < app.frame.midX
            }.sorted { $0.frame.minX < $1.frame.minX }
            guard let button = leading.first else {
                XCTFail("No visible back control while returning to \(target)")
                return
            }
            button.tap()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Root or destination is not visible: \(target)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
