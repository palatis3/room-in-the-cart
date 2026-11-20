import Foundation

public struct CookSoonPin: Codable, Equatable, Hashable, Sendable {
    public enum Recipe: Codable, Hashable, Sendable {
        case reviewed(UUID)
        case imported(String)
    }
    public let owner: String
    public let recipe: Recipe

    public init(owner: String, recipe: Recipe) {
        self.owner = owner
        self.recipe = recipe
    }
}

public enum PrivateRecipeSearch {
    /// Match every search term against the title or any ingredient, preserving mixed-language source wording.
    public static func matches(_ query: String, title: String, ingredients: [String]) -> Bool {
        let terms = normalizedProduct(query).split(separator: " ")
        guard !terms.isEmpty else { return true }
        let text = normalizedProduct(([title] + ingredients).joined(separator: " "))
        return terms.allSatisfy { text.contains($0) }
    }
}

public extension MealTemplate {
    func matchesRecipeSearch(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return PrivateRecipeSearch.matches(query, title: title, ingredients: ingredients.flatMap { [$0.name, $0.originalWording ?? ""] })
    }
}

public extension LedgerWorkspace {
    mutating func setCookSoon(_ pin: CookSoonPin, pinned: Bool) throws {
        if !pinned { cookSoonPins.removeAll { $0 == pin }; return }
        guard !cookSoonPins.contains(pin) else { return }
        try validateRecipePin(pin)
        cookSoonPins.append(pin)
    }

    internal func validateRecipePin(_ pin: CookSoonPin) throws {
        try ledgerText(pin.owner, nonempty: true, maximum: 128)
        if case let .imported(id) = pin.recipe { try ledgerText(id, nonempty: true, maximum: 2048) }
    }

    mutating func discardOrphanedRecipeShortcuts() {
        guard !cookSoonPins.isEmpty else { return }
        let recipes = mealTemplates + dinnerPlanning.acceptedDinners.map(\.template)
        let ids = Set(recipes.map(\.id))
        cookSoonPins.removeAll {
            if case let .reviewed(id) = $0.recipe { return !ids.contains(id) }
            return false
        }
    }
}

/// A private choice of a specific product. Counts, holds, and restriction evidence always come from current stock.
public struct RecipeProductMatch: Codable, Equatable, Sendable {
    public struct Key: Codable, Equatable, Hashable, Sendable {
        public let owner: String
        public let pantryID: UUID
        public let recipeID: UUID
        public let ingredientID: UUID

        public init(owner: String, pantryID: UUID, recipeID: UUID, ingredientID: UUID) {
            self.owner = owner; self.pantryID = pantryID; self.recipeID = recipeID; self.ingredientID = ingredientID
        }
    }
    public let key: Key
    public let recipeRevision: Int
    public let recipeDigest: String
    public let foodID: UUID
    public let productDigest: String

    public init(key: Key, recipeRevision: Int, recipeDigest: String, foodID: UUID, productDigest: String) {
        self.key = key; self.recipeRevision = recipeRevision; self.recipeDigest = recipeDigest
        self.foodID = foodID; self.productDigest = productDigest
    }
}

public extension LedgerWorkspace {
    func withoutRecipeShortcuts() -> Self {
        var copy = self
        copy.cookSoonPins = []
        return copy
    }
}
