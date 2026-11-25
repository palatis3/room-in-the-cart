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
    func testFirstPastedListKeepsTheDuplicateDecisionAndUndonePickAfterOfflineReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let url = directory.appendingPathComponent("ledger.sqlite")
        let ledger = LedgerModel(databaseURL: url)
        cleanup.track(ledger)
        await ledger.open()
        let store = try XCTUnwrap(ledger.firstListStore)
        let editor = try FirstListEditor(store: store, owner: Data(repeating: 1, count: 32), base: ledger.revision,
                                         saved: nil, authorize: { true })
        var draft = editor.content
        draft.original = "Eggs\nRice\nMilk\nRice"
        draft.source = .paste
        let shop = ShoppingLedger(id: draft.shopID)
        let preview = try shop.stageImport(text: draft.original, source: .paste, importID: draft.importID,
                                           reviewPackageCounts: true)
        let duplicate = try XCTUnwrap(preview.lines.last)
        draft.preview = preview
        draft.choices = LedgerImportReview.initialChoices(preview)
        XCTAssertNil(draft.choices[duplicate.id])
        draft.choices[duplicate.id] = .skip
        let flushed = await editor.flush(draft)
        let saved = await ledger.commitFirstList(preview, decisions: draft.choices, draft: try XCTUnwrap(flushed),
                                                 title: "Groceries", authorize: { true })
        XCTAssertTrue(saved)
        let list = try XCTUnwrap(ledger.shop)
        let rice = try XCTUnwrap(list.lines.first { $0.name == "Rice" })
        let picked = await ledger.changeGroceryCheck(rice, in: list, checked: true)
        XCTAssertTrue(picked)
        let updated = try XCTUnwrap(ledger.shop)
        let checked = try XCTUnwrap(updated.lines.first { $0.id == rice.id })
        let undone = await ledger.changeGroceryCheck(checked, in: updated, checked: false)
        XCTAssertTrue(undone)

        let reopened = LedgerModel(databaseURL: url)
        cleanup.track(reopened)
        await reopened.open()
        let groceries = try XCTUnwrap(reopened.shop)
        XCTAssertEqual(groceries.id, draft.shopID)
        XCTAssertEqual(groceries.lines.map(\.name), ["Eggs", "Rice", "Milk"])
        XCTAssertTrue(groceries.recentlyChecked.isEmpty)
        XCTAssertEqual(groceries.importBatches.first?.decisions[duplicate.id], .skip)
    }

    func testQuickGroceryTypingAndExplicitAddUseOnlyTheCurrentDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await ledger.open()
        let store = try XCTUnwrap(ledger.firstListStore)
        let key = LedgerStore.quickGroceryDraftOwner(persona: Data(repeating: 3, count: 32), shopID: nil)
        let editor = try QuickGroceryDraft(shopID: nil, store: store, owner: key, record: nil)
        for text in ["C", "Ca", "Car"] { editor.update(text, revision: 0) }
        let saved = await editor.prepareToSubmit("Car", revision: 0)
        XCTAssertTrue(saved)
        let record = try await store.firstListDraft(owner: key)
        XCTAssertEqual(record?.payload, Data("Car".utf8))
        XCTAssertTrue(ledger.workspace.shops.isEmpty)
        XCTAssertFalse(String(decoding: try ledger.exportPayload(), as: UTF8.self).contains("Car"))

        let resumed = try QuickGroceryDraft(shopID: nil, store: store, owner: key, record: record)
        resumed.update("Carrots", revision: 0)
        let ready = await resumed.prepareToSubmit("Carrots", revision: 0)
        XCTAssertTrue(ready)
        let version = try XCTUnwrap(resumed.version)
        let preview = try XCTUnwrap(try QuickGrocery.stage("Carrots", in: ShoppingLedger(title: "Pickup")))
        let denied = await ledger.addQuickGrocery(preview, selectedShopID: nil, workspaceID: store.workspaceID, quickDraft: version, authorize: { false })
        XCTAssertFalse(denied)
        let retained = try await store.firstListDraft(owner: key)
        XCTAssertEqual(retained?.version, version)
        let added = await ledger.addQuickGrocery(preview, selectedShopID: nil, workspaceID: store.workspaceID, quickDraft: version, authorize: { true })
        XCTAssertTrue(added)
        await resumed.committed(version, wording: "Carrots", revision: ledger.revision)
        XCTAssertEqual(resumed.text, "")
        let cleared = try await store.firstListDraft(owner: key)
        XCTAssertNil(cleared)
        XCTAssertEqual(ledger.shop?.lines.map(\.name), ["Carrots"])
    }

    func testAppendingRestockPreservesReviewedDraftAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite"), owner = Data(repeating: 6, count: 32)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LedgerStore(url: url)
        let editor = try FirstListEditor(store: store, owner: owner, base: 0, saved: nil, authorize: { true })
        var input = editor.content
        let shop = ShoppingLedger(id: input.shopID, title: "List")
        input.original = (1...50).map { "Item " + String($0) }.joined(separator: "\n")
        var reviewed = try shop.stageImport(text: input.original, importID: input.importID)
        reviewed.lines[0].name = "Corrected name"
        reviewed.lines[0].quantity = Quantity(amount: .one, unit: .cup, originalLiteral: "1")
        reviewed.lines[1].exclusions = ["sesame"]
        input.preview = reviewed
        input.choices = LedgerImportReview.initialChoices(reviewed)
        let skip = reviewed.lines[2].id
        input.choices[skip] = .skip
        input.explicitSeparate = [reviewed.lines[0].id]
        input.invalidAmounts[reviewed.lines[3].id] = .init(text: "1/", unit: .cup)
        input.matchesAreCurrent = false
        let first = await editor.flush(input); XCTAssertNotNil(first)
        let saved = try await store.firstListDraft(owner: owner)
        let resumed = try FirstListEditor(store: store, owner: owner, base: 0, saved: saved, authorize: { true })
        let next = try resumed.content.appending("5 spice", pantryFood: true, shop: shop)
        let nextVersion = await resumed.flush(next); XCTAssertNotNil(nextVersion)
        let other = try LedgerStore(url: url)
        let record = try await other.firstListDraft(owner: owner)
        let reopened = try FirstListEditor(store: other, owner: owner, base: 0, saved: record, authorize: { true })
        XCTAssertEqual(reopened.content, next)
        let preview = try XCTUnwrap(next.preview)
        XCTAssertEqual(preview.id, reviewed.id)
        XCTAssertEqual(Array(preview.lines.prefix(50)), reviewed.lines)
        XCTAssertEqual(next.choices.filter { $0.key != preview.lines.last?.id }, input.choices)
        XCTAssertEqual(next.explicitSeparate, input.explicitSeparate)
        XCTAssertEqual(next.invalidAmounts, input.invalidAmounts)
        XCTAssertFalse(next.matchesAreCurrent)
        XCTAssertEqual(preview.lines.last?.name, "5 spice")
        XCTAssertNil(preview.lines.last?.quantity)
        XCTAssertEqual(preview.originalText, input.original + "\n5 spice")
        XCTAssertFalse(PantryRestockReview.draftIncludes(food: reviewed.lines[2].name, text: next.original, preview: preview, choices: next.choices))
        XCTAssertFalse(PantryRestockReview.draftIncludes(food: "Item 1", text: next.original, preview: preview, choices: next.choices))
        try await other.close()
        try await store.close()
    }

    func testAppendingShortcutChecksCombinedLimitsAndRetainsDuplicateDecisions() throws {
        var input = FirstListContents()
        let shop = ShoppingLedger(id: input.shopID, title: "List")
        input.original = "2 eggs"
        let before = try shop.stageImport(text: input.original, importID: input.importID)
        input.preview = before
        input.choices = LedgerImportReview.initialChoices(before)
        let next = try input.appending("3 eggs\n2 kg rice", pantryFood: false, shop: shop)
        let preview = try XCTUnwrap(next.preview)
        XCTAssertEqual(preview.lines[0], before.lines[0])
        XCTAssertEqual(preview.lines[1].duplicateLineIDs, [before.lines[0].proposedLineID])
        XCTAssertNil(next.choices[preview.lines[1].id])
        XCTAssertEqual(preview.lines[2].quantity?.unit, .kilogram)
        XCTAssertEqual(next.choices[preview.lines[2].id], .addNew)
        var choices = next.choices
        choices[preview.lines[1].id] = .addToLine(before.lines[0].proposedLineID)
        var committed = shop
        try committed.commitImport(preview, decisions: choices)
        XCTAssertEqual(committed.lines.count, 2)
        XCTAssertEqual(try committed.quantity(forLineID: before.lines[0].proposedLineID)?.amount, try Rational(5))
        let excess = Array(repeating: "x", count: StagedListImport.maximumLines).joined(separator: "\n")
        XCTAssertThrowsError(try input.appending(excess, pantryFood: false, shop: shop)) {
            XCTAssertEqual($0 as? ImportTextLimit, .nonblankLines(maximum: StagedListImport.maximumLines))
        }
        XCTAssertEqual(input.preview, before)
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
