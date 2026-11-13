import Foundation

/// Public configuration readiness only. This response carries no invitation, account, notice text or household data.
public struct GuardianAvailabilityResponse: Codable, Equatable, Sendable {
    public let available: Bool; public let reason: GuardianNoticeResponse.Reason?
    public init(available: Bool, reason: GuardianNoticeResponse.Reason?) { self.available = available; self.reason = reason }
    private enum CodingKeys: String, CodingKey { case available, reason }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        available = try values.decode(Bool.self, forKey: .available)
        reason = try values.decode(GuardianNoticeResponse.Reason?.self, forKey: .reason)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(available, forKey: .available); try values.encode(reason, forKey: .reason)
    }
    func validate() throws {
        guard available ? reason == nil : reason != nil else { throw ClientError.invalidResponse }
    }
}

public struct ChildNativeAuthChallenge: Codable, Equatable, Sendable {
    public let householdId: String; public let challengeId: String; public let status: String; public let expiresAt: String
    func validate() throws {
        guard GuardianValidation.ids([householdId, challengeId]), status == "check_email", GuardianValidation.date(expiresAt) else { throw ClientError.invalidResponse }
    }
}
public struct ChildNativeAuthAdmission: Codable, Equatable, Sendable {
    public let admitted: Bool
    func validate() throws { guard admitted else { throw ClientError.invalidResponse } }
}
private struct ChildNativeAuthStartBody: Codable, Equatable, Sendable {
    let clientKey: String; let token: String; let email: String; let challengeSecret: String
}
/// Save in the child's dedicated protected pending store before requesting a code. Ambiguous delivery retries these exact bytes.
public struct ChildNativeAuthStartIntent: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String; public let email: String; public let bytes: Data
    private let body: ChildNativeAuthStartBody
    public var description: String { "ChildNativeAuthStartIntent(<redacted>)" }
    public var debugDescription: String { description }
    var challengeSecret: String { body.challengeSecret }
    var invitationToken: String { body.token }
    init(token: String, email: String) throws {
        id = UUID().uuidString.lowercased(); self.email = email
        body = .init(clientKey: id, token: token, email: email, challengeSecret: try GuardianSecret.generate())
        bytes = try encoded(body); try validate()
    }
    public func validate() throws {
        guard GuardianValidation.ids([id]), GuardianChildSignInEmail.isValid(email), GuardianValidation.token(body.token),
              body.clientKey == id, body.email == email, GuardianSecret.isCanonical(body.challengeSecret), bytes == (try encoded(body)) else { throw ClientError.configuration }
    }
}
private struct ChildNativeAuthAdmitBody: Codable, Equatable, Sendable {
    let clientKey: String; let householdId: String; let challengeId: String; let challengeSecret: String
}
/// Admission stays bound to the exact fresh child session and original challenge secret. It is not an adult attestation.
public struct ChildNativeAuthAdmitIntent: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String; public let startID: String; public let issuer: String; public let subject: String; public let sessionID: String
    public let householdID: String; public let challengeID: String; public let bytes: Data
    private let body: ChildNativeAuthAdmitBody
    public var description: String { "ChildNativeAuthAdmitIntent(<redacted>)" }
    public var debugDescription: String { description }
    var binding: ChildInvitationBinding { .init(issuer: issuer, subject: subject, sessionID: sessionID) }
    init(binding: ChildInvitationBinding, challenge: ChildNativeAuthChallenge, start: ChildNativeAuthStartIntent) throws {
        try challenge.validate(); try start.validate()
        id = UUID().uuidString.lowercased(); startID = start.id; issuer = binding.issuer; subject = binding.subject; sessionID = binding.sessionID
        householdID = challenge.householdId; challengeID = challenge.challengeId
        body = .init(clientKey: id, householdId: householdID, challengeId: challengeID, challengeSecret: start.challengeSecret)
        bytes = try encoded(body); try validate()
    }
    public func validate() throws {
        guard GuardianValidation.ids([id, startID, householdID, challengeID]), GuardianValidation.text(issuer, 2000),
              GuardianValidation.text(subject, 200), GuardianValidation.text(sessionID, 200),
              body.clientKey == id, body.householdId == householdID, body.challengeId == challengeID,
              GuardianSecret.isCanonical(body.challengeSecret), bytes == (try encoded(body)) else { throw ClientError.configuration }
    }
    func matches(_ start: ChildNativeAuthStartIntent) -> Bool { startID == start.id && body.challengeSecret == start.challengeSecret }
}

extension ChildInvitationAccess {
    static func verifiedProjection(_ access: AdultAccess, expectedIssuer: String) throws -> Self {
        let sessionID = try access.verifiedSessionID(expectedIssuer: expectedIssuer)
        let value = Self(issuer: expectedIssuer, subject: access.identity.subject, sessionID: sessionID, accessToken: access.accessToken)
        try value.validate(); return value
    }
}
