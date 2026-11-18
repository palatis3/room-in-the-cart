import XCTest
import Foundation
import CSQLite
@testable import LocalStore

final class InventoryPersistenceTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("pickup.sqlite") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func lot(_ id: UUID = UUID(), revision: Int64 = 1, bytes: [UInt8] = [1]) -> InventoryWrite {
        .init(record: .init(key: .init(.lot, id), revision: revision, payload: Data(bytes)), expectedRevision: revision - 1)
    }
    private func linked(_ kind: InventoryRecordKind, lotID: UUID, id: UUID = UUID(), source: InventorySourceIdentity? = nil) -> InventoryWrite {
        .init(record: .init(key: .init(kind, id), revision: 1, payload: Data([2]), lotID: lotID, source: source), expectedRevision: 0)
    }
    @discardableResult
    private func activate(_ store: ComparisonStore, writes: [InventoryWrite] = []) async throws -> InventoryOperationReceipt {
        let token = try await store.inventoryCutoverSnapshot().token
        let state = try await store.inventoryState()
        return try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: state.revision, request: Data([1]), mode: .activate, sourceToken: token, writes: writes))
    }

    private let dropPrices = "DROP TABLE inventory_prices; DROP TABLE inventory_staged_prices; DROP TABLE inventory_retired_prices;"
    private let dropStaples = "DROP TABLE inventory_staple_answers; DROP TABLE inventory_staple_preferences;"

    func testStandaloneReviewedPricesPreserveRevisionsAndEraseWithoutStockOrSettlement() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let initial = try await activate(store)
        let id = UUID()
        let first = InventoryPriceRow(id: id, revision: 1, lotID: nil, payload: Data([1]))
        let firstWrite = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: initial.revision, request: first.payload, price: first)
        let saved = try await store.commitInventory(firstWrite)
        let replay = try await store.commitInventory(firstWrite)
        XCTAssertEqual(saved, replay)
        let second = InventoryPriceRow(id: id, revision: 2, lotID: nil, payload: Data([2]))
        let correction = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: saved.revision, request: second.payload, price: second))
        let current = try await store.priceRows()
        let history = try await store.priceRows(id: id, latestOnly: false)
        let lots = try await store.inventoryRecords(kind: .lot)
        XCTAssertEqual(current, [second])
        XCTAssertEqual(history, [first, second])
        XCTAssertTrue(lots.isEmpty)
        let operationID = UUID()
        let token = try await store.inventorySourceToken()
        _ = try await store.beginInventoryErasure(.init(workspaceID: store.workspaceID, operationID: operationID,
            expectedRevision: correction.revision, sourceToken: token, price: .init(id: id, revision: 2),
            chunkCount: 0, entryCount: 0, manifestDigest: InventoryErasureManifest.initialDigest))
        _ = try await store.finishInventoryErasure(id: operationID)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let old = try await reopened.priceRows(id: id, latestOnly: false)
        let erased = try await reopened.priceWasErased(id)
        XCTAssertTrue(old.isEmpty)
        XCTAssertTrue(erased)
        do {
            _ = try await reopened.commitInventory(firstWrite)
            XCTFail("A saved price cannot be replayed after erasure")
        } catch ComparisonStoreError.erased {}
        try await reopened.close()
    }

    func testVersionSevenPricesKeepHistoryAndReplayWhenStaplesAreAdded() async throws {
        let original = try ComparisonStore(url: url, inventoryEnabled: true)
        let initial = try await activate(original)
        let first = InventoryPriceRow(id: UUID(), revision: 1, lotID: nil, payload: Data([1]))
        let saved = try await original.commitInventory(.init(workspaceID: original.workspaceID, operationID: UUID(),
            expectedRevision: initial.revision, request: first.payload, price: first))
        let corrected = InventoryPriceRow(id: first.id, revision: 2, lotID: nil, payload: Data([2]))
        let batch = InventoryBatch(workspaceID: original.workspaceID, operationID: UUID(),
            expectedRevision: saved.revision, request: corrected.payload, price: corrected)
        let receipt = try await original.commitInventory(batch)
        try await original.close()
        try sql(dropStaples + "PRAGMA user_version=7;")

        for _ in 0..<2 {
            let store = try ComparisonStore(url: url, inventoryEnabled: true)
            XCTAssertEqual(store.workspaceID, original.workspaceID)
            let prices = try await store.priceRows(id: first.id, latestOnly: false)
            let replay = try await store.commitInventory(batch)
            let preferences = try await store.staplePreferences(persona: UUID())
            XCTAssertEqual(prices, [first, corrected])
            XCTAssertEqual(replay, receipt)
            XCTAssertFalse(preferences.enabled)
            XCTAssertEqual(try scalar("PRAGMA user_version"), 8)
            try await store.close()
        }
    }

    func testVersionSevenStaplesKeepAnswersAndReceiptReplayWhenPricesAreAdded() async throws {
        let original = try ComparisonStore(url: url, inventoryEnabled: true)
        let initial = try await activate(original)
        let parent = lot(), persona = UUID()
        let source = InventoryAcquisitionRow(id: UUID(), receiptID: UUID(), lineID: UUID(), lotID: parent.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([5]))
        let batch = InventoryBatch(workspaceID: original.workspaceID, operationID: UUID(),
            expectedRevision: initial.revision, request: source.payload, writes: [parent], acquisitions: [source])
        let receipt = try await original.commitInventory(batch)
        try await original.setStaplePrompts(true, persona: persona, expectedRevision: nil)
        let enabled = try await original.staplePreferences(persona: persona)
        try await original.answerStaplePrompt(.dismiss, foodID: UUID(), sourceID: source.id,
            persona: persona, expectedRevision: XCTUnwrap(enabled.revision), inventoryRevision: receipt.revision)
        let expected = try await original.staplePreferences(persona: persona)
        try await original.close()
        try sql(dropPrices + "PRAGMA user_version=7;")

        for _ in 0..<2 {
            let store = try ComparisonStore(url: url, inventoryEnabled: true)
            let preferences = try await store.staplePreferences(persona: persona)
            let acquisitions = try await store.acquisitionRows()
            let prices = try await store.priceRows()
            let replay = try await store.commitInventory(batch)
            XCTAssertEqual(preferences, expected)
            XCTAssertEqual(preferences.answers, [source.id: .dismiss])
            XCTAssertEqual(acquisitions, [source])
            XCTAssertTrue(prices.isEmpty)
            XCTAssertEqual(replay, receipt)
            XCTAssertEqual(try scalar("PRAGMA user_version"), 8)
            try await store.close()
        }
    }

    func testVersionSevenRejectsPartialSchemaAndRollsBackInterruptedAdoption() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        try await store.close()
        try sql("DROP INDEX inventory_staple_source; PRAGMA user_version=7;")
        XCTAssertThrowsError(try ComparisonStore(url: url, inventoryEnabled: true)) {
            XCTAssertEqual($0 as? ComparisonStoreError, .corruptRecord)
        }
        XCTAssertEqual(try scalar("PRAGMA user_version"), 7)
        try sql(dropStaples + "CREATE VIEW inventory_staple_answers AS SELECT 1;")
        XCTAssertThrowsError(try ComparisonStore(url: url, inventoryEnabled: true))
        XCTAssertEqual(try scalar("PRAGMA user_version"), 7)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name='inventory_staple_preferences'"), 0)
        try sql("DROP VIEW inventory_staple_answers")
        let recovered = try ComparisonStore(url: url, inventoryEnabled: true)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 8)
        try await recovered.close()
    }

    func testOptInMigrationPreservesSourcesAndGenericDatabaseRemainsVersionTwo() async throws {
        let legacy = try ComparisonStore(url: url)
        let saved = try await legacy.save(id: UUID(), title: "Original", payload: Data([9, 8, 7]), savedAt: Date(timeIntervalSince1970: 123))
        let workspace = legacy.workspaceID
        try await legacy.close()
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        XCTAssertEqual(store.workspaceID, workspace)
        let snapshot = try await store.inventoryCutoverSnapshot()
        XCTAssertEqual(snapshot.sources, [saved])
        XCTAssertEqual(try scalar("PRAGMA user_version"), 8)
        try await store.close()
        XCTAssertThrowsError(try ComparisonStore(url: url)) { XCTAssertEqual($0 as? ComparisonStoreError, .unsupportedSchema(8)) }
        let other = directory.appendingPathComponent("comparisons.sqlite")
        let generic = try ComparisonStore(url: other)
        _ = try await generic.save(id: UUID(), title: "Pack", payload: Data([1]), savedAt: Date())
        do { _ = try await generic.inventoryState(); XCTFail("generic store has no inventory") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryDisabled) }
        try await generic.close()
        XCTAssertEqual(try scalar("PRAGMA user_version", at: other), 2)
    }

    func testStapleConsentSnoozeAndDismissPersistOnlyForTheCurrentPersonaAndReceipt() async throws {
        let initial = try ComparisonStore(url: url, inventoryEnabled: true)
        try await activate(initial)
        let parent = lot(), persona = UUID(), other = UUID(), food = UUID()
        let source = InventoryAcquisitionRow(id: UUID(), receiptID: UUID(), lineID: UUID(), lotID: parent.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([9]))
        _ = try await initial.commitInventory(.init(workspaceID: initial.workspaceID, operationID: UUID(), expectedRevision: 1,
            request: Data([2]), writes: [parent], acquisitions: [source]))
        try await initial.close()
        try sql(dropPrices + dropStaples + "PRAGMA user_version=6;")
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 8)
        let prices = try await store.priceRows()
        XCTAssertTrue(prices.isEmpty)
        let off = try await store.staplePreferences(persona: persona)
        XCTAssertFalse(off.enabled)
        try await store.setStaplePrompts(true, persona: persona, expectedRevision: nil)
        let enabled = try await store.staplePreferences(persona: persona)
        let revision = try XCTUnwrap(enabled.revision)
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.answerStaplePrompt(.snooze(until: until), foodID: food, sourceID: source.id, persona: persona,
                                          expectedRevision: revision, inventoryRevision: 2)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let saved = try await reopened.staplePreferences(persona: persona)
        let unrelated = try await reopened.staplePreferences(persona: other)
        XCTAssertEqual(saved.answers, [source.id: .snooze(until: until)])
        XCTAssertFalse(unrelated.enabled)
        do {
            try await reopened.answerStaplePrompt(.dismiss, foodID: food, sourceID: source.id, persona: persona,
                                                  expectedRevision: revision, inventoryRevision: 2)
            XCTFail("An outdated reminder must not overwrite a newer choice")
        } catch ComparisonStoreError.staleInventory {}
        try await reopened.answerStaplePrompt(.dismiss, foodID: food, sourceID: source.id, persona: persona,
                                              expectedRevision: XCTUnwrap(saved.revision), inventoryRevision: 2)
        let dismissed = try await reopened.staplePreferences(persona: persona)
        XCTAssertEqual(dismissed.answers, [source.id: .dismiss])
        try await reopened.setStaplePrompts(false, persona: persona, expectedRevision: dismissed.revision)
        let disabled = try await reopened.staplePreferences(persona: persona)
        XCTAssertEqual(disabled, off)
        let finalState = try await reopened.inventoryState()
        XCTAssertEqual(finalState.revision, 2, "Reminder answers must never change stock")
        try await reopened.close()
    }

    func testVersionFiveReceiptEvidenceMigratesToAnEmptySpellingStore() async throws {
        let original = try ComparisonStore(url: url, inventoryEnabled: true)
        try await activate(original)
        let parent = lot()
        let row = InventoryAcquisitionRow(id: UUID(), receiptID: UUID(), lineID: UUID(), lotID: parent.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([2]))
        _ = try await original.commitInventory(.init(workspaceID: original.workspaceID, operationID: UUID(), expectedRevision: 1,
            request: Data([3]), writes: [parent], acquisitions: [row]))
        try await original.close()
        try sql(dropPrices + dropStaples + "DROP TABLE inventory_receipt_aliases; PRAGMA user_version=5;")
        let migrated = try ComparisonStore(url: url, inventoryEnabled: true)
        let rows = try await migrated.acquisitionRows(), aliases = try await migrated.receiptAliasCount()
        XCTAssertEqual(rows, [row])
        XCTAssertEqual(aliases, 0)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 8)
        try await migrated.close()
    }

    func testReceiptSpellingsSurviveReopenAndForgetOnlyTheReviewedPersonaRows() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        try await activate(store)
        let parent = lot(), persona = UUID(), other = UUID(), food = UUID()
        let row = InventoryAcquisitionRow(id: UUID(), receiptID: UUID(), lineID: UUID(), lotID: parent.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([7]))
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: 1, request: Data([1]), writes: [parent], acquisitions: [row]))
        func alias(_ persona: UUID, _ language: String) -> InventoryReceiptAlias {
            .init(personaID: persona, merchant: "Market", language: language, wording: "BN", product: "Beans", foodID: food,
                sourceID: row.id, lotID: parent.record.key.id)
        }
        let english = alias(persona, "en"), spanish = alias(persona, "es"), independent = alias(other, "en")
        for (index, item) in [english, spanish, independent].enumerated() {
            _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: Int64(index + 2),
                request: Data([UInt8(index)]), aliasEdit: .remember(item)))
        }
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let filtered = try await reopened.receiptAliases(personaID: persona, merchant: " market ", language: "en")
        XCTAssertEqual(filtered, [english])
        do {
            _ = try await reopened.commitInventory(.init(workspaceID: reopened.workspaceID, operationID: UUID(), expectedRevision: 5,
                request: Data([2]), aliasEdit: .forget(personaID: persona, ids: [english.id, independent.id])))
            XCTFail("Mixed scope must roll back all removals")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        let count = try await reopened.receiptAliasCount(lotIDs: [row.lotID])
        XCTAssertEqual(count, 3)
        let removal = InventoryBatch(workspaceID: reopened.workspaceID, operationID: UUID(), expectedRevision: 5,
            request: Data([5]), aliasEdit: .forget(personaID: persona, ids: [english.id, spanish.id]))
        _ = try await reopened.commitInventory(removal)
        _ = try await reopened.commitInventory(removal)
        let kept = try await reopened.receiptAliases(personaID: other), cleared = try await reopened.receiptAliases(personaID: persona)
        XCTAssertEqual(kept, [independent])
        XCTAssertTrue(cleared.isEmpty)
        let evidence = try await reopened.acquisitionRows()
        XCTAssertEqual(evidence, [row])
        _ = try await reopened.commitInventory(.init(workspaceID: reopened.workspaceID, operationID: UUID(),
            expectedRevision: 6, request: Data([8]), erasures: [.init(key: parent.record.key, expectedRevision: 1)]))
        let remaining = try await reopened.receiptAliasCount()
        XCTAssertEqual(remaining, 0)
        try await reopened.close()
    }

    func testRescanBindingsArePrivateAtomicAndErasedWithTheirPhysicalLine() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        try await activate(store)
        let parent = lot(), receipt = UUID(), owner = UUID(), day = UUID(), wording = UUID(), doc = UUID()
        let digest = String(repeating: "a", count: 64)
        let row = InventoryAcquisitionRow(id: UUID(), receiptID: receipt, lineID: UUID(), lotID: parent.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([5]))
        func binding(_ actor: UUID, document: UUID, ordinal: Int) -> InventoryReceiptBinding {
            .init(owner: actor, merchantDay: day, wording: wording, document: document, ordinal: ordinal,
                  sourceID: row.id, receiptID: receipt, lotID: row.lotID, fileDigest: digest)
        }
        let original = binding(owner, document: doc, ordinal: 4)
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1,
            request: Data([1]), writes: [parent], acquisitions: [row], receiptBindings: [original]))
        let crop = UUID(), linked = binding(owner, document: crop, ordinal: 0)
        let pending = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2,
            request: Data([2]), receiptBindings: [linked])
        let committed = try await store.commitInventory(pending)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let replay = try await reopened.commitInventory(pending)
        XCTAssertEqual(replay, committed)
        let saved = try await reopened.rescanBindings(owner: owner, document: crop)
        let mine = try await reopened.rescanCandidates(owner: owner, merchantDay: day, wording: [wording])
        let other = try await reopened.rescanCandidates(owner: UUID(), merchantDay: day, wording: [wording])
        let files = try await reopened.rescanDocumentDigests(for: [row.lotID])
        XCTAssertEqual(saved, [linked]); XCTAssertEqual(mine, [receipt]); XCTAssertTrue(other.isEmpty); XCTAssertEqual(files, [digest])
        let third = UUID()
        do {
            _ = try await reopened.commitInventory(.init(workspaceID: reopened.workspaceID, operationID: UUID(), expectedRevision: 3,
                request: Data([3]), receiptBindings: [binding(owner, document: third, ordinal: 0), binding(UUID(), document: third, ordinal: 1)]))
            XCTFail("A conflicting actor cannot claim an existing receipt")
        } catch ComparisonStoreError.invalidInput {}
        let rolledBack = try await reopened.rescanBindings(owner: owner, document: third)
        XCTAssertTrue(rolledBack.isEmpty)
        _ = try await reopened.commitInventory(.init(workspaceID: reopened.workspaceID, operationID: UUID(), expectedRevision: 3,
            request: Data([4]), erasures: [.init(key: parent.record.key, expectedRevision: 1)]))
        let after = try await reopened.rescanCandidates(owner: owner, merchantDay: day, wording: [wording])
        let erased = try await reopened.rescanDocumentDigests(for: [row.lotID])
        XCTAssertTrue(after.isEmpty); XCTAssertTrue(erased.isEmpty)
        do { _ = try await reopened.commitInventory(pending); XCTFail("Retired links cannot replay") }
        catch ComparisonStoreError.erased {}
        do { try await reopened.checkRescanLines(owner: owner, document: crop, ordinals: [0]); XCTFail("A cropped line cannot reappear after erasure") }
        catch ComparisonStoreError.invalidInput {}
        try await reopened.checkRescanLines(owner: owner, document: crop, ordinals: [1])
        try await reopened.close()
    }

    func testReceiptEvidenceIdentitiesAreAtomicAndRemainRetiredAcrossReopen() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        _ = try await activate(store, writes: [])
        let parent = lot(), receipt = UUID(), line = UUID(), image = UUID(), transaction = UUID()
        let row = InventoryAcquisitionRow(id: UUID(), receiptID: receipt, lineID: line, lotID: parent.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([1, 2]), imageIdentity: image, transactionIdentity: transaction)
        let batch = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1,
            request: Data([11]), writes: [parent], acquisitions: [row])
        let committed = try await store.commitInventory(batch)
        let replay = try await store.commitInventory(batch)
        XCTAssertEqual(replay, committed)
        let other = lot(), alias = UUID()
        let conflict = InventoryAcquisitionRow(id: UUID(), receiptID: UUID(), lineID: UUID(), lotID: other.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([5]), imageIdentity: alias, transactionIdentity: transaction)
        do {
            _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2,
                request: Data([7]), writes: [other], acquisitions: [conflict]))
            XCTFail("Identity reuse cannot create stock")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
        let absent = try await store.acquisitionReceiptID(for: alias)
        XCTAssertNil(absent)
        let lotRows = try await store.inventoryRecords(kind: .lot, limit: 5)
        XCTAssertEqual(lotRows.count, 1)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let same = try await reopened.acquisitionRows(receiptID: receipt, lineIDs: [line], firstRevisionOnly: true)
        XCTAssertEqual(same, [row])
        let id = try await reopened.acquisitionReceiptID(for: image)
        XCTAssertEqual(id, receipt)
        _ = try await reopened.commitInventory(.init(workspaceID: reopened.workspaceID, operationID: UUID(),
            expectedRevision: 2, request: Data([4]), erasures: [.init(key: parent.record.key, expectedRevision: 1)]))
        let erased = try await reopened.acquisitionRows()
        XCTAssertTrue(erased.isEmpty)
        do { _ = try await reopened.commitInventory(batch); XCTFail("Retired evidence cannot replay") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        let replacement = lot()
        let oldLine = InventoryAcquisitionRow(id: UUID(), receiptID: receipt, lineID: line, lotID: replacement.record.key.id,
            revision: 1, supersedesID: nil, payload: Data([3]))
        do {
            _ = try await reopened.commitInventory(.init(workspaceID: reopened.workspaceID, operationID: UUID(), expectedRevision: 3,
                request: Data([8]), writes: [replacement], acquisitions: [oldLine]))
            XCTFail("A retired line cannot be rebound to another lot")
        } catch {}
        let replacementLots = try await reopened.inventoryRecords(kind: .lot, limit: 10)
        XCTAssertTrue(replacementLots.isEmpty)
        try await reopened.close()
    }

    func testCutoverRejectsInsertedAndErasedSourcesAcrossInstancesWithoutPartialImport() async throws {
        let stale = try ComparisonStore(url: url)
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let token = try await store.inventoryCutoverSnapshot().token
        let inserted = try await stale.save(id: UUID(), title: "Later source", payload: Data([3]), savedAt: Date())
        let write = lot()
        let batch = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0, request: Data([1]),
            mode: .activate, sourceToken: token, writes: [write])
        do { _ = try await store.commitInventory(batch); XCTFail("complete source set changed") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        _ = try await stale.erase(id: inserted.id, expectedRevision: 1, operationID: UUID(), at: Date())
        do { _ = try await store.commitInventory(batch); XCTFail("insert+erase must not look unchanged") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        let state = try await store.inventoryState()
        XCTAssertEqual(state.revision, 0); XCTAssertFalse(state.active)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        let current = try await store.inventoryCutoverSnapshot()
        XCTAssertEqual(current.sources.count, 0); XCTAssertEqual(current.tombstones.count, 1)
        XCTAssertNotEqual(current.token, token)
        _ = try await activate(store, writes: [write])
        do { _ = try await stale.save(id: UUID(), title: "Bypass", payload: Data([4]), savedAt: Date()); XCTFail("stale actor bypass") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryRequired) }
        do { _ = try await stale.erase(id: inserted.id, expectedRevision: 1, operationID: UUID(), at: Date()); XCTFail("stale erase bypass") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryRequired) }
        try await stale.close(); try await store.close()
    }

    func testRestartReplayAndChangedBodyConflictAfterNewerRevision() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let first = lot()
        _ = try await activate(store, writes: [first])
        let update = lot(first.record.key.id, revision: 2, bytes: [4])
        let batch = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]), writes: [update])
        let receipt = try await store.commitInventory(batch, at: Date(timeIntervalSince1970: 50))
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2, request: Data([1]),
            writes: [lot(first.record.key.id, revision: 3, bytes: [5])]))
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let retry = try await reopened.commitInventory(batch, at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(retry, receipt)
        let current = try await reopened.inventoryRecord(first.record.key)
        XCTAssertEqual(current?.revision, 3); XCTAssertEqual(current?.payload, Data([5]))
        let changed = InventoryBatch(workspaceID: batch.workspaceID, operationID: batch.operationID, expectedRevision: 1, request: Data([1]),
            writes: [lot(first.record.key.id, revision: 2, bytes: [7])])
        do { _ = try await reopened.commitInventory(changed); XCTFail("changed replay") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_revisions"), 3)
        try await reopened.close()
    }

    func testCompoundComparisonFailureRollsBackInventoryAndReceipt() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let saved = try await store.save(id: UUID(), title: "Before", payload: Data([1]), savedAt: Date())
        let first = lot(); _ = try await activate(store, writes: [first])
        let batch = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]),
            writes: [lot(first.record.key.id, revision: 2, bytes: [8])], comparisons: [
                .init(action: .save, id: saved.id, expectedRevision: 1, title: "After", payload: Data([2]))])
        try sql("CREATE TRIGGER fail_inventory_comparison BEFORE UPDATE ON comparisons BEGIN SELECT RAISE(ABORT, 'test boundary'); END")
        do { _ = try await store.commitInventory(batch); XCTFail("expected rollback") } catch ComparisonStoreError.database { }
        let unchanged = try await store.inventoryRecord(first.record.key)
        let comparison = try await store.load(id: saved.id)
        XCTAssertEqual(unchanged, first.record); XCTAssertEqual(comparison, saved)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_operations"), 1)
        try sql("DROP TRIGGER fail_inventory_comparison")
        let receipt = try await store.commitInventory(batch)
        XCTAssertEqual(receipt.comparisonHeads[saved.id], 2)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let replay = try await reopened.commitInventory(batch)
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 2)
        try await reopened.close()
    }

    func testMissingParentAndDuplicateSourceRollbackWholeBatch() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        _ = try await activate(store)
        let orphan = linked(.observation, lotID: UUID())
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]), writes: [orphan])); XCTFail("orphan") }
        catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        let a = lot(), b = lot(), source = InventorySourceIdentity(originID: UUID(), sourceID: "receipt:event/line/segment")
        let duplicate = [a, b, linked(.sourceLink, lotID: a.record.key.id, source: source), linked(.sourceLink, lotID: b.record.key.id, source: source)]
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]), writes: duplicate)); XCTFail("duplicate source") }
        catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_operations"), 1)
        try await store.close()
    }

    func testAppendOnlyFactsAndLinkedLotErasureRequiresWholeGraph() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let parent = lot(), observation = linked(.observation, lotID: parent.record.key.id)
        let claim = linked(.reservation, lotID: parent.record.key.id)
        _ = try await activate(store, writes: [observation, claim, parent])
        let replacement = InventoryWrite(record: .init(key: observation.record.key, revision: 2, payload: Data([9]), lotID: parent.record.key.id), expectedRevision: 1)
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]), writes: [replacement])); XCTFail("immutable observation") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .invalidInput) }
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]),
            erasures: [.init(key: parent.record.key, expectedRevision: 1)])); XCTFail("orphan claims") }
        catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_tombstones"), 0)
        let erasure = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]),
            erasures: [parent, observation, claim].map { .init(key: $0.record.key, expectedRevision: 1) })
        let receipt = try await store.commitInventory(erasure)
        let replay = try await store.commitInventory(erasure)
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_revisions"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_tombstones"), 3)
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2, request: Data([1]), writes: [parent])); XCTFail("resurrection") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        try await store.close()
    }

    func testPreparedIntentSurvivesReopenButCannotAdvertiseActiveInventory() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let intent = InventoryWrite(record: .init(key: .init(.intent, UUID()), revision: 1, payload: Data([1, 2])), expectedRevision: 0)
        let batch = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0, request: Data([1]), mode: .prepare, writes: [intent])
        _ = try await store.commitInventory(batch)
        let state = try await store.inventoryState(); XCTAssertFalse(state.active)
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]), writes: [lot()])); XCTFail("inactive") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryInactive) }
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let loaded = try await reopened.inventoryRecord(intent.record.key); XCTAssertEqual(loaded, intent.record)
        let active = try await activate(reopened)
        XCTAssertEqual(active.revision, 2)
        try await reopened.close()
    }

    func testStaleInventoryHeadAndOversizedInputDoNotMutate() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let initial = lot(); _ = try await activate(store, writes: [initial])
        let bad = InventoryWrite(record: .init(key: .init(.lot, UUID()), revision: 1,
            payload: Data(count: InventoryPersistenceLimits.recordBytes + 1)), expectedRevision: 0)
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]), writes: [bad])); XCTFail("oversized") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .invalidInput) }
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]),
            writes: [lot(initial.record.key.id, revision: 3)])); XCTFail("wrong record head") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_operations"), 1)
        try await store.close()
    }

    func testCorruptInventoryAndFutureSchemaRefusedWithoutChangingBytes() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        _ = try await activate(store, writes: [lot()]); try await store.close()
        try sql("DROP TRIGGER inventory_revision_immutable; UPDATE inventory_revisions SET payload = x'03'")
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url, inventoryEnabled: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try sql("PRAGMA user_version = 77")
        let future = try Data(contentsOf: url)
        XCTAssertThrowsError(try ComparisonStore(url: url, inventoryEnabled: true)) { XCTAssertEqual($0 as? ComparisonStoreError, .unsupportedSchema(77)) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testOriginalRequestLookupSurvivesLaterEditsAndRejectsChangedOrRetiredRequests() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let original = lot(); _ = try await activate(store, writes: [original])
        let request = Data("count source 3 from reviewed revision 1".utf8)
        let operation = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: request,
            writes: [lot(original.record.key.id, revision: 2, bytes: [3])])
        let receipt = try await store.commitInventory(operation)
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2, request: Data([4]),
            writes: [lot(original.record.key.id, revision: 3, bytes: [8])]))
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let found = try await reopened.inventoryCommittedOperation(id: operation.operationID, request: request)
        XCTAssertEqual(found, receipt)
        do { _ = try await reopened.inventoryCommittedOperation(id: operation.operationID, request: Data([9])); XCTFail("changed original request") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
        let erasure = InventoryBatch(workspaceID: reopened.workspaceID, operationID: UUID(), expectedRevision: 3, request: Data([5]),
            erasures: [.init(key: original.record.key, expectedRevision: 3)])
        let erased = try await reopened.commitInventory(erasure)
        let own = try await reopened.inventoryCommittedOperation(id: erasure.operationID, request: erasure.request)
        XCTAssertEqual(own, erased)
        do { _ = try await reopened.inventoryCommittedOperation(id: operation.operationID, request: request); XCTFail("retired original result") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        do { _ = try await reopened.commitInventory(operation); XCTFail("retired original batch") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        try await reopened.close()
    }

    func testUnpinnedClaimCanPinMoveAndReleaseWithReviewedHeads() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let a = lot(), b = lot(), key = InventoryRecordKey(.reservation, UUID())
        let unpinned = InventoryWrite(record: .init(key: key, revision: 1, payload: Data([1])), expectedRevision: 0)
        _ = try await activate(store, writes: [a, b, unpinned])
        for (offset, parent) in [a.record.key.id, b.record.key.id, nil].enumerated() {
            let revision = Int64(offset + 2)
            let write = InventoryWrite(record: .init(key: key, revision: revision, payload: Data([UInt8(revision)]), lotID: parent), expectedRevision: revision - 1)
            _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: revision - 1,
                request: Data([UInt8(revision)]), writes: [write]))
            let loaded = try await store.inventoryRecord(key)
            XCTAssertEqual(loaded?.lotID, parent)
        }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_revisions WHERE kind = 'reservation' AND lot_id IS NOT NULL"), 2)
        let invalid = InventoryWrite(record: .init(key: key, revision: 5, payload: Data([5]), lotID: UUID()), expectedRevision: 4)
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 4,
            request: Data([5]), writes: [invalid])); XCTFail("unknown pin target") }
        catch ComparisonStoreError.database { }
        let last = try await store.inventoryRecord(key)
        XCTAssertEqual(last?.revision, 4); XCTAssertNil(last?.lotID)
        try await store.close()
    }

    func testErasedSourceIdentityCannotBeRelinkedUnderNewRecordID() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let parent = lot(), source = InventorySourceIdentity(originID: UUID(), sourceID: "arrival/branch/segment")
        let link = linked(.sourceLink, lotID: parent.record.key.id, source: source)
        _ = try await activate(store, writes: [parent, link])
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([2]),
            erasures: [.init(key: link.record.key, expectedRevision: 1)]))
        let newLink = linked(.sourceLink, lotID: parent.record.key.id, source: source)
        do { _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2,
            request: Data([3]), writes: [newLink])); XCTFail("retired source address") }
        catch ComparisonStoreError.database { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_revisions WHERE kind = 'sourceLink'"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_retired_sources"), 1)
        try await store.close()
    }

    func testCompoundSourceErasureAllowsOwnReceiptButRejectsPriorProjection() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let id = UUID(); _ = try await activate(store)
        let create = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([1]),
            comparisons: [.init(action: .save, id: id, expectedRevision: 0, title: "Food source", payload: Data([7]))])
        _ = try await store.commitInventory(create)
        let erase = InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2, request: Data([2]),
            comparisons: [.init(action: .erase, id: id, expectedRevision: 1)])
        let result = try await store.commitInventory(erase)
        let replay = try await store.commitInventory(erase)
        let lookup = try await store.inventoryCommittedOperation(id: erase.operationID, request: erase.request)
        XCTAssertEqual(replay, result); XCTAssertEqual(lookup, result)
        do { _ = try await store.inventoryCommittedOperation(id: create.operationID, request: create.request); XCTFail("retired comparison receipt") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 0)
        try await store.close()
    }

    func testRetirementEvidencePagesKeepKindsAndOriginalIdentityAcrossRestart() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        let lots = [lot(), lot(), lot()].sorted { $0.record.key.id.uuidString < $1.record.key.id.uuidString }
        let observation = linked(.observation, lotID: lots[0].record.key.id, id: lots[0].record.key.id)
        _ = try await activate(store, writes: lots + [observation])
        let operation = UUID()
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: operation,
            expectedRevision: 1, request: Data([7]), erasures: (lots + [observation]).map {
                .init(key: $0.record.key, expectedRevision: 1)
            }))
        let first = try await store.inventoryTombstones(kind: .lot, expectedInventoryRevision: 2, limit: 2)
        let second = try await store.inventoryTombstones(kind: .lot, expectedInventoryRevision: 2, after: first.last?.key.id, limit: 2)
        XCTAssertEqual(first.count, 2); XCTAssertEqual(second.count, 1)
        XCTAssertEqual((first + second).map(\.key), lots.map { $0.record.key })
        XCTAssertTrue((first + second).allSatisfy { $0.operationID == operation && $0.erasedRevision == 1 && $0.workspaceID == store.workspaceID })
        let observations = try await store.inventoryTombstones(kind: .observation, expectedInventoryRevision: 2)
        XCTAssertEqual(observations.map(\.key), [observation.record.key])
        let empty = try await store.inventoryTombstones(kind: .lot, expectedInventoryRevision: 2, after: second.last?.key.id)
        XCTAssertTrue(empty.isEmpty)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        let reread = try await reopened.inventoryTombstones(kind: .lot, expectedInventoryRevision: 2)
        XCTAssertEqual(reread, first + second)
        try await reopened.close()
    }

    func testRetiredSourcePagesUseFullIdentityAndRejectChangedScanRevision() async throws {
        let store = try ComparisonStore(url: url, inventoryEnabled: true), parent = lot()
        let origins = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let sources = [InventorySourceIdentity(originID: origins[0], sourceID: "arrival/a"),
                       InventorySourceIdentity(originID: origins[0], sourceID: "arrival/b"),
                       InventorySourceIdentity(originID: origins[1], sourceID: "arrival/a")]
        let links = sources.map { linked(.sourceLink, lotID: parent.record.key.id, source: $0) }
        _ = try await activate(store, writes: [parent] + links)
        let operation = UUID()
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: operation,
            expectedRevision: 1, request: Data([2]), erasures: links.map { .init(key: $0.record.key, expectedRevision: 1) }))
        let first = try await store.inventoryRetiredSources(expectedInventoryRevision: 2, limit: 2)
        let second = try await store.inventoryRetiredSources(expectedInventoryRevision: 2, after: first.last?.source, limit: 2)
        XCTAssertEqual(first.count, 2); XCTAssertEqual(second.count, 1)
        XCTAssertEqual((first + second).map(\.source), sources)
        XCTAssertTrue((first + second).allSatisfy { $0.operationID == operation && $0.workspaceID == store.workspaceID })
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2,
            request: Data([3]), writes: [lot(parent.record.key.id, revision: 2)]))
        do { _ = try await store.inventoryRetiredSources(expectedInventoryRevision: 2, after: first.last?.source); XCTFail("stale source scan") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        do { _ = try await store.inventoryTombstones(kind: .sourceLink, expectedInventoryRevision: 2); XCTFail("stale tombstone scan") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        try await store.close()
    }

    func testRetirementEvidenceRejectsDisabledInvalidAndCorruptReadsWithoutRepair() async throws {
        let legacy = try ComparisonStore(url: url)
        do { _ = try await legacy.inventoryTombstones(kind: .lot, expectedInventoryRevision: 0); XCTFail("disabled") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryDisabled) }
        do { _ = try await legacy.inventoryRetiredSources(expectedInventoryRevision: 0); XCTFail("disabled") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .inventoryDisabled) }
        try await legacy.close()
        let store = try ComparisonStore(url: url, inventoryEnabled: true), parent = lot()
        _ = try await activate(store, writes: [parent])
        for limit in [0, InventoryPersistenceLimits.pageItems + 1] {
            do { _ = try await store.inventoryTombstones(kind: .lot, expectedInventoryRevision: 1, limit: limit); XCTFail("bad bound") }
            catch { XCTAssertEqual(error as? ComparisonStoreError, .invalidInput) }
            do { _ = try await store.inventoryRetiredSources(expectedInventoryRevision: 1, limit: limit); XCTFail("bad bound") }
            catch { XCTAssertEqual(error as? ComparisonStoreError, .invalidInput) }
        }
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1,
            request: Data([2]), erasures: [.init(key: parent.record.key, expectedRevision: 1)]))
        try sql("DROP TRIGGER inventory_tombstone_update")
        try sql("UPDATE inventory_tombstones SET operation_id = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'")
        do { _ = try await store.inventoryTombstones(kind: .lot, expectedInventoryRevision: 2); XCTFail("corrupt evidence is not absence") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .corruptRecord) }
        XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_tombstones"), 1)
        try await store.close()
    }

    private enum TestError: Error { case sqlite }
    private func sql(_ query: String) throws {
        var db: OpaquePointer?; guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
    }
    private func scalar(_ query: String, at target: URL? = nil) throws -> Int64 {
        var db: OpaquePointer?; guard sqlite3_open((target ?? url).path, &db) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(db) }
        var row: OpaquePointer?; guard sqlite3_prepare_v2(db, query, -1, &row, nil) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw TestError.sqlite }
        return sqlite3_column_int64(row, 0)
    }
}
