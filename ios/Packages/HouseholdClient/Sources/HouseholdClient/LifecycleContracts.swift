import Foundation

public struct MembershipReceipt: Codable, Equatable, Sendable {
    public let householdId: String; public let memberId: String; public let role: String; public let grantId: String?
    public private(set) var dinnerInviteId: UUID? = nil
}
public struct InvitationDinnerTarget: Codable, Equatable, Sendable {
    public let shopId: UUID
    public let occurrenceId: UUID
    public init(shopId: UUID, occurrenceId: UUID) { self.shopId = shopId; self.occurrenceId = occurrenceId }
}
public struct InvitedDinner: Decodable, Equatable, Sendable {
    public let inviteId: UUID
    public let shopId: UUID
    public let occurrence: SharedMealOccurrence
    public let expiresAt: String
}
public struct InvitationOffer: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case adultContributor = "adult_contributor"
        case helperRead = "helper_read"
        case helperEdit = "helper_edit"
    }

    public let householdLabel: String
    public let role: Role

    public static func isCompleteToken(_ token: String) -> Bool {
        token.utf8.count == 80 && UUID(uuidString: String(token.prefix(36))) != nil &&
            token.range(of: #"^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    }
}

/// Only the same verified account may retry these fixed bytes. Tokens never enter URLs or logs.
public struct MembershipIntent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case create, redeem }
    public let id: String; public let subject: String; public let kind: Kind; public let bytes: Data
    public let defaultAliasLanguage: String?
    public static func create(subject: String, label: String, alias: String, adultAttestation: Bool) throws -> Self {
        guard adultAttestation, validAlias(label), validAlias(alias) else { throw ClientError.configuration }
        let id = UUID().uuidString.lowercased()
        struct Input: Encodable { let clientKey: String; let label: String; let alias: String; let adultAttestation: Bool }
        return Self(id: id, subject: subject, kind: .create, bytes: try encoded(Input(clientKey: id, label: label, alias: alias, adultAttestation: true)), defaultAliasLanguage: nil)
    }
    public static func redeem(subject: String, token: String, alias: String?, adultAttestation: Bool, defaultAliasLocale: Locale? = nil, reviewedOffer: InvitationOffer? = nil) throws -> Self {
        guard adultAttestation, InvitationOffer.isCompleteToken(token), alias.map(validAlias) ?? true else { throw ClientError.configuration }
        struct Input: Encodable { let token: String; let intent = "join"; let alias: String?; let adultAttestation = true; let reviewedOffer: InvitationOffer? }
        let language = defaultAliasLocale.map { $0.language.languageCode?.identifier == "es" ? "es" : "en" }
        let input = Input(token: token, alias: alias, reviewedOffer: reviewedOffer)
        return Self(id: UUID().uuidString.lowercased(), subject: subject, kind: .redeem, bytes: try encoded(input),
                    defaultAliasLanguage: alias == nil ? language : nil)
    }
    private struct Redemption: Decodable {
        let token: String
        let alias: String?
        let reviewedOffer: InvitationOffer?
    }
    private var redemption: Redemption? {
        guard kind == .redeem, let draft = try? JSONDecoder().decode(Redemption.self, from: bytes),
              InvitationOffer.isCompleteToken(draft.token) else { return nil }
        return draft
    }
    public var invitationDraft: (token: String, alias: String?)? {
        redemption.map { ($0.token, $0.alias) }
    }
    func validateRedemptionReceipt(_ receipt: MembershipReceipt) throws {
        guard let draft = redemption,
              let household = UUID(uuidString: receipt.householdId),
              household == UUID(uuidString: String(draft.token.prefix(36))) else { throw ClientError.invalidResponse }
        let offeredRole: InvitationOffer.Role
        switch (receipt.role, receipt.grantId) {
        case ("contributor", nil): offeredRole = .adultContributor
        case let ("helper", grant?) where UUID(uuidString: grant) != nil: offeredRole = .helperRead
        case let ("editor", grant?) where UUID(uuidString: grant) != nil: offeredRole = .helperEdit
        default: throw ClientError.invalidResponse
        }
        if receipt.dinnerInviteId != nil && offeredRole != .adultContributor { throw ClientError.invalidResponse }
        if let reviewed = draft.reviewedOffer, reviewed.role != offeredRole { throw ClientError.invalidResponse }
    }
    private static func validAlias(_ value: String) -> Bool { !value.isEmpty && value.count <= 80 }
}
public struct HouseholdMember: Codable, Equatable, Identifiable, Sendable {
    public var id: String { memberId }
    public let memberId: String; public let alias: String; public let kind: String; public let state: String; public let role: String
}
public struct HouseholdMembers: Codable, Equatable, Sendable { public let members: [HouseholdMember] }
public struct ManagedInvitation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { inviteId }
    public let inviteId: String; public let kind: String; public let grantId: String?; public let expiresAt: String
    public let redeemedAt: String?; public let revokedAt: String?; public let status: String
}
public struct ManagedInvitations: Codable, Equatable, Sendable { public let invites: [ManagedInvitation] }
public struct ManagedHelperView: Codable, Equatable, Identifiable, Sendable {
    public var id: String { grantId }
    public let grantId: String; public let shopId: String; public let mode: String; public let revision: Int; public let shopLabel: String
    public let expiresAt: String; public let revokedAt: String?; public let recipientAlias: String?; public let status: String
}
public struct ManagedHelperViews: Codable, Equatable, Sendable { public let views: [ManagedHelperView] }
public struct IssuedInvitation: Codable, Equatable, Sendable {
    public let inviteId: String; public let token: String; public let expiresAt: String; public let grantId: String?
}
public enum RevocationKind: String, Codable, Sendable { case member, invite, view }
public struct RevocationReceipt: Codable, Equatable, Sendable {
    public let revoked: Bool; public let kind: RevocationKind; public let targetId: String
}
public struct HelperInstruction: Codable, Equatable, Sendable {
    public let label: String; public let amount: String?; public let unit: String?; public let action: String
    public init(label: String, amount: String?, unit: String?, action: String) {
        self.label = label; self.amount = amount; self.unit = unit; self.action = action
    }
    private enum CodingKeys: String, CodingKey { case label, amount, unit, action }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(label, forKey: .label); try values.encode(action, forKey: .action)
        try values.encode(amount, forKey: .amount); try values.encode(unit, forKey: .unit)
    }
}
/// Explicitly reviewed fields only; this type cannot encode budgets, rosters or billing data.
public struct HelperProjection: Codable, Equatable, Sendable {
    public let shopLabel: String; public let language: String; public let items: [HelperInstruction]
    public init(shopLabel: String, language: String, items: [HelperInstruction]) throws {
        guard !shopLabel.isEmpty, shopLabel.count <= 80, ["en", "es"].contains(language), items.count <= 200,
              items.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 240 && !$0.action.isEmpty && $0.action.count <= 500 &&
                  ($0.amount.map { !$0.isEmpty && $0.count <= 80 } ?? true) && ($0.unit.map { !$0.isEmpty && $0.count <= 80 } ?? true) }) else { throw ClientError.configuration }
        self.shopLabel = shopLabel; self.language = language; self.items = items
    }
}
public struct HelperView: Codable, Equatable, Sendable {
    public private(set) var canReportContent: Bool? = nil
    public let grantId: String; public let shopId: String; public let revision: Int; public let asOf: String; public let expiresAt: String
    public let mode: String; public let canPropose: Bool; public let shopLabel: String; public let language: String; public let items: [HelperInstruction]
}
public struct HelperProposalReceipt: Codable, Equatable, Sendable {
    public let proposalId: String; public let grantId: String; public let baseRevision: Int; public let status: String
}
public struct HelperProposal: Codable, Equatable, Identifiable, Sendable {
    public let canReportContent: Bool?
    public var id: String { proposalId }
    public let proposalId: String; public let grantId: String; public let baseRevision: Int; public let correction: String
    public let status: String; public let createdAt: String
    public let proposalRevision: Int
    public let resolution: HelperProposalResolution?
    private enum CodingKeys: String, CodingKey { case proposalId, grantId, baseRevision, correction, status, createdAt, proposalRevision, resolution, canReportContent }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canReportContent = try values.decodeIfPresent(Bool.self, forKey: .canReportContent)
        proposalId = try values.decode(String.self, forKey: .proposalId); grantId = try values.decode(String.self, forKey: .grantId)
        baseRevision = try values.decode(Int.self, forKey: .baseRevision); correction = try values.decode(String.self, forKey: .correction)
        status = try values.decode(String.self, forKey: .status); createdAt = try values.decode(String.self, forKey: .createdAt)
        // Legacy list rows remain readable, but cannot be used to prepare a reviewed mutation.
        proposalRevision = try values.decodeIfPresent(Int.self, forKey: .proposalRevision) ?? 0
        resolution = try values.decodeIfPresent(HelperProposalResolution.self, forKey: .resolution)
    }
}
public struct HelperProposals: Codable, Equatable, Sendable {
    public let proposals: [HelperProposal]
    public let nextCursor: String?
}
public struct HelperProposalIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public let grantID: String; public let bytes: Data
    private struct Input: Codable {
        let clientKey: String
        let baseRevision: Int
        let correction: String
    }
    /// Recover the exact submitted wording and revision from a durable retry.
    private var reviewedInput: Input? {
        guard let input = try? JSONDecoder().decode(Input.self, from: bytes),
              input.clientKey == id, input.baseRevision > 0 else { return nil }
        return input
    }
    public var reviewedCorrection: String? { reviewedInput?.correction }
    public var reviewedRevision: Int? { reviewedInput?.baseRevision }
    init(householdID: String, memberID: String, deviceID: String, grantID: String, baseRevision: Int, correction: String) throws {
        guard baseRevision > 0, !correction.isEmpty, correction.utf16.count <= 1000 else { throw ClientError.configuration }
        id = UUID().uuidString.lowercased(); self.householdID = householdID; self.memberID = memberID; self.deviceID = deviceID; self.grantID = grantID
        bytes = try encoded(Input(clientKey: id, baseRevision: baseRevision, correction: correction))
    }
}
public struct GuardianConsent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { consentId }
    public let consentId: String; public let childId: String; public let childAlias: String; public let noticeVersion: String
    public let grantedAt: String; public let revokedAt: String?
}
public struct GuardianConsents: Codable, Equatable, Sendable { public let enrollmentEnabled: Bool; public let consents: [GuardianConsent] }
public struct ConsentWithdrawalReceipt: Codable, Equatable, Sendable { public let consentId: String; public let revoked: Bool }

public struct LifecyclePendingState: Codable, Equatable, Sendable {
    public struct Activation: Codable, Equatable, Sendable {
        public let subject: String; public let receipt: MembershipReceipt
        public init(subject: String, receipt: MembershipReceipt) { self.subject = subject; self.receipt = receipt }
    }
    public var membership: MembershipIntent?
    public var activation: Activation?
    public fileprivate(set) var dinnerInvitation: Activation? = nil
    public var proposals: [HelperProposalIntent]
    public var reviewActions: [HelperReviewIntent]?
    public init(membership: MembershipIntent? = nil, activation: Activation? = nil, proposals: [HelperProposalIntent] = [], reviewActions: [HelperReviewIntent]? = nil) {
        self.membership = membership; self.activation = activation; self.proposals = proposals; self.reviewActions = reviewActions
    }
}
public actor LifecycleIntentStore {
    private let url: URL
    private var reviewGeneration = UUID()
    public init(url: URL) { self.url = url }
    public func read() throws -> LifecyclePendingState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(LifecyclePendingState.self, from: Data(contentsOf: url))
    }
    public func completeActivation(_ activation: LifecyclePendingState.Activation) throws {
        var state = try read()
        guard state.activation == activation else { throw ClientError.cancelled }
        state.activation = nil
        state.dinnerInvitation = activation.receipt.dinnerInviteId == nil ? nil : activation
        try write(state)
    }
    /// Legacy lifecycle updates cannot replace review actions from an older snapshot.
    /// Review actions are changed only through the atomic, epoch-checked operations below.
    public func save(_ state: LifecyclePendingState) throws {
        var merged = state
        let live = try read()
        merged.reviewActions = live.reviewActions
        merged.dinnerInvitation = live.dinnerInvitation
        try write(merged)
    }
    public func discardRejectedInvitation(_ intent: MembershipIntent) throws {
        var state = try read()
        guard state.membership == intent, intent.kind == .redeem else { throw ClientError.cancelled }
        state.membership = nil
        try write(state)
    }
    private func write(_ state: LifecyclePendingState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try encoded(state).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encoded(state).write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true; try protected.setResourceValues(values)
    }
    public func reviewEpoch() -> UUID { reviewGeneration }
    public func saveReviewAction(_ intent: HelperReviewIntent, expectedEpoch: UUID) throws {
        guard expectedEpoch == reviewGeneration else { throw ClientError.cancelled }
        try intent.validate()
        var state = try read()
        var actions = state.reviewActions ?? []
        if let existing = actions.first(where: { $0.id == intent.id }) {
            guard existing == intent else { throw ClientError.service(status: 409, code: "key_reused", correlationID: nil, retryAfter: nil) }
            return
        }
        guard !actions.contains(where: {
            $0.subject == intent.subject && $0.householdID == intent.householdID &&
            $0.memberID == intent.memberID && $0.grantID == intent.grantID
        }) else { throw ClientError.service(status: 409, code: "helper_review_pending", correlationID: nil, retryAfter: nil) }
        actions.append(intent); state.reviewActions = actions; try write(state)
    }
    public func removeReviewAction(id: String) throws {
        var state = try read()
        state.reviewActions = state.reviewActions?.filter { $0.id != id }
        try write(state)
    }
    public func purge(householdID: String, memberID: String, subject: String) throws {
        reviewGeneration = UUID()
        var state = try read()
        if state.activation?.subject == subject, state.activation?.receipt.householdId == householdID { state.activation = nil }
        if state.dinnerInvitation?.subject == subject, state.dinnerInvitation?.receipt.householdId == householdID,
           state.dinnerInvitation?.receipt.memberId == memberID { state.dinnerInvitation = nil }
        state.proposals.removeAll { $0.householdID == householdID && $0.memberID == memberID }
        state.reviewActions?.removeAll { $0.householdID == householdID && $0.memberID == memberID && $0.subject == subject }
        try write(state)
    }
    public func purge() throws { reviewGeneration = UUID(); try write(.init()) }
}
