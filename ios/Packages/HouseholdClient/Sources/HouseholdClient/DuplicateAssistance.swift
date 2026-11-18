import Foundation

public struct FamilyDuplicateBasis: Equatable, Encodable, Sendable {
    public let shopID: UUID
    public let shopRevision: Int
    public let authorityEpoch: Int
    public let requestRevision: Int

    public init(shopID: UUID, shopRevision: Int, authorityEpoch: Int, requestRevision: Int) {
        self.shopID = shopID
        self.shopRevision = shopRevision
        self.authorityEpoch = authorityEpoch
        self.requestRevision = requestRevision
    }
}

public struct DuplicateAssistanceRequest: Encodable, Sendable {
    public let base: LanguageAssistanceRequest
    public let candidates: [LanguageSourceLine]
    public let family: FamilyDuplicateBasis?

    public init(consentingTo source: LanguageSourceLine, candidates: [LanguageSourceLine], locale: String,
                family: FamilyDuplicateBasis? = nil) throws {
        guard (1...8).contains(candidates.count), Set(candidates.map(\.id)).count == candidates.count,
              candidates.allSatisfy({ ReceiptLineAssistanceRequest.accepts($0.text) &&
                  $0.text == $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }) else { throw ClientError.configuration }
        base = try LanguageAssistanceRequest(consentingTo: [source], locale: locale)
        self.candidates = candidates
        self.family = family
    }

    public var purpose: String { family == nil ? "receipt-alias" : "request-duplicate" }

    private enum Fields: String, CodingKey { case candidates }
    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        try family?.encode(to: encoder)
        var fields = encoder.container(keyedBy: Fields.self)
        try fields.encode(candidates, forKey: .candidates)
    }
}

public struct DuplicateAssistanceReply: Decodable, Sendable {
    public struct Suggestion: Decodable, Sendable { let sourceLineID: UUID; let candidateID: UUID }
    let version: Int
    let requestID: UUID
    let suggestions: [Suggestion]

    public func candidate(for request: DuplicateAssistanceRequest) throws -> UUID? {
        guard version == 1, requestID == request.base.requestID, suggestions.count <= 1 else { throw ClientError.invalidResponse }
        guard let suggestion = suggestions.first else { return nil }
        guard suggestion.sourceLineID == request.base.sourceLines[0].id,
              request.candidates.contains(where: { $0.id == suggestion.candidateID }) else { throw ClientError.invalidResponse }
        return suggestion.candidateID
    }
}
