import Foundation

struct GuardianActorBinding: Equatable, Sendable {
    let subject: String; let householdID: String; let memberID: String; let deviceID: String
}
struct GuardianIntentBody: Codable, Equatable, Sendable {
    let clientKey: String
    var baseRevision: Int?; var noticeVersion: String?; var noticeDigest: String?; var language: GuardianLanguage?
    var childLocation: String?; var guardianDeclaration: String?; var childId: String?; var childAlias: String?
    var decision: String?; var secret: String?; var claimId: String?; var pairingCode: String?; var childSignInEmail: String?
}

/// A retained action is never rebound to another actor, device, household, enrollment or revision.
/// Persist in a dedicated device-only protected vault before transmission. The service independently binds the live provider session.
public struct GuardianEnrollmentIntent: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Codable, Sendable { case create, verification, consent, childInvitation, confirmChild, cancel }
    public let id: String; public let subject: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public let kind: Kind; public let enrollmentID: String?; public let baseRevision: Int?; public let bytes: Data
    private let body: GuardianIntentBody
    public var childAlias: String? { body.childAlias }
    public var childSignInEmail: String? { body.childSignInEmail }
    public var noticeVersion: String? { body.noticeVersion }
    public var noticeDigest: String? { body.noticeDigest }
    public var claimID: String? { body.claimId }
    public var pairingCode: String? { body.pairingCode }
    public var description: String { "GuardianEnrollmentIntent(\(kind.rawValue), <redacted>)" }
    public var debugDescription: String { description }
    var binding: GuardianActorBinding { .init(subject: subject, householdID: householdID, memberID: memberID, deviceID: deviceID) }
    init(binding: GuardianActorBinding, kind: Kind, enrollment: GuardianEnrollment? = nil,
         notice: GuardianNotice? = nil, childLocation: String? = nil, childID: String? = nil,
         childAlias: String? = nil, childSignInEmail: String? = nil, claimID: String? = nil, pairingCode: String? = nil) throws {
        id = UUID().uuidString.lowercased(); subject = binding.subject; householdID = binding.householdID
        memberID = binding.memberID; deviceID = binding.deviceID; self.kind = kind
        enrollmentID = enrollment?.enrollmentId; baseRevision = enrollment?.revision
        var value = GuardianIntentBody(clientKey: id)
        switch kind {
        case .create:
            value.noticeVersion = notice?.version; value.noticeDigest = notice?.digest; value.language = notice?.locale
            value.childLocation = childLocation; value.guardianDeclaration = "parent_or_legal_guardian"; value.childId = childID
        case .verification, .cancel: value.baseRevision = baseRevision
        case .consent:
            value.baseRevision = baseRevision; value.noticeVersion = notice?.version; value.noticeDigest = notice?.digest
            value.childAlias = childAlias; value.childSignInEmail = childSignInEmail; value.decision = "grant"
        case .childInvitation: value.baseRevision = baseRevision; value.secret = try GuardianSecret.generate()
        case .confirmChild: value.baseRevision = baseRevision; value.claimId = claimID; value.pairingCode = pairingCode
        }
        body = value; bytes = try encoded(value); try validate()
    }
    public func validate() throws {
        guard GuardianValidation.ids([id, householdID, memberID]), !subject.isEmpty, !deviceID.isEmpty,
              body.clientKey == id, body.baseRevision == baseRevision,
              kind == .create ? enrollmentID == nil && baseRevision == nil :
                enrollmentID.map({ GuardianValidation.ids([$0]) }) == true && (baseRevision ?? 0) > 0 && (baseRevision ?? Int.max) < Int.max
        else { throw ClientError.configuration }
        var expected = GuardianIntentBody(clientKey: id)
        switch kind {
        case .create:
            guard let version = body.noticeVersion, let digest = body.noticeDigest, let location = body.childLocation,
                  GuardianValidation.text(version, 200), GuardianValidation.text(digest, 256), GuardianValidation.text(location, 200),
                  body.language != nil, body.guardianDeclaration == "parent_or_legal_guardian",
                  body.childId.map({ GuardianValidation.ids([$0]) }) ?? true else { throw ClientError.configuration }
            expected.noticeVersion = version; expected.noticeDigest = digest; expected.language = body.language
            expected.childLocation = location; expected.guardianDeclaration = "parent_or_legal_guardian"; expected.childId = body.childId
        case .verification, .cancel: expected.baseRevision = baseRevision
        case .consent:
            guard let version = body.noticeVersion, let digest = body.noticeDigest, let alias = body.childAlias, let childEmail = body.childSignInEmail,
                  GuardianValidation.text(version, 200), GuardianValidation.text(digest, 256), GuardianValidation.text(alias, 80),
                  GuardianChildSignInEmail.isValid(childEmail), body.decision == "grant" else { throw ClientError.configuration }
            expected.baseRevision = baseRevision; expected.noticeVersion = version; expected.noticeDigest = digest
            expected.childAlias = alias; expected.childSignInEmail = childEmail; expected.decision = "grant"
        case .childInvitation:
            guard let secret = body.secret, GuardianSecret.isCanonical(secret) else { throw ClientError.configuration }
            expected.baseRevision = baseRevision; expected.secret = secret
        case .confirmChild:
            guard let claim = body.claimId, let code = body.pairingCode, GuardianValidation.ids([claim]), GuardianPairingCode.isValid(code) else { throw ClientError.configuration }
            expected.baseRevision = baseRevision; expected.claimId = claim; expected.pairingCode = code
        }
        guard body == expected, bytes == (try encoded(expected)) else { throw ClientError.configuration }
    }
    var path: String {
        guard let enrollmentID else { return "guardian/enrollments" }
        let suffix: String
        switch kind {
        case .create: suffix = ""
        case .verification: suffix = "/verification"
        case .consent: suffix = "/consent"
        case .childInvitation: suffix = "/child-invitations"
        case .confirmChild: suffix = "/confirm-child"
        case .cancel: suffix = "/cancel"
        }
        return "guardian/enrollments/\(enrollmentID)\(suffix)"
    }
    func validate(_ enrollment: GuardianEnrollment) throws {
        try enrollment.validate()
        guard enrollmentID.map({ $0 == enrollment.enrollmentId }) ?? true,
              baseRevision.map({ enrollment.revision >= $0 }) ?? true,
              body.childId.map({ enrollment.childId == $0 }) ?? true,
              body.childAlias.map({ enrollment.childAlias == $0 }) ?? true,
              body.claimId.map({ enrollment.claimId == $0 }) ?? true,
              body.noticeVersion.map({ enrollment.noticeVersion == $0 }) ?? true,
              body.noticeDigest.map({ enrollment.noticeDigest == $0 }) ?? true else { throw ClientError.invalidResponse }
    }
}

/// Supply a dedicated KeychainRefreshTokenVault (WhenUnlockedThisDeviceOnly); this state never enters shared-operation outboxes or backups.
public actor GuardianIntentStore {
    private let vault: any RefreshTokenVault
    private var generation = UUID()
    public init(vault: any RefreshTokenVault) { self.vault = vault }
    public func epoch() -> UUID { generation }
    public func read() throws -> [GuardianEnrollmentIntent] {
        guard let stored = try vault.read() else { return [] }
        let intents = try JSONDecoder().decode([GuardianEnrollmentIntent].self, from: Data(stored.utf8))
        guard Set(intents.map(\.id)).count == intents.count else { throw ClientError.configuration }
        try intents.forEach { try $0.validate() }; return intents
    }
    public func save(_ intent: GuardianEnrollmentIntent, expectedEpoch: UUID) throws {
        guard expectedEpoch == generation else { throw ClientError.cancelled }
        try intent.validate(); var intents = try read()
        if let existing = intents.first(where: { $0.id == intent.id }) {
            guard existing == intent else { throw ClientError.service(status: 409, code: "key_reused", correlationID: nil, retryAfter: nil) }
            return
        }
        guard intents.count < 100, !intents.contains(where: {
            $0.subject == intent.subject && $0.householdID == intent.householdID && $0.memberID == intent.memberID && $0.enrollmentID == intent.enrollmentID
        }) else { throw ClientError.service(status: 409, code: "pending_action_exists", correlationID: nil, retryAfter: nil) }
        intents.append(intent); try write(intents)
    }
    public func complete(id: String, expectedEpoch: UUID) throws {
        guard expectedEpoch == generation else { throw ClientError.cancelled }
        try write(read().filter { $0.id != id })
    }
    public func purge(householdID: String, subject: String) throws {
        generation = UUID(); try write(read().filter { $0.householdID != householdID || $0.subject != subject })
    }
    public func purge() throws { generation = UUID(); try vault.clear() }
    private func write(_ intents: [GuardianEnrollmentIntent]) throws {
        if intents.isEmpty { try vault.clear() }
        else { try vault.write(String(decoding: encoded(intents), as: UTF8.self)) }
    }
}
