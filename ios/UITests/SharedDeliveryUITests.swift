#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class SharedDeliveryUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            capture.name = "Shared delivery failure"; capture.lifetime = .keepAlways; add(capture)
        }
        app.terminate()
    }

    private func launch(_ language: String, locale: String, cookCopies: Bool = false) {
        app.launchArguments = ["--ui-testing", "--shared-delivery-fixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if cookCopies { app.launchArguments.append("--shared-cook-copies-fixture") }
        app.launch()
        tap(app.buttons["sharedShop.deliveryEvidence"])
    }
    private func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if target.waitForExistence(timeout: 3), target.isHittable { return }
        for step in 0..<16 {
            let exists = target.exists
            if exists && target.isHittable { return }
            if exists && !target.frame.isEmpty {
                if target.frame.midY > app.frame.midY { app.swipeUp() } else { app.swipeDown() }
            } else if (step / 4).isMultiple(of: 2) { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(target.exists && target.isHittable, "Unable to reveal \(target)", file: file, line: line)
    }
    private func tap(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(target, file: file, line: line)
        target.tap()
    }
    private func assertFact(_ label: String, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS %@ AND (label CONTAINS %@ OR value CONTAINS %@)", label, value, value)).firstMatch
        reveal(row, file: file, line: line)
    }
    private func checkCookCopy(in title: String, fragments: [String], openShare: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) {
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "delivery.cook.")).firstMatch
        tap(link, file: file, line: line)
        let preview = app.staticTexts["delivery.cook.preview"]
        reveal(preview, file: file, line: line)
        let copy = preview.label
        for fragment in fragments {
            XCTAssertTrue(copy.contains(fragment), "Missing cook instruction: \(fragment)", file: file, line: line)
        }
        if openShare {
            tap(app.buttons["delivery.cook.share"], file: file, line: line)
            let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "header.closeButton", "Close")).firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, file: file, line: line)
            close.tap()
            reveal(preview, file: file, line: line)
            XCTAssertEqual(preview.label, copy, file: file, line: line)
        }
        tap(app.navigationBars[title].buttons.firstMatch, file: file, line: line)
    }
    private func enter(_ input: String, in field: XCUIElement) {
        tap(field)
        field.typeText(input)
    }
    private func hasUsable(_ text: String) -> Bool {
        let row = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "delivery.confirmed.", text, text)).firstMatch
        return row.waitForExistence(timeout: 8)
    }
    func testShopperSavesDatedCookCopyAndReopensRecipientSendRecord() {
        launch("en", locale: "en_US", cookCopies: true)
        tap(app.buttons["Delivered food by meal"])
        let occurrence = "AAAAAAA1-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        tap(app.buttons["delivery.cook." + occurrence])
        let preview = app.staticTexts["delivery.cook.preview"]
        reveal(preview)
        let reviewed = preview.label
        for fact in ["Lunch wraps", "School lunch", "Uncovered by deliveries: 2 units", "Beans soaked"] {
            XCTAssertTrue(reviewed.contains(fact), "Missing no-delivery meal fact: \(fact)")
        }
        tap(app.buttons["delivery.cook.save"])
        reveal(app.staticTexts["Dated copy saved"])

        let savedText = app.staticTexts["delivery.cook.savedText"]
        func openSavedCopy() {
            tap(app.buttons["delivery.cook.history"])
            tap(app.buttons["delivery.cook.saved.1"])
            reveal(savedText)
            XCTAssertEqual(savedText.label, reviewed)
        }
        openSavedCopy()
        tap(app.buttons["delivery.cook.savedShare"])
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "header.closeButton", "Close")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        close.tap()

        let recipient = app.textFields["delivery.cook.recipient"]
        let check = app.buttons["delivery.cook.checkRecipient"], mark = app.buttons["delivery.cook.markSent"]
        let last = app.descendants(matching: .any).matching(identifier: "delivery.cook.lastSent").firstMatch
        func assertFirstVersionSent() {
            reveal(last)
            let text = [last.label, last.value as? String ?? ""].joined(separator: " ")
            XCTAssertNotNil(text.range(of: #"\b1\b"#, options: .regularExpression), text)
            XCTAssertFalse(mark.exists)
        }
        enter("Fixture cook", in: recipient)
        recipient.typeText("\n")
        tap(check)
        reveal(app.staticTexts["No previous send recorded for this recipient."])
        XCTAssertFalse(last.exists)
        tap(mark)
        assertFirstVersionSent()

        tap(app.navigationBars.buttons.firstMatch)
        tap(app.navigationBars.buttons.firstMatch)
        openSavedCopy()
        enter("Fixture cook", in: recipient)
        recipient.typeText("\n")
        tap(check)
        assertFirstVersionSent()
    }
    func testShopperRecordsAndCorrectsDeliveryThenReopensIt() {
        launch("en", locale: "en_US")
        let save = app.buttons["Save to shared shop"]
        tap(app.buttons["Add a delivery"])
        tap(app.buttons["Ordered wraps"])
        enter("Kitchen wraps", in: app.textFields["Food that came home"])
        tap(save)
        tap(app.buttons["Record arrival"])
        app.switches["Arrival time known"].coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.5)).tap()
        enter("8", in: app.textFields["delivery.amount"])
        tap(save)
        tap(app.buttons["Record usable quantity"])
        enter("6", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("6 units"))
        tap(app.buttons["Record usable quantity"])
        enter(XCUIKeyboardKey.delete.rawValue + "7", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("7 units"))
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["sharedShop.deliveryEvidence"])
        XCTAssertTrue(hasUsable("7 units"))
        XCTAssertEqual(app.buttons.matching(identifier: "Record arrival").count, 1)
        let openMatches = app.buttons["Meal ingredient matches"], ingredient = app.buttons.containing(.staticText, identifier: "Tortillas").firstMatch
        tap(openMatches)
        tap(ingredient)
        let exclusions = app.descendants(matching: .any).matching(NSPredicate(format:
            "(label CONTAINS %@ OR value CONTAINS %@)", "sesame", "sesame")).firstMatch
        XCTAssertTrue(exclusions.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "School lunch")).firstMatch.exists)
        tap(app.buttons["Match this ingredient"])
        tap(app.buttons["Delivered food by meal"])
        let covered = app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "Covered by deliveries", "2 units", "2 units")).firstMatch
        XCTAssertTrue(covered.waitForExistence(timeout: 8))
        let missing = app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "Uncovered by deliveries", "0 units", "0 units")).firstMatch
        XCTAssertTrue(missing.exists)
        tap(app.buttons["Done"])
        let reviewReservation = app.buttons["Review amount to set aside for School lunch"]
        tap(openMatches)
        tap(ingredient)
        tap(reviewReservation)
        enter("2", in: app.textFields["delivery.reservation.amount"])
        tap(app.buttons["Save amount set aside"])
        tap(app.buttons["Record usable quantity"])
        enter(XCUIKeyboardKey.delete.rawValue + "1", in: app.textFields["delivery.amount"])
        tap(save)
        XCTAssertTrue(hasUsable("1 unit"))
        tap(app.buttons["Delivered food by meal"])
        assertFact("Amount set aside", "2 units")
        assertFact("Still backed by this delivery", "1 unit")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Set-aside lunch after a delivery correction"; evidence.lifetime = .keepAlways; add(evidence)
        checkCookCopy(in: "Tell the cook", fragments: ["Lunch wraps", "School lunch", "peanuts", "sesame", "Beans soaked", "Kitchen wraps",
                       "Amount set aside: 2 units", "Still backed by this delivery: 1 unit"], openShare: true)
        tap(app.buttons["Done"])
        tap(openMatches)
        tap(ingredient)
        reveal(app.buttons["Remove ingredient match"])
        XCTAssertFalse(app.buttons["Remove ingredient match"].isEnabled)
        tap(reviewReservation)
        tap(app.buttons["Release this reservation"])
        tap(app.buttons["Release amount set aside"])
        tap(openMatches)
        tap(ingredient)
        tap(app.buttons["Remove ingredient match"])
        tap(openMatches)
        tap(ingredient)
        reveal(app.buttons["Match this ingredient"])
    }
    func testSpanishShopperDistinguishesFractionalUsableFoodZeroAndUnknown() {
        launch("es", locale: "es_US")
        tap(app.buttons["Alimentos entregados por comida"])
        for (label, value) in [("Exclusiones de la comida", "peanuts"), ("Tiempo de preparación en minutos", "120"),
                               ("Pasos de preparación completados", "Beans soaked")] {
            assertFact(label, value)
        }
        reveal(app.staticTexts["Ninguna entrega está vinculada a este ingrediente."])
        tap(app.buttons["Listo"])
        let save = app.buttons["Guardar en la compra compartida"], record = app.buttons["Registrar cantidad utilizable"]
        let amount = app.textFields["delivery.amount"]
        tap(app.buttons["Agregar una entrega"])
        tap(app.buttons["Ordered wraps"])
        enter("Tortillas de maíz", in: app.textFields["Alimento que llegó"])
        tap(save)
        tap(app.buttons["Registrar llegada"])
        app.switches["Se conoce la hora de llegada"].coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.5)).tap()
        enter("1,5", in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("Cantidad sin resolver"))
        tap(record)
        enter("0,5", in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("1/2 unidades"))
        let matches = app.buttons["Correspondencias con ingredientes de las comidas"]
        let ingredient = app.buttons.containing(.staticText, identifier: "Tortillas").firstMatch
        tap(matches); tap(ingredient); tap(app.buttons["Vincular este ingrediente"])
        tap(matches); tap(ingredient)
        tap(app.buttons["Revisar cuánto apartar para School lunch"])
        enter("0,25", in: app.textFields["delivery.reservation.amount"])
        tap(app.buttons["Guardar cantidad apartada"])
        tap(record)
        enter(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "0", in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("0 unidades"))
        tap(app.buttons["Alimentos entregados por comida"])
        assertFact("Cantidad apartada", "1/4 unidades")
        assertFact("Cantidad que aún cubre esta entrega", "0 unidades")
        checkCookCopy(in: "Avisar a quien cocina", fragments: ["Lunch wraps", "School lunch", "Tortillas de maíz", "Cantidad apartada: 1/4 unidades",
                       "Cantidad que aún cubre esta entrega: 0 unidades", "peanuts", "sesame"])
        tap(app.buttons["Listo"])
        tap(record)
        enter(XCUIKeyboardKey.delete.rawValue, in: amount)
        tap(save)
        XCTAssertTrue(hasUsable("Cantidad sin resolver"))
    }
}
#endif
