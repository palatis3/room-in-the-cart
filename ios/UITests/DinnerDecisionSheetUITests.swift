#if DINNER_DECISION_UI_FIXTURE
import XCTest

final class DinnerDecisionSheetUITests: XCTestCase {
    private let app = XCUIApplication()
    func testEnglishPaidGroupReplacementAndGuestCancellation() { exercise("en") }
    func testSpanishPaidGroupReplacementAndGuestCancellation() { exercise("es") }

    func testLargestTypePairingSheetReturnsToItsInitiatingControl() {
        continueAfterFailure = false
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let origin = app.buttons["dinnerPairings"]
        tap(origin)
        let cancel = app.buttons["dinnerDecisionCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5) && cancel.isHittable)
        let review = app.buttons["dinnerScenarioReview"]
        XCTAssertTrue(review.exists && review.isHittable)
        capture("S15-largest-text")
        cancel.tap()
        XCTAssertTrue(origin.waitForExistence(timeout: 5) && origin.isHittable)
    }

    private func exercise(_ language: String) {
        continueAfterFailure = false
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "es" ? "es_US" : "en_US"]
        app.launch()
        let origin = app.buttons["dinnerPairings"]
        let cancel = app.buttons["dinnerDecisionCancel"]
        tap(origin)
        XCTAssertEqual(cancel.label, language == "es" ? "Cancelar" : "Cancel")
        tap(cancel)
        XCTAssertTrue(origin.waitForExistence(timeout: 5) && origin.isHittable)
        let meal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerOccurrence-' AND label CONTAINS 'Arroz'")).firstMatch
        tap(meal)
        let guests = app.buttons["dinnerGuests"]
        tap(guests)
        let servings = app.textFields["dinnerGuestServings"]
        tap(servings)
        servings.typeText("2")
        tap(app.buttons["dinnerGuestPreview"])
        XCTAssertTrue(app.buttons["dinnerApply"].exists || app.navigationBars[language == "es" ? "Vista previa de cenas" : "Dinner preview"].exists)
        let ricePreview = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerPreviewMeal-' AND label CONTAINS 'Arroz'")).firstMatch
        reveal(ricePreview)
        XCTAssertTrue(ricePreview.label.contains(language == "es" ? "Porciones: 23" : "Servings: 23"),ricePreview.label)
        XCTAssertTrue(ricePreview.label.contains("Almuerzo"),ricePreview.label)
        capture("S16-S17-" + language)
        tap(app.buttons["dinnerCancelPreview"])
        XCTAssertTrue(guests.waitForExistence(timeout: 5) && guests.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(origin)
        tap(app.buttons["dinnerScenarioReview"])
        tap(app.buttons["dinnerComparePairings"])
        let replace = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerReplacement-'")).firstMatch
        tap(replace)
        let lunch = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerPreviewMeal-' AND label CONTAINS 'Almuerzo'")).firstMatch
        reveal(lunch)
        XCTAssertTrue(lunch.label.contains(language == "es" ? "Porciones: 1" : "Servings: 1"),lunch.label)
        let remaining = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerPreviewNeed-' AND label CONTAINS %@", language == "es" ? "Después: 5" : "After: 5")).firstMatch
        reveal(remaining)
        capture("S15-S17-" + language)
        tap(app.buttons["dinnerApply"])
        XCTAssertTrue(origin.waitForExistence(timeout: 8))
        let tacos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dinnerOccurrence-' AND label CONTAINS 'Tacos'")).firstMatch
        tap(tacos)
        XCTAssertTrue(app.staticTexts["Tacos"].waitForExistence(timeout: 4))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(meal)
        let pending = app.buttons["dinnerGuests"]
        tap(pending)
        let protected = app.staticTexts["Almuerzo"]
        reveal(protected)
        XCTAssertFalse(app.textFields["dinnerGuestServings"].exists)
        capture("S15-retained-lunch-" + language)
    }

    private func tap(_ item: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(item,file: file,line: line)
        item.tap()
    }
    private func reveal(_ item: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let surface = app.collectionViews.firstMatch
        for attempt in 0..<32 {
            if item.exists && item.isHittable { return }
            if attempt < 19 { surface.swipeUp() } else { surface.swipeDown() }
        }
        XCTFail("Control did not become visible: \(item)",file: file,line: line)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
