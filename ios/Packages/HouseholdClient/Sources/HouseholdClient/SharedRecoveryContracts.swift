import CryptoKit
import Foundation

/// The service distinguishes required nullable fields from optional, absent fields.
@propertyWrapper public struct RecoveryNullable<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Value?
    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(Value?.self) }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(wrappedValue)
    }
}

public struct SharedRecoveryBase: Codable, Equatable, Sendable {
    public let shopRevision, authorityEpoch, recoveryRevision, supplyRevision, pantryRevision, contextRevision: Int
}

public struct SharedRecoveryNeed: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    @RecoveryNullable public var foodId: UUID?
    public var matchedSourceIds: [UUID]?
    public var ingredientId: UUID
    @RecoveryNullable public var groupId: UUID?
    public var groupIds: [UUID]?
    public var name, notes: String
    @RecoveryNullable public var quantity: SharedMealQuantity?
    public var priority: String
    @RecoveryNullable public var due: String?
    public var exclusions: [String]

    public init(id: UUID, foodId: UUID?, matchedSourceIds: [UUID]?, ingredientId: UUID, groupId: UUID?, groupIds: [UUID]?,
                name: String, notes: String, quantity: SharedMealQuantity?, priority: String, due: String?, exclusions: [String]) {
        self.id = id; self.foodId = foodId; self.matchedSourceIds = matchedSourceIds; self.ingredientId = ingredientId
        self.groupId = groupId; self.groupIds = groupIds; self.name = name; self.notes = notes; self.quantity = quantity
        self.priority = priority; self.due = due; self.exclusions = exclusions
    }
    var groups: [UUID] { groupId.map { [$0] } ?? groupIds ?? [] }
    var sources: Set<UUID> { Set(matchedSourceIds ?? foodId.map { [$0] } ?? []) }
}

public struct SharedRecoveryMeal: Codable, Equatable, Sendable, Identifiable {
    public struct Group: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var servings: SharedMealAmount
        public var protected: Bool
        public var exclusions: [String]
    }
    public struct Template: Codable, Equatable, Sendable {
        public var id: UUID
        public var version: Int
    }
    public var id: UUID { occurrenceId }
    public var occurrenceId, revisionId: UUID
    public var sourceMealRevision, portions: Int
    public var title, notes, day: String
    @RecoveryNullable public var sourceURL: String?
    @RecoveryNullable public var zone: String?
    @RecoveryNullable public var due: String?
    public var exclusions: [String]
    @RecoveryNullable public var template: Template?
    public var groups: [Group]
    public var needs: [SharedRecoveryNeed]
    @RecoveryNullable public var remainingElapsedMinutes: Int?
    @RecoveryNullable public var requiredLeadMinutes: Int?
    public var advanceStepsCompleted: Bool

    /// The same semantic SHA-256 used by the recovery service, including nulls
    /// and explicit source matches. UUIDs are lowercased only in identity fields.
    public func targetDigest() throws -> String {
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded(self))
        let payload = try recoveryCanonical(value)
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private func recoveryCanonical(_ value: JSONValue, key: String = "") throws -> String {
    func quoted(_ text: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(text), as: UTF8.self)
    }
    switch value {
    case .null: return "null"
    case .bool(let flag): return flag ? "true" : "false"
    case .integer(let n): return String(n)
    case .string(let text):
        let identifier = key == "id" || key.hasSuffix("Id") || key.hasSuffix("Ids")
        return try quoted(identifier ? text.lowercased() : text)
    case .array(let values): return "[" + (try values.map { try recoveryCanonical($0, key: key) }).joined(separator: ",") + "]"
    case .object(let fields):
        let entries = try fields.sorted { $0.key < $1.key }.map { name, field in
            try quoted(name) + ":" + recoveryCanonical(field, key: name)
        }
        return "{" + entries.joined(separator: ",") + "}"
    }
}

public struct SharedRecoveryPage: Decodable, Equatable, Sendable {
    public struct SourceOption: Decodable, Equatable, Sendable, Identifiable {
        public var id: UUID { sourceId }
        public let sourceId: UUID
        public let name, kind: String
        public let exclusionTags: [String]
        @RecoveryNullable public var quantity: SharedMealQuantity?
    }
    public struct MealSource: Decodable, Equatable, Sendable {
        public struct ApprovedIdea: Codable, Equatable, Sendable { public let id: UUID; public let revision: Int }
        public let occurrenceId: UUID
        public let sourceMealRevision: Int
        public let sealedRevisionId: UUID
        public let completedSteps: [String]
        @RecoveryNullable public var sourceOccurrenceId: UUID?
        @RecoveryNullable public var approvedIdea: ApprovedIdea?
    }
    public struct TargetDigest: Decodable, Equatable, Sendable { public let occurrenceId: UUID; public let digest: String }
    public let shopId: UUID
    public let placedRevision: Int
    public let asOf: String
    public let base: SharedRecoveryBase
    public let meals: [SharedRecoveryMeal]
    public let targetDigests: [TargetDigest]
    public let sourceOptions: [SourceOption]
    public let mealSources: [MealSource]
    public let unplannedOccurrenceIds: [UUID]
    public let commitmentInventoryComplete: Bool
    var deliverySourceIDs: Set<UUID> = []
    var pinsByNeed: [UUID: [UUID: SharedDeliveryPage.Reservation]] = [:]
    private enum CodingKeys: CodingKey {
        case shopId, placedRevision, asOf, base, meals, targetDigests, sourceOptions, mealSources, unplannedOccurrenceIds, commitmentInventoryComplete
    }
}

public struct SharedRecoveryIntent: Codable, Equatable, Sendable {
    public let occurrenceId: UUID
    public let targetDigest: String
    public let replacement: SharedRecoveryMeal
    public let reviewedAt: String
    @RecoveryNullable public var repeatOfOccurrenceId: UUID?
    // A ranked dish can require agreement due to a prior accepted version with a different title.
    // Keep this witnessed requirement when opening and refreshing a preview. It is not a request field.
    var witnessedRepeatRequired: Bool?
    enum CodingKeys: String, CodingKey {
        case occurrenceId, targetDigest, replacement, reviewedAt, repeatOfOccurrenceId, agreesToRepeat,
             proposesExtraTrip, agreesToExtraTrip, acceptsUnresolved, fallback
    }
    public let fallback: SharedFallbackSelection?
    public let agreesToRepeat, proposesExtraTrip, agreesToExtraTrip, acceptsUnresolved: Bool
    public init(occurrenceId: UUID, targetDigest: String, replacement: SharedRecoveryMeal, reviewedAt: String, repeatOfOccurrenceId: UUID?,
                agreesToRepeat: Bool, proposesExtraTrip: Bool, agreesToExtraTrip: Bool, acceptsUnresolved: Bool, fallback: SharedFallbackSelection? = nil) {
        self.occurrenceId = occurrenceId; self.targetDigest = targetDigest; self.replacement = replacement
        self.reviewedAt = reviewedAt; self.repeatOfOccurrenceId = repeatOfOccurrenceId
        self.agreesToRepeat = agreesToRepeat; self.proposesExtraTrip = proposesExtraTrip; self.agreesToExtraTrip = agreesToExtraTrip
        self.acceptsUnresolved = acceptsUnresolved
        self.fallback = fallback
    }

    public func withFallbackAgreements(repeatMeal: Bool, extraTrip: Bool, unresolved: Bool) -> Self {
        var next = Self(occurrenceId: occurrenceId, targetDigest: targetDigest, replacement: replacement, reviewedAt: reviewedAt,
                        repeatOfOccurrenceId: repeatOfOccurrenceId, agreesToRepeat: repeatMeal, proposesExtraTrip: proposesExtraTrip,
                        agreesToExtraTrip: extraTrip, acceptsUnresolved: unresolved, fallback: fallback)
        next.witnessedRepeatRequired = witnessedRepeatRequired
        return next
    }

}

public struct SharedRecoveryPreview: Decodable, Equatable, Sendable {
    public struct Demand: Decodable, Equatable, Sendable, Identifiable {
        public struct SourceIssue: Decodable, Equatable, Sendable { public let sourceId: UUID; public let issue: String }
        public var id: UUID { needId }
        public let needId: UUID
        @RecoveryNullable public var due: String?
        public let deadlineStatus: String
        @RecoveryNullable public var allocated: SharedDeliveryCoverage.Fraction?
        @RecoveryNullable public var shortfall: SharedDeliveryCoverage.Fraction?
        @RecoveryNullable public var unit: String?
        public let issues: [String]
        public let sourceIssues: [SourceIssue]
        public let reservations: [SharedDeliveryCoverage.Reservation]
    }
    public struct Allocation: Decodable, Equatable, Sendable {
        public let needId, sourceId: UUID
        public let amount: SharedDeliveryCoverage.Fraction
        public let unit: String
    }
    public struct Projection: Decodable, Equatable, Sendable {
        public let meals: [SharedRecoveryMeal]
        public let demands: [Demand]
        public let allocations: [Allocation]
    }
    public let shopId, previewId: UUID
    public let placedRevision: Int
    public let base: SharedRecoveryBase
    public let asOf, expiresAt, previewDigest: String
    public let before, after: Projection
    public let foodConfirmed, timingConfirmed, repeatRequired, feasible, consentSatisfied: Bool
}
