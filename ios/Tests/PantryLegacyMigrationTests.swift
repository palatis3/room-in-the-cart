import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryLegacyMigrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64) -> Quantity { .init(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }

    private struct Fixture {
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
        return Fixture(cleanup: cleanup, pickup: pickup, ledger: ledger, food: food, meal: meal, receipt: receipt, observation: observation)
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
        let reversed = try PantryLegacyMigration.map(originID: snapshot.workspaceID,
            heads: snapshot.records.reversed().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        XCTAssertEqual(conflict, reversed)
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
        XCTAssertThrowsError(try PantryLegacyMigration.map(originID: snapshot.workspaceID, heads: [head, head], ledger: .unavailable, at: now)) {
            XCTAssertEqual($0 as? PantryLegacyMigration.Failure, .duplicateSource)
        }
        XCTAssertThrowsError(try PantryLegacyMigration.map(originID: snapshot.workspaceID, heads: [head], ledger: .unavailable,
            at: Date(timeIntervalSinceReferenceDate: .infinity))) {
            XCTAssertEqual($0 as? PantryLegacyMigration.Failure, .invalidClock)
        }
    }
}
