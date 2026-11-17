import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class DinnerPantrySupplyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64) -> Quantity { .init(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let directory: URL
        let store: ComparisonStore
        let repository: PantryRepository
        let mapping: PantryLegacyMigration.Plan
    }
    private func activate(_ journeys: [PickupJourney]) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        for journey in journeys {
            try PickupModel.validate(journey)
            _ = try await store.save(id: journey.id, title: "Dinner fixture", payload: JSONEncoder().encode(journey), savedAt: journey.savedAt)
        }
        let mapping = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: try await store.list().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await store.inventorySourceToken(),
            inventoryRevision: await store.inventoryState().revision, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: store, authorize: { true })
        cleanup.track(repository)
        return .init(cleanup: cleanup, directory: directory, store: store, repository: repository, mapping: mapping)
    }
    private func supply(_ f: Fixture, shopID: UUID) async throws -> DinnerPantrySupply.Snapshot {
        try DinnerPantrySupply.build(context: .init(snapshot: await f.repository.load(at: now), mapping: f.mapping, asOf: now), shopID: shopID)
    }
    private func recount(_ f: Fixture, lotID: UUID, count: InventoryCount) async throws {
        let before = try await f.repository.load(at: now), lot = try XCTUnwrap(before.lots.first { $0.id == lotID })
        _ = try await f.repository.apply(.init(id: UUID(), originID: f.store.workspaceID, lotID: lotID, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(count, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
    }
    private func add(_ f: Fixture, foodID: UUID, count: InventoryCount) async throws -> UUID {
        let before = try await f.repository.load(at: now), id = UUID()
        _ = try await f.repository.apply(.init(id: UUID(), originID: f.store.workspaceID, lotID: id,
            eventID: UUID(), expectedRevision: nil, occurredAt: now,
            change: .create(.init(foodID: foodID, name: "Wraps", source: .manual(originID: f.store.workspaceID, sourceID: id),
                location: .fridge, unit: .count, count: count), observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
        return id
    }
    private func idea(shop: ShoppingLedger, workspaceID: UUID, foodID: UUID) -> DinnerIdeaDraft {
        let ingredient = MealIngredient(name: "Wraps", quantity: q(4))
        var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "manual", template: .init(title: "Dinner", ingredients: [ingredient]), createdAt: now)
        idea.supplyEvidence = [.init(ingredient: ingredient, workspaceID: workspaceID, shopID: shop.id,
            basisRevision: shop.basisRevision, foodID: foodID, pack: nil, source: nil, observedAt: nil)]
        return idea
    }

    func testIdeaAndLeftoversUseRecountAndAllShopClaimsWithoutDoubleSubtracting() async throws {
        let shop = ShoppingLedger(), food = UUID(), scope = UUID()
        var first = PickupJourney(id: shop.id, savedAt: now)
        first.stockLots = [.init(id: food, foodID: food, name: "Wraps", usable: q(8), confirmedAt: now, source: .pantry)]
        first.stockNeeds = [.init(id: UUID(), foodID: food, name: "Existing dinner", amount: q(3), priority: .required)]
        var second = PickupJourney(id: UUID(), savedAt: now)
        second.originShopID = first.id; second.stockLots = first.stockLots
        second.stockNeeds = [.init(id: UUID(), foodID: food, name: "Other pickup lunch", amount: q(2), priority: .protected)]
        let f = try await activate([first, second]), initial = try await supply(f, shopID: shop.id)
        var workspace = LedgerWorkspace(); workspace.shops = [shop]
        func row(_ canonical: DinnerPantrySupply.Snapshot) throws -> IdeaSupplyRow {
            try XCTUnwrap(DinnerIdeaSupplyReview.rows(idea: idea(shop: shop, workspaceID: scope, foodID: food),
                shop: shop, workspace: workspace, workspaceID: scope, journey: first, canonical: canonical, at: now).first)
        }
        XCTAssertEqual(try row(initial).credited, q(3))
        XCTAssertEqual(try row(initial).uncovered, q(1))
        XCTAssertEqual(Set(try row(initial).reservations.map(\.name)), ["Existing dinner", "Other pickup lunch"])
        let leftovers = DinnerLibraryPairings.unreservedLots(canonical: initial)
        XCTAssertEqual(leftovers.count, 1); XCTAssertEqual(leftovers.first?.usable, q(3))
        XCTAssertNotEqual(leftovers.first?.id, first.stockLots.first?.id, "Global rows keep physical canonical IDs, not copied aliases")
        XCTAssertEqual(initial.basis.sourceHeads.count, 2)
        let lot = try XCTUnwrap(leftovers.first)
        try await recount(f, lotID: lot.id, count: .exact(q(4)))
        let changed = try await supply(f, shopID: shop.id)
        XCTAssertNotEqual(changed.basis, initial.basis)
        XCTAssertEqual(changed.basis.sourceHeads, initial.basis.sourceHeads, "A standalone recount need not edit any pickup")
        XCTAssertEqual(try row(changed).credited, q(0))
        XCTAssertTrue(DinnerLibraryPairings.unreservedLots(canonical: changed).isEmpty)
        XCTAssertEqual(first.stockLots.first?.usable, q(8), "Historical copies are not rewritten")
    }

    func testNoJourneyPantryAndQualitativeObservationNeverUseOldNumericCount() async throws {
        let f = try await activate([]), shop = ShoppingLedger(), food = UUID(), scope = UUID()
        let lot = try await add(f, foodID: food, count: .exact(q(6)))
        let initial = try await supply(f, shopID: shop.id)
        XCTAssertTrue(initial.basis.sourceHeads.isEmpty)
        XCTAssertEqual(initial.globallyFreeLots.first?.id, lot)
        XCTAssertEqual(initial.globallyFreeLots.first?.usable, q(6))
        var workspace = LedgerWorkspace(); workspace.shops = [shop]
        try await recount(f, lotID: lot, count: .someLeft)
        let changed = try await supply(f, shopID: shop.id)
        XCTAssertTrue(changed.globallyFreeLots.isEmpty)
        XCTAssertTrue(changed.foods.first?.detail.contains(pantryText("Some left — amount unknown")) == true)
        XCTAssertTrue(changed.foods.first?.detail.contains(pantryLocationName(.fridge)) == true)
        let row = try XCTUnwrap(DinnerIdeaSupplyReview.rows(idea: idea(shop: shop, workspaceID: scope, foodID: food),
            shop: shop, workspace: workspace, workspaceID: scope, journey: nil, canonical: changed, at: now).first)
        XCTAssertNil(row.credited); XCTAssertNil(row.uncovered)
        let heads = try await f.store.list(); XCTAssertTrue(heads.isEmpty, "Reading dinner supply never fabricates a pickup")
    }

    func testNoJourneyNamedProtectedNeedConsumesOnlyPreviouslyUnreservedSupply() async throws {
        let f = try await activate([]), scope = UUID()
        var shop = ShoppingLedger()
        let food = try shop.addManualLine(name: "Wraps", quantity: q(6))
        let manual = try XCTUnwrap(shop.contributions(forLineID: food).first)
        try shop.addProtectedNeed(name: "Wraps", quantity: q(2), purpose: "School lunch", within: manual.id)
        _ = try await add(f, foodID: food, count: .exact(q(3)))
        let canonical = try await supply(f, shopID: shop.id)
        var workspace = LedgerWorkspace(); workspace.shops = [shop]
        let row = try XCTUnwrap(DinnerIdeaSupplyReview.rows(idea: idea(shop: shop, workspaceID: scope, foodID: food),
            shop: shop, workspace: workspace, workspaceID: scope, journey: nil, canonical: canonical, at: now).first)
        XCTAssertEqual(row.credited, q(1)); XCTAssertEqual(row.uncovered, q(3))
        XCTAssertEqual(row.reservations.map(\.name), ["School lunch"])
        XCTAssertEqual(canonical.globallyFreeLots.first?.usable, q(3), "Preview does not reserve stock")
    }

    func testActualDinnerApplyRejectsIndependentInventoryEditThenFreshReviewSaves() async throws {
        let f = try await activate([]), instant = now, gate = PantryMutationGate()
        let food = UUID(), lot = try await add(f, foodID: food, count: .exact(q(6)))
        let ledgerURL = f.directory.appendingPathComponent("ledger.sqlite")
        let ledger = LedgerModel(databaseURL: ledgerURL, clock: { instant }, inventoryProjectionsEnabled: true, mutationGate: gate)
        await ledger.open()
        let shop = ShoppingLedger(title: "Tonight", basis: .init(timeZoneIdentifier: "America/New_York"))
        let saved = await ledger.change(key: "dinner-fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(saved)
        let ledgerStore = try LedgerStore(url: ledgerURL, inventoryProjectionsEnabled: true)
        let pending = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: f.store.workspaceID, ledgerWorkspaceID: ledgerStore.workspaceID)
        var allowed = true
        let pickup = PickupModel(store: f.store, clock: { instant }, pantry: .init(ledger: ledgerStore,
            pendingStore: pending, gate: gate, authorize: { allowed }))
        pickup.bindCookLedger(ledger); await pickup.load()
        f.cleanup.track(ledger, ledgerStore, pickup)
        try await ledger.configurePantryPackRecovery(pickup.makePantryPackSelectionPort())
        let model = DinnerFeatureModel(store: ledger, access: { id in
            .init(scope: .local(workspaceID: ledgerStore.workspaceID), actorID: "local", shopID: id,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: true,
                roleRevision: 0, verifiedAt: instant, validUntil: instant.addingTimeInterval(3600))
        }, phase: { _ in .draft }, clock: { instant })
        let template = MealTemplate(title: "Wraps", ingredients: [.init(name: "Wraps", quantity: q(4))])
        let acceptedID = UUID()
        let accepted = await model.accept(template, id: acceptedID, fallback: false)
        XCTAssertTrue(accepted, model.error ?? ledger.error ?? "")
        let reviewed = try XCTUnwrap(DinnerPantrySupply.read(pickup: pickup, workspaceID: ledger.sourceWorkspaceID,
            linkedWorkspaceID: ledger.sourceWorkspaceID, shopID: shop.id))
        let change = DinnerLedgerChange.choose(.init(acceptedDinnerID: acceptedID, template: template))
        XCTAssertTrue(model.prepare([change], tool: .pairing, reviewedPantryBasis: reviewed.basis), model.error ?? "")
        let preview = model.preview
        model.endDecision(restoring: preview, pantryBasis: model.reviewedPantryBasis)
        XCTAssertEqual(model.reviewedPantryBasis, reviewed.basis, "Returning from a nested editor retains its stock proof")
        let before = ledger.workspace
        try await recount(f, lotID: lot, count: .exact(q(2)))
        XCTAssertTrue(pickup.pantryReadIsCurrent, "Deliberately keep the UI cache unchanged to exercise the real save guard")
        let rejected = await model.applyPreview()
        XCTAssertFalse(rejected); XCTAssertEqual(ledger.workspace, before)
        XCTAssertFalse(ledger.hasPendingSave, "Stale evidence is rejected before a new mutation is retained")
        let refreshed = await pickup.refreshPantryStock(); XCTAssertTrue(refreshed)
        let fresh = try XCTUnwrap(DinnerPantrySupply.read(pickup: pickup, workspaceID: ledger.sourceWorkspaceID,
            linkedWorkspaceID: ledger.sourceWorkspaceID, shopID: shop.id))
        XCTAssertNotEqual(fresh.basis, reviewed.basis)
        XCTAssertTrue(model.prepare([change], tool: .pairing, reviewedPantryBasis: fresh.basis), model.error ?? "")
        let applied = await model.applyPreview(); XCTAssertTrue(applied, ledger.error ?? model.error ?? "")
        XCTAssertEqual(ledger.workspace.shops.first?.mealOccurrences.count, 1)
        allowed = false
        XCTAssertTrue(pickup.pantryIsActive)
        XCTAssertThrowsError(try DinnerPantrySupply.read(pickup: pickup, workspaceID: ledger.sourceWorkspaceID,
            linkedWorkspaceID: ledger.sourceWorkspaceID, shopID: shop.id), "Access loss must fail closed, never select legacy copied stock")
    }
}
