import XCTest
import HouseholdClient
@testable import RoomInTheCart

private final class NativeAuthModelVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private actor NativeChildIdentityFixture: GuardianChildIdentityVerifying {
    var verifications: [(String,String)] = []
    func verifyGuardianChildCode(email: String, code: String) async throws { verifications.append((email,code)) }
    func childInvitationAccess() async throws -> ChildInvitationAccess { .init(issuer:"https://identity.fixture.invalid/auth/v1",subject:"fixture-child",sessionID:"30000000-0000-4000-8000-000000000001",accessToken:"fixture-token") }
    func clearLocalSession() async throws {}
    func count() -> Int { verifications.count }
    func email() -> String? { verifications.first?.0 }
}
private actor NativeAuthModelFixture: GuardianNativeAuthenticating {
    var available = true
    var loseStart = false
    var starts: [ChildNativeAuthStartIntent] = []
    var admits: [ChildNativeAuthAdmitIntent] = []
    var prepared = 0
    var onAdmission: (@Sendable () async throws -> Void)?
    func setAvailable(_ value: Bool) { available = value }
    func setLost(_ value: Bool) { loseStart = value }
    func setAdmission(_ action: @escaping @Sendable () async throws -> Void) { onAdmission = action }
    func counts() -> (Int,[ChildNativeAuthStartIntent],[ChildNativeAuthAdmitIntent]) { (prepared,starts,admits) }
    func childEnrollmentAvailability(language: GuardianLanguage) async throws -> GuardianAvailabilityResponse {
        .init(available:available,reason:available ? nil : .providerConfigurationRequired)
    }
    private func decode<T:Decodable>(_ value: Any) throws -> T { try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) }
    func prepareNativeAuthentication(token: String, email: String) async throws -> ChildNativeAuthStartIntent {
        prepared += 1
        let id = UUID().uuidString.lowercased()
        let body = ["clientKey":id,"token":token,"email":email,"challengeSecret":try GuardianSecret.generate()]
        return try decode(["id":id,"email":email,"body":body,"bytes":try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys]).base64EncodedString()])
    }
    func startNativeAuthentication(_ intent: ChildNativeAuthStartIntent) async throws -> ChildNativeAuthChallenge {
        starts.append(intent); if loseStart { throw ClientError.transport }
        return try decode(["householdId":"30000000-0000-4000-8000-000000000002","challengeId":"30000000-0000-4000-8000-000000000003","status":"check_email","expiresAt":"2099-01-01T00:00:00Z"])
    }
    func prepareNativeAdmission(challenge: ChildNativeAuthChallenge, startIntent: ChildNativeAuthStartIntent) async throws -> ChildNativeAuthAdmitIntent {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with:startIntent.bytes) as? [String:String])
        let id = UUID().uuidString.lowercased(), body = ["clientKey":id,"householdId":challenge.householdId,"challengeId":challenge.challengeId,"challengeSecret":try XCTUnwrap(raw["challengeSecret"])]
        return try decode(["id":id,"startID":startIntent.id,"issuer":"https://identity.fixture.invalid/auth/v1","subject":"fixture-child","sessionID":"30000000-0000-4000-8000-000000000001","householdID":challenge.householdId,"challengeID":challenge.challengeId,"body":body,"bytes":try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys]).base64EncodedString()])
    }
    func authorizeNativeAdmission(_ intent: ChildNativeAuthAdmitIntent) async throws { try intent.validate() }
    func admitNativeAuthentication(_ intent: ChildNativeAuthAdmitIntent) async throws -> ChildNativeAuthAdmission {
        try await onAdmission?(); admits.append(intent); return try decode(["admitted":true])
    }
    func close() async {}
}
@MainActor final class GuardianNativeAuthenticationTests: XCTestCase {
    func testUnavailableGateDoesNotPrepareOrSendEmail() async throws {
        let service = NativeAuthModelFixture(), identity = NativeChildIdentityFixture()
        await service.setAvailable(false)
        let model = GuardianNativeAuthenticationModel(service:service,identity:identity,store:.init(vault:NativeAuthModelVault()),live:{ true },onAdmitted:{ _,_,_ in XCTFail("No admission") })
        await model.load(); model.token = "fixture-invitation"; model.email = "fictional-child@example.invalid"
        XCTAssertFalse(model.canStart); await model.startSignIn()
        let counts = await service.counts(), verified = await identity.count()
        XCTAssertEqual(counts.0,0); XCTAssertTrue(counts.1.isEmpty); XCTAssertEqual(verified,0)
    }
    func testLostStartResumesExactSecretAndCodeVerificationUsesReviewedEmail() async throws {
        let vault = NativeAuthModelVault(), store = GuardianChildPendingStore(vault:vault), service = NativeAuthModelFixture(), identity = NativeChildIdentityFixture()
        var admitted = 0
        await service.setLost(true)
        let first = GuardianNativeAuthenticationModel(service:service,identity:identity,store:store,live:{ true },onAdmitted:{ _,_,_ in XCTFail("No admission yet") })
        await first.load(); first.token = "fixture-invitation"; first.email = "Fictional.Child+setup@example.invalid"; await first.startSignIn(); first.invalidate()
        await service.setLost(false)
        let second = GuardianNativeAuthenticationModel(service:service,identity:identity,store:store,live:{ true },onAdmitted:{ access,_,_ in XCTAssertEqual(access.subject,"fixture-child"); admitted += 1 })
        await second.load(); XCTAssertFalse(second.challengeReady); await second.resumeSavedSignIn()
        await service.setAdmission { let saved = try await store.read(); XCTAssertNotNil(saved.admission) }
        second.code = "123456"; await second.verifyCode()
        let counts = await service.counts(), email = await identity.email()
        XCTAssertEqual(counts.0,1); XCTAssertEqual(counts.1.count,2); XCTAssertEqual(counts.1[0].bytes,counts.1[1].bytes)
        XCTAssertEqual(email,"Fictional.Child+setup@example.invalid"); XCTAssertEqual(admitted,1); XCTAssertEqual(counts.2.count,1)
    }
    func testSuspensionHidesDraftAndForegroundReloadDoesNotResendEmail() async throws {
        let service = NativeAuthModelFixture(), identity = NativeChildIdentityFixture()
        let model = GuardianNativeAuthenticationModel(service:service,identity:identity,store:.init(vault:NativeAuthModelVault()),live:{ true },onAdmitted:{ _,_,_ in })
        await model.load(); model.token = "fixture-invitation"; model.email = "fictional-child@example.invalid"; await model.startSignIn()
        model.code = "private-code"; model.suspend(); XCTAssertTrue(model.code.isEmpty); XCTAssertFalse(model.challengeReady)
        await model.load(); XCTAssertTrue(model.hasSavedAction); XCTAssertFalse(model.challengeReady)
        let counts = await service.counts(); XCTAssertEqual(counts.1.count,1)
    }
}
