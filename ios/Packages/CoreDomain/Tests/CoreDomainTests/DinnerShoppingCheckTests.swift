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

extension DinnerShoppingCheckTests {
    func testLinkedProductsSurviveReopenInEnglishAndSpanishWithFullMealNeeds() throws {
        for names in [["After work market", "Lentils", "Rice", "Tomatoes", "Coffee"],
                      ["Mercado después del trabajo", "Lentejas", "Arroz", "Tomates", "Café"]] {
            let now = Date(), origin = UUID(), ledgerID = UUID(), rice = UUID(), lentils = UUID()
            var destination = ShoppingLedger(title: names[0])
            _ = try destination.addManualLine(name: names[4], quantity: q(1, .count))
            let weekend = ShoppingLedger(title: "Weekend")
            let recipe = MealTemplate(title: "Bowls", ingredients: [.init(name: names[1], quantity: q(1)),
                .init(name: names[2], quantity: q(1)), .init(name: names[3], quantity: q(2, .count))])
            let initial = LedgerWorkspace(shops: [destination, weekend], mealTemplates: [recipe], selectedShopID: destination.id)
            let lots = [ConfirmedStockLot(id: UUID(), foodID: lentils, name: names[1], usable: q(2), confirmedAt: now),
                        ConfirmedStockLot(id: UUID(), foodID: rice, name: names[2], usable: q(3), confirmedAt: now)]
            let reviewed = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [recipe.ingredients[0].id: lentils,
                recipe.ingredients[1].id: rice], globallyFreeLots: lots, unresolvedFoods: [], profile: nil)
            let access = DinnerAccessContext(scope: .local(workspaceID: ledgerID), actorID: "adult", shopID: destination.id,
                assignedShopperID: "adult", canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0,
                verifiedAt: now, validUntil: now.addingTimeInterval(30))
            let plan = try SavedDinnerReview(recipe: recipe, action: .plan(day: MealDay(date: now, timeZoneIdentifier:
                destination.basis.timeZoneIdentifier), servings: Rational(3)), workspace: initial, access: access,
                phase: .draft, at: now, pantryReview: (reviewed, origin))
            var workspace = initial
            XCTAssertFalse(plan.isApplied(in: workspace))
            try plan.apply(to: &workspace, access: access, phase: .draft, at: now)
            try plan.apply(to: &workspace, access: access, phase: .draft, at: now)
            let reopened = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
            try reopened.validate()
            let shop = reopened.shops[0], meal = try XCTUnwrap(shop.mealOccurrences.first)
            func linked(_ originID: UUID, owner: String) -> Set<UUID> {
                reopened.dinnerPantryLines(shop: shop, workspaceID: ledgerID, originID: originID, actorID: owner, occurrenceID: meal.id)
            }
            XCTAssertEqual(linked(origin, owner: "adult"), [rice, lentils])
            XCTAssertTrue(linked(UUID(), owner: "adult").isEmpty)
            XCTAssertTrue(linked(origin, owner: "other").isEmpty)
            XCTAssertEqual(reopened.shops[1], weekend)
            XCTAssertEqual(meal.servings, try Rational(3))
            XCTAssertEqual(reopened.dinnerPlanning.applyReceipts.count, 1)
            XCTAssertEqual(meal.ingredientContributionIDs.count, 3)
            XCTAssertEqual(try shop.quantity(forLineID: rice)?.amount, q(1).amount)
            XCTAssertEqual(try shop.quantity(forLineID: lentils)?.amount, q(1).amount)
            XCTAssertTrue(reopened.packSelections.isEmpty, "Linking alone never confirms a purchase decision.")
            XCTAssertEqual(shop.lines.count, 4)
            let groups = reopened.listLayout.groups(shop: shop, excluding: linked(origin, owner: "adult"))
            XCTAssertEqual(groups.flatMap(\.lines).map(\.name), [names[4], names[3]])
            XCTAssertThrowsError(try DinnerPantryProducts(review: reviewed, workspace: reopened, originID: origin))
            let tonight = try TonightDinnerSelection.prepare(match: reviewed, destination: destination, createsPickup: false,
                workspace: initial, access: access, phase: .draft, now: now, pantryProductOrigin: origin)
            workspace = initial
            try tonight.apply(to: &workspace, access: access, phase: .draft, now: now)
            XCTAssertEqual(workspace.dinnerPantryLines(shop: workspace.shops[0], workspaceID: ledgerID, originID: origin,
                actorID: "adult"), [rice, lentils])
        }
    }

    func testProductLinkRefusesPartialRepeatedUnknownAndAnExistingLineOnAnotherList() throws {
        var other = ShoppingLedger()
        let product = try other.addManualLine(name: "Protected lunch", quantity: q(3))
        let origin = UUID(), now = Date()
        let recipe = MealTemplate(title: "Soup", ingredients: [.init(name: "Beans", quantity: q(2)),
                                                               .init(name: "Beans", quantity: q(1))])
        let stock = ConfirmedStockLot(id: UUID(), foodID: product, name: "Beans", usable: q(3), confirmedAt: now)
        let initial = LedgerWorkspace()
        func matched(_ matches: [UUID: UUID], lots: [ConfirmedStockLot], unknown: Set<UUID> = []) throws -> PantryMealMatcher.Review {
            try PantryMealMatcher.review(recipe: recipe, reviewedFoods: matches, globallyFreeLots: lots,
                unresolvedFoods: unknown, profile: nil)
        }
        let one = [recipe.ingredients[0].id: product]
        let repeated = [recipe.ingredients[0].id: product, recipe.ingredients[1].id: product]
        XCTAssertThrowsError(try DinnerPantryProducts(review: matched(repeated, lots: [stock]), workspace: initial, originID: origin))
        XCTAssertThrowsError(try DinnerPantryProducts(review: matched(one, lots: []), workspace: initial, originID: origin))
        XCTAssertThrowsError(try DinnerPantryProducts(review: matched(one, lots: [stock], unknown: [product]), workspace: initial, originID: origin))
        let available = try DinnerPantryProducts(review: matched(one, lots: [stock]), workspace: initial, originID: origin)
        XCTAssertThrowsError(try available.verifyNewLines(in: LedgerWorkspace(shops: [other])))
    }
}

extension DinnerShoppingCheckTests {
    func testRealReservationProofKeepsDinnerDemandAndExcludesOtherProtectedStockAfterRelaunch() throws {
        typealias Evidence = LedgerCanonicalPackStockEvidence
        let now = Date(), origin = UUID(), ledgerID = UUID(), food = UUID(), lotID = UUID(), observation = UUID()
        let recipe = MealTemplate(title: "Dinner", ingredients: [.init(name: "Rice", quantity: q(1)),
                                                                .init(name: "Tomatoes", quantity: q(2, .count))])
        var shop = ShoppingLedger(title: "After work market")
        _ = try shop.addManualLine(name: "Coffee", quantity: q(1, .count))
        var workspace = LedgerWorkspace(shops: [shop], mealTemplates: [recipe], selectedShopID: shop.id)
        let access = DinnerAccessContext(scope: .local(workspaceID: ledgerID), actorID: "adult", shopID: shop.id,
            assignedShopperID: "adult", canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0, verifiedAt: now,
            validUntil: now.addingTimeInterval(30))
        let review = try PantryMealMatcher.review(recipe: recipe, reviewedFoods: [recipe.ingredients[0].id: food],
            globallyFreeLots: [.init(id: lotID, foodID: food, name: "Arroz", usable: q(1), confirmedAt: now)],
            unresolvedFoods: [], profile: nil)
        let plan = try SavedDinnerReview(recipe: recipe, action: .planTonight, workspace: workspace, access: access, phase: .draft,
            at: now, pantryReview: (review, origin))
        try plan.apply(to: &workspace, access: access, phase: .draft, at: now)
        shop = workspace.shops[0]
        let meal = try XCTUnwrap(shop.mealOccurrences.first)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: food)
        let need = StockNeed(id: meal.ingredientContributionIDs[0], foodID: food, name: meal.title, amount: q(1), priority: .required)
        let claim = InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: food, lotID: nil,
            name: meal.title, amount: q(1), priority: .required)
        let lunch = InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: food, lotID: lotID,
            name: "Other lunch", amount: q(2), priority: .protected)
        let source = InventorySource.manual(originID: origin, sourceID: UUID())
        var lot = InventoryLot(id: lotID, foodID: food, name: "Arroz", source: source, revision: 1, location: .cupboard,
            unit: .cup, count: .exact(q(3)), observationID: observation, confirmedAt: now, updatedAt: now)
        let basketID = UUID()
        func proof(_ revision: Int64) throws -> Evidence {
            let projection = try InventoryProjection.build(originID: origin, lots: [lot], reservations: [claim, lunch], at: now)
            return try Evidence.review(scope: .init(journeyID: shop.id, journeyRevision: 1, basketRevisionID: basketID,
                shopRevisionID: shop.revisionID, lineID: food), basis: .init(originID: origin, inventoryRevision: revision,
                    sourceHeads: [.init(journeyID: shop.id, revision: 1)]), requirement: requirement,
                claimBindings: [.init(need: need, reservationID: claim.id)], canonicalLots: [lot],
                canonicalReservations: [claim,lunch], projection: projection,
                eligibility: [.init(lotID: lot.id, source: source, observationID: lot.observationID, status: .eligible, receiptEvidenceDigest: nil)])
        }
        let current = try proof(1)
        let offerA = PackOffer(id: DinnerPantryProducts.atHomeOfferID, label: "Arroz en casa", usableQuantity: nil, price: nil)
        let offerB = PackOffer(id: DinnerPantryProducts.alternateOfferID, label: "Arroz en casa", usableQuantity: nil, price: nil)
        let choice = try LedgerPackSelection(workspaceID: ledgerID, shop: shop, lineID: food,
            request: .init(itemName: requirement.name, needed: requirement.quantity, confirmedAtHome: current.confirmedQuantity(for: requirement),
                protectedAmount: requirement.protectedQuantity, offerA: offerA, offerB: offerB), selectedOfferID: offerA.id, at: now,
            source: "Asignación de despensa", canonicalStockEvidence: current)
        XCTAssertTrue(choice.isNoPurchase)
        XCTAssertTrue(try workspace.recordPackSelection(choice, workspaceID: ledgerID, currentCanonicalEvidence: current))
        XCTAssertFalse(try workspace.recordPackSelection(choice, workspaceID: ledgerID, currentCanonicalEvidence: current))
        let saved = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        let reopenedChoice = try XCTUnwrap(saved.currentPackSelection(shopID: shop.id, lineID: food,
            workspaceID: ledgerID, currentCanonicalEvidence: current))
        XCTAssertTrue(reopenedChoice.isNoPurchase)
        XCTAssertEqual(saved.dinnerAuthorizedPacks(in: [choice], shop: shop, workspaceID: ledgerID, originID: origin, actorID: "adult"), [choice])
        XCTAssertTrue(saved.dinnerAuthorizedPacks(in: [choice], shop: shop, workspaceID: ledgerID, originID: origin, actorID: "other").isEmpty)
        XCTAssertTrue(saved.dinnerAuthorizedPacks(in: [choice], shop: shop, workspaceID: ledgerID, originID: UUID(), actorID: "adult").isEmpty)
        XCTAssertTrue(saved.dinnerAuthorizedPacks(in: [choice], shop: shop, workspaceID: ledgerID, originID: origin, actorID: nil).isEmpty)
        var missingReceipt = saved
        missingReceipt.dinnerPlanning = DinnerPlanningState()
        XCTAssertTrue(missingReceipt.dinnerAuthorizedPacks(in: [choice], shop: shop, workspaceID: ledgerID, originID: origin, actorID: "adult").isEmpty)
        var edited = saved
        try edited.shops[0].updateLine(lineID: food, name: "A different product", notes: "", aisle: "")
        XCTAssertTrue(edited.dinnerAuthorizedPacks(in: [choice], shop: edited.shops[0], workspaceID: ledgerID, originID: origin, actorID: "adult").isEmpty)
        XCTAssertEqual(saved.listLayout.groups(shop: shop, excluding: [reopenedChoice.lineID]).flatMap(\.lines).map(\.name), ["Coffee", "Tomatoes"])
        XCTAssertEqual(saved.shops[0].mealOccurrences[0], meal)
        XCTAssertEqual(saved.shops[0].contributions, shop.contributions)
        XCTAssertEqual(lot.count, .exact(q(3)))
        lot = InventoryLot(id: lotID, foodID: food, name: "Arroz", source: source, revision: 2, location: .cupboard,
            unit: .cup, count: .exact(q(2)), observationID: UUID(), confirmedAt: now, updatedAt: now)
        let recounted = try proof(2)
        XCTAssertEqual(try recounted.confirmedQuantity(for: requirement)?.amount, .zero)
        XCTAssertNil(try saved.currentPackSelection(shopID: shop.id, lineID: food, workspaceID: ledgerID, currentCanonicalEvidence: recounted))
        XCTAssertEqual(saved.listLayout.groups(shop: shop).flatMap(\.lines).map(\.name), ["Coffee","Rice","Tomatoes"])
    }
}
