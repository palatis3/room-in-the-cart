import XCTest
import CoreDomain
@testable import RoomInTheCart

final class DinnerIdeaSupplyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64, _ unit: UnitOfMeasure = .count) -> Quantity {
        Quantity(amount: try! Rational(amount), unit: unit, originalLiteral: String(amount))
    }

    func testProtectedLunchIsSubtractedBeforeRoundUpAndIdeaAcceptanceDoesNotSpendOrAllocate() throws {
        let shop = ShoppingLedger(), scope = UUID(), food = UUID()
        var workspace = LedgerWorkspace(); workspace.shops = [shop]
        let ingredient = MealIngredient(name: "Wraps", quantity: q(4))
        var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "manual-v1", template: .init(title: "Tacos", ingredients: [ingredient]), createdAt: now)
        idea.supplyEvidence = [.init(ingredient: ingredient, workspaceID: scope, shopID: shop.id, basisRevision: shop.basisRevision,
            foodID: food, pack: PackOffer(id: "two", label: "Wraps", usableQuantity: q(2), price: Money(minorUnits: 125)),
            source: "Shelf label", observedAt: now)]
        var pickup = PickupJourney(id: shop.id, savedAt: now)
        pickup.stockLots = [.init(id: UUID(), foodID: food, name: "Wraps", usable: q(3), confirmedAt: now)]
        pickup.stockNeeds = [.init(id: UUID(), foodID: food, name: "Tomorrow’s lunch", amount: q(2), priority: .protected)]
        let originalPickup = pickup, originalShop = shop
        func preview(_ draft: DinnerIdeaDraft) throws -> [IdeaSupplyRow] {
            try DinnerIdeaSupplyReview.rows(idea: draft, shop: shop, workspace: workspace, workspaceID: scope, journey: pickup, at: now)
        }
        let row = try XCTUnwrap(preview(idea).first)
        XCTAssertEqual(row.reservations.first?.name, "Tomorrow’s lunch")
        XCTAssertEqual(row.reservations.first?.quantity.amount, q(2).amount)
        XCTAssertEqual(row.credited?.amount, .one)
        XCTAssertEqual(row.uncovered?.amount, q(3).amount)
        XCTAssertEqual(row.packs, 2)
        XCTAssertEqual(row.cost?.minorUnits, 250)
        let access = DinnerAccessContext(scope: .local(workspaceID: scope), actorID: "me", shopID: shop.id, assignedShopperID: "me",
            canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(30))
        let acceptedID = UUID()
        _ = try workspace.dinnerPlanning.acceptIdea(idea, acceptedID: acceptedID, access: access, at: now)
        _ = try workspace.dinnerPlanning.acceptIdea(idea, acceptedID: acceptedID, access: access, at: now)
        XCTAssertEqual(workspace.dinnerPlanning.acceptedDinners.count, 1)
        XCTAssertEqual(workspace.shops, [originalShop]); XCTAssertEqual(pickup, originalPickup)
        let reopened = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(reopened.dinnerPlanning.ideas.first?.supplyEvidence, idea.supplyEvidence)
        var withoutMatch = idea; withoutMatch.supplyEvidence = nil
        let unresolved = try XCTUnwrap(preview(withoutMatch).first)
        XCTAssertEqual(unresolved.credited?.amount, .zero); XCTAssertEqual(unresolved.uncovered?.amount, q(4).amount)
        XCTAssertNil(unresolved.packs); XCTAssertNil(unresolved.cost)
    }

    func testDraftShopUsesNamedListReservationsBeforeCheckout() throws {
        var shop = ShoppingLedger()
        let food = try shop.addManualLine(name: "Tortillas", quantity: q(6))
        let manual = try XCTUnwrap(shop.contributions(forLineID: food).first)
        try shop.addProtectedNeed(name: "Tortillas", quantity: q(2), purpose: "School lunch", within: manual.id)
        var workspace = LedgerWorkspace()
        workspace.shops = [shop]
        let scope = UUID(), ingredient = MealIngredient(name: "Dinner tortillas", quantity: q(4))
        var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "v1", template: .init(title: "Wraps", ingredients: [ingredient]), createdAt: now)
        idea.supplyEvidence = [.init(ingredient: ingredient, workspaceID: scope, shopID: shop.id, basisRevision: shop.basisRevision,
                                      foodID: food, pack: nil, source: nil, observedAt: nil)]
        var pickup = PickupJourney(id: shop.id, savedAt: now)
        pickup.stockLots = [.init(id: UUID(), foodID: food, name: "Tortillas", usable: q(3), confirmedAt: now)]
        let rows = try DinnerIdeaSupplyReview.rows(idea: idea, shop: shop, workspace: workspace, workspaceID: scope, journey: pickup, at: now)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.reservations.map(\.name), ["School lunch"])
        XCTAssertEqual(row.credited?.amount, .one)
        XCTAssertEqual(row.uncovered?.amount, q(3).amount)
    }

    func testRepeatedFoodUsesStockOnceAndNeverReusesForeignOrIncompatiblePackTerms() throws {
        let shop = ShoppingLedger(), scope = UUID(), food = UUID()
        var workspace = LedgerWorkspace(); workspace.shops = [shop]
        let first = MealIngredient(name: "Wraps for dinner", quantity: q(2)), second = MealIngredient(name: "Wraps for lunch", quantity: q(2))
        var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "v1", template: .init(title: "Wraps", ingredients: [first, second]), createdAt: now)
        var pickup = PickupJourney(id: shop.id, savedAt: now)
        pickup.stockLots = [.init(id: UUID(), foodID: food, name: "Sesame wraps", usable: q(1), confirmedAt: now)]
        func evidence(_ item: MealIngredient, _ pack: PackOffer?, revision: Int = 0) -> DinnerIdeaFoodEvidence {
            .init(ingredient: item, workspaceID: scope, shopID: shop.id, basisRevision: revision, foodID: food, pack: pack,
                  source: pack == nil ? nil : "Bag", observedAt: pack == nil ? nil : now)
        }
        func rows(_ scope: UUID) throws -> [IdeaSupplyRow] {
            try DinnerIdeaSupplyReview.rows(idea: idea, shop: shop, workspace: workspace, workspaceID: scope, journey: pickup, at: now)
        }
        let pack = PackOffer(id: "p", label: "Five", usableQuantity: q(5), price: nil)
        idea.supplyEvidence = [evidence(first, pack), evidence(second, nil)]
        let result = try rows(scope)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].uncovered?.amount, q(3).amount)
        XCTAssertEqual(result[0].packs, 1); XCTAssertNil(result[0].cost)
        XCTAssertEqual(try rows(UUID()).count, 2)
        idea.supplyEvidence = [evidence(first, pack, revision: shop.basisRevision + 1), evidence(second, nil)]
        XCTAssertNil(try rows(scope)[0].packs)
        idea.supplyEvidence = [evidence(first, PackOffer(id: "g", label: "Grams", usableQuantity: q(3, .gram), price: .zero)), evidence(second, nil)]
        XCTAssertNil(try rows(scope)[0].cost)
        let reviews = idea.supplyEvidence
        idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "v1", template: idea.template, hardExclusions: ["Sesame"], createdAt: now)
        idea.supplyEvidence = reviews
        let excluded = try rows(scope)[0]
        XCTAssertTrue(excluded.excludedMatch)
        XCTAssertNil(excluded.credited)
        XCTAssertNil(excluded.packs)
    }
}
