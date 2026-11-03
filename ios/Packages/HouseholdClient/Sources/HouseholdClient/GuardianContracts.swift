import Foundation
import Security

public enum GuardianLanguage: String, Codable, CaseIterable, Sendable { case en, es }
public enum GuardianScope: String, Codable, Sendable { case ownRequests = "own_requests" }
public struct GuardianNotice: Codable, Equatable, Sendable {
    public let version: String; public let digest: String; public let locale: GuardianLanguage; public let text: String
    public let scope: GuardianScope; public let methodVersion: String
    func validate() throws {
        guard GuardianValidation.text(version, 200), GuardianValidation.text(digest, 256),
              GuardianValidation.text(text, 100_000), GuardianValidation.text(methodVersion, 200) else { throw ClientError.invalidResponse }
    }
}
public struct GuardianNoticeResponse: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case providerConfigurationRequired = "provider_configuration_required", noticeApprovalRequired = "notice_approval_required"
    }
    public let available: Bool; public let reason: Reason?; public let notice: GuardianNotice?
    func validate(language: GuardianLanguage) throws {
        guard available ? reason == nil && notice != nil : reason != nil else { throw ClientError.invalidResponse }
        if let notice { try notice.validate(); guard notice.locale == language else { throw ClientError.invalidResponse } }
    }
}
public enum GuardianEnrollmentState: String, Codable, Sendable {
    case awaitingVerification = "awaiting_verification", verificationPending = "verification_pending"
    case verificationUncertain = "verification_uncertain", verified, consented, childClaimed = "child_claimed"
    case childApproved = "child_approved", active, cancelled, expired, withdrawn
    public var ended: Bool { [.cancelled, .expired, .withdrawn].contains(self) }
}
/// Server-owned projection. Neither a redirect nor a local action advances this state.
public struct GuardianEnrollment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { enrollmentId }
    public let enrollmentId: String; public let revision: Int; public let childId: String
    public let state: GuardianEnrollmentState; public let childAlias: String?
    public let noticeVersion: String; public let noticeDigest: String; public let scope: GuardianScope
    public let expiresAt: String; public let verifiedAt: String?; public let consentedAt: String?; public let claimId: String?
    func validate() throws {
        guard GuardianValidation.ids([enrollmentId, childId]), revision > 0, revision < Int.max,
              GuardianValidation.text(noticeVersion, 200), GuardianValidation.text(noticeDigest, 256),
              GuardianValidation.date(expiresAt), childAlias.map({ GuardianValidation.text($0, 80) }) ?? true,
              verifiedAt.map(GuardianValidation.date) ?? true, consentedAt.map(GuardianValidation.date) ?? true,
              claimId.map({ GuardianValidation.ids([$0]) }) ?? true else { throw ClientError.invalidResponse }
        if [.verified, .consented, .childClaimed, .childApproved, .active].contains(state), verifiedAt == nil { throw ClientError.invalidResponse }
        if [.consented, .childClaimed, .childApproved, .active].contains(state), consentedAt == nil || childAlias == nil { throw ClientError.invalidResponse }
        if [.childClaimed, .childApproved, .active].contains(state), claimId == nil { throw ClientError.invalidResponse }
    }
}
public struct GuardianEnrollments: Codable, Equatable, Sendable { public let enrollments: [GuardianEnrollment] }
public struct GuardianChildInvitation: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let inviteId: String; public let token: String; public let expiresAt: String
    public var description: String { "GuardianChildInvitation(<redacted>)" }
    public var debugDescription: String { description }
    func validate() throws {
        guard GuardianValidation.ids([inviteId]), GuardianValidation.token(token), GuardianValidation.date(expiresAt) else { throw ClientError.invalidResponse }
    }
}
public struct ChildInvitationClaimReceipt: Codable, Equatable, Sendable {
    public let householdId: String; public let claimId: String; public let status: String; public let expiresAt: String
    func validate() throws {
        guard GuardianValidation.ids([householdId, claimId]), status == "awaiting_guardian", GuardianValidation.date(expiresAt) else { throw ClientError.invalidResponse }
    }
}
public struct ChildInvitationClaimStatus: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case awaitingGuardian = "awaiting_guardian", approved, active, ended }
    public let claimId: String; public let status: Status; public let expiresAt: String
    func validate(claimID: String) throws {
        guard claimId == claimID, GuardianValidation.date(expiresAt) else { throw ClientError.invalidResponse }
    }
}
public struct ChildEnrollmentReceipt: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let householdId: String; public let memberId: String; public let role: String
    public let deviceId: String; public let deviceToken: String
    public var description: String { "ChildEnrollmentReceipt(<redacted>)" }
    public var debugDescription: String { description }
    func validate(householdID: String) throws {
        guard self.householdId == householdID, GuardianValidation.ids([householdId, memberId, deviceId]),
              role == "contributor", GuardianValidation.token(deviceToken) else { throw ClientError.invalidResponse }
    }
}

/// Cryptographic material is generated once, stored in the protected reviewed intent, and retried unchanged.
public enum GuardianSecret {
    public static func generate() throws -> String { canonical(try randomBytes(count: 32)) }
    public static func isCanonical(_ value: String) -> Bool {
        guard value.utf8.count == 43, value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              data.count == 32 else { return false }
        return canonical(data) == value
    }
    static func canonical(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ClientError.configuration }
        return Data(bytes)
    }
}
public enum GuardianPairingCode {
    public static func generate() throws -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        return String(try GuardianSecret.randomBytes(count: 8).map { alphabet[Int($0 & 31)] })
    }
    public static func isValid(_ value: String) -> Bool {
        value.range(of: "^[A-Z2-7]{8}$", options: .regularExpression) != nil
    }
}
/// Preserve the exact reviewed address. The server validates provider syntax and binds the confirmed address; clients do not normalize it.
public enum GuardianChildSignInEmail {
    public static func isValid(_ value: String) -> Bool {
        guard value.utf8.count <= 254, GuardianValidation.token(value) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }
}
enum GuardianValidation {
    static func ids(_ values: [String]) -> Bool { values.allSatisfy { UUID(uuidString: $0) != nil } }
    static func text(_ value: String, _ maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= maximum
    }
    static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
    }
    static func date(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }
}
