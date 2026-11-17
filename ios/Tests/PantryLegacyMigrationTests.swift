import XCTest
import CryptoKit
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class PantryLegacyMigrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64) -> Quantity { .init(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }

    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
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
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        cleanup.track(ledger, pickup)
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
        return Fixture(directory: directory, cleanup: cleanup, pickup: pickup, ledger: ledger, food: food, meal: meal, receipt: receipt, observation: observation)
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

    func testErasureScanFindsHistoricalPackProofAndKeepsCollateralReceiptAndPin() async throws {
        let f = try await fixture()
        let store = try ComparisonStore(url: f.directory.appendingPathComponent("erasure.sqlite"), inventoryEnabled: true)
        let repository = PantryRepository(store: store, authorize: { true })
        f.cleanup.track(store, repository)
        let origin = store.workspaceID, operation = UUID()
        let current = try XCTUnwrap(f.pickup.journey), shop = try XCTUnwrap(f.ledger.shop)
        let standalone = try InventoryEngine.prepare(.init(id: operation, originID: origin, lotID: UUID(), eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: f.food, name: "Separate freezer wraps",
                source: .manual(originID: origin, sourceID: UUID()), location: .freezer, unit: .count,
                count: .exact(q(6))), observationID: UUID())), current: nil, at: now)
        let lot = standalone.lot
        let needs = current.rawPhysicalStockNeeds.filter { $0.foodID == f.food && $0.amount.amount > .zero }
        let claims = needs.map { InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: f.food,
            lotID: lot.id, name: $0.name, amount: $0.amount, priority: $0.priority) }
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: f.food)
        let proof = try LedgerCanonicalPackStockEvidence.review(
            scope: .init(journeyID: shop.id, journeyRevision: current.revision,
                basketRevisionID: XCTUnwrap(current.basket?.current.id), shopRevisionID: shop.revisionID, lineID: f.food),
            basis: .init(originID: origin, inventoryRevision: 1, sourceHeads: [.init(journeyID: shop.id, revision: 1)]),
            requirement: requirement, claimBindings: zip(needs, claims).map { .init(need: $0.0, reservationID: $0.1.id) },
            canonicalLots: [lot], canonicalReservations: claims,
            projection: InventoryProjection.build(originID: origin, lots: [lot], reservations: claims, at: now),
            eligibility: [.init(lotID: lot.id, source: lot.source, observationID: lot.observationID,
                status: .eligible, receiptEvidenceDigest: nil)])
        let originalPack = try XCTUnwrap(current.ledgerPackSelections.first)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
            confirmedAtHome: try proof.confirmedQuantity(for: requirement), protectedAmount: requirement.protectedQuantity,
            offerA: originalPack.request.offerA, offerB: originalPack.request.offerB)
        let pack = try LedgerPackSelection(workspaceID: originalPack.sourceWorkspaceID, shop: shop,
            lineID: f.food, request: request, selectedOfferID: originalPack.selectedOfferID, at: now,
            source: "Saved shelf review", canonicalStockEvidence: proof)
        XCTAssertEqual(pack.formatVersion, 3)
        var old = current
        old.ledgerPackSelections = [pack]
        try PickupModel.validate(old)
        let historical = try await store.save(id: shop.id, title: shop.title, payload: JSONEncoder().encode(old), savedAt: now)
        let head = try await store.save(id: shop.id, title: shop.title, payload: JSONEncoder().encode(current), savedAt: now)
        let mapping = try PantryLegacyMigration.map(originID: origin, heads: [.init(head)], ledger: .unavailable, at: now)
        let receipt = try XCTUnwrap(mapping.lots.first)
        let received = try InventoryEngine.prepare(.init(id: operation, originID: origin, lotID: receipt.id, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: receipt.foodID, name: receipt.name,
                source: receipt.source, location: receipt.location, unit: receipt.unit, count: receipt.count),
                observationID: receipt.observationID)), current: nil, at: now)
        let pin = InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: f.food, lotID: receipt.id,
            name: "Saved for another lunch", amount: q(2), priority: .protected)
        let pinRow = InventoryRecord(key: .init(.reservation, pin.id), revision: pin.revision,
            payload: try JSONEncoder().encode(pin), lotID: pin.lotID)
        let token = try await store.inventorySourceToken()
        var writes = try PantryPersistenceCodec.writes(standalone)
        writes += try PantryPersistenceCodec.writes(received)
        writes.append(.init(record: pinRow, expectedRevision: 0))
        _ = try await store.commitInventory(.init(workspaceID: origin, operationID: operation, expectedRevision: 0,
            request: Data(operation.uuidString.utf8), mode: .activate, sourceToken: token, writes: writes), at: now)
        let snapshot = try await repository.load(at: now)
        let context = try PantryErasureDependencies.Context(snapshot: snapshot, mapping: mapping, sourceToken: token, at: now)
        let selected = PantryErasureDependencies.Selection.lot(lot.id, revision: lot.revision)
        let preview = try await PantryErasureDependencies.scan(store: store, selection: selected, context: context, authorize: { true })

        let historicalProof = try XCTUnwrap(preview.inspections.first { $0.container == .pickup(shop.id, revision: historical.revision) })
        XCTAssertTrue(historicalProof.matches.contains(.init(subject: .lot(lot.id), role: .incidentalCopy)))
        XCTAssertEqual(historicalProof.sourceFactLotIDs, [receipt.id])
        XCTAssertFalse(preview.inspections.contains { $0.container == .pickup(shop.id, revision: head.revision) })
        XCTAssertTrue(preview.sqlDependenciesVerified)
        XCTAssertEqual(preview.collateralPickupIDs, [shop.id])
        XCTAssertTrue(preview.needsExpandedReview)
        XCTAssertEqual(preview.explicitlySelectedLotIDs, [lot.id])
        XCTAssertEqual(preview.retainedReceiptLotIDsInCollateralPickups, [receipt.id])
        XCTAssertEqual(preview.retainedPhysicalLotIDs, [receipt.id])
        XCTAssertEqual(preview.retainedReservations, [pin])
        let pickupSelection = PantryErasureDependencies.Selection.pickup(shop.id, revision: head.revision,
            payloadDigest: Data(SHA256.hash(data: head.payload)))
        let pickupPreview = try await PantryErasureDependencies.scan(store: store, selection: pickupSelection,
            context: context, authorize: { true })
        XCTAssertEqual(pickupPreview.pickupSourceCandidateLotIDs, [receipt.id])
        XCTAssertTrue(pickupPreview.explicitlySelectedLotIDs.isEmpty)
        XCTAssertEqual(pickupPreview.retainedPhysicalLotIDs, [receipt.id, lot.id])
        XCTAssertEqual(pickupPreview.retainedReservations, [pin])
        let after = try await repository.load(at: now)
        XCTAssertEqual(after.state, snapshot.state)
        XCTAssertEqual(after.lots, snapshot.lots)
        XCTAssertEqual(after.reservations, snapshot.reservations)

        let paired = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(paired)
        let coordinator = PantryErasureCoordinator(inventory: store, ledger: paired, gate: PantryMutationGate(),
            pendingDirectory: f.directory.appendingPathComponent("pending"),
            registry: try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json")),
            worker: try PantryArchiveWorker(root: f.directory.appendingPathComponent("archives")),
            journalDirectory: f.directory.appendingPathComponent("privacy"),
            cleanup: { _, _ in XCTFail("Unreviewed collateral reached cleanup") }, authorize: { true }, clock: { self.now })
        let impact = try await coordinator.prepare(selected)
        XCTAssertEqual(impact.blockers, [.collateralPickups]); XCTAssertFalse(impact.canCommit)
        XCTAssertEqual(impact.collateralPickupIDs, [shop.id])
        XCTAssertEqual(impact.retainedReceiptFoodNames, [receipt.name]); XCTAssertEqual(impact.foodNames, [lot.name])
        do { _ = try await coordinator.commit(impact); XCTFail("Historical contact is insufficient authorization") }
        catch PantryErasureCoordinator.Failure.blocked { }
        let untouched = try await repository.load(at: now); XCTAssertEqual(untouched.state, snapshot.state)

        let future = InventoryRecord(key: .init(.intent, UUID()), revision: 1,
            payload: Data(#"{"namespace":"pantry-future/v2","privateEvidence":"opaque"}"#.utf8))
        _ = try await store.commitInventory(.init(workspaceID: origin, operationID: UUID(),
            expectedRevision: snapshot.state.revision, request: Data("add future intent".utf8),
            writes: [.init(record: future, expectedRevision: 0)]), at: now)
        let updated = try await repository.load(at: now)
        let updatedContext = try PantryErasureDependencies.Context(snapshot: updated, mapping: mapping,
            sourceToken: await store.inventorySourceToken(), at: now)
        let blocked = try await PantryErasureDependencies.scan(store: store, selection: selected,
            context: updatedContext, authorize: { true })
        XCTAssertTrue(blocked.sqlHistoriesComplete)
        XCTAssertFalse(blocked.sqlDependenciesVerified)
        XCTAssertEqual(blocked.unresolvedSQLReasons, [.unknownNamespace])
        XCTAssertEqual(blocked.remainingScopes, [.externalCopiesNotScanned])
        XCTAssertEqual(blocked.retainedReservations, [pin])

        // After a reviewed whole-origin retirement, even a foreign pickup or
        // ledger wrapper cannot make the old pack proof independent.
        _ = try await store.eraseInventoryOrigin(expectedRevision: updated.state.revision, sourceToken: updatedContext.sourceToken,
            operationID: UUID(), at: now)
        let replacement = try ComparisonStore(url: f.directory.appendingPathComponent("replacement.sqlite"), inventoryEnabled: true)
        f.cleanup.track(replacement)
        let foreignPickupOrigin = "pickups/" + UUID().uuidString
        func archive(_ bytes: Data, origin: String, kind: ArchiveRecordKind) -> ArchiveRecord {
            .init(id: shop.id.uuidString, origin: origin, revision: ArchiveCodec.digest(bytes), kind: kind,
                title: shop.title, savedAtMilliseconds: 1_800_000_000_000, nativePayload: bytes)
        }
        struct LedgerDocument: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
        var ledgerWithProof = f.ledger.workspace
        ledgerWithProof.packSelections = [pack]
        let ordinaryPickup = archive(try RecordsNativeCodec.canonical(old), origin: foreignPickupOrigin, kind: .pickup)
        let ledgerOrigin = "ledger/" + paired.workspaceID.uuidString
        let ordinaryLedger = archive(try RecordsNativeCodec.canonical(LedgerDocument(workspace: ledgerWithProof)), origin: ledgerOrigin, kind: .ledger)
        for record in [ordinaryPickup, ordinaryLedger] {
            try RecordsNativeCodec.validate(record)
            do {
                try await PantryArchivePrivacyValidator.validate(record, inventory: replacement, ledger: paired, gate: PantryMutationGate(),
                    retiredOrigins: [origin], authorize: { true })
                XCTFail("Ordinary backup contained the retired origin's v3 pack proof")
            } catch PantryArchivePrivacyValidator.Failure.retired { }
        }
        let independent = archive(try RecordsNativeCodec.canonical(LedgerDocument(workspace: f.ledger.workspace)), origin: ledgerOrigin, kind: .ledger)
        try await PantryArchivePrivacyValidator.validate(independent, inventory: replacement, ledger: paired, gate: PantryMutationGate(),
            retiredOrigins: [origin], authorize: { true })

    }

    func testReceiptCorrectionKeepsOnePhysicalLotAndFullObservationSupersession() async throws {
        let f = try await fixture(), before = try await mapped(f)
        let corrected = UsableObservation(id: UUID(), receipt: f.receipt.key, usable: q(3), confirmedAt: now,
            supersedesID: f.observation.id, confirmedMatchToOrderLine: true)
        let saved = await f.pickup.confirmUsable(corrected); XCTAssertTrue(saved)
        let after = try await mapped(f)
        XCTAssertEqual(after.lots.count, 1)
        XCTAssertEqual(after.lots.first?.id, before.lots.first?.id)
        XCTAssertNotEqual(after.lots.first?.observationID, before.lots.first?.observationID)
        XCTAssertEqual(after.lots.first?.count.quantity, q(3))
        XCTAssertEqual(after.observations.count, 2)
        XCTAssertEqual(after.observations.last?.supersedesID, after.observations.first?.id)
        XCTAssertEqual(Set(after.observationLinks.map(\.legacyObservationID)), [f.observation.id, corrected.id])
        XCTAssertEqual(after.reservations.count, 2, "Planned and placed demands must not be duplicated.")
        let snapshot = try await f.pickup.archiveSnapshot()
        XCTAssertEqual(after.sourceHeads.first?.payload, snapshot.records.first?.payload)
        let again = try await mapped(f); XCTAssertEqual(after, again)
    }

    func testSecondReceiptSegmentIsNotDeduplicatedByNameOrQuantity() async throws {
        let f = try await fixture()
        let key = ReceiptKey(sourceEventID: f.receipt.key.sourceEventID, orderLineID: f.food, branchID: "Main", segmentID: "two")
        let fragment = ReceiptFragment(key: key, itemName: "Wraps", received: q(8), disposition: .received, receivedAt: now)
        let received = await f.pickup.receive(fragment, usable: .init(id: UUID(), receipt: key, usable: q(8),
            confirmedAt: now, confirmedMatchToOrderLine: true)); XCTAssertTrue(received)
        let result = try await mapped(f)
        XCTAssertEqual(result.lots.count, 2)
        XCTAssertEqual(Set(result.lots.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.lots.map(\.source)).count, 2)
    }

    func testCarriedManualSourceMergesButConflictingCountAndResidualClaimStayUnresolved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        cleanup.track(pickup)
        let food = UUID()
        let added = await pickup.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: q(6),
            available: q(0), due: nil, confirmedAt: now)); XCTAssertTrue(added)
        let firstID = try XCTUnwrap(pickup.journey?.id)
        let original = ConfirmedStockLot(id: UUID(), foodID: food, name: "Freezer wraps", usable: q(4), confirmedAt: now, source: .freezer)
        let stocked = await pickup.saveStockLot(original, in: firstID); XCTAssertTrue(stocked)
        let next = await pickup.startNextShop(accept: []); XCTAssertTrue(next)
        let secondID = try XCTUnwrap(pickup.journey?.id)
        let copied = await pickup.saveStockLot(original, in: secondID, carriedFrom: original); XCTAssertTrue(copied)
        var snapshot = try await pickup.archiveSnapshot()
        let merged = try PantryLegacyMigration.map(originID: snapshot.workspaceID,
            heads: snapshot.records.map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let source = InventorySource.manual(originID: snapshot.workspaceID, sourceID: original.id)
        XCTAssertEqual(merged.lots.filter { $0.source == source }.count, 1)
        XCTAssertEqual(merged.lots.first { $0.source == source }?.count.quantity, q(4))
        XCTAssertEqual(merged.reservations.count, 1)
        XCTAssertEqual(merged.reservations.first?.state, .unresolved, "Six original versus two carried shortfall is not two independent demands or a new smaller promise.")
        let changed = ConfirmedStockLot(id: original.id, foodID: food, name: original.name, usable: q(3), confirmedAt: now, source: .freezer)
        let corrected = await pickup.saveStockLot(changed, in: secondID, replacing: original); XCTAssertTrue(corrected)
        snapshot = try await pickup.archiveSnapshot()
        let conflict = try PantryLegacyMigration.map(originID: snapshot.workspaceID,
            heads: snapshot.records.map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        XCTAssertEqual(conflict.lots.first { $0.source == source }?.count, .unknown)
        XCTAssertTrue(conflict.issues.contains { $0.kind == .ambiguousManualCount })
        let projection = try InventoryProjection.build(originID: conflict.originID, lots: conflict.lots,
            reservations: conflict.reservations, at: now)
        XCTAssertTrue(projection.lots.allSatisfy { $0.free == nil })
        let reversed = try PantryLegacyMigration.mapWithJourneys(originID: snapshot.workspaceID,
            heads: snapshot.records.reversed().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        XCTAssertEqual(conflict, reversed.plan)
        let expectedJourneys = try snapshot.records.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            try JSONDecoder().decode(PickupJourney.self, from: $0.payload)
        }
        XCTAssertEqual(reversed.journeys, expectedJourneys)
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

    func testEveryCarryoverPhaseRetainsExactPinAndPendingLedgerLineage() async throws {
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
            let result = try await mapped(f)
            let lineage = try XCTUnwrap(result.pendingLineage.first)
            XCTAssertEqual(lineage.record.phase, phase)
            XCTAssertEqual(lineage.record.intent, intent)
            XCTAssertEqual(result.lots.count, 1)
            if phase == .cancelled {
                XCTAssertEqual(lineage.ledgerDisposition, .cancelled)
                XCTAssertFalse(result.reservations.contains { $0.id == lineage.reservationID })
            } else {
                let reservation = try XCTUnwrap(result.reservations.first { $0.id == lineage.reservationID })
                XCTAssertEqual(reservation.lotID, result.lots.first?.id)
                XCTAssertEqual(reservation.amount, q(2))
                XCTAssertEqual(reservation.state, phase == .prepared ? .unresolved : .active)
                XCTAssertEqual(lineage.ledgerDisposition, phase == .completed ? .applied : .pendingProjection)
                let missingLedger = try await mapped(f, ledger: .unavailable)
                XCTAssertEqual(missingLedger.reservations.first { $0.id == lineage.reservationID }?.state, .unresolved)
                XCTAssertEqual(missingLedger.pendingLineage.first?.ledgerDisposition, .needsReview)
            }
        }
    }

    func testEffectiveRecoveryDemandsReplaceRawOriginalInsteadOfAddingBoth() async throws {
        let f = try await fixture()
        let original = try XCTUnwrap(f.pickup.recoveryDefinitions().first { $0.meal.id == f.meal })
        let food = UUID(), replacementNeed = StockNeed(id: UUID(), foodID: food, name: "Beans dinner", amount: q(3), priority: .required)
        let stocked = await f.pickup.change { $0.stockLots.append(.init(id: UUID(), foodID: food, name: "Beans", usable: self.q(4), confirmedAt: self.now, source: .freezer)) }
        XCTAssertTrue(stocked)
        let authority = PickupRecoveryAuthority(presentation: .init(workspaceID: f.pickup.sourceWorkspaceID,
            localActorID: UUID(), workspaceUnlocked: true, sceneActive: true, childPresented: false,
            guardianChildOnly: false, accountSubject: nil, householdLocked: false, projection: nil),
            ledgerWorkspaceID: try XCTUnwrap(f.ledger.sourceWorkspaceID), ledgerRevisionID: try XCTUnwrap(f.ledger.shop?.revisionID),
            selectedPickupID: try XCTUnwrap(f.pickup.journey?.id), leaseID: UUID())
        let due = now.addingTimeInterval(2700)
        let replacement = RecoveryMeal(id: original.meal.id, revisionID: UUID(), templateID: nil, templateVersion: nil,
            title: "Beans dinner", servings: original.meal.servings,
            ingredients: [.init(ingredientID: UUID(), groupID: nil, foodName: "Beans", need: replacementNeed)],
            scheduledDay: original.meal.scheduledDay, due: due, timeZoneID: original.meal.timeZoneID,
            exclusions: original.meal.exclusions, remainingElapsedMinutes: 15, requiredLeadMinutes: nil, advanceStepsCompleted: false)
        let review = try f.pickup.prepareMealRecovery(definition: .init(meal: replacement, groups: original.groups,
            notes: "Warm beans", sourceURL: nil, ingredientRules: [.init(needID: replacementNeed.id, notes: "", exclusions: [])],
            acceptedTemplate: nil), operationID: UUID(), confirmedUnknownDeadline: original.meal.due == nil ? due : nil,
            agreesToRepeat: false, proposesExtraTrip: false, agreesToExtraTrip: false, acceptsUnresolved: true, authority: authority)
        let saved = await f.pickup.applyMealRecovery(review, currentAuthority: { authority }); XCTAssertTrue(saved, f.pickup.error ?? "")
        let result = try await mapped(f)
        XCTAssertTrue(result.claimLinks.contains { $0.legacyNeedID == replacementNeed.id })
        XCTAssertFalse(result.claimLinks.contains { original.meal.needs.map(\.id).contains($0.legacyNeedID) })
        XCTAssertEqual(result.reservations.count, 2, "Replacement dinner plus protected lunch, not the original dinner too.")
    }

    func testMalformedOrDuplicateSourceSetDoesNotReturnPartialMigration() async throws {
        let f = try await fixture(), snapshot = try await f.pickup.archiveSnapshot()
        let head = PantryLegacyMigration.SourceHead(try XCTUnwrap(snapshot.records.first))
        let original = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
        var futureVersion = original
        futureVersion.version = original.version + 1
        var prematureFeedback = original
        prematureFeedback.closedAt = nil
        prematureFeedback.feedback = PickupFeedback(decision: .unchanged, baseline: .list, comparison: .same)
        for invalid in [futureVersion, prematureFeedback] {
            let badHead = PantryLegacyMigration.SourceHead(id: head.id, revision: head.revision,
                payload: try JSONEncoder().encode(invalid), savedAt: head.savedAt)
            XCTAssertThrowsError(try PickupModel.validate(invalid))
            XCTAssertThrowsError(try PantryLegacyMigration.mapWithJourneys(originID: snapshot.workspaceID,
                heads: [badHead], ledger: .unavailable, at: now))
        }
        XCTAssertThrowsError(try PantryLegacyMigration.map(originID: snapshot.workspaceID, heads: [head, head], ledger: .unavailable, at: now)) {
            XCTAssertEqual($0 as? PantryLegacyMigration.Failure, .duplicateSource)
        }
        XCTAssertThrowsError(try PantryLegacyMigration.map(originID: snapshot.workspaceID, heads: [head], ledger: .unavailable,
            at: Date(timeIntervalSinceReferenceDate: .infinity))) {
            XCTAssertEqual($0 as? PantryLegacyMigration.Failure, .invalidClock)
        }
    }
}
