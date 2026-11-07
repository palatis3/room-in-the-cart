import XCTest
import CoreDomain
import DeviceSurfaces
@testable import RoomInTheCart

@MainActor final class SurfaceIntegrationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_664_000)
    private func fixture() async throws -> (SelectedTextInbox, SurfaceImportJournal, FakeLedgerPort, SelectedTextEntry, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = try SelectedTextInbox(url: dir.appendingPathComponent("inbox.sqlite"))
        _ = try await inbox.stage(operationID: UUID(), originalText: "12 wraps\n2 apples", editedText: "12 wraps\n3 apples", now: now)
        let entry = try await inbox.pending(now: now)[0]
        let journal = try SurfaceImportJournal(directory: dir.appendingPathComponent("reviews"))
        return (inbox, journal, FakeLedgerPort(), entry, dir)
    }
    func testCommitPersistsFullReviewAndAcknowledgesOnce() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let draftResult = try await bridge.open(entry, shopID: port.value.id)
        let draft = try XCTUnwrap(draftResult)
        XCTAssertEqual(draft.preview.id, entry.id)
        try await bridge.commit(draft)
        XCTAssertEqual(port.value.importBatches.count, 1)
        XCTAssertNil(try journal.read(entry.id))
        let receipt = try await inbox.receipt(entry.id)
        XCTAssertEqual(receipt?.disposition, .consumed)
        let pending = try await inbox.pending(now: now); XCTAssertTrue(pending.isEmpty)
    }
    func testInterruptedAcknowledgmentReopensReceiptWithoutRestaging() async throws {
        let (inbox, journal, port, entry, dir) = try await fixture()
        var bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let draftResult = try await bridge.open(entry, shopID: port.value.id)
        let draft = try XCTUnwrap(draftResult)
        port.failureAfterCommit = true
        do { try await bridge.commit(draft); XCTFail() } catch {}
        XCTAssertEqual(try journal.read(entry.id)?.phase, .committing)
        XCTAssertEqual(port.value.importBatches.count, 1)
        port.failureAfterCommit = false
        let reopened = try SurfaceImportJournal(directory: dir.appendingPathComponent("reviews"))
        bridge = SurfaceImportBridge(inbox: inbox, journal: reopened, port: port, clock: { self.now })
        let replay = try await bridge.open(entry, shopID: port.value.id); XCTAssertNil(replay)
        XCTAssertEqual(port.stageCalls, 1)
        XCTAssertEqual(port.value.importBatches.count, 1)
    }
    func testInterruptedBeforeCommitKeepsAllIDsAndDecisions() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let originalResult = try await bridge.open(entry, shopID: port.value.id)
        let original = try XCTUnwrap(originalResult)
        var reviewed = original; reviewed.decisions[reviewed.preview.lines[1].id] = .skip
        try bridge.saveReview(reviewed, replacing: original)
        port.failureBeforeCommit = true
        do { try await bridge.commit(reviewed); XCTFail() } catch {}
        port.failureBeforeCommit = false
        let reopenedResult = try await bridge.open(entry, shopID: port.value.id)
        let reopened = try XCTUnwrap(reopenedResult)
        XCTAssertEqual(reopened.preview, reviewed.preview); XCTAssertEqual(reopened.decisions, reviewed.decisions)
        try await bridge.commit(reopened)
        XCTAssertEqual(port.value.importBatches.first?.decisions, reviewed.decisions)
        XCTAssertEqual(port.stageCalls, 1)
    }
    func testChangedScopeCannotReadOrCommitReview() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let draftResult = try await bridge.open(entry, shopID: port.value.id)
        let draft = try XCTUnwrap(draftResult)
        port.scope = SurfaceImportScope(personaID: UUID(), workspaceID: UUID())
        do { _ = try await bridge.open(entry, shopID: port.value.id); XCTFail() } catch {}
        do { try await bridge.commit(draft); XCTFail() } catch {}
        XCTAssertTrue(port.value.importBatches.isEmpty)
        let pending = try await inbox.pending(now: now); XCTAssertEqual(pending.count, 1)
    }
    func testAuthorityChangingDuringCommitDoesNotAcknowledge() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let draftResult = try await bridge.open(entry, shopID: port.value.id)
        let draft = try XCTUnwrap(draftResult)
        port.changeGenerationOnCommit = true
        do { try await bridge.commit(draft); XCTFail() } catch {}
        let pending = try await inbox.pending(now: now); XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(port.value.importBatches.count, 1)
    }
    func testReceiptMismatchCannotConsumeInbox() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let draftResult = try await bridge.open(entry, shopID: port.value.id)
        let draft = try XCTUnwrap(draftResult)
        var altered = draft.preview; altered.lines[0].name = "Different item"
        try port.value.commitImport(altered, decisions: draft.decisions)
        do { _ = try await bridge.open(entry, shopID: port.value.id); XCTFail() } catch {}
        let receipt = try await inbox.receipt(entry.id); XCTAssertEqual(receipt?.disposition, .pending)
    }
    func testJournalRejectsChangedIdentityWithoutReplacingHealthyDraft() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let originalResult = try await bridge.open(entry, shopID: port.value.id)
        let original = try XCTUnwrap(originalResult)
        var invalid = original; invalid.preview = try port.value.stageImport(text: "12 wraps", source: .selectedText)
        XCTAssertThrowsError(try journal.save(invalid, replacing: original))
        XCTAssertEqual(try journal.read(entry.id), original)
    }
    func testErasureAndExpiryRemovePrivateReviewCopies() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        _ = try await bridge.open(entry, shopID: port.value.id)
        try journal.eraseWorkspace(UUID()); XCTAssertNotNil(try journal.read(entry.id))
        try journal.eraseWorkspace(try XCTUnwrap(port.scope).workspaceID); XCTAssertNil(try journal.read(entry.id))
        _ = try await bridge.open(entry, shopID: port.value.id)
        try journal.prune(pendingIDs: [entry.id], now: entry.receipt.expiresAt)
        XCTAssertNil(try journal.read(entry.id))
    }
    func testExplicitStaleReviewRetainsOperationAndPriorConfirmedAttempt() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let initialResult = try await bridge.open(entry, shopID: port.value.id)
        let initial = try XCTUnwrap(initialResult)
        port.failureBeforeCommit = true
        do { try await bridge.commit(initial); XCTFail() } catch {}
        port.failureBeforeCommit = false
        _ = try port.value.addManualLine(name: "Soap", quantity: nil)
        let refreshResult = try await bridge.refreshReview(entry.id)
        let refreshed = try XCTUnwrap(refreshResult)
        XCTAssertEqual(refreshed.id, initial.id)
        XCTAssertEqual(refreshed.preview.baseRevision, port.value.revision)
        XCTAssertEqual(refreshed.confirmedAttempts.first?.preview, initial.preview)
        XCTAssertNotEqual(refreshed.preview.lines.map(\.id), initial.preview.lines.map(\.id))
        try await bridge.commit(refreshed)
        XCTAssertEqual(port.value.importBatches.count, 1)
    }
    func testRacingOldReceiptIsRecognizedAfterExplicitFreshReview() async throws {
        let (inbox, journal, port, entry, _) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        let initialResult = try await bridge.open(entry, shopID: port.value.id)
        let initial = try XCTUnwrap(initialResult)
        port.failureBeforeCommit = true
        do { try await bridge.commit(initial); XCTFail() } catch {}
        port.failureBeforeCommit = false
        _ = try await bridge.refreshReview(entry.id)
        try port.value.commitImport(initial.preview, decisions: initial.decisions)
        let reopened = try await bridge.open(entry, shopID: port.value.id)
        XCTAssertNil(reopened); XCTAssertEqual(port.value.importBatches.count, 1)
        let receipt = try await inbox.receipt(entry.id); XCTAssertEqual(receipt?.disposition, .consumed)
    }
    func testFutureReviewSchemaFailsClosedWithoutReplacingBytes() async throws {
        let (inbox, journal, port, entry, dir) = try await fixture()
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { self.now })
        _ = try await bridge.open(entry, shopID: port.value.id)
        let file = dir.appendingPathComponent("reviews/" + entry.id.uuidString + ".json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["version"] = 99
        let future = try JSONSerialization.data(withJSONObject: object)
        try future.write(to: file)
        XCTAssertThrowsError(try journal.read(entry.id))
        XCTAssertThrowsError(try journal.eraseWorkspace(try XCTUnwrap(port.scope).workspaceID))
        XCTAssertEqual(try Data(contentsOf: file), future)
    }
    func testRouteStoreIdempotencyAndExactScopeRemoval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SurfaceRouteStore(url: dir.appendingPathComponent("routes.json"))
        let workspace = UUID(), targetID = UUID()
        let target = SurfacePrivateTarget.offer(workspaceID: workspace, journeyID: UUID(), offerID: targetID)
        let route = try PrivateRoute(handle: .random(), personaID: UUID(), targetID: targetID, generation: UUID(), destination: .shoppingList, expiresAt: now.addingTimeInterval(100))
        let row = SurfaceRouteRecord(route: route, target: target, sourceRevision: 1, reminderID: UUID())
        try store.put(row); try store.put(row); XCTAssertEqual(try store.all(), [row])
        XCTAssertThrowsError(try store.put(SurfaceRouteRecord(route: route, target: target, sourceRevision: 2, reminderID: row.reminderID)))
        try store.remove(route.handle); try store.remove(route.handle); XCTAssertTrue(try store.all().isEmpty)
    }
}

@MainActor private final class FakeLedgerPort: SurfaceLedgerPort {
    var scope: SurfaceImportScope? = SurfaceImportScope(personaID: UUID(), workspaceID: UUID())
    var generation: UUID? = UUID()
    var hasPendingSave = false
    var value = ShoppingLedger()
    var stageCalls = 0
    var failureBeforeCommit = false, failureAfterCommit = false, changeGenerationOnCommit = false
    func shop(_ id: UUID) -> ShoppingLedger? { value.id == id ? value : nil }
    func stage(_ entry: SelectedTextEntry, shopID: UUID) throws -> StagedListImport {
        stageCalls += 1
        return try value.stageImport(text: entry.textForReview, source: .selectedText, importID: entry.id)
    }
    func reload() async throws {}
    func commit(_ draft: SurfaceImportDraft) async throws {
        if failureBeforeCommit { throw SurfaceError.unavailable }
        try value.commitImport(draft.preview, decisions: draft.decisions)
        if changeGenerationOnCommit { generation = UUID() }
        if failureAfterCommit { throw SurfaceError.unavailable }
    }
}

import XCTest
import CoreDomain
import DeviceSurfaces
@testable import RoomInTheCart

@MainActor final class LedgerSelectedTextPortTests: XCTestCase {
    func testRealLedgerRestartAcknowledgesExactReceiptWithoutDuplicate() async throws {
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledgerURL = dir.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: ledgerURL, clock: { date }); await model.open()
        let shop = ShoppingLedger()
        let created = await model.change(key: "new") { $0.shops = [shop]; $0.selectedShopID = shop.id }; XCTAssertTrue(created)
        let persona = UUID(), generation = UUID()
        let scope = SurfaceImportScope(personaID: persona, workspaceID: try XCTUnwrap(model.sourceWorkspaceID))
        let inbox = try SelectedTextInbox(url: dir.appendingPathComponent("shared/inbox.sqlite"))
        _ = try await inbox.stage(operationID: UUID(), originalText: "12 wraps\n2 apples", now: date)
        let entry = try await inbox.pending(now: date)[0]
        let journal = try SurfaceImportJournal(directory: dir.appendingPathComponent("reviews"))
        let port = LedgerSelectedTextPort(ledger: model, scope: { scope }, generation: { generation })
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { date })
        let staged = try await bridge.open(entry, shopID: shop.id)
        var draft = try XCTUnwrap(staged); draft.phase = .committing
        try journal.save(draft, replacing: staged)
        // Simulate process death after the actual SQLite ledger commit and before inbox acknowledgment.
        try await port.commit(draft)
        let restarted = LedgerModel(databaseURL: ledgerURL, clock: { date }); await restarted.open()
        XCTAssertEqual(restarted.shop?.importBatches.count, 1)
        let restoredPort = LedgerSelectedTextPort(ledger: restarted, scope: { scope }, generation: { generation })
        let restoredJournal = try SurfaceImportJournal(directory: dir.appendingPathComponent("reviews"))
        let restored = SurfaceImportBridge(inbox: inbox, journal: restoredJournal, port: restoredPort, clock: { date })
        let result = try await restored.open(entry, shopID: shop.id); XCTAssertNil(result)
        let disposition = try await inbox.receipt(entry.id)?.disposition; XCTAssertEqual(disposition, .consumed)
        XCTAssertEqual(restarted.shop?.importBatches.count, 1)
        XCTAssertEqual(restarted.shop?.contributions.count, 2)
    }
    func testActualLedgerScopeLossPreventsMutationAndLeavesInboxPending() async throws {
        let date = Date(timeIntervalSince1970: 1_793_664_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = LedgerModel(databaseURL: dir.appendingPathComponent("ledger.sqlite")); await model.open()
        let shop = ShoppingLedger()
        _ = await model.change(key: "new") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        var scope: SurfaceImportScope? = SurfaceImportScope(personaID: UUID(), workspaceID: try XCTUnwrap(model.sourceWorkspaceID))
        let generation = UUID()
        let inbox = try SelectedTextInbox(url: dir.appendingPathComponent("shared/inbox.sqlite"))
        _ = try await inbox.stage(operationID: UUID(), originalText: "12 wraps", now: date)
        let entry = try await inbox.pending(now: date)[0]
        let journal = try SurfaceImportJournal(directory: dir.appendingPathComponent("reviews"))
        let port = LedgerSelectedTextPort(ledger: model, scope: { scope }, generation: { scope == nil ? nil : generation })
        let bridge = SurfaceImportBridge(inbox: inbox, journal: journal, port: port, clock: { date })
        let staged = try await bridge.open(entry, shopID: shop.id)
        let draft = try XCTUnwrap(staged); scope = nil
        do { try await bridge.commit(draft); XCTFail() } catch {}
        XCTAssertTrue(model.shop?.importBatches.isEmpty == true)
        let pending = try await inbox.pending(now: date); XCTAssertEqual(pending.count, 1)
    }
}
