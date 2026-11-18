import XCTest
@testable import CoreDomain

final class TonightPurchaseEstimateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func quantity(_ amount: Int64) throws -> Quantity {
        Quantity(amount: try Rational(amount), unit: .count, originalLiteral: String(amount))
    }

    func testRepeatedIngredientsShareOnePackageAndSavedPriceStaysWithItsShop() throws {
        let origin = UUID(), foodID = UUID(), shop = ShoppingLedger(title: "Market")
        let first = MealIngredient(name: "Wraps", quantity: try quantity(2))
        let second = MealIngredient(name: "Wraps", quantity: try quantity(2))
        let sauce = MealIngredient(name: "Sauce", quantity: try quantity(1))
        let recipe = MealTemplate(title: "Folded wraps", ingredients: [first, second, sauce])
        let stock = ConfirmedStockLot(id: UUID(), foodID: foodID, name: "Wraps", usable: try quantity(1), confirmedAt: now)
        let match = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [first.id: foodID, second.id: foodID],
            globallyFreeLots: [stock], unresolvedFoods: [], profile: nil)
        let access = DinnerAccessContext(scope: .local(workspaceID: origin), actorID: "a", shopID: shop.id, assignedShopperID: "a",
            canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(60))
        let pack = PackOffer(id: "wraps", label: "Three wraps", usableQuantity: try quantity(3), price: Money(minorUnits: 285))
        var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "reviewed", template: recipe, createdAt: now)
        idea.supplyEvidence = [first, second].map {
            DinnerIdeaFoodEvidence(ingredient: $0, workspaceID: origin, shopID: shop.id, basisRevision: shop.basisRevision,
                foodID: foodID, pack: pack, source: "Shelf label", observedAt: now)
        }
        var workspace = LedgerWorkspace(shops: [shop])
        try workspace.dinnerPlanning.saveIdea(idea, access: access, at: now)
        try workspace.dinnerPlanning.accept(AcceptedDinner(id: UUID(), template: recipe, acceptedAt: now, sourceIdeaID: idea.id),
                                           access: access, at: now)
        let estimate = try TonightPurchaseEstimate.estimate(match, workspace: workspace, workspaceID: origin, shopID: shop.id, at: now)
        XCTAssertEqual(estimate.packages.map(\.count), [1])
        XCTAssertEqual(estimate.subtotal?.minorUnits, 285)
        XCTAssertEqual(estimate.packages.first?.source, "Shelf label")
        XCTAssertFalse(estimate.complete, "Sauce has no reviewed price")
        let completeMatch = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [first.id: foodID, second.id: foodID, sauce.id: sauce.id],
            globallyFreeLots: [stock, ConfirmedStockLot(id: UUID(), foodID: sauce.id, name: sauce.name, usable: try quantity(1), confirmedAt: now)],
            unresolvedFoods: [], profile: nil)
        let completeEstimate = try TonightPurchaseEstimate.estimate(completeMatch, workspace: workspace, workspaceID: origin, shopID: shop.id, at: now)
        XCTAssertTrue(completeEstimate.complete)
        XCTAssertEqual(completeEstimate.subtotal?.minorUnits, 285)
        let sauceOnly = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [sauce.id: sauce.id],
            globallyFreeLots: [ConfirmedStockLot(id: UUID(), foodID: sauce.id, name: sauce.name,
                usable: try quantity(1), confirmedAt: now)], unresolvedFoods: [], profile: nil)
        let noWrapStock = try TonightPurchaseEstimate.estimate(sauceOnly, workspace: workspace,
            workspaceID: origin, shopID: shop.id, at: now)
        XCTAssertTrue(noWrapStock.complete)
        XCTAssertEqual(noWrapStock.packages.map(\.count), [2])
        XCTAssertEqual(noWrapStock.subtotal?.minorUnits, 570)
        for (workspaceID, shopID, date) in [(origin, UUID(), now), (UUID(), shop.id, now), (origin, shop.id, now.addingTimeInterval(-1))] {
            let unknown = try TonightPurchaseEstimate.estimate(match, workspace: workspace, workspaceID: workspaceID, shopID: shopID, at: date)
            XCTAssertNil(unknown.subtotal)
            XCTAssertFalse(unknown.complete)
        }
    }

    func testAllIngredientsCoveredNeedsZeroAdditionalPackagesEvenWithoutAPickup() throws {
        let food = UUID(), ingredient = MealIngredient(name: "Lime", quantity: try quantity(1))
        let recipe = MealTemplate(title: "Lime wedges", ingredients: [ingredient])
        let stock = ConfirmedStockLot(id: UUID(), foodID: food, name: "Lime", usable: try quantity(2), confirmedAt: now)
        let match = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [ingredient.id: food], globallyFreeLots: [stock],
            unresolvedFoods: [], profile: nil)
        let estimate = try TonightPurchaseEstimate.estimate(match, workspace: .init(), workspaceID: UUID(), shopID: nil, at: now)
        XCTAssertTrue(estimate.complete)
        XCTAssertEqual(estimate.subtotal, .zero)
        XCTAssertTrue(estimate.packages.isEmpty)
    }
}
