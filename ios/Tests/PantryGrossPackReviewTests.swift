import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryGrossPackReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ value: Int64) -> Quantity { .init(amount: try! Rational(value), unit: .count, originalLiteral: String(value)) }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let inventory: ComparisonStore
        let ledgerStore: LedgerStore
        let ledger: LedgerModel
        let pickup: PickupModel
        let food: UUID
        let shopID: UUID
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now, gate = PantryMutationGate()
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        let token = try await inventory.inventorySourceToken()
        _ = try await inventory.commitInventory(.init(workspaceID: inventory.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data("reviewed empty pantry".utf8), mode: .activate, sourceToken: token), at: now)
        let ledgerURL = directory.appendingPathComponent("ledger.sqlite")
        let ledger = LedgerModel(databaseURL: ledgerURL, clock: { instant }, inventoryProjectionsEnabled: true, mutationGate: gate)
        await ledger.open()
        var shop = ShoppingLedger(title: "Before pickup", basis: .init(branch: "Main", mode: .pickup, slot: now,
            timeZoneIdentifier: "America/New_York"))
        let food = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let contribution = try XCTUnwrap(shop.contributions(forLineID: food).first)
        try shop.addProtectedNeed(name: "Wraps", quantity: q(4), purpose: "Lunch", within: contribution.id)
        let saved = await ledger.change(key: "gross-fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(saved)
        let ledgerStore = try LedgerStore(url: ledgerURL, inventoryProjectionsEnabled: true)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledgerStore.workspaceID)
        let pickup = PickupModel(store: inventory, clock: { instant }, pantry: .init(ledger: ledgerStore,
            pendingStore: pending, gate: gate, authorize: { true }))
        pickup.bindCookLedger(ledger)
        await pickup.load()
        cleanup.track(inventory, ledgerStore, ledger, pickup)
        XCTAssertTrue(pickup.pantryIsActive)
        XCTAssertTrue(pickup.pantryReadIsCurrent)
        XCTAssertTrue(pickup.journeys.isEmpty)
        return .init(cleanup: cleanup, inventory: inventory, ledgerStore: ledgerStore, ledger: ledger, pickup: pickup,
                     food: food, shopID: shop.id)
    }
    private func review(_ f: Fixture) throws -> LedgerPackReview {
        try .prepare(ledger: f.ledger, shopID: f.shopID, lineID: f.food,
            offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)),
            itemCap: nil, at: now, source: "Shelf", pickup: f.pickup)
    }
    private func request(_ review: LedgerPackReview, inventoryID: UUID) throws -> PantryPackSelectionCommitPort.Request {
        let selection = try LedgerPackSelection(id: review.operationID, workspaceID: review.sourceWorkspaceID,
            shop: review.sourceShop, lineID: review.lineID, request: review.request, selectedOfferID: "a",
            at: review.reviewedAt, source: review.source, bindings: review.bindings,
            stockEvidence: review.stockEvidence, canonicalStockEvidence: review.canonicalStockEvidence)
        return .init(inventoryWorkspaceID: inventoryID, ledgerWorkspaceID: review.sourceWorkspaceID,
            selection: selection, reviewedLedgerRevision: review.workspaceRevision, grossBasis: review.grossBasis)
    }
    private func checkout(_ f: Fixture) async throws -> LedgerCheckoutReview {
        let shop = try XCTUnwrap(f.ledger.workspace.shops.first { $0.id == f.shopID })
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: f.ledger.revision,
            previous: f.pickup.journeys.first { $0.id == shop.id }, packSelections: f.ledger.workspace.packSelections,
            workspaceID: f.ledger.sourceWorkspaceID, pickupWorkspaceID: f.pickup.sourceWorkspaceID,
            bindings: f.ledger.workspace.dinnerPlanning.portionBindings,
            pantryContext: f.pickup.pantryReviewContext(), pantryIsActive: true)
        let applied = try await LedgerCheckoutAdapter.apply(review, ledger: f.ledger, pickup: f.pickup)
        XCTAssertTrue(applied, f.pickup.error ?? "")
        return review
    }

    func testNoJourneyGrossReviewSavesAndFirstCheckoutRetainsFullPurchaseWithoutStockCredit() async throws {
        let f = try await fixture(), review = try review(f)
        XCTAssertNil(try f.pickup.confirmedPackStock(shop: review.sourceShop, lineID: f.food, bindings: []))
        XCTAssertNotNil(review.grossBasis)
        XCTAssertNil(review.canonicalStockEvidence)
        XCTAssertNil(review.stockEvidence)
        XCTAssertNil(review.request.confirmedAtHome)
        XCTAssertEqual(review.request.needed?.amount, try Rational(12))
        XCTAssertEqual(review.request.protectedAmount?.amount, try Rational(4))
        let saved = try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup)
        XCTAssertTrue(saved)
        let selection = try XCTUnwrap(f.ledger.workspace.packSelections.first)
        XCTAssertTrue(selection.isGrossOnlyPurchase)
        XCTAssertFalse(selection.isNoPurchase)
        XCTAssertEqual(selection.selectedResult.packsToBuy, 2)
        XCTAssertTrue(f.pickup.journeys.isEmpty, "Saving a comparison must not invent a pickup journey")
        let checkout = try await checkout(f)
        XCTAssertEqual(checkout.packSelections, [selection])
        XCTAssertEqual(checkout.lines.first?.quantity.amount, try Rational(16))
        XCTAssertEqual(checkout.lines.first?.expectedCost, .exact(.init(minorUnits: 600)))
        XCTAssertEqual(checkout.needs.map(\.amount.amount).reduce(.zero) { try! $0.adding($1) }, try Rational(12))
        XCTAssertTrue(f.pickup.hasCurrentBasketStockBasis)
    }

    func testChangedInventoryOrNewJourneyRejectsUncommittedGrossBasis() async throws {
        for createJourney in [false, true] {
            let f = try await fixture(), original = try request(review(f), inventoryID: f.inventory.workspaceID)
            let port = try f.pickup.makePantryPackSelectionPort()
            guard case .pending(let entry) = try await port.prepare(original) else { return XCTFail("Expected original pending selection") }
            if createJourney {
                _ = try await checkout(f)
            } else {
                let repository = PantryRepository(store: f.inventory, authorize: { true })
                let before = try await repository.load(at: now), id = UUID()
                _ = try await repository.apply(.init(id: UUID(), originID: f.inventory.workspaceID, lotID: id,
                    eventID: UUID(), expectedRevision: nil, occurredAt: now,
                    change: .create(.init(foodID: UUID(), name: "Milk", source: .manual(originID: f.inventory.workspaceID, sourceID: id),
                        location: .fridge, unit: .count, count: .unknown), observationID: UUID())),
                    reviewedInventoryRevision: before.state.revision, at: now)
            }
            do { _ = try await port.recover(entry, commitIfUnapplied: true); XCTFail("Changed admission cannot be rebased") }
            catch { XCTAssertEqual(error as? PantryPackSelectionCommitPort.Failure, .staleReview) }
            let receipt = try await f.ledgerStore.savedOperation(id: original.selection.id)
            XCTAssertNil(receipt)
            XCTAssertEqual(try port.readPending()?.request, original)
        }
    }

    func testGrossReceiptWinsAfterJourneyCreationAndLaterLedgerEdit() async throws {
        let f = try await fixture(), review = try review(f)
        let original = try request(review, inventoryID: f.inventory.workspaceID)
        let savedSelection = try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup)
        XCTAssertTrue(savedSelection)
        _ = try await checkout(f)
        let another = ShoppingLedger(title: "Later list")
        let saved = await f.ledger.change(key: "later-ledger-edit") { $0.shops.append(another) }
        XCTAssertTrue(saved)
        let port = try f.pickup.makePantryPackSelectionPort()
        guard case .committed(let retained, let result) = try await port.recover(.init(request: original), commitIfUnapplied: true) else {
            return XCTFail("Exact old ledger receipt must win over changed no-journey admission")
        }
        XCTAssertNil(retained)
        XCTAssertTrue(result.replayed)
        XCTAssertEqual(result.current.revision, f.ledger.revision)
        XCTAssertEqual(result.workspace.packSelections.filter { $0.id == original.selection.id }.count, 1)
        XCTAssertNil(try port.readPending())
    }

    func testExistingInvalidCanonicalJourneyNeverFallsBackToGross() async throws {
        let f = try await fixture()
        _ = try await checkout(f)
        let quantity = q(2)
        let changed = await f.ledger.change(key: "changed-source") { workspace in
            let index = try XCTUnwrap(workspace.shops.firstIndex { $0.id == f.shopID })
            _ = try workspace.shops[index].addManualLine(name: "Rice", quantity: quantity)
        }
        XCTAssertTrue(changed)
        XCTAssertThrowsError(try review(f))
        XCTAssertTrue(f.ledger.workspace.packSelections.isEmpty)
        XCTAssertNil(try f.pickup.makePantryPackSelectionPort().readPending())
    }

    func testRequestRequiresExactlyGrossOrCanonicalAndOldCanonicalBytesDecode() async throws {
        let f = try await fixture(), gross = try request(review(f), inventoryID: f.inventory.workspaceID)
        XCTAssertNoThrow(try PantryPackSelectionCommitPort.validate(gross))
        let unbound = PantryPackSelectionCommitPort.Request(inventoryWorkspaceID: gross.inventoryWorkspaceID,
            ledgerWorkspaceID: gross.ledgerWorkspaceID, selection: gross.selection, reviewedLedgerRevision: gross.reviewedLedgerRevision)
        XCTAssertThrowsError(try PantryPackSelectionCommitPort.validate(unbound))
        _ = try await checkout(f)
        let canonical = try request(review(f), inventoryID: f.inventory.workspaceID)
        XCTAssertEqual(canonical.selection.formatVersion, 3)
        XCTAssertFalse(canonical.selection.isGrossOnlyPurchase)
        XCTAssertNil(canonical.grossBasis)
        let bytes = try JSONEncoder().encode(canonical)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["grossBasis"])
        XCTAssertEqual(try JSONDecoder().decode(PantryPackSelectionCommitPort.Request.self, from: bytes), canonical)
        let mixed = PantryPackSelectionCommitPort.Request(inventoryWorkspaceID: canonical.inventoryWorkspaceID,
            ledgerWorkspaceID: canonical.ledgerWorkspaceID, selection: canonical.selection,
            reviewedLedgerRevision: canonical.reviewedLedgerRevision, grossBasis: gross.grossBasis)
        XCTAssertThrowsError(try PantryPackSelectionCommitPort.validate(mixed))
    }
}
