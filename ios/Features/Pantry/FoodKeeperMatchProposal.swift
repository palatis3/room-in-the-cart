import CoreDomain
import Foundation
import HouseholdClient

struct FoodKeeperMatchChoice: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let label: String
}

/// The private workspace/lot basis stays on the device. Only the confirmed wording and public catalog subset are encoded.
struct FoodKeeperMatchBasis: Equatable {
    let actor: CapturePrivateIdentity
    let workspaceLifetime: UUID
    let householdLifetime: UUID
    let scope: ReceiptAssistanceScope
    let pantry: PantryDigestScope
    let lotID: UUID
    let lotRevision: Int64
    let catalogVersion: Int
    let locale: String
    let candidates: [FoodKeeperMatchChoice]
}

struct FoodKeeperMatchConsent {
    let basis: FoodKeeperMatchBasis
    let request: LanguageAssistanceRequest
    init(basis: FoodKeeperMatchBasis, wording: String, now: Date = Date()) throws {
        guard (1...8).contains(basis.candidates.count), Set(basis.candidates.map(\.id)).count == basis.candidates.count,
              basis.actor.subject == basis.scope.subject, basis.actor.memberID == basis.scope.memberID,
              basis.actor.householdID == basis.scope.householdID else { throw ClientError.accessEnded }
        self.basis = basis
        request = try LanguageAssistanceRequest(consentingTo: [.init(id: UUID(), text: wording)], locale: basis.locale, now: now)
    }

    func requireCurrent(_ current: FoodKeeperMatchBasis?, wording: String, now: Date = Date()) throws {
        let age = Int64(now.timeIntervalSince1970 * 1000) - request.issuedAt
        guard basis == current, request.sourceLines.first?.text == wording, (-15_000...300_000).contains(age) else {
            throw ClientError.accessEnded
        }
    }

    func wireData() throws -> Data {
        struct Body: Encodable {
            let consent: FoodKeeperMatchConsent
            enum Keys: String, CodingKey { case catalogVersion, candidates }
            func encode(to encoder: Encoder) throws {
                try consent.request.encode(to: encoder)
                var fields = encoder.container(keyedBy: Keys.self)
                try fields.encode(consent.basis.catalogVersion, forKey: .catalogVersion)
                try fields.encode(consent.basis.candidates, forKey: .candidates)
            }
        }
        return try JSONEncoder().encode(Body(consent: self))
    }
}

private struct MatchResponseKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct FoodKeeperMatchReply: Decodable, Sendable {
    struct Suggestion: Decodable, Sendable { let sourceLineID: UUID; let candidateID: Int
        enum Keys: String, CodingKey, CaseIterable { case sourceLineID, candidateID }
        init(from decoder: Decoder) throws {
            try FoodKeeperMatchReply.requireKeys(Keys.allCases.map(\.rawValue), in: decoder)
            let row = try decoder.container(keyedBy: Keys.self)
            sourceLineID = try row.decode(UUID.self, forKey: .sourceLineID)
            candidateID = try row.decode(Int.self, forKey: .candidateID)
        }
    }
    let version: Int
    let requestID: UUID
    let catalogVersion: Int
    let suggestions: [Suggestion]

    enum Keys: String, CodingKey, CaseIterable { case version, requestID, catalogVersion, suggestions }
    fileprivate static func requireKeys(_ expected: [String], in decoder: Decoder) throws {
        let actual = try decoder.container(keyedBy: MatchResponseKey.self)
        guard Set(actual.allKeys.map(\.stringValue)) == Set(expected) else { throw ClientError.invalidResponse }
    }
    init(from decoder: Decoder) throws {
        try Self.requireKeys(Keys.allCases.map(\.rawValue), in: decoder)
        let row = try decoder.container(keyedBy: Keys.self)
        version = try row.decode(Int.self, forKey: .version)
        requestID = try row.decode(UUID.self, forKey: .requestID)
        catalogVersion = try row.decode(Int.self, forKey: .catalogVersion)
        suggestions = try row.decode([Suggestion].self, forKey: .suggestions)
    }

    func match(for consent: FoodKeeperMatchConsent, current: FoodKeeperMatchBasis?, wording: String, now: Date = Date()) throws -> Int? {
        try consent.requireCurrent(current, wording: wording, now: now)
        guard version == 1, requestID == consent.request.requestID, catalogVersion == consent.basis.catalogVersion,
              suggestions.count <= 1 else { throw ClientError.invalidResponse }
        guard let choice = suggestions.first else { return nil }
        guard choice.sourceLineID == consent.request.sourceLines.first?.id,
              consent.basis.candidates.contains(where: { $0.id == choice.candidateID }) else { throw ClientError.invalidResponse }
        return choice.candidateID
    }
}
