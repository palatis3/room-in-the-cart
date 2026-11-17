import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryPackModelRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private final class State { var allowed = true; var failCleanup = false }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let ledger: LedgerModel
        let ledgerStore: LedgerStore
        let inventory: ComparisonStore
        let pickup: PickupModel
        let gate: PantryMutationGate
        let journal: PantryPackSelectionPendingStore
        let port: PantryPackSelectionCommitPort
        let state: State
        let shop: UUID
        let food: UUID
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), gate = PantryMutationGate(), instant = now
        let state = State()
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), clock: { instant },
            inventoryProjectionsEnabled: true, mutationGate: gate)
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(ledger, producer, inventory)
        await ledger.open(); await producer.load()
        let ledgerStore = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(ledgerStore)
        var shop = ShoppingLedger(title: "Pantry pack recovery", basis: .init(branch: "Main", mode: .pickup,
            slot: now, timeZoneIdentifier: "America/New_York"))
        let food = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let saved = await ledger.change(key: "fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(saved)
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        let started = try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: producer)
        XCTAssertTrue(started)
        let stocked = await producer.saveStockLot(.init(id: food, foodID: food, name: "Wraps at home", usable: q(4),
            confirmedAt: now, source: .freezer), in: shop.id)
        XCTAssertTrue(stocked)
        for head in try await producer.archiveSnapshot().records {
            _ = try await inventory.save(id: head.id, title: head.title, payload: head.payload, savedAt: head.savedAt)
        }
        let snapshot = try await inventory.inventoryCutoverSnapshot()
        let mapped = try PantryLegacyMigration.map(originID: inventory.workspaceID,
            heads: snapshot.sources.map(PantryLegacyMigration.SourceHead.init),
            ledger: .available(originID: ledgerStore.workspaceID, revision: ledger.revision, workspace: ledger.workspace), at: now)
        let package = try PantryMigrationPackage.build(mapped, migrationID: UUID(), sourceToken: snapshot.token, inventoryRevision: 0, at: now)
        _ = try await inventory.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await inventory.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await inventory.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledgerStore.workspaceID)
        let pickup = PickupModel(store: inventory, clock: { instant }, pantry: .init(ledger: ledgerStore,
            pendingStore: pending, gate: gate, authorize: { state.allowed }))
        cleanup.track(pickup)
        await pickup.load()
        XCTAssertTrue(pickup.ready)
        let journal = try PantryPackSelectionPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledgerStore.workspaceID, removeFile: { url in
                if state.failCleanup { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.removeItem(at: url)
            })
        let port = PantryPackSelectionCommitPort(store: inventory, ledger: ledgerStore, pendingStore: journal,
            gate: gate, authorize: { _, _ in state.allowed }, clock: { instant })
        return .init(directory: directory, cleanup: cleanup, ledger: ledger, ledgerStore: ledgerStore,
            inventory: inventory, pickup: pickup, gate: gate, journal: journal, port: port, state: state, shop: shop.id, food: food)
    }
    private func review(_ f: Fixture) throws -> LedgerPackReview {
        try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop, lineID: f.food,
            offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)),
            itemCap: nil, at: now, source: "Fixture", pickup: f.pickup)
    }
    private func request(_ review: LedgerPackReview, in f: Fixture) throws -> PantryPackSelectionCommitPort.Request {
        let selection = try LedgerPackSelection(id: review.operationID, workspaceID: review.sourceWorkspaceID,
            shop: review.sourceShop, lineID: review.lineID, request: review.request, selectedOfferID: "a",
            at: review.reviewedAt, source: review.source, bindings: review.bindings,
            canonicalStockEvidence: review.canonicalStockEvidence)
        return .init(inventoryWorkspaceID: f.inventory.workspaceID, ledgerWorkspaceID: f.ledgerStore.workspaceID,
            selection: selection, reviewedLedgerRevision: review.workspaceRevision)
    }
    private func reopen(_ f: Fixture) async -> LedgerModel {
        let instant = now
        let model = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"), clock: { instant },
            inventoryProjectionsEnabled: true, mutationGate: f.gate, pantryPackPort: f.port)
        f.cleanup.track(model)
        await model.open()
        return model
    }
    private func recount(_ f: Fixture) async throws {
        let repository = PantryRepository(store: f.inventory, mutationGate: f.gate, authorize: { f.state.allowed })
        let before = try await repository.load(at: now), lot = try XCTUnwrap(before.lots.first)
        _ = try await repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: lot.id,
            eventID: UUID(), expectedRevision: lot.revision, occurredAt: now, change: .count(.someLeft, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
    }

    func testRealPackReviewSavesCanonicalChoiceAndExactRetryDoesNotWriteAgain() async throws {
        let f = try await fixture(), reviewed = try review(f)
        XCTAssertEqual(reviewed.request.confirmedAtHome?.amount, try Rational(4))
        let before = try await f.inventory.inventoryState()
        let saved = try await reviewed.save(offerID: "a", ledger: f.ledger, pickup: f.pickup)
        XCTAssertTrue(saved); XCTAssertFalse(f.ledger.hasPendingSave)
        XCTAssertEqual(f.ledger.workspace.packSelections.first?.formatVersion, 3)
        XCTAssertNil(try f.journal.read())
        let revision = f.ledger.revision
        try await recount(f)
        let replayed = try await reviewed.save(offerID: "a", ledger: f.ledger, pickup: f.pickup)
        XCTAssertTrue(replayed); XCTAssertEqual(f.ledger.revision, revision)
        do { _ = try await reviewed.save(offerID: "b", ledger: f.ledger, pickup: f.pickup); XCTFail("Different offer under completed ID") }
        catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .operationConflict) }
        XCTAssertNil(try f.journal.read(), "Changed completed retry must not poison the journal.")
        let after = try await f.inventory.inventoryState()
        XCTAssertEqual(after.revision, before.revision + 1, "Only the explicit recount changes inventory.")
    }

    func testRestartRestoresUnappliedRequestBlocksOrdinaryEditsAndDiscardsOnlyAfterNoReceipt() async throws {
        let f = try await fixture(), original = try request(review(f), in: f)
        let entry = try f.port.stage(original)
        let restored = await reopen(f)
        XCTAssertTrue(restored.ready); XCTAssertTrue(restored.hasPendingSave)
        XCTAssertEqual(restored.pendingPantryPack?.request, original)
        let edited = await restored.change(key: "must wait") { $0.shops[0].title = "Unexpected" }
        XCTAssertFalse(edited)
        try await recount(f)
        let retried = await restored.retrySave()
        XCTAssertFalse(retried); XCTAssertEqual(try f.journal.read(), entry)
        XCTAssertTrue(restored.workspace.packSelections.isEmpty)
        await restored.discardPendingSave()
        XCTAssertFalse(restored.hasPendingSave); XCTAssertNil(try f.journal.read())
        let receipt = try await f.ledgerStore.savedOperation(id: original.selection.id)
        XCTAssertNil(receipt)
        let current = try await f.ledgerStore.load()
        XCTAssertEqual(current?.revision, original.reviewedLedgerRevision)
    }

    func testCommittedCleanupFailureReopensAndAdoptsLaterLedgerWithoutDuplicate() async throws {
        let f = try await fixture(), original = try request(review(f), in: f)
        f.state.failCleanup = true
        do { _ = try await f.ledger.savePantryPack(original, using: f.port); XCTFail("Injected cleanup failure") }
        catch { XCTAssertNotNil(f.ledger.pendingPantryPack) }
        XCTAssertTrue(f.ledger.hasPendingSave)
        XCTAssertNotNil(try f.journal.read()?.acknowledgment)
        XCTAssertEqual(f.ledger.workspace.packSelections.first?.id, original.selection.id)
        let later = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"),
            inventoryProjectionsEnabled: true, mutationGate: f.gate)
        f.cleanup.track(later)
        await later.open()
        let changed = await later.change(key: "independent later edit") { $0.shops[0].title = "Later title" }
        XCTAssertTrue(changed)
        try await recount(f)
        f.state.failCleanup = false
        let restored = await reopen(f)
        XCTAssertTrue(restored.ready); XCTAssertFalse(restored.hasPendingSave)
        XCTAssertEqual(restored.workspace.shops.first?.title, "Later title")
        XCTAssertEqual(restored.revision, later.revision)
        XCTAssertEqual(restored.workspace.packSelections.count, 1)
        XCTAssertNil(try f.journal.read())
        let replay = await f.ledger.retrySave()
        XCTAssertTrue(replay); XCTAssertEqual(f.ledger.revision, later.revision)
        XCTAssertEqual(f.ledger.workspace.shops.first?.title, "Later title")
    }

    func testRetiredLedgerPortCannotOpenOrRetargetReplacementOrigin() async throws {
        let f = try await fixture(), original = try request(review(f), in: f)
        let entry = try f.port.stage(original)
        _ = try await f.ledgerStore.eraseWorkspace(workspaceID: f.ledgerStore.workspaceID,
            expectedRevision: original.reviewedLedgerRevision, operationID: UUID(), at: now)
        let replacement = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(replacement)
        let restored = await reopen(f)
        XCTAssertFalse(restored.ready)
        XCTAssertTrue(restored.workspace.shops.isEmpty)
        XCTAssertEqual(try f.journal.read(), entry, "Rebuilding composition must never retarget an old request.")
        let head = try await replacement.load()
        XCTAssertNil(head)
        XCTAssertNotEqual(replacement.workspaceID, original.ledgerWorkspaceID)
    }

    func testRevokedReadAccessRedactsModelAndKeepsJournalForAuthorizedRestart() async throws {
        let f = try await fixture(), original = try request(review(f), in: f)
        let entry = try f.port.stage(original)
        let restored = await reopen(f)
        f.state.allowed = false
        let retried = await restored.retrySave()
        XCTAssertFalse(retried); XCTAssertFalse(restored.ready)
        XCTAssertTrue(restored.workspace.shops.isEmpty)
        XCTAssertNil(restored.pendingPantryPack)
        XCTAssertEqual(try f.journal.read(), entry)
        f.state.allowed = true
        await restored.open()
        XCTAssertTrue(restored.hasPendingSave)
        let saved = await restored.retrySave()
        XCTAssertTrue(saved); XCTAssertNil(try f.journal.read())
        XCTAssertEqual(restored.workspace.packSelections.first?.id, original.selection.id)
    }
}
