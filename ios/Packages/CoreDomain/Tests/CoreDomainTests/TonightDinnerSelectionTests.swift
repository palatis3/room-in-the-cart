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
