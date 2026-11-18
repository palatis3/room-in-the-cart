import Foundation

public struct LanguageSourceLine: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public init(id: UUID, text: String) { self.id = id; self.text = text }
}

public struct LanguageAssistanceRequest: Encodable, Equatable, Sendable {
    public let version = 1
    public let requestID: UUID
    public let issuedAt: Int64
    public let consent = true
    public let locale: String
    public let sourceLines: [LanguageSourceLine]

    public init(consentingTo lines: [LanguageSourceLine], locale: String, now: Date = Date()) throws {
        guard ["en", "es"].contains(locale), (1...8).contains(lines.count), Set(lines.map(\.id)).count == lines.count,
              lines.allSatisfy({ ReceiptLineAssistanceRequest.accepts($0.text) &&
                  $0.text == $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }) else { throw ClientError.configuration }
        self.requestID = UUID(); self.issuedAt = Int64(now.timeIntervalSince1970 * 1000)
        self.locale = locale; self.sourceLines = lines
    }
}

private struct LanguageAvailability: Decodable, Sendable { let version: Int; let available: Bool }

public struct NaturalListSuggestion: Decodable, Equatable, Sendable {
    public let sourceLineID: UUID
    public let itemName: String
    public let purpose: String?
    public let exclusion: String?
}

public struct NaturalListReply: Decodable, Sendable {
    public let version: Int; public let requestID: UUID
    public let suggestions: [NaturalListSuggestion]
    public func validate(for request: LanguageAssistanceRequest) throws {
        guard version == 1, requestID == request.requestID, suggestions.count <= request.sourceLines.count,
              Set(suggestions.map(\.sourceLineID)).count == suggestions.count else { throw ClientError.invalidResponse }
        for suggestion in suggestions {
            guard let line = request.sourceLines.first(where: { $0.id == suggestion.sourceLineID }),
                  [suggestion.itemName, suggestion.purpose, suggestion.exclusion].compactMap({ $0 }).allSatisfy({
                      ReceiptLineAssistanceRequest.accepts($0) && line.text.range(of: $0, options: .literal) != nil
                  }) else { throw ClientError.invalidResponse }
        }
    }
}

extension HouseholdService {
    private func languagePath(_ purpose: String) throws -> String {
        guard (1...40).contains(purpose.utf8.count), purpose.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }) else { throw ClientError.configuration }
        return "language-assistance/" + purpose
    }

    public func languageAssistanceAvailable(purpose: String, scope: ReceiptAssistanceScope) async throws -> Bool {
        try verifyReceiptAssistanceScope(scope)
        let reply: LanguageAvailability = try await perform(try languagePath(purpose), method: "GET", reportingShopID: scope.shopID, maximumResponseBytes: 1024)
        try verifyReceiptAssistanceScope(scope)
        guard reply.version == 1 else { throw ClientError.invalidResponse }
        return reply.available
    }

    public func languageSuggestion<T: Decodable & Sendable>(purpose: String, body: Data, scope: ReceiptAssistanceScope) async throws -> T {
        try verifyReceiptAssistanceScope(scope)
        guard body.count <= 16_384 else { throw ClientError.configuration }
        let reply: T = try await perform(try languagePath(purpose), method: "POST", body: body, reportingShopID: scope.shopID, maximumResponseBytes: 24_576)
        try Task.checkCancellation()
        try verifyReceiptAssistanceScope(scope)
        return reply
    }

    public func naturalListSuggestion(_ request: LanguageAssistanceRequest, scope: ReceiptAssistanceScope) async throws -> NaturalListReply {
        let reply: NaturalListReply = try await languageSuggestion(purpose: "natural-list", body: JSONEncoder().encode(request), scope: scope)
        try reply.validate(for: request)
        return reply
    }
}
