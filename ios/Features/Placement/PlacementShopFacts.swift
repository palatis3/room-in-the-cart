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
                    Text(verbatim: line.originalItem).font(.headline).foregroundStyle(Theme.ink)
                    LabeledContent(PlacementCopy.text("Packs"), value: line.packs.formatted()).monospacedDigit()
                    LabeledContent(PlacementCopy.text("Entered price per pack"), value: PlacementCopy.money(line.unitPriceMinor, currency: quote.currency)).monospacedDigit()
                    Text(line.feeEligible ? PlacementCopy.text("Counts toward the fee threshold") : PlacementCopy.text("Does not count toward the fee threshold")).font(.caption)
                }
            }
            LabeledContent(PlacementCopy.text("Quote scope"), value: PlacementCopy.scope(quote.scope))
            Text(quote.complete ? PlacementCopy.text("Entered quote marked complete") : PlacementCopy.text("Entered quote incomplete"))
            LabeledContent(PlacementCopy.text("Entered spending cap"), value: PlacementCopy.money(quote.capMinor, currency: quote.currency))
            LabeledContent(PlacementCopy.text("Cap scope"), value: PlacementCopy.scope(quote.capScope))
            if quote.fee.kind == "threshold" {
                LabeledContent(PlacementCopy.text("Fee threshold"), value: PlacementCopy.money(quote.fee.thresholdMinor, currency: quote.currency))
                LabeledContent(PlacementCopy.text("Fee below threshold"), value: PlacementCopy.money(quote.fee.belowMinor, currency: quote.currency))
                LabeledContent(PlacementCopy.text("Fee at or above threshold"), value: PlacementCopy.money(quote.fee.aboveMinor, currency: quote.currency))
            } else {
                LabeledContent(PlacementCopy.text("Entered fee"), value: PlacementCopy.money(quote.fee.amountMinor, currency: quote.currency))
            }
            LabeledContent(PlacementCopy.text("Entered taxes"), value: PlacementCopy.money(quote.taxesMinor, currency: quote.currency))
            LabeledContent(PlacementCopy.text("Entered deposits"), value: PlacementCopy.money(quote.depositsMinor, currency: quote.currency))
            LabeledContent(PlacementCopy.text("Entered discounts"), value: PlacementCopy.money(quote.discountsMinor, currency: quote.currency))
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
            LabeledContent(PlacementCopy.text("Captured total"), value: PlacementCopy.money(budget.totalMinor, currency: budget.currency))
                .font(.headline).monospacedDigit()
            LabeledContent(PlacementCopy.text("Captured lower bound"), value: PlacementCopy.money(budget.lowerBoundMinor, currency: budget.currency))
            LabeledContent(PlacementCopy.text("Captured upper bound"), value: PlacementCopy.money(budget.upperBoundMinor, currency: budget.currency))
            LabeledContent(PlacementCopy.text("Captured amount over cap"), value: PlacementCopy.money(budget.overCapMinor, currency: budget.currency))
            LabeledContent(PlacementCopy.text("Captured room under cap"), value: PlacementCopy.money(budget.headroomMinor, currency: budget.currency))
            Text(budget.wholeCheckoutWithinCap ? PlacementCopy.text("Captured whole checkout was within the entered cap") : PlacementCopy.text("The captured facts do not establish that the whole checkout was within the cap"))
            if !budget.missing.isEmpty {
                Text(PlacementCopy.text("The captured estimate has missing cost facts. Unknown amounts remain unknown."))
            }
        }
    }
}

struct PlacementMealFacts: View {
    let meals: [SharedMealOccurrence]
    @Environment(\.locale) private var locale
    var body: some View {
        ForEach(meals) { occurrence in
            VStack(alignment: .leading, spacing: 4) {
                Text(occurrence.meal.title).font(.headline)
                LabeledContent(PlacementCopy.text("Meal day as entered"),
                    value: occurrence.meal.day ?? sharedMealScheduleText(nil, locale: locale))
                LabeledContent(PlacementCopy.text("Meal kind"), value: PlacementCopy.mealKind(occurrence.meal.kind))
                LabeledContent(PlacementCopy.text("Meal portions"), value: occurrence.meal.portions.formatted())
                Text(occurrence.meal.protected ? PlacementCopy.text("Protected meal") : PlacementCopy.text("Flexible meal"))
                LabeledContent(PlacementCopy.text("Original meal revision"), value: occurrence.revision.formatted())
            }
        }
    }
}
