import SwiftUI
import HouseholdClient

/// Readable original terms; never recomputed from a newer basket.
struct PlacementShopFacts: View {
    let quote: ShopperQuote
    let lines: [ShopperBasketLine]
    var body: some View {
        Group {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.originalItem).font(.headline)
                    LabeledContent(PlacementCopy.text("Packs"), value: line.packs.formatted())
                    LabeledContent(PlacementCopy.text("Entered price per pack"), value: PlacementCopy.money(line.unitPriceMinor))
                    Text(line.feeEligible ? PlacementCopy.text("Counts toward the fee threshold") : PlacementCopy.text("Does not count toward the fee threshold")).font(.caption)
                }
            }
            LabeledContent(PlacementCopy.text("Quote scope"), value: PlacementCopy.scope(quote.scope))
            Text(quote.complete ? PlacementCopy.text("Entered quote marked complete") : PlacementCopy.text("Entered quote incomplete"))
            LabeledContent(PlacementCopy.text("Entered spending cap"), value: PlacementCopy.money(quote.capMinor))
            LabeledContent(PlacementCopy.text("Cap scope"), value: PlacementCopy.scope(quote.capScope))
            if quote.fee.kind == "threshold" {
                LabeledContent(PlacementCopy.text("Fee threshold"), value: PlacementCopy.money(quote.fee.thresholdMinor))
                LabeledContent(PlacementCopy.text("Fee below threshold"), value: PlacementCopy.money(quote.fee.belowMinor))
                LabeledContent(PlacementCopy.text("Fee at or above threshold"), value: PlacementCopy.money(quote.fee.aboveMinor))
            } else {
                LabeledContent(PlacementCopy.text("Entered fee"), value: PlacementCopy.money(quote.fee.amountMinor))
            }
            LabeledContent(PlacementCopy.text("Entered taxes"), value: PlacementCopy.money(quote.taxesMinor))
            LabeledContent(PlacementCopy.text("Entered deposits"), value: PlacementCopy.money(quote.depositsMinor))
            LabeledContent(PlacementCopy.text("Entered discounts"), value: PlacementCopy.money(quote.discountsMinor))
            LabeledContent(PlacementCopy.text("Quote observed"), value: PlacementCopy.date(quote.observedAt))
            LabeledContent(PlacementCopy.text("Quote expires"), value: PlacementCopy.date(quote.expiresAt))
            Text(PlacementCopy.text("These are the captured household-entered terms. They do not verify a retailer order, final charge or payment."))
                .font(.footnote)
        }
    }
}

struct PlacementBudgetFacts: View {
    let budget: ShopperBudget
    var body: some View {
        Group {
            LabeledContent(PlacementCopy.text("Captured total"), value: PlacementCopy.money(budget.totalMinor))
            LabeledContent(PlacementCopy.text("Captured lower bound"), value: PlacementCopy.money(budget.lowerBoundMinor))
            LabeledContent(PlacementCopy.text("Captured upper bound"), value: PlacementCopy.money(budget.upperBoundMinor))
            LabeledContent(PlacementCopy.text("Captured amount over cap"), value: PlacementCopy.money(budget.overCapMinor))
            LabeledContent(PlacementCopy.text("Captured room under cap"), value: PlacementCopy.money(budget.headroomMinor))
            Text(budget.wholeCheckoutWithinCap ? PlacementCopy.text("Captured whole checkout was within the entered cap") : PlacementCopy.text("The captured facts do not establish that the whole checkout was within the cap"))
            if !budget.missing.isEmpty {
                Text(PlacementCopy.text("The captured estimate has missing cost facts. Unknown amounts remain unknown."))
            }
        }
    }
}

struct PlacementMealFacts: View {
    let meals: [SharedMealOccurrence]
    var body: some View {
        ForEach(meals) { occurrence in
            VStack(alignment: .leading, spacing: 4) {
                Text(occurrence.meal.title).font(.headline)
                LabeledContent(PlacementCopy.text("Meal day as entered"), value: occurrence.meal.day)
                LabeledContent(PlacementCopy.text("Meal kind"), value: PlacementCopy.mealKind(occurrence.meal.kind))
                LabeledContent(PlacementCopy.text("Meal portions"), value: occurrence.meal.portions.formatted())
                Text(occurrence.meal.protected ? PlacementCopy.text("Protected meal") : PlacementCopy.text("Flexible meal"))
                LabeledContent(PlacementCopy.text("Original meal revision"), value: occurrence.revision.formatted())
            }
        }
    }
}
