import Foundation

public enum MealEffort: String, CaseIterable, Codable, Sendable {
    case low, medium, high
    var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
}

public struct MealTimeLimit: Codable, Equatable, Sendable {
    public var maximumMinutes: Int
    public var strict: Bool
    public init(maximumMinutes: Int, strict: Bool = false) {
        self.maximumMinutes = maximumMinutes
        self.strict = strict
    }
}

/// An absent appliance list means the kitchen has not been reviewed. A reviewed
/// empty list records a kitchen with no available appliances.
public struct MealPreferenceSettings: Codable, Equatable, Sendable {
    public var exclusions: [String] = []
    public var availableAppliances: [String]?
    public var dislikes: [String] = []
    public var preferredBrands: [String] = []
    public var maximumEffort: MealEffort?
    public var timeLimit: MealTimeLimit?
    public var strictDislikes = false
    public var strictBrands = false
    public var strictEffort = false
    public init() {}
    public func validate() throws {
        try [exclusions, availableAppliances ?? [], dislikes, preferredBrands].forEach(MealEligibilityPolicy.validateTerms)
        guard timeLimit.map({ (0...525_600).contains($0.maximumMinutes) }) ?? true,
              !strictDislikes || !dislikes.isEmpty, !strictBrands || !preferredBrands.isEmpty,
              !strictEffort || maximumEffort != nil else { throw DinnerPlanningError.invalid("mealPreferences") }
    }
}

public struct MealPreferenceProfile: Codable, Equatable, Sendable {
    public let revision: UUID
    public let settings: MealPreferenceSettings
    public init(revision: UUID = UUID(), settings: MealPreferenceSettings) {
        self.revision = revision
        self.settings = settings
    }
}

/// Only a person reviewing a recipe or substitution can mark its ingredient
/// details complete. Unknown fields survive older documents and imported text.
public struct MealEligibilityEvidence: Codable, Equatable, Sendable {
    public var reviewedIngredientDetails: [String]?
    public var requiredAppliances: [String]?
    public var brands: [String]?
    public var effort: MealEffort?
    public init() {}
    public func validate() throws {
        try [reviewedIngredientDetails, requiredAppliances, brands].compactMap { $0 }.forEach(MealEligibilityPolicy.validateTerms)
    }
}

public enum MealEligibilityPolicy {
    public enum Issue: Equatable, Sendable {
        case excluded(String), disliked(String), appliancesUnavailable([String]), brandMismatch, effortAboveLimit
        case ingredientsUnknown, appliancesUnknown, brandsUnknown, effortUnknown
        case durationAboveLimit, durationUnknown
    }
    public struct Result: Equatable, Sendable {
        public var blocked: [Issue] = []
        public var unresolved: [Issue] = []
        public var softDifferences: [Issue] = []
        public var eligible: Bool { blocked.isEmpty && unresolved.isEmpty }
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func validateTerms(_ terms: [String]) throws {
        guard terms.count <= 64, terms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 && !normalized($0).isEmpty }),
              Set(terms.map(normalized)).count == terms.count else { throw DinnerPlanningError.invalid("preferenceTerms") }
    }
    public static func evaluate(profile: MealPreferenceProfile?, ingredients: [String], evidence: MealEligibilityEvidence?,
                                reviewedElapsedMinutes: Int? = nil) -> Result {
        var result = Result()
        guard let settings = profile?.settings else { return result }
        let names = (ingredients + (evidence?.reviewedIngredientDetails ?? [])).map { " " + normalized($0) + " " }
        func matches(_ term: String) -> Bool { names.contains { $0.contains(" " + normalized(term) + " ") } }
        result.blocked = settings.exclusions.filter(matches).map(Issue.excluded)
        for term in settings.dislikes where matches(term) {
            if settings.strictDislikes { result.blocked.append(.disliked(term)) }
            else { result.softDifferences.append(.disliked(term)) }
        }
        if (!settings.exclusions.isEmpty || settings.strictDislikes), (ingredients.isEmpty || evidence?.reviewedIngredientDetails == nil) {
            result.unresolved.append(.ingredientsUnknown)
        }
        if let available = settings.availableAppliances {
            if let required = evidence?.requiredAppliances {
                let kitchen = Set(available.map(normalized))
                let missing = required.filter { !kitchen.contains(normalized($0)) }
                if !missing.isEmpty { result.blocked.append(.appliancesUnavailable(missing)) }
            } else { result.unresolved.append(.appliancesUnknown) }
        }
        if !settings.preferredBrands.isEmpty {
            let preferred = Set(settings.preferredBrands.map(normalized))
            if let brands = evidence?.brands {
                if !brands.allSatisfy({ preferred.contains(normalized($0)) }) {
                    if settings.strictBrands { result.blocked.append(.brandMismatch) } else { result.softDifferences.append(.brandMismatch) }
                }
            } else if settings.strictBrands { result.unresolved.append(.brandsUnknown) }
            else { result.softDifferences.append(.brandsUnknown) }
        }
        if let maximum = settings.maximumEffort {
            if let effort = evidence?.effort {
                if effort.rank > maximum.rank {
                    if settings.strictEffort { result.blocked.append(.effortAboveLimit) } else { result.softDifferences.append(.effortAboveLimit) }
                }
            } else if settings.strictEffort { result.unresolved.append(.effortUnknown) }
            else { result.softDifferences.append(.effortUnknown) }
        }
        if let limit = settings.timeLimit {
            if let minutes = reviewedElapsedMinutes, (0...525_600).contains(minutes) {
                if minutes > limit.maximumMinutes {
                    if limit.strict { result.blocked.append(.durationAboveLimit) }
                    else { result.softDifferences.append(.durationAboveLimit) }
                }
            } else if limit.strict { result.unresolved.append(.durationUnknown) }
            else { result.softDifferences.append(.durationUnknown) }
        }
        return result
    }
    /// Appliances and effort apply to preparing a meal. An individual food must
    /// supply its own ingredient and brand details; recipe evidence cannot clear it.
    public static func evaluateFood(profile: MealPreferenceProfile?, labels: [String], evidence: MealEligibilityEvidence?) -> Result {
        guard let profile else { return Result() }
        var food = profile.settings
        food.availableAppliances = nil
        food.maximumEffort = nil
        food.strictEffort = false
        food.timeLimit = nil
        return evaluate(profile: .init(revision: profile.revision, settings: food), ingredients: labels, evidence: evidence)
    }
    public static func evaluate(profile: MealPreferenceProfile?, template: MealTemplate) -> Result {
        evaluate(profile: profile, ingredients: template.ingredients.map(\.name), evidence: template.eligibilityEvidence,
                 reviewedElapsedMinutes: template.leadTimeMinutes)
    }
}
