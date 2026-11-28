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
    static func notice(available: Bool = true, digest: String = "reviewed-digest", countries: [String]? = nil) throws -> GuardianNoticeResponse {
        var response: [String: Any] = available ? ["available":true, "reason":NSNull(), "notice":["version":"notice-1", "digest":digest, "locale":"en", "text":"Fixture current guardian notice", "scope":"own_requests", "methodVersion":"fixture-only-method"]] :
            ["available":false,"reason":"provider_configuration_required","notice":NSNull()]
        if let countries { response["availableChildCountries"] = countries }
        return try decode(response)
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
                       notice: GuardianNotice? = nil, childLocation: String = "US", alias: String? = nil,
                       pairingCode: String? = nil) throws -> GuardianEnrollmentIntent {
        let id = UUID().uuidString.lowercased()
        var body: [String: Any] = ["clientKey":id]
        if let enrollment { body["baseRevision"] = enrollment.revision }
        if let notice { body["noticeVersion"] = notice.version; body["noticeDigest"] = notice.digest }
        switch kind {
        case .create: body["language"] = "en"; body["childLocation"] = childLocation; body["guardianDeclaration"] = "parent_or_legal_guardian"
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
    init(scope: GuardianRuntimeScope, state: String = "awaiting_verification", available: Bool = true, countries: [String]? = nil) throws {
        self.scope = scope; noticeValue = try GuardianFixtureData.notice(available: available, countries: countries)
        rows = [try GuardianFixtureData.enrollment(state)]
    }
    func setLost(_ value: Bool) { lostResponse = value }
    func setDenied(_ value: Bool) { denied = value }
    func setNoticeCountries(_ countries: [String]) throws { noticeValue = try GuardianFixtureData.notice(countries: countries) }
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
        return try GuardianFixtureData.intent(.create, scope: scope, notice: notice, childLocation: childLocation)
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
    func testBrowserInvitationSharesOnlyThePublicRouteInTheAddressAndPreservesTheCode() throws {
        let origin = try XCTUnwrap(URL(string: "https://family.grocery.example:8443/"))
        let code = "fictional-secret.ABC123"
        for route in BrowserInvitationRoute.allCases {
            let share = try XCTUnwrap(route.shareText(serviceURL: origin, code: code))
            let lines = share.components(separatedBy: "\n")
            XCTAssertTrue(lines.first?.contains("Room in the Cart") == true)
            XCTAssertEqual(lines.count, 5)
            let expected = route == .child ? "child-invite" : route.rawValue + "?enterCode=1"
            XCTAssertEqual(lines[1], "https://family.grocery.example:8443/" + expected)
            XCTAssertEqual(lines.last, code)
            XCTAssertFalse(lines.dropLast().joined().contains(code))
        }
        for invalid in ["http://family.grocery.example", "https://person@family.grocery.example",
                        "https://family.grocery.example/?tenant=1", "https://family.grocery.example/#private",
                        "https://family.grocery.example/api"] {
            XCTAssertNil(BrowserInvitationRoute.child.shareText(serviceURL: try XCTUnwrap(URL(string: invalid)), code: code))
        }
        XCTAssertNil(BrowserInvitationRoute.child.shareText(serviceURL: origin, code: ""))
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
    func testCountrySelectionUsesApprovedListAndStartsWithoutAResidenceDefault() async throws {
        let scope = scope(), service = try GuardianNativeFixture(scope: scope, countries: ["US", "MX"])
        let model = GuardianEnrollmentModel(scope: scope, service: service, store: .init(vault: GuardianModelVault()), runtime: { scope })
        await model.load()
        XCTAssertEqual(model.supportedChildCountries, [.unitedStates, .mexico])
        XCTAssertFalse(model.usesLegacyChildLocation)
        XCTAssertNil(model.childCountry)
        model.guardianDeclaration = true
        model.noticeReviewed = true
        model.childLocation = "US"
        XCTAssertFalse(model.canStart)

        model.childCountry = .unitedStates
        XCTAssertTrue(model.canStart)
        for unsupportedRegion in ["CAN", "PR", "VI", "ZZ"] {
            model.childUSRegion = unsupportedRegion
            XCTAssertFalse(model.canStart, unsupportedRegion)
        }
        model.childUSRegion = "DC"
        XCTAssertTrue(model.canStart)
        model.childUSRegion = "CA"
        XCTAssertTrue(model.canStart)
        model.childCountry = .mexico
        XCTAssertEqual(model.childUSRegion, "")
        XCTAssertTrue(model.canStart)
        await model.start()
        let sends = await service.sends()
        let intent = try XCTUnwrap(sends.first)
        let body: [String: String] = try JSONDecoder().decode([String: String].self, from: intent.bytes)
        XCTAssertEqual(body["childLocation"], "MX")
        XCTAssertEqual(body["guardianDeclaration"], "parent_or_legal_guardian")
        XCTAssertNil(model.childCountry)

        model.childCountry = .mexico
        try await service.setNoticeCountries(["US"])
        await model.load()
        XCTAssertTrue(model.usesLegacyChildLocation)
        XCTAssertNil(model.childCountry)
        XCTAssertFalse(model.noticeReviewed)
        model.noticeReviewed = true
        model.guardianDeclaration = true
        model.childLocation = "MX"
        XCTAssertFalse(model.canStart)
        model.childLocation = "US-CA"
        XCTAssertTrue(model.canStart)
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

private actor GuardianDeletionFixture: GuardianChildDeletionServing {
    let child: GuardianDeletionChild
    let reviewed: GuardianDeletionReview
    var sent = [UUID]()
    var sealed = false
    init() throws {
        let id = UUID().uuidString
        child = try GuardianFixtureData.decode(["enrollmentId": id, "childAlias": "Sam"])
        reviewed = try GuardianFixtureData.decode(["enrollmentId": id, "childAlias": "Sam", "reviewId": UUID().uuidString,
            "expiresAt": "2099-01-01T00:00:00Z", "verifiedBackupRetentionDays": 30])
    }
    func guardianDeletionChildren(subject: String, householdID: String, memberID: String) -> [GuardianDeletionChild] { sealed ? [] : [child] }
    func guardianDeletionReview(subject: String, householdID: String, memberID: String, child: GuardianDeletionChild, childSignInEmail: String) throws -> GuardianDeletionReview {
        guard childSignInEmail == "sam@example.invalid" else { throw ClientError.service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil) }
        return reviewed
    }
    func deleteGuardianChildAccount(_ request: GuardianDeletionRequest) throws -> DeletionStatus {
        sent.append(request.id)
        throw ClientError.transport
    }
    func seal() { sealed = true }
    func deletionStatus(_ receipt: DeletionReceipt) throws -> DeletionStatus {
        guard sealed, sent.contains(receipt.id) else { throw ClientError.service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil) }
        return try GuardianFixtureData.decode(["jobId":receipt.id.uuidString, "status":"complete", "appDataErased":true,
            "providerAccountDeleted":true, "completedAt":"2026-11-19T00:00:00Z", "receiptExpiresAt":"2099-01-01T00:00:00Z"])
    }
}

@MainActor final class GuardianChildDeletionTests: XCTestCase {
    private func scope(_ subject: String = "guardian") -> GuardianRuntimeScope {
        .init(subject: subject, householdID: GuardianFixtureData.householdID, memberID: GuardianFixtureData.memberID,
              generation: UUID(), enrollmentRevision: UUID())
    }

    func testUnconfirmedDeletionSurvivesRestartChecksStatusAndReusesOneReceiptForTheSameChild() async throws {
        let scope = scope(), fixture = try GuardianDeletionFixture(), vault = GuardianModelVault()
        func open() -> GuardianChildDeletionModel {
            GuardianChildDeletionModel(scope: scope, service: fixture, vault: vault, runtime: { scope })
        }
        let model = open()
        await model.load()
        let child = try XCTUnwrap(model.children?.first)
        await model.select(child, email: "sam@example.invalid")
        let review = try XCTUnwrap(model.review)
        XCTAssertTrue(model.receipts.isEmpty)
        await model.submit(review)
        let request = try XCTUnwrap(model.receipts.first)
        XCTAssertNil(model.statuses[request.id])
        XCTAssertFalse(model.canReview(child))
        XCTAssertFalse(try XCTUnwrap(vault.read()).contains("sam@example.invalid"))

        let restarted = open()
        await restarted.load()
        let persisted = try XCTUnwrap(restarted.receipts.first)
        XCTAssertEqual(persisted.id, request.id)
        await restarted.check(persisted)
        XCTAssertTrue(restarted.canReview(child))
        await restarted.select(child, email: "sam@example.invalid")
        await restarted.submit(try XCTUnwrap(restarted.review))
        let sent = await fixture.sent
        XCTAssertEqual(sent, [request.id, request.id])
        await fixture.seal()
        await restarted.check(persisted)
        XCTAssertEqual(restarted.statuses[persisted.id]?.status, .complete)
        restarted.forget(persisted)
        XCTAssertTrue(restarted.receipts.isEmpty)
    }

    func testWrongEmailFailedReceiptWriteAndScopeChangeCannotSendOrRevealSavedReceipt() async throws {
        let original = scope(), other = scope("other"), fixture = try GuardianDeletionFixture(), vault = GuardianModelVault()
        var live = original
        let model = GuardianChildDeletionModel(scope: original, service: fixture, vault: vault, runtime: { live })
        await model.load()
        let child = try XCTUnwrap(model.children?.first)
        await model.select(child, email: "wrong@example.invalid")
        XCTAssertNil(model.review)
        await model.load()
        await model.select(child, email: "sam@example.invalid")
        let approved = try XCTUnwrap(model.review)
        vault.rejectWrites = true
        await model.submit(approved)
        let sent = await fixture.sent
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(model.receipts.isEmpty)
        vault.rejectWrites = false
        await model.select(child, email: "sam@example.invalid")
        live = other
        await model.submit(approved)
        let sentAfterChange = await fixture.sent
        XCTAssertTrue(sentAfterChange.isEmpty)
        live = original
        await model.submit(approved)
        model.clear()
        XCTAssertTrue(model.receipts.isEmpty)
        let stranger = GuardianChildDeletionModel(scope: other, service: fixture, vault: vault, runtime: { other })
        await stranger.load()
        XCTAssertTrue(stranger.receipts.isEmpty)
    }
}

private actor ManualGuardianFixture: GuardianManualReviewServing {
    private let enrollment = UUID(), created = "2026-11-18T16:00:00Z", expires = "2099-01-01T00:00:00Z"
    private var saved: UUID?
    private var intake = true
    private var hideFirstStatus = true
    private(set) var keys: [UUID] = []

    func guardianManualReviews(subject: String, householdID: String, memberID: String) throws -> GuardianManualReviewPage {
        let cases: [[String: String]]
        if let saved, !hideFirstStatus { cases = [receipt(saved)] }
        else { cases = [] }
        return try GuardianFixtureData.decode(["available":intake, "children":[["enrollmentId":enrollment.uuidString, "childAlias":"Sam", "identityState":"unmatched"]], "requests":cases])
    }
    private func receipt(_ id: UUID) -> [String: String] {
        ["requestId":id.uuidString, "status":intake ? "received" : "closed", "createdAt":created, "updatedAt":created, "expiresAt":expires]
    }
    func requestGuardianManualReview(_ key: GuardianManualReviewKey, childSignInEmail: String) throws -> GuardianManualReviewCase {
        guard childSignInEmail == "sam@example.invalid" else { throw ClientError.accessEnded }
        keys.append(key.id)
        saved = key.id
        if keys.count == 1 { throw ClientError.transport }
        hideFirstStatus = false
        return try GuardianFixtureData.decode(receipt(key.id))
    }
    func closeIntake() { intake = false }
}

extension GuardianChildDeletionTests {
    func testPrivateCaseSubmissionRecoversOneKeyAndClosedIntakeStillShowsCaseStatus() async throws {
        let scope = scope(), fixture = ManualGuardianFixture(), vault = GuardianModelVault()
        func open() -> GuardianManualReviewModel {
            GuardianManualReviewModel(scope: scope, service: fixture, vault: vault, runtime: { scope })
        }
        let first = open()
        await first.refresh()
        let child = try XCTUnwrap(first.children.first)
        XCTAssertEqual(child.identityState, .unmatched)
        await first.submit(child: child, email: "sam@example.invalid")
        XCTAssertTrue(first.cases.isEmpty)
        XCTAssertFalse(try XCTUnwrap(vault.read()).contains("sam@example.invalid"))

        let restarted = open()
        await restarted.refresh()
        await restarted.submit(child: child, email: "sam@example.invalid")
        let result = try XCTUnwrap(restarted.cases.first)
        XCTAssertEqual(result.status, .received)
        let keys = await fixture.keys
        XCTAssertEqual(keys, [result.id, result.id])
        XCTAssertNil(try vault.read())
        await fixture.closeIntake()
        await restarted.refresh()
        XCTAssertEqual(restarted.available, false)
        XCTAssertEqual(restarted.cases.first?.status, .closed)
        await restarted.submit(child: child, email: "sam@example.invalid")
        let final = await fixture.keys
        XCTAssertEqual(final.count, 2)
    }

    func testPrivateSupportDraftContainsOnlyValidatedAddressAndLocalizedSubject() throws {
        let url = try XCTUnwrap(GuardianDeletionSupportSection.contactURL(address: "hello@example.org"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "mailto")
        XCTAssertEqual(parts.path, "hello@example.org")
        XCTAssertEqual(parts.queryItems?.map(\.name), ["subject"])
        XCTAssertNil(GuardianDeletionSupportSection.contactURL(address: "hello@example.org?cc=other@example.com"))
    }
}
