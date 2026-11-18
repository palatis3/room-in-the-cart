import Foundation

public enum MealExplanationReason: String, Codable, CaseIterable, Sendable {
    case pantryMatch = "pantry_match"
    case ingredientsCovered = "ingredients_covered"
    case needsMoreFood = "needs_more_food"
    case reviewedPreparationTime = "reviewed_preparation_time"
}

public struct MealExplanationCandidate: Encodable, Equatable, Sendable {
    public let id: UUID
    public let allowedReasons: [MealExplanationReason]
    public init(id: UUID, allowedReasons: [MealExplanationReason]) { self.id = id; self.allowedReasons = allowedReasons }
}

public struct MealExplanationRequest: Encodable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let issuedAt: Int64
    public let consent: Bool
    public let locale: String
    public let sourceLines: [LanguageSourceLine]
    public let candidates: [MealExplanationCandidate]
    public init(consentingTo lines: [LanguageSourceLine], candidates: [MealExplanationCandidate], locale: String, now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0,
              now.timeIntervalSince1970 < Double(Int64.max / 1000),
              candidates.count == lines.count, Set(candidates.map(\.id)) == Set(lines.map(\.id)),
              candidates.allSatisfy({ !$0.allowedReasons.isEmpty && Set($0.allowedReasons).count == $0.allowedReasons.count }) else {
            throw ClientError.configuration
        }
        let base = try LanguageAssistanceRequest(consentingTo: lines, locale: locale, now: now)
        version = 1; requestID = base.requestID; issuedAt = base.issuedAt; consent = true
        self.locale = locale; sourceLines = lines; self.candidates = candidates
    }
}

private struct MealExplanationKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func exactMealKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let values = try decoder.container(keyedBy: MealExplanationKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == expected else { throw ClientError.invalidResponse }
}

public struct MealExplanationSuggestion: Decodable, Equatable, Sendable {
    public let sourceLineID: UUID
    public let reasons: [MealExplanationReason]
    private enum CodingKeys: String, CodingKey { case sourceLineID, reasons }
    public init(from decoder: Decoder) throws {
        try exactMealKeys(decoder, ["sourceLineID", "reasons"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceLineID = try c.decode(UUID.self, forKey: .sourceLineID)
        reasons = try c.decode([MealExplanationReason].self, forKey: .reasons)
        guard (1...4).contains(reasons.count), Set(reasons).count == reasons.count else { throw ClientError.invalidResponse }
    }
}
public struct MealExplanationReply: Decodable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let suggestions: [MealExplanationSuggestion]
    private enum CodingKeys: String, CodingKey { case version, requestID, suggestions }
    public init(from decoder: Decoder) throws {
        try exactMealKeys(decoder, ["version", "requestID", "suggestions"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        suggestions = try c.decode([MealExplanationSuggestion].self, forKey: .suggestions)
        guard version == 1, suggestions.count <= 8 else { throw ClientError.invalidResponse }
    }
    public func validate(for request: MealExplanationRequest) throws {
        guard requestID == request.requestID, suggestions.count <= request.candidates.count,
              Set(suggestions.map(\.sourceLineID)).count == suggestions.count else { throw ClientError.invalidResponse }
        for suggestion in suggestions {
            guard let candidate = request.candidates.first(where: { $0.id == suggestion.sourceLineID }),
                  Set(suggestion.reasons).isSubset(of: Set(candidate.allowedReasons)) else { throw ClientError.invalidResponse }
        }
    }
}

extension HouseholdService {
    public func mealExplanations(_ request: MealExplanationRequest, scope: ReceiptAssistanceScope) async throws -> MealExplanationReply {
        let reply: MealExplanationReply = try await languageSuggestion(purpose: "meal-explanations", body: JSONEncoder().encode(request), scope: scope)
        try reply.validate(for: request)
        return reply
    }
}
