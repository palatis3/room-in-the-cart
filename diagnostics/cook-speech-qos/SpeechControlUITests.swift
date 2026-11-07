import XCTest

final class SpeechControlUITests: XCTestCase {
    @MainActor func testOpenWithoutPlayback() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Speak"].waitForExistence(timeout: 10))
    }

    @MainActor func testPublicSpeech() {
        let app = XCUIApplication()
        app.launch()
        for action in ["Speak", "Pause", "Resume", "Stop"] {
            let button = app.buttons[action]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
        }
    }
}
