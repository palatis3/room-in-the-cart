import Foundation

public struct SharedCookReview: Codable, Equatable, Sendable {
    public struct Base: Codable, Equatable, Sendable {
        public let grantEpoch, pantryRevision, supplyRevision, recoveryRevision, contextRevision, shopRevision, authorityEpoch, mealRevision: Int
        public let occurrenceId, recipeRevisionId: UUID

        public func fields() -> [String: JSONValue] {
            ["grantEpoch": .integer(grantEpoch), "pantryRevision": .integer(pantryRevision), "supplyRevision": .integer(supplyRevision),
             "recoveryRevision": .integer(recoveryRevision), "contextRevision": .integer(contextRevision), "mealRevision": .integer(mealRevision),
             "occurrenceId": .string(occurrenceId.uuidString.lowercased()), "recipeRevisionId": .string(recipeRevisionId.uuidString.lowercased())]
        }
    }
    public struct Lot: Codable, Equatable, Identifiable, Sendable {
        public let lotId, headId: UUID
        public let name, location: String
        public let quantity: SharedMealQuantity?
        public var id: UUID { lotId }
    }
    public struct Need: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let quantity: SharedMealQuantity?
        public let groupNames: [String]
        public let lots: [Lot]
    }
    public struct Unresolved: Codable, Equatable, Identifiable, Sendable {
        public let rowId, needId: UUID
        public let lotId: UUID?
        public var id: UUID { rowId }
    }
    public struct Completion: Codable, Equatable, Sendable {
        public let cookId: UUID
        public let servings: Int
        public let unresolved: [Unresolved]
    }
    public let v: Int
    public let base: Base
    public let title: String
    public let plannedPortions: Int
    public let needs: [Need]
    public let completion: Completion?

    func validate(occurrence: UUID) throws {
        guard v == 1, occurrence == base.occurrenceId, !title.isEmpty, plannedPortions > 0,
              [base.grantEpoch, base.pantryRevision, base.supplyRevision, base.recoveryRevision, base.contextRevision].allSatisfy({ $0 >= 0 }),
              base.shopRevision > 0, base.authorityEpoch > 0, base.mealRevision > 0, needs.count <= 200,
              Set(needs.map(\.id)).count == needs.count else { throw ClientError.invalidResponse }
        for need in needs {
            guard !need.name.isEmpty, Set(need.lots.map(\.id)).count == need.lots.count else { throw ClientError.invalidResponse }
            for lot in need.lots {
                guard !lot.name.isEmpty, ["fridge", "freezer", "pantry"].contains(lot.location) else { throw ClientError.invalidResponse }
                if let count = lot.quantity {
                    guard (0...1_000_000_000).contains(count.amount.numerator), (1...1_000_000_000).contains(count.amount.denominator) else { throw ClientError.invalidResponse }
                }
            }
        }
        if let c = completion {
            guard c.servings > 0, Set(c.unresolved.map(\.id)).count == c.unresolved.count,
                  c.unresolved.allSatisfy({ row in needs.contains { $0.id == row.needId } }) else { throw ClientError.invalidResponse }
        }
    }
}
extension HouseholdService {
    public func sharedCookReview(shopID: String, occurrence: UUID) async throws -> SharedCookReview {
        let start = generation
        _ = try await authorizeShopper(shopID: shopID, capability: "cook_completion")
        guard start == generation else { throw ClientError.cancelled }
        let result: SharedCookReview = try await perform("shops/\(shopID)/cook-completion", method: "GET",
            query: [.init(name: "occurrenceId", value: occurrence.uuidString.lowercased())])
        try result.validate(occurrence: occurrence)
        return result
    }
}
extension ShopperReceipt {
    func validateCookCompletion(_ envelope: CommandEnvelope) throws {
        guard let op = UUID(uuidString: operationId), let cookId, let grantEpoch, let pantryRevision, pantryRevision > 0,
              kind == envelope.kind, disposition == "recorded", shopId == envelope.shopId,
              shopRevision == envelope.base.shopRevision, authorityEpoch == envelope.base.authorityEpoch,
              envelope.body["grantEpoch"] == .integer(grantEpoch), envelope.body["pantryRevision"] == .integer(pantryRevision - 1),
              kind == "cook.complete" ? op == cookId : envelope.body["cookId"] == .string(cookId.uuidString.lowercased()) else {
            throw ClientError.invalidResponse
        }
    }
}
