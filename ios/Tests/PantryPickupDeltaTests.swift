import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryPickupDeltaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private final class Clock { var now: Date; init(_ now: Date) { self.now = now } }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let targetURL: URL
        let producer: ComparisonStore
        let pickup: PickupModel
        let target: ComparisonStore
        let repository: PantryRepository
        let clock: Clock
        let food: UUID
        let stock: UUID
    }
    /// Both sides contain real persisted PickupModel journeys. The inactive
    /// producer supplies legacy candidates while the target has activated pantry.
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), clock = Clock(now)
        let producer = try ComparisonStore(url: directory.appendingPathComponent("producer.sqlite"))
        let pickup = PickupModel(store: producer, clock: { clock.now })
        let food = UUID(), stock = UUID()
        let added = await pickup.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: q(6),
            available: q(1), due: nil, confirmedAt: now))
        XCTAssertTrue(added)
        let journey = try XCTUnwrap(pickup.journey?.id)
        let stocked = await pickup.saveStockLot(.init(id: stock, foodID: food, name: "Freezer wraps", usable: q(4),
            confirmedAt: now, source: .freezer), in: journey)
        XCTAssertTrue(stocked)
        return try await activate(producer: producer, pickup: pickup, directory: directory, cleanup: cleanup,
            clock: clock, food: food, stock: stock)
    }
    private func activate(producer: ComparisonStore, pickup: PickupModel, directory: URL,
                          cleanup: SQLiteFixtureDirectory, clock: Clock, food: UUID, stock: UUID) async throws -> Fixture {
        let targetURL = directory.appendingPathComponent("target.sqlite")
        let target = try ComparisonStore(url: targetURL, inventoryEnabled: true)
        for record in try await producer.list() {
            _ = try await target.save(id: record.id, title: record.title, payload: record.payload, savedAt: record.savedAt)
        }
        let heads = try await target.list().map(PantryLegacyMigration.SourceHead.init)
        let mapped = try PantryLegacyMigration.map(originID: target.workspaceID, heads: heads, ledger: .unavailable, at: now)
        let token = try await target.inventorySourceToken(), state = try await target.inventoryState()
        let package = try PantryMigrationPackage.build(mapped, migrationID: UUID(), sourceToken: token,
            inventoryRevision: state.revision, at: now)
        _ = try await target.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await target.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await target.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: target, authorize: { true })
        cleanup.track(producer, pickup, target, repository)
        return Fixture(cleanup: cleanup, targetURL: targetURL, producer: producer, pickup: pickup, target: target,
            repository: repository, clock: clock, food: food, stock: stock)
    }
    private func lot(_ source: UUID, in f: Fixture) async throws -> InventoryLot {
        let snapshot = try await f.repository.load(at: f.clock.now)
        return try XCTUnwrap(snapshot.lots.first { $0.source == .manual(originID: f.target.workspaceID, sourceID: source) })
    }
    @discardableResult private func change(_ change: InventoryChange, source: UUID, in f: Fixture) async throws -> InventoryLot {
        let snapshot = try await f.repository.load(at: f.clock.now), current = try await lot(source, in: f)
        let command = InventoryCommand(id: UUID(), originID: f.target.workspaceID, lotID: current.id, eventID: UUID(),
            expectedRevision: current.revision, occurredAt: f.clock.now, change: change)
        let result = try await f.repository.apply(command, reviewedInventoryRevision: snapshot.state.revision, at: f.clock.now)
        return try XCTUnwrap(result.current.lots.first { $0.id == current.id })
    }
    private func review(_ f: Fixture) async throws -> PantryPickupDelta.Review {
        let prior = try await f.target.list().map(PantryLegacyMigration.SourceHead.init)
        let current = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
        let proposed = try await f.producer.list().map { record -> PantryLegacyMigration.SourceHead in
            if let old = current[record.id], old.payload == record.payload { return old }
            return .init(id: record.id, revision: (current[record.id]?.revision ?? 0) + 1,
                payload: record.payload, savedAt: record.savedAt)
        }
        let snapshot = try await f.repository.load(at: f.clock.now)
        return try PantryPickupDelta.prepare(operationID: UUID(), originID: f.target.workspaceID, prior: prior,
            proposed: proposed, inventory: snapshot, ledger: .unavailable, at: f.clock.now)
    }
    @discardableResult private func commit(_ review: PantryPickupDelta.Review, in f: Fixture) async throws -> PantryRepository.Snapshot {
        let current = try await f.repository.load(at: f.clock.now)
        try f.repository.validateCapacity(of: review.batch.writes, replacing: current)
        _ = try await f.target.commitInventory(review.batch, at: review.preparedAt)
        return try await f.repository.load(at: f.clock.now)
    }
    private func note(_ f: Fixture) async throws {
        let saved = await f.pickup.change { value in
            value.notes.append(.init(id: UUID(), text: "Keep dinner private", language: "en", createdAt: f.clock.now, revision: value.revision))
        }
        XCTAssertTrue(saved)
    }

    func testUnrelatedPersistedNotePreservesQualitativeCountStorageOpenedAndStandaloneLotAfterReopen() async throws {
        let f = try await fixture()
        f.clock.now = now.addingTimeInterval(10)
        _ = try await change(.count(.someLeft, observationID: UUID()), source: f.stock, in: f)
        _ = try await change(.move(.fridge), source: f.stock, in: f)
        _ = try await change(.opened(f.clock.now), source: f.stock, in: f)
        let preserved = try await change(.revise(.init(name: "My wraps", useFirst: true)), source: f.stock, in: f)
        let snapshot = try await f.repository.load(at: f.clock.now), standaloneID = UUID()
        let create = InventoryCommand(id: UUID(), originID: f.target.workspaceID, lotID: standaloneID, eventID: UUID(),
            expectedRevision: nil, occurredAt: f.clock.now, change: .create(.init(foodID: UUID(), name: "Milk",
                source: .manual(originID: f.target.workspaceID, sourceID: UUID()), location: .fridge,
                unit: .count, count: .exact(q(2))), observationID: UUID()))
        let created = try await f.repository.apply(create, reviewedInventoryRevision: snapshot.state.revision, at: f.clock.now)
        let standalone = try XCTUnwrap(created.current.lots.first { $0.id == standaloneID })
        try await note(f)
        let delta = try await review(f)
        XCTAssertTrue(delta.batch.writes.isEmpty)
        XCTAssertEqual(delta.changedHeads.count, 1)
        _ = try await commit(delta, in: f)
        let reopened = try ComparisonStore(url: f.targetURL, inventoryEnabled: true)
        f.cleanup.track(reopened)
        let actual = try await PantryRepository(store: reopened, authorize: { true }).load(at: f.clock.now)
        XCTAssertEqual(actual.lots.first { $0.id == preserved.id }, preserved)
        XCTAssertEqual(actual.lots.first { $0.id == standaloneID }, standalone)
        let saved = try await reopened.load(id: XCTUnwrap(f.pickup.journey?.id))
        XCTAssertEqual(saved?.payload, delta.changedHeads.first?.payload)
        XCTAssertEqual(saved?.savedAt, delta.preparedAt)
        XCTAssertNil(actual.availability.lots.first { $0.id == preserved.id }?.free)
    }

    func testMetadataOnlyAndExplicitRecountAdvanceOneHeadWithoutCopyingOldCanonicalFields() async throws {
        let f = try await fixture()
        f.clock.now = now.addingTimeInterval(10)
        let qualitative = try await change(.count(.haveEnough, observationID: UUID()), source: f.stock, in: f)
        _ = try await change(.move(.fridge), source: f.stock, in: f)
        let old = try XCTUnwrap(f.pickup.journey?.stockLots.first { $0.id == f.stock })
        let renamed = ConfirmedStockLot(id: old.id, foodID: old.foodID, name: "Lunch wraps", usable: old.usable,
            confirmedAt: old.confirmedAt, source: old.source, useFirst: true)
        let saved = try await f.pickup.saveStockLot(renamed, in: XCTUnwrap(f.pickup.journey?.id), replacing: old)
        XCTAssertTrue(saved)
        let metadata = try await review(f)
        XCTAssertFalse(metadata.batch.writes.contains { $0.record.key.kind == .observation })
        _ = try await commit(metadata, in: f)
        let afterMetadata = try await lot(f.stock, in: f)
        XCTAssertEqual(afterMetadata.count, .haveEnough)
        XCTAssertEqual(afterMetadata.observationID, qualitative.observationID)
        XCTAssertEqual(afterMetadata.location, .fridge)
        XCTAssertEqual(afterMetadata.name, "Lunch wraps"); XCTAssertTrue(afterMetadata.useFirst)
        f.clock.now = now.addingTimeInterval(30)
        let countedAt = now.addingTimeInterval(20)
        let recount = ConfirmedStockLot(id: old.id, foodID: old.foodID, name: "Counted wraps", usable: q(3),
            confirmedAt: countedAt, source: .pantry, useFirst: true)
        let counted = try await f.pickup.saveStockLot(recount, in: XCTUnwrap(f.pickup.journey?.id), replacing: renamed)
        XCTAssertTrue(counted)
        let physical = try await review(f)
        XCTAssertEqual(physical.batch.writes.filter { $0.record.key.kind == .observation }.count, 1)
        _ = try await commit(physical, in: f)
        let result = try await lot(f.stock, in: f)
        XCTAssertEqual(result.id, qualitative.id)
        XCTAssertEqual(result.revision, afterMetadata.revision + 1)
        XCTAssertEqual(result.count, .exact(q(3))); XCTAssertEqual(result.confirmedAt, countedAt)
        XCTAssertEqual(result.updatedAt, f.clock.now); XCTAssertEqual(result.location, .cupboard)
    }

    func testUrgentAvailabilityUpdatesItsExistingPhysicalSourceAndReleasesOnlyRemovedNeed() async throws {
        let f = try await fixture(), original = try await lot(f.food, in: f)
        f.clock.now = now.addingTimeInterval(10)
        let saved = await f.pickup.change { value in
            let index = try XCTUnwrap(value.stockLots.firstIndex { $0.id == f.food })
            value.stockLots[index] = .init(id: f.food, foodID: f.food, name: "Wraps", usable: q(2), confirmedAt: f.clock.now)
            value.stockNeeds.removeAll { $0.id == f.food }
        }
        XCTAssertTrue(saved)
        let delta = try await review(f), current = try await commit(delta, in: f)
        let counted = try XCTUnwrap(current.lots.first { $0.id == original.id })
        XCTAssertEqual(counted.count, .exact(q(2)))
        XCTAssertEqual(counted.revision, original.revision + 1)
        XCTAssertEqual(current.reservations.count, 1)
        XCTAssertEqual(current.reservations.first?.state, .released)
    }

    func testCopiedNextShopReferenceCannotRestoreOldCountOrDuplicatePhysicalLot() async throws {
        let f = try await fixture()
        f.clock.now = now.addingTimeInterval(10)
        let preserved = try await change(.count(.someLeft, observationID: UUID()), source: f.stock, in: f)
        let previous = try XCTUnwrap(f.pickup.journey), copied = try XCTUnwrap(previous.stockLots.first { $0.id == f.stock })
        let started = await f.pickup.startNextShop(accept: [])
        XCTAssertTrue(started)
        _ = try await commit(review(f), in: f)
        let saved = try await f.pickup.saveStockLot(copied, in: XCTUnwrap(f.pickup.journey?.id), carriedFrom: copied)
        XCTAssertTrue(saved)
        let delta = try await review(f)
        XCTAssertFalse(delta.batch.writes.contains { $0.record.key.kind == .lot || $0.record.key.kind == .observation })
        let current = try await commit(delta, in: f)
        XCTAssertEqual(current.lots.first { $0.id == preserved.id }, preserved)
        XCTAssertEqual(current.lots.filter { $0.source == preserved.source }.count, 1)
        XCTAssertEqual(current.reservations.count, 1, "Carrying the same urgent need does not double its demand.")
    }

    func testNewLegacyReferenceToStandaloneCanonicalSourcePreservesItsCountAndIdentity() async throws {
        let f = try await fixture(), sourceID = UUID(), canonicalID = UUID()
        let snapshot = try await f.repository.load(at: now)
        let command = InventoryCommand(id: UUID(), originID: f.target.workspaceID, lotID: canonicalID, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: f.food, name: "My separate batch",
                source: .manual(originID: f.target.workspaceID, sourceID: sourceID), location: .fridge,
                unit: .count, count: .someLeft), observationID: UUID()))
        let created = try await f.repository.apply(command, reviewedInventoryRevision: snapshot.state.revision, at: now)
        let original = try XCTUnwrap(created.current.lots.first { $0.id == canonicalID })
        let saved = try await f.pickup.saveStockLot(.init(id: sourceID, foodID: f.food, name: "Older count", usable: q(8),
            confirmedAt: now, source: .freezer), in: XCTUnwrap(f.pickup.journey?.id))
        XCTAssertTrue(saved)
        let delta = try await review(f), result = try await commit(delta, in: f)
        XCTAssertEqual(result.lots.first { $0.id == canonicalID }, original)
        XCTAssertEqual(result.lots.filter { $0.source == original.source }.count, 1)
    }

    func testSourceErasureIsNotInterpretedAsPhysicalConsumptionOrClaimRelease() async throws {
        let f = try await fixture(), prior = try await f.target.list().map(PantryLegacyMigration.SourceHead.init)
        let snapshot = try await f.repository.load(at: now)
        XCTAssertThrowsError(try PantryPickupDelta.prepare(operationID: UUID(), originID: f.target.workspaceID,
            prior: prior, proposed: [], inventory: snapshot, ledger: .unavailable, at: now)) {
            XCTAssertEqual($0 as? PantryPickupDelta.Failure, .removedSourceHead)
        }
        let unchanged = try await f.repository.load(at: now)
        XCTAssertEqual(unchanged.lots, snapshot.lots); XCTAssertEqual(unchanged.reservations, snapshot.reservations)
    }

    private func receiptFixture() async throws -> (Fixture, ReceiptFragment, UsableObservation) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), clock = Clock(now)
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let store = try ComparisonStore(url: directory.appendingPathComponent("producer.sqlite"))
        let pickup = PickupModel(store: store, clock: { clock.now })
        cleanup.track(ledger, pickup, store)
        await ledger.open(); await pickup.load(); pickup.bindCookLedger(ledger)
        var shop = ShoppingLedger(title: "Pantry migration", basis: .init(branch: "Main", mode: .pickup, slot: now,
            timeZoneIdentifier: "America/New_York", cap: .init(minorUnits: 3800)))
        let food = try shop.addManualLine(name: "Wraps", quantity: q(6))
        let supply = try XCTUnwrap(shop.contributions(forLineID: food).first?.id)
        let meal = try shop.chooseMeal(.init(title: "Wrap dinner", servings: try Rational(2),
            ingredients: [.init(name: "Wraps", quantity: q(4))]), on: now)
        let ingredient = try XCTUnwrap(shop.mealOccurrences.first { $0.id == meal }?.ingredientContributionIDs.first)
        try shop.linkContribution(contributionID: ingredient, within: supply, quantity: q(4))
        try shop.addProtectedNeed(name: "Wraps", quantity: q(2), purpose: "Lunch", within: supply)
        let saved = await ledger.change(key: "migration-fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(saved)
        let packs = try LedgerPackReview.prepare(ledger: ledger, shopID: shop.id, lineID: food,
            offerA: .init(id: "eight", label: "Eight wraps", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "six", label: "Six wraps", usableQuantity: q(6), price: .init(minorUnits: 250)),
            itemCap: nil, at: now, source: "Package")
        let packed = try await packs.save(offerID: "eight", ledger: ledger); XCTAssertTrue(packed)
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision,
            previous: nil, packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        let applied = try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: pickup); XCTAssertTrue(applied)
        let quoted = await pickup.setQuote(.init(scope: .wholeCheckout, context: checkout.context,
            pricing: .inclusiveTotal(.exact(.init(minorUnits: 300)))), cap: nil); XCTAssertTrue(quoted)
        let frozen = await pickup.freeze(); XCTAssertTrue(frozen)
        let placed = await pickup.reportPlaced(); XCTAssertTrue(placed)
        let key = ReceiptKey(sourceEventID: "actual-delivery", orderLineID: food, branchID: "Main", segmentID: "one")
        let receipt = ReceiptFragment(key: key, itemName: "Wraps", received: q(8), disposition: .received, receivedAt: now)
        let observation = UsableObservation(id: UUID(), receipt: key, usable: q(8), confirmedAt: now, confirmedMatchToOrderLine: true)
        let received = await pickup.receive(receipt, usable: observation); XCTAssertTrue(received)
        let stock = UUID()
        let stocked = try await pickup.saveStockLot(.init(id: stock, foodID: food, name: "Existing freezer batch",
            usable: q(4), confirmedAt: now, source: .freezer), in: XCTUnwrap(pickup.journey?.id))
        XCTAssertTrue(stocked)
        let fixture = try await activate(producer: store, pickup: pickup, directory: directory, cleanup: cleanup,
            clock: clock, food: food, stock: stock)
        return (fixture, receipt, observation)
    }

    func testReceiptCorrectionChangesOnlyFullReceiptSourceAndPreservesIndependentRecount() async throws {
        let (f, receipt, observation) = try await receiptFixture()
        f.clock.now = now.addingTimeInterval(10)
        let preserved = try await change(.count(.someLeft, observationID: UUID()), source: f.stock, in: f)
        let before = try await f.repository.load(at: f.clock.now)
        let source = InventorySource.receipt(originID: f.target.workspaceID, key: receipt.key)
        let physical = try XCTUnwrap(before.lots.first { $0.source == source })
        let corrected = UsableObservation(id: UUID(), receipt: receipt.key, usable: q(3), confirmedAt: f.clock.now,
            supersedesID: observation.id, confirmedMatchToOrderLine: true)
        let saved = await f.pickup.confirmUsable(corrected)
        XCTAssertTrue(saved)
        let delta = try await review(f), result = try await commit(delta, in: f)
        let updated = try XCTUnwrap(result.lots.first { $0.id == physical.id })
        XCTAssertEqual(updated.source, source); XCTAssertEqual(updated.count, .exact(q(3)))
        XCTAssertEqual(updated.revision, physical.revision + 1)
        XCTAssertEqual(result.lots.first { $0.id == preserved.id }, preserved)
        XCTAssertEqual(result.reservations, before.reservations, "A recount does not copy or double legacy demand.")
        // A different segment with the same food/order/source event is a distinct
        // received physical source, never an alias for the corrected first one.
        f.clock.now = now.addingTimeInterval(20)
        let secondKey = ReceiptKey(sourceEventID: receipt.key.sourceEventID, orderLineID: receipt.key.orderLineID,
            branchID: receipt.key.branchID, segmentID: "two")
        let second = ReceiptFragment(key: secondKey, itemName: "Wraps", received: q(2), disposition: .received, receivedAt: f.clock.now)
        let secondObservation = UsableObservation(id: UUID(), receipt: secondKey, usable: q(2), confirmedAt: f.clock.now,
            confirmedMatchToOrderLine: true)
        let received = await f.pickup.receive(second, usable: secondObservation)
        XCTAssertTrue(received)
        let addition = try await review(f)
        _ = try await commit(addition, in: f)
        let reopened = try ComparisonStore(url: f.targetURL, inventoryEnabled: true)
        f.cleanup.track(reopened)
        let reloaded = try await PantryRepository(store: reopened, authorize: { true }).load(at: f.clock.now)
        XCTAssertEqual(reloaded.lots.first { $0.id == physical.id }, updated)
        let distinct = try XCTUnwrap(reloaded.lots.first { $0.source == .receipt(originID: f.target.workspaceID, key: secondKey) })
        XCTAssertNotEqual(distinct.id, physical.id); XCTAssertEqual(distinct.count, .exact(q(2)))
        XCTAssertEqual(reloaded.lots.first { $0.id == preserved.id }, preserved)
    }
}
