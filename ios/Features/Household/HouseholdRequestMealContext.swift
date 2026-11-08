import SwiftUI
import HouseholdClient

/// Read-only meal facts from the same authorized shop revision as the decision.
/// A reservation is a commitment, not evidence that the basket covers it.
struct HouseholdRequestMealContext: Equatable {
    let meals: [SharedMealOccurrence]?

    init?(authorized: Bool, shopID: String, shop: ShopperShop?, request: OwnRequest?, preview: ShopperPreview?) {
        guard authorized, let shop, let request, let preview,
              shop.shopId == shopID, request.shopId == shopID,
              preview.shopRevision == shop.shopRevision,
              preview.authorityEpoch == shop.authorityEpoch,
              preview.requestRevision == request.revision else { return nil }
        meals = shop.meals
    }

    var protectedMeals: [SharedMealOccurrence] { sorted(meals?.filter { $0.meal.protected } ?? []) }
    var otherMeals: [SharedMealOccurrence] { sorted(meals?.filter { !$0.meal.protected } ?? []) }

    private func sorted(_ values: [SharedMealOccurrence]) -> [SharedMealOccurrence] {
        values.sorted {
            if $0.meal.day != $1.meal.day { return $0.meal.day < $1.meal.day }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

extension HouseholdInboxModel {
    var requestMealContext: HouseholdRequestMealContext? {
        HouseholdRequestMealContext(authorized: authorized, shopID: shopID, shop: shop, request: selected, preview: preview)
    }
}

struct HouseholdRequestMealContextView: View {
    let context: HouseholdRequestMealContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ht("Protected meal commitments"), systemImage: "lock")
                .font(.headline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if context.meals == nil {
                Text(ht("Meal commitments are unavailable. Check the meal plan before deciding."))
                    .accessibilityIdentifier("household.decision.meals.unknown")
            } else if context.meals?.isEmpty == true {
                Text(ht("No meal commitments are recorded for this shop."))
            } else {
                if context.protectedMeals.isEmpty { Text(ht("No protected portions are recorded for this shop.")) }
                ForEach(context.protectedMeals) { occurrence in
                    HouseholdRequestMealFacts(occurrence: occurrence)
                }
                if !context.otherMeals.isEmpty {
                    DisclosureGroup(ht("Other meals in this shop")) {
                        ForEach(context.otherMeals) { occurrence in HouseholdRequestMealFacts(occurrence: occurrence) }
                    }
                }
            }
            Text(ht("Check usable food separately; this review does not confirm meal coverage."))
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }
}

private struct HouseholdRequestMealFacts: View {
    let occurrence: SharedMealOccurrence
    @Environment(\.locale) private var locale

    private var kind: String {
        switch occurrence.meal.kind {
        case "lunch": return ht("Lunch")
        case "side": return ht("Side")
        case "dinner": return ht("Dinner")
        default: return ht("Unknown")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(occurrence.meal.title).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text([kind, sharedMealDayText(occurrence.meal.day, locale: locale) ?? ht("Meal day unknown")].joined(separator: " · "))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HouseholdDecisionFact(occurrence.meal.protected ? ht("Protected portions") : ht("Portions"), value: occurrence.meal.portions.formatted())
                .font(.caption)
        }
        .lineLimit(nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("household.decision.meal.\(occurrence.id.uuidString.lowercased())")
    }
}

/// Preserve LabeledContent's native stacked layout at accessibility sizes.
struct HouseholdDecisionFact: View {
    enum ValueRole {
        case essential
        case metadata

        var foregroundColor: Color {
            switch self {
            case .essential: Theme.ink
            case .metadata: Theme.secondary
            }
        }
    }

    let title: String
    let value: String
    let valueRole: ValueRole

    init(_ title: String, value: String, valueRole: ValueRole = .essential) {
        self.title = title
        self.value = value
        self.valueRole = valueRole
    }

    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(valueRole.foregroundColor)
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
}
