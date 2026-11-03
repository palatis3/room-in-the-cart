#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import HouseholdClient

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
    init(_ scope: GuardianChildScope) { self.scope = scope }
    func setStatus(_ value: ChildInvitationClaimStatus.Status) { statusValue = value }
    func setLost(claim: Bool, finish: Bool) { loseClaim = claim; loseFinish = finish }
    func setRead(_ action: (@Sendable () async -> Void)?) { onStatus = action }
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
        finishes.append(intent); if loseFinish { throw ClientError.transport }
        return try ChildModelData.decode(["householdId":ChildModelData.household,"memberId":"20000000-0000-4000-8000-000000000003",
            "deviceId":"20000000-0000-4000-8000-000000000004","deviceToken":"fixture-child-device-secret","role":"contributor"])
    }
    func close() async {}
}


@MainActor struct GuardianChildFixtureRoot: View {
    @StateObject private var model: GuardianChildModel
    init() {
        let scope = GuardianChildScope(issuer:"https://fixture.invalid/auth/v1",subject:"fictional-child",sessionID:"fictional-child-session",generation:UUID())
        let fixture = ChildModelFixture(scope)
        _model = StateObject(wrappedValue:GuardianChildModel(scope:scope,service:fixture,store:.init(vault:ChildModelVault()),runtime:{ scope },onEnrolled:{ _,_ in throw ClientError.configuration }))
    }
    var body: some View { NavigationStack { GuardianChildView(model:model) } }
}
#endif
