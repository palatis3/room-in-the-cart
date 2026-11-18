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
