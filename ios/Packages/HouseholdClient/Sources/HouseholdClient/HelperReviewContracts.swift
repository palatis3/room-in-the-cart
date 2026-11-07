import Foundation

public enum HelperReviewDecision: String, Codable, Sendable { case replace, dismiss }

public struct ManagedHelperProjection: Codable, Equatable, Sendable {
    public let grantId: String; public let shopId: String; public let revision: Int
    public let asOf: String; public let expiresAt: String; public let mode: String
    public let projection: HelperProjection
}
public struct HelperProposalResolution: Codable, Equatable, Sendable {
    public let mutationId: String; public let decision: String; public let revision: Int; public let resolvedAt: String
}

/// The complete reviewed action, including its original bytes. Persist before sending, and retry unchanged.
public struct HelperReviewIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: String; public let subject: String; public let householdID: String; public let memberID: String
    public let deviceID: String; public let grantID: String; public let shopID: String; public let proposalID: String?
    public let baseRevision: Int; public let proposalRevision: Int?; public let decision: HelperReviewDecision
    public let projection: HelperProjection?; public let bytes: Data

    init(subject: String, householdID: String, memberID: String, deviceID: String,
         current: ManagedHelperProjection, proposal: HelperProposal?, decision: HelperReviewDecision,
         projection: HelperProjection?) throws {
        id = UUID().uuidString.lowercased(); self.subject = subject; self.householdID = householdID
        self.memberID = memberID; self.deviceID = deviceID; grantID = current.grantId; shopID = current.shopId
        proposalID = proposal?.proposalId; baseRevision = current.revision; proposalRevision = proposal?.proposalRevision
        self.decision = decision; self.projection = projection
        bytes = try Self.payload(id: id, baseRevision: baseRevision, proposalID: proposalID,
                                 proposalRevision: proposalRevision, decision: decision, projection: projection)
        try validate()
    }
    private static func payload(id: String, baseRevision: Int, proposalID: String?, proposalRevision: Int?,
                                decision: HelperReviewDecision, projection: HelperProjection?) throws -> Data {
        struct Input: Encodable {
            let clientKey: String; let baseRevision: Int; let proposalRevision: Int?
            let decision: HelperReviewDecision?; let projection: HelperProjection?
        }
        return try encoded(Input(clientKey: id, baseRevision: baseRevision, proposalRevision: proposalRevision,
                                 decision: proposalID == nil ? nil : decision, projection: projection))
    }
    func validate() throws {
        guard [id, householdID, memberID, grantID, shopID].allSatisfy({ UUID(uuidString: $0) != nil }),
              !subject.isEmpty, !deviceID.isEmpty, baseRevision > 0, baseRevision < Int.max,
              proposalID.map({ UUID(uuidString: $0) != nil }) ?? true,
              (proposalID == nil ? proposalRevision == nil && decision == .replace : (proposalRevision ?? 0) > 0 && (proposalRevision ?? Int.max) < Int.max),
              (decision == .replace ? projection != nil : projection == nil) else { throw ClientError.configuration }
        if let projection { try projection.validateReviewed() }
        guard bytes == (try Self.payload(id: id, baseRevision: baseRevision, proposalID: proposalID,
                                         proposalRevision: proposalRevision, decision: decision, projection: projection)) else { throw ClientError.configuration }
    }
}

public struct HelperReviewReceipt: Codable, Equatable, Sendable {
    public let mutationId: String; public let grantId: String; public let baseRevision: Int; public let revision: Int
    public let status: String; public let asOf: String?; public let proposalId: String?; public let proposalRevision: Int?
    public let resolution: String?; public let resolvedAt: String?
    func validate(for intent: HelperReviewIntent) throws {
        guard UUID(uuidString: mutationId) != nil, grantId == intent.grantID, baseRevision == intent.baseRevision,
              revision == intent.baseRevision + (intent.decision == .replace ? 1 : 0) else { throw ClientError.invalidResponse }
        if let proposalID = intent.proposalID {
            guard proposalId == proposalID, proposalRevision == intent.proposalRevision.map({ $0 + 1 }),
                  status == (intent.decision == .replace ? "reviewed" : "dismissed"),
                  resolution == (intent.decision == .replace ? "replaced" : "dismissed"),
                  validHelperTimestamp(resolvedAt), asOf == nil else { throw ClientError.invalidResponse }
        } else {
            guard status == "replaced", validHelperTimestamp(asOf), proposalId == nil, proposalRevision == nil,
                  resolution == nil, resolvedAt == nil else { throw ClientError.invalidResponse }
        }
    }
}

extension HelperProjection {
    func validateReviewed() throws {
        func text(_ value: String, _ maximum: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= maximum
        }
        guard text(shopLabel, 80), ["en", "es"].contains(language), items.count <= 200,
              items.allSatisfy({ text($0.label, 240) && text($0.action, 500) &&
                  ($0.amount.map { text($0, 80) } ?? true) && ($0.unit.map { text($0, 80) } ?? true) }) else { throw ClientError.configuration }
    }
}
func validHelperTimestamp(_ value: String?) -> Bool { householdTimestamp(value) != nil }

func householdTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let result = formatter.date(from: value) { return result }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}
