import XCTest
@testable import CoreDomain

final class TonightPurchaseEstimateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func quantity(_ amount: Int64) throws -> Quantity {
        Quantity(amount: try Rational(amount), unit: .count, originalLiteral: String(amount))
    }

    func testRepeatedIngredientsShareOnePackageAndSavedPriceStaysWithItsShop() throws {
        let origin = UUID(), foodID = UUID()
        let shop = ShoppingLedger(title: "Market", basis: ShopBasis(knownFees: Money(minorUnits: 599)))
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
        // The original pickup already has a fee. Only the $1.25 added for
        // the second meal is entered here, once even for repeated ingredients.
        let topUp = Money(minorUnits: 125)
        let priced = try completeEstimate.additionalCash(addedCharges: topUp, chargesComplete: true)
        XCTAssertEqual(priced.known?.minorUnits, 410)
        XCTAssertTrue(priced.complete)
        let moreFeesUnknown = try completeEstimate.additionalCash(addedCharges: topUp, chargesComplete: false)
        XCTAssertEqual(moreFeesUnknown.known?.minorUnits, 410)
        XCTAssertFalse(moreFeesUnknown.complete)
        let unknownFees = try completeEstimate.additionalCash(addedCharges: nil, chargesComplete: true)
        XCTAssertEqual(unknownFees.known?.minorUnits, 285)
        XCTAssertFalse(unknownFees.complete)
        let noAddedFee = try completeEstimate.additionalCash(addedCharges: .zero, chargesComplete: true)
        XCTAssertEqual(noAddedFee.known?.minorUnits, 285)
        XCTAssertTrue(noAddedFee.complete)
        let missingSauce = try estimate.additionalCash(addedCharges: topUp, chargesComplete: true)
        XCTAssertEqual(missingSauce.known?.minorUnits, 410)
        XCTAssertFalse(missingSauce.complete)
        XCTAssertThrowsError(try completeEstimate.additionalCash(addedCharges: Money(minorUnits: -1), chargesComplete: true))
        XCTAssertThrowsError(try completeEstimate.additionalCash(addedCharges: Money(minorUnits: .max), chargesComplete: true))
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
            let feeOnly = try unknown.additionalCash(addedCharges: topUp, chargesComplete: true)
            XCTAssertEqual(feeOnly.known, topUp)
            XCTAssertFalse(feeOnly.complete)
            XCTAssertNil(try unknown.additionalCash(addedCharges: nil, chargesComplete: false).known)
        }
    }

    func testSecondMealPricesOnlyPackagesBeyondTheFirstMeal() throws {
        let house = UUID(), wraps = UUID(), cheese = UUID()
        let shop = ShoppingLedger(title: "Market")
        let access = DinnerAccessContext(scope: .local(workspaceID: house), actorID: "a", shopID: shop.id,
            assignedShopperID: "a", canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 0,
            verifiedAt: now, validUntil: now.addingTimeInterval(60))
        let offer = PackOffer(id: "slices", label: "Four cheese slices", usableQuantity: try quantity(4),
                              price: Money(minorUnits: 400))
        var workspace = LedgerWorkspace(shops: [shop])
        func meal(_ title: String, slices: Int64, pack: PackOffer?, foodID: UUID = cheese,
                  extra: Bool = false, unit: UnitOfMeasure = .count, quoteSource: String = "Shelf label") throws -> MealTemplate {
            let wrap = MealIngredient(name: "Wrap", quantity: try quantity(1))
            let filling = MealIngredient(name: "Cheese", quantity: Quantity(amount: try Rational(slices), unit: unit, originalLiteral: String(slices)))
            let sauce = MealIngredient(name: "Sauce", quantity: try quantity(1))
            let result = MealTemplate(title: title, ingredients: [wrap, filling] + (extra ? [sauce] : []))
            var idea = DinnerIdeaDraft(requestID: UUID(), catalogVersion: "reviewed", template: result, createdAt: now)
            if let pack {
                idea.supplyEvidence = [DinnerIdeaFoodEvidence(ingredient: filling, workspaceID: house, shopID: shop.id,
                    basisRevision: shop.basisRevision, foodID: foodID, pack: pack, source: quoteSource, observedAt: now)]
            }
            try workspace.dinnerPlanning.saveIdea(idea, access: access, at: now)
            try workspace.dinnerPlanning.accept(AcceptedDinner(id: UUID(), template: result, acceptedAt: now,
                sourceIdeaID: idea.id), access: access, at: now)
            return result
        }
        // Only the two unreserved wraps enter the matcher. The protected stock cannot fund this pair.
        let confirmed = try quantity(5)
        let lot = ConfirmedStockLot(id: UUID(), foodID: wraps, name: "Wraps", usable: confirmed, confirmedAt: now)
        let protected = StockNeed(id: UUID(), foodID: wraps, name: "Protected dinner", amount: try quantity(3), priority: .protected)
        let allocation = try ConfirmedStockAllocator.allocate(lots: [lot], needs: [protected])
        let free = try XCTUnwrap(allocation.remainingLots.first)
        let unreserved = ConfirmedStockLot(id: lot.id, foodID: wraps, name: lot.name,
            usable: Quantity(amount: free.remainingUnallocated, unit: free.unit, originalLiteral: "2"), confirmedAt: now)
        XCTAssertEqual(unreserved.usable.amount, try Rational(2))
        func paired(_ first: MealTemplate, _ next: MealTemplate) throws -> TonightPurchaseEstimate {
            let review = try PantryMealMatcher.review(recipe: first, reviewedFoods: [first.ingredients[0].id: wraps],
                globallyFreeLots: [unreserved], unresolvedFoods: [], profile: nil, firstLotID: lot.id, projectRemainder: true)
            let remaining = try XCTUnwrap(review.stockAfterMeal)
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remaining[0].usable.amount, .one)
            let second = try PantryMealMatcher.review(recipe: next, reviewedFoods: [next.ingredients[0].id: wraps],
                globallyFreeLots: remaining, unresolvedFoods: [], profile: nil, firstLotID: lot.id)
            return try TonightPurchaseEstimate.estimate(second, after: review, workspace: workspace,
                                                        workspaceID: house, shopID: shop.id, at: now)
        }
        let first = try meal("First", slices: 1, pack: offer)
        let shared = try paired(first, meal("Second", slices: 1, pack: offer))
        XCTAssertTrue(shared.complete)
        XCTAssertTrue(shared.packages.isEmpty)
        XCTAssertEqual(shared.subtotal, .zero)
        let crossing = try paired(first, meal("Second with extra slices", slices: 4, pack: offer))
        XCTAssertTrue(crossing.complete)
        XCTAssertEqual(crossing.packages.map(\.count), [1])
        XCTAssertEqual(crossing.subtotal?.minorUnits, 400)
        let charged = try crossing.additionalCash(addedCharges: Money(minorUnits: 125), chargesComplete: true)
        XCTAssertEqual(charged.known?.minorUnits, 525)
        XCTAssertTrue(charged.complete)
        let partial = try paired(first, meal("Second with unpriced sauce", slices: 4, pack: offer, extra: true))
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(partial.subtotal?.minorUnits, 400)
        let conflict = try paired(first, meal("Different offer", slices: 1,
            pack: PackOffer(id: "other", label: "Two cheese slices", usableQuantity: try quantity(2), price: Money(minorUnits: 350))))
        XCTAssertFalse(conflict.complete)
        XCTAssertNil(conflict.subtotal)
        let incomparable = try paired(first, meal("Unconverted weight", slices: 1, pack: offer, unit: .gram))
        XCTAssertFalse(incomparable.complete)
        XCTAssertNil(incomparable.subtotal)
        let unverifiedOffer = try paired(first, meal("Separate observation", slices: 1, pack: offer, quoteSource: "Unrelated listing"))
        XCTAssertFalse(unverifiedOffer.complete)
        XCTAssertNil(unverifiedOffer.subtotal)
        let unidentifiedFirst = try meal("Unidentified filling", slices: 1, pack: nil)
        let uncertain = try paired(unidentifiedFirst, meal("Quoted second", slices: 1, pack: offer))
        XCTAssertFalse(uncertain.complete)
        XCTAssertNil(uncertain.subtotal)
        let distinct = try paired(first, meal("Separately identified filling", slices: 1, pack: offer, foodID: UUID()))
        XCTAssertTrue(distinct.complete)
        XCTAssertEqual(distinct.subtotal?.minorUnits, 400)
        XCTAssertEqual(unreserved.usable.amount, try Rational(2))
    }

    func testAllIngredientsCoveredNeedsZeroAdditionalPackagesEvenWithoutAPickup() throws {
        let food = UUID(), ingredient = MealIngredient(name: "Lime", quantity: try quantity(1))
        let recipe = MealTemplate(title: "Lime wedges", ingredients: [ingredient])
        let stock = ConfirmedStockLot(id: UUID(), foodID: food, name: "Lime", usable: try quantity(2), confirmedAt: now)
        let match = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [ingredient.id: food], globallyFreeLots: [stock],
            unresolvedFoods: [], profile: nil)
        let estimate = try TonightPurchaseEstimate.estimate(match, workspace: .init(), workspaceID: UUID(), shopID: nil, at: now)
        XCTAssertTrue(estimate.complete)
        XCTAssertEqual(estimate.subtotal, Money(minorUnits: 0, currency: .groceryDefault()))
        XCTAssertTrue(estimate.packages.isEmpty)
        let cash = try estimate.additionalCash(addedCharges: nil, chargesComplete: false)
        XCTAssertEqual(cash.known, estimate.subtotal)
        XCTAssertTrue(cash.complete)
    }
}
