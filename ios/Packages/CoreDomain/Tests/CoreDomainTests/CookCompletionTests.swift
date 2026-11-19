import XCTest
@testable import CoreDomain

final class CookCompletionTests: XCTestCase {
    private let origin = UUID(), ledger = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64) throws -> Quantity { .init(amount: try Rational(amount), unit: .count, originalLiteral: String(amount)) }
    private func lot(_ name: String, count: Int64, food: UUID = UUID()) throws -> InventoryLot {
        InventoryLot(id: UUID(), foodID: food, name: name, source: .manual(originID: origin, sourceID: UUID()),
            revision: 1, location: .cupboard, unit: .count, count: .exact(try q(count)), observationID: UUID(),
            confirmedAt: now, updatedAt: now)
    }
    private func makeMeal() throws -> (ShoppingLedger, MealOccurrence) {
        var shop = ShoppingLedger(title: "Groceries")
        let ingredients = try ["Wraps", "Salt", "Oil"].map { MealIngredient(name: $0, quantity: try q(1)) }
        let recipe = MealTemplate(title: "Tacos", servings: try Rational(4), ingredients: ingredients)
        _ = try shop.chooseMeal(recipe, at: now)
        return (shop, try XCTUnwrap(shop.mealOccurrences.first))
    }
    private func evaluate(_ draft: CookCompletionDraft, _ shop: ShoppingLedger, _ lots: [InventoryLot],
                          _ holds: [InventoryReservation] = [], owned: [UUID: Set<UUID>] = [:]) throws -> CookCompletion.Review {
        try CookCompletion.review(draft, inventoryID: origin, inventoryRevision: 6, ledgerID: ledger, shop: shop,
                                  lots: lots, reservations: holds, mealClaims: owned, at: now)
    }
    func testCookReviewRequiresEveryLiveContributionAndAcceptsAnExplicitlyEmptyDinner() throws {
        var (shop, meal) = try makeMeal()
        func draft(_ ids: [UUID]) -> CookCompletionDraft {
            CookCompletionDraft(inventoryID: origin, inventoryRevision: 6, ledgerID: ledger, shop: shop, meal: meal,
                cookedAt: now, servingsMade: .one, parts: ids.map { .init(contributionID: $0, use: .notUsed) }, leftovers: [])
        }
        let original = draft(meal.ingredientContributionIDs)
        let bytes = try JSONEncoder().encode(original)
        let originalFields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(originalFields["activeContributionIDs"])
        XCTAssertEqual(try JSONDecoder().decode(CookCompletionDraft.self, from: bytes), original)
        XCTAssertNoThrow(try evaluate(original, shop, []))

        try shop.removeContribution(contributionID: meal.ingredientContributionIDs[1], at: now)
        let active = [meal.ingredientContributionIDs[0], meal.ingredientContributionIDs[2]]
        let current = draft(active)
        XCTAssertEqual(current.ingredientRowIDs, active)
        XCTAssertNoThrow(try evaluate(current, shop, []))
        let incomplete = draft([active[0]])
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(incomplete)) as? [String: Any])
        forged["activeContributionIDs"] = [active[0].uuidString]
        let forgedDraft = try JSONDecoder().decode(CookCompletionDraft.self, from: JSONSerialization.data(withJSONObject: forged))
        XCTAssertThrowsError(try evaluate(forgedDraft, shop, []))
        for id in active { try shop.removeContribution(contributionID: id, at: now) }
        let empty = draft([])
        XCTAssertEqual(empty.ingredientRowIDs, [])
        XCTAssertTrue(try evaluate(empty, shop, []).changes.isEmpty)
    }

    func testActualSplitUseAndTwoLeftoversKeepUntrackedSaltAndUnknownOilDistinct() throws {
        let (shop, meal) = try makeMeal(), ids = meal.ingredientContributionIDs
        let wraps = try lot("Corn wraps", count: 4), other = try lot("Flour wraps", count: 2)
        let oil = try lot("Oil", count: 1)
        let lunch = InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: wraps.foodID, lotID: wraps.id,
            name: "Tomorrow's lunch", amount: try q(2), priority: .protected, personal: .init(day: nil))
        let oilHold = InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: oil.foodID, lotID: oil.id,
            name: "Other meal", amount: try q(1))
        let salt = CookCompletionDraft.Part(contributionID: ids[1], use: .untracked)
        let unknown = CookCompletionDraft.Part(contributionID: ids[2], use: .lot(id: oil.id, revision: 1, amount: nil))
        let leftovers = CookCompletionDraft.Leftovers(name: "Cooked tacos", portions: try Rational(2), location: .fridge)
        let draft = CookCompletionDraft(inventoryID: origin, inventoryRevision: 6, ledgerID: ledger, shop: shop, meal: meal, cookedAt: now,
            servingsMade: try Rational(3), parts: [
                .init(contributionID: ids[0], use: .lot(id: wraps.id, revision: 1, amount: try q(2))),
                .init(contributionID: ids[0], use: .lot(id: other.id, revision: 1, amount: try q(1)), substitution: "Flour wraps"),
                salt, unknown
            ], leftovers: [leftovers])
        let stock = [wraps, other, oil], holds = [lunch, oilHold]
        let result = try evaluate(draft, shop, stock, holds)
        XCTAssertEqual(result, try evaluate(JSONDecoder().decode(CookCompletionDraft.self, from: JSONEncoder().encode(draft)), shop, stock, holds))
        XCTAssertEqual(result.unresolvedUseIDs, [salt.id, unknown.id])
        XCTAssertEqual(result.affectedHolds.map(\.id), [oilHold.id])
        XCTAssertTrue(result.needsInventoryReview)
        XCTAssertEqual(result.availability.lots.first { $0.id == wraps.id }?.free?.amount, .zero)
        XCTAssertEqual(result.availability.lots.first { $0.id == other.id }?.free?.amount, .one)
        XCTAssertNil(result.availability.lots.first { $0.id == oil.id }?.free)
        XCTAssertEqual(result.availability.lots.first { $0.id == leftovers.id }?.free?.amount, try Rational(2))
        XCTAssertEqual(result.changes.count, 4)
        XCTAssertEqual(wraps.count, .exact(try q(4)))
        var excess = draft
        excess.leftovers = [.init(name: "Too many portions", portions: try Rational(4), location: .freezer)]
        XCTAssertThrowsError(try evaluate(excess, shop, stock, holds))
    }

    func testOwnClaimCanBeFulfilledOnceAndOtherReservationsCannotBeSpent() throws {
        let (shop, meal) = try makeMeal(), ids = meal.ingredientContributionIDs
        let wraps = try lot("Wraps", count: 4)
        func hold(_ name: String, _ count: Int64) throws -> InventoryReservation {
            .init(id: UUID(), originID: origin, revision: 1, foodID: wraps.foodID, lotID: wraps.id, name: name, amount: try q(count))
        }
        let claim = try hold("Tacos", 2), protected = try hold("Tomorrow", 1)
        var draft = CookCompletionDraft(inventoryID: origin, inventoryRevision: 6, ledgerID: ledger, shop: shop, meal: meal,
            cookedAt: now, servingsMade: .one, parts: [
                .init(contributionID: ids[0], use: .lot(id: wraps.id, revision: 1, amount: try q(3))),
                .init(contributionID: ids[1], use: .notUsed), .init(contributionID: ids[2], use: .notUsed)
            ], leftovers: [])
        XCTAssertThrowsError(try evaluate(draft, shop, [wraps], [claim, protected]))
        let review = try evaluate(draft, shop, [wraps], [claim, protected], owned: [ids[0]: [claim.id]])
        XCTAssertEqual(review.reservations.map(\.state), [.released])
        XCTAssertEqual(review.reservations.map(\.id), [claim.id])
        XCTAssertTrue(review.unresolvedUseIDs.isEmpty)
        XCTAssertTrue(review.affectedHolds.isEmpty)
        XCTAssertEqual(review.availability.lots.first?.remaining?.amount, .one)
        var changedShop = shop
        try changedShop.updateMeal(occurrenceID: meal.id, title: "Later plan", notes: "", at: now)
        XCTAssertThrowsError(try evaluate(draft, changedShop, [wraps], [claim, protected], owned: [ids[0]: [claim.id]]))
        draft.parts.removeLast()
        XCTAssertThrowsError(try evaluate(draft, shop, [wraps], [claim, protected], owned: [ids[0]: [claim.id]]))
    }
    func testRecoveredDinnerMustMatchTheReviewedReplacementAndItsPortionNeedRows() throws {
        let (shop, original) = try makeMeal()
        let beans = try lot("Beans", count: 4)
        let ingredient = UUID()
        let ids = [UUID(), UUID()]
        func replacement(revision: UUID) throws -> RecoveryMeal {
            let groups = try [1, 3].enumerated().map { offset, amount in
                RecoveryIngredient(ingredientID: ingredient, groupID: nil, foodName: beans.name,
                    need: StockNeed(id: ids[offset], foodID: beans.foodID, name: beans.name,
                        amount: try q(Int64(amount)), priority: .required))
            }
            return RecoveryMeal(id: original.id, revisionID: revision, templateID: nil, templateVersion: nil,
                title: "Beans for dinner", servings: try Rational(4), ingredients: groups, scheduledDay: nil,
                due: nil, timeZoneID: "UTC", exclusions: [], remainingElapsedMinutes: nil,
                requiredLeadMinutes: nil, advanceStepsCompleted: false)
        }
        let current = try replacement(revision: UUID())
        let draft = CookCompletionDraft(inventoryID: origin, inventoryRevision: 6, ledgerID: ledger, shop: shop,
            meal: original, cookedAt: now, servingsMade: try Rational(4),
            parts: try current.ingredients.map { row in .init(contributionID: row.need.id,
                use: .lot(id: beans.id, revision: 1, amount: try q(1))) }, leftovers: [], recoveredMeal: current)
        func check(_ draft: CookCompletionDraft, against current: RecoveryMeal?) throws -> CookCompletion.Review {
            try CookCompletion.review(draft, inventoryID: origin, inventoryRevision: 6, ledgerID: ledger, shop: shop,
                lots: [beans], reservations: [], mealClaims: [:], at: now, recoveredMeal: current)
        }
        let checked = try check(draft, against: current)
        XCTAssertEqual(checked.changes.count, 1)
        XCTAssertEqual(checked.changes.first?.lot.count.quantity?.amount, try Rational(2))
        XCTAssertThrowsError(try check(draft, against: replacement(revision: UUID())))
        XCTAssertThrowsError(try check(draft, against: nil))
        var stale = draft
        stale.parts = original.ingredientContributionIDs.map { .init(contributionID: $0, use: .notUsed) }
        XCTAssertThrowsError(try check(stale, against: current))
    }

}
