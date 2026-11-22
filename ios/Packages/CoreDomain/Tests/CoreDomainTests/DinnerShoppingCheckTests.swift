import XCTest
@testable import CoreDomain

final class DinnerShoppingCheckTests: XCTestCase {
    private func q(_ n: Int64, _ unit: UnitOfMeasure = .cup) -> Quantity {
        Quantity(amount: try! Rational(n), unit: unit, originalLiteral: String(n))
    }

    func testBowlDinnerForThreeShowsOnlyTomatoesAndKeepsAllOriginalNeeds() throws {
        let recipe = MealTemplate(title: "Lentil and tomato bowls", servings: try Rational(2), ingredients: [
            .init(name: "Lentils", quantity: q(1)), .init(name: "Tomatoes", quantity: q(2, .count)), .init(name: "Rice", quantity: q(1))
        ])
        var shop = ShoppingLedger(title: "After work market")
        _ = try shop.addManualLine(name: "Coffee", quantity: q(1, .count))
        let servings = try Rational(3), now = Date()
        let day = try MealDay(date: now, timeZoneIdentifier: shop.basis.timeZoneIdentifier)
        let access = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "adult", shopID: shop.id,
            assignedShopperID: "adult", canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0,
            verifiedAt: now, validUntil: now.addingTimeInterval(30))
        var workspace = LedgerWorkspace(shops: [shop], mealTemplates: [recipe], selectedShopID: shop.id)
        let plan = try SavedDinnerReview(recipe: recipe, action: .plan(day: day, servings: servings), workspace: workspace,
            access: access, phase: .draft, at: now)
        try plan.apply(to: &workspace, access: access, phase: .draft, at: now)
        shop = workspace.shops[0]
        let meal = try XCTUnwrap(plan.occurrenceID)
        let prior = shop
        let check = try DinnerShoppingCheck(shop: shop, occurrenceID: meal, savedTemplates: [recipe])
        let rows = check.recipe.ingredients
        let lots = [
            ConfirmedStockLot(id: UUID(), foodID: UUID(), name: "Lentils", usable: q(2), confirmedAt: Date()),
            ConfirmedStockLot(id: UUID(), foodID: UUID(), name: "Rice", usable: q(3), confirmedAt: Date())
        ]
        let choices = [rows[0].id: lots[0].foodID, rows[2].id: lots[1].foodID]
        func remaining(_ matches: [UUID: UUID]) throws -> [DinnerShoppingCheck.Remainder] {
            try PantryMealMatcher.review(recipe: check.recipe, reviewedFoods: matches, globallyFreeLots: lots,
                unresolvedFoods: [], profile: nil).ingredients.map(DinnerShoppingCheck.remainder)
        }
        XCTAssertEqual(check.recipe.servings, servings)
        XCTAssertEqual(try remaining(choices), [.covered, .buy(q(2, .count)), .covered])
        XCTAssertEqual(try remaining([:]), [.buy(q(1)), .buy(q(2, .count)), .buy(q(1))])
        XCTAssertEqual(shop, prior)
        XCTAssertEqual(check.lineIDs.count, 3)
    }

    func testSharedLineUsesOnlyThisDinnerAmountAndWaitsForOtherUnallocatedPurposes() throws {
        var shop = ShoppingLedger(title: "Groceries")
        let food = try shop.addManualLine(name: "Rice", quantity: q(6))
        let typed = try XCTUnwrap(shop.contributions(forLineID: food).first)
        let recipe = MealTemplate(title: "Dinner", ingredients: [.init(name: "Rice", quantity: q(1))])
        let dinner = try shop.chooseMeal(recipe)
        let source = try XCTUnwrap(shop.mealOccurrences.first?.ingredientContributionIDs.first)
        try shop.linkContribution(contributionID: source, within: typed.id, quantity: q(1))
        let first = try DinnerShoppingCheck(shop: shop, occurrenceID: dinner, savedTemplates: [])
        XCTAssertTrue(first.foodsAwaitingAllocation(in: [shop], matched: [food], currentCheckoutLines: [:]).isEmpty)
        try shop.addProtectedNeed(name: "Rice", quantity: q(2), purpose: "Lunch", within: typed.id)
        let original = shop
        let restored = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        let check = try DinnerShoppingCheck(shop: restored, occurrenceID: dinner, savedTemplates: [])
        XCTAssertEqual(check.recipe.ingredients.map(\.quantity), [q(1)])
        XCTAssertEqual(check.foodsAwaitingAllocation(in: [restored], matched: [food], currentCheckoutLines: [:]), [food])
        XCTAssertTrue(check.foodsAwaitingAllocation(in: [restored], matched: [food], currentCheckoutLines: [shop.id: [food]]).isEmpty)
        XCTAssertEqual(shop, original)
    }

    func testRepeatedMatchesShareFreeStockAndUnknownAmountsStayForReview() throws {
        let recipe = MealTemplate(title: "Rice bowls", ingredients: [
            .init(name: "Rice", quantity: q(2)), .init(name: "Rice", quantity: q(2)),
            .init(name: "Salt", quantity: nil, checkedWithoutAmount: true), .init(name: "Pepper", quantity: nil)
        ])
        var shop = ShoppingLedger(title: "Shop")
        let id = try shop.chooseMeal(recipe)
        let check = try DinnerShoppingCheck(shop: shop, occurrenceID: id, savedTemplates: [])
        let food = UUID(), rice = Array(check.recipe.ingredients.prefix(2))
        let matches = Dictionary(uniqueKeysWithValues: rice.map { ($0.id, food) })
        let origin = UUID(), lotID = UUID(), now = Date()
        let seed = InventoryLotSeed(foodID: food, name: "Rice", source: .manual(originID: origin, sourceID: lotID),
            location: .cupboard, unit: .cup, count: .exact(q(3)))
        let lot = try InventoryEngine.prepare(InventoryCommand(id: UUID(), originID: origin, lotID: lotID, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(seed, observationID: UUID())), current: nil, at: now).lot
        let lunch = InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: food, lotID: lotID,
            name: "Lunch", amount: q(2), priority: .protected, personal: .init(day: nil))
        let physical = try InventoryProjection.build(originID: origin, lots: [lot], reservations: [lunch], at: now)
        let free = ConfirmedStockLot(id: lotID, foodID: food, name: "Rice", usable: try XCTUnwrap(physical.lots.first?.free), confirmedAt: now)
        XCTAssertEqual(free.usable.amount, .one)
        func review(lot: ConfirmedStockLot, unresolved: Set<UUID> = []) throws -> [DinnerShoppingCheck.Remainder] {
            try PantryMealMatcher.review(recipe: check.recipe, reviewedFoods: matches, globallyFreeLots: [lot],
                unresolvedFoods: unresolved, profile: nil).ingredients.map(DinnerShoppingCheck.remainder)
        }
        let result = try review(lot: free)
        XCTAssertTrue(result.prefix(2).contains(.buy(q(1))))
        XCTAssertTrue(result.prefix(2).contains(.buy(q(2))))
        XCTAssertEqual(Array(result.suffix(2)), [.checkAmount, .checkAmount])
        XCTAssertEqual(try review(lot: free, unresolved: [food]), Array(repeating: .checkAmount, count: 4))
        let incompatible = ConfirmedStockLot(id: UUID(), foodID: food, name: "Rice bag", usable: q(1, .count), confirmedAt: Date())
        XCTAssertEqual(try review(lot: incompatible), Array(repeating: .checkAmount, count: 4))
    }
}
