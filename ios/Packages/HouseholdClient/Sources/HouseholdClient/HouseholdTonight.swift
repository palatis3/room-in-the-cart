import Foundation

public struct HouseholdTonightPage: Decodable, Equatable, Sendable {
    public struct EditableRecipe: Decodable, Identifiable, Equatable, Sendable {
        public let recipeId: UUID
        public var id: UUID { recipeId }
        public let recipeRevision: Int
        public let reviewedRecipe: HouseholdTonightRecipeWrite.Recipe
    }
    public struct Ingredient: Decodable, Identifiable, Equatable, Sendable {
        public enum Status: String, Decodable, Sendable { case covered, missing, unknown }
        public let id: UUID
        public let name: String
        public let status: Status
        public let missing: SharedMealQuantity?
        public let evidenceAt: String?
        public let useSoon: Bool
    }
    public struct Recipe: Decodable, Identifiable, Equatable, Sendable {
        public enum Status: String, Decodable, Sendable { case eligible, unresolved }
        public enum Estimate: String, Decodable, Sendable { case incomplete, noPurchaseNeeded }
        public let recipeId: UUID
        public var id: UUID { recipeId }
        public let recipeRevision: Int
        public let title: String
        public let portions: Int
        public let minutes: Int?
        public let status: Status
        public let ingredients: [Ingredient]
        public let reviewToken: String?
        public let checkoutEstimate: Estimate
        public let reviewedRecipe: HouseholdTonightRecipeWrite.Recipe?
        public var editable: EditableRecipe? {
            reviewedRecipe.map { EditableRecipe(recipeId: id, recipeRevision: recipeRevision, reviewedRecipe: $0) }
        }
    }
    public let v: Int
    public let householdId: UUID
    public let grantEpoch: Int
    public let pantryRevision: Int
    public let asOf: String
    public let canReviewRecipes: Bool
    public let recipes: [Recipe]
    public let excludedCount: Int
    public let excludedReviewedRecipes: [EditableRecipe]?

    func validate(session: HouseholdPantrySession) throws {
        guard v == 1, householdId == session.householdID, grantEpoch >= 0, pantryRevision >= 0,
              validHelperTimestamp(asOf), excludedCount >= 0, recipes.count <= 100,
              Set(recipes.map(\.id)).count == recipes.count else { throw ClientError.invalidResponse }
        let excluded = excludedReviewedRecipes ?? []
        guard excluded.isEmpty || canReviewRecipes, excluded.count <= excludedCount,
              recipes.count + excluded.count <= 100,
              Set(recipes.map(\.id) + excluded.map(\.id)).count == recipes.count + excluded.count else {
            throw ClientError.invalidResponse
        }
        for record in excluded {
            guard record.recipeRevision > 0 else { throw ClientError.invalidResponse }
            try record.reviewedRecipe.validate()
        }
        for recipe in recipes {
            guard sharedMealText(recipe.title, 240), recipe.recipeRevision > 0, (1...1000).contains(recipe.portions),
                  recipe.minutes.map({ (0...525600).contains($0) }) != false, (1...60).contains(recipe.ingredients.count),
                  Set(recipe.ingredients.map(\.id)).count == recipe.ingredients.count,
                  (recipe.status == .eligible) == (recipe.reviewToken != nil),
                  recipe.reviewToken.map(Self.validToken) != false,
                  recipe.status != .eligible || recipe.ingredients.allSatisfy({ $0.status != .unknown }),
                  recipe.checkoutEstimate != .noPurchaseNeeded || (recipe.status == .eligible &&
                      recipe.ingredients.allSatisfy({ $0.status == .covered }))
            else { throw ClientError.invalidResponse }
            if let editable = recipe.reviewedRecipe {
                try editable.validate()
                guard canReviewRecipes, editable.title == recipe.title, editable.portions == recipe.portions,
                      editable.minutes == recipe.minutes, editable.ingredients.map(\.id) == recipe.ingredients.map(\.id),
                      editable.ingredients.map(\.name) == recipe.ingredients.map(\.name) else { throw ClientError.invalidResponse }
            }
            for row in recipe.ingredients {
                guard sharedMealText(row.name, 240), row.evidenceAt.map(validHelperTimestamp) != false, (row.status == .missing) == (row.missing != nil),
                      row.missing.map({ $0.validStockQuantity && $0.amount.numerator > 0 }) != false else {
                    throw ClientError.invalidResponse
                }
            }
        }
    }
    static func validToken(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    public func choiceBody(for recipe: Recipe, day: String?, occurrence: UUID) throws -> [String: JSONValue] {
        guard recipes.contains(recipe), recipe.status == .eligible, let token = recipe.reviewToken,
              Self.validToken(token), day.map(householdReceiptDay) != false else { throw ClientError.configuration }
        return ["v": .integer(1), "recipeId": .string(recipe.id.uuidString.lowercased()),
                "recipeRevision": .integer(recipe.recipeRevision), "grantEpoch": .integer(grantEpoch),
                "reviewToken": .string(token), "day": day.map(JSONValue.string) ?? .null,
                "occurrenceId": .string(occurrence.uuidString.lowercased())]
    }
}

/// Carries the exact reviewed recipe and its retry key across a lost response.
public struct HouseholdTonightRecipeWrite: Encodable, Sendable {
    public struct Recipe: Codable, Equatable, Sendable {
        public struct Ingredient: Codable, Equatable, Sendable {
            public let id: UUID, name: String, quantity: SharedMealQuantity?
            public let reviewedLotIds: [UUID]
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id.uuidString.lowercased(), forKey: .id); try c.encode(name, forKey: .name); try c.encode(quantity, forKey: .quantity)
                try c.encode(reviewedLotIds.map { $0.uuidString.lowercased() }, forKey: .reviewedLotIds)
            }
            private enum CodingKeys: String, CodingKey { case id, name, quantity, reviewedLotIds }
        }
        public let title: String, portions: Int, minutes: Int?, ingredients: [Ingredient], preferenceEvidence: SharedMealPreferenceEvidence?
        fileprivate func validate() throws {
            guard sharedMealText(title, 240), (1...1000).contains(portions),
                  minutes.map({ (0...525600).contains($0) }) != false, (1...60).contains(ingredients.count),
                  Set(ingredients.map(\.id)).count == ingredients.count, ingredients.allSatisfy({ row in
                      sharedMealText(row.name, 240) && row.reviewedLotIds.count <= 12 &&
                          Set(row.reviewedLotIds).count == row.reviewedLotIds.count &&
                          row.quantity.map({ $0.validStockQuantity && $0.amount.numerator > 0 }) != false
                  }) else { throw ClientError.invalidResponse }
        }
        private enum CodingKeys: String, CodingKey { case title, portions, minutes, ingredients, preferenceEvidence }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title); try c.encode(portions, forKey: .portions); try c.encode(minutes, forKey: .minutes)
            try c.encode(ingredients, forKey: .ingredients); try c.encode(preferenceEvidence, forKey: .preferenceEvidence)
        }
    }
    public let v = 1, reviewed = true
    public let clientKey: UUID, replayWindow: UUID, grantEpoch: Int, recipeId: UUID, recipe: Recipe
    public let baseRevision: Int?
    public let session: HouseholdPantrySession
    private enum CodingKeys: String, CodingKey { case v, reviewed, clientKey, replayWindow, grantEpoch, recipeId, baseRevision, recipe }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v); try c.encode(reviewed, forKey: .reviewed); try c.encode(clientKey, forKey: .clientKey)
        try c.encode(replayWindow, forKey: .replayWindow); try c.encode(grantEpoch, forKey: .grantEpoch)
        try c.encode(recipeId, forKey: .recipeId); try c.encode(baseRevision, forKey: .baseRevision); try c.encode(recipe, forKey: .recipe)
    }
}

extension HouseholdService {
    public func householdTonight(for session: HouseholdPantrySession) async throws -> HouseholdTonightPage {
        let start = generation
        guard authorizedTonightSession == session, try currentHouseholdPantrySession() == session else { throw ClientError.accessEnded }
        let page: HouseholdTonightPage = try await perform("pantry/tonight", method: "GET", omitSelectedShop: true)
        guard start == generation, authorizedTonightSession == session, try currentHouseholdPantrySession() == session else { throw ClientError.accessEnded }
        try page.validate(session: session)
        return page
    }

    public func prepareTonightRecipe(_ meal: SharedMeal, evidence: SharedMealPreferenceEvidence?, reviewedLots: [UUID: [UUID]],
            page: HouseholdTonightPage, session: HouseholdPantrySession, replacing: HouseholdTonightPage.EditableRecipe? = nil) async throws -> HouseholdTonightRecipeWrite {
        try page.validate(session: session)
        try meal.validatePlanning()
        guard authorizedTonightSession == session, try currentHouseholdPantrySession() == session, page.canReviewRecipes, meal.kind == "dinner",
              !meal.protected, meal.day == nil, let planning = meal.planning, !planning.ingredients.isEmpty else {
            throw ClientError.configuration
        }
        guard replacing.map({ page.recipes.compactMap(\.editable).contains($0) || page.excludedReviewedRecipes?.contains($0) == true }) != false,
              planning.leadTimeMinutes.map({ (0...525600).contains($0) }) != false,
              Set(reviewedLots.keys).isSubset(of: Set(planning.ingredients.map(\.id))),
              reviewedLots.values.allSatisfy({ $0.count <= 12 && Set($0).count == $0.count }) else { throw ClientError.configuration }
        let start = generation
        let window: ReplayWindow = try await perform("replay-windows", method: "POST", body: Data("{}".utf8), omitSelectedShop: true)
        guard start == generation, authorizedTonightSession == session, try currentHouseholdPantrySession() == session else { throw ClientError.accessEnded }
        guard let windowID = UUID(uuidString: window.id), validHelperTimestamp(window.expiresAt) else { throw ClientError.invalidResponse }
        let recipe = HouseholdTonightRecipeWrite.Recipe(title: meal.title, portions: meal.portions, minutes: planning.leadTimeMinutes,
            ingredients: planning.ingredients.map { .init(id: $0.id, name: $0.name, quantity: $0.quantity, reviewedLotIds: reviewedLots[$0.id] ?? []) }, preferenceEvidence: evidence)
        return .init(clientKey: UUID(), replayWindow: windowID, grantEpoch: page.grantEpoch, recipeId: replacing?.id ?? UUID(), recipe: recipe, baseRevision: replacing?.recipeRevision, session: session)
    }

    public func saveTonightRecipe(_ write: HouseholdTonightRecipeWrite) async throws {
        struct Receipt: Decodable, Sendable { let recipeId: UUID, recipeRevision: Int }
        let start = generation
        guard authorizedTonightSession == write.session, try currentHouseholdPantrySession() == write.session else { throw ClientError.accessEnded }
        let result: Receipt = try await perform("pantry/tonight/recipes", method: "POST", body: encoded(write), omitSelectedShop: true)
        guard start == generation, authorizedTonightSession == write.session, try currentHouseholdPantrySession() == write.session else { throw ClientError.accessEnded }
        guard result.recipeId == write.recipeId, result.recipeRevision == (write.baseRevision ?? 0) + 1 else { throw ClientError.invalidResponse }
    }
}
