import Foundation
import XCTest
@testable import CoreDomain

final class DinnerCostTests: XCTestCase {
    private struct Vector: Decodable {
        let currency, item, essential: String
        let servings, required, onHand, held, usablePerPack, packMinor, essentialMinor, feeThresholdMinor, feeMinor, capMinor: Int64
        let expected: Expected

        struct Expected: Decodable {
            let neededAfterStock, packs, packageMinor, ingredientMinor, perServingMinor, completeMinor, unknownFeeLowerMinor: Int64
        }
    }

    func testIngredientValuePackagesEssentialsAndPartialCheckoutUseDifferentBases() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/dinner-cost.json"))
        let vector = try JSONDecoder().decode(Vector.self, from: data)
        let expected = vector.expected
        func amount(_ value: Int64, _ unit: UnitOfMeasure = .count) throws -> Quantity {
            Quantity(amount: try Rational(value), unit: unit, originalLiteral: String(value))
        }
        let portions = try Rational(vector.servings)
        let ingredient = MealIngredient(name: vector.item, quantity: try amount(vector.required))
        let template = MealTemplate(title: "Lunch wraps", servings: portions, ingredients: [ingredient])
        let dinner = AcceptedDinner(id: UUID(), template: template, acceptedAt: Date())
        let meal = DinnerCommitment(name: "Lunch", kind: .dinner, portions: portions)
        let set = DinnerCommitmentSet(commitments: [meal])
        let food = UUID()
        let demand = DinnerDemand(commitmentID: meal.id, foodID: food, name: ingredient.name, quantity: ingredient.quantity,
            acceptedDinnerID: dinner.id, ingredientID: ingredient.id)
        let pantry = ConfirmedStockLot(id: UUID(), foodID: food, name: vector.item, usable: try amount(vector.onHand), confirmedAt: Date(), source: .pantry)
        let hold = StockNeed(id: UUID(), foodID: food, name: "Tomorrow's lunch", amount: try amount(vector.held), priority: .protected)
        let essential = CheckoutLine(id: UUID(), name: vector.essential, cost: .exact(Money(minorUnits: vector.essentialMinor)), thresholdEligible: false)
        let context = CheckoutContext(storeID: "market", branchID: "main", mode: .pickup, slot: "today",
            commitmentsID: set.id, observedAt: Date(), source: "Shelf label")
        let cap = CheckoutCap(scope: .wholeCheckout, commitmentsID: set.id, amount: Money(minorUnits: vector.capMinor))
        func evaluate(price: Int64, fee: CostEvidence, unit: UnitOfMeasure = .count,
                      availability: DinnerAvailability = .confirmed(maximumPacks: nil)) throws -> DinnerScenarioResult {
            let offer = PackOffer(id: "wrap-pack", label: vector.item,
                usableQuantity: try amount(vector.usablePerPack, unit), price: Money(minorUnits: price))
            let pack = DinnerPackSelection(foodID: food, offer: offer, availability: availability)
            let feeRule = CheckoutFeeRule.waivedAt(threshold: Money(minorUnits: vector.feeThresholdMinor),
                belowThreshold: fee, basis: .eligibleItemsBeforeDiscounts)
            let scenario = DinnerScenario(commitments: set, acceptedDinnerIDs: [dinner.id], demands: [demand],
                stock: [pantry], otherReservations: [hold], packs: [pack], baselineLines: [essential], baselineComplete: true,
                fees: [CheckoutFee(id: "pickup", rule: feeRule)], tax: .exact(.zero), deposits: .exact(.zero),
                context: context, preparation: .init(handsOnMinutes: 5, remainingLeadMinutes: 10, availableMinutes: 20))
            return try DinnerScenarioEngine.evaluate(scenario, acceptedDinners: [dinner], cap: cap)
        }
        let knownFee = CostEvidence.exact(Money(minorUnits: vector.feeMinor))
        let complete = try evaluate(price: vector.packMinor, fee: knownFee)
        XCTAssertEqual(complete.ingredientValues[meal.id]?.total.minorUnits, expected.ingredientMinor)
        XCTAssertEqual(complete.ingredientValues[meal.id]?.perServing.minorUnits, expected.perServingMinor)
        let pack = try XCTUnwrap(complete.packs.first?.result)
        XCTAssertEqual(pack.amountToBuy, try Rational(expected.neededAfterStock))
        XCTAssertEqual(pack.packsToBuy, expected.packs)
        XCTAssertEqual(pack.totalCost?.minorUnits, expected.packageMinor)
        XCTAssertEqual(complete.checkout.total.exact?.minorUnits, expected.completeMinor)
        XCTAssertEqual(complete.checkout.total.exact?.currency.rawValue, vector.currency)
        XCTAssertTrue(complete.checkout.isWholeCheckoutWithinCap)

        let partial = try evaluate(price: vector.packMinor, fee: .unknown(reason: "Pickup fee pending"))
        XCTAssertNil(partial.checkout.total.exact)
        XCTAssertEqual(partial.checkout.total.lowerBound.minorUnits, expected.unknownFeeLowerMinor)
        XCTAssertFalse(partial.checkout.isWholeCheckoutWithinCap)
        let bounded = try evaluate(price: vector.packMinor, fee: .bounded(lower: .zero, upper: Money(minorUnits: 50), reason: "Estimated fee"))
        XCTAssertNotNil(bounded.checkout.total.upperBound)
        XCTAssertNil(bounded.checkout.total.exact)
        XCTAssertFalse(bounded.checkout.isWholeCheckoutWithinCap)
        let unavailable = try evaluate(price: vector.packMinor, fee: knownFee, availability: .confirmed(maximumPacks: 1))
        XCTAssertFalse(unavailable.foodCoverageComplete)
        XCTAssertNil(unavailable.checkout.total.exact)
        XCTAssertFalse(unavailable.checkout.isWholeCheckoutWithinCap)
        let incompatible = try evaluate(price: vector.packMinor, fee: knownFee, unit: .gram)
        XCTAssertNil(incompatible.ingredientValues[meal.id])
        XCTAssertNil(incompatible.checkout.total.exact)
        XCTAssertFalse(incompatible.checkout.isWholeCheckoutWithinCap)
        XCTAssertThrowsError(try evaluate(price: .max, fee: knownFee))
    }

    func testRoundsCompleteIngredientValueAndExactServingIndependently() throws {
        XCTAssertEqual(try Rational(3, 2).roundedNearest(), 2)
        XCTAssertEqual(try Rational(3, 2).divided(by: Rational(4)).roundedNearest(), 0)
        XCTAssertEqual(try Rational(Int64.max).roundedNearest(), Int64.max)
        XCTAssertThrowsError(try Rational(Int64.max).multiplied(by: Rational(2)))
    }
}
