import CoreDomain
import Foundation
import HouseholdClient

enum SharedCookCoverage {
    case delivery(SharedDeliveryCoverage)
    case food(SharedPantryPage, SharedFoodCoverage)
    case recovered(SharedRecoveryPage, SharedRecoveryCoverage, SharedRecoveryMeal)

    var reviewedPantry: SharedPantryPage? {
        if case .food(let pantry, _) = self { return pantry }
        return nil
    }

    var asOf: String {
        switch self {
        case .delivery(let report): report.asOf
        case .food(_, let report): report.asOf
        case .recovered(_, let report, _): report.asOf
        }
    }

    func validate(reviewed page: SharedDeliveryPage) throws {
        switch self {
        case .delivery(let report): try report.validate(reviewed: page)
        case let .food(pantry, report): try report.validate(reviewed: pantry, delivery: page)
        case let .recovered(record, report, meal):
            guard record.shopId == page.shopId, record.placedRevision == page.placedRevision,
                  record.base.shopRevision == page.shopRevision, record.base.authorityEpoch == page.authorityEpoch,
                  record.base.supplyRevision == page.supplyRevision, record.base.recoveryRevision == page.recoveryRevision,
                  record.meals.contains(meal) else { throw ClientError.invalidResponse }
            try report.validate(reviewed: record)
        }
    }
}

struct SharedDeliveryCookDraft {
    private let bundle: Bundle
    private let language: String

    static func make(page: SharedDeliveryPage, coverage: SharedDeliveryCoverage,
                     occurrence: SharedMealOccurrence, language: String) -> String? {
        make(page: page, report: .delivery(coverage), occurrence: occurrence, language: language)
    }

    static func make(page: SharedDeliveryPage, report: SharedCookCoverage,
                     occurrence: SharedMealOccurrence, language: String) -> String? {
        guard page.coverageAvailable == true, page.nextCursor == nil, page.placedRevision > 0,
              page.shopRevision >= page.placedRevision, page.authorityEpoch > 0, page.supplyRevision >= 0,
              (1...page.placedRevision).contains(occurrence.revision), page.meals?.contains(occurrence) == true,
              (try? occurrence.meal.validatePlanning()) != nil, (try? report.validate(reviewed: page)) != nil,
              let asOf = serviceDate(report.asOf) else { return nil }
        if case let .recovered(_, _, meal) = report,
           meal.id != occurrence.id || meal.day != occurrence.meal.day || meal.sourceMealRevision != occurrence.revision { return nil }
        let locale = Locale(identifier: language)
        guard let renderer = Self(language: language),
              let day = sharedMealDayText(occurrence.meal.day, locale: locale) else { return nil }
        let date = DateFormatter()
        date.locale = locale
        date.dateStyle = .long
        date.timeStyle = .medium
        date.timeZone = TimeZone(secondsFromGMT: 0)
        return renderer.text(page: page, report: report, occurrence: occurrence,
                             day: day, checked: date.string(from: asOf) + " UTC")
    }

    init?(language: String) {
        let locale = Locale(identifier: language)
        guard let code = locale.language.languageCode?.identifier, ["en", "es"].contains(code),
              let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        self.bundle = bundle
        self.language = language
    }

    private func label(_ key: String, table: String = "Household") -> String {
        bundle.localizedString(forKey: key, value: key, table: table)
    }

    private func field(_ key: String, _ value: String, table: String = "Household") -> String {
        label(key, table: table) + ": " + value
    }

    private func text(page: SharedDeliveryPage, report: SharedCookCoverage, occurrence: SharedMealOccurrence,
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
            field("Meal deadline", plan?.deadline?.display(locale: Locale(identifier: language)) ?? label("Unknown"), table: "Recovery"),
            field("Meal exclusions", restrictions.isEmpty ? noRecord : restrictions.joined(separator: ", ")),
            field("Preparation time in minutes", plan?.leadTimeMinutes.map(String.init) ?? label("Unknown")),
            field("Completed preparation steps", steps.isEmpty ? noRecord : "\n" + steps.joined(separator: "\n"))
        ]
        var sections = [heading.joined(separator: "\n"), preparation.joined(separator: "\n")]
        var footer: [String]
        let unplanned: Bool
        switch report {
        case let .recovered(record, coverage, currentMeal):
            return currentCookText(meal: currentMeal, record: record, coverage: coverage, day: day, checked: checked)
        case .delivery(let coverage):
            sections += deliveryIngredients(page: page, occurrence: occurrence, coverage: coverage)
            unplanned = coverage.unplannedOccurrenceIds.contains(occurrence.id)
            footer = [label("These counts use confirmed deliveries for this order. Protected portions are counted first.")]
        case let .food(pantry, coverage):
            for need in coverage.needs where need.occurrenceId == occurrence.id {
                sections.append(foodNeed(need, occurrence: occurrence, page: page, pantry: pantry).joined(separator: "\n"))
            }
            unplanned = coverage.unplannedOccurrenceIds.contains(occurrence.id)
            footer = [label(Self.foodScope, table: "DeliveryCook"), field("Pantry revision", String(coverage.pantryRevision), table: "DeliveryCook")]
        }
        if unplanned { sections.append(label("This meal has no recorded ingredient requirements.")) }
        footer += [field("Checked at", checked), field("Delivery revision", String(page.supplyRevision), table: "DeliveryCook"),
                   field("Meal revision", String(occurrence.revision), table: "DeliveryCook")]
        sections.append(footer.joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }

    private func deliveryIngredients(page: SharedDeliveryPage, occurrence: SharedMealOccurrence,
                                     coverage: SharedDeliveryCoverage) -> [String] {
        let plan = occurrence.meal.planning
        let noRecord = label("None recorded", table: "DeliveryCook")
        var sections = [String]()
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
        return sections
    }

    private func measured(_ quantity: SharedMealQuantity?) -> String {
        quantity.flatMap { value -> String? in
            guard let unit = UnitOfMeasure(rawValue: value.unit),
                  let amount = try? Rational(Int64(value.amount.numerator), Int64(value.amount.denominator)) else { return nil }
            return pQuantity(amount, unit: unit, language: language)
        } ?? label("Unknown")
    }

    private func amounts(_ need: SharedDeliveryCoverage.Need) -> [String] {
        [field("Ingredient quantity", measured(need.required)),
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

extension SharedDeliveryCookDraft {
    static let foodScope = "These counts include confirmed deliveries and matched pantry and freezer stock for this order. Each physical source is counted once."

    func foodNeed(_ need: SharedFoodCoverage.Need, occurrence: SharedMealOccurrence,
                  page: SharedDeliveryPage, pantry: SharedPantryPage) -> [String] {
        guard need.occurrenceId == occurrence.id, need.mealRevision == occurrence.revision,
              let plan = occurrence.meal.planning,
              let ingredient = plan.ingredients.first(where: { $0.id == need.ingredientId }) else { return [] }
        let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
        let groups = plan.groups.filter { need.groupIds.contains($0.id) }.map(\.name)
        let noRecord = label("None recorded", table: "DeliveryCook")
        var lines = [field("Ingredient", ingredient.name)]
        if !groups.isEmpty { lines.append(field("Serving group", groups.joined(separator: ", "))) }
        if need.protected { lines.append(label("Protected portions")) }
        lines += [field("Ingredient exclusions", ingredient.exclusions.isEmpty ? noRecord : ingredient.exclusions.joined(separator: ", ")),
                  field("Ingredient quantity", measured(need.required)),
                  field("Covered by deliveries", quantity(need.delivered, required: need.required)),
                  field("Covered by pantry stock", quantity(need.pantry, required: need.required), table: "DeliveryCook"),
                  field("Covered by freezer stock", quantity(need.freezer, required: need.required), table: "DeliveryCook"),
                  field("Still needed", quantity(need.missing, required: need.required), table: "DeliveryCook")]

        func sourceLines(id: UUID, kind: String, name: String, tags: [String], count: SharedMealQuantity?) -> [String] {
            var facts = [field(kind, name, table: "DeliveryCook"),
                         field("Latest confirmed usable count", measured(count), table: "DeliveryCook")]
            if !tags.isEmpty { facts.append(field("Source exclusions", tags.joined(separator: ", "), table: "DeliveryCook")) }
            for reservation in need.reservations ?? [] where reservation.sourceId == id {
                facts += [field("Amount set aside", quantity(reservation.requested, required: need.required)),
                          field("Still backed by this source", quantity(reservation.backed, required: need.required), table: "DeliveryCook")]
            }
            if let allocation = need.allocations.first(where: { $0.sourceId == id }) {
                facts.append(field("Allocated from this source", quantity(allocation.amount, required: need.required), table: "DeliveryCook"))
            }
            return facts
        }

        for source in page.sources where source.matches?.contains(target) == true {
            lines += sourceLines(id: source.id, kind: "Matched delivery",
                                 name: source.foodName + " · " + source.segmentKey.uuidString.prefix(8),
                                 tags: source.exclusionTags, count: source.confirmed?.quantity)
        }
        for lot in pantry.lots where lot.selected && lot.matches.contains(target) {
            lines += sourceLines(id: lot.id, kind: lot.location == "freezer" ? "Matched freezer stock" : "Matched pantry stock",
                                 name: lot.foodName + " · " + lot.id.uuidString.prefix(8),
                                 tags: lot.exclusionTags, count: lot.observation?.quantity)
        }
        if need.reservations?.isEmpty != false {
            lines.append(field("Amount set aside", need.reservations == nil ? label("Unknown") : noRecord))
        }
        lines += need.issues.map { issue in
            switch issue {
            case "noMatch": label("No source has been matched to this ingredient.", table: "DeliveryCook")
            case "unconfirmed": label("A matched source is waiting for a usable count.", table: "DeliveryCook")
            case "exclusion": label("A matched source conflicts with a recorded exclusion.", table: "DeliveryCook")
            case "unitMismatch": label("A matched source uses an incompatible unit.", table: "DeliveryCook")
            case "reservationShortfall": label("A source no longer covers the full amount set aside.", table: "DeliveryCook")
            default: label(Self.issueKey(issue))
            }
        }
        return lines
    }
}

extension SharedDeliveryCookDraft {
    private func currentCookText(meal: SharedRecoveryMeal, record: SharedRecoveryPage, coverage: SharedRecoveryCoverage,
                                 day: String, checked: String) -> String {
        let unknown = label("Unknown")
        let none = label("None recorded", table: "DeliveryCook")
        var header = [label("Cook instructions") + " — " + meal.title, day, field("Portions", String(meal.portions))]
        for group in meal.groups {
            let servings = group.servings.denominator == 1 ? String(group.servings.numerator) : "\(group.servings.numerator)/\(group.servings.denominator)"
            header.append(field("Serving group", group.name) + " · " + field("Portions", servings) + (group.protected ? " · " + label("Protected portions") : ""))
            if !group.exclusions.isEmpty { header.append(field("Group exclusions", group.exclusions.joined(separator: ", "), table: "Recovery")) }
        }
        if !meal.notes.isEmpty { header.append(meal.notes) }
        if let url = meal.sourceURL { header.append(url) }
        header += [field("Meal exclusions", meal.exclusions.isEmpty ? none : meal.exclusions.joined(separator: ", ")),
                   field("Required lead time in minutes", meal.requiredLeadMinutes.map(String.init) ?? unknown, table: "Recovery"),
                   field("Remaining preparation minutes", meal.remainingElapsedMinutes.map(String.init) ?? unknown, table: "Recovery")]
        if let provenance = record.mealSources.first(where: { $0.occurrenceId == meal.id && $0.sealedRevisionId == meal.revisionId }),
           !provenance.completedSteps.isEmpty {
            header.append(field("Completed preparation steps", "\n" + provenance.completedSteps.joined(separator: "\n")))
        }
        if meal.advanceStepsCompleted { header.append(label("Advance steps confirmed complete", table: "Recovery")) }
        else { header.append(label("Advance steps not confirmed complete", table: "Recovery")) }
        let deadline = meal.due.flatMap { SharedMealDeadline(at: $0, zone: meal.zone ?? "UTC").display(locale: Locale(identifier: language)) }
        header.append(field("Meal deadline", deadline ?? unknown, table: "Recovery"))
        var sections = [header.joined(separator: "\n")]
        for row in coverage.needs where row.occurrenceId == meal.id {
            sections.append(recoveryNeed(row, meal: meal, record: record).joined(separator: "\n"))
        }
        if coverage.unplannedOccurrenceIds.contains(meal.id) { sections.append(label("This meal has no recorded ingredient requirements.")) }
        sections.append([label(Self.foodScope, table: "DeliveryCook"), field("Checked at", checked),
                         field("Meal plan revision", String(record.base.recoveryRevision), table: "Recovery"),
                         field("Current meal revision", meal.revisionId.uuidString, table: "Recovery"),
                         field("Pantry revision", String(record.base.pantryRevision), table: "DeliveryCook"),
                         field("Delivery revision", String(record.base.supplyRevision), table: "DeliveryCook")].joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }

    func recoveryNeed(_ row: SharedRecoveryCoverage.Need, meal: SharedRecoveryMeal, record: SharedRecoveryPage) -> [String] {
        guard row.occurrenceId == meal.id, let need = meal.needs.first(where: { $0.id == row.needId }) else { return [] }
        let none = label("None recorded", table: "DeliveryCook")
        var lines = [field("Ingredient", need.name)]
        if !need.notes.isEmpty { lines.append(need.notes) }
        let groups = meal.groups.filter { row.groupIds.contains($0.id) }.map(\.name)
        if !groups.isEmpty { lines.append(field("Serving group", groups.joined(separator: ", "))) }
        if need.priority == "protected" { lines.append(label("Protected portions")) }
        lines += [field("Ingredient exclusions", need.exclusions.isEmpty ? none : need.exclusions.joined(separator: ", ")),
                  field("Ingredient quantity", measured(row.required)),
                  field("Covered by deliveries", quantity(row.delivered, required: row.required)),
                  field("Covered by pantry stock", quantity(row.pantry, required: row.required), table: "DeliveryCook"),
                  field("Covered by freezer stock", quantity(row.freezer, required: row.required), table: "DeliveryCook"),
                  field("Still needed", quantity(row.missing, required: row.required), table: "DeliveryCook")]
        for source in record.sourceOptions where (need.matchedSourceIds ?? []).contains(source.id) {
            let allocation = row.allocations.first { $0.sourceId == source.id }
            let kind = allocation?.kind ?? source.kind
            let key = kind == "delivery" ? "Matched delivery" : kind == "freezer" ? "Matched freezer stock" : "Matched pantry stock"
            lines += [field(key, source.name + " · " + source.id.uuidString.prefix(8), table: "DeliveryCook"),
                      field("Latest confirmed usable count", measured(source.quantity), table: "DeliveryCook")]
            if !source.exclusionTags.isEmpty { lines.append(field("Source exclusions", source.exclusionTags.joined(separator: ", "), table: "DeliveryCook")) }
            if let claim = row.reservations?.first(where: { $0.sourceId == source.id }) {
                lines.append(field("Amount set aside", quantity(claim.requested, required: row.required)))
                lines.append(field("Still backed by this source", quantity(claim.backed, required: row.required), table: "DeliveryCook"))
            }
            if let allocation { lines.append(field("Allocated from this source", quantity(allocation.amount, required: row.required), table: "DeliveryCook")) }
        }
        if row.reservations?.isEmpty != false { lines.append(field("Amount set aside", none)) }
        lines += row.issues.map { issue in
            switch issue {
            case "noMatch": label("No source has been matched to this ingredient.", table: "DeliveryCook")
            case "unconfirmed": label("A matched source is waiting for a usable count.", table: "DeliveryCook")
            case "unitMismatch": label("A matched source uses an incompatible unit.", table: "DeliveryCook")
            case "exclusion": label("A matched source conflicts with a recorded exclusion.", table: "DeliveryCook")
            case "reservationShortfall": label("A source no longer covers the full amount set aside.", table: "DeliveryCook")
            default: label(Self.issueKey(issue))
            }
        }
        return lines
    }
}
