#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Actual RecordsToolsEntryView with isolated native stores and a real normalized
/// source JPEG. Only system file destination/selection is deterministic; every
/// disclosure, encryption, review, cancellation and import action is production UI.
@MainActor final class RecordsMediaUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    private let photoID = "77777777-7777-4777-8777-777777777777"
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("F07 failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "F07 failure accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        app.terminate()
    }
    func testSelectedPhotoDisclosureEncryptedPreviewCancelSiblingRecoveryAndReadablePhoto() {
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["--ui-testing", "--records-media-fixture", "--reset-records-media-fixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 20))
        assertEvidence(copies: 1)
        let source = app.switches.matching(NSPredicate(format: "label == %@", "F07 source pickup")).firstMatch
        enableSwitch(source)
        let recovery = button("records.encryptedRecovery")
        reveal(recovery)
        XCTAssertTrue(recovery.label.contains("Encrypted personal recovery"), "The disclosure action must have a meaningful accessibility label")
        tap(recovery)
        let selection = element("records.mediaSelection." + photoID)
        reveal(selection)
        XCTAssertEqual(selection.value as? String, "0", "Photo inclusion must begin off")
        let preview = button("records.mediaPreview." + photoID)
        reveal(preview)
        XCTAssertTrue(preview.label.contains("Preview source reference"))
        tap(preview)
        let photo = element("records.mediaImage." + photoID)
        reveal(photo, requiresHitTarget: false)
        XCTAssertTrue(photo.exists)
        reveal(element("records.mediaWording." + photoID), requiresHitTarget: false)
        XCTAssertTrue(element("records.mediaWording." + photoID).label.contains("F07 package wording: 8 wraps per pack"))
        capture("F07 actual source JPEG and original wording before selection")
        enableSwitch(selection, upward: true)
        let summary = element("records.mediaSummary")
        reveal(summary, requiresHitTarget: false)
        XCTAssertTrue(summary.label.hasPrefix("1 selected references"))
        XCTAssertTrue(summary.label.contains("KB"), "The selected reference's nonzero size must be disclosed")
        capture("F07 selected source reference and disclosed size")

        tap(element("records.generateKey"))
        enableSwitch(element("records.savedKey"))
        let prepare = element("records.prepareRecovery")
        reveal(prepare, requiresHitTarget: false)
        XCTAssertFalse(prepare.isEnabled, "A saved key alone cannot bypass the selected-media privacy disclosure")
        let disclosure = element("records.mediaDisclosure")
        reveal(disclosure, upward: true)
        XCTAssertEqual(disclosure.value as? String, "0")
        XCTAssertTrue(disclosure.label.contains("private source details"))
        enableSwitch(disclosure)
        tap(prepare)
        let save = element("records.saveFile")
        XCTAssertTrue(save.waitForExistence(timeout: 12))
        reveal(save)
        XCTAssertTrue(app.staticTexts["Private owner file ready"].exists)
        capture("F07 encrypted recovery prepared after private-content disclosure")
        tap(save)
        XCTAssertTrue(waitForLabel("fixture.records.savedFiles", "F07 encrypted files: 1"))
        XCTAssertTrue(waitForLabel("fixture.records.fileHidesSource", "F07 file hides source: yes"))
        assertEvidence(copies: 1)
        // Collapse only the export disclosure. Generated key and saved encrypted
        // file remain available to the actual import control below it.
        tap(recovery, upward: true)

        tap(element("records.chooseFile"))
        let related = app.staticTexts["Related revision — keep both copies"]
        XCTAssertTrue(related.waitForExistence(timeout: 12))
        reveal(related, requiresHitTarget: false)
        capture("F07 sibling review before cancelling import")
        tap(element("records.cancelImport"))
        assertEvidence(copies: 1)
        assertVisibleStatus("Import cancelled. Your records are unchanged.")
        XCTAssertFalse(element("records.applyImport").exists)

        tap(element("records.chooseFile"), upward: true)
        XCTAssertTrue(related.waitForExistence(timeout: 12))
        tap(element("records.applyImport"))
        assertEvidence(copies: 2)
        assertVisibleStatus("Saved separate recovered copies. Your current work is unchanged.")
        capture("F07 import outcome returned to visible result anchor")
        let recovered = button("records.recovered.F07 source pickup")
        reveal(recovered)
        XCTAssertTrue(recovered.label.contains("Recovered copy: F07 source pickup"))
        tap(recovered)
        tap(button("records.mediaPreview." + photoID))
        reveal(element("records.mediaImage." + photoID), requiresHitTarget: false)
        reveal(element("records.mediaWording." + photoID), requiresHitTarget: false)
        XCTAssertTrue(element("records.mediaWording." + photoID).label.contains("F07 package wording: 8 wraps per pack"))
        XCTAssertTrue(app.staticTexts["Package reference"].exists)
        capture("F07 readable recovered source photo beside newer separate work")
        assertEvidence(copies: 2)
        tap(app.buttons["Delete this recovered copy"])
        tap(app.buttons["Delete from this iPhone"])
        assertEvidence(copies: 1)
        assertVisibleStatus("The recovered copies and their separate workspaces were permanently deleted from this iPhone.")
        capture("F07 deletion outcome returned to visible result anchor")
    }
    private func assertEvidence(copies: Int) {
        XCTAssertTrue(waitForLabel("fixture.records.recoveredCount", "F07 recovered copies: \(copies)"))
        XCTAssertTrue(waitForLabel("fixture.records.sourceUnchanged", "F07 source unchanged: yes"))
        XCTAssertFalse(element("fixture.records.failure").exists)
        XCTAssertFalse(element("records.error").exists)
    }
    private func waitForLabel(_ id: String, _ expected: String) -> Bool {
        let value = element(id)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: value)], timeout: 12) == .completed
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func button(_ id: String) -> XCUIElement { app.buttons.matching(identifier: id).firstMatch }
    private func tap(_ value: XCUIElement, upward: Bool = false) {
        reveal(value, upward: upward)
        XCTAssertTrue(value.isHittable, value.debugDescription)
        value.tap()
    }
    private func enableSwitch(_ value: XCUIElement, upward: Bool = false) {
        reveal(value, upward: upward)
        if value.value as? String == "0" { value.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(value.value as? String, "1", "The reviewed switch must be on")
    }
    private func assertVisibleStatus(_ expected: String) {
        XCTAssertTrue(waitForLabel("records.status", expected))
        let status = element("records.status")
        // Do not scroll here: the completed model action must route its own result.
        XCTAssertTrue(touchableArea().contains(CGPoint(x: status.frame.midX, y: status.frame.midY)), "The completed action's result was not brought into view")
    }
    private func reveal(_ value: XCUIElement, upward: Bool = false, requiresHitTarget: Bool = true) {
        for attempt in 0..<48 {
            let viewport = touchableArea()
            if value.exists && (!requiresHitTarget || value.isHittable),
               viewport.contains(CGPoint(x: value.frame.midX, y: value.frame.midY)) { return }
            let contentUp: Bool
            if value.exists && !value.frame.isEmpty { contentUp = value.frame.midY > viewport.midY }
            else { contentUp = attempt < 24 ? !upward : upward }
            scrollContent(upward: contentUp)
        }
        XCTAssertTrue(value.exists && (!requiresHitTarget || value.isHittable) && touchableArea().contains(CGPoint(x: value.frame.midX, y: value.frame.midY)), value.debugDescription)
    }
    private func touchableArea() -> CGRect {
        let bounds = app.frame, keyboard = app.keyboards.firstMatch, tabs = app.tabBars.firstMatch
        let keyboardTop = keyboard.exists ? keyboard.frame.minY : bounds.maxY
        let tabTop = tabs.exists && tabs.isHittable && !tabs.frame.isEmpty ? tabs.frame.minY : bounds.maxY
        let navigation = app.navigationBars.firstMatch
        let top = navigation.exists && navigation.isHittable ? navigation.frame.maxY : bounds.minY + 88
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, min(keyboardTop, tabTop) - top - 4))
    }
    private func scrollContent(upward: Bool) {
        let viewport = touchableArea(), bounds = app.frame
        let drag = viewport.insetBy(dx: 24, dy: 16)
        let high = drag.minY + drag.height * 0.2, low = drag.minY + drag.height * 0.8
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: drag.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: drag.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY)))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = name + " accessibility"; accessibility.lifetime = .keepAlways; add(accessibility)
    }
}
#endif
