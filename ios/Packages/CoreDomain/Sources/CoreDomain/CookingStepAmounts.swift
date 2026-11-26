import Foundation

/// All values refer to a single revision of the cooking source. The session key binds the
/// review to the actor, source and revision. Original instructions and timers are separate.
public struct CookingStepAmounts: Codable, Equatable, Sendable {
    public enum Unit: String, CaseIterable, Codable, Sendable {
        case tablespoons, teaspoons, cups, milliliters, liters, grams, kilograms, ounces, pounds, pieces
    }
    public struct Allocation: Codable, Equatable, Sendable {
        public let ingredient: Int
        public let originalAmount: Rational
        public let unit: Unit
        public let byStep: [Int: Rational]

        public init(ingredient: Int, originalAmount: Rational, unit: Unit, byStep: [Int: Rational]) {
            self.ingredient = ingredient
            self.originalAmount = originalAmount
            self.unit = unit
            self.byStep = byStep
        }
    }

    public let recipeServings: Rational
    public var cookingServings: Rational
    public var allocations: [Allocation]

    public init(recipeServings: Rational, cookingServings: Rational, allocations: [Allocation]) {
        self.recipeServings = recipeServings
        self.cookingServings = cookingServings
        self.allocations = allocations
    }

    public func validate(stepCount: Int, ingredientCount: Int = 1000) throws {
        guard (1...1000).contains(stepCount), (1...1000).contains(ingredientCount),
              recipeServings > .zero, cookingServings > .zero, !allocations.isEmpty, allocations.count <= 200,
              Set(allocations.map(\.ingredient)).count == allocations.count else { throw DomainError.invalidInput("stepAmounts") }
        let scale = try cookingServings.divided(by: recipeServings)
        for allocation in allocations {
            guard (0..<ingredientCount).contains(allocation.ingredient), allocation.originalAmount > .zero,
                  !allocation.byStep.isEmpty, allocation.byStep.count <= stepCount,
                  allocation.byStep.allSatisfy({ (0..<stepCount).contains($0.key) && $0.value > .zero })
            else { throw DomainError.invalidInput("stepAllocation") }
            let sum = try allocation.byStep.values.reduce(Rational.zero) { try $0.adding($1) }
            guard sum == allocation.originalAmount else { throw DomainError.invalidInput("unreconciledStepAllocation") }
            for amount in allocation.byStep.values { _ = try amount.multiplied(by: scale) }
        }
    }

    public func scaled(_ amount: Rational) throws -> Rational {
        try amount.multiplied(by: cookingServings.divided(by: recipeServings))
    }
}
