import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryPickupClaimTransitionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_312_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private enum Kind { case manual, received, recovery }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let pickup: PickupModel
        let ledger: LedgerModel
        let ledgerStore: LedgerStore
        let store: ComparisonStore
        let gate: PantryMutationGate
        let port: PantryPickupCommitPort
        let dinner: DinnerFeatureModel
        let coordinator: DinnerAwayCarryoverModel
        let meals: [UUID]
        let wraps: UUID
        let beans: UUID?
        let aID: UUID?
        let bID: UUID?
        let receipt: ReceiptFragment?
    }

    /// Production ledger/checkout/receipt commands supply exact persisted legacy
    /// candidates. Each phase is then committed to a real migrated target through
    /// the production commit port; no synthetic journey payloads or fake records.
    private func fixture(_ kind: Kind) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        await ledger.open(); await pickup.load(); pickup.bindCookLedger(ledger)
        let ledgerStore = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(ledger, pickup, ledgerStore)
        var shop = ShoppingLedger(title: "Claim transitions", basis: .init(branch: "Main", mode: .pickup, slot: now,
            timeZoneIdentifier: "America/New_York", cap: .init(minorUnits: 3800)))
        let wraps = try shop.addManualLine(name: "Wraps", quantity: q(kind == .recovery ? 12 : 4))
        let supply = try XCTUnwrap(shop.contributions(forLineID: wraps).first?.id)
        let descriptions: [(String, Int64, Int)] = kind == .recovery
            ? [("Tuesday tacos", 6, 10), ("Wednesday quesadillas", 4, 11)] : [("Wrap dinner", 4, 10)]
        var meals: [UUID] = []
        for (title, count, day) in descriptions {
            let date = try MealDay(year: 2026, month: 11, day: day, timeZoneIdentifier: "America/New_York")
            let meal = try shop.chooseMeal(.init(title: title, servings: try Rational(count),
                ingredients: [.init(name: "Wraps", quantity: q(count), notes: "Keep separate", exclusions: ["garlic"])],
                exclusions: ["garlic"]), on: date.date)
            let ingredient = try XCTUnwrap(shop.mealOccurrences.first { $0.id == meal }?.ingredientContributionIDs.first)
            try shop.linkContribution(contributionID: ingredient, within: supply, quantity: q(count))
            meals.append(meal)
        }
        if kind == .recovery { try shop.addProtectedNeed(name: "Wraps", quantity: q(2), purpose: "Lunch", within: supply) }
        let seeded = await ledger.change(key: "claim-transition-fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(seeded)
        let packs = try LedgerPackReview.prepare(ledger: ledger, shopID: shop.id, lineID: wraps,
            offerA: .init(id: "pack", label: "Wrap pack", usableQuantity: q(kind == .recovery ? 8 : 4), price: .init(minorUnits: 300)),
            offerB: .init(id: "two", label: "Two wraps", usableQuantity: q(2), price: .init(minorUnits: 250)),
            itemCap: nil, at: now, source: "Package")
        let packed = try await packs.save(offerID: "pack", ledger: ledger); XCTAssertTrue(packed)
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision,
            previous: nil, packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        let applied = try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: pickup); XCTAssertTrue(applied)
        let quoted = await pickup.setQuote(.init(scope: .wholeCheckout, context: checkout.context,
            pricing: .inclusiveTotal(.exact(.init(minorUnits: 600)))), cap: nil); XCTAssertTrue(quoted)
        let frozen = await pickup.freeze(); XCTAssertTrue(frozen)
        let placed = await pickup.reportPlaced(); XCTAssertTrue(placed)
        var receipt: ReceiptFragment?
        if kind != .manual {
            let key = ReceiptKey(sourceEventID: "actual-wrap-delivery", orderLineID: wraps, branchID: "Main", segmentID: "one")
            let fragment = ReceiptFragment(key: key, itemName: "Wraps", received: q(kind == .recovery ? 8 : 4),
                disposition: .received, receivedAt: now)
            let received = await pickup.receive(fragment, usable: .init(id: UUID(), receipt: key,
                usable: q(kind == .recovery ? 6 : 4), confirmedAt: now, confirmedMatchToOrderLine: true))
            XCTAssertTrue(received); receipt = fragment
        }
        var aID: UUID?, bID: UUID?, beans: UUID?
        if kind == .recovery {
            let food = UUID(); beans = food
            let stocked = await pickup.change { $0.stockLots.append(.init(id: UUID(), foodID: food,
                name: "Beans", usable: q(4), confirmedAt: now, source: .freezer)) }
            XCTAssertTrue(stocked)
        } else {
            let a = ConfirmedStockLot(id: UUID(), foodID: wraps, name: "Use-first wraps A", usable: q(4),
                confirmedAt: now, source: .pantry, useFirst: true)
            let stockedA = await pickup.saveStockLot(a, in: shop.id); XCTAssertTrue(stockedA); aID = a.id
            if kind == .manual {
                let b = ConfirmedStockLot(id: UUID(), foodID: wraps, name: "Freezer wraps B", usable: q(4),
                    confirmedAt: now, source: .freezer)
                let stockedB = await pickup.saveStockLot(b, in: shop.id); XCTAssertTrue(stockedB); bID = b.id
            }
        }
        let store = try ComparisonStore(url: directory.appendingPathComponent("target.sqlite"), inventoryEnabled: true)
        for head in try await pickup.archiveSnapshot().records {
            _ = try await store.save(id: head.id, title: head.title, payload: head.payload, savedAt: head.savedAt)
        }
        let sources = try await store.inventoryCutoverSnapshot()
        let mapped = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: sources.sources.map(PantryLegacyMigration.SourceHead.init),
            ledger: .available(originID: ledgerStore.workspaceID, revision: ledger.revision, workspace: ledger.workspace), at: now)
        let package = try PantryMigrationPackage.build(mapped, migrationID: UUID(), sourceToken: sources.token, inventoryRevision: 0, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let gate = PantryMutationGate()
        let port = PantryPickupCommitPort(store: store, ledger: ledgerStore, gate: gate, authorize: { _, _ in true }, clock: { instant })
        let workspaceID = ledgerStore.workspaceID
        let dinner = DinnerFeatureModel(store: ledger, access: { shopID in
            .init(scope: .local(workspaceID: workspaceID), actorID: "local", shopID: shopID,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: false,
                roleRevision: 0, verifiedAt: instant.addingTimeInterval(-1), validUntil: instant.addingTimeInterval(3600))
        }, phase: { _ in .reportedPlaced }, clock: { instant })
        let coordinator = DinnerAwayCarryoverModel(dinner: dinner, pickup: pickup, clock: { instant })
        cleanup.track(store, port, dinner, coordinator)
        return Fixture(directory: directory, cleanup: cleanup, pickup: pickup, ledger: ledger, ledgerStore: ledgerStore,
            store: store, gate: gate, port: port, dinner: dinner, coordinator: coordinator,
            meals: meals, wraps: wraps, beans: beans, aID: aID, bID: bID, receipt: receipt)
    }

    private func snapshot(_ f: Fixture) async throws -> PantryRepository.Snapshot {
        try await PantryRepository(store: f.store, authorize: { true }).load(at: now)
    }
    /// The producer must advance exactly one real save between port submissions.
    private func submit(_ f: Fixture) async throws -> (PantryPickupCommitPort.Submission, PantryPickupCommitPort.Result) {
        let archive = try await f.pickup.archiveSnapshot()
        let source = try XCTUnwrap(archive.records.first)
        let before = try await f.store.load(id: source.id)
        let head = PantryLegacyMigration.SourceHead(id: source.id, revision: try XCTUnwrap(before).revision + 1,
            payload: source.payload, savedAt: source.savedAt)
        let review = try await f.port.prepare(operationID: UUID(), changedHeads: [head], preparedAt: now)
        let result = try await f.port.apply(review.submission)
        XCTAssertFalse(result.replayed)
        XCTAssertEqual(result.sources.first { $0.id == source.id }?.payload, source.payload)
        return (review.submission, result)
    }
    private func claimID(_ legacyNeedID: UUID, in f: Fixture) async throws -> UUID {
        let sources = try await f.store.list().map(PantryLegacyMigration.SourceHead.init)
        let mapped = try PantryLegacyMigration.map(originID: f.store.workspaceID, heads: sources,
            ledger: .available(originID: f.ledgerStore.workspaceID, revision: f.ledger.revision, workspace: f.ledger.workspace), at: now)
        return try XCTUnwrap(mapped.claimLinks.first { $0.legacyNeedID == legacyNeedID }?.reservationID)
    }
    private func sourceNeed(_ mealID: UUID, in f: Fixture) throws -> AllocationNeed {
        let meal = try XCTUnwrap(f.ledger.shop?.mealOccurrences.first { $0.id == mealID })
        return try XCTUnwrap(AwayCarryoverEngine.sourceNeeds(meal, in: XCTUnwrap(f.pickup.journey)).first)
    }
    private func prepare(_ f: Fixture, mealID: UUID, supply: AwayCarryoverSupply,
                         counted: Int64, reserved: Int64) throws -> AwayCarryoverIntent {
        let need = try sourceNeed(mealID, in: f)
        let accepted = f.coordinator.prepare(id: UUID(), occurrenceID: mealID, needID: need.id, supply: supply,
            counted: q(counted), reserved: q(reserved), servings: .one,
            day: try MealDay(year: 2026, month: 11, day: 13, timeZoneIdentifier: "America/New_York"), observedAt: now)
        XCTAssertTrue(accepted, f.coordinator.message ?? "carryover review")
        return try XCTUnwrap(f.coordinator.review)
    }
    private func prepared(_ intent: AwayCarryoverIntent, in f: Fixture) async throws -> (PantryPickupCommitPort.Submission, PantryPickupCommitPort.Result) {
        // These are the exact central-save/engine calls used by complete().
        // Persist each boundary independently so the canonical intermediate hold
        // is verified without an injected failure or a production testing hook.
        let saved = await f.pickup.change { $0.awayCarryovers.append(.init(intent: intent, phase: .prepared)) }
        XCTAssertTrue(saved, f.pickup.error ?? "prepare")
        return try await submit(f)
    }
    private func reserved(_ intent: AwayCarryoverIntent, in f: Fixture) async throws -> (PantryPickupCommitPort.Submission, PantryPickupCommitPort.Result) {
        let saved = await f.pickup.change { $0 = try AwayCarryoverEngine.reserving(intent, in: $0, at: now) }
        XCTAssertTrue(saved, f.pickup.error ?? "reserve")
        return try await submit(f)
    }
    private func completed(_ intent: AwayCarryoverIntent, in f: Fixture) async throws -> (PantryPickupCommitPort.Submission, PantryPickupCommitPort.Result) {
        let record = try XCTUnwrap(f.coordinator.records.first { $0.id == intent.id })
        XCTAssertEqual(record.phase, .reserved)
        let saved = await f.coordinator.retry(record)
        XCTAssertTrue(saved, f.coordinator.message ?? "complete")
        XCTAssertEqual(f.coordinator.records.first { $0.id == intent.id }?.phase, .completed)
        return try await submit(f)
    }
    private func assertReopened(_ f: Fixture, equals expected: PantryRepository.Snapshot,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let reopened = try ComparisonStore(url: f.directory.appendingPathComponent("target.sqlite"), inventoryEnabled: true)
        f.cleanup.track(reopened)
        let actual = try await PantryRepository(store: reopened, authorize: { true }).load(at: now)
        XCTAssertEqual(actual.state, expected.state, file: file, line: line)
        XCTAssertEqual(actual.lots, expected.lots, file: file, line: line)
        XCTAssertEqual(actual.reservations, expected.reservations, file: file, line: line)
        XCTAssertEqual(actual.availability, expected.availability, file: file, line: line)
        let heads = try await reopened.list(), producer = try await f.pickup.archiveSnapshot()
        XCTAssertEqual(heads.map(\.payload), producer.records.map(\.payload), file: file, line: line)
        try await reopened.close()
    }

    func testPreparedReservedCompletedManualPinStaysOnBAndReplaysWithoutDoubleDemand() async throws {
        let f = try await fixture(.manual), initial = try await snapshot(f)
        let a = try XCTUnwrap(initial.lots.first { $0.source == .manual(originID: f.store.workspaceID, sourceID: f.aID!) })
        let b = try XCTUnwrap(initial.lots.first { $0.source == .manual(originID: f.store.workspaceID, sourceID: f.bID!) })
        let oldNeed = try sourceNeed(f.meals[0], in: f), oldClaimID = try await claimID(oldNeed.id, in: f)
        let bLegacy = try XCTUnwrap(f.pickup.journey?.stockLots.first { $0.id == f.bID })
        _ = try prepare(f, mealID: f.meals[0], supply: .batch(bLegacy), counted: 4, reserved: 4)
        f.coordinator.cancelReview()
        let afterCancel = try await snapshot(f)
        XCTAssertEqual(afterCancel.state, initial.state); XCTAssertEqual(afterCancel.reservations, initial.reservations)
        XCTAssertTrue(f.coordinator.records.isEmpty)
        let intent = try prepare(f, mealID: f.meals[0], supply: .batch(bLegacy), counted: 4, reserved: 4)
        let (preparedSubmission, first) = try await prepared(intent, in: f)
        let pinID = try await claimID(intent.plan.link.reservationID, in: f)
        let held = try XCTUnwrap(first.current.reservations.first { $0.id == pinID })
        XCTAssertEqual(held.state, .unresolved); XCTAssertEqual(held.amount, q(4)); XCTAssertEqual(held.lotID, b.id)
        XCTAssertEqual(first.current.reservations.first { $0.id == oldClaimID }?.state, .active)
        XCTAssertNil(first.current.availability.lots.first { $0.id == b.id }?.free)
        XCTAssertEqual(first.current.lots, initial.lots)
        let (reservedSubmission, second) = try await reserved(intent, in: f)
        let pin = try XCTUnwrap(second.current.reservations.first { $0.id == pinID })
        XCTAssertEqual(pin.state, .active); XCTAssertEqual(pin.amount, q(4)); XCTAssertEqual(pin.lotID, b.id)
        XCTAssertEqual(second.current.reservations.first { $0.id == oldClaimID }?.state, .released)
        XCTAssertEqual(second.current.availability.lots.first { $0.id == a.id }?.free, q(4))
        XCTAssertEqual(second.current.availability.lots.first { $0.id == b.id }?.held, q(4))
        XCTAssertEqual(second.current.availability.lots.first { $0.id == b.id }?.free, q(0))
        XCTAssertEqual(second.current.reservations.filter { $0.state == .active }.map(\.id), [pinID])
        XCTAssertEqual(second.current.lots.count, 2)
        let (submission, third) = try await completed(intent, in: f)
        XCTAssertEqual(third.current.reservations, second.current.reservations)
        XCTAssertEqual(third.current.lots, second.current.lots)
        let observations = try await f.store.inventoryRecords(kind: .observation)
        for savedSubmission in [preparedSubmission, reservedSubmission, submission] {
            let replay = try await f.port.apply(savedSubmission)
            XCTAssertTrue(replay.replayed); XCTAssertEqual(replay.current.state, third.current.state)
            XCTAssertEqual(replay.current.reservations, third.current.reservations,
                "An old phase receipt must not downgrade a completed pin to an unresolved hold.")
        }
        let record = try XCTUnwrap(f.coordinator.records.first)
        let retry = await f.coordinator.retry(record); XCTAssertTrue(retry)
        let afterRetry = try await snapshot(f), observationsAfter = try await f.store.inventoryRecords(kind: .observation)
        XCTAssertEqual(afterRetry.state, third.current.state); XCTAssertEqual(observationsAfter, observations)
        XCTAssertEqual(f.ledger.shop?.mealOccurrences.filter { $0.id == intent.plan.occurrenceID }.count, 1)
        try await assertReopened(f, equals: third.current)
    }

    func testCompletingCalendarWriteCannotReactivateIndependentlyReleasedCanonicalPin() async throws {
        let f = try await fixture(.manual)
        let supply = try XCTUnwrap(f.pickup.journey?.stockLots.first { $0.id == f.bID })
        let intent = try prepare(f, mealID: f.meals[0], supply: .batch(supply), counted: 4, reserved: 4)
        _ = try await prepared(intent, in: f)
        let (_, reservedResult) = try await reserved(intent, in: f)
        let claimID = try await claimID(intent.plan.link.reservationID, in: f)
        let original = try XCTUnwrap(reservedResult.current.reservations.first { $0.id == claimID })
        let released = InventoryReservation(id: original.id, originID: original.originID, revision: original.revision + 1,
            foodID: original.foodID, lotID: original.lotID, name: original.name, amount: original.amount,
            priority: original.priority, state: .released)
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: reservedResult.current.state.revision, request: Data("explicit consumption releases carryover".utf8),
            writes: [.init(record: .init(key: .init(.reservation, released.id), revision: released.revision,
                payload: JSONEncoder().encode(released), lotID: released.lotID), expectedRevision: original.revision)]), at: now)
        let (submission, completedResult) = try await completed(intent, in: f)
        XCTAssertEqual(completedResult.current.reservations.first { $0.id == claimID }, released)
        XCTAssertEqual(completedResult.current.lots, reservedResult.current.lots)
        let replay = try await f.port.apply(submission)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.current.reservations.first { $0.id == claimID }, released)
        try await assertReopened(f, equals: completedResult.current)
    }

    func testReceivedPinSurvivesObservationReplacementAndCannotBorrowCompatibleAAfterCorrection() async throws {
        let f = try await fixture(.received), initial = try await snapshot(f), receipt = try XCTUnwrap(f.receipt)
        let b = try XCTUnwrap(initial.lots.first { $0.source == .receipt(originID: f.store.workspaceID, key: receipt.key) })
        let a = try XCTUnwrap(initial.lots.first { $0.source == .manual(originID: f.store.workspaceID, sourceID: f.aID!) })
        let observation = try XCTUnwrap(f.pickup.journey?.pickup?.usableObservations.last { $0.receipt == receipt.key })
        let intent = try prepare(f, mealID: f.meals[0], supply: .received(receipt, observation), counted: 4, reserved: 4)
        _ = try await prepared(intent, in: f)
        let beforeRows = try await f.store.inventoryRecords(kind: .observation)
        let (_, reservation) = try await reserved(intent, in: f)
        let pinID = try await claimID(intent.plan.link.reservationID, in: f)
        let reservedB = try XCTUnwrap(reservation.current.lots.first { $0.id == b.id })
        XCTAssertEqual(reservedB.source, b.source); XCTAssertNotEqual(reservedB.observationID, b.observationID)
        let afterRows = try await f.store.inventoryRecords(kind: .observation)
        XCTAssertEqual(afterRows.count, beforeRows.count + 1)
        XCTAssertEqual(reservation.current.reservations.first { $0.id == pinID }?.lotID, b.id)
        XCTAssertNotEqual(b.id, intent.plan.link.confirmedSupplyID)
        _ = try await completed(intent, in: f)
        let previous = try XCTUnwrap(f.pickup.journey?.pickup?.usableObservations.last { $0.receipt == receipt.key })
        let corrected = await f.pickup.confirmUsable(.init(id: UUID(), receipt: receipt.key, usable: q(2), confirmedAt: now,
            supersedesID: previous.id, confirmedMatchToOrderLine: true))
        XCTAssertTrue(corrected)
        let (_, result) = try await submit(f)
        XCTAssertEqual(result.current.lots.count, initial.lots.count)
        XCTAssertEqual(result.current.lots.first { $0.id == b.id }?.count, .exact(q(2)))
        XCTAssertEqual(result.current.reservations.first { $0.id == pinID }?.lotID, b.id)
        let coverage = try XCTUnwrap(result.current.availability.reservations.first { $0.id == pinID })
        XCTAssertEqual(coverage.requested, q(4)); XCTAssertEqual(coverage.backed, q(2)); XCTAssertEqual(coverage.shortfall, q(2))
        XCTAssertEqual(result.current.availability.allocations.filter { $0.needID == pinID }.map(\.lotID), [b.id])
        XCTAssertEqual(result.current.availability.lots.first { $0.id == a.id }?.free, q(4))
        let phase = try XCTUnwrap(f.coordinator.records.first)
        let retry = await f.coordinator.retry(phase); XCTAssertTrue(retry)
        let afterRetry = try await snapshot(f)
        XCTAssertEqual(afterRetry.state, result.current.state); XCTAssertEqual(afterRetry.reservations, result.current.reservations)
        try await assertReopened(f, equals: result.current)
    }

    func testRecoveryReplacementThenTwoPartialCarryoversKeepsOnlyEffectiveClaimsAndExactPins() async throws {
        let f = try await fixture(.recovery), initial = try await snapshot(f), beans = try XCTUnwrap(f.beans)
        let journey = try XCTUnwrap(f.pickup.journey), wednesday = f.meals[1]
        let originalNeed = try sourceNeed(wednesday, in: f), oldClaimID = try await claimID(originalNeed.id, in: f)
        let protectedClaim = try XCTUnwrap(initial.reservations.first { $0.priority == .protected })
        let tuesdayNeed = try sourceNeed(f.meals[0], in: f), tuesdayID = try await claimID(tuesdayNeed.id, in: f)
        let tuesdayClaim = try XCTUnwrap(initial.reservations.first { $0.id == tuesdayID })
        let authority = PickupRecoveryAuthority(presentation: .init(workspaceID: f.pickup.sourceWorkspaceID,
            localActorID: UUID(), workspaceUnlocked: true, sceneActive: true, childPresented: false,
            guardianChildOnly: false, accountSubject: nil, householdLocked: false, projection: nil),
            ledgerWorkspaceID: f.ledgerStore.workspaceID, ledgerRevisionID: try XCTUnwrap(f.ledger.shop?.revisionID),
            selectedPickupID: journey.id, leaseID: UUID())
        let old = try XCTUnwrap(f.pickup.recoveryDefinitions().first { $0.meal.id == wednesday })
        let need = StockNeed(id: UUID(), foodID: beans, name: "Wednesday beans", amount: q(4), priority: .required)
        let due = now.addingTimeInterval(2700)
        let replacement = RecoveryMeal(id: old.meal.id, revisionID: UUID(), templateID: nil, templateVersion: nil,
            title: "Wednesday beans", servings: old.meal.servings,
            ingredients: [.init(ingredientID: UUID(), groupID: nil, foodName: "Beans", need: need)],
            scheduledDay: old.meal.scheduledDay, due: due, timeZoneID: old.meal.timeZoneID,
            exclusions: old.meal.exclusions, remainingElapsedMinutes: 15, requiredLeadMinutes: old.meal.requiredLeadMinutes,
            advanceStepsCompleted: false)
        let review = try f.pickup.prepareMealRecovery(definition: .init(meal: replacement, groups: old.groups,
            notes: "Warm beans", sourceURL: nil,
            ingredientRules: [.init(needID: need.id, notes: "Use freezer beans", exclusions: ["garlic"])], acceptedTemplate: nil),
            operationID: UUID(), confirmedUnknownDeadline: old.meal.due == nil ? due : nil,
            agreesToRepeat: false, proposesExtraTrip: false, agreesToExtraTrip: false, acceptsUnresolved: true, authority: authority)
        let afterPreview = try await snapshot(f)
        XCTAssertEqual(afterPreview.state, initial.state); XCTAssertEqual(f.pickup.journey, journey)
        let applied = await f.pickup.applyMealRecovery(review, currentAuthority: { authority }); XCTAssertTrue(applied)
        let (submission, recovered) = try await submit(f)
        let replacementID = try await claimID(need.id, in: f)
        XCTAssertEqual(recovered.current.reservations.first { $0.id == oldClaimID }?.state, .released)
        XCTAssertEqual(recovered.current.reservations.first { $0.id == replacementID }?.amount, q(4))
        XCTAssertEqual(recovered.current.lots, initial.lots)
        XCTAssertEqual(f.pickup.journey?.needs, journey.needs, "Original purchase needs stay raw; only their effective replacement is reserved.")
        let replay = try await f.port.apply(submission); XCTAssertTrue(replay.replayed)
        let recoveryReplay = await f.pickup.applyMealRecovery(review, currentAuthority: { authority }); XCTAssertTrue(recoveryReplay)
        let afterReplay = try await snapshot(f); XCTAssertEqual(afterReplay.state, recovered.current.state)
        let beanLot = try XCTUnwrap(initial.lots.first { $0.foodID == beans })
        var pins: [UUID] = []
        for remainder in [Int64(4), 2] {
            let current = try XCTUnwrap(f.pickup.journey), currentNeed = try sourceNeed(wednesday, in: f)
            XCTAssertEqual(currentNeed.amount, q(remainder))
            let supply = try XCTUnwrap(AwayCarryoverEngine.supplies(for: currentNeed, in: current).first)
            let intent = try prepare(f, mealID: wednesday, supply: supply, counted: 4, reserved: 2)
            _ = try await prepared(intent, in: f)
            _ = try await reserved(intent, in: f)
            let (completedSubmission, result) = try await completed(intent, in: f)
            let pinID = try await claimID(intent.plan.link.reservationID, in: f); pins.append(pinID)
            let claim = try XCTUnwrap(result.current.reservations.first { $0.id == pinID })
            XCTAssertEqual(claim.lotID, beanLot.id); XCTAssertEqual(claim.amount, q(2)); XCTAssertEqual(claim.state, .active)
            let effectiveMeal = try XCTUnwrap(result.current.reservations.first { $0.id == replacementID })
            if remainder == 4 { XCTAssertEqual(effectiveMeal.amount, q(2)); XCTAssertEqual(effectiveMeal.state, .active) }
            else { XCTAssertEqual(effectiveMeal.state, .released) }
            XCTAssertEqual(result.current.reservations.first { $0.id == oldClaimID }?.state, .released)
            XCTAssertEqual(result.current.reservations.first { $0.id == tuesdayID }, tuesdayClaim)
            XCTAssertEqual(result.current.reservations.first { $0.id == protectedClaim.id }, protectedClaim)
            let beanClaims = result.current.reservations.filter { $0.foodID == beans && $0.state == .active }
            XCTAssertEqual(try beanClaims.reduce(Rational.zero) { try $0.adding(XCTUnwrap($1.amount).amount) }, try Rational(4))
            let committedReplay = try await f.port.apply(completedSubmission)
            XCTAssertTrue(committedReplay.replayed); XCTAssertEqual(committedReplay.current.state, result.current.state)
            let record = try XCTUnwrap(f.coordinator.records.first { $0.id == intent.id })
            let retried = await f.coordinator.retry(record); XCTAssertTrue(retried)
        }
        let final = try await snapshot(f)
        XCTAssertEqual(Set(pins).count, 2)
        XCTAssertEqual(final.availability.lots.first { $0.id == beanLot.id }?.held, q(4))
        XCTAssertEqual(final.availability.lots.first { $0.id == beanLot.id }?.free, q(0))
        XCTAssertEqual(Set(final.availability.allocations.filter { pins.contains($0.needID) }.map(\.lotID)), [beanLot.id])
        XCTAssertEqual(f.pickup.journey?.needs, journey.needs)
        XCTAssertEqual(f.pickup.journey?.pickup, journey.pickup)
        try await assertReopened(f, equals: final)
    }
}
