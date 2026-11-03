import Foundation

private func measurementDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

public enum MeasurementNotice {
    public static let currentVersion = "pickup-feedback-2026-11-03.v1"
}
public struct MeasurementConsent: Codable, Equatable, Sendable {
    public let consentId: UUID
    public let noticeVersion: String
    public let grantedAt: String
}
public struct MeasurementStatus: Codable, Equatable, Sendable {
    public let noticeVersion: String
    public let consent: MeasurementConsent?
    func validate() throws {
        guard noticeVersion == MeasurementNotice.currentVersion,
              consent == nil || (consent?.noticeVersion == noticeVersion && measurementDate(consent!.grantedAt) != nil)
        else { throw ClientError.invalidResponse }
    }
}
public struct MeasurementAnswer: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, CaseIterable, Sendable { case acted, unchanged, late, unknown, alreadyKnew = "already_knew", wrong }
    public enum Baseline: String, Codable, CaseIterable, Sendable { case retailer, list, usualRoutine, unknown }
    public enum Comparison: String, Codable, CaseIterable, Sendable { case same, different, unknown }
    public let outcome: Outcome
    public let baseline: Baseline
    public let comparison: Comparison
    public init(outcome: Outcome, baseline: Baseline, comparison: Comparison) {
        self.outcome = outcome; self.baseline = baseline; self.comparison = comparison
    }
    public var incrementalBenefit: Int? {
        comparison == .same || [.unchanged, .late, .alreadyKnew, .wrong].contains(outcome) ? 0 : nil
    }
}
public struct MeasurementFeedback: Codable, Equatable, Sendable {
    public let feedbackId: UUID
    public let shopId: UUID
    public let eligibleWeek: String
    public let consentVersion: String
    public let outcome: MeasurementAnswer.Outcome
    public let baseline: MeasurementAnswer.Baseline
    public let comparison: MeasurementAnswer.Comparison
    public let incrementalBenefit: Int?
    public let recordedAt: String
    public var answer: MeasurementAnswer { .init(outcome: outcome, baseline: baseline, comparison: comparison) }
    func validate(shopID: UUID) throws {
        guard shopId == shopID, consentVersion == MeasurementNotice.currentVersion,
              eligibleWeek.range(of: #"^\d{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$"#, options: .regularExpression) != nil,
              measurementDate(recordedAt) != nil, incrementalBenefit == answer.incrementalBenefit else { throw ClientError.invalidResponse }
    }
}
public struct MeasurementFeedbackPage: Codable, Equatable, Sendable {
    public let shopId: UUID
    public let eligibleWeek: String
    public let feedback: MeasurementFeedback?
}
extension HouseholdService {
    public func measurementStatus() async throws -> MeasurementStatus {
        let value: MeasurementStatus = try await measurementRequest(path: "measurement/status")
        try value.validate(); return value
    }
    /// Called only from an explicit choice after displaying the current notice.
    /// No restore/archive/billing path invokes this method.
    public func grantMeasurementConsent(noticeVersion: String) async throws -> MeasurementStatus {
        guard noticeVersion == MeasurementNotice.currentVersion else { throw ClientError.configuration }
        let value: MeasurementStatus = try await measurementRequest(path: "measurement/consent", method: "POST",
            body: encoded(["noticeVersion": noticeVersion]))
        try value.validate(); guard value.consent != nil else { throw ClientError.invalidResponse }; return value
    }
    public func withdrawMeasurementConsent(_ consent: MeasurementConsent) async throws {
        struct Response: Decodable, Sendable { let withdrawn: Bool }
        let value: Response = try await measurementRequest(path: "measurement/withdraw", method: "POST",
            body: encoded(["consentId": consent.consentId.uuidString.lowercased()]))
        guard value.withdrawn else { throw ClientError.invalidResponse }
    }
    public func measurementFeedback(shopID: UUID) async throws -> MeasurementFeedbackPage {
        let page: MeasurementFeedbackPage = try await measurementRequest(path: "shops/\(shopID.uuidString.lowercased())/measurement-feedback")
        guard page.shopId == shopID, page.eligibleWeek.range(of: #"^\d{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$"#, options: .regularExpression) != nil,
              page.feedback == nil || page.feedback?.eligibleWeek == page.eligibleWeek else { throw ClientError.invalidResponse }
        try page.feedback?.validate(shopID: shopID); return page
    }
    public func sendMeasurementFeedback(shopID: UUID, answer: MeasurementAnswer, consent: MeasurementConsent) async throws -> MeasurementFeedback {
        guard consent.noticeVersion == MeasurementNotice.currentVersion else { throw ClientError.configuration }
        struct Input: Encodable { let consentId: UUID; let noticeVersion: String; let outcome: MeasurementAnswer.Outcome; let baseline: MeasurementAnswer.Baseline; let comparison: MeasurementAnswer.Comparison }
        let input = Input(consentId: consent.consentId, noticeVersion: consent.noticeVersion, outcome: answer.outcome, baseline: answer.baseline, comparison: answer.comparison)
        let result: MeasurementFeedback = try await measurementRequest(path: "shops/\(shopID.uuidString.lowercased())/measurement-feedback", method: "POST", body: encoded(input))
        try result.validate(shopID: shopID); guard result.answer == answer else { throw ClientError.invalidResponse }; return result
    }
    public func removeMeasurementFeedback(shopID: UUID, feedbackID: UUID) async throws {
        struct Response: Decodable, Sendable { let removed: Bool }
        let response: Response = try await measurementRequest(path: "shops/\(shopID.uuidString.lowercased())/measurement-feedback", method: "DELETE",
            body: encoded(["feedbackId": feedbackID.uuidString.lowercased()]))
        guard response.removed else { throw ClientError.invalidResponse }
    }
}
