import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryCanonicalCheckoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let directory: URL
        let ledger: LedgerModel
        let ledgerStore: LedgerStore
        let pickup: PickupModel
        let inventory: ComparisonStore
        let shop: UUID
        let food: UUID
        let rice: UUID?
    }
    private func fixture(stock: Int64 = 4, rice: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), gate = PantryMutationGate(), instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), clock: { instant },
            inventoryProjectionsEnabled: true, mutationGate: gate)
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(ledger, producer, inventory)
        await ledger.open(); await producer.load()
        let ledgerStore = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(ledgerStore)
        var shop = ShoppingLedger(title: "Canonical checkout", basis: .init(branch: "Main", mode: .pickup,
            slot: now, timeZoneIdentifier: "America/New_York"))
        let food = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let supply = try XCTUnwrap(shop.contributions(forLineID: food).first?.id)
        try shop.addProtectedNeed(name: "Wraps", quantity: q(4), purpose: "Lunch", within: supply)
        let riceID = try rice ? shop.addManualLine(name: "Rice", quantity: q(2)) : nil
        let saved = await ledger.change(key: "fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }; XCTAssertTrue(saved)
        let checkout = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        let started = try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: producer); XCTAssertTrue(started)
        let stocked = await producer.saveStockLot(.init(id: food, foodID: food, name: "Wraps at home", usable: q(stock),
            confirmedAt: now, source: .freezer), in: shop.id); XCTAssertTrue(stocked)
        for head in try await producer.archiveSnapshot().records {
            _ = try await inventory.save(id: head.id, title: head.title, payload: head.payload, savedAt: head.savedAt)
        }
        let mapping = try PantryLegacyMigration.map(originID: inventory.workspaceID,
            heads: try await inventory.list().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await inventory.inventorySourceToken(),
            inventoryRevision: await inventory.inventoryState().revision, at: now)
        _ = try await inventory.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await inventory.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await inventory.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledgerStore.workspaceID)
        let pickup = PickupModel(store: inventory, clock: { instant }, pantry: .init(ledger: ledgerStore,
            pendingStore: pending, gate: gate, authorize: { true }))
        cleanup.track(pickup); await pickup.load(); pickup.bindCookLedger(ledger); XCTAssertTrue(pickup.ready)
        return .init(cleanup: cleanup, directory: directory, ledger: ledger, ledgerStore: ledgerStore,
            pickup: pickup, inventory: inventory, shop: shop.id, food: food, rice: riceID)
    }
    @discardableResult private func choose(_ f: Fixture, food: UUID? = nil) async throws -> LedgerPackSelection {
        let review = try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop, lineID: food ?? f.food,
            offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)),
            itemCap: nil, at: now, source: "Shelf", pickup: f.pickup)
        let saved = try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup); XCTAssertTrue(saved)
        return try XCTUnwrap(f.ledger.workspace.packSelections.last)
    }
    private func checkout(_ f: Fixture) throws -> LedgerCheckoutReview {
        try LedgerCheckoutAdapter.review(shop: XCTUnwrap(f.ledger.shop), workspaceRevision: f.ledger.revision,
            previous: f.pickup.journeys.first { $0.id == f.shop }, packSelections: f.ledger.workspace.packSelections,
            workspaceID: f.ledger.sourceWorkspaceID, pickupWorkspaceID: f.pickup.sourceWorkspaceID,
            bindings: f.ledger.workspace.dinnerPlanning.portionBindings,
            pantryContext: f.pickup.canonicalPackContext(for: f.shop), pantryIsActive: true)
    }
    private func recount(_ f: Fixture, _ count: InventoryCount) async throws {
        let repository = PantryRepository(store: f.inventory, authorize: { true }); f.cleanup.track(repository)
        let before = try await repository.load(at: now), lot = try XCTUnwrap(before.lots.first)
        _ = try await repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(count, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
    }

    func testFreshCanonicalPacksPreserveGrossProtectedNeedsAndReopenExactBasket() async throws {
        let f = try await fixture(), selected = try await choose(f), reviewed = try checkout(f)
        XCTAssertEqual(reviewed.packSelections, [selected]); XCTAssertTrue(reviewed.needsApplication)
        XCTAssertEqual(reviewed.lines.first?.quantity.amount, try Rational(8))
        XCTAssertEqual(try reviewed.needs.reduce(Rational.zero) { try $0.adding($1.amount.amount) }, try Rational(12))
        XCTAssertEqual(reviewed.needs.first(where: { $0.priority == .protected })?.amount.amount, try Rational(4))
        let applied = try await LedgerCheckoutAdapter.apply(reviewed, ledger: f.ledger, pickup: f.pickup); XCTAssertTrue(applied)
        let actual = try XCTUnwrap(f.pickup.journey), reopened = try checkout(f)
        XCTAssertFalse(reopened.needsApplication); XCTAssertEqual(reopened.packSelections, [selected])
        XCTAssertTrue(f.pickup.hasCurrentBasketStockBasis)
        let repeated = try await LedgerCheckoutAdapter.apply(reopened, ledger: f.ledger, pickup: f.pickup); XCTAssertTrue(repeated)
        XCTAssertEqual(f.pickup.journey, actual)
        XCTAssertEqual(try f.ledger.shop?.quantity(forLineID: f.food)?.amount, try Rational(12))
        XCTAssertEqual(actual.plannedNeeds, reviewed.needs)
    }

    func testApplyRefreshesIndependentCountAndRejectsCachedSelectionWithoutSourceOverwrite() async throws {
        let f = try await fixture()
        _ = try await choose(f)
        let review = try checkout(f), source = try XCTUnwrap(f.pickup.journey)
        try await recount(f, .exact(q(0)))
        do { _ = try await LedgerCheckoutAdapter.apply(review, ledger: f.ledger, pickup: f.pickup); XCTFail("New independent count") }
        catch { XCTAssertEqual(error as? LedgerCheckoutError, .staleSource) }
        XCTAssertEqual(f.pickup.journey, source)
        let current = try checkout(f)
        XCTAssertTrue(current.packSelections.isEmpty); XCTAssertEqual(current.unreviewedPackLineIDs, [f.food])
        XCTAssertEqual(current.lines.first?.quantity.amount, try Rational(12))
        guard case .unknown = current.lines[0].expectedCost else { return XCTFail("Old net pack cost cannot survive") }
        XCTAssertEqual(f.pickup.pantrySnapshot?.lots.first?.count, .exact(q(0)))
    }

    func testNoPurchaseSurvivesNoteOnlyAppliedBasketButUnknownCountRequiresNewReview() async throws {
        let f = try await fixture(stock: 12), selected = try await choose(f), review = try checkout(f)
        XCTAssertTrue(selected.isNoPurchase); XCTAssertTrue(review.lines.isEmpty)
        let applied = try await LedgerCheckoutAdapter.apply(review, ledger: f.ledger, pickup: f.pickup); XCTAssertTrue(applied)
        let noted = await f.pickup.change { value in
            value.notes.append(.init(id: UUID(), text: "Take bags", language: "en", createdAt: self.now, revision: value.revision))
        }; XCTAssertTrue(noted)
        let unchanged = try checkout(f)
        XCTAssertFalse(unchanged.needsApplication); XCTAssertTrue(unchanged.lines.isEmpty)
        XCTAssertTrue(f.pickup.hasCurrentBasketStockBasis)
        try await recount(f, .someLeft)
        let refreshed = await f.pickup.refreshPantryStock(); XCTAssertTrue(refreshed)
        let changed = try checkout(f)
        XCTAssertTrue(changed.packSelections.isEmpty); XCTAssertFalse(changed.lines.isEmpty)
        XCTAssertFalse(f.pickup.hasCurrentBasketStockBasis)
        XCTAssertEqual(changed.needs, review.needs)
        XCTAssertEqual(f.pickup.journey?.stockLots.first?.usable.amount, try Rational(12), "Copied source count stays historical.")
    }

    func testAppliedMaterialExceptionCannotBeAdoptedForDifferentCheckoutChange() async throws {
        let f = try await fixture(stock: 12, rice: true), wrapped = try await choose(f)
        let initial = try checkout(f)
        let applied = try await LedgerCheckoutAdapter.apply(initial, ledger: f.ledger, pickup: f.pickup); XCTAssertTrue(applied)
        XCTAssertEqual(try checkout(f).packSelections, [wrapped])
        let rice = try await choose(f, food: XCTUnwrap(f.rice))
        let changed = try checkout(f)
        XCTAssertTrue(changed.needsApplication)
        XCTAssertEqual(changed.packSelections, [rice], "Only the newly exact reviewed selection can authorize a new basket.")
        XCTAssertEqual(changed.lines.first(where: { $0.id == f.food })?.quantity.amount, try Rational(12))
        XCTAssertTrue(changed.unreviewedPackLineIDs.contains(f.food))
        XCTAssertEqual(changed.needs, initial.needs)
    }

    func testActivePantryRejectsLegacyDiscountAndMissingProofStillShowsGrossNeeds() async throws {
        let f = try await fixture(stock: 12), selected = try await choose(f)
        let shop = try XCTUnwrap(f.ledger.shop), journey = try XCTUnwrap(f.pickup.journey)
        let missing = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: f.ledger.revision, previous: journey,
            packSelections: [selected], workspaceID: f.ledger.sourceWorkspaceID, pickupWorkspaceID: f.pickup.sourceWorkspaceID,
            pantryContext: nil, pantryIsActive: true)
        XCTAssertTrue(missing.packSelections.isEmpty); XCTAssertEqual(missing.lines.first?.quantity.amount, try Rational(12))
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: f.food)
        let legacy = try XCTUnwrap(LedgerPackStockReview.evidence(shop: shop, lineID: f.food, requirement: requirement,
            journey: journey, pickupWorkspaceID: f.inventory.workspaceID, bindings: []))
        let old = try LedgerPackSelection(workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID), shop: shop, lineID: f.food,
            request: selected.request, selectedOfferID: "a", at: now, source: "Legacy", stockEvidence: legacy)
        XCTAssertTrue(old.isNoPurchase)
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: f.ledger.revision, previous: journey,
            packSelections: [old], workspaceID: f.ledger.sourceWorkspaceID, pickupWorkspaceID: f.pickup.sourceWorkspaceID,
            pantryContext: f.pickup.canonicalPackContext(for: f.shop), pantryIsActive: true)
        XCTAssertTrue(review.packSelections.isEmpty); XCTAssertFalse(review.lines.isEmpty)
        XCTAssertEqual(review.needs, missing.needs)
        let grossRequest = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
            protectedAmount: requirement.protectedQuantity, offerA: selected.request.offerA, offerB: selected.request.offerB)
        let gross = try LedgerPackSelection(workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID), shop: shop, lineID: f.food,
            request: grossRequest, selectedOfferID: "a", at: now, source: "Gross packs")
        let grossCheckout = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: f.ledger.revision, previous: journey,
            packSelections: [gross], workspaceID: f.ledger.sourceWorkspaceID, pickupWorkspaceID: f.pickup.sourceWorkspaceID,
            pantryContext: f.pickup.canonicalPackContext(for: f.shop), pantryIsActive: true)
        XCTAssertEqual(grossCheckout.packSelections, [gross], "A typed gross purchase grants no food credit and remains usable after activation.")
        XCTAssertEqual(grossCheckout.lines.first?.quantity.amount, try Rational(16))
        XCTAssertEqual(grossCheckout.needs, missing.needs)
    }

    func testIndependentLedgerWriterCannotBecomeCheckoutNewReviewedBase() async throws {
        let f = try await fixture(), selected = try await choose(f), review = try checkout(f)
        let source = try XCTUnwrap(f.pickup.journey)
        let loaded = try await f.ledgerStore.load(), head = try XCTUnwrap(loaded)
        // A separate connection advances the actual ledger without refreshing the UI model.
        let other = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(other)
        _ = try await other.save(payload: head.payload, expectedRevision: head.revision, operationID: UUID(), savedAt: now)
        let saved = try await LedgerCheckoutAdapter.apply(review, ledger: f.ledger, pickup: f.pickup)
        XCTAssertFalse(saved)
        XCTAssertEqual(f.pickup.journey, source)
        XCTAssertEqual(f.ledger.workspace.packSelections, [selected])
        XCTAssertFalse(f.pickup.hasPendingSave, "A changed actual ledger is rejected before a new journal is staged.")
    }
}
