import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PickupPantryAddEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ value: Int64) -> Quantity { .init(amount: try! Rational(value), unit: .count, originalLiteral: String(value)) }
    private final class Authority { var allowed = true }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let inventory: ComparisonStore
        let pickup: PickupModel
        let journal: PantryPendingStore
        let authority: Authority
        let foodID: UUID
        let oldReview: PickupStockLotReview?
        let scope: PickupStockReviewScope
    }
    private func fixture(withNeed: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(inventory, ledger)
        let foodID = UUID()
        let scope = PickupStockReviewScope(workspaceID: inventory.workspaceID, localActorID: UUID(),
            accountSubject: nil, householdID: nil, memberID: nil, role: nil)
        var oldReview: PickupStockLotReview?
        if withNeed {
            // Use the real pre-cutover writer to create a separately identified
            // batch and a reviewed need whose food has no physical batch yet.
            let legacy = PickupModel(store: inventory, clock: { instant })
            cleanup.track(legacy)
            await legacy.load()
            let legacyLotID = UUID()
            let lot = ConfirmedStockLot(id: legacyLotID, foodID: legacyLotID, name: "Wraps", usable: q(5), confirmedAt: now, source: .freezer)
            let created = await legacy.saveStockLot(lot, in: UUID(), createIfEmpty: true)
            XCTAssertTrue(created, legacy.error ?? "")
            let need = StockNeed(id: UUID(), foodID: foodID, name: "Wraps", amount: q(3), priority: .required)
            let changed = await legacy.change { $0.stockNeeds.append(need) }
            XCTAssertTrue(changed, legacy.error ?? "")
            let corrected = ConfirmedStockLot(id: lot.id, foodID: lot.foodID, name: lot.name, usable: q(2), confirmedAt: now, source: lot.source)
            oldReview = try legacy.previewStockLot(corrected, in: XCTUnwrap(legacy.journey?.id), replacing: lot, scope: scope)
            XCTAssertTrue(legacy.isCurrentStockLotReview(try XCTUnwrap(oldReview), scope: scope))
        }
        let before = try await inventory.inventoryCutoverSnapshot()
        let mapping = try PantryLegacyMigration.map(originID: inventory.workspaceID,
            heads: before.sources.map(PantryLegacyMigration.SourceHead.init),
            ledger: .available(originID: ledger.workspaceID, revision: 0, workspace: LedgerWorkspace()), at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: before.token, inventoryRevision: 0, at: now)
        _ = try await inventory.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await inventory.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await inventory.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        let authority = Authority()
        let pickup = PickupModel(store: inventory, clock: { instant }, pantry: .init(ledger: ledger, pendingStore: pending,
            gate: PantryMutationGate(), authorize: { authority.allowed }))
        cleanup.track(pickup)
        await pickup.load()
        XCTAssertTrue(pickup.pantryIsActive); XCTAssertTrue(pickup.pantryReadIsCurrent)
        return .init(cleanup: cleanup, inventory: inventory, pickup: pickup, journal: try pending.makeFoodPendingStore(),
                     authority: authority, foodID: foodID, oldReview: oldReview, scope: scope)
    }

    func testStandaloneCanonicalAddPersistsWithoutCreatingJourneyAndRejectsLegacyWriter() async throws {
        let f = try await fixture()
        let route = try PickupPantryAddContext.resolve(model: f.pickup, ingredientID: nil)
        XCTAssertNil(route.journeyID); XCTAssertNil(route.reviewedFood)
        XCTAssertTrue(route.matches(model: f.pickup))
        XCTAssertThrowsError(try PickupPantryAddContext.resolve(model: f.pickup, ingredientID: f.foodID))
        let editor = try XCTUnwrap(f.pickup.makePantryModel())
        await editor.load()
        await editor.prepareNewFood(name: "Milk", location: .fridge, amount: "1.5", unit: .liter)
        let review = try XCTUnwrap(editor.review)
        await editor.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(editor.notice, .saved)
        XCTAssertEqual(editor.snapshot?.lots.first?.id, review.command.lotID)
        XCTAssertEqual(editor.snapshot?.lots.first?.confirmedAt, now)
        XCTAssertTrue(f.pickup.pantryReadIsCurrent)
        XCTAssertTrue(f.pickup.journeys.isEmpty)
        let current = try await f.inventory.inventoryCutoverSnapshot()
        XCTAssertTrue(current.sources.isEmpty, "A physical food record is not a shopping journey")
        XCTAssertNil(try f.journal.read())
        let reopened = try XCTUnwrap(f.pickup.makePantryModel())
        await reopened.load()
        XCTAssertEqual(reopened.snapshot?.lots.map(\.id), [review.command.lotID])
        let legacy = ConfirmedStockLot(id: UUID(), foodID: UUID(), name: "Copied milk", usable: q(9), confirmedAt: now, source: .pantry)
        let refused = await f.pickup.saveStockLot(legacy, in: UUID(), createIfEmpty: true)
        XCTAssertFalse(refused); XCTAssertTrue(f.pickup.journeys.isEmpty)
        XCTAssertEqual(f.pickup.pantrySnapshot?.lots.count, 1)
    }

    func testReviewedIngredientFirstBatchKeepsExactIdentityAndSourceChangeExpiresRoute() async throws {
        let f = try await fixture(withNeed: true)
        let route = try PickupPantryAddContext.resolve(model: f.pickup, ingredientID: f.foodID)
        let reviewed = try XCTUnwrap(route.reviewedFood)
        XCTAssertEqual(reviewed.id, f.foodID)
        XCTAssertFalse(f.pickup.pantrySnapshot?.lots.contains { $0.foodID == f.foodID } ?? true)
        XCTAssertThrowsError(try PickupPantryAddContext.resolve(model: f.pickup, ingredientID: UUID()))
        let editor = try XCTUnwrap(f.pickup.makePantryModel())
        await editor.load()
        await editor.prepareNewFood(name: "Wraps", existingFoodID: f.foodID, location: .cupboard, amount: "4", unit: .count)
        XCTAssertNil(editor.review, "Existing-only selection must not become an arbitrary identity constructor")
        await editor.prepareNewFood(name: "Ignored", reviewedFood: reviewed, location: .cupboard, amount: "4", unit: .count)
        XCTAssertEqual(editor.review?.proposedLot.foodID, f.foodID)
        XCTAssertEqual(editor.review?.proposedLot.name, "Wraps")
        await editor.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(editor.notice, .saved)
        XCTAssertEqual(f.pickup.pantrySnapshot?.lots.count, 2, "Equal names do not merge separate reviewed food identities")
        XCTAssertEqual(f.pickup.allocation?.demands.first?.allocated, try Rational(3))
        XCTAssertFalse(f.pickup.journey?.stockLots.contains { $0.foodID == f.foodID } ?? true,
                       "Canonical addition must not rewrite the historical journey's stock")
        XCTAssertTrue(route.matches(model: f.pickup), "A count-only save does not change the ingredient source")
        let changed = await f.pickup.change { $0.stockNeeds.removeAll { $0.foodID == f.foodID } }
        XCTAssertTrue(changed, f.pickup.error ?? "")
        XCTAssertFalse(route.matches(model: f.pickup))
        XCTAssertThrowsError(try PickupPantryAddContext.resolve(model: f.pickup, ingredientID: f.foodID))
    }

    func testIngredientContextRejectsNewSourceBothBeforeLoadAndDuringRepositoryReview() async throws {
        let f = try await fixture(withNeed: true)
        let original = try XCTUnwrap(PickupPantryAddContext.resolve(model: f.pickup, ingredientID: f.foodID).reviewedFood)
        let loadedBeforeChange = try XCTUnwrap(f.pickup.makePantryModel())
        await loadedBeforeChange.load()
        let oldNeed = try XCTUnwrap(f.pickup.journey?.stockNeeds.first { $0.foodID == f.foodID })
        let changedNeed = StockNeed(id: oldNeed.id, foodID: oldNeed.foodID, name: oldNeed.name, amount: q(4), priority: oldNeed.priority)
        let changed = await f.pickup.change { value in
            guard let index = value.stockNeeds.firstIndex(where: { $0.id == oldNeed.id }) else { throw PickupStockReviewError.stale }
            value.stockNeeds[index] = changedNeed
        }
        XCTAssertTrue(changed, f.pickup.error ?? "")
        // The editor still has its old snapshot, so only the actual repository
        // review read can detect this window. It must not silently rebase identity.
        await loadedBeforeChange.prepareNewFood(name: "", reviewedFood: original, location: .cupboard, amount: "5", unit: .count)
        XCTAssertNil(loadedBeforeChange.review); XCTAssertNil(loadedBeforeChange.pending)
        XCTAssertEqual(loadedBeforeChange.notice, .stale)
        let loadedAfterChange = try XCTUnwrap(f.pickup.makePantryModel())
        await loadedAfterChange.load()
        await loadedAfterChange.prepareNewFood(name: "", reviewedFood: original, location: .cupboard, amount: "5", unit: .count)
        XCTAssertNil(loadedAfterChange.review); XCTAssertEqual(loadedAfterChange.notice, .stale)
        XCTAssertNil(try f.journal.read())
        let refreshed = await f.pickup.refreshPantryStock()
        XCTAssertTrue(refreshed)
        let current = try XCTUnwrap(PickupPantryAddContext.resolve(model: f.pickup, ingredientID: f.foodID).reviewedFood)
        XCTAssertNotEqual(current.inventoryRevision, original.inventoryRevision)
        let refreshedEditor = try XCTUnwrap(f.pickup.makePantryModel())
        await refreshedEditor.load()
        await refreshedEditor.prepareNewFood(name: "", reviewedFood: current, location: .cupboard, amount: "5", unit: .count)
        XCTAssertNotNil(refreshedEditor.review)
        await refreshedEditor.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(refreshedEditor.notice, .saved)
        XCTAssertEqual(f.pickup.allocation?.demands.first { $0.id == changedNeed.id }?.allocated, try Rational(4))
    }

    func testActivePantryRejectsPreviouslyValidCopiedStockPreviewAndApply() async throws {
        let f = try await fixture(withNeed: true), old = try XCTUnwrap(f.oldReview)
        let before = f.pickup.pantrySnapshot, journeys = f.pickup.journeys
        XCTAssertThrowsError(try f.pickup.previewStockLot(old.lot, in: old.journeyID, replacing: old.original, scope: f.scope))
        XCTAssertFalse(f.pickup.isCurrentStockLotReview(old, scope: f.scope))
        let applied = await f.pickup.applyStockLotReview(old, scope: f.scope, confirmed: true)
        XCTAssertFalse(applied)
        XCTAssertEqual(f.pickup.pantrySnapshot?.state.revision, before?.state.revision)
        XCTAssertEqual(f.pickup.journeys, journeys)
        XCTAssertNil(try f.journal.read())
    }

    func testPendingAddRestoresOriginalBeforeEditingAndLiveAuthorityStillWins() async throws {
        let f = try await fixture()
        let editor = try XCTUnwrap(f.pickup.makePantryModel())
        await editor.load()
        await editor.prepareNewFood(name: "Milk", location: .fridge, amount: "", unit: .liter)
        let review = try XCTUnwrap(editor.review)
        let pending = try f.journal.save(command: review.command, reviewedInventoryRevision: review.before.state.revision)
        editor.accessLost()
        let restored = try XCTUnwrap(f.pickup.makePantryModel())
        await restored.load()
        XCTAssertEqual(restored.pending, pending)
        XCTAssertNil(restored.review, "Pending recovery does not fabricate the old preview")
        XCTAssertFalse(restored.canEdit)
        await restored.prepareNewFood(name: "Duplicate", location: .fridge, amount: "2", unit: .liter)
        XCTAssertEqual(restored.pending, pending); XCTAssertNil(restored.review)
        await restored.retryPending()
        XCTAssertEqual(restored.notice, .saved)
        XCTAssertEqual(restored.snapshot?.lots.map(\.id), [review.command.lotID])
        XCTAssertEqual(restored.snapshot?.lots.first?.count, .unknown)
        XCTAssertNil(try f.journal.read())
        f.authority.allowed = false
        XCTAssertNil(f.pickup.makePantryModel())
        await restored.prepareNewFood(name: "Denied", location: .fridge, amount: "1", unit: .liter)
        XCTAssertEqual(restored.phase, .accessDenied)
        XCTAssertNil(restored.snapshot); XCTAssertNil(restored.review)
        let refreshed = await f.pickup.refreshPantryStock()
        XCTAssertFalse(refreshed)
        XCTAssertTrue(f.pickup.pantryIsActive, "Access loss must not reopen the copied-stock route")
        XCTAssertThrowsError(try PickupPantryAddContext.resolve(model: f.pickup, ingredientID: nil))
    }
}
