import CoreDomain
import Foundation
import HouseholdClient

struct SharedDeliveryCookDraft {
    private let bundle: Bundle
    private let language: String

    static func make(page: SharedDeliveryPage, coverage: SharedDeliveryCoverage,
                     occurrence: SharedMealOccurrence, language: String) -> String? {
        guard page.coverageAvailable == true, page.nextCursor == nil, page.placedRevision > 0,
              page.shopRevision >= page.placedRevision, page.authorityEpoch > 0, page.supplyRevision >= 0,
              (1...page.placedRevision).contains(occurrence.revision), page.meals?.contains(occurrence) == true,
              (try? occurrence.meal.validatePlanning()) != nil, (try? coverage.validate(reviewed: page)) != nil,
              let asOf = serviceDate(coverage.asOf) else { return nil }
        let locale = Locale(identifier: language)
        guard let code = locale.language.languageCode?.identifier, ["en", "es"].contains(code),
              let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path),
              let day = sharedMealDayText(occurrence.meal.day, locale: locale) else { return nil }
        let date = DateFormatter()
        date.locale = locale
        date.dateStyle = .long
        date.timeStyle = .medium
        // The shared meal day is a civil date. Only the coverage check represents an instant.
        date.timeZone = TimeZone(secondsFromGMT: 0)
        return Self(bundle: bundle, language: language).text(page: page, coverage: coverage, occurrence: occurrence,
                                                            day: day, checked: date.string(from: asOf) + " UTC")
    }

    private func label(_ key: String, table: String = "Household") -> String {
        bundle.localizedString(forKey: key, value: key, table: table)
    }

    private func field(_ key: String, _ value: String, table: String = "Household") -> String {
        label(key, table: table) + ": " + value
    }

    private func text(page: SharedDeliveryPage, coverage: SharedDeliveryCoverage, occurrence: SharedMealOccurrence,
                      day: String, checked: String) -> String {
        let meal = occurrence.meal, plan = meal.planning
        let noRecord = label("None recorded", table: "DeliveryCook")
        var heading = [label("Cook instructions") + " — " + meal.title, day,
                       field("Portions", String(meal.portions))]
        if meal.protected { heading.append(label("Protected portions")) }
        for group in plan?.groups ?? [] {
            let amount = group.servings
            let servings = amount.denominator == 1 ? String(amount.numerator) : "\(amount.numerator)/\(amount.denominator)"
            var line = field("Serving group", group.name) + " · " + field("Portions", servings)
            if group.protected || meal.protected { line += " · " + label("Protected portions") }
            heading.append(line)
        }
        if plan?.groups.isEmpty != false { heading.append(field("Serving group", noRecord)) }

        let restrictions = plan?.exclusions ?? []
        let steps = plan?.completedSteps ?? []
        let preparation = [
            field("Meal exclusions", restrictions.isEmpty ? noRecord : restrictions.joined(separator: ", ")),
            field("Preparation time in minutes", plan?.leadTimeMinutes.map(String.init) ?? label("Unknown")),
            field("Completed preparation steps", steps.isEmpty ? noRecord : "\n" + steps.joined(separator: "\n"))
        ]
        var sections = [heading.joined(separator: "\n"), preparation.joined(separator: "\n")]
        let needs = Dictionary(grouping: coverage.needs.filter { $0.occurrenceId == occurrence.id }, by: \.ingredientId)
        for ingredient in plan?.ingredients ?? [] {
            let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
            let matched = page.sources.filter { $0.matches?.contains(target) == true }
            var lines = [field("Ingredient", ingredient.name),
                         field("Ingredient exclusions", ingredient.exclusions.isEmpty ? noRecord : ingredient.exclusions.joined(separator: ", "))]
            for need in needs[ingredient.id] ?? [] {
                let groups = plan?.groups.filter { need.groupIds.contains($0.id) }.map(\.name) ?? []
                if !groups.isEmpty { lines.append(field("Serving group", groups.joined(separator: ", "))) }
                if need.protected { lines.append(label("Protected portions")) }
                lines += amounts(need)
                for source in matched {
                    let reference = String(source.segmentKey.uuidString.prefix(8))
                    lines.append(field("Matched delivery", source.foodName + " · " + reference, table: "DeliveryCook"))
                    if !source.exclusionTags.isEmpty { lines.append(field("Delivery exclusions", source.exclusionTags.joined(separator: ", "))) }
                    if let reservation = need.reservations?.first(where: { $0.sourceId == source.id }) {
                        lines.append(field("Amount set aside", quantity(reservation.requested, required: need.required)))
                        lines.append(field("Still backed by this delivery", quantity(reservation.backed, required: need.required)))
                    }
                    if let allocation = need.allocations.first(where: { $0.sourceId == source.id }) {
                        lines.append(field("Allocated from this delivery", quantity(allocation.amount, required: need.required), table: "DeliveryCook"))
                    }
                }
                if need.reservations?.isEmpty != false {
                    lines.append(field("Amount set aside", page.reservationsAvailable == true ? noRecord : label("Unknown")))
                }
                lines += need.issues.map { label(Self.issueKey($0)) }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if coverage.unplannedOccurrenceIds.contains(occurrence.id) { sections.append(label("This meal has no recorded ingredient requirements.")) }
        sections.append([label("These counts use confirmed deliveries for this order. Protected portions are counted first."),
                         field("Checked at", checked),
                         field("Delivery revision", String(coverage.supplyRevision), table: "DeliveryCook"),
                         field("Meal revision", String(occurrence.revision), table: "DeliveryCook")].joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }

    private func amounts(_ need: SharedDeliveryCoverage.Need) -> [String] {
        let required = need.required.flatMap { value -> String? in
            guard let unit = UnitOfMeasure(rawValue: value.unit),
                  let amount = try? Rational(Int64(value.amount.numerator), Int64(value.amount.denominator)) else { return nil }
            return pQuantity(amount, unit: unit, language: language)
        }
        return [field("Ingredient quantity", required ?? label("Unknown")),
                field("Covered by deliveries", quantity(need.covered, required: need.required)),
                field("Uncovered by deliveries", quantity(need.missing, required: need.required))]
    }

    private func quantity(_ fraction: SharedDeliveryCoverage.Fraction?, required: SharedMealQuantity?) -> String {
        guard let fraction, let unit = required.flatMap({ UnitOfMeasure(rawValue: $0.unit) }) else { return label("Unknown") }
        return pQuantity(fraction.formatted, unit: unit, singular: fraction.numerator == fraction.denominator, language: language)
    }

    static func issueKey(_ code: String) -> String {
        switch code {
        case "unknownQuantity": "The required amount is unknown."
        case "unknownSplit": "The total is shared. Amounts for each group are unresolved."
        case "noMatch": "No delivery has been matched to this ingredient."
        case "unconfirmed": "A matched delivery is waiting for a usable count."
        case "exclusion": "A matched delivery conflicts with a recorded exclusion."
        case "unitMismatch": "A matched delivery uses an incompatible unit."
        case "reservationShortfall": "This delivery no longer covers the full amount set aside."
        case "protectedQuantityUnknown": "Matched food is held for a protected group whose quantity is unknown."
        default: "Refresh deliveries and review the current record."
        }
    }
}
