    func testImportRecoveryUsesRealWriterContentionAndKeepsOneCommit() throws {
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["RITC_IMPORT_RECOVERY_TOKEN"])
        _ = try XCTUnwrap(UUID(uuidString: token), "Use one unique host/runner exchange token")
        let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("ImportRecovery-" + token, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var observations: [[String: Any]] = []
        func write(_ value: [String: Any], to name: String) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        func exchange(_ phase: String, expecting state: String) throws {
            try write(["token": token, "phase": phase, "requestedUnixUTC": Date().timeIntervalSince1970], to: phase + ".request.json")
            let acknowledgement = directory.appendingPathComponent(phase + ".ack.json")
            let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: acknowledgement),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return value["token"] as? String == token && value["phase"] as? String == phase && value["state"] as? String == state
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 30), .completed,
                           "Host acknowledgement must match this exact run, phase and lock state: \(phase)")
        }
        let recoveryMessage = "Could not save on this iPhone. Your entries are still here. Retry the same change."
        func importForm() -> XCUIElement {
            let forms = app.collectionViews.matching(identifier: "ledgerImportForm")
            XCTAssertEqual(forms.count, 1, "Recovery belongs to the single presented import Form")
            return forms.element(boundBy: 0)
        }
        func onlyHittableAction(_ identifierOrLabel: String, phase: String) {
            let matches = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifierOrLabel, identifierOrLabel)).allElementsBoundByIndex
            let states: [[String: Any]] = matches.map { ["identifier": $0.identifier, "label": $0.label, "hittable": $0.isHittable, "frame": String(describing: $0.frame)] }
            observations.append(["phase": phase, "actionMatches": states])
            do { try write(["token": token, "observations": observations], to: "observations.json") }
            catch { XCTFail("Could not preserve recovery action observations: \(error)") }
            XCTAssertEqual(states.filter { $0["hittable"] as? Bool == true }.count, 1,
                           "Only the presented sheet's recovery action may be hittable")
        }
        func contentArea() -> CGRect {
            let bounds = app.windows.firstMatch.frame
            let navigation = app.navigationBars["Bring the list"]
            let keyboard = app.keyboards.firstMatch
            let commit = element("ledgerCommitImport")
            let top = navigation.exists ? navigation.frame.maxY : bounds.minY
            let bottom = min(commit.exists ? commit.frame.minY : bounds.maxY,
                             keyboard.exists ? keyboard.frame.minY : bounds.maxY)
            return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
        }
        func revealRecovery(_ target: XCUIElement) {
            for _ in 0..<24 {
                let area = contentArea().insetBy(dx: 4, dy: 4)
                guard area.height > 60 else { XCTFail("Recovery content needs a usable scroll viewport"); return }
                let frame = target.exists ? target.frame : .zero
                let center = CGPoint(x: frame.midX, y: frame.midY)
                if target.exists && target.isHittable && area.contains(center) { return }
                let upward = !target.exists || center.y > area.midY
                let distance = min(180, area.height * 0.6)
                let direction: CGFloat = upward ? 1 : -1
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let x = area.maxX - 8 - app.frame.minX
                let start = origin.withOffset(CGVector(dx: x, dy: area.midY + direction * distance / 2 - app.frame.minY))
                let end = origin.withOffset(CGVector(dx: x, dy: area.midY - direction * distance / 2 - app.frame.minY))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            }
            XCTFail("Recovery target must be unobscured through ordinary Form scrolling: \(target.identifier)")
        }
        func stage(_ text: String) {
            tap(element("ledgerImport"))
            fill(text, into: "ledgerImportText")
            tap(element("ledgerReviewImport"))
            let commit = element("ledgerCommitImport")
            XCTAssertTrue(commit.waitForExistence(timeout: 5) && commit.isEnabled && commit.isHittable)
            let amount = importForm().textFields.matching(NSPredicate(format: "placeholderValue == %@", "Amount, unknown if blank")).firstMatch
            revealRecovery(amount)
            amount.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Submit begins with a real focused preview field")
        }
        func failImport(_ prefix: String) throws {
            let commit = element("ledgerCommitImport")
            XCTAssertEqual(app.buttons.matching(identifier: "ledgerCommitImport").count, 1)
            XCTAssertTrue(commit.isEnabled && commit.isHittable)
            let heading = importForm().staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Original wording")).firstMatch
            let beforeArea = contentArea()
            observations.append(["phase": prefix + "-before-submit", "keyboardExists": app.keyboards.firstMatch.exists,
                                 "originalHeadingExists": heading.exists,
                                 "originalHeadingFrame": heading.exists ? String(describing: heading.frame) : "unavailable",
                                 "originalHeadingAboveViewport": heading.exists && heading.frame.maxY < beforeArea.minY,
                                 "contentArea": String(describing: beforeArea)])
            try write(["token": token, "observations": observations], to: "observations.json")
            capture("Import-recovery-" + prefix + "-before-submit")
            try exchange(prefix + "-ready", expecting: "locked")
            commit.tap() // One authorized import attempt while the host holds the writer lock.
            let errorQuery = importForm().staticTexts.matching(NSPredicate(format: "label == %@", recoveryMessage))
            let error = errorQuery.element(boundBy: 0)
            XCTAssertTrue(error.waitForExistence(timeout: 15), "Real writer contention must expose the ordinary save error")
            XCTAssertEqual(errorQuery.count, 1)
            XCTAssertGreaterThan(error.frame.width, 0)
            XCTAssertGreaterThan(error.frame.height, 0)
            XCTAssertFalse(commit.isEnabled, "A pending confirmed save must not accept a second Add")
            XCTAssertEqual(app.buttons.matching(identifier: "ledgerCommitImport").count, 1)
            let area = contentArea()
            let firstLineVisible = error.frame.minY >= area.minY - 2 && error.frame.minY < area.maxY - 44
            observations.append(["phase": prefix, "keyboardAfterFailure": app.keyboards.firstMatch.exists,
                                 "errorFrame": String(describing: error.frame), "contentArea": String(describing: area),
                                 "errorStartVisibleBeforeReveal": firstLineVisible, "commitFrame": String(describing: commit.frame)])
            try write(["token": token, "observations": observations], to: "observations.json")
            capture("Import-recovery-" + prefix + "-failure-before-reveal")
            XCTAssertTrue(firstLineVisible, "The new save error must be brought into view before a reveal gesture")
            try exchange(prefix + "-failed", expecting: "released")
            let retry = importForm().buttons["ledgerRetrySave"]
            revealRecovery(retry)
            XCTAssertEqual(importForm().buttons.matching(identifier: "ledgerRetrySave").count, 1)
            onlyHittableAction("ledgerRetrySave", phase: prefix + "-retry-visible")
            XCTAssertTrue(retry.isEnabled && retry.isHittable)
            let discard = importForm().buttons["Discard unsaved change"]
            revealRecovery(discard)
            XCTAssertEqual(importForm().buttons.matching(NSPredicate(format: "label == %@", "Discard unsaved change")).count, 1)
            onlyHittableAction("Discard unsaved change", phase: prefix + "-discard-visible")
            XCTAssertTrue(discard.isEnabled && discard.isHittable)
            capture("Import-recovery-" + prefix + "-actions")
        }

        launch(reset: true, largestText: true)
        try exchange("bootstrap", expecting: "bound")
        tap(element("openPickupList")); tap(element("ledgerStartShop"))
        fill("Recovery check", into: "ledgerShopName")
        tap(element("ledgerCreateShop"))
        stage("2 recovery wraps\n3 recovery pears")
        try failImport("retry")
        let retry = importForm().buttons["ledgerRetrySave"]
        revealRecovery(retry); onlyHittableAction("ledgerRetrySave", phase: "retry-before-tap"); retry.tap()
        XCTAssertTrue(app.navigationBars["Bring the list"].waitForNonExistence(timeout: 15), "Successful Retry must dismiss through the original callback")
        try exchange("retry-saved", expecting: "verified")
        app.terminate(); launch(reset: false, largestText: true)
        if !element("ledgerSearch").exists { tap(element("openPickupList")) }
        fill("recovery pears", into: "ledgerSearch")
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledgerInspect-"))
        XCTAssertEqual(element("ledgerSearch").value as? String, "recovery pears")
        revealContent(results.firstMatch)
        XCTAssertEqual(results.count, 1, "The retried import is visible after restart")
        XCTAssertTrue(results.firstMatch.label.localizedCaseInsensitiveContains("recovery pears"))
        capture("Import-recovery-retried-row-after-restart")

        stage("4 discarded oat jars")
        try failImport("discard")
        let discard = importForm().buttons["Discard unsaved change"]
        revealRecovery(discard); onlyHittableAction("Discard unsaved change", phase: "discard-before-tap"); discard.tap()
        XCTAssertTrue(importForm().staticTexts[recoveryMessage].waitForNonExistence(timeout: 8))
        XCTAssertFalse(importForm().buttons["ledgerRetrySave"].exists)
        XCTAssertTrue(app.navigationBars["Bring the list"].exists, "Discard clears pending persistence; it does not submit or dismiss the review")
        XCTAssertTrue(element("ledgerCommitImport").isEnabled)
        app.navigationBars["Bring the list"].buttons["Cancel"].tap()
        app.terminate(); launch(reset: false, largestText: true)
        if !element("ledgerSearch").exists { tap(element("openPickupList")) }
        fill("discarded oat jars", into: "ledgerSearch", replacing: true)
        XCTAssertEqual(element("ledgerSearch").value as? String, "discarded oat jars")
        revealContent(app.staticTexts["No active items match your search."])
        XCTAssertTrue(app.staticTexts["No active items match your search."].exists)
        try exchange("discard-cancelled", expecting: "verified")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "import-recovery-observations"; attachment.lifetime = .keepAlways; add(attachment)
        try write(["token": token, "phase": "done"], to: "done.request.json")
    }

