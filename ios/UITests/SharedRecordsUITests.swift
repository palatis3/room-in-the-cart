#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

/// Synthetic HTTP transport, real HouseholdService/HouseholdModel and production
/// RecordsToolsEntryView/Composition. Only system file selection/destination is
/// deterministic. These journeys do not qualify real service/guardian access.
@MainActor final class SharedRecordsUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.roominthecart.app.debug")
    private let shop = "00000000-0000-4000-8000-000000000002"
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 { capture("S20 failure") }
        app.terminate()
    }
    func testSharedRecordsENPrivateExportCancelDedupeAndInertRecovery() { journey(spanish: false) }
    func testSharedRecordsESPrivateExportCancelDedupeAndInertRecovery() { journey(spanish: true) }

    private func journey(spanish: Bool) {
        func text(_ en: String, _ es: String) -> String { spanish ? es : en }
        let language = spanish ? "ES" : "EN"
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["--ui-testing", "--shared-records-fixture", "--reset-shared-records-fixture",
            "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_US" : "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars[text("Data and recovery", "Datos y recuperación")].waitForExistence(timeout: 20))
        let source = app.switches.matching(identifier: "records.source." + shop).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 12))
        evidence(copies: 0, files: 0, encrypted: false)
        enable(source)
        let unknown = text("Source saved date not supplied", "Fecha de guardado de origen no indicada")
        assertLabel("records.sourceDate." + shop, equals: unknown)
        XCTAssertFalse(element("records.sourceDate." + shop).label.contains("1970"))
        capture("S20 \(language) actual shared source with unknown source date")

        // Both helper paths must reject BEFORE publishing a document or file.
        for action in ["records.prepareHelperText", "records.prepareHelperJSON"] {
            tap(element(action))
            let expected = text("This file uses an unsupported format or record type. Your records are unchanged.", "Este archivo usa un formato o tipo de registro no compatible. Tus registros no cambiaron.")
            XCTAssertTrue(waitLabel("records.error", equals: expected))
            XCTAssertFalse(element("records.saveFile").exists)
            XCTAssertFalse(element("records.readableText").exists)
            evidence(copies: 0, files: 0, encrypted: false, allowsExportError: true)
        }
        capture("S20 \(language) helper export denied without prepared private document")

        enable(app.switches.matching(identifier: "records.ownerDisclosure").firstMatch)
        tap(element("records.prepareOwnerText"))
        let saveFile = app.buttons.matching(identifier: "records.saveFile").firstMatch
        reveal(saveFile)
        XCTAssertTrue(saveFile.waitForExistence(timeout: 12))
        tap(app.buttons.matching(identifier: "records.readablePreview").firstMatch)
        let readable = element("records.readableText")
        reveal(readable, requiresHitTarget: false)
        assertFood(readable.label, spanish: spanish)
        XCTAssertFalse(readable.label.contains("1970"))
        capture("S20 \(language) private readable preview preserves unknown protected unbound food")
        tap(element("records.discardFile"))
        XCTAssertFalse(element("records.saveFile").exists)
        evidence(copies: 0, files: 0, encrypted: false)

        let recovery = app.buttons.matching(identifier: "records.encryptedRecovery").firstMatch
        tap(recovery, upward: true)
        tap(element("records.generateKey"))
        enable(app.switches.matching(identifier: "records.savedKey").firstMatch)
        tap(element("records.prepareRecovery"))
        reveal(saveFile)
        XCTAssertTrue(saveFile.waitForExistence(timeout: 12))
        capture("S20 \(language) encrypted personal file prepared through production model")
        tap(element("records.saveFile"))
        evidence(copies: 0, files: 1, encrypted: true)
        tap(recovery, upward: true)

        tap(element("records.chooseFile"))
        assertDisposition(text("Ready to recover a separate copy", "Puedes recuperar una copia por separado"))
        assertLabel("records.importSourceDate." + shop, equals: unknown)
        let exportDate = element("records.importExportDate")
        reveal(exportDate, requiresHitTarget: false)
        XCTAssertTrue(exportDate.label.hasPrefix(text("File exported at: ", "Archivo exportado: ")))
        XCTAssertFalse(exportDate.label.contains("1970")); XCTAssertNotEqual(exportDate.label, unknown)
        capture("S20 \(language) import review separates real export time from unknown source save")
        tap(element("records.cancelImport"))
        evidence(copies: 0, files: 1, encrypted: true)
        XCTAssertEqual(element("fixture.sharedRecords.copyID").label, "none")
        XCTAssertFalse(element("records.applyImport").exists)
        XCTAssertTrue(waitLabel("records.status", equals: text("Import cancelled. Your records are unchanged.", "Importación cancelada. Tus registros no cambiaron.")))
        capture("S20 \(language) Cancel leaves no recovered shared record")

        tap(element("records.chooseFile"))
        assertDisposition(text("Ready to recover a separate copy", "Puedes recuperar una copia por separado"))
        tap(element("records.applyImport"))
        evidence(copies: 1, files: 1, encrypted: true)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "none"), object: element("fixture.sharedRecords.copyID"))], timeout: 12) == .completed)
        let recoveredID = element("fixture.sharedRecords.copyID").label
        XCTAssertNotEqual(recoveredID, "none"); XCTAssertNotNil(UUID(uuidString: recoveredID))
        XCTAssertTrue(waitLabel("records.status", equals: text("Saved separate recovered copies. Your current work is unchanged.", "Se guardaron copias recuperadas por separado. Tu trabajo actual no cambió.")))

        tap(element("records.chooseFile"))
        assertDisposition(text("Identical — reopen existing copy", "Idéntica — abrir la copia existente"))
        tap(element("records.applyImport"))
        XCTAssertTrue(waitLabel("records.status", equals: text("Opened the existing recovered copies. Nothing was duplicated.", "Se abrieron las copias recuperadas existentes. No se duplicó nada.")))
        evidence(copies: 1, files: 1, encrypted: true)
        XCTAssertEqual(element("fixture.sharedRecords.copyID").label, recoveredID)
        capture("S20 \(language) repeated import preserves one exact recovered copy")

        let reopened = app.buttons.matching(identifier: "records.recovered.Shared pickup").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 12))
        XCTAssertTrue(reopened.isHittable, "The identical retry must present its copy beside the result")
        XCTAssertEqual(reopened.value as? String, text("Expanded", "Expandido"))
        assertLabel("records.recoveredSourceDate." + shop, equals: unknown)
        let recoveredDate = element("records.recoveryDate." + shop)
        reveal(recoveredDate, requiresHitTarget: false)
        XCTAssertTrue(recoveredDate.label.hasPrefix(text("Copy recovered at: ", "Copia recuperada: ")))
        XCTAssertFalse(recoveredDate.label.contains("1970"))
        capture("S20 \(language) recovered disclosure separates recovery time from source date")
        tap(element("records.openRecovered." + shop))
        let recoveredText = element("records.sharedRecoveredText")
        XCTAssertTrue(recoveredText.waitForExistence(timeout: 12))
        assertFood(recoveredText.label, spanish: spanish)
        XCTAssertFalse(recoveredText.label.contains("1970"))
        XCTAssertTrue(recoveredText.label.contains(text("Read-only copy. Household access and checkout authority are not restored.", "Copia de solo lectura. No restablece acceso al hogar ni permisos de compra.")))
        capture("S20 \(language) production recovered read-only viewer source and access disclosure")
        scrollContent(upward: true, distanceFraction: 0.55)
        capture("S20 \(language) production recovered read-only viewer food facts")
        XCTAssertFalse(app.buttons["Apply"].exists); XCTAssertFalse(app.buttons["Aplicar"].exists)
        let done = app.buttons[text("Done", "Listo")]
        XCTAssertTrue(done.waitForExistence(timeout: 12)); XCTAssertTrue(done.isHittable); done.tap()
        evidence(copies: 1, files: 1, encrypted: true)
        XCTAssertEqual(element("fixture.sharedRecords.copyID").label, recoveredID)
    }
    private func assertFood(_ value: String, spanish: Bool) {
        XCTAssertTrue(value.contains("Unknown lunch wraps"), "Original wording must survive both display languages")
        XCTAssertTrue(value.contains("Exact family restriction"))
        XCTAssertTrue(value.contains(spanish ? "Reserva protegida" : "Protected reservation"))
        XCTAssertTrue(value.contains(spanish ? "Sin vincular; no disponible como existencias libres" : "Unbound; not available as free supply"))
        XCTAssertTrue(value.contains(spanish ? "Sin determinar" : "Unknown"))
        XCTAssertTrue(value.contains(spanish ? "Fecha de guardado no indicada" : "Saved date not supplied"))
        XCTAssertTrue(value.contains(spanish ? "Solo subtotales registrados" : "Tracked subtotals only"))
        XCTAssertTrue(value.contains("USD 2.00"))
        XCTAssertTrue(value.contains(spanish ? "La cotización está incompleta" : "The quote is incomplete"))
        for forbidden in ["authorityEpoch", "previewId", "replayWindow", "shared-records-device-token"] { XCTAssertFalse(value.contains(forbidden), forbidden) }
    }
    private func assertDisposition(_ expected: String) {
        let value = element("records.importDisposition." + shop)
        reveal(value, requiresHitTarget: false); XCTAssertEqual(value.label, expected)
    }
    private func assertLabel(_ id: String, equals value: String) {
        let target = element(id); reveal(target, requiresHitTarget: false); XCTAssertEqual(target.label, value)
    }
    private func evidence(copies: Int, files: Int, encrypted: Bool, allowsExportError: Bool = false) {
        let expected = "Copies: \(copies); Saved files: \(files); Encrypted: \(encrypted ? "yes" : "no")"
        XCTAssertTrue(waitLabel("fixture.sharedRecords.storage", equals: expected))
        let network = element("fixture.sharedRecords.network")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "Reads: [1-9][0-9]*; Mutations: 0; Unchanged: yes"), object: network)], timeout: 12) == .completed, "The production client must read v2 without changing local/source data or issuing mutations")
        XCTAssertFalse(element("fixture.sharedRecords.failure").exists)
        if !allowsExportError { XCTAssertFalse(element("records.error").exists) }
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func waitLabel(_ id: String, equals expected: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element(id))], timeout: 12) == .completed
    }
    private func tap(_ value: XCUIElement, upward: Bool = false) {
        reveal(value, upward: upward); XCTAssertTrue(value.isHittable, value.debugDescription); value.tap()
    }
    private func enable(_ value: XCUIElement) {
        reveal(value)
        // The observed SwiftUI row contains a separate native UISwitch.
        XCTAssertEqual(value.switches.count, 1, "Expected one native switch inside the Records row")
        let nativeSwitch = value.switches.firstMatch
        reveal(nativeSwitch, requiresFullFrame: true)
        if nativeSwitch.value as? String == "0" {
            // A tap on the visible off thumb can leave the Records switch off.
            // Move the thumb across the native track in one gesture.
            XCTAssertTrue(nativeSwitch.isEnabled && nativeSwitch.isHittable)
            let off = nativeSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            let on = nativeSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            off.press(forDuration: 0.1, thenDragTo: on)
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            nativeSwitch.value as? String == "1" && value.value as? String == "1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 12), .completed)
        XCTAssertEqual(value.value as? String, "1")
    }
    private func reveal(_ value: XCUIElement, upward: Bool = false, requiresHitTarget: Bool = true, requiresFullFrame: Bool = false) {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        for attempt in 0..<32 {
            let viewport = touchableArea()
            if value.exists && (!requiresHitTarget || value.isHittable),
               requiresFullFrame ? viewport.insetBy(dx: 0, dy: 8).contains(value.frame) : viewport.contains(CGPoint(x: value.frame.midX, y: value.frame.midY)) { return }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            let contentUp = value.exists && !value.frame.isEmpty ? value.frame.midY > viewport.midY : attempt < 16 ? !upward : upward
            scrollContent(upward: contentUp)
        }
        XCTFail("Could not reveal scoped Records element within bounded search: " + value.debugDescription)
    }
    private func touchableArea() -> CGRect {
        let bounds = app.frame, navigation = app.navigationBars.firstMatch
        let top = navigation.exists && navigation.isHittable ? navigation.frame.maxY : bounds.minY + 100
        let keyboard = app.keyboards.firstMatch, bottom = keyboard.exists ? keyboard.frame.minY : bounds.maxY
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top - 8))
    }
    private func scrollContent(upward: Bool, distanceFraction: CGFloat = 0.6) {
        let drag = touchableArea().insetBy(dx: 24, dy: 16), bounds = app.frame
        let distance = drag.height * distanceFraction / 2, high = drag.midY - distance, low = drag.midY + distance
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: drag.midX - bounds.minX, dy: (upward ? low : high) - bounds.minY)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: drag.midX - bounds.minX, dy: (upward ? high : low) - bounds.minY)))
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
#endif
