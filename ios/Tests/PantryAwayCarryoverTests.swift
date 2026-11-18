import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryAwayCarryoverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private final class Controls { var action = true; var removals = 0; var failRemoval: Int? }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let controls: Controls
        let inventory: ComparisonStore
        let ledgerStore: LedgerStore
        let ledger: LedgerModel
        let gate: PantryMutationGate
        let journal: PantryPickupPendingStore
        let packPort: PantryPackSelectionCommitPort
        let pickup: PickupModel
        let dinner: DinnerFeatureModel
        let model: DinnerAwayCarryoverModel
        let meal: UUID
        let need: UUID
        let food: UUID
        let supply: AwayCarryoverSupply
    }
    private func fixture(received: Bool = false, external: Bool = false,
                         legacyPhase: AwayCarryoverRecord.Phase? = nil, calendarCreated: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), controls = Controls(), gate = PantryMutationGate(), instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), clock: { instant },
            inventoryProjectionsEnabled: true, mutationGate: gate)
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        cleanup.track(ledger, producer); await ledger.open(); await producer.load()
        let ledgerStore = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(ledgerStore)
        var shop = ShoppingLedger(title: "Canonical carryover", basis: .init(timeZoneIdentifier: "America/New_York"))
        let meal = try shop.chooseMeal(.init(title: "Wrap dinner", servings: try Rational(2), ingredients: [.init(name: "Wraps", quantity: q(4))]),
            on: now.addingTimeInterval(-86_400), at: now.addingTimeInterval(-86_400))
        let occurrence = try XCTUnwrap(shop.mealOccurrences.first), need = try XCTUnwrap(occurrence.ingredientContributionIDs.first)
        let food = try XCTUnwrap(shop.contributions.first { $0.id == need }?.lineID)
        let lunch = UUID()
        let seeded = await ledger.change(key: "away-fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }; XCTAssertTrue(seeded)
        let context = CheckoutContext(storeID: "Store", branchID: "Main", mode: .pickup, slot: "Evening", commitmentsID: shop.id, observedAt: now, source: "Shopper")
        let needs: [AllocationNeed] = [.init(id: need, orderLineID: food, name: "Wrap dinner", amount: q(4), priority: .required),
            .init(id: lunch, orderLineID: food, name: "Lunch", amount: q(2), priority: .protected)]
        let started = await producer.start(from: [.init(id: food, name: "Wraps", quantity: q(6), expectedCost: .exact(.init(minorUnits: 700)))],
            shopID: shop.id, context: context, plannedNeeds: needs, ledgerBasis: shop.basis, ledgerSourceRevisionID: shop.revisionID,
            needDetails: [.init(id: need, mealName: "Wrap dinner", exclusions: [], scheduledDay: occurrence.scheduledDay,
                leadTimeMinutes: nil, completedSteps: [], sourceContributionID: need)])
        XCTAssertTrue(started)
        let quoted = await producer.setQuote(.init(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.init(minorUnits: 700)))), cap: nil)
        XCTAssertTrue(quoted)
        let frozen = await producer.freeze(); XCTAssertTrue(frozen)
        let placed = await producer.reportPlaced(); XCTAssertTrue(placed)
        let receipt = ReceiptFragment(key: .init(sourceEventID: "actual", orderLineID: food, branchID: "Main", segmentID: "one"),
            itemName: "Wraps", received: q(6), disposition: .received, receivedAt: now)
        let observation = UsableObservation(id: UUID(), receipt: receipt.key, usable: q(6), confirmedAt: now, confirmedMatchToOrderLine: true)
        let arrived = await producer.receive(receipt, usable: received ? observation : nil); XCTAssertTrue(arrived)
        let supply: AwayCarryoverSupply
        if received { supply = .received(receipt, observation) }
        else {
            let lot = ConfirmedStockLot(id: UUID(), foodID: food, name: "Freezer wraps", usable: q(6), confirmedAt: now, source: .freezer)
            let stocked = await producer.saveStockLot(lot, in: shop.id); XCTAssertTrue(stocked)
            supply = .batch(lot)
        }
        let origin = ledgerStore.workspaceID
        let dinner = DinnerFeatureModel(store: ledger, access: { shopID in
            guard controls.action else { return nil }
            return .init(scope: .local(workspaceID: origin), actorID: "local", shopID: shopID,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: false,
                roleRevision: 0, verifiedAt: instant.addingTimeInterval(-1), validUntil: instant.addingTimeInterval(3_600))
        }, phase: { _ in .reportedPlaced }, clock: { instant })
        cleanup.track(dinner)
        if let legacyPhase {
            let legacy = DinnerAwayCarryoverModel(dinner: dinner, pickup: producer, clock: { instant }); cleanup.track(legacy)
            XCTAssertTrue(legacy.prepare(id: UUID(), occurrenceID: meal, needID: need, supply: supply, counted: q(6), reserved: q(2),
                servings: .one, day: try MealDay(date: now.addingTimeInterval(86_400), timeZoneIdentifier: "America/New_York"), observedAt: now))
            let intent = try XCTUnwrap(legacy.review)
            let saved = await producer.change { journey in
                if legacyPhase == .prepared { journey.awayCarryovers.append(.init(intent: intent, phase: .prepared)) }
                else { journey = try AwayCarryoverEngine.reserving(intent, in: journey, at: instant) }
            }; XCTAssertTrue(saved)
            if calendarCreated {
                let created = await ledger.change(key: "legacy-calendar") { try $0.shops[0].appendConfirmedCarryover(intent.plan, at: instant) }
                XCTAssertTrue(created)
            }
        }
        if external {
            // A second genuinely persisted source owns a protected claim on this
            // same food. It contributes no duplicate physical stock.
            let other = UUID(), otherContext = CheckoutContext(storeID: "Store", branchID: "Main", mode: .pickup, slot: "Later",
                commitmentsID: UUID(), observedAt: now, source: "Shopper")
            let saved = await producer.start(from: [.init(id: food, name: "Wraps", quantity: q(6), expectedCost: .exact(.init(minorUnits: 700)))],
                shopID: other, context: otherContext, plannedNeeds: [.init(id: UUID(), orderLineID: food, name: "Other shop protected dinner", amount: q(6), priority: .protected)])
            XCTAssertTrue(saved)
        }
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("inventory.sqlite"), inventoryEnabled: true); cleanup.track(inventory)
        for record in try await producer.archiveSnapshot().records {
            _ = try await inventory.save(id: record.id, title: record.title, payload: record.payload, savedAt: record.savedAt)
        }
        let captured = try await inventory.inventoryCutoverSnapshot()
        let mapping = try PantryLegacyMigration.map(originID: inventory.workspaceID, heads: captured.sources.map(PantryLegacyMigration.SourceHead.init),
            ledger: .available(originID: ledgerStore.workspaceID, revision: ledger.revision, workspace: ledger.workspace), at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: captured.token,
            inventoryRevision: await inventory.inventoryState().revision, at: now)
        _ = try await inventory.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await inventory.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await inventory.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let journal = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"), inventoryWorkspaceID: inventory.workspaceID,
            ledgerWorkspaceID: ledgerStore.workspaceID, removeFile: { url in
                controls.removals += 1
                if controls.removals == controls.failRemoval { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.removeItem(at: url)
            })
        let packJournal = try PantryPackSelectionPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledgerStore.workspaceID)
        let port = PantryPackSelectionCommitPort(store: inventory, ledger: ledgerStore, pendingStore: packJournal,
            gate: gate, authorize: { _, _ in true }, clock: { instant })
        cleanup.track(port)
        try await ledger.configurePantryPackRecovery(port)
        let pickup = PickupModel(store: inventory, clock: { instant }, pantry: .init(ledger: ledgerStore, pendingStore: journal,
            gate: gate, authorize: { true }, packSelectionPort: port))
        cleanup.track(pickup); await pickup.load(); pickup.selectedID = shop.id; pickup.bindCookLedger(ledger)
        let model = DinnerAwayCarryoverModel(dinner: dinner, pickup: pickup, clock: { instant }); cleanup.track(model)
        return .init(directory: directory, cleanup: cleanup, controls: controls, inventory: inventory, ledgerStore: ledgerStore,
            ledger: ledger, gate: gate, journal: journal, packPort: port, pickup: pickup, dinner: dinner, model: model,
            meal: meal, need: need, food: food, supply: supply)
    }
    private func prepare(_ f: Fixture, counted: Int64 = 6) throws -> AwayCarryoverIntent {
        XCTAssertTrue(f.model.prepare(id: UUID(), occurrenceID: f.meal, needID: f.need, supply: f.supply, counted: q(counted), reserved: q(2),
            servings: .one, day: try MealDay(date: now.addingTimeInterval(86_400), timeZoneIdentifier: "America/New_York"), observedAt: now), f.model.message ?? "")
        return try XCTUnwrap(f.model.review)
    }
    private func snapshot(_ f: Fixture) async throws -> PantryRepository.Snapshot {
        let repository = PantryRepository(store: f.inventory, mutationGate: f.gate, authorize: { true }); f.cleanup.track(repository)
        return try await repository.load(at: now)
    }
    private func recount(_ f: Fixture, count: InventoryCount) async throws {
        let before = try await snapshot(f)
        let selected = try XCTUnwrap(before.lots.first { lot in
            switch (f.supply, lot.source) {
            case (.batch(let old), .manual(_, let id)): return old.id == id
            case (.received(let receipt, _), .receipt(_, let key)): return receipt.key == key
            default: return false
            }
        })
        let repository = PantryRepository(store: f.inventory, mutationGate: f.gate, authorize: { true }); f.cleanup.track(repository)
        _ = try await repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: selected.id, eventID: UUID(),
            expectedRevision: selected.revision, occurredAt: now, change: .count(count, observationID: UUID())), reviewedInventoryRevision: before.state.revision, at: now)
    }

    func testCanonicalTransferPinsOnePhysicalLotAndCompletedReplayUsesCurrentCountWithoutActionGrant() async throws {
        let f = try await fixture(), before = try await snapshot(f), intent = try prepare(f)
        let applied = await f.model.apply(); XCTAssertTrue(applied, f.model.message ?? "")
        let after = try await snapshot(f), record = try XCTUnwrap(f.model.records.first)
        XCTAssertEqual(record.phase, .completed)
        let claimID = try PantryLegacyMigration.claimIdentity(originID: f.inventory.workspaceID, needID: intent.plan.link.reservationID, foodID: f.food)
        let claim = try XCTUnwrap(after.reservations.first { $0.id == claimID })
        XCTAssertEqual(claim.lotID, intent.canonical?.lot.id)
        XCTAssertEqual(after.availability.reservations.first { $0.id == claimID }?.shortfall?.amount, .zero)
        XCTAssertEqual(after.lots, before.lots, "Equal explicit recount need not create another physical lot or overwrite metadata.")
        let savedSource = f.pickup.journey, revision = f.ledger.revision
        try await recount(f, count: .exact(q(0)))
        f.controls.action = false
        let replayed = await f.model.retry(record); XCTAssertTrue(replayed)
        XCTAssertEqual(f.pickup.journey, savedSource); XCTAssertEqual(f.ledger.revision, revision)
        let current = try await snapshot(f)
        XCTAssertEqual(current.lots.first { $0.id == claim.lotID }?.count, .exact(q(0)))
    }
    func testOtherShopProtectedClaimPreventsLocalCopiedStockApproval() async throws {
        let f = try await fixture(external: true), before = try await snapshot(f)
        let accepted = f.model.prepare(id: UUID(), occurrenceID: f.meal, needID: f.need, supply: f.supply, counted: q(6), reserved: q(2),
            servings: .one, day: try MealDay(date: now.addingTimeInterval(86_400), timeZoneIdentifier: "America/New_York"), observedAt: now)
        XCTAssertFalse(accepted); XCTAssertNil(f.model.review)
        let after = try await snapshot(f)
        XCTAssertEqual(after.state, before.state); XCTAssertEqual(after.reservations, before.reservations)
        XCTAssertTrue(f.model.records.isEmpty)
    }
    func testIndependentRecountRejectsOldPreviewBeforePreparedHoldIsWritten() async throws {
        let f = try await fixture(); _ = try prepare(f)
        try await recount(f, count: .someLeft)
        let before = try await snapshot(f)
        let applied = await f.model.apply(); XCTAssertFalse(applied)
        XCTAssertFalse(f.pickup.hasPendingSave); XCTAssertTrue(f.model.records.isEmpty)
        let after = try await snapshot(f)
        XCTAssertEqual(after.state, before.state); XCTAssertEqual(after.reservations, before.reservations)
    }
    func testPreparedReceiptRecoveryAfterRestartThenResumeDoesNotDuplicateClaimsOrTarget() async throws {
        let f = try await fixture(); let intent = try prepare(f)
        f.controls.failRemoval = 1
        let applied = await f.model.apply(); XCTAssertFalse(applied); XCTAssertTrue(f.pickup.hasPendingSave)
        let record = try XCTUnwrap(f.model.pending); XCTAssertEqual(record.phase, .prepared)
        f.controls.failRemoval = nil; f.controls.action = false
        let reopened = try ComparisonStore(url: f.directory.appendingPathComponent("inventory.sqlite"), inventoryEnabled: true)
        let journal = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: reopened.workspaceID, ledgerWorkspaceID: f.ledgerStore.workspaceID)
        let instant = now
        let pickup = PickupModel(store: reopened, clock: { instant }, pantry: .init(ledger: f.ledgerStore, pendingStore: journal,
            gate: f.gate, authorize: { true }, packSelectionPort: f.packPort))
        f.cleanup.track(reopened, pickup); await pickup.load(); pickup.selectedID = record.intent.plan.link.sourceShopID; pickup.bindCookLedger(f.ledger)
        let resumed = DinnerAwayCarryoverModel(dinner: f.dinner, pickup: pickup, clock: { instant }); f.cleanup.track(resumed)
        let acknowledged = await resumed.retry(record); XCTAssertFalse(acknowledged, "Receipt can clear, but an uncommitted next phase still needs action authority.")
        XCTAssertFalse(pickup.hasPendingSave); XCTAssertNil(try journal.read())
        f.controls.action = true
        let finished = await resumed.retry(try XCTUnwrap(resumed.pending)); XCTAssertTrue(finished, resumed.message ?? "")
        let after = try await snapshot(f)
        let target = try PantryLegacyMigration.claimIdentity(originID: f.inventory.workspaceID, needID: intent.plan.link.reservationID, foodID: f.food)
        XCTAssertEqual(after.reservations.filter { $0.id == target }.count, 1)
        XCTAssertEqual(f.ledger.shop?.mealOccurrences.filter { $0.id == intent.plan.occurrenceID }.count, 1)
    }
    func testLegacyPreparedCancellationReleasesOnlyOwnHoldAndKeepsCountsAndSourceDemand() async throws {
        let f = try await fixture(legacyPhase: .prepared), record = try XCTUnwrap(f.model.pending)
        let before = try await snapshot(f), source = try XCTUnwrap(f.pickup.journey)
        XCTAssertNil(record.intent.canonical)
        let cancelled = await f.model.cancelPrepared(record); XCTAssertTrue(cancelled, f.model.message ?? "")
        let after = try await snapshot(f)
        let target = try PantryLegacyMigration.claimIdentity(originID: f.inventory.workspaceID, needID: record.intent.plan.link.reservationID, foodID: f.food)
        XCTAssertEqual(after.lots, before.lots)
        XCTAssertEqual(after.reservations.filter { $0.id != target }, before.reservations.filter { $0.id != target })
        XCTAssertEqual(after.reservations.first { $0.id == target }?.state, .released)
        XCTAssertEqual(f.pickup.journey?.needs, source.needs); XCTAssertEqual(f.pickup.journey?.stockNeeds, source.stockNeeds)
        XCTAssertEqual(f.model.records.first?.phase, .cancelled)
    }
    func testPreparedCancellationRejectsIndependentlyChangedHeldClaim() async throws {
        let f = try await fixture(legacyPhase: .prepared), record = try XCTUnwrap(f.model.pending)
        let before = try await snapshot(f)
        let target = try PantryLegacyMigration.claimIdentity(originID: f.inventory.workspaceID, needID: record.intent.plan.link.reservationID, foodID: f.food)
        let old = try XCTUnwrap(before.reservations.first { $0.id == target })
        let changed = InventoryReservation(id: old.id, originID: old.originID, revision: old.revision + 1,
            foodID: old.foodID, lotID: old.lotID, name: "Independently reviewed hold", amount: old.amount,
            priority: old.priority, state: old.state)
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(),
            expectedRevision: before.state.revision, request: Data("independent hold edit".utf8),
            writes: [.init(record: .init(key: .init(.reservation, changed.id), revision: changed.revision,
                payload: JSONEncoder().encode(changed), lotID: changed.lotID), expectedRevision: old.revision)]), at: now)
        let cancelled = await f.model.cancelPrepared(record); XCTAssertFalse(cancelled)
        let after = try await snapshot(f)
        XCTAssertEqual(after.reservations.first { $0.id == target }, changed)
        XCTAssertEqual(f.model.pending?.phase, .prepared); XCTAssertFalse(f.pickup.hasPendingSave)
    }
    func testLegacyReservedRequiresExplicitCanonicalReviewAndThenCreatesOneCalendarTarget() async throws {
        let f = try await fixture(legacyPhase: .reserved), record = try XCTUnwrap(f.model.pending)
        let implicit = await f.model.retry(record); XCTAssertFalse(implicit)
        XCTAssertTrue(f.model.prepareSavedReservation(record), f.model.message ?? "")
        XCTAssertNotNil(f.model.review?.canonical)
        let applied = await f.model.apply(); XCTAssertTrue(applied, f.model.message ?? "")
        XCTAssertEqual(f.model.records.first?.phase, .completed)
        XCTAssertEqual(f.ledger.shop?.mealOccurrences.filter { $0.id == record.intent.plan.occurrenceID }.count, 1)
    }
    func testExistingCalendarTargetCompletesLegacySagaAfterCountFallsWithoutRecountingOldFood() async throws {
        let f = try await fixture(legacyPhase: .reserved, calendarCreated: true), record = try XCTUnwrap(f.model.pending)
        try await recount(f, count: .exact(q(0))); f.controls.action = false
        let before = try await snapshot(f), ledgerRevision = f.ledger.revision
        let completed = await f.model.retry(record); XCTAssertTrue(completed, f.model.message ?? "")
        let after = try await snapshot(f)
        XCTAssertEqual(after.lots, before.lots); XCTAssertEqual(after.reservations, before.reservations)
        XCTAssertEqual(f.ledger.revision, ledgerRevision); XCTAssertEqual(f.model.records.first?.phase, .completed)
    }
    func testCurrentCanonicalCountAboveHistoricalCopyCanBeRecountedAndReserved() async throws {
        let f = try await fixture()
        try await recount(f, count: .exact(q(8)))
        let refreshed = await f.pickup.refreshPantryStock(); XCTAssertTrue(refreshed)
        XCTAssertEqual(f.pickup.journey?.stockLots.first?.usable, q(6))
        let intent = try prepare(f, counted: 8)
        XCTAssertEqual(intent.canonical?.lot.count, .exact(q(8)))
        let applied = await f.model.apply(); XCTAssertTrue(applied, f.model.message ?? "")
        let after = try await snapshot(f)
        XCTAssertEqual(after.lots.first { $0.id == intent.canonical?.lot.id }?.count, .exact(q(8)))
        XCTAssertEqual(f.model.records.first?.phase, .completed)
    }
    func testExplicitRecountResolvesUnknownEvenWhenHistoricalAmountAndTimestampAreUnchanged() async throws {
        let f = try await fixture()
        try await recount(f, count: .unknown)
        let refreshed = await f.pickup.refreshPantryStock(); XCTAssertTrue(refreshed)
        let before = try await snapshot(f), intent = try prepare(f)
        XCTAssertEqual(intent.canonical?.lot.count, .unknown)
        XCTAssertEqual(intent.plan.link.observedAt, f.supply.observedAt)
        let applied = await f.model.apply(); XCTAssertTrue(applied, f.model.message ?? "")
        let after = try await snapshot(f)
        let selected = try XCTUnwrap(after.lots.first { $0.id == intent.canonical?.lot.id })
        XCTAssertEqual(selected.count, .exact(q(6)))
        XCTAssertGreaterThan(selected.revision, try XCTUnwrap(before.lots.first { $0.id == selected.id }).revision)
        XCTAssertEqual(f.model.records.first?.phase, .completed)
    }
    func testActiveLegacyTargetAdoptsItsExistingBackingAfterCountFalls() async throws {
        let f = try await fixture(legacyPhase: .reserved), record = try XCTUnwrap(f.model.pending)
        try await recount(f, count: .exact(q(4)))
        let refreshed = await f.pickup.refreshPantryStock(); XCTAssertTrue(refreshed)
        let before = try await snapshot(f)
        let target = try PantryLegacyMigration.claimIdentity(originID: f.inventory.workspaceID, needID: record.intent.plan.link.reservationID, foodID: f.food)
        XCTAssertEqual(before.availability.reservations.first { $0.id == target }?.backed, q(2))
        XCTAssertTrue(f.model.prepareSavedReservation(record), f.model.message ?? "")
        XCTAssertEqual(f.model.review?.canonical?.recountsPhysicalSource, false)
        let applied = await f.model.apply(); XCTAssertTrue(applied, f.model.message ?? "")
        let after = try await snapshot(f)
        XCTAssertEqual(after.lots, before.lots); XCTAssertEqual(after.reservations, before.reservations)
        XCTAssertEqual(f.model.records.first?.phase, .completed)
    }
    func testCanonicalReceiptCountAboveReceivedAmountUsesIndependentRecountAndKeepsReceiptFacts() async throws {
        let f = try await fixture(received: true), original = try XCTUnwrap(f.pickup.journey?.pickup)
        try await recount(f, count: .exact(q(8)))
        let refreshed = await f.pickup.refreshPantryStock(); XCTAssertTrue(refreshed)
        let intent = try prepare(f, counted: 8)
        XCTAssertEqual(intent.plan.link.confirmedSupplyID, f.supply.id)
        let applied = await f.model.apply(); XCTAssertTrue(applied, f.model.message ?? "")
        let after = try await snapshot(f)
        XCTAssertEqual(after.lots.count, 1); XCTAssertEqual(after.lots.first?.count, .exact(q(8)))
        XCTAssertEqual(f.pickup.journey?.pickup, original)
        let target = try PantryLegacyMigration.claimIdentity(originID: f.inventory.workspaceID, needID: intent.plan.link.reservationID, foodID: f.food)
        XCTAssertEqual(after.reservations.first { $0.id == target }?.lotID, after.lots.first?.id)
        XCTAssertEqual(f.model.records.first?.phase, .completed)
    }
    func testReceiptTransferKeepsPhysicalIdentityAndOriginalObservationHistory() async throws {
        let f = try await fixture(received: true), before = try XCTUnwrap(f.pickup.journey)
        let intent = try prepare(f)
        let applied = await f.model.apply(); XCTAssertTrue(applied, f.model.message ?? "")
        let after = try await snapshot(f), journey = try XCTUnwrap(f.pickup.journey)
        XCTAssertEqual(after.lots.count, 1); XCTAssertTrue(journey.stockLots.isEmpty)
        XCTAssertEqual(journey.pickup?.receipts, before.pickup?.receipts)
        XCTAssertEqual(journey.pickup?.usableObservations, before.pickup?.usableObservations,
            "The canonical recount never changes original receipt or usable facts.")
        let target = try PantryLegacyMigration.claimIdentity(originID: f.inventory.workspaceID, needID: intent.plan.link.reservationID, foodID: f.food)
        XCTAssertEqual(after.reservations.first { $0.id == target }?.lotID, after.lots.first?.id)
        XCTAssertNotEqual(after.lots.first?.id, journey.pickup?.usableObservations.last?.id)
    }
}
