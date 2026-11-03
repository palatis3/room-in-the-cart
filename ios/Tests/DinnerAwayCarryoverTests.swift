import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor private final class CarryoverLedgerStore: DinnerWorkspaceStore {
    let disk: LedgerStore
    var workspace = LedgerWorkspace()
    var sourceWorkspaceID: UUID? { disk.workspaceID }
    var ready = true
    var saving = false
    var hasPendingSave = false
    var revision: Int64 = 0
    var failNext = false
    var loseNextReceipt = false
    let now: Date
    init(url: URL, now: Date) async throws {
        disk = try LedgerStore(url: url); self.now = now
        if let value = try await disk.load() { workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: value.payload); revision = value.revision }
    }
    func change(key: String, _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        do {
            var next = workspace; try edit(&next); try next.validate()
            if failNext { failNext = false; return false }
            if next == workspace { return true }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let saved = try await disk.save(payload: encoder.encode(next), expectedRevision: revision, operationID: UUID(), savedAt: now)
            if loseNextReceipt { loseNextReceipt = false; return false }
            workspace = next; revision = saved.revision; return true
        } catch { return false }
    }
}

@MainActor final class DinnerAwayCarryoverTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { Quantity(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private struct Fixture {
        let directory: URL
        let ledger: CarryoverLedgerStore
        let dinner: DinnerFeatureModel
        let pickup: PickupModel
        let coordinator: DinnerAwayCarryoverModel
        let mealID: UUID
        let needID: UUID
        let lunchID: UUID
        let supply: AwayCarryoverSupply
    }
    private func model(_ ledger: CarryoverLedgerStore, pickup: PickupModel) -> DinnerFeatureModel {
        DinnerFeatureModel(store: ledger, access: { id in
            DinnerAccessContext(scope: .local(workspaceID: ledger.sourceWorkspaceID!), actorID: "local", shopID: id,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: false,
                roleRevision: 0, verifiedAt: self.now.addingTimeInterval(-60), validUntil: self.now.addingTimeInterval(3600))
        }, phase: { _ in .reportedPlaced }, clock: { self.now })
    }
    private func fixture(receivedSource: Bool = false) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = try await CarryoverLedgerStore(url: dir.appendingPathComponent("ledger.sqlite"), now: now)
        var shop = ShoppingLedger(title: "Purchased pickup", basis: ShopBasis(timeZoneIdentifier: "America/New_York"))
        let template = MealTemplate(title: "Wrap dinner", servings: try Rational(2), ingredients: [MealIngredient(name: "Wraps", quantity: q(4))])
        let mealID = try shop.chooseMeal(template, on: now.addingTimeInterval(-86400), at: now.addingTimeInterval(-86400))
        let meal = try XCTUnwrap(shop.mealOccurrences.first), needID = try XCTUnwrap(meal.ingredientContributionIDs.first)
        let source = try XCTUnwrap(shop.contributions.first { $0.id == needID })
        let lunchID = try shop.addProtectedNeed(name: "Wraps", quantity: q(2), purpose: "Protected lunch", at: now.addingTimeInterval(-86400))
        let saved = await ledger.change(key: "fixture") { $0 = LedgerWorkspace(shops: [shop], selectedShopID: shop.id) }
        XCTAssertTrue(saved)
        let pickup = PickupModel(databaseURL: dir.appendingPathComponent("pickup.sqlite"), clock: { self.now })
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "Evening", commitmentsID: shop.id, observedAt: now, source: "Shopper")
        let needs = [AllocationNeed(id: needID, orderLineID: source.lineID, name: "Wrap dinner", amount: q(4), priority: .required),
                     AllocationNeed(id: lunchID, orderLineID: source.lineID, name: "Protected lunch", amount: q(2), priority: .protected)]
        let details = [PickupNeedDetail(id: needID, mealName: meal.title, exclusions: [], scheduledDay: meal.scheduledDay, leadTimeMinutes: nil, completedSteps: [], sourceContributionID: needID),
                       PickupNeedDetail(id: lunchID, mealName: "Protected lunch", exclusions: [], scheduledDay: meal.scheduledDay, leadTimeMinutes: nil, completedSteps: [])]
        let started = await pickup.start(from: [BasketLine(id: source.lineID, name: "Wraps", quantity: q(6), expectedCost: .exact(Money(minorUnits: 700)))],
            shopID: shop.id, context: context, plannedNeeds: needs, ledgerBasis: shop.basis, ledgerSourceRevisionID: shop.revisionID, needDetails: details)
        XCTAssertTrue(started)
        let quote = await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 700)))), cap: nil)
        XCTAssertTrue(quote, pickup.error ?? "quote")
        let frozen = await pickup.freeze(); XCTAssertTrue(frozen, pickup.error ?? "freeze")
        let placed = await pickup.reportPlaced(); XCTAssertTrue(placed, pickup.error ?? "place")
        let key = ReceiptKey(sourceEventID: "actual-bag", orderLineID: source.lineID, branchID: "Branch", segmentID: "one")
        let receipt = ReceiptFragment(key: key, itemName: "Wraps", received: q(6), disposition: .received, receivedAt: now)
        let observation = UsableObservation(id: UUID(), receipt: key, usable: q(6), confirmedAt: now, confirmedMatchToOrderLine: true)
        let received = await pickup.receive(receipt, usable: receivedSource ? observation : nil); XCTAssertTrue(received)
        let charged = await pickup.settle(SettlementEntry(id: UUID(), evidenceKey: "posted", kind: .postedCharge, amount: Money(minorUnits: 700), occurredAt: now)); XCTAssertTrue(charged)
        let supply: AwayCarryoverSupply
        if receivedSource { supply = .received(receipt, observation) }
        else {
            let lot = ConfirmedStockLot(id: UUID(), foodID: source.lineID, name: "Existing freezer wraps", usable: q(6), confirmedAt: now, source: .freezer)
            let stocked = await pickup.saveStockLot(lot, in: shop.id); XCTAssertTrue(stocked); supply = .batch(lot)
        }
        let dinner = model(ledger, pickup: pickup)
        return Fixture(directory: dir, ledger: ledger, dinner: dinner, pickup: pickup,
            coordinator: DinnerAwayCarryoverModel(dinner: dinner, pickup: pickup, clock: { self.now }), mealID: mealID, needID: needID, lunchID: lunchID, supply: supply)
    }
    private func prepare(_ fixture: Fixture, counted: Int64 = 6, reserved: Int64 = 2, needID: UUID? = nil) throws -> Bool {
        fixture.coordinator.prepare(id: UUID(), occurrenceID: fixture.mealID, needID: needID ?? fixture.needID,
            supply: fixture.supply, counted: q(counted), reserved: q(reserved), servings: .one,
            day: try MealDay(date: now.addingTimeInterval(86400), timeZoneIdentifier: "America/New_York"), observedAt: now)
    }
    func testCancelBeforeApplyChangesNeitherPhysicalFoodNorCalendar() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let pickup = f.pickup.journey, workspace = f.ledger.workspace
        XCTAssertTrue(try prepare(f)); f.coordinator.cancelReview()
        XCTAssertEqual(f.pickup.journey, pickup); XCTAssertEqual(f.ledger.workspace, workspace)
        XCTAssertTrue(f.coordinator.records.isEmpty)
    }
    func testDatedTargetPinsPhysicalFoodOnceAndPreservesPurchaseAndProtectedLunch() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try XCTUnwrap(f.pickup.journey), sourceMeal = f.dinner.shop?.mealOccurrences.first { $0.id == f.mealID }
        XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review)
        let asyncResult1 = await f.coordinator.apply(); XCTAssertTrue(asyncResult1)
        let after = try XCTUnwrap(f.pickup.journey), target = try XCTUnwrap(f.dinner.shop?.mealOccurrences.first { $0.id == intent.plan.occurrenceID })
        XCTAssertEqual(target.carryover, intent.plan.link); XCTAssertEqual(target.scheduledDay, intent.plan.day)
        XCTAssertEqual(target.templateID, sourceMeal?.templateID); XCTAssertTrue(target.ingredientContributionIDs.isEmpty)
        XCTAssertEqual(f.dinner.shop?.mealOccurrences.first { $0.id == f.mealID }, sourceMeal)
        XCTAssertEqual(after.basket, before.basket); XCTAssertEqual(after.quote, before.quote); XCTAssertEqual(after.settlement, before.settlement)
        XCTAssertEqual(after.pickup, before.pickup); XCTAssertEqual(after.stockLots.count, before.stockLots.count)
        XCTAssertEqual(after.needs.first { $0.id == f.lunchID }, before.needs.first { $0.id == f.lunchID })
        XCTAssertEqual(after.needDetails.first { $0.id == f.lunchID }, before.needDetails.first { $0.id == f.lunchID })
        let allocation = try after.carryoverAllocation()
        XCTAssertEqual(allocation.demands.first { $0.id == f.lunchID }?.allocated, try Rational(2))
        XCTAssertEqual(allocation.demands.first { $0.id == intent.plan.link.reservationID }?.allocated, try Rational(2))
        XCTAssertEqual(allocation.allocations.filter { $0.needID == intent.plan.link.reservationID }.map(\.lotID), [f.supply.id])
        XCTAssertEqual(allocation.remainingLots.reduce(Rational.zero) { try! $0.adding($1.remainingUnallocated) }, .zero)
        let revision = f.pickup.journey?.revision, ledgerRevision = f.ledger.revision
        let asyncResult2 = await f.coordinator.retry(try XCTUnwrap(f.coordinator.records.first)); XCTAssertTrue(asyncResult2)
        XCTAssertEqual(f.pickup.journey?.revision, revision); XCTAssertEqual(f.ledger.revision, ledgerRevision)
        var ledger = try XCTUnwrap(f.dinner.shop)
        XCTAssertThrowsError(try ledger.scheduleMeal(occurrenceID: target.id, day: nil, at: now))
        XCTAssertThrowsError(try ledger.removeMeal(occurrenceID: target.id, at: now))
    }
    func testFailedCalendarWriteSurvivesRestartAndOverlappingReviewIsBlocked() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        f.ledger.failNext = true; XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review)
        let asyncResult3 = await f.coordinator.apply(); XCTAssertFalse(asyncResult3)
        XCTAssertEqual(f.coordinator.pending?.phase, .reserved)
        XCTAssertNil(f.dinner.shop?.mealOccurrences.first { $0.id == intent.plan.occurrenceID })
        XCTAssertFalse(try prepare(f)); XCTAssertEqual(f.pickup.journey?.stockNeeds.count, 1)
        let ledger = try await CarryoverLedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), now: now)
        let pickup = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"), clock: { self.now }); await pickup.load()
        let dinner = model(ledger, pickup: pickup), resumed = DinnerAwayCarryoverModel(dinner: model(ledger, pickup: pickup), pickup: pickup, clock: { self.now })
        let asyncResult4 = await resumed.retry(try XCTUnwrap(resumed.pending)); XCTAssertTrue(asyncResult4)
        XCTAssertEqual(dinner.shop?.mealOccurrences.filter { $0.id == intent.plan.occurrenceID }.count, 1)
        XCTAssertEqual(pickup.journey?.stockNeeds.count, 1); XCTAssertEqual(resumed.records.first?.phase, .completed)
    }
    func testLostCalendarReceiptReconcilesExistingStableTargetWithoutSecondWrite() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        f.ledger.loseNextReceipt = true; XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review)
        let asyncResult5 = await f.coordinator.apply(); XCTAssertFalse(asyncResult5); XCTAssertEqual(f.coordinator.pending?.phase, .reserved)
        let ledger = try await CarryoverLedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), now: now)
        let committedRevision = ledger.revision
        let pickup = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"), clock: { self.now }); await pickup.load()
        let resumed = DinnerAwayCarryoverModel(dinner: model(ledger, pickup: pickup), pickup: pickup, clock: { self.now })
        let asyncResult6 = await resumed.retry(try XCTUnwrap(resumed.pending)); XCTAssertTrue(asyncResult6)
        XCTAssertEqual(ledger.revision, committedRevision)
        XCTAssertEqual(ledger.workspace.shops.first?.mealOccurrences.filter { $0.id == intent.plan.occurrenceID }.count, 1)
    }
    func testReceivedPhysicalIdentityIsRecountedWithoutNewStockOrChangingReceipt() async throws {
        let f = try await fixture(receivedSource: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try XCTUnwrap(f.pickup.journey)
        XCTAssertTrue(try prepare(f)); let asyncResult7 = await f.coordinator.apply(); XCTAssertTrue(asyncResult7)
        let after = try XCTUnwrap(f.pickup.journey)
        XCTAssertTrue(after.stockLots.isEmpty); XCTAssertEqual(after.pickup?.receipts, before.pickup?.receipts)
        XCTAssertEqual(after.pickup?.usableObservations.count, 2)
        XCTAssertEqual(after.pickup?.usableObservations.first, before.pickup?.usableObservations.first)
        XCTAssertEqual(after.pickup?.usableObservations.last?.supersedesID, before.pickup?.usableObservations.last?.id)
        XCTAssertEqual(after.basket, before.basket); XCTAssertEqual(after.settlement, before.settlement)
    }
    func testInsufficientCountAndProtectedSourceAreRejectedWithoutWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = f.pickup.journey
        XCTAssertFalse(try prepare(f, counted: 3)); XCTAssertFalse(try prepare(f, reserved: 5))
        XCTAssertFalse(try prepare(f, needID: f.lunchID)); XCTAssertEqual(f.pickup.journey, before)
        XCTAssertEqual(f.dinner.shop?.mealOccurrences.count, 1)
    }
    func testLaterSourceCorrectionDoesNotBorrowAnotherLotForPinnedCarryover() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review); let asyncResult8 = await f.coordinator.apply(); XCTAssertTrue(asyncResult8)
        guard case .batch(let original) = f.supply else { return XCTFail() }
        let second = ConfirmedStockLot(id: UUID(), foodID: original.foodID, name: "Different batch", usable: q(6), confirmedAt: now, source: .pantry)
        let asyncResult9 = await f.pickup.saveStockLot(second, in: intent.plan.link.sourceShopID); XCTAssertTrue(asyncResult9)
        let current = try XCTUnwrap(f.pickup.journey?.stockLots.first { $0.id == original.id })
        let corrected = ConfirmedStockLot(id: original.id, foodID: original.foodID, name: original.name, usable: q(1), confirmedAt: now, source: original.source)
        let asyncResult10 = await f.pickup.saveStockLot(corrected, in: intent.plan.link.sourceShopID, replacing: current); XCTAssertTrue(asyncResult10)
        let result = try XCTUnwrap(f.pickup.allocation)
        XCTAssertEqual(result.demands.first { $0.id == intent.plan.link.reservationID }?.shortfall, try Rational(2))
        XCTAssertFalse(result.allocations.contains { $0.needID == intent.plan.link.reservationID && $0.lotID == second.id })
    }
    func testAppliedCarryoverKeepsNamedReservationsOutOfNewDinnerIdeaAvailability() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review)
        let applied = await f.coordinator.apply(); XCTAssertTrue(applied)
        let spare = ConfirmedStockLot(id: UUID(), foodID: f.supply.foodID, name: "Separate spare wraps", usable: q(3), confirmedAt: now, source: .pantry)
        let saved = await f.pickup.saveStockLot(spare, in: intent.plan.link.sourceShopID); XCTAssertTrue(saved)
        let shop = try XCTUnwrap(f.dinner.shop), scope = try XCTUnwrap(f.ledger.sourceWorkspaceID)
        let ingredient = MealIngredient(name: "New dinner wraps", quantity: q(4))
        var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "manual-v1", template: .init(title: "New dinner", ingredients: [ingredient]), createdAt: now)
        idea.supplyEvidence = [.init(ingredient: ingredient, workspaceID: scope, shopID: shop.id, basisRevision: shop.basisRevision,
                                     foodID: f.supply.foodID, pack: nil, source: nil, observedAt: nil)]
        let before = f.pickup.journey
        let row = try XCTUnwrap(DinnerIdeaSupplyReview.rows(idea: idea, shop: shop, workspace: f.ledger.workspace,
            workspaceID: scope, journey: before, at: now).first)
        let lunch = try XCTUnwrap(row.reservations.first { $0.id == f.lunchID })
        XCTAssertEqual(lunch.name, "Protected lunch"); XCTAssertTrue(lunch.protected); XCTAssertEqual(lunch.quantity, q(2))
        let carryover = try XCTUnwrap(row.reservations.first { $0.id == intent.plan.link.reservationID })
        XCTAssertEqual(carryover.name, intent.plan.source.title); XCTAssertEqual(carryover.quantity, q(2)); XCTAssertFalse(carryover.protected)
        XCTAssertEqual(row.credited?.amount, try Rational(3)); XCTAssertEqual(row.uncovered?.amount, .one)
        XCTAssertEqual(before?.stockLots.count, 2); XCTAssertEqual(f.pickup.journey, before)
        let allocation = try XCTUnwrap(before).carryoverAllocation()
        XCTAssertEqual(allocation.allocations.filter { $0.needID == intent.plan.link.reservationID }.map(\.lotID), [f.supply.id])
        XCTAssertEqual(allocation.remainingLots.first { $0.lotID == spare.id }?.remainingUnallocated, try Rational(3))
    }

    func testReservedCarryoverReconcilesAfterUnrelatedSettlementAndRestart() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        f.ledger.failNext = true; XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review)
        let failed = await f.coordinator.apply(); XCTAssertFalse(failed)
        let entry = SettlementEntry(id: UUID(), evidenceKey: "later-credit", kind: .postedCharge, amount: Money(minorUnits: 25), occurredAt: now)
        let charged = await f.pickup.settle(entry); XCTAssertTrue(charged)
        let ledger = try await CarryoverLedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), now: now)
        let pickup = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"), clock: { self.now }); await pickup.load()
        let resumed = DinnerAwayCarryoverModel(dinner: model(ledger, pickup: pickup), pickup: pickup, clock: { self.now })
        let saved = await resumed.retry(try XCTUnwrap(resumed.pending)); XCTAssertTrue(saved)
        XCTAssertTrue(pickup.journey?.settlement.entries.contains(entry) == true)
        XCTAssertEqual(pickup.journey?.stockNeeds.count, 1)
        XCTAssertEqual(ledger.workspace.shops.first?.mealOccurrences.filter { $0.id == intent.plan.occurrenceID }.count, 1)
        XCTAssertEqual(resumed.records.first?.phase, .completed)
    }
    func testReservedReconciliationRefusesChangedPhysicalSourceWithoutRebasing() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        f.ledger.failNext = true; XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review)
        let failed = await f.coordinator.apply(); XCTAssertFalse(failed)
        guard case .batch(let original) = f.supply else { return XCTFail() }
        let current = try XCTUnwrap(f.pickup.journey?.stockLots.first { $0.id == original.id })
        let changed = ConfirmedStockLot(id: original.id, foodID: original.foodID, name: original.name, usable: q(5), confirmedAt: now, source: original.source)
        let corrected = await f.pickup.saveStockLot(changed, in: intent.plan.link.sourceShopID, replacing: current); XCTAssertTrue(corrected)
        let saved = await f.coordinator.retry(try XCTUnwrap(f.coordinator.pending)); XCTAssertFalse(saved)
        XCTAssertNil(f.dinner.shop?.mealOccurrences.first { $0.id == intent.plan.occurrenceID })
        XCTAssertEqual(f.coordinator.pending?.intent, intent)
        XCTAssertEqual(f.pickup.journey?.stockLots.first { $0.id == original.id }, changed)
    }

    func testUnrelatedUnresolvedFoodDoesNotBlockKnownPhysicalCarryover() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let food = UUID(), need = UUID()
        let added = await f.pickup.change { value in
            value.stockLots.append(ConfirmedStockLot(id: UUID(), foodID: food, name: "Milk by weight", usable: Quantity(amount: .one, unit: .gram, originalLiteral: "1 g"), confirmedAt: self.now))
            value.stockNeeds.append(StockNeed(id: need, foodID: food, name: "Milk by volume", amount: Quantity(amount: .one, unit: .milliliter, originalLiteral: "1 ml"), priority: .required))
        }; XCTAssertTrue(added)
        let before = try XCTUnwrap(f.pickup.allocation?.demands.first { $0.id == need }); XCTAssertTrue(before.issues.contains(.conversionUnknown))
        XCTAssertTrue(try prepare(f)); let saved = await f.coordinator.apply(); XCTAssertTrue(saved)
        XCTAssertEqual(f.pickup.allocation?.demands.first { $0.id == need }, before)
    }
    func testRecoveryRejectsChangedCalendarTargetEvenWhenLinkAndDateMatch() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        f.ledger.loseNextReceipt = true; XCTAssertTrue(try prepare(f)); let intent = try XCTUnwrap(f.coordinator.review)
        let failed = await f.coordinator.apply(); XCTAssertFalse(failed)
        let ledger = try await CarryoverLedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), now: now)
        let changed = await ledger.change(key: "restore-conflicting-target") { workspace in
            // Simulate a separately restored archive; normal mutation APIs forbid changing a carryover.
            let encoder = JSONEncoder()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(workspace.shops[0])) as? [String: Any])
            var meals = try XCTUnwrap(object["mealOccurrences"] as? [[String: Any]])
            let index = try XCTUnwrap(meals.firstIndex { $0["id"] as? String == intent.plan.occurrenceID.uuidString })
            meals[index]["servings"] = try JSONSerialization.jsonObject(with: encoder.encode(Rational(7)))
            object["mealOccurrences"] = meals
            workspace.shops[0] = try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: object))
        }; XCTAssertTrue(changed)
        let resumed = DinnerAwayCarryoverModel(dinner: model(ledger, pickup: f.pickup), pickup: f.pickup, clock: { self.now })
        let saved = await resumed.retry(try XCTUnwrap(resumed.pending)); XCTAssertFalse(saved)
        XCTAssertEqual(resumed.pending?.phase, .reserved)
        XCTAssertEqual(ledger.workspace.shops[0].mealOccurrences.first { $0.id == intent.plan.occurrenceID }?.servings, try Rational(7))
    }

}
