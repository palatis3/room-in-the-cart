#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class ImportRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!
    private let recoveryMessage = "Could not save on this iPhone. Your entries are still here. Retry the same change."

    private struct Audit: Decodable {
        let sequence: Int
        let revision: Int64
        let payloadSHA256: String
        let matchesBaseline: Bool
        let pending: Bool
        let saving: Bool
        let batchCount: Int
        let lineIDs: [String]
        let contributionIDs: [String]
        let names: [String]
        let quantities: [String]
        let batchIDs: [String]
        let previewIDs: [String]
        let batchContributionIDs: [String]
        let proposedLineIDs: [String]
        let stagedContributionIDs: [String]
        let originalTexts: [String]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    }

    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            capture("Import-recovery-fixture-failure")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Import-recovery-accessibility"; tree.lifetime = .keepAlways; add(tree)
            retainAudit("Import-recovery-last-audit")
        }
        app.terminate()
    }

    func testDiscardKeepsPendingImportUncommittedAndReviewPresented() throws {
        let before = try failedImport("4 discarded oat jars")
        let discard = importForm().buttons["Discard unsaved change"]
        reveal(discard)
        XCTAssertEqual(importForm().buttons.matching(NSPredicate(format: "label == %@", "Discard unsaved change")).count, 1)
        try requireSingleHittableAction("Discard unsaved change", name: "Discard-before-tap")
        XCTAssertTrue(discard.isEnabled && discard.isHittable)
        discard.tap()

        // Audit before checking sheet presence: the negative control saves and dismisses.
        let after = try completedAudit()
        XCTAssertTrue(after.matchesBaseline, "Discard must preserve the independent durable record")
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.payloadSHA256, before.payloadSHA256)
        XCTAssertEqual(after.batchCount, 0)
        XCTAssertTrue(after.lineIDs.isEmpty && after.contributionIDs.isEmpty && after.names.isEmpty)
        XCTAssertFalse(after.pending || after.saving)
        XCTAssertEqual(diagnostic("dismissals").label, "0")
        XCTAssertTrue(formQuery.element(boundBy: 0).exists, "Discard must keep the real review sheet open")
        XCTAssertFalse(importForm().buttons["ledgerRetrySave"].exists)
        XCTAssertFalse(importForm().staticTexts[recoveryMessage].exists)
        XCTAssertTrue(app.buttons["ledgerCommitImport"].isEnabled)
        capture("Discard-keeps-review-and-durable-baseline")
        app.navigationBars["Bring the list"].buttons["Cancel"].tap()
        XCTAssertTrue(formQuery.element(boundBy: 0).waitForNonExistence(timeout: 8))
    }

    func testRetryPersistsOneImportAndDismissesThroughItsCallback() throws {
        let before = try failedImport("2 recovery wraps\n3 recovery pears")
        let retry = importForm().buttons["ledgerRetrySave"]
        reveal(retry)
        XCTAssertEqual(importForm().buttons.matching(identifier: "ledgerRetrySave").count, 1)
        try requireSingleHittableAction("ledgerRetrySave", name: "Retry-before-tap")
        XCTAssertTrue(retry.isEnabled && retry.isHittable)
        retry.tap()
        XCTAssertTrue(formQuery.element(boundBy: 0).waitForNonExistence(timeout: 15),
                      "The production onRetried callback must dismiss the sheet")
        let after = try completedAudit()
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertFalse(after.matchesBaseline)
        XCTAssertNotEqual(after.payloadSHA256, before.payloadSHA256)
        XCTAssertEqual(after.batchCount, 1)
        XCTAssertEqual(after.names, ["recovery pears", "recovery wraps"])
        XCTAssertEqual(after.quantities, ["recovery pears=3/1 count", "recovery wraps=2/1 count"])
        XCTAssertEqual(after.lineIDs.count, 2); XCTAssertEqual(Set(after.lineIDs).count, 2)
        XCTAssertEqual(after.contributionIDs.count, 2); XCTAssertEqual(Set(after.contributionIDs).count, 2)
        XCTAssertEqual(after.batchIDs, after.previewIDs)
        XCTAssertEqual(after.batchContributionIDs, after.contributionIDs)
        XCTAssertEqual(after.proposedLineIDs, after.lineIDs)
        XCTAssertEqual(after.stagedContributionIDs, after.contributionIDs)
        XCTAssertEqual(after.originalTexts, ["2 recovery wraps\n3 recovery pears"])
        XCTAssertFalse(after.pending || after.saving)
        waitForLabel(diagnostic("dismissals"), "1")
        capture("Retry-persists-one-import-and-dismisses")
    }

    private var formQuery: XCUIElementQuery { app.collectionViews.matching(identifier: "ledgerImportForm") }

    private func importForm() -> XCUIElement {
        XCTAssertEqual(formQuery.count, 1, "Use the actual single import Form")
        return formQuery.element(boundBy: 0)
    }

    private func diagnostic(_ name: String) -> XCUIElement {
        let location = formQuery.element(boundBy: 0).exists ? "sheet" : "root"
        return app.staticTexts["fixture.importRecovery.\(location).\(name)"]
    }

    private func failedImport(_ text: String) throws -> Audit {
        app.launchEnvironment["RITC_IMPORT_RECOVERY_FIXTURE_ID"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--import-recovery-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForLabel(app.staticTexts["fixture.importRecovery.root.phase"], "ready")
        XCTAssertEqual(diagnostic("failure").label, "none")
        let before = try readAudit()
        XCTAssertEqual(before.sequence, 0)
        XCTAssertEqual(before.batchCount, 0)
        XCTAssertTrue(before.lineIDs.isEmpty && before.contributionIDs.isEmpty)
        app.buttons["fixture.importRecovery.open"].tap()
        XCTAssertTrue(formQuery.element(boundBy: 0).waitForExistence(timeout: 8))
        let editor = importForm().textViews["ledgerImportText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        reveal(editor); editor.tap(); editor.typeText(text)
        XCTAssertEqual(editor.value as? String, text)
        let review = importForm().buttons["ledgerReviewImport"]
        reveal(review); XCTAssertTrue(review.isEnabled && review.isHittable); review.tap()
        let commit = app.buttons["ledgerCommitImport"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5) && commit.isEnabled && commit.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "ledgerCommitImport").count, 1)

        // Fault setup begins only after UI staging, keeping the lease short and bounded.
        let writer = app.buttons["fixture.importRecovery.writer"]
        XCTAssertTrue(writer.isEnabled && writer.isHittable); writer.tap()
        waitForLabel(diagnostic("phase"), "held")
        commit.tap()
        let errorQuery = importForm().staticTexts.matching(NSPredicate(format: "label == %@", recoveryMessage))
        XCTAssertTrue(errorQuery.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertEqual(errorQuery.count, 1)
        XCTAssertFalse(commit.isEnabled)
        XCTAssertEqual(importForm().buttons.matching(identifier: "ledgerRetrySave").count, 1)
        XCTAssertEqual(importForm().buttons.matching(NSPredicate(format: "label == %@", "Discard unsaved change")).count, 1)
        XCTAssertTrue(writer.isEnabled && writer.isHittable); writer.tap()
        waitForLabel(diagnostic("phase"), "released")
        XCTAssertEqual(diagnostic("failure").label, "none")
        capture("Import-failed-under-real-contention-writer-released")
        return before
    }

    private func readAudit() throws -> Audit {
        let value = diagnostic("audit")
        XCTAssertTrue(value.exists)
        return try JSONDecoder().decode(Audit.self, from: Data(value.label.utf8))
    }

    private func completedAudit() throws -> Audit {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let element = diagnostic("audit")
            guard element.exists, let value = try? JSONDecoder().decode(Audit.self, from: Data(element.label.utf8)) else { return false }
            return value.sequence == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        retainAudit("Recovery-independent-durable-readback")
        XCTAssertEqual(diagnostic("failure").label, "none")
        return try readAudit()
    }

    private func requireSingleHittableAction(_ identifierOrLabel: String, name: String) throws {
        let matches = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifierOrLabel, identifierOrLabel)).allElementsBoundByIndex
        let values: [[String: Any]] = matches.map { ["identifier": $0.identifier, "label": $0.label,
            "hittable": $0.isHittable, "frame": String(describing: $0.frame)] }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(values.filter { $0["hittable"] as? Bool == true }.count, 1)
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }

    private func reveal(_ target: XCUIElement) {
        for _ in 0..<16 {
            let bounds = app.windows.firstMatch.frame
            let navigation = app.navigationBars["Bring the list"]
            let keyboard = app.keyboards.firstMatch
            let commit = app.buttons["ledgerCommitImport"]
            let top = navigation.exists ? navigation.frame.maxY : bounds.minY
            let bottom = min(commit.exists ? commit.frame.minY : bounds.maxY,
                             keyboard.exists ? keyboard.frame.minY : bounds.maxY)
            let area = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top)).insetBy(dx: 4, dy: 4)
            guard area.height > 60 else { XCTFail("Import Form needs a usable viewport"); return }
            let frame = target.exists ? target.frame : .zero
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if target.exists && target.isHittable && area.contains(center) { return }
            let direction: CGFloat = !target.exists || center.y > area.midY ? 1 : -1
            let distance = min(180, area.height * 0.6)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: area.maxX - 8 - app.frame.minX, dy: area.midY + direction * distance / 2 - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: area.maxX - 8 - app.frame.minX, dy: area.midY - direction * distance / 2 - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTFail("Recovery target did not become visible and hittable")
    }

    private func retainAudit(_ name: String) {
        let value = diagnostic("audit")
        guard value.exists else { return }
        let attachment = XCTAttachment(string: value.label)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
