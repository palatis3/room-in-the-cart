import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryMigrationPackageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64) -> Quantity { .init(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }

    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let databaseURL: URL
        let store: ComparisonStore
        let pickup: PickupModel
        let ledger: LedgerModel
        let food: UUID
        let meal: UUID
        let receipt: ReceiptFragment
        let observation: UsableObservation
    }

    /// Production ledger/checkout/pickup commands create and save this fixture.
    /// The mapper always receives bytes returned by the real SQLite snapshot API.
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let pickup = PickupModel(store: store, clock: { instant })
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
        return Fixture(cleanup: cleanup, databaseURL: directory.appendingPathComponent("pickup.sqlite"), store: store, pickup: pickup, ledger: ledger, food: food, meal: meal, receipt: receipt, observation: observation)
    }

    private func context(_ fixture: Fixture) throws -> PantryLegacyMigration.LedgerContext {
        .available(originID: try XCTUnwrap(fixture.ledger.sourceWorkspaceID), revision: fixture.ledger.revision,
            workspace: fixture.ledger.workspace)
    }
    private func mapped(_ fixture: Fixture, ledger: PantryLegacyMigration.LedgerContext? = nil) async throws -> PantryLegacyMigration.Plan {
        let snapshot = try await fixture.pickup.archiveSnapshot()
        return try PantryLegacyMigration.map(originID: snapshot.workspaceID,
            heads: snapshot.records.map(PantryLegacyMigration.SourceHead.init), ledger: ledger ?? context(fixture), at: now)
    }

    private func package(_ plan: PantryLegacyMigration.Plan, store: ComparisonStore,
                         id: UUID = UUID()) async throws -> PantryMigrationPackage.Package {
        let token = try await store.inventorySourceToken(), state = try await store.inventoryState()
        return try PantryMigrationPackage.build(plan, migrationID: id, sourceToken: token,
            inventoryRevision: state.revision, at: now)
    }
    private func activate(_ package: PantryMigrationPackage.Package, in store: ComparisonStore) async throws -> LocalStore.InventoryOperationReceipt {
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        return try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
    }
    private func persistedProvenance(_ package: PantryMigrationPackage.Package, store: ComparisonStore) async throws -> [PantryMigrationPackage.Envelope] {
        var rows: [InventoryRecord] = [], cursor: UUID?
        while true {
            let page = try await store.inventoryRecords(kind: .intent, after: cursor, limit: InventoryPersistenceLimits.pageItems)
            rows += page
            if page.count < InventoryPersistenceLimits.pageItems { break }
            cursor = page.last?.key.id
        }
        let expected = package.chunks.flatMap(\.records).filter { $0.key.kind == .intent }.sorted { $0.key.id.uuidString < $1.key.id.uuidString }
        XCTAssertEqual(rows, expected)
        return try rows.map {
            try PantryMigrationPackage.provenance($0, migrationID: package.plan.migrationID, originID: package.plan.workspaceID)
        }
    }

    func testCorrectedReceiptStagesOneBaselineAndPreservesHistoryAndRetry() async throws {
        let f = try await fixture()
        let correction = UsableObservation(id: UUID(), receipt: f.receipt.key, usable: q(3), confirmedAt: now,
            supersedesID: f.observation.id, confirmedMatchToOrderLine: true)
        let saved = await f.pickup.confirmUsable(correction); XCTAssertTrue(saved)
        let original = try await mapped(f), package = try await package(original, store: f.store)
        let before = try await f.pickup.archiveSnapshot()
        let receipt = try await activate(package, in: f.store)
        let repository = PantryRepository(store: f.store, authorize: { true })
        let loaded = try await repository.load(at: now)
        let lot = try XCTUnwrap(loaded.lots.first)
        XCTAssertEqual(lot.count.quantity, q(3)); XCTAssertEqual(lot.revision, 1)
        XCTAssertNotEqual(lot.observationID, original.lots.first?.observationID)
        let live = try await f.store.inventoryRecords(kind: .observation)
        XCTAssertEqual(live.count, 1)
        let baseline = try PantryPersistenceCodec.observation(XCTUnwrap(live.first))
        XCTAssertEqual(baseline.revision, 1); XCTAssertNil(baseline.supersedesID)
        let lineage = try await persistedProvenance(package, store: f.store)
        let histories: [InventoryObservation] = lineage.compactMap {
            if case .originalObservation(let value, let baselineID) = $0.body {
                XCTAssertEqual(baselineID, baseline.id); return value
            }; return nil
        }
        XCTAssertEqual(Set(histories.map(\.id)), Set(original.observations.map(\.id)))
        for value in histories { XCTAssertEqual(value, original.observations.first { $0.id == value.id }) }
        XCTAssertEqual(histories.count, 2)
        let links = lineage.compactMap { envelope -> PantryLegacyMigration.ObservationLink? in
            if case .observationLink(let link, let baselineID) = envelope.body {
                XCTAssertEqual(baselineID, baseline.id); return link
            }; return nil
        }
        XCTAssertEqual(Set(links.map(\.legacyObservationID)), [f.observation.id, correction.id])
        let after = try await f.pickup.archiveSnapshot()
        XCTAssertEqual(before.records.map(\.payload), after.records.map(\.payload))
        XCTAssertEqual(loaded.reservations, original.reservations.sorted { $0.id.uuidString < $1.id.uuidString })
        let command = InventoryCommand(id: UUID(), originID: original.originID, lotID: lot.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: now, change: .count(.someLeft, observationID: UUID()))
        _ = try await repository.apply(command, reviewedInventoryRevision: loaded.state.revision, at: now)
        _ = try await f.store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await f.store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        let retried = try await f.store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        XCTAssertEqual(retried, receipt)
        let current = try await repository.load(at: now)
        XCTAssertEqual(current.lots.first?.count, .someLeft, "Replay must not restore the imported count.")
    }

    func testConflictingCarriedManualCountsKeepHeldClaimsThroughActivation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let pickup = PickupModel(store: store, clock: { instant }); cleanup.track(pickup, store)
        let food = UUID()
        let added = await pickup.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: q(6),
            available: q(0), due: nil, confirmedAt: now)); XCTAssertTrue(added)
        let firstID = try XCTUnwrap(pickup.journey?.id)
        let stock = ConfirmedStockLot(id: UUID(), foodID: food, name: "Freezer wraps", usable: q(4), confirmedAt: now, source: .freezer)
        let stocked = await pickup.saveStockLot(stock, in: firstID); XCTAssertTrue(stocked)
        let next = await pickup.startNextShop(accept: []); XCTAssertTrue(next)
        let secondID = try XCTUnwrap(pickup.journey?.id)
        let copied = await pickup.saveStockLot(stock, in: secondID, carriedFrom: stock); XCTAssertTrue(copied)
        let changed = ConfirmedStockLot(id: stock.id, foodID: food, name: stock.name, usable: q(3), confirmedAt: now, source: .freezer)
        let corrected = await pickup.saveStockLot(changed, in: secondID, replacing: stock); XCTAssertTrue(corrected)
        let snapshot = try await pickup.archiveSnapshot()
        let original = try PantryLegacyMigration.map(originID: snapshot.workspaceID,
            heads: snapshot.records.map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let packed = try await package(original, store: store)
        _ = try await activate(packed, in: store)
        let loaded = try await PantryRepository(store: store, authorize: { true }).load(at: now)
        XCTAssertEqual(loaded.lots.first { $0.source == .manual(originID: snapshot.workspaceID, sourceID: stock.id) }?.count, .unknown)
        XCTAssertEqual(loaded.reservations.count, 1); XCTAssertEqual(loaded.reservations.first?.state, .unresolved)
        XCTAssertNil(loaded.reservations.first?.amount)
        XCTAssertTrue(loaded.availability.lots.allSatisfy { $0.free == nil })
        let values = try await persistedProvenance(packed, store: store)
        XCTAssertTrue(values.contains { if case .issue(let issue) = $0.body { return issue.kind == .ambiguousManualCount }; return false })
        XCTAssertEqual(values.filter { if case .claimLink = $0.body { return true }; return false }.count, 2)
    }

    func testDeterministicBoundedChunksAndStructuralAndReadBudgetRejections() async throws {
        let f = try await fixture()
        let extra = (0..<100).map { index in ConfirmedStockLot(id: UUID(), foodID: UUID(), name: "Pantry \(index)",
            usable: q(1), confirmedAt: now, source: .freezer) }
        let saved = await f.pickup.change { $0.stockLots += extra }; XCTAssertTrue(saved)
        let original = try await mapped(f), id = UUID(), token = try await f.store.inventorySourceToken()
        let first = try PantryMigrationPackage.build(original, migrationID: id, sourceToken: token, inventoryRevision: 0, at: now)
        let second = try PantryMigrationPackage.build(original, migrationID: id, sourceToken: token, inventoryRevision: 0, at: now)
        XCTAssertEqual(first, second); XCTAssertGreaterThan(first.chunks.count, 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for chunk in first.chunks {
            XCTAssertLessThanOrEqual(chunk.records.count, InventoryPersistenceLimits.batchItems)
            XCTAssertLessThanOrEqual(try encoder.encode(chunk).count, InventoryPersistenceLimits.batchBytes)
            for record in chunk.records { XCTAssertLessThanOrEqual(record.payload.count, InventoryPersistenceLimits.recordBytes) }
        }
        XCTAssertThrowsError(try PantryMigrationPackage.build(original, migrationID: id, sourceToken: token,
            inventoryRevision: 0, at: now, readLimits: .init(payloadBytes: 1, observations: 1))) {
            XCTAssertEqual($0 as? PantryMigrationPackage.Failure, .capacity)
        }
        let row = try XCTUnwrap(first.chunks.flatMap(\.records).first { $0.key.kind == .intent })
        XCTAssertThrowsError(try PantryMigrationPackage.provenance(row, migrationID: id, originID: UUID()))
        let wrongKey = InventoryRecord(key: .init(.intent, UUID()), revision: 1, payload: row.payload)
        XCTAssertThrowsError(try PantryMigrationPackage.provenance(wrongKey, migrationID: id, originID: original.originID))
        let wrongMetadata = InventoryRecord(key: row.key, revision: 1, payload: row.payload, lotID: UUID())
        XCTAssertThrowsError(try PantryMigrationPackage.provenance(wrongMetadata, migrationID: id, originID: original.originID))
        _ = try await activate(first, in: f.store)
        let current = try await PantryRepository(store: f.store, authorize: { true }).load(at: now)
        XCTAssertEqual(current.lots.count, original.lots.count)
    }

    func testOversizedRealReceiptReferenceFailsWithoutTruncatingHistory() async throws {
        let f = try await fixture()
        let instant = now, key = f.receipt.key, amount = q(3)
        let saved = await f.pickup.change { journey in
            var received = try XCTUnwrap(journey.pickup), predecessor = f.observation.id
            for _ in 0..<1_700 {
                let next = UsableObservation(id: UUID(), receipt: key, usable: amount, confirmedAt: instant,
                    supersedesID: predecessor, confirmedMatchToOrderLine: true)
                try received.confirmUsable(next); predecessor = next.id
            }
            journey.pickup = received
        }
        XCTAssertTrue(saved, f.pickup.error ?? "")
        let original = try await mapped(f), token = try await f.store.inventorySourceToken()
        XCTAssertEqual(original.observations.count, 1_701)
        XCTAssertThrowsError(try PantryMigrationPackage.build(original, migrationID: UUID(), sourceToken: token,
            inventoryRevision: 0, at: now)) { XCTAssertEqual($0 as? PantryMigrationPackage.Failure, .capacity) }
        let state = try await f.store.inventoryState(); XCTAssertFalse(state.active)
        let snapshot = try await f.pickup.archiveSnapshot()
        XCTAssertEqual(snapshot.records.first?.payload, original.sourceHeads.first?.payload)
    }

    private func carryover(_ f: Fixture) throws -> DinnerAwayCarryoverModel {
        let origin = try XCTUnwrap(f.ledger.sourceWorkspaceID), instant = now
        let dinner = DinnerFeatureModel(store: f.ledger, access: { id in
            .init(scope: .local(workspaceID: origin), actorID: "local", shopID: id, assignedShopperID: "local",
                canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 0,
                verifiedAt: instant.addingTimeInterval(-60), validUntil: instant.addingTimeInterval(3600))
        }, phase: { _ in .reportedPlaced }, clock: { instant })
        let coordinator = DinnerAwayCarryoverModel(dinner: dinner, pickup: f.pickup, clock: { instant })
        let need = try XCTUnwrap(f.pickup.journey?.needs.first { $0.priority == .required })
        XCTAssertTrue(coordinator.prepare(id: UUID(), occurrenceID: f.meal, needID: need.id,
            supply: .received(f.receipt, f.observation), counted: q(8), reserved: q(2), servings: .one,
            day: try MealDay(date: now.addingTimeInterval(86400), timeZoneIdentifier: "America/New_York"), observedAt: now))
        return coordinator
    }

    func testAllCarryoverPhasesPreserveCompleteLineageAndExactPins() async throws {
        for phase in [AwayCarryoverRecord.Phase.prepared, .reserved, .completed, .cancelled] {
            let f = try await fixture(), coordinator = try carryover(f)
            let intent = try XCTUnwrap(coordinator.review)
            switch phase {
            case .prepared, .cancelled:
                let saved = await f.pickup.change { $0.awayCarryovers.append(.init(intent: intent, phase: phase)) }; XCTAssertTrue(saved)
            case .reserved:
                let saved = await f.pickup.change { $0 = try AwayCarryoverEngine.reserving(intent, in: $0, at: self.now) }; XCTAssertTrue(saved)
            case .completed:
                let saved = await coordinator.apply(); XCTAssertTrue(saved, coordinator.message ?? "")
            }
            let original = try await mapped(f), packed = try await package(original, store: f.store)
            _ = try await activate(packed, in: f.store)
            let loaded = try await PantryRepository(store: f.store, authorize: { true }).load(at: now)
            let persisted = try await persistedProvenance(packed, store: f.store)
            let archived = persisted.compactMap { envelope -> PantryLegacyMigration.PendingLineage? in
                if case .pending(let value) = envelope.body { return value }; return nil
            }
            XCTAssertEqual(archived, original.pendingLineage)
            let pending = try XCTUnwrap(archived.first)
            XCTAssertEqual(pending.record.phase, phase); XCTAssertEqual(pending.record.intent, intent)
            if phase != .cancelled {
                let claim = try XCTUnwrap(loaded.reservations.first { $0.id == pending.reservationID })
                XCTAssertEqual(claim.lotID, loaded.lots.first?.id)
                XCTAssertEqual(claim.state, phase == .prepared ? .unresolved : .active)
            }
        }
    }


    func testCapturedPreparationContextRebuildsIdenticalPackageAfterSourceReopen() async throws {
        let f = try await fixture()
        let observation = UsableObservation(id: UUID(), receipt: f.receipt.key, usable: q(3), confirmedAt: now,
            supersedesID: f.observation.id, confirmedMatchToOrderLine: false)
        let saved = await f.pickup.confirmUsable(observation); XCTAssertTrue(saved)
        let snapshot = try await f.store.inventoryCutoverSnapshot()
        let ledger = try context(f), preparedAt = now, migrationID = UUID()
        let original = try PantryLegacyMigration.map(originID: snapshot.token.workspaceID,
            heads: snapshot.sources.map(PantryLegacyMigration.SourceHead.init), ledger: ledger, at: preparedAt)
        XCTAssertEqual(original.lots.first?.count, .unknown)
        let first = try PantryMigrationPackage.build(original, migrationID: migrationID,
            sourceToken: snapshot.token, inventoryRevision: 0, at: preparedAt)
        XCTAssertThrowsError(try PantryMigrationPackage.build(original, migrationID: migrationID,
            sourceToken: snapshot.token, inventoryRevision: 0, at: preparedAt.addingTimeInterval(60))) {
            XCTAssertEqual($0 as? PantryMigrationPackage.Failure, .invalidPlan)
        }
        let storedContext = try JSONDecoder().decode(PantryMigrationPackage.Context.self, from: first.plan.reviewContext)
        XCTAssertEqual(storedContext.preparedAt, preparedAt)
        XCTAssertEqual(storedContext.sourceToken, snapshot.token)
        XCTAssertEqual(storedContext.ledgerOriginID, original.ledgerOriginID)
        XCTAssertEqual(storedContext.ledgerRevision, original.ledgerRevision)
        let archivedContexts = try first.chunks.flatMap(\.records).filter { $0.key.kind == .intent }.compactMap { record -> PantryMigrationPackage.Context? in
            let envelope = try PantryMigrationPackage.provenance(record, migrationID: migrationID, originID: original.originID)
            if case .context(let value) = envelope.body { return value }; return nil
        }
        XCTAssertEqual(archivedContexts, [storedContext])
        _ = try await f.store.beginInventoryMigration(first.plan)
        try await f.store.close()
        let reopened = try ComparisonStore(url: f.databaseURL, inventoryEnabled: true)
        f.cleanup.track(reopened)
        let progress = try await reopened.inventoryMigrationProgress(id: migrationID)
        let persistedPlan = try XCTUnwrap(progress?.plan)
        let recoveredContext = try JSONDecoder().decode(PantryMigrationPackage.Context.self, from: persistedPlan.reviewContext)
        // Use the persisted enumeration token, never a new token for the previously mapped plan.
        let heads = try await reopened.inventorySourcePage(token: recoveredContext.sourceToken)
        XCTAssertEqual(heads.map(\.payload), snapshot.sources.map(\.payload))
        let remapped = try PantryLegacyMigration.map(originID: snapshot.token.workspaceID,
            heads: heads.map(PantryLegacyMigration.SourceHead.init), ledger: ledger, at: recoveredContext.preparedAt)
        let rebuilt = try PantryMigrationPackage.build(remapped, migrationID: persistedPlan.migrationID,
            sourceToken: recoveredContext.sourceToken, inventoryRevision: persistedPlan.expectedRevision, at: recoveredContext.preparedAt)
        XCTAssertEqual(remapped, original)
        XCTAssertEqual(rebuilt, first)
        let newClockMapping = try PantryLegacyMigration.map(originID: snapshot.token.workspaceID,
            heads: heads.map(PantryLegacyMigration.SourceHead.init), ledger: ledger, at: preparedAt.addingTimeInterval(60))
        XCTAssertNotEqual(newClockMapping, original, "A restart clock must not replace the captured preparation time.")
        _ = try await activate(rebuilt, in: reopened)
        let current = try await PantryRepository(store: reopened, authorize: { true }).load(at: preparedAt.addingTimeInterval(60))
        XCTAssertEqual(current.lots.first?.count, .unknown)
        try await reopened.close()
    }
}
