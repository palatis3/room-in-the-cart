import XCTest
import CoreDomain
@testable import RoomInTheCart

final class LedgerCheckoutAdapterTests: XCTestCase {
    func testTwelveExistingWrapsProjectSixFourTwoExactlyOnce() throws {
        let shop = try wrapShop()
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.lines.count, 1)
        XCTAssertEqual(review.lines[0].quantity.amount, try Rational(12))
        XCTAssertEqual(review.needs.count, 3)
        XCTAssertEqual(review.needs.first(where: { $0.name == "Tacos" })?.amount.amount, try Rational(6))
        XCTAssertEqual(review.needs.first(where: { $0.name == "Quesadillas" })?.amount.amount, try Rational(4))
        let protected = try XCTUnwrap(review.needs.first(where: { $0.priority == .protected }))
        XCTAssertEqual(protected.name, "Lunch")
        XCTAssertEqual(protected.amount.amount, try Rational(2))
        XCTAssertEqual(Set(review.needs.map(\.orderLineID)), Set(review.lines.map(\.id)))
        let repeated = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.needs, repeated.needs)
    }

    func testNamedServingGroupsPartitionOneMealAndKeepStableNeedIdentities() throws {
        var shop = ShoppingLedger(basis: basis())
        let meal = MealTemplate(title: "Soup", servings: try Rational(6), ingredients: [MealIngredient(name: "Soup portions", quantity: quantity(6))], servingGroups: [ServingGroup(name: "Lunch", servings: try Rational(2), isProtected: true)])
        try shop.chooseMeal(meal)
        let first = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        let second = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(first.needs, second.needs)
        XCTAssertEqual(first.needs.first(where: { $0.priority == .protected })?.amount.amount, try Rational(2))
        XCTAssertEqual(first.needs.first(where: { $0.priority == .required })?.amount.amount, try Rational(4))
    }

    func testUnknownAmountsBlockProjectionAndMissingContextStaysMissing() throws {
        var unknown = ShoppingLedger()
        try unknown.addManualLine(name: "Milk", quantity: nil)
        XCTAssertThrowsError(try LedgerCheckoutAdapter.review(shop: unknown, workspaceRevision: 1, previous: nil)) { error in
            XCTAssertEqual(error as? LedgerCheckoutError, .missingQuantity)
        }
        var knownQuantity = ShoppingLedger()
        try knownQuantity.addManualLine(name: "Milk", quantity: quantity(1))
        let review = try LedgerCheckoutAdapter.review(shop: knownQuantity, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.context.branchID, "")
        XCTAssertEqual(review.context.slot, "")
        XCTAssertNil(review.cap)
        XCTAssertFalse(review.lines.isEmpty)
    }

    @MainActor func testBasisOnlyChangeRequiresReviewClearsQuoteAndLeavesOldSnapshotImmutable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await ledger.open(); await pickup.load()
        let shop = try wrapShop()
        _ = await ledger.change(key: "seed") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        let originalReview = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        let started = try await LedgerCheckoutAdapter.apply(originalReview, ledger: ledger, pickup: pickup)
        XCTAssertTrue(started)
        _ = await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: originalReview.context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 3720)))), cap: originalReview.cap)
        _ = await pickup.freeze()
        let original = try XCTUnwrap(pickup.journey)
        let frozen = try XCTUnwrap(pickup.frozenSnapshot)
        let updated = await ledger.editShop(key: "cap", shopID: shop.id) { current in
            var changed = current.basis; changed.cap = Money(minorUnits: 3000); changed.knownFees = Money(minorUnits: 495)
            try current.updateBasis(changed)
        }
        XCTAssertTrue(updated)
        let changedShop = try XCTUnwrap(ledger.shop)
        let review = try LedgerCheckoutAdapter.review(shop: changedShop, workspaceRevision: ledger.revision, previous: original)
        XCTAssertTrue(review.needsApplication)
        XCTAssertNotNil(review.proposal)
        XCTAssertEqual(review.lines.map(\.quantity), originalReview.lines.map(\.quantity))
        let saved = try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: pickup)
        XCTAssertTrue(saved)
        XCTAssertNil(pickup.journey?.quote)
        XCTAssertNil(pickup.journey?.quotedRevisionID)
        XCTAssertEqual(pickup.journey?.basket?.phase, .draft)
        XCTAssertEqual(pickup.journey?.basket?.snapshots.first, frozen)
        XCTAssertEqual(pickup.journey?.cap?.amount, Money(minorUnits: 3000))
        XCTAssertEqual(pickup.journey?.plannedNeeds.filter { $0.priority == .protected }.count, 1)
    }

    @MainActor func testSourceChangesAfterPreviewAreRejectedEvenWhenQuantitiesStayTheSame() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await ledger.open(); await pickup.load()
        let shop = try wrapShop()
        _ = await ledger.change(key: "seed") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        let stale = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        _ = await ledger.editShop(key: "rename-purpose", shopID: shop.id) { current in
            try current.updateMeal(occurrenceID: current.mealOccurrences[0].id, title: "Tuesday tacos", notes: "Keep lunch protected")
        }
        do {
            _ = try await LedgerCheckoutAdapter.apply(stale, ledger: ledger, pickup: pickup)
            XCTFail("A stale source review must not create a checkout")
        } catch { XCTAssertEqual(error as? LedgerCheckoutError, .staleSource) }
        XCTAssertNil(pickup.journey)
        let changed = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil)
        XCTAssertEqual(changed.lines, stale.lines)
        XCTAssertNotEqual(changed.needs, stale.needs)
    }

    @MainActor func testSameLinesStillReviewRetailerSourceAndZoneChanges() async throws {
        let shop = try wrapShop()
        let first = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        var previous = PickupJourney(id: shop.id, savedAt: Date())
        previous.basket = try BasketPlan(id: shop.id, revisionID: UUID(), lines: first.lines, createdAt: Date())
        previous.context = first.context; previous.cap = first.cap; previous.plannedNeeds = first.needs
        previous.needDetails = first.details; previous.ledgerBasis = shop.basis; previous.ledgerSourceRevisionID = shop.revisionID
        let unchanged = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: previous)
        XCTAssertFalse(unchanged.needsApplication)
        var changed = shop
        var revisedBasis = changed.basis
        revisedBasis.timeZoneIdentifier = "America/Chicago"
        revisedBasis.retailerPreview = LedgerRetailerPreview(total: Money(minorUnits: 3720), source: "New retailer preview", capturedAt: Date(), includedCharges: ["tax"])
        try changed.updateBasis(revisedBasis)
        let review = try LedgerCheckoutAdapter.review(shop: changed, workspaceRevision: 2, previous: previous)
        XCTAssertTrue(review.needsApplication)
        XCTAssertEqual(review.lines.map(\.id), unchanged.lines.map(\.id))
        XCTAssertEqual(review.context.source, "New retailer preview")
        XCTAssertTrue(review.context.slot.contains("America/Chicago"))
    }

    @MainActor func testNextShopBridgeAndRepeatedOriginActionCreateOneEditableShop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        let urgent = UrgentMealNeed(id: UUID(), food: "Wraps", meal: "Dinner", required: quantity(6), available: quantity(4), due: nil, confirmedAt: Date())
        _ = await pickup.addUrgent(urgent)
        let origin = try XCTUnwrap(pickup.journey?.id)
        let deferred = DeferredPickupNeed(id: UUID(), sourceShopID: origin, line: BasketLine(id: UUID(), name: "Coffee", quantity: quantity(1), expectedCost: .exact(Money(minorUnits: 460))))
        _ = await pickup.change { $0.deferred = [deferred] }
        _ = await pickup.startNextShop(accept: [deferred.id])
        let next = try XCTUnwrap(pickup.journey)
        let first = await LedgerCheckoutAdapter.openNextShop(next, ledger: ledger)
        XCTAssertTrue(first)
        let firstLineIDs = ledger.shop?.lines.map(\.id)
        let second = await LedgerCheckoutAdapter.openNextShop(next, ledger: ledger)
        XCTAssertTrue(second)
        XCTAssertEqual(ledger.workspace.shops.count, 1)
        XCTAssertEqual(ledger.shop?.id, next.id)
        XCTAssertEqual(ledger.shop?.lines.map(\.id), firstLineIDs)
        XCTAssertNil(ledger.shop?.basis.retailerPreview)
        XCTAssertNil(ledger.shop?.basis.slot)
        XCTAssertEqual(ledger.shop?.basis.branch, "")
        pickup.selectedID = origin
        _ = await pickup.startNextShop(accept: [deferred.id])
        XCTAssertEqual(pickup.journey?.id, next.id)
        XCTAssertEqual(pickup.journeys.count, 2)
    }

    private func wrapShop() throws -> ShoppingLedger {
        var shop = ShoppingLedger(title: "Tuesday pickup", basis: basis())
        let line = try shop.addManualLine(name: "Wraps", quantity: quantity(12))
        let supply = try XCTUnwrap(shop.contributions(forLineID: line).first?.id)
        for (title, count) in [("Tacos", Int64(6)), ("Quesadillas", Int64(4))] {
            let occurrence = try shop.chooseMeal(MealTemplate(title: title, ingredients: [MealIngredient(name: "Wraps", quantity: quantity(count))]))
            let demand = try XCTUnwrap(shop.mealOccurrences.first { $0.id == occurrence }?.ingredientContributionIDs.first)
            try shop.linkContribution(contributionID: demand, within: supply, quantity: quantity(count))
        }
        try shop.addProtectedNeed(name: "Wraps", quantity: quantity(2), purpose: "Lunch", within: supply)
        return shop
    }
    private func basis() -> ShopBasis {
        ShopBasis(branch: "Main branch", mode: .pickup, slot: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/New_York", cap: Money(minorUnits: 3800))
    }
    private func quantity(_ count: Int64) -> Quantity { Quantity(amount: try! Rational(count), unit: .count, originalLiteral: String(count)) }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
