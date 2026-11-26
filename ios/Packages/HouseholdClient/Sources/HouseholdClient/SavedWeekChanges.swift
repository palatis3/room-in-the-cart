import Foundation

public struct SavedWeekNight: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let day: String
}

public struct SavedWeekReview: Decodable, Sendable {
    public struct BasketRow: Decodable, Identifiable, Sendable {
        public struct Amount: Decodable, Sendable {
            public let numerator, denominator, unit: String
        }
        public let beforeNeed, afterNeed: Amount?
        public let id: UUID
        public let name: String
        public let before, after: Int
        public let unlinked, manual, held: Bool
        public let mealIds: [UUID]
    }
    public let steps: [SavedWeekNight]
    public let basket: [BasketRow]
    public let digest: String
    public let shopper: Bool
}

public struct SavedWeekProgress: Decodable, Sendable {
    public let planId: UUID
    public let steps: [SavedWeekNight]
    public let completed: Int
    public let stopped, conflicted: Bool
    public var next: SavedWeekNight? {
        guard !stopped, steps.indices.contains(completed) else { return nil }
        return steps[completed]
    }
}

extension HouseholdService {
    private struct SavedWeekResponse: Decodable, Sendable { let series: SavedWeekProgress? }
    private func savedWeekPath(_ shop: UUID) -> String { "shops/\(shop.uuidString.lowercased())/meal-plan/saved-week" }
    public func savedWeekProgress(shop: UUID, week: String) async throws -> SavedWeekProgress? {
        let response: SavedWeekResponse = try await perform(savedWeekPath(shop), method: "GET",
                                                           query: [.init(name: "week", value: week)])
        return response.series
    }
    private func selectedWeek(_ plan: SharedMealPlan, _ week: String, _ ids: Set<UUID>) -> [String: JSONValue] {
        ["week": .string(week), "ids": .array(ids.map { $0.uuidString.lowercased() }.sorted().map(JSONValue.string)),
         "shopRevision": .integer(plan.shopRevision), "authorityEpoch": .integer(plan.authorityEpoch),
         "grantRevision": .integer(plan.grantRevision)]
    }
    public func reviewSavedWeek(_ plan: SharedMealPlan, week: String, nights: Set<UUID>) async throws -> SavedWeekReview {
        let review: SavedWeekReview = try await perform(savedWeekPath(plan.shopId) + "/preview", method: "POST",
            body: encoded(selectedWeek(plan, week, nights)))
        guard review.shopper == plan.shopper, Set(review.steps.map(\.id)) == nights,
              review.steps.count == nights.count, plan.shopper || review.basket.isEmpty else { throw ClientError.invalidResponse }
        return review
    }
    public func confirmSavedWeek(id: UUID, plan: SharedMealPlan, week: String, review: SavedWeekReview) async throws -> SavedWeekProgress {
        guard plan.shopper, review.shopper else { throw ClientError.configuration }
        var body = selectedWeek(plan, week, Set(review.steps.map(\.id)))
        body["planId"] = .string(id.uuidString.lowercased()); body["digest"] = .string(review.digest)
        let response: SavedWeekResponse = try await perform(savedWeekPath(plan.shopId) + "/confirm", method: "POST", body: encoded(body))
        guard let series = response.series, series.planId == id, series.steps == review.steps else { throw ClientError.invalidResponse }
        return series
    }
    public func advanceSavedWeek(shop: UUID, series: SavedWeekProgress, stop: Bool = false) async throws -> SavedWeekProgress {
        guard let night = series.next else { throw ClientError.configuration }
        let body: [String:JSONValue] = ["planId": .string(series.planId.uuidString.lowercased()), "id": .string(night.id.uuidString.lowercased())]
        let response: SavedWeekResponse = try await perform(savedWeekPath(shop) + (stop ? "/stop" : "/step"), method: "POST", body: encoded(body))
        guard let new = response.series, new.planId == series.planId, new.steps == series.steps,
              new.completed >= series.completed, new.completed <= new.steps.count,
              stop ? new.stopped || new.completed > series.completed : new.completed > series.completed else { throw ClientError.invalidResponse }
        return new
    }
}
