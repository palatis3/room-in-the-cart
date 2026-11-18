import XCTest
import LocalStore
import CoreDomain
@testable import RoomInTheCart

@MainActor final class FirstListTests: XCTestCase {
    func testCloseResumeReviewCommitExportAndUndoUseExistingLedger() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite"), owner = Data(repeating: 7, count: 32)
        let ledger = LedgerModel(databaseURL: url)
        await ledger.open()
        let store = try XCTUnwrap(ledger.firstListStore)
        let editor = try FirstListEditor(store: store, owner: owner, base: 0, saved: nil, authorize: { true })
        var contents = editor.content
        contents.original = "2 kg arroz\ncebollas"
        editor.update(contents)
        contents.original += "\n3 limones"
        let saved = await editor.flush(contents)
        XCTAssertNotNil(saved); XCTAssertNil(ledger.shop)
        var oversized = contents
        oversized.original = String(repeating: "x", count: StagedListImport.maximumTextBytes + 1)
        let rejected = await editor.flush(oversized)
        XCTAssertNil(rejected)
        XCTAssertTrue(editor.failed)
        let restoredVersion = await editor.flush(contents)
        XCTAssertEqual(restoredVersion, saved)
        XCTAssertFalse(editor.failed)
        XCTAssertNil(ledger.shop)
        XCTAssertFalse(String(decoding: try ledger.exportPayload(), as: UTF8.self).contains("cebollas"))

        let resumed = LedgerModel(databaseURL: url)
        await resumed.open()
        let newStore = try XCTUnwrap(resumed.firstListStore)
        let restored = try await newStore.firstListDraft(owner: owner)
        let session = try FirstListEditor(store: newStore, owner: owner, base: 0, saved: restored, authorize: { true })
        XCTAssertEqual(session.content, contents)
        let candidate = ShoppingLedger(id: contents.shopID, title: "Pedido")
        let review = try candidate.stageImport(text: contents.original, importID: contents.importID)
        contents.preview = review; contents.choices = LedgerImportReview.initialChoices(review)
        let stored = await session.flush(contents)
        let reviewed = try XCTUnwrap(stored)
        let savedReview = try await newStore.firstListDraft(owner: owner)
        let reopenedReview = try FirstListEditor(store: newStore, owner: owner, base: 0, saved: savedReview, authorize: { true })
        XCTAssertEqual(reopenedReview.content.preview, review)
        XCTAssertEqual(reopenedReview.content.choices, contents.choices)
        let denied = await resumed.commitFirstList(review, decisions: contents.choices, draft: reviewed, title: candidate.title, authorize: { false })
        XCTAssertFalse(denied); XCTAssertNil(resumed.shop)
        let retryVersion = await reopenedReview.flush(contents)
        XCTAssertEqual(retryVersion, reviewed)
        let accepted = await resumed.commitFirstList(review, decisions: contents.choices, draft: try XCTUnwrap(retryVersion), title: candidate.title, authorize: { true })
        XCTAssertTrue(accepted); XCTAssertEqual(resumed.workspace.shops.count, 1)
        XCTAssertEqual(resumed.shop?.importBatches.first?.preview.originalText, contents.original)
        let afterSave = try await newStore.firstListDraft(owner: owner)
        XCTAssertNil(afterSave)
        let exported = try LedgerModel.validatePayload(resumed.exportPayload())
        XCTAssertEqual(exported, resumed.workspace)
        let next = LedgerModel(databaseURL: url)
        await next.open()
        let undone = await next.editShop(key: "undo-first", shopID: candidate.id) { try $0.undoImport(batchID: review.id) }
        XCTAssertTrue(undone); XCTAssertNotNil(next.shop?.importBatches.first?.undoneAt)
    }
    func testDiscardClosesTheEditorAndCannotResurrectQueuedTyping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await ledger.open()
        let store = try XCTUnwrap(ledger.firstListStore), owner = Data(repeating: 4, count: 32)
        let editor = try FirstListEditor(store: store, owner: owner, base: 0, saved: nil, authorize: { true })
        var contents = editor.content
        contents.original = "milk"
        editor.update(contents)
        let discarded = await editor.discard()
        XCTAssertTrue(discarded)
        let lateEdit = await editor.flush(contents)
        XCTAssertNil(lateEdit)
        let draft = try await store.firstListDraft(owner: owner)
        XCTAssertNil(draft)
        XCTAssertNil(ledger.shop)
    }

    func testInterruptedDraftNeedsNewReviewAfterAnotherPickupIsCreated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await ledger.open()
        let store = try XCTUnwrap(ledger.firstListStore), owner = Data(repeating: 9, count: 32)
        let first = try FirstListEditor(store: store, owner: owner, base: 0, saved: nil, authorize: { true })
        var old = first.content
        old.original = "onions"
        old.preview = try ShoppingLedger(id: old.shopID, title: "First").stageImport(text: old.original, importID: old.importID)
        let originalVersion = await first.flush(old)
        XCTAssertNotNil(originalVersion)
        let started = await ledger.startShop(title: "Another pickup")
        XCTAssertTrue(started)
        let other = try XCTUnwrap(ledger.shop)
        let saved = try await store.firstListDraft(owner: owner)
        let next = try FirstListEditor(store: store, owner: owner, base: ledger.revision, saved: saved, authorize: { true })
        XCTAssertTrue(next.stale)
        await next.reviewAgain()
        XCTAssertFalse(next.stale)
        var fresh = next.content
        XCTAssertEqual(fresh.original, old.original); XCTAssertNil(fresh.preview)
        XCTAssertNotEqual(fresh.shopID, old.shopID); XCTAssertNotEqual(fresh.importID, old.importID)
        let review = try ShoppingLedger(id: fresh.shopID, title: "First").stageImport(text: fresh.original, importID: fresh.importID)
        fresh.preview = review; fresh.choices = LedgerImportReview.initialChoices(review)
        let flushed = await next.flush(fresh)
        let version = try XCTUnwrap(flushed)
        let accepted = await ledger.commitFirstList(review, decisions: fresh.choices, draft: version, title: "First", authorize: { true })
        XCTAssertTrue(accepted)
        XCTAssertEqual(ledger.workspace.shops.map(\.id), [other.id, fresh.shopID])
        XCTAssertEqual(ledger.workspace.shops.first, other)
    }

}
