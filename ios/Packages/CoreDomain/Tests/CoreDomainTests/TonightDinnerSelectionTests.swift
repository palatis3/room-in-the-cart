import XCTest
@testable import CoreDomain

final class TonightDinnerSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let workspaceID = UUID()
    private func access(_ shopID: UUID, at date: Date, actor: String = "adult") -> DinnerAccessContext {
        DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: actor, shopID: shopID, assignedShopperID: actor,
            canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0,
            verifiedAt: date, validUntil: date.addingTimeInterval(30))
    }
    private func recipe() -> MealTemplate {
        MealTemplate(title: "Rice", ingredients: [MealIngredient(name: "Rice", quantity: Quantity(amount: .one, unit: .cup, originalLiteral: "1"))])
    }
    private func selection(_ recipe: MealTemplate, shop: ShoppingLedger, isNew: Bool, workspace: LedgerWorkspace) throws -> TonightDinnerSelection {
        let rice = try XCTUnwrap(recipe.ingredients.first)
        let lot = ConfirmedStockLot(id: UUID(), foodID: UUID(), name: rice.name, usable: try XCTUnwrap(rice.quantity), confirmedAt: now)
        let match = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [rice.id: lot.foodID], globallyFreeLots: [lot],
                                                 unresolvedFoods: [], profile: workspace.dinnerPlanning.privateMealPreferences)
        return try TonightDinnerSelection.prepare(match: match, destination: shop, createsPickup: isNew, workspace: workspace,
            access: access(shop.id, at: now), phase: .draft, now: now)
    }

    func testPlannedDayAndHandCheckedSeasoningRemainDistinctFromNumericCoverage() throws {
        var meal = recipe()
        let seasoning = MealIngredient(name: "cilantro al gusto", quantity: nil, checkedWithoutAmount: true)
        meal.ingredients.append(seasoning)
        let lentils = meal.ingredients[0], lot = ConfirmedStockLot(id: UUID(), foodID: UUID(), name: "Rice",
            usable: try XCTUnwrap(lentils.quantity), confirmedAt: now)
        let stock = [lot], shop = ShoppingLedger(title: "Market")
        var workspace = LedgerWorkspace(shops: [shop], mealTemplates: [meal], selectedShopID: shop.id)
        let match = try PantryMealMatcher.review(recipe: meal, reviewedFoods: [lentils.id: lot.foodID, seasoning.id: lot.foodID],
            globallyFreeLots: stock, unresolvedFoods: [], profile: nil)
        XCTAssertEqual(match.numericIngredients.map(\.id), [lentils.id])
        XCTAssertNil(match.ingredients.last?.coverage)
        XCTAssertNil(match.ingredients.last?.foodID)
        XCTAssertTrue(match.canChooseUsingPantry)
        XCTAssertFalse(match.allIngredientsCovered)
        let friday = now.addingTimeInterval(3 * 86_400)
        let choice = try TonightDinnerSelection.prepare(match: match, destination: shop, createsPickup: false, workspace: workspace,
            access: access(shop.id, at: now), phase: .draft, now: now, plannedDate: friday)
        try choice.apply(to: &workspace, access: access(shop.id, at: now), phase: .draft, now: now)
        XCTAssertEqual(workspace.shops[0].mealOccurrences.first?.scheduledDay, try MealDay(date: friday, timeZoneIdentifier: shop.basis.timeZoneIdentifier))
        let savedSeasoning = try XCTUnwrap(workspace.shops[0].contributions.first { $0.productName == seasoning.name })
        XCTAssertEqual(savedSeasoning.checkedWithoutAmount, true)
        XCTAssertNil(savedSeasoning.quantity)
        meal.ingredients[1].checkedWithoutAmount = nil
        let unresolved = try PantryMealMatcher.review(recipe: meal, reviewedFoods: [lentils.id: lot.foodID],
            globallyFreeLots: stock, unresolvedFoods: [], profile: nil)
        XCTAssertFalse(unresolved.canChooseUsingPantry)
    }

    func testCookSoonSearchAndLegacyWorkspaceRoundTrip() throws {
        let recipes = (1...74).map { MealTemplate(title: "Dinner " + String($0)) } +
            [MealTemplate(title: "Sopa de lentejas", ingredients: [.init(name: "Cilantro", quantity: nil, originalWording: "Cílandro al gusto")])]
        XCTAssertEqual(recipes.filter { $0.matchesRecipeSearch("sopa CILANTRO") }.count, 1)
        XCTAssertEqual(recipes.filter { $0.matchesRecipeSearch("cilandro") }.count, 1)
        let meal = try XCTUnwrap(recipes.last)
        var workspace = LedgerWorkspace(mealTemplates: recipes)
        let original = try JSONEncoder().encode(workspace)
        XCTAssertFalse(String(decoding: original, as: UTF8.self).contains("cookSoonPins"))
        workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: original)
        let pin = CookSoonPin(owner: "adult", recipe: .reviewed(meal.id))
        try workspace.setCookSoon(pin, pinned: true)
        try workspace.setCookSoon(pin, pinned: true)
        let reopened = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(reopened.cookSoonPins, [pin])
        XCTAssertFalse(reopened.cookSoonPins.contains(.init(owner: "other", recipe: .reviewed(meal.id))))
        try workspace.setCookSoon(pin, pinned: false)
        XCTAssertTrue(workspace.cookSoonPins.isEmpty)
    }

    func testZeroShopPreviewCreatesNothingAndConfirmedReplayPreservesLaterSelection() throws {
        let meal = recipe(), shop = ShoppingLedger(title: "Tuesday pickup")
        var workspace = LedgerWorkspace(mealTemplates: [meal])
        let review = try selection(meal, shop: shop, isNew: true, workspace: workspace)
        XCTAssertTrue(workspace.shops.isEmpty)
        XCTAssertNil(workspace.selectedShopID)
        XCTAssertEqual(review.preview.changedOccurrenceIDs.count, 1)
        try review.apply(to: &workspace, access: access(shop.id, at: now), phase: .draft, now: now)
        XCTAssertEqual(workspace.selectedShopID, shop.id)
        XCTAssertEqual(workspace.shops[0].mealOccurrences.map(\.id), review.preview.changedOccurrenceIDs)
        XCTAssertEqual(workspace.dinnerPlanning.applyReceipts.count, 1)
        let later = ShoppingLedger()
        workspace.shops.append(later)
        workspace.selectedShopID = later.id
        let saved = workspace
        try review.apply(to: &workspace, access: access(shop.id, at: now), phase: .reportedPlaced, now: now)
        XCTAssertEqual(workspace, saved)
        XCTAssertThrowsError(try review.apply(to: &workspace, access: access(shop.id, at: now, actor: "other"), phase: .draft, now: now))
        XCTAssertEqual(workspace, saved)
        try workspace.validate()
    }

    func testChangedRecipePlacedPickupOrNextDayCannotApplyAnOldPreview() throws {
        let meal = recipe(), shop = ShoppingLedger(title: "Tuesday pickup")
        var workspace = LedgerWorkspace(shops: [shop], mealTemplates: [meal], selectedShopID: shop.id)
        let review = try selection(meal, shop: shop, isNew: false, workspace: workspace)
        let saved = workspace
        XCTAssertThrowsError(try review.apply(to: &workspace, access: access(shop.id, at: now), phase: .reportedPlaced, now: now))
        let tomorrow = now.addingTimeInterval(24 * 3600)
        XCTAssertThrowsError(try review.apply(to: &workspace, access: access(shop.id, at: tomorrow), phase: .draft, now: tomorrow))
        XCTAssertEqual(workspace, saved)
        workspace.mealTemplates[0].revision += 1
        let changed = workspace
        XCTAssertThrowsError(try review.apply(to: &workspace, access: access(shop.id, at: now), phase: .draft, now: now))
        XCTAssertEqual(workspace, changed)
    }

    func testChangingDestinationBeforeCreatingPickupLeavesNoPartialShop() throws {
        let meal = recipe(), destination = ShoppingLedger(title: "New"), existing = ShoppingLedger(title: "Existing")
        var workspace = LedgerWorkspace(shops: [existing], mealTemplates: [meal])
        let review = try selection(meal, shop: destination, isNew: true, workspace: workspace)
        workspace.selectedShopID = existing.id
        let before = workspace
        XCTAssertThrowsError(try review.apply(to: &workspace, access: access(destination.id, at: now), phase: .draft, now: now))
        XCTAssertEqual(workspace, before)
    }
}
