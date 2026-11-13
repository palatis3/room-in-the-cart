// Append to RoomInTheCartUITests.swift in a disposable source copy to share the
// ordinary entry and saved-comparison assertions. See README.md for provisioning.
extension RoomInTheCartUITests {
    func testRealFilesCancelCorruptAndReimportAfterRelaunch() throws {
        let live = "Later market oats"
        let restored = "Earlier saffron rice"
        let separate = app.buttons["records.recovered." + restored]
        let choose = app.buttons["records.chooseFile"]
        let apply = app.buttons["records.applyImport"]
        launch()
        openEmptyComparison()
        enterComparison(item: live, firstQuantity: "8", cap: "30")
        compare()
        saveAndAssertDurableStatus()
        openRecoveryTools()
        checkpoint("N06 baseline")

        tap(choose)
        let cancel = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Cancel")).firstMatch
        // Wait for the OS document service to attach its controls to the sheet.
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "Files must present its real Cancel control")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 8))
        XCTAssertFalse(apply.exists)
        XCTAssertFalse(element("records.error").exists)
        assertNoImportedRecords(live: live)
        checkpoint("N06 picker cancelled")

        tap(choose)
        pickProviderBackup("N06-damaged")
        let error = element("records.error")
        XCTAssertTrue(error.waitForExistence(timeout: 8) && error.isHittable,
                      "Damaged-file feedback should be visible when the picker closes")
        XCTAssertTrue(error.label.contains("This file is incomplete or damaged. Your records are unchanged."),
                      "The picker must distinguish damaged data from an unavailable provider")
        XCTAssertFalse(apply.exists)
        assertNoImportedRecords(live: live)

        checkpoint("N06 damaged rejected")

        // Read the unchanged original before attempting recovery.
        reopenSavedRecord(recordsLabel: "Records", item: live)
        assertKnownTotals()
        app.terminate()
        launch(reset: false)
        openRecoveryTools()
        enterFictionalRecoveryKey()
        tap(choose)
        pickProviderBackup("N06-valid")
        assertContains("n06-local-kitchen")
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .abbreviated, time: .shortened)
        assertContains("Saved at " + savedAt)
        assertContains("Ready to recover a separate copy")
        let revision = "3f67f5c2977250473b9e87bbb3869ab4657a1464ee702f4b125e81b2e9abe739"
        assertContains("Revision: " + revision)
        tap(app.buttons["records.cancelImport"])
        assertContains("Import cancelled. Your records are unchanged.")
        assertNoImportedRecords(live: live)
        checkpoint("N06 review cancelled")

        tap(choose)
        pickProviderBackup("N06-valid")
        tap(apply)
        assertContains("Saved separate recovered copies. Your current work is unchanged.")
        checkpoint("N06 first applied")
        tap(separate)
        for text in ["Makes four bowls", "2 cups short-grain rice", "Steam for twenty minutes.",
                     "Set one bowl aside.", "https://cook.invalid/rice"] {
            assertContains(text)
        }

        app.terminate()
        launch(reset: false)
        openRecoveryTools()
        enterFictionalRecoveryKey()
        tap(choose)
        pickProviderBackup("N06-valid")
        assertContains("Identical — reopen existing copy")
        tap(apply)
        assertContains("Opened the existing recovered copies. Nothing was duplicated.")
        checkpoint("N06 identical reopened")
        reveal(separate)
        XCTAssertEqual(app.buttons.matching(identifier: "records.recovered." + restored).count, 1)
        tap(separate)
        assertContains("2 cups short-grain rice")
        assertContains("Set one bowl aside.")
        reopenSavedRecord(recordsLabel: "Records", item: live)
        assertKnownTotals()
    }

    private func checkpoint(_ name: String) {
        XCTContext.runActivity(named: name) { _ in }
    }

    private func assertNoImportedRecords(live: String) {
        assertContains("No recovered copies yet.")
        let source = app.switches[live]
        let form = app.collectionViews["records.tools"]
        for _ in 0..<12 {
            if source.exists && source.isHittable { break }
            form.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(source.exists && source.isHittable)
    }

    private func openRecoveryTools() {
        tap(app.tabBars.buttons["Records"])
        if !app.navigationBars["Data and recovery"].exists {
            if !app.navigationBars["Records"].exists {
                let back = app.navigationBars.buttons["BackButton"].firstMatch
                tap(back)
            }
            tap(app.buttons["Recovery, exports and saved records"])
        }
        XCTAssertTrue(app.navigationBars["Data and recovery"].waitForExistence(timeout: 8))
    }

    private func enterFictionalRecoveryKey() {
        let field = app.textFields["Key for an encrypted recovery file"]
        tap(field)
        field.typeText(Data(repeating: 42, count: 32).base64EncodedString())
        field.typeText("\n")
    }

    private func pickProviderBackup(_ name: String) {
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if !file.waitForExistence(timeout: 2) {
            let picker = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 30), "Files must finish presenting before navigation")
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists && browse.isHittable && !browse.isSelected { browse.tap() }
            let local = app.staticTexts["On My iPhone"].firstMatch
            if local.exists && local.isHittable { local.tap() }
            let downloads = app.cells["Downloads, Folder"].firstMatch
            if !file.exists && downloads.exists && downloads.isHittable { downloads.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Expected named backup in the simulator local provider")
        file.tap()
    }
}
