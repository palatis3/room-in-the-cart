import XCTest
import HouseholdClient
@testable import RoomInTheCart

private final class GuardianModelVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var rejectWrites = false
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectWrites { throw ClientError.configuration }; value = token
    }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private enum GuardianFixtureData {
    static let enrollmentID = "10000000-0000-4000-8000-000000000001"
    static let childID = "10000000-0000-4000-8000-000000000002"
    static let claimID = "10000000-0000-4000-8000-000000000003"
    static let householdID = "10000000-0000-4000-8000-000000000004"
    static let memberID = "10000000-0000-4000-8000-000000000005"
    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    static func notice(available: Bool = true, digest: String = "reviewed-digest") throws -> GuardianNoticeResponse {
        try decode(available ? ["available":true, "reason":NSNull(), "notice":["version":"notice-1", "digest":digest, "locale":"en", "text":"Fixture current guardian notice", "scope":"own_requests", "methodVersion":"fixture-only-method"]] :
            ["available":false,"reason":"provider_configuration_required","notice":NSNull()])
    }
    static func enrollment(_ state: String, revision: Int = 1) throws -> GuardianEnrollment {
        let verified = ["verified", "consented", "child_claimed", "child_approved", "active"].contains(state)
        let consented = ["consented", "child_claimed", "child_approved", "active"].contains(state)
        return try decode(["enrollmentId":enrollmentID, "revision":revision, "childId":childID, "state":state,
            "childAlias":consented ? "Sam" as Any : NSNull(), "noticeVersion":"notice-1", "noticeDigest":"reviewed-digest", "scope":"own_requests",
            "expiresAt":"2099-01-01T00:00:00Z", "verifiedAt":verified ? "2026-11-03T12:00:00Z" as Any : NSNull(),
            "consentedAt":consented ? "2026-11-03T12:01:00Z" as Any : NSNull(), "claimId":["child_claimed", "child_approved", "active"].contains(state) ? claimID as Any : NSNull()])
    }
    static func intent(_ kind: GuardianEnrollmentIntent.Kind, scope: GuardianRuntimeScope, enrollment: GuardianEnrollment? = nil,
                       notice: GuardianNotice? = nil, alias: String? = nil, pairingCode: String? = nil) throws -> GuardianEnrollmentIntent {
        let id = UUID().uuidString.lowercased()
        var body: [String: Any] = ["clientKey":id]
        if let enrollment { body["baseRevision"] = enrollment.revision }
        if let notice { body["noticeVersion"] = notice.version; body["noticeDigest"] = notice.digest }
        switch kind {
        case .create: body["language"] = "en"; body["childLocation"] = "US"; body["guardianDeclaration"] = "parent_or_legal_guardian"
        case .consent: body["childAlias"] = alias; body["decision"] = "grant"; body["childSignInEmail"] = "fictional-child@example.invalid"
        case .childInvitation: body["secret"] = try GuardianSecret.generate()
        case .confirmChild: body["claimId"] = claimID; body["pairingCode"] = pairingCode
        default: break
        }
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var raw: [String:Any] = ["id":id,"subject":scope.subject,"householdID":scope.householdID,"memberID":scope.memberID,
            "deviceID":"fixture-device", "kind":kind.rawValue, "body":body,"bytes":bytes.base64EncodedString()]
        if let enrollment { raw["enrollmentID"] = enrollment.enrollmentId; raw["baseRevision"] = enrollment.revision }
        let value: GuardianEnrollmentIntent = try decode(raw); try value.validate(); return value
    }
}
private actor GuardianNativeFixture: GuardianEnrollmentServing {
    let scope: GuardianRuntimeScope
    var noticeValue: GuardianNoticeResponse
    var rows: [GuardianEnrollment]
    var lostResponse = false
    var denied = false
    var sent: [GuardianEnrollmentIntent] = []
    var verificationPrepared = 0
    var onRead: (@Sendable () async -> Void)?
    init(scope: GuardianRuntimeScope, state: String = "awaiting_verification", available: Bool = true) throws {
        self.scope = scope; noticeValue = try GuardianFixtureData.notice(available: available)
        rows = [try GuardianFixtureData.enrollment(state)]
    }
    func setLost(_ value: Bool) { lostResponse = value }
    func setDenied(_ value: Bool) { denied = value }
    func setRead(_ value: (@Sendable () async -> Void)?) { onRead = value }
    func replace(_ state: String) throws { rows = [try GuardianFixtureData.enrollment(state)] }
    func sends() -> [GuardianEnrollmentIntent] { sent }
    func verificationCount() -> Int { verificationPrepared }
    func guardianNotice(language: GuardianLanguage) async throws -> GuardianNoticeResponse { noticeValue }
    func guardianEnrollments() async throws -> [GuardianEnrollment] {
        if let onRead { await onRead() }; if denied { throw ClientError.accessEnded }; return rows
    }
    func guardianEnrollment(enrollmentID: String) async throws -> GuardianEnrollment { rows[0] }
    func prepareGuardianEnrollment(notice: GuardianNotice, childLocation: String, childID: String?, guardianDeclaration: Bool) async throws -> GuardianEnrollmentIntent {
        guard guardianDeclaration else { throw ClientError.configuration }
        return try GuardianFixtureData.intent(.create, scope: scope, notice: notice)
    }
    func prepareGuardianVerification(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent {
        verificationPrepared += 1; return try GuardianFixtureData.intent(.verification, scope: scope, enrollment: enrollment)
    }
    func prepareGuardianConsent(enrollment: GuardianEnrollment, notice: GuardianNotice, childAlias: String, childSignInEmail: String) async throws -> GuardianEnrollmentIntent {
        try GuardianFixtureData.intent(.consent, scope: scope, enrollment: enrollment, notice: notice, alias: childAlias)
    }
    func prepareGuardianChildInvitation(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent {
        try GuardianFixtureData.intent(.childInvitation, scope: scope, enrollment: enrollment)
    }
    func prepareGuardianChildConfirmation(enrollment: GuardianEnrollment, claimID: String, pairingCode: String) async throws -> GuardianEnrollmentIntent {
        try GuardianFixtureData.intent(.confirmChild, scope: scope, enrollment: enrollment, pairingCode: pairingCode)
    }
    func prepareGuardianCancellation(enrollment: GuardianEnrollment) async throws -> GuardianEnrollmentIntent {
        try GuardianFixtureData.intent(.cancel, scope: scope, enrollment: enrollment)
    }
    func authorizeGuardianEnrollment(_ intent: GuardianEnrollmentIntent) async throws { if denied { throw ClientError.accessEnded } }
    func executeGuardianEnrollment(_ intent: GuardianEnrollmentIntent) async throws -> GuardianEnrollment {
        sent.append(intent)
        if lostResponse { throw ClientError.transport }
        let state: String
        switch intent.kind {
        case .verification: state = "verification_pending"
        case .consent: state = "consented"
        case .confirmChild: state = "child_approved"
        case .cancel: state = "cancelled"
        default: state = "awaiting_verification"
        }
        let value = try GuardianFixtureData.enrollment(state, revision: 2); rows = [value]; return value
    }
    func executeGuardianChildInvitation(_ intent: GuardianEnrollmentIntent) async throws -> GuardianChildInvitation {
        sent.append(intent); if lostResponse { throw ClientError.transport }
        return try GuardianFixtureData.decode(["inviteId":UUID().uuidString,"token":"fixture-opaque-invitation","expiresAt":"2099-01-01T00:00:00Z"])
    }
}

@MainActor final class GuardianEnrollmentTests: XCTestCase {
    private func scope() -> GuardianRuntimeScope {
        .init(subject:"fixture-guardian",householdID:GuardianFixtureData.householdID,memberID:GuardianFixtureData.memberID,
              generation:UUID(),enrollmentRevision:UUID())
    }
    func testUnavailableNoticePreventsSetupAndVerificationIsNotPermission() async throws {
        let scope = scope(), store = GuardianIntentStore(vault: GuardianModelVault()), unavailable = try GuardianNativeFixture(scope: scope, available: false)
        let blocked = GuardianEnrollmentModel(scope:scope,service:unavailable,store:store,runtime:{ scope })
        await blocked.load(); blocked.noticeReviewed = true; blocked.guardianDeclaration = true; blocked.childLocation = "US"
        XCTAssertFalse(blocked.canStart); await blocked.start(); let sends = await unavailable.sends(); XCTAssertTrue(sends.isEmpty)
        let service = try GuardianNativeFixture(scope:scope), model = GuardianEnrollmentModel(scope:scope,service:service,store:store,runtime:{ scope })
        await model.load(); model.select(try GuardianFixtureData.enrollment("awaiting_verification")); await model.requestVerification()
        XCTAssertEqual(model.selected?.state, .verificationPending); XCTAssertFalse(model.canGrant)
        let actions = await service.sends(); XCTAssertEqual(actions.map(\.kind), [.verification])
    }
    func testUncertainVerificationCannotPrepareANewEmailAction() async throws {
        let scope = scope(), service = try GuardianNativeFixture(scope:scope,state:"verification_uncertain")
        let model = GuardianEnrollmentModel(scope:scope,service:service,store:.init(vault:GuardianModelVault()),runtime:{ scope })
        await model.load(); model.select(try GuardianFixtureData.enrollment("verification_uncertain")); await model.requestVerification()
        let count = await service.verificationCount(), sends = await service.sends()
        XCTAssertEqual(count,0); XCTAssertTrue(sends.isEmpty)
    }
    func testLostResponseRetainsExactIntentAcrossRestartAndReconciliation() async throws {
        let scope = scope(), vault = GuardianModelVault(), store = GuardianIntentStore(vault:vault), service = try GuardianNativeFixture(scope:scope)
        await service.setLost(true)
        let first = GuardianEnrollmentModel(scope:scope,service:service,store:store,runtime:{ scope })
        await first.load(); first.noticeReviewed = true; first.guardianDeclaration = true; first.childLocation = "US"; await first.start()
        let pending = try XCTUnwrap(first.pending); first.invalidate(); await service.setLost(false)
        let second = GuardianEnrollmentModel(scope:scope,service:service,store:.init(vault:vault),runtime:{ scope })
        await second.load(); XCTAssertEqual(second.pending,pending); await second.retry()
        let sends = await service.sends(); XCTAssertEqual(sends.count,2); XCTAssertEqual(sends[0].bytes,sends[1].bytes); XCTAssertEqual(sends[0].id,sends[1].id)
        XCTAssertNil(second.pending); XCTAssertEqual(second.selected?.state,.awaitingVerification)
    }
    func testFailedProtectedSaveSendsNothingAndScopeChangeHidesLateRead() async throws {
        let scope = scope(), vault = GuardianModelVault(), service = try GuardianNativeFixture(scope:scope)
        let model = GuardianEnrollmentModel(scope:scope,service:service,store:.init(vault:vault),runtime:{ scope })
        await model.load(); vault.rejectWrites = true; model.noticeReviewed = true; model.guardianDeclaration = true; model.childLocation = "US"; await model.start()
        let sends = await service.sends(); XCTAssertTrue(sends.isEmpty)
        var live: GuardianRuntimeScope? = scope
        let changed = GuardianEnrollmentModel(scope:scope,service:service,store:.init(vault:GuardianModelVault()),runtime:{ live })
        await service.setRead { await MainActor.run { live = nil; changed.invalidate() } }
        await changed.load(); XCTAssertTrue(changed.enrollments.isEmpty); XCTAssertNil(changed.availability)
    }
    func testGrantNeedsSeparateCurrentNoticeReviewAndPairingNeedsActualCode() async throws {
        let scope = scope(), service = try GuardianNativeFixture(scope:scope,state:"verified")
        let model = GuardianEnrollmentModel(scope:scope,service:service,store:.init(vault:GuardianModelVault()),runtime:{ scope })
        await model.load(); model.select(try GuardianFixtureData.enrollment("verified")); model.childAlias = "Sam"; model.childSignInEmail = "fictional-child@example.invalid"
        XCTAssertFalse(model.canGrant); model.noticeReviewed = true; XCTAssertFalse(model.canGrant)
        model.grantReviewed = true; XCTAssertTrue(model.canGrant); await model.grantPermission()
        XCTAssertEqual(model.selected?.state,.consented)
        try await service.replace("child_claimed"); await model.load(); model.select(try GuardianFixtureData.enrollment("child_claimed"))
        await model.confirmChild(); var sends = await service.sends(); XCTAssertEqual(sends.map(\.kind),[.consent])
        model.pairingCode = "ABCD2345"; await model.confirmChild(); sends = await service.sends()
        XCTAssertEqual(sends.map(\.kind),[.consent,.confirmChild]); XCTAssertEqual(sends.last?.pairingCode,"ABCD2345")
        XCTAssertEqual(model.selected?.state,.childApproved)
    }
    func testInvitationRetainsSecretUntilExplicitStatusCheckedRetirementAndRevocationPurges() async throws {
        let scope = scope(), store = GuardianIntentStore(vault:GuardianModelVault()), service = try GuardianNativeFixture(scope:scope,state:"consented")
        let model = GuardianEnrollmentModel(scope:scope,service:service,store:store,runtime:{ scope })
        await model.load(); model.select(try GuardianFixtureData.enrollment("consented")); await model.createInvitation()
        XCTAssertNotNil(model.invitation); XCTAssertNotNil(model.pending)
        await model.clearRetryAfterStatusReview(); let cleared = try await store.read(); XCTAssertTrue(cleared.isEmpty); XCTAssertNil(model.invitation)
        await model.createInvitation(); await service.setDenied(true); await model.load()
        let purged = try await store.read(); XCTAssertTrue(purged.isEmpty); XCTAssertNil(model.invitation); XCTAssertNil(model.pending)
    }
}
