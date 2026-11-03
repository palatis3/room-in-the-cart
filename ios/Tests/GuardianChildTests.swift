import XCTest
import HouseholdClient
@testable import RoomInTheCart

private final class ChildModelVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ token: String) throws { lock.lock(); defer { lock.unlock() }; value = token }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private enum ChildModelData {
    static let household = "20000000-0000-4000-8000-000000000001"
    static let claim = "20000000-0000-4000-8000-000000000002"
    static func decode<T:Decodable>(_ object: Any) throws -> T { try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) }
    static func receipt() throws -> ChildInvitationClaimReceipt {
        try decode(["householdId":household,"claimId":claim,"status":"awaiting_guardian","expiresAt":"2099-01-01T00:00:00Z"])
    }
    static func intent(_ scope: GuardianChildScope, finish: Bool = false) throws -> ChildInvitationIntent {
        let id = UUID().uuidString.lowercased()
        var body: [String:Any] = ["clientKey":id,"pairingCode":"ABCD2345"]
        if finish { body["householdId"] = household; body["claimId"] = claim; body["deviceSecret"] = try GuardianSecret.generate() }
        else { body["token"] = "fixture-opaque-child-invitation" }
        var raw: [String:Any] = ["id":id,"kind":finish ? "finish" : "claim","issuer":scope.issuer,"subject":scope.subject,"sessionID":scope.sessionID,
            "pairingCode":"ABCD2345","body":body,"bytes":try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys]).base64EncodedString()]
        if finish { raw["householdID"] = household; raw["claimID"] = claim }
        let result: ChildInvitationIntent = try decode(raw); try result.validate(); return result
    }
}
private actor ChildModelFixture: GuardianChildServing {
    let scope: GuardianChildScope
    var statusValue: ChildInvitationClaimStatus.Status = .awaitingGuardian
    var loseClaim = false; var loseFinish = false
    var claims: [ChildInvitationIntent] = []; var finishes: [ChildInvitationIntent] = []
    var onStatus: (@Sendable () async -> Void)?
    var onFinish: (@Sendable () async -> Void)?
    init(_ scope: GuardianChildScope) { self.scope = scope }
    func setStatus(_ value: ChildInvitationClaimStatus.Status) { statusValue = value }
    func setLost(claim: Bool, finish: Bool) { loseClaim = claim; loseFinish = finish }
    func setRead(_ action: (@Sendable () async -> Void)?) { onStatus = action }
    func setFinish(_ action: (@Sendable () async -> Void)?) { onFinish = action }
    func sent() -> ([ChildInvitationIntent],[ChildInvitationIntent]) { (claims,finishes) }
    func prepareClaim(token: String) async throws -> ChildInvitationIntent { try ChildModelData.intent(scope) }
    func authorize(_ intent: ChildInvitationIntent) async throws { guard scope.matches(intent) else { throw ClientError.accessEnded } }
    func claim(_ intent: ChildInvitationIntent) async throws -> ChildInvitationClaimReceipt {
        claims.append(intent); if loseClaim { throw ClientError.transport }; return try ChildModelData.receipt()
    }
    func status(_ receipt: ChildInvitationClaimReceipt) async throws -> ChildInvitationClaimStatus {
        if let onStatus { await onStatus() }
        return try ChildModelData.decode(["claimId":receipt.claimId,"status":statusValue.rawValue,"expiresAt":"2099-01-01T00:00:00Z"])
    }
    func prepareFinish(receipt: ChildInvitationClaimReceipt, pairingCode: String) async throws -> ChildInvitationIntent {
        guard statusValue == .approved, pairingCode == "ABCD2345" else { throw ClientError.accessEnded }
        return try ChildModelData.intent(scope,finish:true)
    }
    func finish(_ intent: ChildInvitationIntent) async throws -> ChildEnrollmentReceipt {
        finishes.append(intent); if let onFinish { await onFinish() }; if loseFinish { throw ClientError.transport }
        return try ChildModelData.decode(["householdId":ChildModelData.household,"memberId":"20000000-0000-4000-8000-000000000003",
            "deviceId":"20000000-0000-4000-8000-000000000004","deviceToken":"fixture-child-device-secret","role":"contributor"])
    }
    func close() async {}
}

@MainActor final class GuardianChildTests: XCTestCase {
    private func scope(session: String = "fixture-child-session") -> GuardianChildScope {
        .init(issuer:"https://fixture-identity.invalid",subject:"fixture-child",sessionID:session,generation:UUID())
    }
    func testClaimShowsDevicePairingButCannotFinishWithoutGuardianApproval() async throws {
        let scope = scope(), service = ChildModelFixture(scope), store = GuardianChildPendingStore(vault:ChildModelVault())
        var installations = 0
        let model = GuardianChildModel(scope:scope,service:service,store:store,runtime:{ scope },onEnrolled:{ _,_ in installations += 1 })
        await model.load(); model.invitationToken = "fixture-invitation"; await model.claimInvitation()
        XCTAssertEqual(model.pairingCode,"ABCD2345"); XCTAssertEqual(model.status,.awaitingGuardian); XCTAssertFalse(model.canFinish)
        await model.finishSetup(); let sent = await service.sent(); XCTAssertTrue(sent.1.isEmpty); XCTAssertEqual(installations,0)
        await service.setStatus(.approved); await model.refreshStatus(); XCTAssertTrue(model.canFinish); await model.finishSetup()
        XCTAssertTrue(model.completed); XCTAssertEqual(installations,1); XCTAssertNil(model.pairingCode)
        let saved = try await store.read(); XCTAssertNil(saved.claim); XCTAssertNil(saved.finish)
    }
    func testLostClaimAndFinishRetryUseSameRandomMaterialAcrossRestart() async throws {
        let scope = scope(), service = ChildModelFixture(scope), vault = ChildModelVault()
        await service.setLost(claim:true,finish:false)
        let first = GuardianChildModel(scope:scope,service:service,store:.init(vault:vault),runtime:{ scope },onEnrolled:{ _,_ in })
        await first.load(); first.invitationToken = "fixture-invitation"; await first.claimInvitation(); first.invalidate()
        await service.setLost(claim:false,finish:true)
        let second = GuardianChildModel(scope:scope,service:service,store:.init(vault:vault),runtime:{ scope },onEnrolled:{ _,_ in })
        await second.load(); await second.retry(); await service.setStatus(.approved); await second.refreshStatus(); await second.finishSetup(); second.invalidate()
        await service.setLost(claim:false,finish:false)
        let third = GuardianChildModel(scope:scope,service:service,store:.init(vault:vault),runtime:{ scope },onEnrolled:{ _,_ in })
        await third.load(); await third.retry()
        let sent = await service.sent(); XCTAssertEqual(sent.0.count,2); XCTAssertEqual(sent.1.count,2)
        XCTAssertEqual(sent.0[0].id,sent.0[1].id); XCTAssertEqual(sent.0[0].bytes,sent.0[1].bytes)
        XCTAssertEqual(sent.1[0].id,sent.1[1].id); XCTAssertEqual(sent.1[0].bytes,sent.1[1].bytes); XCTAssertTrue(third.completed)
    }
    func testSameSubjectNewSessionCannotExposeSavedPairingOrResumeClaim() async throws {
        let scope = scope(), vault = ChildModelVault(), store = GuardianChildPendingStore(vault:vault)
        let epoch = await store.epoch(); try await store.saveClaim(ChildModelData.intent(scope),expectedEpoch:epoch)
        let changed = self.scope(session:"different-session"), service = ChildModelFixture(changed)
        let model = GuardianChildModel(scope:changed,service:service,store:store,runtime:{ changed },onEnrolled:{ _,_ in XCTFail("No installation") })
        await model.load(); XCTAssertNil(model.pairingCode); XCTAssertFalse(model.hasPending)
        let saved = try await store.read(); XCTAssertNil(saved.claim); let sent = await service.sent(); XCTAssertTrue(sent.0.isEmpty)
        do { try await store.saveClaim(ChildModelData.intent(scope),expectedEpoch:epoch); XCTFail("Old epoch must fail") } catch ClientError.cancelled {}
    }
    func testAcceptedFinishArrivingAfterCleanupCannotInstallOrRestoreSecrets() async throws {
        let scope = scope(), service = ChildModelFixture(scope), store = GuardianChildPendingStore(vault:ChildModelVault())
        var runtime: GuardianChildScope? = scope
        var installations = 0
        let model = GuardianChildModel(scope:scope,service:service,store:store,runtime:{ runtime },onEnrolled:{ _,_ in installations += 1 })
        await model.load(); model.invitationToken = "fixture-invitation"; await model.claimInvitation()
        await service.setStatus(.approved); await model.refreshStatus()
        await service.setFinish {
            await MainActor.run { runtime = nil; model.invalidate() }
            try? await store.purge()
        }
        await model.finishSetup()
        XCTAssertEqual(installations,0); XCTAssertFalse(model.completed); XCTAssertNil(model.pairingCode)
        let saved = try await store.read(); XCTAssertNil(saved.claim); XCTAssertNil(saved.finish)
        let sent = await service.sent(); XCTAssertEqual(sent.1.count,1)
    }
    func testBackgroundScopeChangeDropsLateApprovedStatusAndNeverInstalls() async throws {
        let scope = scope(), service = ChildModelFixture(scope); var runtime: GuardianChildScope? = scope
        let model = GuardianChildModel(scope:scope,service:service,store:.init(vault:ChildModelVault()),runtime:{ runtime },onEnrolled:{ _,_ in XCTFail("No installation") })
        await model.load(); model.invitationToken = "fixture-invitation"; await model.claimInvitation()
        await service.setStatus(.approved)
        await service.setRead { await MainActor.run { runtime = nil; model.invalidate() } }
        await model.refreshStatus(); XCTAssertNil(model.pairingCode); XCTAssertNil(model.status); XCTAssertFalse(model.canFinish)
        let sent = await service.sent(); XCTAssertTrue(sent.1.isEmpty)
    }
}
