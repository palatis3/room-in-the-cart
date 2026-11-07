import Foundation

public struct SharedRecoveryFacts: Sendable {
    public let page: SharedRecoveryPage
    public let delivery: SharedDeliveryPage
    public let pantry: SharedPantryPage
}

extension HouseholdService {
    public func mealRecoveryFacts(shopID: String) async throws -> SharedRecoveryFacts {
        let start = generation
        try await authorizeShopper(shopID: shopID, capability: "meal_recovery")
        let delivery = try await deliveryEvidence(shopID: shopID)
        let pantry = try await pantryLots(reviewed: delivery)
        guard start == generation else { throw ClientError.cancelled }
        var page: SharedRecoveryPage = try await perform("shops/\(shopID)/meal-recovery", method: "GET")
        try page.validate(delivery: delivery, pantry: pantry)
        try page.bindPhysicalHeads(delivery: delivery, pantry: pantry)
        return .init(page: page, delivery: delivery, pantry: pantry)
    }

    public func previewMealRecovery(_ intent: SharedRecoveryIntent, reviewed page: SharedRecoveryPage) async throws -> SharedRecoveryPreview {
        let id = page.shopId.uuidString.lowercased(), start = generation
        try await authorizeShopper(shopID: id, capability: "meal_recovery")
        guard start == generation else { throw ClientError.cancelled }
        if intent.fallback != nil { try await authorizeAssistance(shopID: id) }
        guard start == generation else { throw ClientError.cancelled }
        let body = try intent.commandBody(reviewed: page)
        let preview: SharedRecoveryPreview = try await perform("shops/\(id)/meal-recovery/preview", method: "POST", body: encoded(body))
        try preview.validate(page: page, intent: intent)
        return preview
    }

    public func effectiveCoverage(reviewed page: SharedRecoveryPage) async throws -> SharedRecoveryCoverage {
        let id = page.shopId.uuidString.lowercased(), start = generation
        try await authorizeShopper(shopID: id, capability: "meal_recovery")
        guard start == generation else { throw ClientError.cancelled }
        let result: SharedRecoveryCoverage = try await perform("shops/\(id)/meal-recovery/coverage", method: "GET")
        try result.validate(reviewed: page)
        return result
    }
}

extension ShopperReceipt {
    func validateRecovery(_ command: CommandEnvelope) throws {
        guard disposition == "recorded", kind == command.kind, shopId == command.shopId, UUID(uuidString: operationId) != nil,
              shopRevision == command.base.shopRevision, authorityEpoch == command.base.authorityEpoch,
              case .object(let base) = command.body["base"], base["shopRevision"] == .integer(shopRevision),
              base["authorityEpoch"] == .integer(authorityEpoch), let recoveryRevision, recoveryRevision > 0,
              base["recoveryRevision"] == .integer(recoveryRevision - 1), let occurrenceId, let revisionId,
              case .object(let intent) = command.body["intent"], case .string(let occurrence) = intent["occurrenceId"],
              case .object(let meal) = intent["replacement"], case .string(let revision) = meal["revisionId"],
              UUID(uuidString: occurrence) == occurrenceId, UUID(uuidString: revision) == revisionId else { throw ClientError.invalidResponse }
    }
}
