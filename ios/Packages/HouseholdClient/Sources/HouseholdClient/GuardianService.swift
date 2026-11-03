import Foundation

extension HouseholdService {
    public func guardianNotice(language: GuardianLanguage) async throws -> GuardianNoticeResponse {
        let value: GuardianNoticeResponse = try await guardianRequest(path: "guardian/notice", query: [.init(name: "language", value: language.rawValue)])
        try value.validate(language: language); return value
    }
    public func guardianEnrollments() async throws -> [GuardianEnrollment] {
        let page: GuardianEnrollments = try await guardianRequest(path: "guardian/enrollments")
        guard Set(page.enrollments.map(\.enrollmentId)).count == page.enrollments.count else { throw ClientError.invalidResponse }
        try page.enrollments.forEach { try $0.validate() }; return page.enrollments
    }
    public func guardianEnrollment(enrollmentID: String) async throws -> GuardianEnrollment {
        guard GuardianValidation.ids([enrollmentID]) else { throw ClientError.configuration }
        let value: GuardianEnrollment = try await guardianRequest(path: "guardian/enrollments/\(enrollmentID)")
        try value.validate(); guard value.enrollmentId == enrollmentID else { throw ClientError.invalidResponse }; return value
    }
    public func prepareGuardianEnrollment(notice: GuardianNotice, childLocation: String, childID: String? = nil,
                                          guardianDeclaration: Bool) async throws -> GuardianEnrollmentIntent {
        guard guardianDeclaration else { throw ClientError.configuration }
        let binding = try guardianContext()
        let current = try await guardianNotice(language: notice.locale)
        guard current.available, current.notice == notice else { throw guardianStaleNotice() }
        guard binding == (try guardianContext()) else { throw ClientError.cancelled }
        return try .init(binding: binding, kind: .create, notice: notice, childLocation: childLocation, childID: childID)
    }
    public func prepareGuardianVerification(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent {
        let binding = try await reviewedGuardian(enrollment)
        guard enrollment.state == .awaitingVerification else { throw ClientError.configuration }
        return try .init(binding: binding, kind: .verification, enrollment: enrollment)
    }
    public func prepareGuardianConsent(enrollment: GuardianEnrollment, notice: GuardianNotice, childAlias: String,
                                       childSignInEmail: String) async throws -> GuardianEnrollmentIntent {
        guard GuardianChildSignInEmail.isValid(childSignInEmail) else { throw ClientError.configuration }
        let binding = try await reviewedGuardian(enrollment)
        guard enrollment.state == .verified, enrollment.noticeVersion == notice.version, enrollment.noticeDigest == notice.digest else { throw ClientError.configuration }
        let current = try await guardianNotice(language: notice.locale)
        guard current.available, current.notice == notice else { throw guardianStaleNotice() }
        guard binding == (try guardianContext()) else { throw ClientError.cancelled }
        return try .init(binding: binding, kind: .consent, enrollment: enrollment, notice: notice, childAlias: childAlias, childSignInEmail: childSignInEmail)
    }
    public func prepareGuardianChildInvitation(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent {
        let binding = try await reviewedGuardian(enrollment)
        guard enrollment.state == .consented else { throw ClientError.configuration }
        return try .init(binding: binding, kind: .childInvitation, enrollment: enrollment)
    }
    public func prepareGuardianChildConfirmation(enrollment: GuardianEnrollment, claimID: String, pairingCode: String) async throws -> GuardianEnrollmentIntent {
        let binding = try await reviewedGuardian(enrollment)
        guard enrollment.state == .childClaimed, enrollment.claimId == claimID else { throw ClientError.configuration }
        return try .init(binding: binding, kind: .confirmChild, enrollment: enrollment, claimID: claimID, pairingCode: pairingCode)
    }
    public func prepareGuardianCancellation(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent {
        let binding = try await reviewedGuardian(enrollment)
        guard !enrollment.state.ended, enrollment.state != .active else { throw ClientError.configuration }
        return try .init(binding: binding, kind: .cancel, enrollment: enrollment)
    }
    /// Recheck local actor/device scope and live authentication before exposing a retained action for explicit review.
    /// Exact provider-session authority remains a mandatory server check; this does not authorize an action by itself.
    public func authorizeGuardianEnrollment(_ intent: GuardianEnrollmentIntent) async throws {
        try intent.validate(); try await guardianAuthorize(binding: intent.binding)
    }
    public func executeGuardianEnrollment(_ intent: GuardianEnrollmentIntent) async throws -> GuardianEnrollment {
        try intent.validate(); guard intent.kind != .childInvitation else { throw ClientError.configuration }
        let value: GuardianEnrollment = try await guardianRequest(binding: intent.binding, path: intent.path, method: "POST", body: intent.bytes)
        try intent.validate(value); return value
    }
    public func executeGuardianChildInvitation(_ intent: GuardianEnrollmentIntent) async throws -> GuardianChildInvitation {
        try intent.validate(); guard intent.kind == .childInvitation else { throw ClientError.configuration }
        let value: GuardianChildInvitation = try await guardianRequest(binding: intent.binding, path: intent.path, method: "POST", body: intent.bytes)
        try value.validate(); return value
    }
    private func reviewedGuardian(_ enrollment: GuardianEnrollment) async throws -> GuardianActorBinding {
        try enrollment.validate(); let binding = try guardianContext()
        let fresh = try await guardianEnrollment(enrollmentID: enrollment.enrollmentId)
        guard binding == (try guardianContext()) else { throw ClientError.cancelled }
        guard fresh == enrollment else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
        return binding
    }
    private func guardianStaleNotice() -> ClientError {
        .service(status: 409, code: "notice_changed", correlationID: nil, retryAfter: nil)
    }
}
