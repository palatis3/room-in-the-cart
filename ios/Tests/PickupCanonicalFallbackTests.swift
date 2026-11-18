import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PickupCanonicalFallbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64) -> Quantity { .init(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let directory: URL
        let inventory: ComparisonStore
        let ledger: LedgerStore
        let repository: PantryRepository
        let mapping: PantryLegacyMigration.Plan
        let first: PickupJourney
        let second: PickupJourney
        let food: UUID
        let target: StockNeed
        let dinner: AcceptedDinner
        var draft: PickupFallbackDraft
    }
    private func fixture(secondLot: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(inventory, ledger)
        let food = UUID(), target = StockNeed(id: UUID(), foodID: food, name: "Tonight", amount: q(4), priority: .required)
        var first = PickupJourney(id: UUID(), savedAt: now)
        first.stockLots = [.init(id: food, foodID: food, name: "Wraps", usable: q(8), confirmedAt: now, source: .pantry)]
        if secondLot { first.stockLots.append(.init(id: UUID(), foodID: food, name: "Freezer wraps", usable: q(4), confirmedAt: now, source: .freezer)) }
        first.stockNeeds = [target]
        var second = PickupJourney(id: UUID(), savedAt: now)
        second.originShopID = first.id; second.stockLots = first.stockLots
        second.stockNeeds = [.init(id: UUID(), foodID: food, name: "Other shop lunch", amount: q(2), priority: .protected)]
        for journey in [first, second] {
            try PickupModel.validate(journey)
            _ = try await inventory.save(id: journey.id, title: "Fallback fixture", payload: JSONEncoder().encode(journey), savedAt: now)
        }
        let snapshot = try await inventory.inventoryCutoverSnapshot()
        let mapping = try PantryLegacyMigration.map(originID: inventory.workspaceID,
            heads: snapshot.sources.map(PantryLegacyMigration.SourceHead.init),
            ledger: .available(originID: ledger.workspaceID, revision: 0, workspace: LedgerWorkspace()), at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: snapshot.token,
            inventoryRevision: 0, at: now)
        _ = try await inventory.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await inventory.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await inventory.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: inventory, authorize: { true }); cleanup.track(repository)
        let ingredient = MealIngredient(name: "Wraps", quantity: q(1))
        let dinner = AcceptedDinner(id: UUID(), template: .init(title: "Accepted wraps", servings: .one, ingredients: [ingredient]),
            acceptedAt: now, acceptedFallback: true)
        var draft = PickupFallbackDraft()
        draft.target = target.id; draft.portions = "5"; draft.deadline = now.addingTimeInterval(3600)
        draft.topUpBudget = "100"; draft.topUpCharges = "0"; draft.tripMinutes = "10"
        var review = FallbackRecipeReview()
        review.reviewedIdentityYieldAndExclusions = true; review.elapsedMinutes = "15"
        review.ingredients[ingredient.id] = .init(foodID: food, packLabel: "One wrap", packYield: "1", packUnit: .count,
            packPrice: "1.00", availablePacks: "20")
        draft.reviews[dinner.id] = review
        return .init(cleanup: cleanup, directory: directory, inventory: inventory, ledger: ledger, repository: repository,
            mapping: mapping, first: first, second: second, food: food, target: target, dinner: dinner, draft: draft)
    }
    private func supply(_ f: Fixture) async throws -> PickupFallbackCanonicalSupply {
        try .prepare(journey: f.first, context: .init(snapshot: await f.repository.load(at: now), mapping: f.mapping, asOf: now))
    }
    private func ranked(_ f: Fixture, _ supply: PickupFallbackCanonicalSupply) throws -> [PickupFallbackOption] {
        try PickupFallbackOptions.ranked(journey: f.first, library: [f.dinner], chosenTemplates: [], draft: f.draft,
            at: now, paid: true, canonical: supply)
    }
    private func recount(_ f: Fixture, lotID: UUID, count: InventoryCount) async throws {
        let before = try await f.repository.load(at: now), lot = try XCTUnwrap(before.lots.first { $0.id == lotID })
        _ = try await f.repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: lotID, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(count, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
    }
    private func pin(_ f: Fixture, legacyNeedID: UUID, to lotID: UUID) async throws {
        let snapshot = try await f.repository.load(at: now)
        let link = try XCTUnwrap(f.mapping.claimLinks.first { $0.legacyNeedID == legacyNeedID })
        let old = try XCTUnwrap(snapshot.reservations.first { $0.id == link.reservationID })
        let claim = InventoryReservation(id: old.id, originID: old.originID, revision: old.revision + 1,
            foodID: old.foodID, lotID: lotID, name: old.name, amount: old.amount, priority: old.priority)
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(),
            expectedRevision: snapshot.state.revision, request: Data("review exact fallback fixture pin".utf8),
            writes: [.init(record: .init(key: .init(.reservation, claim.id), revision: claim.revision,
                payload: JSONEncoder().encode(claim), lotID: lotID), expectedRevision: old.revision)]), at: now)
    }
    private func addUnknown(_ f: Fixture, source: InventorySource? = nil) async throws -> UUID {
        let snapshot = try await f.repository.load(at: now), id = UUID()
        _ = try await f.repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: id,
            eventID: UUID(), expectedRevision: nil, occurredAt: now,
            change: .create(.init(foodID: f.food, name: "Other wraps", source: source ?? .manual(originID: f.inventory.workspaceID, sourceID: id),
                location: .fridge, unit: .count, count: .unknown, useFirst: true), observationID: UUID())),
            reviewedInventoryRevision: snapshot.state.revision, at: now)
        return id
    }

    func testCurrentRecountAndOtherShopClaimsDetermineTopUpExactlyOnce() async throws {
        let f = try await fixture(), initial = try await supply(f)
        let first = try XCTUnwrap(ranked(f, initial).first)
        XCTAssertEqual(first.packCount, 0); XCTAssertEqual(first.ingredients.first?.allocated.amount, try Rational(5))
        XCTAssertEqual(initial.reservations(excluding: f.target.id).map(\.name), ["Other shop lunch"])
        let snapshot = try await f.repository.load(at: now), lot = try XCTUnwrap(snapshot.lots.first)
        try await recount(f, lotID: lot.id, count: .exact(q(5)))
        let changed = try await supply(f), second = try XCTUnwrap(ranked(f, changed).first)
        XCTAssertEqual(second.packCount, 2); XCTAssertEqual(second.ingredients.first?.allocated.amount, try Rational(3))
        XCTAssertNotEqual(first.reviewedPantryBasis, second.reviewedPantryBasis)
        XCTAssertEqual(f.first.stockLots.first?.usable, q(8))
        try await recount(f, lotID: lot.id, count: .exact(q(1)))
        let short = try await supply(f), last = try XCTUnwrap(ranked(f, short).first)
        XCTAssertEqual(last.packCount, 6, "Five fallback wraps plus the other shop's still-owed one, counted once")
        XCTAssertEqual(last.ingredients.first?.allocated.amount, .zero)
    }

    func testUnknownCountNeverUsesCopiedEightButIndependentKnownFoodRemainsUsable() async throws {
        let f = try await fixture()
        _ = try await addUnknown(f)
        let known = try await supply(f)
        XCTAssertEqual(try ranked(f, known).first?.packCount, 0, "An unrelated unknown lot does not erase enough known backing")
        let snapshot = try await f.repository.load(at: now)
        let lot = try XCTUnwrap(snapshot.lots.first { $0.source == .manual(originID: f.inventory.workspaceID, sourceID: f.food) })
        try await recount(f, lotID: lot.id, count: .someLeft)
        let unknown = try await supply(f)
        XCTAssertTrue(try ranked(f, unknown).isEmpty)
        XCTAssertEqual(f.first.stockLots.first?.usable, q(8))
    }

    func testExactTargetPinCanUseOwnBackingButCannotBorrowFreeLotsOrBuyItsWayOut() async throws {
        var f = try await fixture(secondLot: true)
        let snapshot = try await f.repository.load(at: now)
        let pinned = try XCTUnwrap(snapshot.lots.first { $0.location == .freezer })
        let cupboard = try XCTUnwrap(snapshot.lots.first { $0.location == .cupboard })
        // The protected lunch is owed from its own physical lot. Leaving it
        // unpinned would legitimately let it consume the freezer lot first.
        try await pin(f, legacyNeedID: f.second.stockNeeds[0].id, to: cupboard.id)
        try await pin(f, legacyNeedID: f.target.id, to: pinned.id)
        try await recount(f, lotID: pinned.id, count: .exact(q(2)))
        let allocated = try await f.repository.load(at: now)
        let targetClaim = try XCTUnwrap(f.mapping.claimLinks.first { $0.legacyNeedID == f.target.id })
        let lunchClaim = try XCTUnwrap(f.mapping.claimLinks.first { $0.legacyNeedID == f.second.stockNeeds[0].id })
        XCTAssertEqual(allocated.availability.reservations.first { $0.id == targetClaim.reservationID }?.backed, q(2))
        XCTAssertEqual(allocated.availability.reservations.first { $0.id == lunchClaim.reservationID }?.backed, q(2))
        XCTAssertEqual(Set(allocated.availability.allocations.filter { $0.needID == targetClaim.reservationID }.map(\.lotID)), [pinned.id])
        f.draft.portions = "3"
        let canonical = try await supply(f)
        XCTAssertTrue(try ranked(f, canonical).isEmpty, "The other eight wraps and offered packs cannot replace the exact pin")
        f.draft.portions = "2"
        let own = try XCTUnwrap(ranked(f, canonical).first)
        XCTAssertEqual(own.packCount, 0); XCTAssertEqual(own.ingredients.first?.allocated.amount, try Rational(2))
        try await pin(f, legacyNeedID: f.second.stockNeeds[0].id, to: pinned.id)
        try await recount(f, lotID: pinned.id, count: .exact(q(1)))
        let outsidePin = try await supply(f)
        XCTAssertTrue(try ranked(f, outsidePin).isEmpty, "A shortage on another exact pin is unresolved, not a fungible top-up")
    }

    func testMissingReceiptEvidenceCannotTurnARecountIntoFallbackCredit() async throws {
        let f = try await fixture()
        let key = ReceiptKey(sourceEventID: "missing", orderLineID: f.food, branchID: "Main", segmentID: "one")
        let receipt = try await addUnknown(f, source: .receipt(originID: f.inventory.workspaceID, key: key))
        try await recount(f, lotID: receipt, count: .exact(q(20)))
        let canonical = try await supply(f)
        XCTAssertTrue(try ranked(f, canonical).isEmpty, "A count never substitutes for original receipt identity and eligibility")
    }

    func testSelectedInstructionsRejectStaleBasisAndExactCompletedReplaySurvivesRecount() async throws {
        let f = try await fixture(), instant = now, gate = PantryMutationGate()
        let pending = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: f.inventory.workspaceID, ledgerWorkspaceID: f.ledger.workspaceID)
        let model = PickupModel(store: f.inventory, clock: { instant }, pantry: .init(ledger: f.ledger,
            pendingStore: pending, gate: gate, authorize: { true }))
        f.cleanup.track(model); await model.load(); model.selectedID = f.first.id
        let initial = try PickupFallbackCanonicalSupply.prepare(journey: XCTUnwrap(model.journey), context: XCTUnwrap(model.pantryReviewContext()))
        let best = try XCTUnwrap(ranked(f, initial).first)
        var review = PickupFallbackReview(); review.draft = f.draft; review.reviewDraft()
        let draft = try XCTUnwrap(review.manualRepair(for: best, fresh: best, in: f.first))
        XCTAssertEqual(draft.reviewedPantryBasis, initial.basis)
        let repair = try XCTUnwrap(draft.instruction(in: f.first, at: now))
        let snapshot = try await f.repository.load(at: now), lot = try XCTUnwrap(snapshot.lots.first)
        try await recount(f, lotID: lot.id, count: .exact(q(7)))
        let rejected = await model.saveReviewedRepair(repair, journeyID: f.first.id, reviewedPantryBasis: draft.reviewedPantryBasis)
        XCTAssertFalse(rejected); XCTAssertFalse(model.hasPendingSave); XCTAssertTrue(model.journey?.repairs.isEmpty == true)
        let current = try XCTUnwrap(model.journey)
        let fresh = try PickupFallbackCanonicalSupply.prepare(journey: current, context: XCTUnwrap(model.pantryReviewContext()))
        let freshBest = try XCTUnwrap(PickupFallbackOptions.ranked(journey: current, library: [f.dinner], chosenTemplates: [],
            draft: f.draft, at: now, paid: true, canonical: fresh).first)
        review.reviewDraft()
        let freshDraft = try XCTUnwrap(review.manualRepair(for: freshBest, fresh: freshBest, in: current))
        let exact = try XCTUnwrap(freshDraft.instruction(in: current, at: now))
        let saved = await model.saveReviewedRepair(exact, journeyID: f.first.id, reviewedPantryBasis: freshDraft.reviewedPantryBasis)
        XCTAssertTrue(saved, model.error ?? "")
        let revision = model.journey?.revision
        try await recount(f, lotID: lot.id, count: .exact(q(2)))
        let replay = await model.saveReviewedRepair(exact, journeyID: f.first.id, reviewedPantryBasis: freshDraft.reviewedPantryBasis)
        XCTAssertTrue(replay, model.error ?? ""); XCTAssertEqual(model.journey?.revision, revision)
        XCTAssertEqual(model.journey?.repairs, [exact]); XCTAssertNil(try pending.read())
    }

    func testRealPlannedAndUrgentProducersExposeSavableFallbackTargetsWithoutDuplicateUrgentRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let model = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        cleanup.track(model)
        let shopID = UUID(), food = UUID(), needID = UUID()
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "Evening",
            commitmentsID: shopID, observedAt: now, source: "Reviewed list")
        let started = await model.start(from: [.init(id: food, name: "Wraps", quantity: q(4), expectedCost: .exact(.zero))],
            shopID: shopID, context: context,
            plannedNeeds: [.init(id: needID, orderLineID: food, name: "Planned dinner", amount: q(4), priority: .required)])
        XCTAssertTrue(started, model.error ?? "")
        let stocked = await model.saveStockLot(.init(id: UUID(), foodID: food, name: "Freezer wraps", usable: q(6),
            confirmedAt: now, source: .freezer), in: shopID)
        XCTAssertTrue(stocked, model.error ?? "")

        func reviewedInstruction(journey: PickupJourney, target: UUID, food: UUID, portions: String) throws -> PickupRepair {
            let ingredient = MealIngredient(name: "Wraps", quantity: q(1))
            let dinner = AcceptedDinner(id: UUID(), template: .init(title: "Accepted wraps", servings: .one, ingredients: [ingredient]),
                acceptedAt: now, acceptedFallback: true)
            var draft = PickupFallbackDraft()
            draft.target = target; draft.portions = portions; draft.deadline = now.addingTimeInterval(3600)
            var recipe = FallbackRecipeReview()
            recipe.elapsedMinutes = "15"; recipe.reviewedIdentityYieldAndExclusions = true
            recipe.ingredients[ingredient.id] = .init(foodID: food)
            draft.reviews[dinner.id] = recipe
            let best = try XCTUnwrap(PickupFallbackOptions.ranked(journey: journey, library: [dinner], chosenTemplates: [],
                draft: draft, at: now, paid: true).first)
            var review = PickupFallbackReview(); review.draft = draft; review.reviewDraft()
            let manual = try XCTUnwrap(review.manualRepair(for: best, fresh: best, in: journey))
            return try XCTUnwrap(manual.instruction(in: journey, at: now))
        }
        let planned = try XCTUnwrap(model.journey)
        XCTAssertNil(planned.pickup); XCTAssertTrue(planned.needs.isEmpty)
        XCTAssertEqual(planned.currentRepairNeeds.map(\.id), [needID])
        let plannedRepair = try reviewedInstruction(journey: planned, target: needID, food: food, portions: "4")
        let savedPlan = await model.saveReviewedRepair(plannedRepair, journeyID: planned.id)
        XCTAssertTrue(savedPlan, model.error ?? "")

        let urgent = UrgentMealNeed(id: UUID(), food: "Wraps", meal: "Tonight", required: q(2), available: q(3),
            due: now.addingTimeInterval(3600), confirmedAt: now)
        let added = await model.addUrgent(urgent); XCTAssertTrue(added, model.error ?? "")
        let urgentJourney = try XCTUnwrap(model.journey)
        XCTAssertTrue(urgentJourney.currentRepairNeeds.isEmpty, "The manual picker lists this target once in the urgent section")
        XCTAssertEqual(urgentJourney.recoveryCurrentUrgent.map(\.id), [urgent.id])
        XCTAssertEqual(urgentJourney.stockNeeds.map(\.id), [urgent.id])
        let urgentRepair = try reviewedInstruction(journey: urgentJourney, target: urgent.id, food: urgent.id, portions: "2")
        let savedUrgent = await model.saveReviewedRepair(urgentRepair, journeyID: urgentJourney.id)
        XCTAssertTrue(savedUrgent, model.error ?? "")
        XCTAssertEqual(model.journey?.currentRepairInstructions, [urgentRepair])
    }

}
