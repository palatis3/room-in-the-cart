import XCTest
import CoreDomain
@testable import RoomInTheCart

final class LedgerPackStockReviewTests: XCTestCase {
    @MainActor func testReviewedStockReducesWholePacksButDoesNotNetLedgerOrCheckoutMealDemand() async throws {
        let f = try await fixture(stock: 8)
        let original = try XCTUnwrap(f.pickup.journey)
        let review = try packReview(f)
        XCTAssertEqual(review.request.needed?.amount, try Rational(12))
        XCTAssertEqual(review.request.confirmedAtHome?.amount, try Rational(8))
        XCTAssertEqual(review.result.offerA.packsToBuy, 1)
        try accepted(try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        XCTAssertEqual(f.pickup.journey, original)
        let checkout = try checkout(f)
        XCTAssertEqual(checkout.lines.first?.quantity.amount, try Rational(8))
        XCTAssertEqual(checkout.lines.first?.expectedCost, .exact(Money(minorUnits: 300)))
        XCTAssertEqual(try checkout.needs.reduce(Rational.zero) { try $0.adding($1.amount.amount) }, try Rational(12))
        XCTAssertEqual(try f.ledger.shop?.quantity(forLineID: f.line)?.amount, try Rational(12))
        try accepted(try await LedgerCheckoutAdapter.apply(checkout, ledger: f.ledger, pickup: f.pickup))
        let applied = try XCTUnwrap(f.pickup.journey)
        let unchanged = try self.checkout(f)
        XCTAssertFalse(unchanged.needsApplication, "The exact intentional checkout application is an explicit receipt, not a silent rebase")
        XCTAssertEqual(unchanged.packSelections.count, 1)
        try accepted(try await LedgerCheckoutAdapter.apply(unchanged, ledger: f.ledger, pickup: f.pickup))
        XCTAssertEqual(f.pickup.journey, applied)
        try accepted(await f.pickup.change { $0.flexible.insert(f.line) })
        XCTAssertTrue(try self.checkout(f).packSelections.isEmpty,
            "The intentional r-to-r+1 application receipt must not become an indefinite content-only exception")
    }

    @MainActor func testFullyCoveredProducesDurableStockOnlyPlanWithoutFakePurchaseOrPlacement() async throws {
        let f = try await fixture(stock: 12)
        let review = try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop, lineID: f.line,
            offerA: PackOffer(id: "a", label: "Confirmed at home", usableQuantity: nil, price: nil),
            offerB: PackOffer(id: "b", label: "Confirmed at home", usableQuantity: nil, price: nil),
            itemCap: nil, at: Date(), source: "Reviewed pantry allocation", pickup: f.pickup)
        try accepted(try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        let checkout = try self.checkout(f)
        XCTAssertTrue(checkout.lines.isEmpty)
        XCTAssertEqual(checkout.needs.first?.amount.amount, try Rational(12))
        XCTAssertTrue(try XCTUnwrap(checkout.packSelections.first).isNoPurchase)
        XCTAssertNil(checkout.packSelections.first?.purchasedQuantity)
        try accepted(try await LedgerCheckoutAdapter.apply(checkout, ledger: f.ledger, pickup: f.pickup))
        XCTAssertTrue(try XCTUnwrap(f.pickup.journey).isAtHomeOnlyPlan)
        XCTAssertNil(f.pickup.journey?.pickup)
        XCTAssertNil(f.pickup.journey?.quote)
        XCTAssertEqual(f.pickup.allocation?.confirmedCoverageComplete, true)
        try rejected(await f.pickup.freeze())
        try rejected(await f.pickup.reportPlaced())
        let reopenedLedger = LedgerModel(databaseURL: f.directory.appendingPathComponent("ledger.sqlite"))
        let reopenedPickup = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"))
        f.cleanup.track(reopenedLedger, reopenedPickup)
        await reopenedLedger.open(); await reopenedPickup.load()
        XCTAssertEqual(reopenedLedger.workspace.packSelections, f.ledger.workspace.packSelections)
        XCTAssertTrue(try XCTUnwrap(reopenedPickup.journey).isAtHomeOnlyPlan)
        let resumed = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(reopenedLedger.shop), workspaceRevision: reopenedLedger.revision,
            previous: reopenedPickup.journey, packSelections: reopenedLedger.workspace.packSelections,
            workspaceID: reopenedLedger.sourceWorkspaceID, pickupWorkspaceID: reopenedPickup.sourceWorkspaceID)
        XCTAssertFalse(resumed.needsApplication)
        XCTAssertTrue(resumed.lines.isEmpty)
        XCTAssertNil(reopenedPickup.journey?.pickup)
        // Stock-only plans keep a real matching food identity after the purchase
        // row is omitted. Correcting that batch must reopen the purchase need.
        let originalLot = try XCTUnwrap(f.pickup.journey?.stockLots.first)
        let revisedLot = ConfirmedStockLot(id: originalLot.id, foodID: f.line, name: originalLot.name,
            usable: q(8), confirmedAt: Date().addingTimeInterval(-1), source: originalLot.source)
        let scope = PickupStockReviewScope(workspaceID: try XCTUnwrap(f.pickup.sourceWorkspaceID), localActorID: UUID(),
            accountSubject: nil, householdID: nil, memberID: nil, role: nil)
        let correction = try f.pickup.previewStockLot(revisedLot, in: f.shop, replacing: originalLot, scope: scope)
        XCTAssertEqual(correction.after.demands.first?.shortfall, try Rational(4))
        try accepted(await f.pickup.applyStockLotReview(correction, scope: scope, confirmed: true))
        XCTAssertEqual(f.pickup.allocation?.demands.first?.shortfall, try Rational(4))
        XCTAssertFalse(f.pickup.hasCurrentBasketStockBasis)
        XCTAssertTrue(try self.checkout(f).packSelections.isEmpty)
        let newReview = try packReview(f)
        XCTAssertEqual(newReview.result.offerA.packsToBuy, 1)
    }

    @MainActor func testChangedBatchRejectsUnsavedReviewAndInvalidatesSavedSelection() async throws {
        let f = try await fixture(stock: 8)
        let stale = try packReview(f)
        try await updateStock(f, amount: 4)
        do { _ = try await stale.save(offerID: "a", ledger: f.ledger, pickup: f.pickup); XCTFail("Changed batch must invalidate the open review") }
        catch { XCTAssertEqual(error as? LedgerPackError, .staleSource) }
        let current = try packReview(f)
        try accepted(try await current.save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        try await updateStock(f, amount: 3)
        let checkout = try self.checkout(f)
        XCTAssertTrue(checkout.packSelections.isEmpty)
        XCTAssertEqual(checkout.lines.first?.quantity.amount, try Rational(12))
        guard case .unknown = checkout.lines[0].expectedCost else { return XCTFail("Stale pack cost must never be reused") }
    }

    @MainActor func testChangedJourneyRevisionListOrWorkspaceRequiresFreshReview() async throws {
        let f = try await fixture(stock: 8)
        let review = try packReview(f)
        try accepted(try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        let selection = try XCTUnwrap(f.ledger.workspace.packSelections.first), shop = try XCTUnwrap(f.ledger.shop)
        XCTAssertFalse(try LedgerPackStockReview.isCurrent(selection, shop: shop,
            workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID), journey: f.pickup.journey,
            pickupWorkspaceID: UUID(), bindings: []))
        var foreign = try XCTUnwrap(f.pickup.journey)
        foreign = PickupJourney(id: UUID(), savedAt: foreign.savedAt)
        XCTAssertFalse(try LedgerPackStockReview.isCurrent(selection, shop: shop,
            workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID), journey: foreign,
            pickupWorkspaceID: f.pickup.sourceWorkspaceID, bindings: []))
        let pendingCheckout = try self.checkout(f)
        try accepted(await f.pickup.change { $0.flexible.insert(f.line) })
        XCTAssertTrue(try self.checkout(f).packSelections.isEmpty)
        do { _ = try await LedgerCheckoutAdapter.apply(pendingCheckout, ledger: f.ledger, pickup: f.pickup); XCTFail("Changed revision must reject checkout application") }
        catch { XCTAssertEqual(error as? LedgerCheckoutError, .staleCheckout) }
        let next = try packReview(f)
        try accepted(await f.ledger.editShop(key: "list-edit", shopID: f.shop) { try $0.updateLine(lineID: f.line, name: "Wraps", notes: "Review recipe", aisle: "") })
        do { _ = try await next.save(offerID: "a", ledger: f.ledger, pickup: f.pickup); XCTFail("Changed list must invalidate stock source") }
        catch { XCTAssertEqual(error as? LedgerPackError, .staleSource) }
    }

    @MainActor func testProtectedFoodElsewhereIsUnavailableForThePackReview() async throws {
        let f = try await fixture(stock: 8)
        try accepted(await f.pickup.change { value in
            value.stockNeeds.append(StockNeed(id: UUID(), foodID: f.line, name: "Protected lunches elsewhere", amount: self.q(8), priority: .protected))
        })
        let review = try packReview(f)
        XCTAssertEqual(review.request.confirmedAtHome?.amount, .zero)
        XCTAssertEqual(review.result.offerA.packsToBuy, 2)
    }

    @MainActor func testStockAddedAfterNoStockReviewRejectsOldChoiceAndNoStockStillBuysTwo() async throws {
        let f = try await fixture(stock: nil)
        let review = try packReview(f)
        XCTAssertNil(review.stockEvidence)
        XCTAssertEqual(review.result.offerA.packsToBuy, 2)
        try accepted(try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        let lot = ConfirmedStockLot(id: UUID(), foodID: f.line, name: "Wraps at home", usable: q(8), confirmedAt: Date().addingTimeInterval(-1), source: .pantry)
        try accepted(await f.pickup.saveStockLot(lot, in: f.shop))
        XCTAssertTrue(try checkout(f).packSelections.isEmpty)
        do { _ = try await review.save(offerID: "a", ledger: f.ledger, pickup: f.pickup); XCTFail("A formerly no-stock choice cannot bypass new reviewed stock") }
        catch { XCTAssertEqual(error as? LedgerPackError, .staleSource) }
    }

    @MainActor func testCachedCheckoutRejectsChangedStockButRecordsAnExplicitAlreadyPlacedOriginalOrder() async throws {
        let f = try await fixture(stock: 8)
        try accepted(try await packReview(f).save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        let checkout = try self.checkout(f)
        try accepted(try await LedgerCheckoutAdapter.apply(checkout, ledger: f.ledger, pickup: f.pickup))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: checkout.context,
            pricing: .inclusiveTotal(.exact(Money(minorUnits: 300))))
        try accepted(await f.pickup.setQuote(quote, cap: nil))
        XCTAssertTrue(f.pickup.hasCurrentBasketStockBasis, "Quote-only revisions preserve the exact applied basket")
        XCTAssertNotNil(f.pickup.result)
        try accepted(await f.pickup.freeze())
        let snapshot = try XCTUnwrap(f.pickup.frozenSnapshot)
        try accepted(await f.pickup.recordHandoff(.copyAttempted))
        XCTAssertTrue(f.pickup.hasCurrentBasketStockBasis)
        try await updateStock(f, amount: 0)
        XCTAssertFalse(f.pickup.hasCurrentBasketStockBasis)
        XCTAssertNil(f.pickup.result, "Cached affordability cannot survive changed material supply")
        XCTAssertEqual(f.pickup.frozenSnapshot, snapshot, "Keep the original frozen order readable")
        try rejected(await f.pickup.setQuote(quote, cap: nil))
        try rejected(await f.pickup.freeze())
        try rejected(await f.pickup.recordHandoff(.copyAttempted))
        try rejected(await f.pickup.recordHandoff(.shareOpened))
        try rejected(await f.pickup.reportPlaced())
        // Explicitly reporting an external action records the original order;
        // it neither changes the purchase nor claims meal coverage is repaired.
        try accepted(await f.pickup.reportPlaced(acknowledgingChangedStock: true))
        XCTAssertEqual(f.pickup.journey?.pickup?.orderLines.first?.ordered.amount, try Rational(8))
        XCTAssertEqual(f.pickup.journey?.basket?.reportedOrderLines?.first?.quantity.amount, try Rational(8))
        XCTAssertEqual(f.pickup.journey?.basket?.snapshots.first, snapshot)
        let placement = try XCTUnwrap(f.pickup.journey?.basket?.placements.first)
        try await updateStock(f, amount: 4)
        XCTAssertEqual(f.pickup.journey?.basket?.placements.first, placement)
        XCTAssertEqual(f.pickup.journey?.pickup?.orderLines.first?.ordered.amount, try Rational(8))
    }

    @MainActor func testStockAddedToCachedVersionOneBasketRequiresNewReview() async throws {
        let f = try await fixture(stock: nil)
        try accepted(try await packReview(f).save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        let checkout = try self.checkout(f)
        try accepted(try await LedgerCheckoutAdapter.apply(checkout, ledger: f.ledger, pickup: f.pickup))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: checkout.context,
            pricing: .inclusiveTotal(.exact(Money(minorUnits: 600))))
        try accepted(await f.pickup.setQuote(quote, cap: nil))
        XCTAssertNotNil(f.pickup.result)
        let lot = ConfirmedStockLot(id: UUID(), foodID: f.line, name: "Newly confirmed wraps", usable: q(8),
            confirmedAt: Date().addingTimeInterval(-1), source: .pantry)
        try accepted(await f.pickup.saveStockLot(lot, in: f.shop))
        XCTAssertFalse(f.pickup.hasCurrentBasketStockBasis)
        XCTAssertNil(f.pickup.result)
        try rejected(await f.pickup.freeze())
        XCTAssertEqual(f.pickup.journey?.basket?.current.lines.first?.quantity.amount, try Rational(16),
            "The shopper must review a new choice; stock changes cannot silently change a saved basket")
    }

    @MainActor func testAnAppliedStockSelectionCannotBeAdoptedForAnotherCheckoutChange() async throws {
        let f = try await fixture(stock: 8)
        try accepted(await f.ledger.editShop(key: "second-food", shopID: f.shop) { value in
            _ = try value.addManualLine(name: "Rice", quantity: self.q(12))
        })
        try accepted(try await LedgerCheckoutAdapter.apply(checkout(f), ledger: f.ledger, pickup: f.pickup))
        try accepted(try await packReview(f).save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        try accepted(try await LedgerCheckoutAdapter.apply(checkout(f), ledger: f.ledger, pickup: f.pickup))
        XCTAssertTrue(try checkout(f).packSelections.contains(where: { $0.lineID == f.line }))
        let rice = try XCTUnwrap(f.ledger.shop?.lines.first(where: { $0.name == "Rice" }))
        let riceReview = try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop, lineID: rice.id,
            offerA: PackOffer(id: "a", label: "Ten rice units", usableQuantity: q(10), price: Money(minorUnits: 100)),
            offerB: PackOffer(id: "b", label: "Six rice units", usableQuantity: q(6), price: Money(minorUnits: 80)),
            itemCap: nil, at: Date(), source: "Rice shelf", pickup: f.pickup)
        try accepted(try await riceReview.save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        let changed = try checkout(f)
        XCTAssertTrue(changed.needsApplication)
        XCTAssertFalse(changed.packSelections.contains(where: { $0.lineID == f.line }),
            "The old stock application receipt only reopens its own basket")
        XCTAssertEqual(changed.lines.first(where: { $0.id == f.line })?.quantity.amount, try Rational(12))
        XCTAssertTrue(changed.packSelections.contains(where: { $0.lineID == rice.id }))
    }

    @MainActor func testMixedStockOnlyAndPurchasedFoodKeepsAllDemandsWhenTheActualOrderIsReported() async throws {
        let f = try await fixture(stock: 12)
        try accepted(await f.ledger.editShop(key: "rice", shopID: f.shop) { value in
            _ = try value.addManualLine(name: "Rice", quantity: self.q(2))
        })
        let source = try self.checkout(f)
        try accepted(try await LedgerCheckoutAdapter.apply(source, ledger: f.ledger, pickup: f.pickup))
        try accepted(try await packReview(f).save(offerID: "a", ledger: f.ledger, pickup: f.pickup))
        let checkout = try self.checkout(f)
        XCTAssertEqual(checkout.lines.map(\.name), ["Rice"])
        XCTAssertEqual(checkout.needs.count, 2)
        try accepted(try await LedgerCheckoutAdapter.apply(checkout, ledger: f.ledger, pickup: f.pickup))
        let quote = CheckoutQuote(scope: .wholeCheckout, context: checkout.context,
            pricing: .inclusiveTotal(.exact(Money(minorUnits: 400))))
        try accepted(await f.pickup.setQuote(quote, cap: nil))
        XCTAssertTrue(f.pickup.hasCurrentBasketStockBasis)
        try accepted(await f.pickup.freeze())
        try accepted(await f.pickup.reportPlaced())
        XCTAssertEqual(f.pickup.journey?.pickup?.orderLines.map(\.name), ["Rice"])
        XCTAssertEqual(f.pickup.journey?.needs.count, 2)
        XCTAssertEqual(f.pickup.allocation?.demands.first(where: { $0.foodID == f.line })?.allocated, try Rational(12))
        let rice = try XCTUnwrap(f.pickup.journey?.pickup?.orderLines.first)
        try accepted(await f.pickup.change { value in
            value.needs.append(AllocationNeed(id: UUID(), orderLineID: rice.id, name: "Another rice purpose", amount: self.q(1), priority: .required))
        })
        XCTAssertEqual(f.pickup.journey?.needs.count, 3)
    }

    private struct Fixture { let cleanup: SQLiteFixtureDirectory; let ledger: LedgerModel; let pickup: PickupModel; let directory: URL; let shop: UUID; let line: UUID }
    @MainActor private func fixture(stock: Int64?) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        cleanup.track(ledger, pickup)
        await ledger.open(); await pickup.load()
        try accepted(await ledger.startShop(title: "Stock-aware packs"))
        let shop = try XCTUnwrap(ledger.shop?.id)
        try accepted(await ledger.editShop(key: "need", shopID: shop) { value in
            try value.updateBasis(ShopBasis(branch: "Local market", mode: .pickup,
                slot: Date().addingTimeInterval(3600), timeZoneIdentifier: "America/New_York"))
            _ = try value.addManualLine(name: "Wraps", quantity: self.q(12))
        })
        let line = try XCTUnwrap(ledger.shop?.lines.first?.id)
        let original = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil)
        try accepted(try await LedgerCheckoutAdapter.apply(original, ledger: ledger, pickup: pickup))
        if let stock {
            let lot = ConfirmedStockLot(id: UUID(), foodID: line, name: "Wraps at home", usable: q(stock), confirmedAt: Date().addingTimeInterval(-1), source: .freezer)
            try accepted(await pickup.saveStockLot(lot, in: shop))
        }
        return Fixture(cleanup: cleanup, ledger: ledger, pickup: pickup, directory: directory, shop: shop, line: line)
    }
    @MainActor private func packReview(_ f: Fixture) throws -> LedgerPackReview {
        try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop, lineID: f.line,
            offerA: PackOffer(id: "a", label: "Eight pack", usableQuantity: q(8), price: Money(minorUnits: 300)),
            offerB: PackOffer(id: "b", label: "Six pack", usableQuantity: q(6), price: Money(minorUnits: 250)),
            itemCap: nil, at: Date(), source: "Store shelf", pickup: f.pickup)
    }
    @MainActor private func checkout(_ f: Fixture) throws -> LedgerCheckoutReview {
        try LedgerCheckoutAdapter.review(shop: XCTUnwrap(f.ledger.shop), workspaceRevision: f.ledger.revision,
            previous: f.pickup.journey, packSelections: f.ledger.workspace.packSelections,
            workspaceID: f.ledger.sourceWorkspaceID, pickupWorkspaceID: f.pickup.sourceWorkspaceID)
    }
    @MainActor private func updateStock(_ f: Fixture, amount: Int64) async throws {
        let original = try XCTUnwrap(f.pickup.journey?.stockLots.first)
        let revised = ConfirmedStockLot(id: original.id, foodID: original.foodID, name: original.name,
            usable: q(amount), confirmedAt: Date().addingTimeInterval(-1), source: original.source)
        try accepted(await f.pickup.saveStockLot(revised, in: f.shop, replacing: original))
    }
    private func accepted(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(value, file: file, line: line)
        if !value { throw CocoaError(.fileWriteUnknown) }
    }
    private func rejected(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(value, file: file, line: line)
        if value { throw CocoaError(.fileWriteUnknown) }
    }
    private func q(_ n: Int64) -> Quantity { Quantity(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
}
