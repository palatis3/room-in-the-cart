import Foundation

public struct TonightPurchaseEstimate: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let package: String
        public let count: Int64
        public let cost: Money
        public let source: String
        public let observedAt: Date
    }

    public let packages: [Line]
    public let subtotal: Money?
    public let complete: Bool
    public let currency: Currency

    /// Charges are the shopper-reviewed increase over the shop without this second
    /// meal. Existing cart fees and threshold waivers are not new cash costs.
    public func additionalCash(addedCharges: Money?, chargesComplete: Bool) throws -> (known: Money?, complete: Bool) {
        _ = try Currency.matching([currency, subtotal?.currency, addedCharges?.currency])
        if complete && packages.isEmpty { return (Money(minorUnits: 0, currency: currency), true) }
        guard let addedCharges else { return (subtotal, false) }
        guard addedCharges.minorUnits >= 0 else { throw CheckoutError.invalidEvidence }
        return (try subtotal?.adding(addedCharges) ?? addedCharges, complete && chargesComplete)
    }

    private struct Observation: Equatable {
        let offer: PackOffer
        let source: String
        let date: Date
        let details: MealEligibilityEvidence?
    }

    private struct QuotedNeed {
        let observation: Observation
        let packs: Rational // Exact shortfall divided by usable package size, before rounding.
        let price: Money
    }

    private struct Needs {
        var quoted: [UUID: QuotedNeed] = [:]
        var unpricedFoods: Set<UUID> = []
        var hasUnidentifiedFood = false
    }

    /// A following meal is reviewed against the free pantry stock remaining after the first.
    /// Compare whole packages for both meals with those already needed for the first meal.
    public static func estimate(_ review: PantryMealMatcher.Review, after first: PantryMealMatcher.Review? = nil,
                                workspace: LedgerWorkspace, workspaceID: UUID, shopID: UUID?, at now: Date,
                                currency fallbackCurrency: Currency = .groceryDefault()) throws -> Self {
        let selectedShop = workspace.shops.first { $0.id == shopID }
        let currency = selectedShop?.basis.currency ?? fallbackCurrency
        let unknown = Self(packages: [], subtotal: nil, complete: false, currency: currency)
        let revision = workspace.dinnerPlanning.privateMealPreferences?.revision
        for meal in [first, review].compactMap({ $0 }) {
            guard meal.eligibility.eligible, !meal.ingredients.isEmpty, meal.preferenceRevision == revision else { return unknown }
        }
        if let first {
            guard first.recipe.id != review.recipe.id, first.canProjectRemainder,
                  let batch = first.batchUse, batch.lotID == review.batchUse?.lotID else { return unknown }
        }
        if !review.numericIngredients.isEmpty && review.numericIngredients.allSatisfy(\.covered) {
            return Self(packages: [], subtotal: Money(minorUnits: 0, currency: currency), complete: true, currency: currency)
        }
        guard let shop = selectedShop else { return unknown }
        let next = try needs(review, workspace: workspace, workspaceID: workspaceID, shop: shop, at: now)
        let prior = try first.map { try needs($0, workspace: workspace, workspaceID: workspaceID, shop: shop, at: now) } ?? Needs()
        // An unidentified baseline purchase might supply any of the second meal's missing food.
        guard !prior.hasUnidentifiedFood else { return unknown }

        var lines: [Line] = []
        var subtotal = Money(minorUnits: 0, currency: currency)
        var complete = !next.hasUnidentifiedFood && next.unpricedFoods.isEmpty
        for (foodID, need) in next.quoted.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let baseline = prior.quoted[foodID]
            guard !prior.unpricedFoods.contains(foodID), baseline == nil || baseline?.observation == need.observation else {
                complete = false
                continue
            }
            let previous = baseline?.packs ?? .zero
            let count = try previous.adding(need.packs).roundedUp() - previous.roundedUp()
            guard count > 0 else { continue }
            let cost = try need.price.multiplied(by: count)
            subtotal = try subtotal.adding(cost)
            lines.append(Line(id: foodID, package: need.observation.offer.label, count: count,
                              cost: cost, source: need.observation.source, observedAt: need.observation.date))
        }
        return Self(packages: lines, subtotal: !lines.isEmpty || complete ? subtotal : nil, complete: complete, currency: currency)
    }

    private static func needs(_ review: PantryMealMatcher.Review, workspace: LedgerWorkspace,
                              workspaceID: UUID, shop: ShoppingLedger, at now: Date) throws -> Needs {
        let shopID = shop.id
        let accepted = workspace.dinnerPlanning.acceptedDinners.filter { $0.template == review.recipe }
        let sources = Set(accepted.compactMap(\.sourceIdeaID))
        let evidence = workspace.dinnerPlanning.ideas.filter { sources.contains($0.id) }
            .flatMap { $0.supplyEvidence ?? [] }
            .filter { $0.workspaceID == workspaceID && $0.shopID == shopID && $0.basisRevision == shop.basisRevision }
        let profile = workspace.dinnerPlanning.privateMealPreferences
        var groups: [UUID: [PantryMealMatcher.IngredientReview]] = [:]
        var result = Needs()
        for row in review.numericIngredients where !row.covered {
            let savedFoodIDs = Set(evidence.filter {
                $0.id == row.id && $0.ingredientName == row.ingredient.name && $0.pack != nil
            }.compactMap(\.foodID))
            if let foodID = row.foodID ?? (savedFoodIDs.count == 1 ? savedFoodIDs.first : nil) {
                groups[foodID, default: []].append(row)
            } else { result.hasUnidentifiedFood = true }
        }
        for (foodID, rows) in groups {
            var quotes: [Observation] = []
            for row in rows {
                quotes += evidence.compactMap { entry in
                    guard entry.id == row.id, entry.ingredientName == row.ingredient.name,
                          entry.foodID == foodID, let pack = entry.pack, let source = entry.source,
                          let date = entry.observedAt, date <= now else { return nil }
                    return Observation(offer: pack, source: source, date: date, details: entry.foodDetails)
                }
            }
            if quotes.isEmpty, let selected = try workspace.currentPackSelection(shopID: shopID, lineID: foodID, workspaceID: workspaceID),
               selected.reviewedAt <= now {
                let pack = selected.request.offerA.id == selected.selectedOfferID ? selected.request.offerA : selected.request.offerB
                quotes = [Observation(offer: pack, source: selected.source, date: selected.reviewedAt, details: nil)]
            }
            guard let quote = quotes.first, quotes.allSatisfy({ $0 == quote }),
                  MealEligibilityPolicy.evaluateFood(profile: profile, labels: [quote.offer.label], evidence: quote.details).eligible,
                  let need = try quotedNeed(rows: rows, quote: quote, exclusions: review.recipe.exclusions)
            else { result.unpricedFoods.insert(foodID); continue }
            result.quoted[foodID] = need
        }
        return result
    }

    private static func quotedNeed(rows: [PantryMealMatcher.IngredientReview], quote: Observation,
                                   exclusions: [String]) throws -> QuotedNeed? {
        guard let usable = quote.offer.usableQuantity, usable.amount > .zero, let price = quote.offer.price else { return nil }
        var needed = Rational.zero
        for row in rows {
            guard !row.hasUnresolvedStock else { return nil }
            let quantity: Quantity
            if let coverage = row.coverage, coverage.issues.isEmpty, let shortfall = coverage.shortfall, shortfall > .zero {
                quantity = Quantity(amount: shortfall, unit: coverage.unit, originalLiteral: shortfall.description)
            } else if row.foodID == nil, let original = row.ingredient.quantity {
                // A reviewed purchase identity may exist before the first pantry
                // lot. In this scenario no pantry quantity has been credited.
                quantity = original
            } else { return nil }
            do { try permittedProduct(quote.offer.label, exclusions: exclusions + row.ingredient.exclusions) }
            catch LedgerError.excludedIngredient { return nil }
            guard let converted = try quantity.converted(to: usable.unit, using: quote.offer.confirmedConversion) else { return nil }
            needed = try needed.adding(converted)
        }
        return QuotedNeed(observation: quote, packs: try needed.divided(by: usable.amount), price: price)
    }
}
