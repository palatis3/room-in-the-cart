import Foundation

/// An adult's explicit ingredient match and optional pack observation for one shop.
/// Unmatched ingredients do not inherit stock or prices from similarly named food.
public struct DinnerIdeaFoodEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let ingredientName: String
    public let workspaceID: UUID
    public let shopID: UUID
    public let basisRevision: Int
    public let foodID: UUID?
    public let pack: PackOffer?
    public let source: String?
    public let observedAt: Date?

    public init(ingredient: MealIngredient, workspaceID: UUID, shopID: UUID, basisRevision: Int,
                foodID: UUID?, pack: PackOffer?, source: String?, observedAt: Date?) {
        id = ingredient.id
        ingredientName = ingredient.name
        self.workspaceID = workspaceID
        self.shopID = shopID
        self.basisRevision = basisRevision
        self.foodID = foodID
        self.pack = pack
        self.source = source
        self.observedAt = observedAt
    }

    func validate() throws {
        try dinnerText(ingredientName)
        guard basisRevision >= 0, foodID != nil || pack != nil else { throw DinnerPlanningError.invalid("ideaSupply") }
        if let pack {
            guard let source, let observedAt, pack.price.map({ $0 >= .zero }) ?? true,
                  pack.usableQuantity != nil || pack.price != nil else { throw DinnerPlanningError.invalid("ideaPack") }
            try dinnerText(source)
            try dinnerText(pack.label)
            try pack.confirmedConversion?.validate()
            try dinnerDate(observedAt)
            try pack.usableQuantity?.validate()
        } else if source != nil || observedAt != nil {
            throw DinnerPlanningError.invalid("ideaPack")
        }
    }
}
