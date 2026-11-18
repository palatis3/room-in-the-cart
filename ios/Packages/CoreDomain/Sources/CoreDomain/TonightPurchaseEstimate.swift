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

    /// Charges are the shopper-reviewed increase over the shop without this second
    /// meal. Existing cart fees and threshold waivers are not new cash costs.
    public func additionalCash(addedCharges: Money?, chargesComplete: Bool) throws -> (known: Money?, complete: Bool) {
        if complete && packages.isEmpty { return (.zero, true) }
        guard let addedCharges else { return (subtotal, false) }
        guard addedCharges >= .zero else { throw CheckoutError.invalidEvidence }
        let cents = try checkedAdd(subtotal?.minorUnits ?? 0, addedCharges.minorUnits)
        return (Money(minorUnits: cents), complete && chargesComplete)
    }

    private struct Observation: Equatable {
        let offer: PackOffer
        let source: String
        let date: Date
        let details: MealEligibilityEvidence?
    }

    /// Estimates ingredient purchases at the selected shop. A balanced pantry
    /// needs zero additional packs regardless of whether a shop has been created.
    public static func estimate(_ review: PantryMealMatcher.Review, workspace: LedgerWorkspace,
                                workspaceID: UUID, shopID: UUID?, at now: Date) throws -> Self {
        guard review.eligibility.eligible, !review.ingredients.isEmpty,
              workspace.dinnerPlanning.privateMealPreferences?.revision == review.preferenceRevision else {
            return Self(packages: [], subtotal: nil, complete: false)
        }
        let missing = review.ingredients.filter { !$0.covered }
        if missing.isEmpty { return Self(packages: [], subtotal: .zero, complete: true) }
        guard let shopID, let shop = workspace.shops.first(where: { $0.id == shopID }) else {
            return Self(packages: [], subtotal: nil, complete: false)
        }
        let accepted = workspace.dinnerPlanning.acceptedDinners.filter { $0.template == review.recipe }
        let sources = Set(accepted.compactMap(\.sourceIdeaID))
        let evidence = workspace.dinnerPlanning.ideas.filter { sources.contains($0.id) }
            .flatMap { $0.supplyEvidence ?? [] }
            .filter { $0.workspaceID == workspaceID && $0.shopID == shopID && $0.basisRevision == shop.basisRevision }
        let profile = workspace.dinnerPlanning.privateMealPreferences
        var groups: [UUID: [PantryMealMatcher.IngredientReview]] = [:]
        var complete = true
        for row in missing {
            let savedFoodIDs = Set(evidence.filter {
                $0.id == row.id && $0.ingredientName == row.ingredient.name && $0.pack != nil
            }.compactMap(\.foodID))
            if let foodID = row.foodID ?? (savedFoodIDs.count == 1 ? savedFoodIDs.first : nil) {
                groups[foodID, default: []].append(row)
            } else { complete = false }
        }
        var lines: [Line] = []
        var cents: Int64 = 0
        for foodID in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let rows = groups[foodID] ?? []
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
                  let line = try purchase(foodID: foodID, rows: rows, quote: quote, exclusions: review.recipe.exclusions)
            else { complete = false; continue }
            lines.append(line)
            cents = try checkedAdd(cents, line.cost.minorUnits)
        }
        let subtotal = !lines.isEmpty || complete ? Money(minorUnits: cents) : nil
        return Self(packages: lines, subtotal: subtotal, complete: complete)
    }

    private static func purchase(foodID: UUID, rows: [PantryMealMatcher.IngredientReview], quote: Observation,
                                 exclusions: [String]) throws -> Line? {
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
        let count = try needed.divided(by: usable.amount).roundedUp()
        return Line(id: foodID, package: quote.offer.label, count: count, cost: try price.multiplied(by: count),
                    source: quote.source, observedAt: quote.date)
    }
}
