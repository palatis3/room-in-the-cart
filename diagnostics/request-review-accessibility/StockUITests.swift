import XCTest

@MainActor final class FormToggleDiagnosticUITests: XCTestCase {
  let app = XCUIApplication()
  func testCompareSizes() {
    for (name, category) in [
      ("small", "UICTContentSizeCategoryS"), ("large", "UICTContentSizeCategoryL"),
      ("ax5", "UICTContentSizeCategoryAccessibilityXXXL"),
    ] {
      app.launchArguments = ["-UIPreferredContentSizeCategoryName", category]
      app.launch()
      XCTAssertTrue(app.staticTexts["Body text"].waitForExistence(timeout: 10))
      let ax = XCTAttachment(string: app.debugDescription)
      ax.name = name + " AX"
      ax.lifetime = .keepAlways
      add(ax)
      let screen = XCTAttachment(screenshot: app.screenshot())
      screen.name = name + " screen"
      screen.lifetime = .keepAlways
      add(screen)
      app.terminate()
    }
  }
  func testStockScrolledSheet() throws {
    continueAfterFailure = true
    app.launchArguments = ["--sheet"]
    app.launch()
    app.buttons["Open stock sheet"].tap()
    let review = app.buttons["Review"]
    for _ in 0..<8 where !review.isHittable { app.swipeUp() }
    review.tap()
    XCTAssertTrue(app.staticTexts["Protected meal commitments"].isHittable)
    let snapshot = XCTAttachment(screenshot: app.screenshot())
    snapshot.name = "Stock sheet"
    snapshot.lifetime = .keepAlways
    add(snapshot)
    try app.performAccessibilityAudit { issue in
      let ax = XCTAttachment(
        string: issue.detailedDescription + "\n" + (issue.element?.debugDescription ?? "No element")
      )
      ax.name = "Issue"
      ax.lifetime = .keepAlways
      self.add(ax)
      return false
    }
  }
  func testDynamicTypeAudit() throws {
    continueAfterFailure = true
    app.launch()
    try app.performAccessibilityAudit(for: .dynamicType) { issue in
      let ax = XCTAttachment(
        string: issue.detailedDescription + "\n" + (issue.element?.debugDescription ?? "No element")
      )
      ax.name = "Issue"
      ax.lifetime = .keepAlways
      self.add(ax)
      return false
    }
  }
}
