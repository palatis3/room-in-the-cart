import Foundation

public enum SharedMealReaction: String, Codable, CaseIterable, Hashable, Sendable {
    case makeAgain, tooMuchEffort, childrenLikedIt, tooManyLeftovers
}

public struct SharedMealFeedback: Decodable, Equatable, Sendable {
    public let v: Int
    public let cookId, occurrenceId: UUID
    public let grantEpoch, authorityEpoch: Int
    public let revision: UUID?
    public let own, shared: [SharedMealReaction]

    func validate(occurrence: UUID, cook: UUID) throws {
        guard v == 1, occurrenceId == occurrence, cookId == cook, grantEpoch >= 0, authorityEpoch >= 0,
              Set(own).count == own.count, Set(shared).count == shared.count else { throw ClientError.invalidResponse }
    }
}

extension HouseholdService {
    public func sharedMealFeedback(shopID: String, occurrence: UUID, cook: UUID) async throws -> SharedMealFeedback {
        let start = generation
        _ = try await authorizeShopper(shopID: shopID, capability: "meal_feedback")
        guard generation == start else { throw ClientError.cancelled }
        let page: SharedMealFeedback = try await perform("shops/\(shopID)/cook-feedback/\(occurrence.uuidString.lowercased())", method: "GET")
        guard generation == start else { throw ClientError.cancelled }
        try page.validate(occurrence: occurrence, cook: cook)
        return page
    }
    public func setSharedMealFeedback(shopID: String, reviewed: SharedMealFeedback, reactions: Set<SharedMealReaction>) async throws -> SharedMealFeedback {
        let start = generation
        let page = try await sharedMealFeedback(shopID: shopID, occurrence: reviewed.occurrenceId, cook: reviewed.cookId)
        guard start == generation, page == reviewed else { throw ClientError.service(status: 409, code: "refresh_required", correlationID: nil, retryAfter: nil) }
        let window = try await replayWindow()
        guard start == generation else { throw ClientError.cancelled }
        let body: [String: JSONValue] = [
            "v": .integer(1), "cookId": .string(page.cookId.uuidString.lowercased()), "authorityEpoch": .integer(page.authorityEpoch),
            "grantEpoch": .integer(page.grantEpoch), "expectedRevision": page.revision.map { .string($0.uuidString.lowercased()) } ?? .null,
            "clientKey": .string(UUID().uuidString.lowercased()), "replayWindow": .string(window.id),
            "reactions": .array(SharedMealReaction.allCases.filter(reactions.contains).map { .string($0.rawValue) })
        ]
        struct Receipt: Decodable { let v: Int; let revision: UUID? }
        let receipt: Receipt = try await perform("shops/\(shopID)/cook-feedback/\(page.occurrenceId.uuidString.lowercased())", method: "PUT", body: encoded(body))
        guard start == generation, receipt.v == 1 else { throw ClientError.cancelled }
        let current = try await sharedMealFeedback(shopID: shopID, occurrence: page.occurrenceId, cook: page.cookId)
        guard start == generation, current.revision == receipt.revision, Set(current.own) == reactions else { throw ClientError.invalidResponse }
        return current
    }
}

public struct SharedMealFeedbackWithdrawal: Codable, Equatable, Sendable {
    public let v, grantEpoch, count: Int
    public let basis: String
    func validate() throws {
        guard v == 1, grantEpoch >= 0, count >= 0, basis.utf8.count == 64,
              basis.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ClientError.invalidResponse }
    }
}

extension HouseholdService {
    public func reviewMyMealFeedbackWithdrawal() async throws -> SharedMealFeedbackWithdrawal {
        let start = generation, session = try currentHouseholdPantrySession()
        let page: SharedMealFeedbackWithdrawal = try await perform("pantry/my-feedback-withdrawal", method: "GET", omitSelectedShop: true)
        guard generation == start, try currentHouseholdPantrySession() == session else { throw ClientError.cancelled }
        try page.validate()
        return page
    }
    public func withdrawMyMealFeedback(_ reviewed: SharedMealFeedbackWithdrawal) async throws -> SharedMealFeedbackWithdrawal {
        let start = generation, session = try currentHouseholdPantrySession()
        let body: [String: JSONValue] = ["v": .integer(1), "grantEpoch": .integer(reviewed.grantEpoch), "basis": .string(reviewed.basis)]
        let result: SharedMealFeedbackWithdrawal = try await perform("pantry/my-feedback-withdrawal", method: "POST", body: encoded(body), omitSelectedShop: true)
        guard generation == start, try currentHouseholdPantrySession() == session else { throw ClientError.cancelled }
        try result.validate()
        guard result.count == 0, result.grantEpoch == reviewed.grantEpoch else { throw ClientError.invalidResponse }
        return result
    }
}
