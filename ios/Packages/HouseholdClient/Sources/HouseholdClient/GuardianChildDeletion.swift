import Foundation

public struct GuardianDeletionChild: Codable, Equatable, Identifiable, Sendable {
    public let enrollmentId: UUID
    public let childAlias: String
    public var id: UUID { enrollmentId }
}

public struct GuardianDeletionReview: Codable, Equatable, Sendable {
    public let enrollmentId: UUID
    public let childAlias: String
    public let reviewId: UUID
    public let expiresAt: String
    public let verifiedBackupRetentionDays: Int
    public var expiry: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

/// Separate from adult self-deletion receipts. Its capability can check only this job.
public struct GuardianDeletionRequest: Codable, Identifiable, Sendable {
    public let receipt: DeletionReceipt
    public let householdID: String
    public let memberID: String
    public let review: GuardianDeletionReview
    public var id: UUID { receipt.id }
}

@MainActor public struct GuardianDeletionReceipts {
    private let vault: any RefreshTokenVault
    public init(vault: any RefreshTokenVault) { self.vault = vault }

    private func all() throws -> [GuardianDeletionRequest] {
        guard let stored = try vault.read() else { return [] }
        return try JSONDecoder().decode([GuardianDeletionRequest].self, from: Data(stored.utf8))
    }

    public func saved(subject: String, householdID: String, memberID: String) throws -> [GuardianDeletionRequest] {
        try all().filter { $0.receipt.subject == subject && $0.householdID == householdID && $0.memberID == memberID }
    }

    /// Persist before sending. A fresh review for the same child keeps the same job ID and status capability.
    public func prepare(subject: String, householdID: String, memberID: String,
                        review: GuardianDeletionReview) throws -> GuardianDeletionRequest {
        guard let expiry = review.expiry, expiry > Date() else { throw ClientError.service(status: 409, code: "review_expired", correlationID: nil, retryAfter: nil) }
        var rows = try all()
        let existing = rows.first { $0.receipt.subject == subject && $0.householdID == householdID &&
            $0.memberID == memberID && $0.review.enrollmentId == review.enrollmentId }
        let receipt: DeletionReceipt
        if let existing { receipt = existing.receipt }
        else { receipt = try DeletionReceipt(id: UUID(), subject: subject, created: Date(), statusToken: GuardianSecret.generate()) }
        let request = GuardianDeletionRequest(receipt: receipt, householdID: householdID, memberID: memberID, review: review)
        rows.removeAll { $0.id == receipt.id }
        rows.append(request)
        try vault.write(String(decoding: encoded(rows), as: UTF8.self))
        return request
    }

    public func remove(_ request: GuardianDeletionRequest) throws {
        let rows = try all().filter { $0.id != request.id }
        if rows.isEmpty { try vault.clear() }
        else { try vault.write(String(decoding: encoded(rows), as: UTF8.self)) }
    }
}

extension HouseholdService {
    private func deletionGuardian(subject: String, householdID: String, memberID: String) throws -> GuardianActorBinding {
        let binding = try guardianContext()
        guard binding.subject == subject, binding.householdID == householdID, binding.memberID == memberID else { throw ClientError.accessEnded }
        return binding
    }

    public func guardianDeletionChildren(subject: String, householdID: String, memberID: String) async throws -> [GuardianDeletionChild] {
        struct List: Decodable, Sendable { let children: [GuardianDeletionChild] }
        let binding = try deletionGuardian(subject: subject, householdID: householdID, memberID: memberID)
        let list: List = try await guardianRequest(binding: binding, path: "guardian/child-account-deletions")
        guard Set(list.children.map(\.id)).count == list.children.count,
              list.children.allSatisfy({ GuardianValidation.text($0.childAlias, 80) }) else { throw ClientError.invalidResponse }
        return list.children
    }

    public func guardianDeletionReview(subject: String, householdID: String, memberID: String,
                                       child: GuardianDeletionChild, childSignInEmail: String) async throws -> GuardianDeletionReview {
        struct Input: Encodable { let enrollmentId, childSignInEmail: String }
        guard GuardianChildSignInEmail.isValid(childSignInEmail) else { throw ClientError.configuration }
        let binding = try deletionGuardian(subject: subject, householdID: householdID, memberID: memberID)
        let review: GuardianDeletionReview = try await guardianRequest(binding: binding, path: "guardian/child-account-deletions/review",
            method: "POST", body: encoded(Input(enrollmentId: child.id.uuidString.lowercased(), childSignInEmail: childSignInEmail)))
        guard review.enrollmentId == child.id, review.childAlias == child.childAlias,
              review.expiry != nil, review.verifiedBackupRetentionDays >= 0 else { throw ClientError.invalidResponse }
        return review
    }

    public func deleteGuardianChildAccount(_ request: GuardianDeletionRequest) async throws -> DeletionStatus {
        struct Input: Encodable { let enrollmentId, reviewId, clientKey, statusToken: String; let confirm: Bool }
        let receipt = request.receipt
        let binding = try deletionGuardian(subject: receipt.subject, householdID: request.householdID, memberID: request.memberID)
        let body = Input(enrollmentId: request.review.enrollmentId.uuidString.lowercased(),
                         reviewId: request.review.reviewId.uuidString.lowercased(), clientKey: receipt.id.uuidString.lowercased(),
                         statusToken: receipt.statusToken, confirm: true)
        let status: DeletionStatus = try await guardianRequest(binding: binding, path: "guardian/child-account-deletions", method: "POST", body: encoded(body))
        return try status.checked(for: receipt)
    }
}

public struct GuardianManualReviewCase: Decodable, Identifiable, Sendable {
    public enum Status: String, Decodable, Sendable { case received, inReview = "in_review", verificationNeeded = "verification_needed", closed }
    public let requestId: UUID
    public let status: Status
    public let createdAt, updatedAt, expiresAt: String
    public var id: UUID { requestId }

    func validate() throws {
        guard [createdAt, updatedAt, expiresAt].allSatisfy(GuardianValidation.date) else { throw ClientError.invalidResponse }
    }
}

public struct GuardianManualReviewChild: Decodable, Equatable, Identifiable, Sendable {
    public enum IdentityState: String, Decodable, Sendable { case confirmed, unmatched }
    public let enrollmentId: UUID
    public let childAlias: String
    public let identityState: IdentityState
    public var id: UUID { enrollmentId }
}

public struct GuardianManualReviewPage: Decodable, Sendable {
    public let available: Bool
    public let children: [GuardianManualReviewChild]
    public let requests: [GuardianManualReviewCase]
}

public struct GuardianManualReviewKey: Codable, Sendable {
    public let id: UUID
    public let enrollmentID: UUID
    let subject, householdID, memberID: String
}

@MainActor public struct GuardianManualReviewKeys {
    private let vault: any RefreshTokenVault
    public init(vault: any RefreshTokenVault) { self.vault = vault }

    private func saved() throws -> [GuardianManualReviewKey] {
        guard let value = try vault.read() else { return [] }
        return try JSONDecoder().decode([GuardianManualReviewKey].self, from: Data(value.utf8))
    }

    public func prepare(subject: String, householdID: String, memberID: String, enrollmentID: UUID) throws -> GuardianManualReviewKey {
        var keys = try saved()
        if let key = keys.first(where: { $0.subject == subject && $0.householdID == householdID && $0.memberID == memberID && $0.enrollmentID == enrollmentID }) { return key }
        let key = GuardianManualReviewKey(id: UUID(), enrollmentID: enrollmentID, subject: subject, householdID: householdID, memberID: memberID)
        keys.append(key)
        try vault.write(String(decoding: encoded(keys), as: UTF8.self))
        return key
    }

    public func received(_ ids: Set<UUID>, subject: String, householdID: String, memberID: String) throws {
        guard !ids.isEmpty else { return }
        let keys = try saved()
        let remaining = keys.filter { !($0.subject == subject && $0.householdID == householdID && $0.memberID == memberID && ids.contains($0.id)) }
        guard remaining.count != keys.count else { return }
        if remaining.isEmpty { try vault.clear() }
        else { try vault.write(String(decoding: encoded(remaining), as: UTF8.self)) }
    }
}

extension HouseholdService {
    public func guardianManualReviews(subject: String, householdID: String, memberID: String) async throws -> GuardianManualReviewPage {
        let binding = try deletionGuardian(subject: subject, householdID: householdID, memberID: memberID)
        let page: GuardianManualReviewPage = try await guardianRequest(binding: binding, path: "guardian/child-account-deletions/manual-reviews")
        guard Set(page.children.map(\.id)).count == page.children.count, Set(page.requests.map(\.id)).count == page.requests.count,
              page.children.allSatisfy({ GuardianValidation.text($0.childAlias, 80) }) else { throw ClientError.invalidResponse }
        try page.requests.forEach { try $0.validate() }
        return page
    }

    public func requestGuardianManualReview(_ key: GuardianManualReviewKey, childSignInEmail: String) async throws -> GuardianManualReviewCase {
        struct Input: Encodable { let clientKey, enrollmentId, childSignInEmail: String; let confirm: Bool }
        guard GuardianChildSignInEmail.isValid(childSignInEmail) else { throw ClientError.configuration }
        let binding = try deletionGuardian(subject: key.subject, householdID: key.householdID, memberID: key.memberID)
        let body = Input(clientKey: key.id.uuidString.lowercased(), enrollmentId: key.enrollmentID.uuidString.lowercased(),
                         childSignInEmail: childSignInEmail, confirm: true)
        let result: GuardianManualReviewCase = try await guardianRequest(binding: binding,
            path: "guardian/child-account-deletions/manual-reviews", method: "POST", body: encoded(body))
        guard result.id == key.id else { throw ClientError.invalidResponse }
        try result.validate()
        return result
    }
}
