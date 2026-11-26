import Foundation

/// Fictional evidence for the read-only Household offer. No workspace or store participates.
public enum DinnerBasketSample {
    public struct Basket: Sendable {
        public let result: DinnerScenarioResult
        public let tortillaPacks: Int64
        public let tortillaPackPrice: Money
        public let brothPrice: Money?
    }

    public static func compare(currency: Currency) throws -> (tacos: Basket, soup: Basket) {
        func pieces(_ count: Int64) throws -> Quantity {
            Quantity(amount: try Rational(count), unit: .count, originalLiteral: String(count))
        }
        let observed = Date(timeIntervalSince1970: 1_795_564_800)
        let tortillas = UUID()
        let servings = try Rational(2)
        let dinner = DinnerCommitment(name: "Dinner", kind: .dinner, portions: servings)
        let commitments = DinnerCommitmentSet(commitments: [dinner])
        let stock = ConfirmedStockLot(id: UUID(), foodID: tortillas, name: "Tortillas",
            usable: try pieces(4), confirmedAt: observed, source: .pantry)
        let lunch = StockNeed(id: UUID(), foodID: tortillas, name: "Two lunches", amount: try pieces(2), priority: .protected)
        let beans = CheckoutLine(id: UUID(), name: "Beans", cost: .unknown(reason: "No sample price"))
        let context = CheckoutContext(storeID: "sample", branchID: "sample", mode: .inStore, slot: "sample",
            commitmentsID: commitments.id, observedAt: observed, source: "Sample shelf prices", currency: currency)
        let zero = CostEvidence.exact(Money(minorUnits: 0, currency: currency))
        let tortillaPrice = Money(minorUnits: currency == .mxn ? 1500 : 200, currency: currency)
        let brothPrice = Money(minorUnits: currency == .mxn ? 1000 : 150, currency: currency)
        let pack = PackOffer(id: "sample-tortillas", label: "Tortillas", usableQuantity: try pieces(4), price: tortillaPrice)
        func basket(title: String, tortillaCount: Int64, broth: Money?) throws -> Basket {
            let ingredient = MealIngredient(name: "Tortillas", quantity: try pieces(tortillaCount))
            let meal = AcceptedDinner(id: UUID(), template: MealTemplate(title: title, servings: servings,
                ingredients: [ingredient]), acceptedAt: observed)
            let demand = DinnerDemand(commitmentID: dinner.id, foodID: tortillas, name: ingredient.name,
                quantity: ingredient.quantity, acceptedDinnerID: meal.id, ingredientID: ingredient.id)
            var otherItems = [beans]
            if let broth { otherItems.append(CheckoutLine(id: UUID(), name: "Broth", cost: .exact(broth))) }
            let scenario = DinnerScenario(commitments: commitments, acceptedDinnerIDs: [meal.id], demands: [demand],
                stock: [stock], otherReservations: [lunch],
                packs: [DinnerPackSelection(foodID: tortillas, offer: pack, availability: .confirmed(maximumPacks: nil))],
                baselineLines: otherItems, baselineComplete: true, fees: [], tax: zero, deposits: zero,
                context: context, preparation: .init(handsOnMinutes: 10, remainingLeadMinutes: 15, availableMinutes: 30))
            let result = try DinnerScenarioEngine.evaluate(scenario, acceptedDinners: [meal])
            guard let count = result.packs.first?.result?.packsToBuy else { throw DinnerPlanningError.reviewRequired("samplePack") }
            return Basket(result: result, tortillaPacks: count, tortillaPackPrice: tortillaPrice, brothPrice: broth)
        }
        return (try basket(title: "Tacos", tortillaCount: 8, broth: nil),
                try basket(title: "Tortilla soup", tortillaCount: 4, broth: brothPrice))
    }
}

extension DinnerBasketSample {
    /// The planning preview uses fictional prices, confirmed stock and a protected lunch.
    public static func changedWeek(currency: Currency, keepTuesday: Bool, keepThursday: Bool) throws
        -> (packs: Int64, riceCost: Money) {
        func grams(_ weight: Int64) throws -> Quantity {
            Quantity(amount: try Rational(weight), unit: .gram, originalLiteral: String(weight))
        }
        let rice = UUID()
        let stock = ConfirmedStockLot(id: UUID(), foodID: rice, name: "Rice", usable: try grams(500),
                                     confirmedAt: Date(timeIntervalSince1970: 1_795_564_800), source: .pantry)
        let lunch = StockNeed(id: UUID(), foodID: rice, name: "Lunch", amount: try grams(200), priority: .protected)
        let dinnerGrams: Int64 = 400 + (keepTuesday ? 300 : 0) + (keepThursday ? 300 : 0)
        let dinners = StockNeed(id: UUID(), foodID: rice, name: "Dinners", amount: try grams(dinnerGrams), priority: .required)
        let allocation = try ConfirmedStockAllocator.allocate(lots: [stock], needs: [lunch, dinners])
        guard let required = allocation.demands.first(where: { $0.id == dinners.id })?.shortfall else {
            throw DinnerPlanningError.reviewRequired("sampleRice")
        }
        let packs = try required.divided(by: Rational(500)).roundedUp()
        let price = Money(minorUnits: currency == .mxn ? 3_200 : 200, currency: currency)
        return (packs, try price.multiplied(by: packs))
    }
}
