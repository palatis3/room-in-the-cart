import Foundation

public enum FoodKeeperStorage: String, Codable, CaseIterable, Sendable { case pantry, refrigerator, freezer }
public enum FoodKeeperStartingEvent: String, Codable, Sendable { case purchased, opened, thawed }

public enum FoodKeeperCondition: String, Codable, CaseIterable, Sendable {
    case pantry, pantryPurchased = "from_date_of_purchase_pantry", pantryOpened = "pantry_after_opening"
    case refrigerated = "refrigerate", refrigeratedPurchased = "from_date_of_purchase_refrigerate"
    case refrigeratedOpened = "refrigerate_after_opening", refrigeratedThawed = "refrigerate_after_thawing"
    case frozen = "freeze", frozenPurchased = "from_date_of_purchase_freeze"

    public var storage: FoodKeeperStorage {
        switch self {
        case .pantry, .pantryPurchased, .pantryOpened: return .pantry
        case .refrigerated, .refrigeratedPurchased, .refrigeratedOpened, .refrigeratedThawed: return .refrigerator
        case .frozen, .frozenPurchased: return .freezer
        }
    }
    public var startingEvent: FoodKeeperStartingEvent? {
        switch self {
        case .pantryPurchased, .refrigeratedPurchased, .frozenPurchased: return .purchased
        case .pantryOpened, .refrigeratedOpened: return .opened
        case .refrigeratedThawed: return .thawed
        case .pantry, .refrigerated, .frozen: return nil
        }
    }
}

public enum FoodKeeperLanguage: Int, Sendable { case english, spanish }
public struct FoodKeeperRule: Decodable, Sendable {
    public enum Unit: String, Decodable, Sendable { case hours, days, weeks, months, years }
    private let display: [String]?
    private let notes: [String]?
    public let minimum: Int?
    public let maximum: Int?
    public let unit: Unit?
    public func guidance(_ language: FoodKeeperLanguage) -> String? { display?[language.rawValue] }
    public func note(_ language: FoodKeeperLanguage) -> String? { notes?[language.rawValue] }
    fileprivate var valid: Bool {
        guard [display, notes].allSatisfy({ $0 == nil || ($0?.count == 2 && $0?.contains("") == false) }),
              display != nil || notes != nil else { return false }
        if let minimum, let maximum { return unit != nil && minimum > 0 && maximum >= minimum && maximum <= 1000 }
        return minimum == nil && maximum == nil && unit == nil
    }
}

public struct FoodKeeperProduct: Identifiable, Decodable, Sendable {
    public let id: Int
    private let names: [String]
    private let category: [String]
    private let rules: [String: FoodKeeperRule]
    private let dateable: Bool
    public func name(_ language: FoodKeeperLanguage) -> String { names[language.rawValue] }
    public func categoryName(_ language: FoodKeeperLanguage) -> String { category[language.rawValue] }
    public func rule(for condition: FoodKeeperCondition) -> FoodKeeperRule? { rules[condition.rawValue] }

    public func supportsDateWindow(for condition: FoodKeeperCondition) -> Bool {
        guard dateable, condition.startingEvent != nil, let rule = rule(for: condition),
              let unit = rule.unit, unit != .hours, rule.minimum != nil, rule.maximum != nil else { return false }
        return true
    }

    public struct Window: Equatable, Sendable {
        public let earliest: MealDay
        public let latest: MealDay
    }
    /// The caller must confirm the product, event, continuity of the applicable storage conditions,
    /// and any more-specific package instructions before turning a source duration into a reminder.
    public func window(for condition: FoodKeeperCondition, storage: FoodKeeperStorage,
                       event: FoodKeeperStartingEvent, start: MealDay, asOf today: MealDay,
                       historyConfirmed: Bool) -> Window? {
        guard historyConfirmed, condition.storage == storage, condition.startingEvent == event, supportsDateWindow(for: condition),
              let rule = rule(for: condition), let lower = rule.minimum, let upper = rule.maximum,
              let unit = rule.unit, start.timeZoneIdentifier == today.timeZoneIdentifier,
              (try? start.validate()) != nil, (try? today.validate()) != nil,
              let date = start.date, let now = today.date, date <= now,
              let zone = TimeZone(identifier: start.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let component: Calendar.Component
        switch unit {
        case .days: component = .day
        case .weeks: component = .weekOfYear
        case .months: component = .month
        case .years: component = .year
        case .hours: return nil
        }
        func shifted(_ value: Int) -> MealDay? {
            guard let end = calendar.date(byAdding: component, value: value, to: date) else { return nil }
            return try? MealDay(date: end, timeZoneIdentifier: start.timeZoneIdentifier)
        }
        guard let earliest = shifted(lower), let latest = shifted(upper) else { return nil }
        return Window(earliest: earliest, latest: latest)
    }

    fileprivate var valid: Bool {
        id > 0 && names.count == 2 && !names.contains("") && category.count == 2 && !category.contains("") &&
        !rules.isEmpty && rules.allSatisfy { FoodKeeperCondition(rawValue: $0.key) != nil && $0.value.valid }
    }
    fileprivate func matches(_ terms: [String]) -> Bool {
        (names + category).contains { field in
            terms.allSatisfy { term in
                field.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
            }
        }
    }
}

/// A shopper-confirmed source interval, retained with the edition and civil dates that produced it.
public struct FoodKeeperReviewedRange: Codable, Equatable, Sendable {
    public let version: Int
    public let productID: Int
    public let storage: FoodKeeperStorage
    public let condition: FoodKeeperCondition
    public let event: FoodKeeperStartingEvent
    public let start: MealDay
    public let earliest: MealDay
    public let latest: MealDay

    public func matches(_ reference: FoodKeeperReference, asOf today: MealDay) -> Bool {
        reference.reviewedRange(productID: productID, condition: condition, storage: storage, event: event,
                                start: start, asOf: today, historyConfirmed: true) == self
    }
}

public struct FoodKeeperReference: Sendable {
    public let version: Int
    public let products: [FoodKeeperProduct]
    public enum Failure: Error { case unavailable, invalid }
    private struct File: Decodable { let version: Int; let products: [FoodKeeperProduct] }

    public static func bundled() throws -> FoodKeeperReference {
        guard let url = Bundle.module.url(forResource: "FoodKeeper-v128", withExtension: "json") else { throw Failure.unavailable }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 1_000_000 else { throw Failure.invalid }
        let file = try JSONDecoder().decode(File.self, from: bytes)
        guard file.version == 128, !file.products.isEmpty, file.products.allSatisfy(\.valid),
              Set(file.products.map(\.id)).count == file.products.count else { throw Failure.invalid }
        return FoodKeeperReference(version: file.version, products: file.products)
    }

    public func reviewedRange(productID: Int, condition: FoodKeeperCondition, storage: FoodKeeperStorage,
                              event: FoodKeeperStartingEvent, start: MealDay, asOf today: MealDay,
                              historyConfirmed: Bool) -> FoodKeeperReviewedRange? {
        guard let product = products.first(where: { $0.id == productID }),
              let range = product.window(for: condition, storage: storage, event: event, start: start,
                                         asOf: today, historyConfirmed: historyConfirmed) else { return nil }
        return .init(version: version, productID: productID, storage: storage, condition: condition, event: event,
                     start: start, earliest: range.earliest, latest: range.latest)
    }

    public func suggestedTerms(for text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [] }
        var seen = Set<String>()
        return words.filter { word in
            word.count >= 3 && seen.insert(word.lowercased()).inserted && products.contains { $0.matches([word]) }
        }
    }

    public func search(_ text: String, language: FoodKeeperLanguage) -> [FoodKeeperProduct] {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let locale = Locale(identifier: language == .spanish ? "es_US" : "en_US")
        return products.filter { terms.isEmpty || $0.matches(terms) }
            .sorted {
                let order = $0.name(language).compare($1.name(language), options: .caseInsensitive, locale: locale)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }
}
