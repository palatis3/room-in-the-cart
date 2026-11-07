import XCTest
import Combine
import DeviceSurfaces
@testable import RoomInTheCart

#if DEBUG
@MainActor final class DeviceSurfacesCompositionStartupTests: XCTestCase {
    func testQueuedOpaqueURLDoesNotSurviveBackgroundThenForeground() async throws {
        let f = try await coldURLFixture()
        let saved = f.ledger.workspace, revision = f.ledger.revision
        let url = f.codec.url(handle: f.handle)
        f.composition.handle(url: url)
        // No suspension before background. Legitimate foreground restores
        // authority before the old URL's scheduled task gets to run.
        f.composition.background()
        await f.composition.foreground()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(f.composition.privateAuthorized, "Legitimate foreground should restore authority")
        XCTAssertNil(f.composition.destination, "Background must cancel an old queued URL even after foreground")
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
        // A new explicit URL in this foreground session must still work.
        f.composition.destination = nil
        f.composition.handle(url: url); await waitForSurfaceDestination(f.composition)
        guard case .shop(let id) = f.composition.destination else { return XCTFail("A fresh current URL should still open") }
        XCTAssertEqual(id, saved.selectedShopID)
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }

    func testReadyGenericURLDoesNotReactivateAfterBackgroundBeforeTaskRuns() async throws {
        let f = try await coldURLFixture()
        let saved = f.ledger.workspace, revision = f.ledger.revision
        f.composition.handle(url: f.codec.url(handle: nil)); f.composition.background()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(f.composition.privateAuthorized, "Generic capture must not reactivate after background")
        XCTAssertNil(f.composition.destination)
        let widget = try WidgetProjectionFile(directory: f.base.appendingPathComponent("surfaces/TestWidget"))
        XCTAssertNil(try widget.read().routeHandle)
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }
    func testActiveAdultGenericCaptureKeepsLedgerUnchanged() async throws {
        let f = try await coldURLFixture()
        let saved = f.ledger.workspace, revision = f.ledger.revision
        f.composition.handle(url: f.codec.url(handle: nil)); await waitForSurfaceDestination(f.composition)
        guard case .capture = f.composition.destination else { return XCTFail("Active adult generic entry should open capture") }
        XCTAssertTrue(f.composition.privateAuthorized)
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }
    func testLockedGenericEntryDoesNotPublishPrivateWidgetOrChangeLedger() async throws {
        let f = try await coldURLFixture()
        let saved = f.ledger.workspace, revision = f.ledger.revision
        f.access.protect(); f.composition.background(); f.composition.handle(url: f.codec.url(handle: nil))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(f.composition.privateAuthorized); XCTAssertFalse(f.access.unlocked)
        if let destination = f.composition.destination {
            guard case .unavailable = destination else { return XCTFail("Locked entry must not expose a private destination") }
        }
        let widget = try WidgetProjectionFile(directory: f.base.appendingPathComponent("surfaces/TestWidget"))
        XCTAssertNil(try widget.read().routeHandle)
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }

    func testReadyOpaqueURLDoesNotReactivateAfterBackgroundBeforeTaskRuns() async throws {
        let f = try await coldURLFixture()
        let saved = f.ledger.workspace, revision = f.ledger.revision
        XCTAssertTrue(f.composition.privateAuthorized)
        f.composition.handle(url: f.codec.url(handle: f.handle))
        // No suspension between receiving the ready URL and entering background:
        // the URL's scheduled task has not had a chance to run yet.
        f.composition.background()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(f.composition.privateAuthorized, "A queued URL must not reactivate a backgrounded composition")
        XCTAssertNil(f.composition.destination)
        let widget = try WidgetProjectionFile(directory: f.base.appendingPathComponent("surfaces/TestWidget"))
        XCTAssertNil(try widget.read().routeHandle)
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }

    func testColdCurrentURLWaitsForActiveAndReadyModels() async throws {
        let f = try await coldURLFixture()
        let coldLedger = LedgerModel(databaseURL: f.base.appendingPathComponent("ledger.sqlite"))
        let coldPickup = PickupModel(databaseURL: f.base.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        let cold = DeviceSurfacesComposition(directory: f.base.appendingPathComponent("surfaces"), bundle: f.bundle, launchArguments: ["--ui-testing"])
        f.cleanup.track(coldLedger, coldPickup, cold)
        cold.bind(ledger: coldLedger, pickup: coldPickup, household: f.household, access: f.access, sceneActive: false)
        cold.handle(url: f.codec.url(handle: f.handle))
        XCTAssertNil(cold.destination, "Inactive startup must not present or prematurely reject a known adult URL")
        XCTAssertFalse(cold.privateAuthorized); XCTAssertFalse(coldLedger.ready); XCTAssertFalse(coldPickup.ready)
        await coldLedger.open(); await coldPickup.load()
        let saved = coldLedger.workspace, revision = coldLedger.revision
        await cold.foreground(); await waitForSurfaceDestination(cold)
        guard case .shop(let id) = cold.destination else { return XCTFail("Current cold URL should open after readiness and authority reconcile") }
        XCTAssertEqual(id, saved.selectedShopID); XCTAssertEqual(coldLedger.workspace, saved); XCTAssertEqual(coldLedger.revision, revision)
    }
    func testColdGenericCaptureWaitsForAdultModels() async throws {
        let f = try await coldURLFixture()
        let coldLedger = LedgerModel(databaseURL: f.base.appendingPathComponent("ledger.sqlite"))
        let coldPickup = PickupModel(databaseURL: f.base.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        let cold = DeviceSurfacesComposition(directory: f.base.appendingPathComponent("surfaces"), bundle: f.bundle, launchArguments: ["--ui-testing"])
        f.cleanup.track(coldLedger, coldPickup, cold)
        cold.bind(ledger: coldLedger, pickup: coldPickup, household: f.household, access: f.access, sceneActive: false)
        cold.handle(url: f.codec.url(handle: nil))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(cold.destination); XCTAssertFalse(cold.privateAuthorized)
        await coldLedger.open(); await coldPickup.load(); await cold.foreground(); await waitForSurfaceDestination(cold)
        guard case .capture = cold.destination else { return XCTFail("Generic cold widget must open capture only after the local models are ready") }
    }
    func testURLReceivedDuringLaterInactivityWaitsForActivation() async throws {
        let f = try await coldURLFixture()
        let saved = f.ledger.workspace, revision = f.ledger.revision
        f.composition.background()
        f.composition.handle(url: f.codec.url(handle: f.handle))
        await f.composition.sourceDidChange()
        XCTAssertNil(f.composition.destination); XCTAssertFalse(f.composition.privateAuthorized)
        await f.composition.foreground(); await waitForSurfaceDestination(f.composition)
        guard case .shop(let id) = f.composition.destination else { return XCTFail("A URL received after a prior active session must wait, then revalidate") }
        XCTAssertEqual(id, saved.selectedShopID); XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }
    func testDeferredURLCannotOpenAfterAuthorityLossBeforeActivation() async throws {
        let f = try await coldURLFixture()
        let saved = f.ledger.workspace, revision = f.ledger.revision
        f.composition.background(); f.composition.handle(url: f.codec.url(handle: f.handle))
        f.access.protect(); await f.composition.sourceDidChange(); await f.composition.foreground()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(f.access.unlocked); XCTAssertFalse(f.composition.privateAuthorized); XCTAssertNil(f.composition.destination)
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }
    func testDeferredURLRevalidatesStalePickupAfterSwitch() async throws {
        let f = try await coldURLFixture()
        f.composition.background(); f.composition.handle(url: f.codec.url(handle: f.handle))
        let madeB = await f.ledger.startShop(title: "Fictional deferred B"); XCTAssertTrue(madeB)
        let saved = f.ledger.workspace, revision = f.ledger.revision
        await f.composition.foreground(); await waitForSurfaceDestination(f.composition)
        guard case .unavailable = f.composition.destination else { return XCTFail("The deferred old pickup handle must fail closed after a switch") }
        XCTAssertEqual(f.ledger.workspace, saved); XCTAssertEqual(f.ledger.revision, revision)
    }
    func testBackgroundAgainCancelsDeferredURL() async throws {
        let f = try await coldURLFixture()
        f.composition.background(); f.composition.handle(url: f.codec.url(handle: f.handle)); f.composition.background()
        await f.composition.foreground()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(f.composition.destination)
    }
    func testCancelledSelectedTextChoicesAndLineEditsDoNotBecomeSavedReview() async throws {
        let f = try await coldURLFixture()
        let now = Date(timeIntervalSince1970: 1_793_664_000)
        let shopID = try XCTUnwrap(f.ledger.shop?.id)
        let original = try XCTUnwrap(f.ledger.shop).stageImport(text: "2 wraps")
        let imported = await f.ledger.editShop(key: "original-wraps", shopID: shopID) { try $0.commitImport(original) }
        XCTAssertTrue(imported)
        let savedWorkspace = f.ledger.workspace, savedRevision = f.ledger.revision
        let inbox = try SelectedTextInbox(url: f.base.appendingPathComponent("surfaces/TestInbox/selected-text.sqlite"))
        _ = try await inbox.stage(operationID: UUID(), originalText: "2 wraps\n3 pears", now: now)
        let pending = try await inbox.pending(now: now)
        let entry = try XCTUnwrap(pending.first)
        await f.composition.review(entry, shopID: shopID)
        let baseline = try XCTUnwrap(f.composition.draft)
        let duplicate = try XCTUnwrap(baseline.preview.lines.first { !$0.duplicateLineIDs.isEmpty })
        let pear = try XCTUnwrap(baseline.preview.lines.first { $0.name == "pears" })
        let targetID = try XCTUnwrap(duplicate.duplicateLineIDs.first)
        let journal = try SurfaceImportJournal(directory: f.base.appendingPathComponent("surfaces/Reviews"))
        XCTAssertNil(baseline.decisions[duplicate.id])

        for interactiveDismissal in [false, true] {
            var changed = try XCTUnwrap(f.composition.draft)
            changed.decisions[duplicate.id] = .skip
            f.composition.saveDraft(changed)
            f.composition.editDraftLine(pear.id, name: "Changed pears", amount: "9", unit: .count)
            XCTAssertEqual(f.composition.draft?.decisions[duplicate.id], .skip)
            XCTAssertEqual(f.composition.draft?.preview.lines.first { $0.id == pear.id }?.name, "Changed pears")
            // The sheet binding writes nil on an interactive dismissal; Cancel uses its action.
            if interactiveDismissal { f.composition.draft = nil }
            else { f.composition.cancelReview() }
            XCTAssertNil(f.composition.draft)
            guard try journal.read(entry.id) == baseline else {
                return XCTFail("Cancelling an unconfirmed review must not persist its choices or line edits")
            }
            XCTAssertEqual(f.ledger.workspace, savedWorkspace)
            XCTAssertEqual(f.ledger.revision, savedRevision)
            let retained = try await inbox.pending(now: now)
            XCTAssertEqual(retained, [entry], "Cancel must retain the explicitly staged source without importing it")
            await f.composition.review(entry, shopID: shopID)
            XCTAssertEqual(f.composition.draft, baseline)
        }

        var explicitlySaved = try XCTUnwrap(f.composition.draft)
        explicitlySaved.decisions[duplicate.id] = .skip
        f.composition.saveDraft(explicitlySaved)
        f.composition.saveReviewDraft()
        XCTAssertEqual(try journal.read(entry.id), explicitlySaved)
        f.composition.editDraftLine(pear.id, name: "Another unsaved edit", amount: "7", unit: .count)
        f.composition.cancelReview()
        await f.composition.review(entry, shopID: shopID)
        XCTAssertEqual(f.composition.draft, explicitlySaved, "Cancel must preserve the last explicitly saved draft")
        XCTAssertEqual(f.ledger.workspace, savedWorkspace)

        var confirmed = try XCTUnwrap(f.composition.draft)
        confirmed.decisions[duplicate.id] = .mergeDuplicate(targetID)
        f.composition.saveDraft(confirmed)
        await f.composition.addReviewedList()
        XCTAssertNil(f.composition.draft)
        let receipt = try await inbox.receipt(entry.id)
        XCTAssertEqual(receipt?.disposition, .consumed)
        XCTAssertNil(try journal.read(entry.id))
        XCTAssertEqual(f.ledger.shop?.importBatches.last?.decisions, confirmed.decisions)
        XCTAssertEqual(f.ledger.shop?.lines.count, 2)
        XCTAssertEqual(f.ledger.shop?.importBatches.count, 2)
        XCTAssertEqual(f.ledger.revision, savedRevision + 1)
    }

    func testSelectedTextRevalidatesDependentChoicesAcrossSavedEdits() async throws {
        let f = try await coldURLFixture()
        let shopID = try XCTUnwrap(f.ledger.shop?.id)
        let now = Date(timeIntervalSince1970: 1_793_664_000)
        let inbox = try SelectedTextInbox(url: f.base.appendingPathComponent("surfaces/TestInbox/selected-text.sqlite"))
        let original = "2 wraps\n2 wraps\n4 rice"
        _ = try await inbox.stage(operationID: UUID(), originalText: original, now: now)
        let pending = try await inbox.pending(now: now)
        let entry = try XCTUnwrap(pending.first)
        await f.composition.review(entry, shopID: shopID)
        let baseline = try XCTUnwrap(f.composition.draft)
        let rows = baseline.preview.lines
        XCTAssertEqual(rows.count, 3)
        let target = rows[0].proposedLineID
        f.composition.chooseImportResolution(.mergeDuplicate(target), for: rows[1].id)
        f.composition.chooseImportResolution(.skip, for: rows[2].id)
        f.composition.editDraftLine(rows[0].id, name: "wraps", amount: "3", unit: .count)
        XCTAssertNil(f.composition.draft?.decisions[rows[1].id])
        XCTAssertEqual(f.composition.draft?.decisions[rows[2].id], .skip)
        f.composition.chooseImportResolution(.addToLine(target), for: rows[1].id)
        f.composition.editDraftLine(rows[0].id, name: "wraps", amount: "4", unit: .count)
        XCTAssertEqual(f.composition.draft?.decisions[rows[1].id], .addToLine(target))
        f.composition.editDraftLine(rows[0].id, name: "beans", amount: "4", unit: .count)
        let changed = try XCTUnwrap(f.composition.draft)
        XCTAssertNil(changed.decisions[rows[1].id])
        XCTAssertEqual(changed.preview.originalText, original)
        XCTAssertEqual(changed.preview.lines.map(\.id), rows.map(\.id))
        XCTAssertEqual(changed.preview.lines.map(\.proposedLineID), rows.map(\.proposedLineID))
        XCTAssertEqual(changed.preview.lines.map(\.originalText), rows.map(\.originalText))
        f.composition.chooseImportResolution(.addNew, for: rows[1].id)
        f.composition.saveReviewDraft()
        f.composition.cancelReview()
        await f.composition.review(entry, shopID: shopID)
        f.composition.editDraftLine(rows[0].id, name: "wraps", amount: "4", unit: .count)
        XCTAssertEqual(f.composition.draft?.decisions[rows[1].id], .addNew, "The explicit separate decision survives save, reopen and a new same-name match")
        await f.composition.addReviewedList()
        let receipt = try XCTUnwrap(f.ledger.shop?.importBatches.last)
        XCTAssertEqual(receipt.preview.id, baseline.preview.id)
        XCTAssertEqual(receipt.preview.originalText, original)
        XCTAssertEqual(receipt.decisions[rows[1].id], .addNew)
        XCTAssertEqual(receipt.decisions[rows[2].id], .skip)

        let handled = await f.ledger.editShop(key: "handled-wraps", shopID: shopID) { try $0.handle(lineID: target, by: "Sam") }
        XCTAssertTrue(handled)
        _ = try await inbox.stage(operationID: UUID(), originalText: "4 wraps", now: now)
        let laterEntries = try await inbox.pending(now: now)
        let later = try XCTUnwrap(laterEntries.first)
        await f.composition.review(later, shopID: shopID)
        let laterDraft = try XCTUnwrap(f.composition.draft)
        let incoming = try XCTUnwrap(laterDraft.preview.lines.first)
        let review = LedgerImportReview(shop: f.ledger.shop, preview: laterDraft.preview, choices: laterDraft.decisions)
        let handledMatch = try XCTUnwrap(review.matches[incoming.id]?.first { $0.id == target })
        XCTAssertTrue(handledMatch.option.canMerge)
        XCTAssertFalse(handledMatch.option.canAdd)
        f.composition.chooseImportResolution(.addToLine(target), for: incoming.id)
        XCTAssertNil(f.composition.draft?.decisions[incoming.id])
        f.composition.chooseImportResolution(.mergeDuplicate(target), for: incoming.id)
        XCTAssertEqual(f.composition.draft?.decisions[incoming.id], .mergeDuplicate(target))
    }
    func testBackgroundDuringConfirmedImportDoesNotRepublishReviewAndStillRecoversOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_793_664_000)
        var interruptSave: (() -> Void)?
        let f = try await coldURLFixture(ledgerClock: { interruptSave?(); return now })
        defer { interruptSave = nil }
        let shopID = try XCTUnwrap(f.ledger.shop?.id)
        let inbox = try SelectedTextInbox(url: f.base.appendingPathComponent("surfaces/TestInbox/selected-text.sqlite"))
        _ = try await inbox.stage(operationID: UUID(), originalText: "3 pears", now: now)
        let pending = try await inbox.pending(now: now)
        let entry = try XCTUnwrap(pending.first)
        await f.composition.review(entry, shopID: shopID)
        let approved = try XCTUnwrap(f.composition.draft)
        let previousRevision = f.ledger.revision
        var interrupted = false
        var republished: [UUID] = []
        let observation = f.composition.$draft.sink { draft in
            if interrupted, let draft { republished.append(draft.id) }
        }
        defer { observation.cancel() }
        // The injected ledger clock runs at the real save boundary, after the
        // journal records confirmation and before the SQLite write is awaited.
        interruptSave = {
            guard !interrupted else { return }
            interrupted = true
            f.composition.background()
        }
        await f.composition.addReviewedList()
        interruptSave = nil
        XCTAssertTrue(interrupted)
        guard republished.isEmpty else {
            return XCTFail("An old import completion must not republish a review after background clears it")
        }
        XCTAssertFalse(f.composition.privateAuthorized)
        XCTAssertNil(f.composition.draft)
        let journal = try SurfaceImportJournal(directory: f.base.appendingPathComponent("surfaces/Reviews"))
        let confirmed = try XCTUnwrap(journal.read(entry.id))
        XCTAssertEqual(confirmed.phase, .committing)
        XCTAssertEqual(confirmed.preview, approved.preview)
        XCTAssertEqual(confirmed.decisions, approved.decisions)
        let unacknowledged = try await inbox.receipt(entry.id)
        XCTAssertEqual(unacknowledged?.disposition, .pending)
        XCTAssertEqual(f.ledger.shop?.importBatches.count, 1)
        XCTAssertEqual(f.ledger.revision, previousRevision + 1)

        // Return explicitly, reconcile the exact saved receipt, and never import twice.
        await f.composition.foreground()
        XCTAssertTrue(f.composition.privateAuthorized)
        await f.composition.review(entry, shopID: shopID)
        XCTAssertNil(f.composition.draft)
        XCTAssertNil(try journal.read(entry.id))
        let acknowledged = try await inbox.receipt(entry.id)
        XCTAssertEqual(acknowledged?.disposition, .consumed)
        XCTAssertEqual(f.ledger.shop?.importBatches.count, 1)
        XCTAssertEqual(f.ledger.shop?.lines.count, 1)
        XCTAssertEqual(f.ledger.revision, previousRevision + 1)
    }

    private func waitForSurfaceDestination(_ surfaces: DeviceSurfacesComposition) async {
        for _ in 0..<100 {
            if surfaces.destination != nil { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    private struct ColdURLFixture {
        let cleanup: SQLiteFixtureDirectory
        let base: URL, bundle: Bundle
        let ledger: LedgerModel, pickup: PickupModel, household: HouseholdModel, access: WorkspaceAccess
        let composition: DeviceSurfacesComposition, codec: SurfaceURLCodec, handle: RouteHandle
    }
    private func coldURLFixture(ledgerClock: @escaping () -> Date = Date.init) async throws -> ColdURLFixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(base, test: self)
        let bundleURL = base.appendingPathComponent("Surface.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "invalid.fixture.cold", SurfaceInfo.schemeKey: "roominthecart-fixture"], format: .xml, options: 0).write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite"), clock: ledgerClock); cleanup.track(ledger); await ledger.open()
        let started = await ledger.startShop(title: "Fictional cold A"); XCTAssertTrue(started)
        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: []); cleanup.track(pickup); await pickup.load()
        let household = HouseholdModel(bundle: bundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "ColdSurface." + UUID().uuidString, now = Date(timeIntervalSince1970: 1_793_664_000)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), access = WorkspaceAccess(defaults: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let composition = DeviceSurfacesComposition(directory: base.appendingPathComponent("surfaces"), bundle: bundle, clock: { now }, launchArguments: ["--ui-testing"])
        cleanup.track(composition)
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let widget = try WidgetProjectionFile(directory: base.appendingPathComponent("surfaces/TestWidget"))
        let projection = try await publishedWidget(widget, at: now)
        return ColdURLFixture(cleanup: cleanup, base: base, bundle: bundle, ledger: ledger, pickup: pickup, household: household, access: access, composition: composition, codec: try SurfaceURLCodec(scheme: "roominthecart-fixture"), handle: try XCTUnwrap(projection.routeHandle))
    }

    func testRetainedWidgetRouteCannotOpenPreviouslySelectedShop() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(base, test: self)
        let surfaceDirectory = base.appendingPathComponent("surfaces")
        var now = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite")); cleanup.track(ledger); await ledger.open()
        let madeA = await ledger.startShop(title: "Fictional widget A"); XCTAssertTrue(madeA)
        let shopA = try XCTUnwrap(ledger.shop?.id)
        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: []); cleanup.track(pickup); await pickup.load()
        let bundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: bundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "RetainedWidget." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let widget = try WidgetProjectionFile(directory: surfaceDirectory.appendingPathComponent("TestWidget"))
        let composition = DeviceSurfacesComposition(directory: surfaceDirectory, bundle: bundle,
            clock: { now }, launchArguments: ["--ui-testing"])
        cleanup.track(composition)
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let projectionA = try await publishedWidget(widget, at: now)
        let handleA = try XCTUnwrap(projectionA.routeHandle)
        now += 60
        let madeB = await ledger.startShop(title: "Fictional widget B"); XCTAssertTrue(madeB)
        let shopB = try XCTUnwrap(ledger.shop?.id)
        let projectionB = try await publishedWidget(widget, at: now)
        let handleB = try XCTUnwrap(projectionB.routeHandle)
        XCTAssertNotEqual(handleA, handleB)
        let saved = ledger.workspace, revision = ledger.revision
        await composition.open(handleA)
        guard case .unavailable = composition.destination else { return XCTFail("Retained A handle must not select A after B becomes current") }
        XCTAssertEqual(ledger.workspace, saved); XCTAssertEqual(ledger.revision, revision)
        XCTAssertEqual(Set(ledger.workspace.shops.map(\.id)), [shopA, shopB])
        await composition.open(handleB)
        guard case .shop(let opened) = composition.destination else { return XCTFail("Current B widget route must remain usable") }
        XCTAssertEqual(opened, shopB); XCTAssertEqual(ledger.workspace, saved)
        let routes = try SurfaceRouteStore(url: surfaceDirectory.appendingPathComponent("routes.json"))
        XCTAssertFalse(try routes.all().contains { $0.route.handle == handleA })
        composition.background(); await composition.foreground()
        await composition.open(handleA)
        guard case .unavailable = composition.destination else { return XCTFail("Foreground reconciliation must not resurrect retained A") }
        XCTAssertEqual(ledger.workspace, saved); XCTAssertEqual(ledger.revision, revision)
    }

    func testResolvedWidgetDestinationDoesNotReselectAfterPickupChanges() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(base, test: self)
        let surfaceDirectory = base.appendingPathComponent("surfaces")
        var now = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite"))
        cleanup.track(ledger)
        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        cleanup.track(pickup)
        let bundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: bundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "WidgetPresentation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let composition = DeviceSurfacesComposition(directory: surfaceDirectory, bundle: bundle,
            clock: { now }, launchArguments: ["--ui-testing"])
        cleanup.track(composition)
        await ledger.open(); await pickup.load()
        let madeA = await ledger.startShop(title: "Fictional widget A"); XCTAssertTrue(madeA)
        let shopA = try XCTUnwrap(ledger.shop?.id)
        let widget = try WidgetProjectionFile(directory: surfaceDirectory.appendingPathComponent("TestWidget"))
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let projectionA = try await publishedWidget(widget, at: now)
        await composition.open(try XCTUnwrap(projectionA.routeHandle))
        let resolvedA = try XCTUnwrap(composition.destination)
        guard case .shop(let resolvedID) = resolvedA else { return XCTFail("A must resolve while it is current") }
        XCTAssertEqual(resolvedID, shopA)

        // Change selection after successful resolution but before the destination's
        // presentation action runs.
        now += 60
        let madeB = await ledger.startShop(title: "Fictional widget B"); XCTAssertTrue(madeB)
        _ = try await publishedWidget(widget, at: now)
        let saved = ledger.workspace, revision = ledger.revision
        let presentation = DeviceSurfacesDestination(composition: composition, destination: resolvedA,
            ledger: ledger, pickup: pickup, household: household)
        let began = await presentation.prepareForPresentation()
        XCTAssertTrue(began)
        XCTAssertEqual(ledger.workspace, saved, "Presentation must not reselect the formerly current pickup")
        XCTAssertEqual(ledger.revision, revision, "Opening a widget must not create a ledger commit")

        composition.background()
        let beganAfterBackground = await presentation.prepareForPresentation()
        XCTAssertFalse(beganAfterBackground, "The retained destination must lose presentation authority in the background")
        XCTAssertEqual(ledger.workspace, saved)
        XCTAssertEqual(ledger.revision, revision)
    }

    func testLargeListSearchLeavesWidgetAloneAndCommittedChangesRefreshIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(base, test: self)
        let privateDirectory = base.appendingPathComponent("isolated-surfaces")
        var now = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite"))
        cleanup.track(ledger)
        await ledger.open()
        let started = await ledger.startShop(title: "Fictional pickup")
        XCTAssertTrue(started)
        let shop = try XCTUnwrap(ledger.shop)
        let source = (0..<500).map { "Fixture arroz item \($0)" }.joined(separator: "\n")
        let preview = try shop.stageImport(text: source, source: .paste)
        let imported = await ledger.editShop(key: "surface-performance-import", shopID: shop.id) {
            try $0.commitImport(preview)
        }
        XCTAssertTrue(imported)
        let savedShop = try XCTUnwrap(ledger.shop)
        XCTAssertEqual(savedShop.lines.count, 500)

        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        cleanup.track(pickup)
        await pickup.load()
        let bundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: bundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "SurfaceSearchTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let widget = try WidgetProjectionFile(directory: privateDirectory.appendingPathComponent("TestWidget"))
        let composition = DeviceSurfacesComposition(directory: privateDirectory, bundle: bundle,
            clock: { now }, launchArguments: ["--ui-testing"])
        cleanup.track(composition)
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        let original = try await publishedWidget(widget, at: now)
        let route = try XCTUnwrap(original.routeHandle)

        now += 60
        for index in 0..<20 {
            ledger.search = "item \(480 + index)"
            XCTAssertEqual(savedShop.search(ledger.search).count, 1)
            try await Task.sleep(for: .milliseconds(25))
        }
        ledger.error = "Fictional form error"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try widget.read(), original, "Search and form errors should leave the published shortcut alone.")

        now += 60
        let line = try XCTUnwrap(savedShop.lines.first)
        let checked = await ledger.editShop(key: "surface-performance-check", shopID: shop.id) {
            try $0.setChecked(lineID: line.id, checked: true)
        }
        XCTAssertTrue(checked)
        let updated = try await publishedWidget(widget, at: now)
        XCTAssertEqual(updated.routeHandle, route)

        now += 60
        let newPickup = await ledger.startShop(title: "Next fictional pickup")
        XCTAssertTrue(newPickup)
        let selected = try await publishedWidget(widget, at: now)
        XCTAssertNotNil(selected.routeHandle)
        XCTAssertNotEqual(selected.routeHandle, route)

        composition.background()
        XCTAssertNil(try widget.read().routeHandle)
    }

    private func publishedWidget(_ file: WidgetProjectionFile, at time: Date) async throws -> WidgetProjection {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let value = try? file.read(), value.writtenAt == time { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(nil, "The bound composition did not publish a widget for \(time).")
    }

    func testBindingBeforePickupLoadPreservesDurablePickupSurfaceState() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(base, test: self)
        let privateDirectory = base.appendingPathComponent("isolated-surfaces")
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        let ledger = LedgerModel(databaseURL: base.appendingPathComponent("ledger.sqlite")); cleanup.track(ledger); await ledger.open()
        XCTAssertTrue(ledger.ready)
        let pickup = PickupModel(databaseURL: base.appendingPathComponent("pickup.sqlite"), launchArguments: [])
        cleanup.track(pickup)
        XCTAssertFalse(pickup.ready)
        let testBundle = Bundle(for: DeviceSurfacesCompositionStartupTests.self)
        let household = HouseholdModel(bundle: testBundle, outboxURL: base.appendingPathComponent("outbox.json"))
        let suite = "SurfaceStartupTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let access = WorkspaceAccess(defaults: defaults)
        let routes = try SurfaceRouteStore(url: privateDirectory.appendingPathComponent("routes.json"))
        let reminderStore = try ReminderStore(url: privateDirectory.appendingPathComponent("reminders.sqlite"))
        cleanup.track(reminderStore)
        let target = UUID(), handle = RouteHandle.random(), reminderID = UUID()
        let route = try PrivateRoute(handle: handle, personaID: access.localActorID, targetID: target, generation: UUID(), destination: .shoppingList, expiresAt: .distantFuture)
        let savedRoute = SurfaceRouteRecord(route: route, target: .offer(workspaceID: UUID(), journeyID: UUID(), offerID: target), sourceRevision: 1, reminderID: reminderID)
        try routes.put(savedRoute)
        let intent = try ReminderIntent(id: reminderID, personaID: access.localActorID, targetID: target, subject: .offer, sourceRevision: 1, routeHandle: handle,
            localTime: CivilReminderTime(year: 2026, month: 11, day: 3, hour: 13, minute: 0, timeZoneID: "UTC", confirmedGMTOffset: 0),
            expiresAt: date.addingTimeInterval(172_800), cutoff: date.addingTimeInterval(86_400), language: .english, now: date)
        _ = try await reminderStore.put(intent, expectedVersion: nil, now: date)
        // Both the directory and the policy are explicit: no live group/notification ports.
        let composition = DeviceSurfacesComposition(directory: privateDirectory, bundle: testBundle, clock: { date }, launchArguments: ["--ui-testing"])
        cleanup.track(composition)
        composition.bind(ledger: ledger, pickup: pickup, household: household, access: access)
        await composition.foreground()
        XCTAssertFalse(composition.available)
        XCTAssertEqual(try routes.all(), [savedRoute])
        let saved = try await reminderStore.get(reminderID); XCTAssertEqual(saved?.status, .desired)
    }
}

#endif
