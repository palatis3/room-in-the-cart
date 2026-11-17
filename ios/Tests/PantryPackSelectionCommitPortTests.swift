import XCTest
import CoreDomain
import LocalStore
import SQLite3
@testable import RoomInTheCart

@MainActor final class PantryPackSelectionCommitPortTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private final class Controls { var access = true; var action = true; var failCleanup = false }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let inventory: ComparisonStore
        let ledger: LedgerStore
        let pending: PantryPackSelectionPendingStore
        let repository: PantryRepository
        let gate: PantryMutationGate
        let controls: Controls
        let request: PantryPackSelectionCommitPort.Request
        let port: PantryPackSelectionCommitPort
    }
    private func fixture(actionRequired: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let ledgerModel = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(ledgerModel, producer, inventory)
        await ledgerModel.open(); await producer.load()
        var shop = ShoppingLedger(title: "Pack port", basis: .init(branch: "Main", mode: .pickup, slot: now,
            timeZoneIdentifier: "America/New_York"))
        let food = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let saved = await ledgerModel.change(key: "fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }; XCTAssertTrue(saved)
        let checkout = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledgerModel.revision, previous: nil)
        let started = try await LedgerCheckoutAdapter.apply(checkout, ledger: ledgerModel, pickup: producer); XCTAssertTrue(started)
        let stocked = await producer.saveStockLot(.init(id: food, foodID: food, name: "Freezer wraps", usable: q(8),
            confirmedAt: now, source: .freezer), in: shop.id); XCTAssertTrue(stocked)
        for head in try await producer.archiveSnapshot().records {
            _ = try await inventory.save(id: head.id, title: head.title, payload: head.payload, savedAt: head.savedAt)
        }
        let mapping = try PantryLegacyMigration.map(originID: inventory.workspaceID,
            heads: try await inventory.list().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await inventory.inventorySourceToken(),
            inventoryRevision: await inventory.inventoryState().revision, at: now)
        _ = try await inventory.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await inventory.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await inventory.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: inventory, authorize: { true })
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"))
        cleanup.track(repository, ledger)
        let snapshot = try await repository.load(at: now)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: food)
        let proof = try PantryPackStockReview.evidence(shop: shop, lineID: food, requirement: requirement, bindings: [],
            context: .init(snapshot: snapshot, mapping: mapping, asOf: now))
        let comparison = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
            confirmedAtHome: try proof.confirmedQuantity(for: requirement), protectedAmount: requirement.protectedQuantity,
            offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)))
        let selection = try LedgerPackSelection(workspaceID: ledger.workspaceID, shop: shop, lineID: food,
            request: comparison, selectedOfferID: "a", at: now, source: "Shelf", canonicalStockEvidence: proof)
        let request = PantryPackSelectionCommitPort.Request(inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledger.workspaceID,
            selection: selection, reviewedLedgerRevision: ledgerModel.revision, requiresActionAuthorization: actionRequired)
        let controls = Controls(), gate = PantryMutationGate()
        let pending = try PantryPackSelectionPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledger.workspaceID, removeFile: { url in
                if controls.failCleanup { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.removeItem(at: url)
            })
        let port = PantryPackSelectionCommitPort(store: inventory, ledger: ledger, pendingStore: pending, gate: gate,
            authorize: { _, _ in controls.access }, authorizeAction: { _ in controls.action }, clock: { instant })
        return .init(directory: directory, cleanup: cleanup, inventory: inventory, ledger: ledger, pending: pending,
            repository: repository, gate: gate, controls: controls, request: request, port: port)
    }
    private func prepared(_ f: Fixture) async throws -> PantryPackSelectionPendingStore.Entry {
        guard case .pending(let entry) = try await f.port.prepare(f.request) else { throw CocoaError(.fileReadCorruptFile) }
        return entry
    }
    private func committed(_ recovery: PantryPackSelectionCommitPort.PendingRecovery) throws -> PantryPackSelectionCommitPort.Result {
        guard case .committed(_, let result) = recovery else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    private func recount(_ f: Fixture, amount: Int64) async throws {
        let before = try await f.repository.load(at: now), lot = try XCTUnwrap(before.lots.first)
        _ = try await f.repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.exact(q(amount)), observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
    }
    private func reopen(_ f: Fixture) throws -> (PantryPackSelectionCommitPort, PantryPackSelectionPendingStore) {
        let inventory = try ComparisonStore(url: f.directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"))
        f.cleanup.track(inventory, ledger)
        let pending = try PantryPackSelectionPendingStore(directory: f.pending.fileURL.deletingLastPathComponent(),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        let instant = now
        return (.init(store: inventory, ledger: ledger, pendingStore: pending, gate: f.gate,
            authorize: { _, _ in f.controls.access }, authorizeAction: { _ in f.controls.action }, clock: { instant }), pending)
    }
    private func encode(_ workspace: LedgerWorkspace) throws -> Data {
        struct Document: Encodable { let formatVersion: Int; let workspace: LedgerWorkspace }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(formatVersion: 1, workspace: workspace))
    }

    func testFreshSaveUsesOriginalOperationAndStaleCountRejectsBeforeWriting() async throws {
        let f = try await fixture(), entry = try await prepared(f)
        try await recount(f, amount: 4)
        do { _ = try await f.port.recover(entry, commitIfUnapplied: true); XCTFail("Stale canonical evidence") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .staleReview) }
        let absent = try await f.ledger.savedOperation(id: entry.operationID); XCTAssertNil(absent)
        XCTAssertEqual(try f.pending.read(), entry)
        guard case .cleared = try await f.port.recover(entry, discardIfUnapplied: true) else { return XCTFail("Explicit discard") }
        XCTAssertNil(try f.pending.read())
        let second = try await fixture(), fresh = try await prepared(second)
        let result = try committed(await second.port.recover(fresh, commitIfUnapplied: true))
        XCTAssertFalse(result.replayed)
        XCTAssertEqual(result.receipt.operationID, second.request.selection.id)
        XCTAssertEqual(result.receipt.savedAt, now)
        XCTAssertEqual(result.workspace.packSelections, [second.request.selection])
        XCTAssertNil(try second.port.finishAdoption(fresh, result: result))
        XCTAssertNil(try second.pending.read())
    }

    func testCleanupFailureAndReopenReplayAdoptNewerLedgerAndPantryWithoutDuplicate() async throws {
        let f = try await fixture(), entry = try await prepared(f)
        let first = try committed(await f.port.recover(entry, commitIfUnapplied: true))
        f.controls.failCleanup = true
        XCTAssertThrowsError(try f.port.finishAdoption(entry, result: first))
        XCTAssertNotNil(try f.pending.read()?.acknowledgment)
        var later = first.workspace
        try later.shops[0].updateLine(lineID: f.request.selection.lineID, name: "Wraps", notes: "New note", aisle: "")
        let saved = try await f.ledger.save(payload: encode(later), expectedRevision: first.current.revision,
            operationID: UUID(), savedAt: now)
        try await recount(f, amount: 1)
        let (reopened, journal) = try reopen(f)
        let pending = try XCTUnwrap(journal.read())
        let recovered = try committed(await reopened.recover(pending, commitIfUnapplied: true))
        XCTAssertTrue(recovered.replayed); XCTAssertEqual(recovered.current, saved)
        XCTAssertEqual(recovered.workspace, later)
        XCTAssertEqual(recovered.receipt.revision, first.receipt.revision)
        XCTAssertNil(try reopened.finishAdoption(pending, result: recovered))
        guard case .completed(let completed) = try await reopened.prepare(f.request) else { return XCTFail("No new journal after exact completion") }
        XCTAssertEqual(completed.current, saved); XCTAssertNil(try journal.read())
    }

    func testUncommittedRestartDiscardPreventsCachedRetryFromRecreatingJournal() async throws {
        let f = try await fixture(), entry = try await prepared(f)
        let (reopened, journal) = try reopen(f)
        guard case .waiting(let restored, _) = try await reopened.recover() else { return XCTFail("Launch must not apply") }
        XCTAssertEqual(restored, entry)
        guard case .cleared = try await reopened.recover(restored, discardIfUnapplied: true) else { return XCTFail("Discard") }
        XCTAssertThrowsError(try f.pending.ensureProtected(expected: entry))
        guard case .cleared = try await f.port.recover(entry, commitIfUnapplied: true) else { return XCTFail("Cached retry must not recreate") }
        XCTAssertNil(try journal.read())
        let receipt = try await f.ledger.savedOperation(id: entry.operationID); XCTAssertNil(receipt)
    }

    func testDifferentBodyCompletedRetryCannotPoisonNewJournal() async throws {
        let f = try await fixture(), entry = try await prepared(f)
        let result = try committed(await f.port.recover(entry, commitIfUnapplied: true))
        _ = try f.port.finishAdoption(entry, result: result)
        let original = f.request.selection, shop = try XCTUnwrap(result.workspace.shops.first)
        let different = try LedgerPackSelection(id: original.id, workspaceID: original.sourceWorkspaceID, shop: shop,
            lineID: original.lineID, request: original.request, selectedOfferID: "b", at: original.reviewedAt,
            source: original.source, canonicalStockEvidence: original.canonicalStockEvidence)
        let request = PantryPackSelectionCommitPort.Request(inventoryWorkspaceID: f.inventory.workspaceID,
            ledgerWorkspaceID: f.ledger.workspaceID, selection: different, reviewedLedgerRevision: f.request.reviewedLedgerRevision)
        do { _ = try await f.port.prepare(request); XCTFail("Changed body") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .operationConflict) }
        XCTAssertNil(try f.pending.read())
        let mismatchedBase = PantryPackSelectionCommitPort.Request(inventoryWorkspaceID: f.inventory.workspaceID,
            ledgerWorkspaceID: f.ledger.workspaceID, selection: original, reviewedLedgerRevision: f.request.reviewedLedgerRevision + 1)
        do { _ = try await f.port.prepare(mismatchedBase); XCTFail("Changed original base") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .operationConflict) }
        XCTAssertNil(try f.pending.read())
    }

    func testExpiredActionGrantAllowsOnlyExactCommittedRecoveryAndReadRevocationDeniesPayload() async throws {
        let f = try await fixture(actionRequired: true), entry = try await prepared(f)
        f.controls.action = false
        do { _ = try await f.port.recover(entry, commitIfUnapplied: true); XCTFail("Fresh action grant required") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .actionUnauthorized) }
        XCTAssertEqual(try f.pending.read(), entry)
        f.controls.action = true
        let first = try committed(await f.port.recover(entry, commitIfUnapplied: true))
        f.controls.action = false
        let (reopened, _) = try reopen(f)
        let replayed = try committed(await reopened.recover(entry, commitIfUnapplied: true))
        XCTAssertEqual(replayed.receipt, first.receipt); XCTAssertTrue(replayed.replayed)
        f.controls.access = false
        do { _ = try await reopened.recover(entry); XCTFail("Private access revoked") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .unauthorized) }
        XCTAssertNotNil(try f.pending.read(), "Protected pending is retained even when UI read authority is lost.")
    }

    func testSharedGateAndIndependentLedgerWriterPreventStaleApplication() async throws {
        let f = try await fixture()
        let lease = try f.gate.beginWrite()
        do { _ = try await f.port.prepare(f.request); XCTFail("Shared writer owns gate") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        f.gate.endWrite(lease)
        XCTAssertNil(try f.pending.read())
        let entry = try await prepared(f)
        let loaded = try await f.ledger.load()
        let original = try XCTUnwrap(loaded)
        let separate = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite")); f.cleanup.track(separate)
        _ = try await separate.save(payload: original.payload, expectedRevision: original.revision, operationID: UUID(), savedAt: now)
        do { _ = try await f.port.recover(entry, commitIfUnapplied: true); XCTFail("Independent ledger changed") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .staleReview) }
        let absent = try await f.ledger.savedOperation(id: entry.operationID); XCTAssertNil(absent)
    }

    func testLockedLedgerFailureThenRestartCannotApplyAgainstChangedStock() async throws {
        let f = try await fixture(), entry = try await prepared(f)
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.directory.appendingPathComponent("ledger.sqlite").path, &lock), SQLITE_OK)
        let pointer = try XCTUnwrap(lock)
        defer { sqlite3_exec(pointer, "ROLLBACK", nil, nil, nil); sqlite3_close(pointer) }
        XCTAssertEqual(sqlite3_exec(pointer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        do { _ = try await f.port.recover(entry, commitIfUnapplied: true); XCTFail("Writer lock") }
        catch { XCTAssertNotNil(error as? LedgerStoreError) }
        XCTAssertEqual(sqlite3_exec(pointer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try f.pending.read(), entry)
        try await recount(f, amount: 1)
        let (reopened, _) = try reopen(f)
        do { _ = try await reopened.recover(entry, commitIfUnapplied: true); XCTFail("Changed stock after failed write") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .staleReview) }
        let receipt = try await f.ledger.savedOperation(id: entry.operationID); XCTAssertNil(receipt)
    }

    func testProtectedOriginalJournalRejectsTamperingForeignOriginAndOversize() async throws {
        let f = try await fixture(), entry = try await prepared(f)
        let bytes = try Data(contentsOf: f.pending.fileURL)
        let foreign = try PantryPackSelectionPendingStore(directory: f.pending.fileURL.deletingLastPathComponent(),
            inventoryWorkspaceID: UUID(), ledgerWorkspaceID: f.ledger.workspaceID)
        try bytes.write(to: foreign.fileURL)
        XCTAssertThrowsError(try foreign.read())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["digest"] = Data(repeating: 0, count: 32).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: f.pending.fileURL)
        XCTAssertThrowsError(try f.pending.read())
        try Data(repeating: 0, count: PantryPackSelectionPendingStore.maximumFileBytes + 1).write(to: f.pending.fileURL)
        XCTAssertThrowsError(try f.pending.read())
        try bytes.write(to: f.pending.fileURL)
        XCTAssertEqual(try f.pending.read(), entry)
        try f.pending.ensureProtected(expected: entry)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.pending.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try f.pending.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
