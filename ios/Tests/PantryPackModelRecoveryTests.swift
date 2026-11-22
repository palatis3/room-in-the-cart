import XCTest
import CoreDomain
import LocalStore
import SQLite3
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
    private func fixture(privateDinnerActorID: UUID? = nil) async throws -> Fixture {
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
            pendingStore: pending, gate: gate, authorize: { state.allowed }, privateDinnerActorID: privateDinnerActorID))
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

    func testTonightChoiceRejectsRecountsAndCommitsOneReopenablePickupWithoutStockMutation() async throws {
        let f = try await fixture()
        try await f.ledger.configurePantryPackRecovery(f.port)
        let repository = PantryRepository(store: f.inventory, mutationGate: f.gate, authorize: { f.state.allowed })
        f.cleanup.track(repository)
        let lotID = UUID(), foodID = UUID()
        let initial = try await repository.load(at: now)
        let creation = InventoryCommand(id: UUID(), originID: f.inventory.workspaceID, lotID: lotID, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(InventoryLotSeed(foodID: foodID, name: "Rice",
                source: .manual(originID: f.inventory.workspaceID, sourceID: lotID), location: .cupboard,
                unit: .count, count: .exact(q(3))), observationID: UUID()))
        _ = try await repository.apply(creation, reviewedInventoryRevision: initial.state.revision, at: now)
        let ingredient = MealIngredient(name: "Rice", quantity: q(2))
        let meal = MealTemplate(title: "Rice bowls", ingredients: [ingredient])
        let stored = await f.ledger.change(key: "save-tonight-recipe") { $0.mealTemplates.append(meal) }
        XCTAssertTrue(stored)
        let identity = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        func prepare() async throws -> TonightPlanChoice.Review {
            let refreshed = await f.pickup.refreshPantryStock()
            XCTAssertTrue(refreshed)
            let context = try XCTUnwrap(f.pickup.pantryReviewContext())
            let supply = try DinnerPantrySupply.build(context: context, shopID: f.shop)
            let match = try PantryMealMatcher.review(recipe: meal, reviewedFoods: [ingredient.id: foodID],
                globallyFreeLots: supply.globallyFreeLots, unresolvedFoods: supply.unresolvedFoodIDs, profile: nil)
            return try TonightPlanChoice.prepare(match: match, pantryBasis: supply.basis, destinationShopID: nil,
                newShopTitle: "Tonight choice", ledger: f.ledger, pickup: f.pickup, currentIdentity: { identity })
        }
        let outdated = try await prepare()
        let before = f.ledger.workspace
        let originalStock = try await repository.load(at: now)
        let rice = try XCTUnwrap(originalStock.lots.first { $0.id == lotID })
        _ = try await repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: lotID, eventID: UUID(),
            expectedRevision: rice.revision, occurredAt: now, change: .count(.exact(q(2)), observationID: UUID())),
            reviewedInventoryRevision: originalStock.state.revision, at: now)
        let rejected = await TonightPlanChoice.apply(outdated, ledger: f.ledger, pickup: f.pickup, currentIdentity: { identity })
        XCTAssertFalse(rejected)
        XCTAssertEqual(f.ledger.workspace, before)
        let choice = try await prepare()
        let stockBefore = try await repository.load(at: now)
        let denied = await TonightPlanChoice.apply(choice, ledger: f.ledger, pickup: f.pickup, currentIdentity: { nil })
        XCTAssertFalse(denied)
        XCTAssertEqual(f.ledger.workspace, before)
        let saved = await TonightPlanChoice.apply(choice, ledger: f.ledger, pickup: f.pickup, currentIdentity: { identity })
        XCTAssertTrue(saved, f.ledger.error ?? "")
        let reopened = await reopen(f)
        let retried = await TonightPlanChoice.apply(choice, ledger: reopened, pickup: f.pickup, currentIdentity: { identity })
        XCTAssertTrue(retried, reopened.error ?? "")
        XCTAssertEqual(reopened.workspace.shops.count, before.shops.count + 1)
        XCTAssertEqual(reopened.shop?.mealOccurrences.map(\.title), ["Rice bowls"])
        XCTAssertEqual(reopened.workspace.dinnerPlanning.applyReceipts.count, 1)
        let stockAfter = try await repository.load(at: now)
        XCTAssertEqual(stockAfter.state, stockBefore.state)
    }

    func testReviewedLedgerRetryRechecksActionPermissionWithoutReplacingPendingBody() async throws {
        let f = try await fixture()
        try await f.ledger.configurePantryPackRecovery(f.port)
        let basis = try XCTUnwrap(review(f).canonicalStockEvidence?.basis)
        let repository = PantryRepository(store: f.inventory, mutationGate: f.gate, authorize: { true })
        f.cleanup.track(repository)
        let before = try await repository.load(at: now), lot = try XCTUnwrap(before.lots.first)
        let competingCommand = InventoryCommand(id: UUID(), originID: f.inventory.workspaceID, lotID: lot.id,
            eventID: UUID(), expectedRevision: lot.revision, occurredAt: now,
            change: .count(.someLeft, observationID: UUID()))
        var competingWrite: Task<Bool, Never>?
        var allowed = true
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.directory.appendingPathComponent("ledger.sqlite").path, &connection), SQLITE_OK)
        let lock = try XCTUnwrap(connection)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let originalRevision = f.ledger.revision
        let saved = await f.ledger.change(key: "reviewed carryover", reviewedPantryBasis: basis, authorize: {
            if competingWrite == nil {
                competingWrite = Task {
                    do {
                        _ = try await repository.apply(competingCommand, reviewedInventoryRevision: before.state.revision, at: self.now)
                        return false
                    } catch PantryMutationGate.Failure.busy { return true }
                    catch { return false }
                }
            }
            return allowed
        }) {
            $0.shops.append(ShoppingLedger(title: "Original reviewed destination"))
        }
        XCTAssertFalse(saved); XCTAssertTrue(f.ledger.hasPendingSave)
        let excluded = await competingWrite?.value
        XCTAssertEqual(excluded, true, "A count writer cannot enter while a stock-backed ledger save is suspended.")
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        allowed = false
        let denied = await f.ledger.retrySave()
        XCTAssertFalse(denied); XCTAssertTrue(f.ledger.hasPendingSave)
        let stillSaved = try await f.ledgerStore.load()
        XCTAssertEqual(stillSaved?.revision, originalRevision)
        allowed = true
        let retried = await f.ledger.retrySave()
        XCTAssertTrue(retried, f.ledger.error ?? "")
        XCTAssertEqual(f.ledger.revision, originalRevision + 1)
        XCTAssertEqual(f.ledger.workspace.shops.filter { $0.title == "Original reviewed destination" }.count, 1)
    }

    func testOrdinaryDinnerEditRejectsStalePantryBasisBeforePendingThenAcceptsFreshReview() async throws {
        let f = try await fixture()
        try await f.ledger.configurePantryPackRecovery(f.port)
        let basis = try XCTUnwrap(review(f).canonicalStockEvidence?.basis)
        let original = f.ledger.workspace, revision = f.ledger.revision
        try await recount(f)
        let rejected = await f.ledger.change(key: "reviewed-dinner", reviewedPantryBasis: basis) {
            $0.shops.append(ShoppingLedger(title: "Stale leftovers"))
        }
        XCTAssertFalse(rejected); XCTAssertFalse(f.ledger.hasPendingSave)
        XCTAssertEqual(f.ledger.workspace, original); XCTAssertEqual(f.ledger.revision, revision)
        let refreshed = await f.pickup.refreshPantryStock(); XCTAssertTrue(refreshed)
        let fresh = try XCTUnwrap(review(f).canonicalStockEvidence?.basis)
        XCTAssertNotEqual(fresh, basis)
        let saved = await f.ledger.change(key: "fresh-dinner", reviewedPantryBasis: fresh) {
            $0.shops.append(ShoppingLedger(title: "Reviewed leftovers"))
        }
        XCTAssertTrue(saved, f.ledger.error ?? "")
        XCTAssertEqual(f.ledger.revision, revision + 1)
        XCTAssertEqual(f.ledger.workspace.shops.last?.title, "Reviewed leftovers")
        f.state.allowed = false
        let denied = await f.ledger.change(key: "revoked-dinner", reviewedPantryBasis: fresh) {
            $0.shops.append(ShoppingLedger(title: "Denied"))
        }
        XCTAssertFalse(denied); XCTAssertFalse(f.ledger.ready); XCTAssertTrue(f.ledger.workspace.shops.isEmpty)
    }

    func testRealPackReviewSavesCanonicalChoiceAndExactRetryDoesNotWriteAgain() async throws {
        let f = try await fixture(), reviewed = try review(f)
        XCTAssertEqual(reviewed.request.confirmedAtHome?.amount, try Rational(4))
        XCTAssertEqual(try f.pickup.confirmedPackStock(shop: reviewed.sourceShop, lineID: f.food, bindings: [])?.amount, try Rational(4))
        let before = try await f.inventory.inventoryState()
        let saved = try await reviewed.save(offerID: "a", ledger: f.ledger, pickup: f.pickup)
        XCTAssertTrue(saved); XCTAssertFalse(f.ledger.hasPendingSave)
        XCTAssertEqual(f.ledger.workspace.packSelections.first?.formatVersion, 3)
        let selected = try XCTUnwrap(f.ledger.workspace.packSelections.first)
        XCTAssertTrue(f.pickup.isPackSelectionCurrent(selected, shop: reviewed.sourceShop,
            workspaceID: f.ledgerStore.workspaceID, bindings: []))
        XCTAssertNil(try f.journal.read())
        let revision = f.ledger.revision
        try await recount(f)
        let refreshed = await f.pickup.refreshPantryStock()
        XCTAssertTrue(refreshed)
        XCTAssertNil(try f.pickup.confirmedPackStock(shop: reviewed.sourceShop, lineID: f.food, bindings: []))
        XCTAssertFalse(f.pickup.isPackSelectionCurrent(selected, shop: reviewed.sourceShop,
            workspaceID: f.ledgerStore.workspaceID, bindings: []))
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

extension PantryPackModelRecoveryTests {
    func testBowlDinnerLinksPantryProductsAndAtomicallyRemovesOnlyTheirPurchases() async throws {
        try await reviewBowlDinner(thenCook: false)
    }

    func testRecordedBowlCookingKeepsSpentFoodOffTheReopenedListAndCheckoutUntilCookUndo() async throws {
        try await reviewBowlDinner(thenCook: true)
    }

    func testGrossDinnerDraftKeepsExactAllocationsAfterServingEditAndReopen() async throws {
        try await reviewBowlDinner(thenCook: true, keepDraft: true)
    }

    func testRecountAfterServingReviewPreservesOriginalCheckoutAndRequiresNewConfirmation() async throws {
        try await reviewBowlDinner(thenCook: true, keepDraft: true, recount: true)
    }

    func testInterruptedServingConfirmationCanResumeFromTheSameDraft() async throws {
        try await reviewBowlDinner(thenCook: true, keepDraft: true, interruptAfterSourceSave: true)
    }

    private func reviewBowlDinner(thenCook: Bool, keepDraft: Bool = false, recount: Bool = false,
                                 interruptAfterSourceSave: Bool = false) async throws {
        let actorID = UUID()
        let f = try await fixture(privateDinnerActorID: actorID)
        try await f.ledger.configurePantryPackRecovery(f.port)
        let pantry = PantryRepository(store: f.inventory, mutationGate: f.gate, authorize: { f.state.allowed })
        f.cleanup.track(pantry)
        let actor = CapturePrivateIdentity(actorID: actorID, subject: nil, householdID: nil, memberID: nil, role: nil)
        let origin = f.inventory.workspaceID, workspaceID = f.ledgerStore.workspaceID
        func cups(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .cup, originalLiteral: String(n)) }
        let rice = UUID(), lentils = UUID(), riceLot = UUID(), lentilLot = UUID()
        for (product, lot, name, quantity) in [(rice, riceLot, "Rice", cups(3)), (lentils, lentilLot, "Lentils", cups(2))] {
            let before = try await pantry.load(at: now)
            _ = try await pantry.apply(.init(id: UUID(), originID: origin, lotID: lot, eventID: UUID(), expectedRevision: nil,
                occurredAt: now, change: .create(.init(foodID: product, name: name, source: .manual(originID: origin, sourceID: UUID()),
                    location: .cupboard, unit: .cup, count: .exact(quantity)), observationID: UUID())),
                reviewedInventoryRevision: before.state.revision, at: now)
        }
        var market = ShoppingLedger(title: "After work market", basis: .init(branch: "Main", timeZoneIdentifier: "America/New_York"))
        _ = try market.addManualLine(name: "Coffee", quantity: q(2))
        let recipe = MealTemplate(title: "Lentil and tomato bowls", ingredients: [
            .init(name: "Lentils", quantity: cups(1)), .init(name: "Tomatoes", quantity: q(2)), .init(name: "Rice", quantity: cups(1))])
        let weekend = ShoppingLedger(title: "Weekend market")
        let seeded = await f.ledger.change(key: "bowl-ingredients") {
            $0.shops.append(contentsOf: [market, weekend]); $0.selectedShopID = market.id; $0.mealTemplates.append(recipe)
        }
        XCTAssertTrue(seeded)
        let refreshed = await f.pickup.refreshPantryStock()
        XCTAssertTrue(refreshed)
        let context = try XCTUnwrap(f.pickup.quickGroceryPantryContext(ledgerWorkspaceID: workspaceID))
        let input = try TonightMealModel.input(workspace: f.ledger.workspace, ledgerRevision: f.ledger.revision, context: context, sources: [])
        let match = try PantryMealMatcher.review(recipe: recipe,
            reviewedFoods: [recipe.ingredients[0].id: lentils, recipe.ingredients[2].id: rice],
            globallyFreeLots: input.freeLots, unresolvedFoods: input.unresolvedFoods, profile: nil)
        let access = DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: actor.actorID.uuidString, shopID: market.id,
            assignedShopperID: actor.actorID.uuidString, canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0,
            verifiedAt: now, validUntil: now.addingTimeInterval(30))
        let earlier = ShoppingLedger(title: "Previous dinner")
        let earlierAccess = DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: actor.actorID.uuidString,
            shopID: earlier.id, assignedShopperID: actor.actorID.uuidString, canPlan: true, canReadBudget: false,
            hasPaidTools: false, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(30))
        let canceled = await f.ledger.change(key: "cancel-earlier-dinner", reviewedPantryBasis: context.dinnerBasis,
            authorize: { f.state.allowed }) { workspace in
            let index = workspace.shops.count
            workspace.shops.append(earlier)
            workspace.selectedShopID = earlier.id
            let old = try SavedDinnerReview(recipe: recipe, action: .planTonight, workspace: workspace, access: earlierAccess,
                phase: .draft, at: self.now, pantryReview: (match, origin), reservedFoods: context.reservedFoods)
            try old.apply(to: &workspace, access: earlierAccess, phase: .draft, at: self.now)
            try workspace.shops[index].removeMeal(occurrenceID: XCTUnwrap(old.occurrenceID), at: self.now)
            workspace.selectedShopID = market.id
        }
        XCTAssertTrue(canceled)
        let priorList = try XCTUnwrap(f.ledger.workspace.shops.first { $0.id == earlier.id })
        XCTAssertTrue(priorList.contributions(forLineID: rice).isEmpty)
        XCTAssertFalse(f.pickup.journeys.contains { $0.id == earlier.id })
        let choice = try SavedDinnerReview(recipe: recipe, action: .plan(day: MealDay(date: now, timeZoneIdentifier: market.basis.timeZoneIdentifier),
            servings: Rational(thenCook ? 2 : 3)), workspace: f.ledger.workspace, access: access, phase: .draft, at: now, pantryReview: (match, origin))
        let stock = try await pantry.load(at: now)
        let planned = await f.ledger.change(key: "bowls", reviewedPantryBasis: context.dinnerBasis, authorize: { f.state.allowed }) {
            try choice.apply(to: &$0, access: access, phase: .draft, at: self.now)
        }
        XCTAssertTrue(planned)
        let justPlanned = try await pantry.load(at: now)
        XCTAssertEqual(justPlanned.lots, stock.lots)
        XCTAssertEqual(justPlanned.reservations, stock.reservations)
        let shop = try XCTUnwrap(f.ledger.shop), occurrence = try XCTUnwrap(choice.occurrenceID)
        let allocation = try DinnerAllocationChoice(ledger: f.ledger, pickup: f.pickup, shop: shop, occurrenceID: occurrence,
            identity: actor, linked: [rice, lentils])
        let originalRice = try XCTUnwrap(justPlanned.lots.first { $0.id == riceLot })
        _ = try await pantry.apply(.init(id: UUID(), originID: origin, lotID: riceLot, eventID: UUID(), expectedRevision: originalRice.revision,
            occurredAt: now, change: .count(.exact(cups(3)), observationID: UUID())),
            reviewedInventoryRevision: justPlanned.state.revision, at: now)
        do {
            let stale = try await LedgerCheckoutAdapter.apply(allocation.checkout, ledger: f.ledger, pickup: f.pickup,
                freshDinnerBasis: allocation.basis, authorize: { true })
            XCTAssertFalse(stale)
        } catch { XCTAssertEqual(error as? LedgerCheckoutError, .staleSource) }
        XCTAssertFalse(f.pickup.journeys.contains { $0.id == market.id })
        let checked = await f.pickup.refreshPantryStock()
        XCTAssertTrue(checked)
        let freshAllocation = try DinnerAllocationChoice(ledger: f.ledger, pickup: f.pickup, shop: shop, occurrenceID: occurrence,
            identity: actor, linked: [rice, lentils])
        let physicalBefore = try await pantry.load(at: now)
        XCTAssertEqual(physicalBefore.reservations, justPlanned.reservations)
        let gross = freshAllocation.checkout
        XCTAssertEqual(gross.lines.count, 4)
        let allocated = try await LedgerCheckoutAdapter.apply(gross, ledger: f.ledger, pickup: f.pickup,
            freshDinnerBasis: freshAllocation.basis, authorize: { true })
        XCTAssertTrue(allocated, f.pickup.error ?? "")
        let beforeChoices = try await pantry.load(at: now)
        let reusedClaims = beforeChoices.reservations.filter { [rice, lentils].contains($0.foodID) && $0.state != .released }
        XCTAssertEqual(reusedClaims.count, 2)
        XCTAssertEqual(Set(reusedClaims.map(\.foodID)), [rice, lentils])
        XCTAssertEqual(beforeChoices.lots, physicalBefore.lots)
        func decision() throws -> DinnerPurchaseDecision {
            try DinnerPurchaseDecision(ledger: f.ledger, pickup: f.pickup, shop: shop, occurrenceID: occurrence,
                identity: actor, linked: [lentils, rice])
        }
        let expired = try decision()
        let lot = try XCTUnwrap(beforeChoices.lots.first { $0.id == lentilLot })
        _ = try await pantry.apply(.init(id: UUID(), originID: origin, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.exact(cups(2)), observationID: UUID())),
            reviewedInventoryRevision: beforeChoices.state.revision, at: now)
        let rejected = await expired.save(ledger: f.ledger, authorize: { true })
        XCTAssertFalse(rejected)
        XCTAssertTrue(f.ledger.workspace.packSelections.isEmpty)
        let fresh = await f.pickup.refreshPantryStock()
        XCTAssertTrue(fresh)
        let confirmed = try decision()
        let denied = await confirmed.save(ledger: f.ledger, authorize: { false })
        XCTAssertFalse(denied)
        let saved = await confirmed.save(ledger: f.ledger, authorize: { true })
        XCTAssertTrue(saved, f.ledger.error ?? "")
        let revision = f.ledger.revision
        let replay = await confirmed.save(ledger: f.ledger, authorize: { true })
        XCTAssertTrue(replay); XCTAssertEqual(f.ledger.revision, revision)
        var reopened = await reopen(f)
        let reopenedShop = try XCTUnwrap(reopened.shop)
        let covered = DinnerPantryPurchases.lines(ledger: reopened, pickup: f.pickup, shop: reopenedShop, identity: actor)
        XCTAssertEqual(covered, [lentils, rice])
        XCTAssertEqual(reopened.workspace.listLayout.groups(shop: reopenedShop, excluding: covered).flatMap(\.lines).map(\.name),
            ["Coffee", "Tomatoes"])
        XCTAssertTrue(DinnerPantryPurchases.lines(ledger: reopened, pickup: f.pickup, shop: reopenedShop, identity: nil).isEmpty)
        let live = try XCTUnwrap(f.pickup.quickGroceryPantryContext(ledgerWorkspaceID: workspaceID))
        let net = try LedgerCheckoutAdapter.review(shop: reopenedShop, workspaceRevision: reopened.revision,
            previous: f.pickup.journeys.first { $0.id == market.id }, packSelections: reopened.workspace.packSelections,
            workspaceID: workspaceID, pickupWorkspaceID: origin, pantryContext: live, pantryIsActive: true)
        XCTAssertEqual(net.lines.map(\.name), ["Coffee", "Tomatoes"])
        XCTAssertEqual(net.needs, gross.needs)
        if !keepDraft {
            let savedBasket = try await LedgerCheckoutAdapter.apply(net, ledger: reopened, pickup: f.pickup)
            XCTAssertTrue(savedBasket, f.pickup.error ?? "")
        }
        let persisted = try XCTUnwrap(f.pickup.journeys.first { $0.id == market.id })
        XCTAssertEqual(persisted.basket?.current.lines, keepDraft ? gross.lines : net.lines)
        XCTAssertEqual(persisted.plannedNeeds, gross.needs)
        let retained = DinnerPantryPurchases.lines(ledger: reopened, pickup: f.pickup, shop: reopenedShop, identity: actor)
        XCTAssertEqual(retained, covered)
        if thenCook {
            let currentMeal = try XCTUnwrap(reopenedShop.mealOccurrences.first { $0.id == occurrence })
            XCTAssertEqual(currentMeal.servings, try Rational(2))
            let displayedAmounts = try currentMeal.ingredientContributionIDs.map { id in
                let ingredient = try XCTUnwrap(reopenedShop.contributions.first { $0.id == id })
                let editor = DinnerIngredientDraft(MealIngredient(id: id, name: ingredient.productName, quantity: ingredient.quantity))
                return DinnerQuantityEdit(contributionID: id, quantity: try editor.reviewedQuantity())
            }
            let adjustment = DinnerAdjustment(occurrenceID: occurrence, servings: try Rational(3),
                groups: currentMeal.servingGroups, quantities: displayedAmounts, scheduledDay: currentMeal.scheduledDay)
            let edited = await reopened.change(key: "change-servings-only") { workspace in
                let index = try XCTUnwrap(workspace.shops.firstIndex { $0.id == shop.id })
                let preview = try DinnerPlanningEngine.preview(changes: [.adjust(adjustment)], tool: .manual,
                    ledger: workspace.shops[index], state: workspace.dinnerPlanning, access: access, phase: .draft, at: self.now)
                _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &workspace.shops[index], state: &workspace.dinnerPlanning,
                    access: access, phase: .draft, at: self.now)
            }
            XCTAssertTrue(edited, reopened.error ?? "")
            let revised = try XCTUnwrap(reopened.shop)
            XCTAssertEqual(revised.contributions, reopenedShop.contributions)
            let afterEdit = DinnerPantryPurchases.lines(ledger: reopened, pickup: f.pickup, shop: revised, identity: actor)
            XCTAssertTrue(afterEdit.isEmpty)
            let pending = DinnerPantryPurchases.pending(in: reopened.workspace, shop: revised, workspaceID: workspaceID,
                originID: origin, actorID: actorID, journey: persisted, covered: afterEdit)
            XCTAssertEqual(pending.map(\.id), [occurrence])
            XCTAssertEqual(pending.map(\.servingsChanged), [true])
            XCTAssertEqual(Set(pending.flatMap { $0.lines.map(\.id) }), [rice, lentils])
            XCTAssertTrue(DinnerPantryPurchases.pending(in: reopened.workspace, shop: revised, workspaceID: workspaceID,
                originID: origin, actorID: UUID(), journey: persisted, covered: []).isEmpty)
            if keepDraft {
                let resumed = await reopen(f)
                let review = try DinnerServingAllocationReview(ledger: resumed, pickup: f.pickup, shop: revised,
                    occurrenceID: occurrence, identity: actor, linked: [rice, lentils])
                let wrongActor = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
                XCTAssertThrowsError(try DinnerServingAllocationReview(ledger: resumed, pickup: f.pickup, shop: revised,
                    occurrenceID: occurrence, identity: wrongActor, linked: [rice, lentils]))
                let refused = try await review.save(ledger: resumed, pickup: f.pickup, authorize: { false })
                XCTAssertFalse(refused)
                XCTAssertEqual(f.pickup.journeys.first { $0.id == shop.id }, persisted)
                if recount {
                    let current = try await pantry.load(at: now)
                    let lot = try XCTUnwrap(current.lots.first { $0.id == riceLot })
                    _ = try await pantry.apply(.init(id: UUID(), originID: origin, lotID: riceLot, eventID: UUID(),
                        expectedRevision: lot.revision, occurredAt: now, change: .count(.exact(cups(3)), observationID: UUID())),
                        reviewedInventoryRevision: current.state.revision, at: now)
                    let accepted = try? await review.save(ledger: resumed, pickup: f.pickup, authorize: { true })
                    XCTAssertNotEqual(accepted, true)
                    XCTAssertEqual(f.pickup.journeys.first { $0.id == shop.id }, persisted)
                    let refreshed = await f.pickup.refreshPantryStock()
                    XCTAssertTrue(refreshed)
                    XCTAssertThrowsError(try DinnerServingAllocationReview(ledger: resumed, pickup: f.pickup, shop: revised,
                        occurrenceID: occurrence, identity: actor, linked: [rice, lentils]))
                    return
                }
                if interruptAfterSourceSave {
                    let updated = try await f.pickup.saveDinnerServingSource(review, ledger: resumed, authorize: { true })
                    XCTAssertTrue(updated)
                    let cold = await reopen(f)
                    let pendingStore = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
                        inventoryWorkspaceID: origin, ledgerWorkspaceID: workspaceID)
                    let pickup = PickupModel(store: f.inventory, clock: { self.now }, pantry: .init(ledger: f.ledgerStore,
                        pendingStore: pendingStore, gate: f.gate, authorize: { f.state.allowed }, privateDinnerActorID: actorID))
                    f.cleanup.track(pickup)
                    await pickup.load()
                    XCTAssertEqual(pickup.journeys.first { $0.id == shop.id }?.basket, persisted.basket)
                    XCTAssertTrue(DinnerPantryPurchases.lines(ledger: cold, pickup: pickup, shop: revised, identity: actor).isEmpty)
                    let decision = try DinnerPurchaseDecision(ledger: cold, pickup: pickup, shop: revised,
                        occurrenceID: occurrence, identity: actor, linked: [rice, lentils])
                    let saved = await decision.save(ledger: cold, authorize: { true })
                    XCTAssertTrue(saved)
                    XCTAssertEqual(DinnerPantryPurchases.lines(ledger: cold, pickup: pickup, shop: revised,
                        identity: actor), [rice, lentils])
                    return
                }
                let kept = try await review.save(ledger: resumed, pickup: f.pickup, authorize: { true })
                XCTAssertTrue(kept, f.pickup.error ?? resumed.error ?? "")
                let result = try XCTUnwrap(f.pickup.journeys.first { $0.id == shop.id })
                XCTAssertEqual(result.basket, persisted.basket)
                XCTAssertEqual(result.context, persisted.context)
                XCTAssertEqual(result.plannedNeeds, persisted.plannedNeeds)
                let snapshot = try await pantry.load(at: now)
                XCTAssertEqual(snapshot.reservations, beforeChoices.reservations)
                reopened = await reopen(f)
                XCTAssertEqual(DinnerPantryPurchases.lines(ledger: reopened, pickup: f.pickup, shop: revised,
                    identity: actor), [rice, lentils])
                let active = reopened.workspace.listLayout.groups(shop: revised, excluding: [rice, lentils])
                XCTAssertEqual(active.flatMap(\.lines).map(\.name), ["Coffee", "Tomatoes"])
            } else {
                XCTAssertThrowsError(try DinnerServingAllocationReview(ledger: reopened, pickup: f.pickup, shop: revised,
                    occurrenceID: occurrence, identity: actor, linked: [rice, lentils]))
                let allocationContext = try XCTUnwrap(f.pickup.quickGroceryPantryContext(ledgerWorkspaceID: workspaceID))
                let freshCheckout = try LedgerCheckoutAdapter.review(shop: revised, workspaceRevision: reopened.revision, previous: persisted,
                    packSelections: f.pickup.dinnerAuthorizedPacks(reopened.workspace.packSelections, ledger: reopened, shop: revised),
                    workspaceID: workspaceID, pickupWorkspaceID: origin, pantryContext: allocationContext, pantryIsActive: true,
                    dinnerWorkspace: reopened.workspace, dinnerActorID: actorID)
                let reapplied = try await LedgerCheckoutAdapter.apply(freshCheckout, ledger: reopened, pickup: f.pickup)
                XCTAssertTrue(reapplied, f.pickup.error ?? "")
                let reconfirm = try DinnerPurchaseDecision(ledger: reopened, pickup: f.pickup, shop: revised, occurrenceID: occurrence,
                    identity: actor, linked: [rice, lentils])
                let reselected = await reconfirm.save(ledger: reopened, authorize: { true })
                XCTAssertTrue(reselected, reopened.error ?? "")
            }
            let available = DinnerPantryPurchases.lines(ledger: reopened, pickup: f.pickup, shop: revised, identity: actor)
            XCTAssertEqual(available, [rice, lentils])
            let freshJourney = try XCTUnwrap(f.pickup.journeys.first { $0.id == market.id })
            XCTAssertTrue(DinnerPantryPurchases.pending(in: reopened.workspace, shop: revised, workspaceID: workspaceID,
                originID: origin, actorID: actorID, journey: freshJourney, covered: available).isEmpty)
            let afterServingReview = try await pantry.load(at: now)
            XCTAssertEqual(afterServingReview.lots.first { $0.id == lentilLot }?.count, .exact(cups(2)))
            XCTAssertEqual(afterServingReview.lots.first { $0.id == riceLot }?.count, .exact(cups(3)))
            let cook = PantryCookPort(store: f.inventory, ledger: f.ledgerStore, gate: f.gate, authorize: { f.state.allowed }, clock: { self.now })
            let initial = try await cook.load(shopID: shop.id, mealID: occurrence)
            let used = Quantity(amount: try Rational(3, 2), unit: .cup, originalLiteral: "1.5")
            let rows = initial.meal.ingredientContributionIDs
            let lentilBatch = try XCTUnwrap(initial.inventory.lots.first { $0.id == lentilLot })
            let riceBatch = try XCTUnwrap(initial.inventory.lots.first { $0.id == riceLot })
            let draft = CookCompletionDraft(inventoryID: origin, inventoryRevision: initial.inventory.state.revision, ledgerID: workspaceID,
                shop: revised, meal: initial.meal, cookedAt: now, servingsMade: try Rational(3), parts: [
                    .init(contributionID: rows[0], use: .lot(id: lentilLot, revision: lentilBatch.revision, amount: used)),
                    .init(contributionID: rows[1], use: .notUsed),
                    .init(contributionID: rows[2], use: .lot(id: riceLot, revision: riceBatch.revision, amount: used))
                ], leftovers: [])
            let review = try await cook.review(draft)
            try await cook.apply(review)
            try await cook.apply(review)
            let store = try ComparisonStore(url: f.directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
            f.cleanup.track(store)
            let coldPending = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
                inventoryWorkspaceID: origin, ledgerWorkspaceID: workspaceID)
            let cold = PickupModel(store: store, clock: { self.now }, pantry: .init(ledger: f.ledgerStore, pendingStore: coldPending,
                gate: f.gate, authorize: { f.state.allowed }, privateDinnerActorID: actorID))
            f.cleanup.track(cold)
            await cold.load()
            let coldLedger = await reopen(f)
            cold.bindCookLedger(coldLedger)
            let coldShop = try XCTUnwrap(coldLedger.shop)
            let cooked = try XCTUnwrap(cold.journeys.first { $0.id == shop.id })
            let context = try XCTUnwrap(cold.quickGroceryPantryContext(ledgerWorkspaceID: workspaceID))
            XCTAssertEqual(cooked.cookedMeals?.count, 1)
            XCTAssertEqual(context.snapshot.lots.first { $0.id == lentilLot }?.count.quantity?.amount, try Rational(1, 2))
            XCTAssertEqual(context.snapshot.lots.first { $0.id == riceLot }?.count.quantity?.amount, try Rational(3, 2))
            let usedForDinner = cooked.usedDinnerPantryLines(in: coldShop, workspace: coldLedger.workspace, workspaceID: workspaceID,
                actorID: actorID, context: context)
            XCTAssertEqual(usedForDinner, [rice, lentils])
            XCTAssertEqual(coldLedger.workspace.listLayout.groups(shop: coldShop, excluding: usedForDinner).flatMap(\.lines).map(\.name),
                ["Coffee", "Tomatoes"])
            let afterCook = try LedgerCheckoutAdapter.review(shop: coldShop, workspaceRevision: coldLedger.revision, previous: cooked,
                packSelections: cold.dinnerAuthorizedPacks(coldLedger.workspace.packSelections, ledger: coldLedger, shop: coldShop),
                workspaceID: workspaceID, pickupWorkspaceID: origin, pantryContext: context, pantryIsActive: true,
                dinnerWorkspace: coldLedger.workspace, dinnerActorID: cold.currentDinnerActorID)
            XCTAssertEqual(afterCook.lines.map(\.name), ["Coffee", "Tomatoes"])
            XCTAssertEqual(afterCook.needs, gross.needs)
            XCTAssertEqual(coldShop.mealOccurrences, revised.mealOccurrences)
            let savedAfterCooking = try await LedgerCheckoutAdapter.apply(afterCook, ledger: coldLedger, pickup: cold)
            XCTAssertTrue(savedAfterCooking, cold.error ?? "")
            cold.selectedID = shop.id
            XCTAssertTrue(cold.hasCurrentBasketStockBasis)
            let savedCopy = try XCTUnwrap(cold.journey)
            let savedCook = try XCTUnwrap(savedCopy.cookedMeals?.first)
            let source = try XCTUnwrap(savedCopy.mealSource)
            XCTAssertEqual(Set(savedCook.fulfilledPurchaseNeeds(in: source).keys), [rows[0], rows[2]])
            XCTAssertEqual(savedCopy.cookPurchaseOmissions, [lentils, rice])
            var unproven = savedCopy
            let dropped = try XCTUnwrap(savedCook.fulfilledNeeds.first)
            let wrongFood = StockNeed(id: dropped.id, foodID: UUID(), name: dropped.name, amount: dropped.amount, priority: dropped.priority)
            let missingProof = PantryCookRecord(draft: savedCook.draft, priorCounts: savedCook.priorCounts,
                priorClaims: savedCook.priorClaims, fulfilledNeeds: [wrongFood] + savedCook.fulfilledNeeds.dropFirst(),
                resultingObservations: savedCook.resultingObservations)
            unproven.cookedMeals = [missingProof]
            XCTAssertNil(missingProof.fulfilledPurchaseNeeds(in: source)[dropped.id])
            XCTAssertThrowsError(try PickupModel.validate(unproven))
            let reversed = try await cook.reviewUndo(shopID: shop.id, mealID: occurrence)
            try await cook.applyUndo(reversed)
            let refreshed = await cold.refreshPantryStock()
            XCTAssertTrue(refreshed)
            let afterUndo = try XCTUnwrap(cold.journeys.first { $0.id == shop.id })
            let undoneContext = try XCTUnwrap(cold.quickGroceryPantryContext(ledgerWorkspaceID: workspaceID))
            XCTAssertFalse(cold.hasCurrentBasketStockBasis, "The earlier checkout omitted ingredients whose cook was undone.")
            XCTAssertTrue(afterUndo.usedDinnerPantryLines(in: coldShop, workspace: coldLedger.workspace, workspaceID: workspaceID,
                actorID: actorID, context: undoneContext).isEmpty)
            XCTAssertEqual(undoneContext.snapshot.lots.first { $0.id == lentilLot }?.count, .exact(cups(2)))
            return
        }
        let undone = await DinnerPurchaseDecision.restore(retained, shop: reopenedShop, occurrenceID: occurrence,
            ledger: reopened, pickup: f.pickup, identity: actor, authorize: { true })
        XCTAssertTrue(undone, reopened.error ?? "")
        XCTAssertTrue(reopened.workspace.packSelections.isEmpty)
        XCTAssertTrue(DinnerPantryPurchases.lines(ledger: reopened, pickup: f.pickup, shop: reopenedShop, identity: actor).isEmpty)
        XCTAssertEqual(reopened.shop?.mealOccurrences, shop.mealOccurrences)
        XCTAssertEqual(reopened.workspace.shops.first { $0.id == weekend.id }, weekend)
        XCTAssertEqual(reopened.workspace.shops.first { $0.id == earlier.id }, priorList)
        let after = try await pantry.load(at: now)
        XCTAssertEqual(after.reservations, beforeChoices.reservations)
        XCTAssertEqual(after.lots.first { $0.id == riceLot }?.count, .exact(cups(3)))
        XCTAssertEqual(after.lots.first { $0.id == lentilLot }?.count, .exact(cups(2)))
    }
}
