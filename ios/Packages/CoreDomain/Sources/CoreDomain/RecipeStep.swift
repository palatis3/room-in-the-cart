import Foundation

/// Ingredient positions refer to the ordered ingredient snapshot saved with this recipe.
/// Empty references mean the relationship has not been reviewed.
public struct RecipeStep: Codable, Sendable, Equatable {
    public let version: Int
    public let instruction: String
    public var ingredientIndices: [Int]
    public var suggestedTimerMinutes: Int?

    public init(_ instruction: String, ingredientIndices: [Int] = [], suggestedTimerMinutes: Int? = nil) {
        self.version = 1
        self.instruction = instruction
        self.ingredientIndices = ingredientIndices
        self.suggestedTimerMinutes = suggestedTimerMinutes
    }

    public static func validate(_ steps: [Self], ingredientCount: Int) throws {
        guard steps.count <= 1000 else { throw LedgerError.invalid("recipeSteps") }
        for step in steps {
            guard step.version == 1, step.instruction.utf8.count <= 32768, !step.instruction.contains("\0"),
                  step.ingredientIndices.count <= ingredientCount,
                  step.ingredientIndices == step.ingredientIndices.sorted(),
                  Set(step.ingredientIndices).count == step.ingredientIndices.count,
                  step.ingredientIndices.allSatisfy({ (0..<ingredientCount).contains($0) }),
                  step.suggestedTimerMinutes.map({ (1...1440).contains($0) }) ?? true else {
                throw LedgerError.invalid("recipeStep")
            }
        }
    }

    public var hasReviewedDetails: Bool { !ingredientIndices.isEmpty || suggestedTimerMinutes != nil }

    public static func rebinding(_ steps: [Self], from old: [MealIngredient], to new: [MealIngredient]) -> [Self] {
        struct Key: Hashable { let id: UUID; let name: String }
        return rebinding(steps, from: old.map { Key(id: $0.id, name: $0.name) },
                         to: new.map { Key(id: $0.id, name: $0.name) })
    }

    /// A changed/deleted ingredient cannot inherit another line's review. Preserve
    /// references only when the same identifiable line survives unambiguously.
    public static func rebinding<Key: Hashable>(_ steps: [Self], from old: [Key], to new: [Key]) -> [Self] {
        guard old != new else { return steps }
        let previous = Dictionary(grouping: old.indices, by: { old[$0] })
        let current = Dictionary(grouping: new.indices, by: { new[$0] })
        return steps.map { original in
            var step = original
            step.ingredientIndices = original.ingredientIndices.compactMap { index in
                guard old.indices.contains(index), previous[old[index]]?.count == 1,
                      let matches = current[old[index]], matches.count == 1 else { return nil }
                return matches[0]
            }.sorted()
            return step
        }
    }
}
