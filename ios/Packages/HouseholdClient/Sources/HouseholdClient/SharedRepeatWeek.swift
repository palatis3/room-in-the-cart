import Foundation

extension SharedMeal {
    public func repeated(on day: String) -> SharedMeal {
        var copy = self
        copy.move(to: day)
        copy.planning?.completedSteps = nil
        return copy
    }
}

public struct SharedRepeatSelection: Codable, Equatable, Sendable {
    public let sourceId: UUID
    public let sourceRevision: Int
    public var day: String
    public init(source: SharedMealOccurrence, day: String) {
        sourceId = source.id
        sourceRevision = source.revision
        self.day = day
    }
}
public struct SharedRepeatSeries: Decodable, Equatable, Sendable {
    public struct Step: Decodable, Equatable, Identifiable, Sendable {
        public let targetId, sourceId: UUID
        public let sourceRevision: Int
        public let day: String
        public var id: UUID { targetId }
        public func reviewedEdit(source: SharedMealOccurrence, planID: UUID) throws -> SharedMealEdit {
            guard source.id == sourceId, source.revision == sourceRevision, source.meal.kind == "dinner" else {
                throw ClientError.configuration
            }
            let meal = source.meal.repeated(on: day)
            try meal.validatePlanning()
            var edit = SharedMealEdit(occurrenceID: targetId, meal: meal)
            edit.repeatPlanID = planID
            return edit
        }
    }
    public let planId: UUID
    public let weekStart: String
    public let stopped: Bool
    public let steps: [Step]
    // The wire dictionary has UUID strings as JSON keys.
    public let receipts: [String:String]
    public func saved(_ step: Step) -> Bool { receipts[step.targetId.uuidString.lowercased()] != nil }
}

extension HouseholdService {
    private struct RepeatResponse: Decodable, Sendable { let series: SharedRepeatSeries? }
    public func sharedRepeatWeek(shopID: UUID, week: String) async throws -> SharedRepeatSeries? {
        let response: RepeatResponse = try await perform("shops/\(shopID.uuidString.lowercased())/meal-plan/repeat-week",
            method: "GET", query: [.init(name: "week", value: week)])
        return response.series
    }
    public func stageRepeatWeek(id: UUID, week: String, plan: SharedMealPlan, selections: [SharedRepeatSelection]) async throws -> SharedRepeatSeries {
        let choices = selections.map { row -> JSONValue in
            .object(["sourceId": .string(row.sourceId.uuidString.lowercased()), "sourceRevision": .integer(row.sourceRevision), "day": .string(row.day)])
        }
        var fields = repeatFields(id: id, week: week, plan: plan)
        fields["shopRevision"] = .integer(plan.shopRevision)
        fields["selections"] = .array(choices)
        let response: RepeatResponse = try await perform("shops/\(plan.shopId.uuidString.lowercased())/meal-plan/repeat-week",
            method: "POST", body: encoded(fields))
        guard let series = response.series, series.planId == id, series.weekStart == week else { throw ClientError.invalidResponse }
        return series
    }
    public func stopRepeatWeek(_ series: SharedRepeatSeries, plan: SharedMealPlan) async throws -> SharedRepeatSeries {
        let fields = repeatFields(id: series.planId, week: series.weekStart, plan: plan)
        let response: RepeatResponse = try await perform("shops/\(plan.shopId.uuidString.lowercased())/meal-plan/repeat-week/stop",
            method: "POST", body: encoded(fields))
        guard let stopped = response.series, stopped.planId == series.planId, stopped.stopped else { throw ClientError.invalidResponse }
        return stopped
    }
    private func repeatFields(id: UUID, week: String, plan: SharedMealPlan) -> [String:JSONValue] {
        ["planId": .string(id.uuidString.lowercased()), "weekStart": .string(week), "authorityEpoch": .integer(plan.authorityEpoch),
         "grantRevision": .integer(plan.grantRevision)]
    }
}

public struct SharedWeekCosts: Decodable, Sendable {
    public struct Version: Decodable, Identifiable, Sendable {
        public struct Line: Decodable, Identifiable, Sendable {
            public let id: UUID
            public let name: String
            public let packs: Int
            public let unitPriceMinor: Int64?
        }
        public struct Quote: Decodable, Sendable {
            public let id: UUID
            public let store, branch, observedAt: String
            public let itemsMinor, checkoutMinor: Int64?
        }
        public let revision: Int
        public let capturedAt, currency: String
        public let pricedLines: Int
        public let lines: [Line]
        public let knownItemSubtotalMinor: Int64?
        public let adoptedQuote: Quote?
        public var id: Int { revision }
    }
    public let original: Version?
    public let revisions: [Version]
    public let currency: String
    public let reportedNetMinor: Int64?
}

extension HouseholdService {
    public func sharedWeekCosts(shopID: UUID, planID: UUID) async throws -> SharedWeekCosts {
        try await perform("shops/\(shopID.uuidString.lowercased())/meal-plan/repeat-week/costs", method: "GET",
                          query: [.init(name: "planId", value: planID.uuidString.lowercased())])
    }
}
