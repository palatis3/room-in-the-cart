#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import HouseholdClient

// Fictional provider/session authority exists only behind this dedicated test build.
// No real provider account, OTP, email, callback, or production activation is available.
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
    static func notice(available: Bool, language: GuardianLanguage, includesMexico: Bool) throws -> GuardianNoticeResponse {
        var response: [String: Any] = available ? ["available":true, "reason":NSNull(), "notice":["version":"notice-1", "digest":"reviewed-digest",
            "locale":language.rawValue, "text":"Fixture current guardian notice", "scope":"own_requests", "methodVersion":"fixture-only-method"]] :
            ["available":false,"reason":"provider_configuration_required","notice":NSNull()]
        if available && includesMexico { response["availableChildCountries"] = ["US", "MX"] }
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
        case .create:
            body["language"] = notice?.locale.rawValue
            body["childLocation"] = childLocation
            body["guardianDeclaration"] = "parent_or_legal_guardian"
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
    let available: Bool
    let includesMexico: Bool
    var rows: [GuardianEnrollment]
    var lostResponse = false
    var denied = false
    var sent: [GuardianEnrollmentIntent] = []
    var verificationPrepared = 0
    var confirmedLocation = ""
    var onRead: (@Sendable () async -> Void)?
    init(scope: GuardianRuntimeScope, state: String = "awaiting_verification", available: Bool = true, empty: Bool = false,
         includesMexico: Bool = false) throws {
        self.scope = scope; self.available = available; self.includesMexico = includesMexico
        rows = empty ? [] : [try GuardianFixtureData.enrollment(state)]
    }
    func setLost(_ value: Bool) { lostResponse = value }
    func setDenied(_ value: Bool) { denied = value }
    func setRead(_ value: (@Sendable () async -> Void)?) { onRead = value }
    func replace(_ state: String) throws { rows = [try GuardianFixtureData.enrollment(state)] }
    func sends() -> [GuardianEnrollmentIntent] { sent }
    func completeProvider() throws { guard rows.first?.state == .verificationPending else { return }; rows = [try GuardianFixtureData.enrollment("verified", revision: 3)] }
    func childClaims() throws { guard rows.first?.state == .consented else { return }; rows = [try GuardianFixtureData.enrollment("child_claimed", revision: 5)] }
    func verificationCount() -> Int { verificationPrepared }
    func guardianNotice(language: GuardianLanguage) async throws -> GuardianNoticeResponse {
        try GuardianFixtureData.notice(available: available, language: language, includesMexico: includesMexico)
    }
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
        if intent.kind == .confirmChild, intent.pairingCode != "ABCD2345" { throw ClientError.service(status:409,code:"pairing_mismatch",correlationID:nil,retryAfter:nil) }
        if lostResponse { throw ClientError.transport }
        let state: String
        switch intent.kind {
        case .verification: state = "verification_pending"
        case .consent: state = "consented"
        case .confirmChild: state = "child_approved"
        case .cancel: state = "cancelled"
        case .create:
            let fields = try JSONDecoder().decode([String: String].self, from: intent.bytes)
            confirmedLocation = fields["childLocation"] ?? ""
            state = "awaiting_verification"
        case .childInvitation: throw ClientError.configuration
        }
        let value = try GuardianFixtureData.enrollment(state, revision: 2); rows = [value]; return value
    }
    func executeGuardianChildInvitation(_ intent: GuardianEnrollmentIntent) async throws -> GuardianChildInvitation {
        sent.append(intent); if lostResponse { throw ClientError.transport }
        return try GuardianFixtureData.decode(["inviteId":UUID().uuidString,"token":"fixture-opaque-invitation","expiresAt":"2099-01-01T00:00:00Z"])
    }
}


@MainActor struct GuardianEnrollmentFixtureRoot: View {
    private let fixture: GuardianNativeFixture
    @StateObject private var model: GuardianEnrollmentModel
    @State private var verificationCount = 0
    @State private var confirmedLocation = ""
    private var childMode: Bool { ProcessInfo.processInfo.arguments.contains("--guardian-fixture-child") }
    private var includesMexico: Bool { ProcessInfo.processInfo.arguments.contains("--guardian-fixture-mexico") }
    init() {
        let args = ProcessInfo.processInfo.arguments
        let unavailable = args.contains("--guardian-fixture-unavailable")
        let uncertain = args.contains("--guardian-fixture-uncertain")
        let awaiting = args.contains("--guardian-fixture-awaiting")
        let scope = GuardianRuntimeScope(subject: "fictional-guardian", householdID: GuardianFixtureData.householdID,
            memberID: GuardianFixtureData.memberID, generation: UUID(), enrollmentRevision: UUID())
        let service = try! GuardianNativeFixture(scope: scope, state: uncertain ? "verification_uncertain" : "awaiting_verification",
            available: !unavailable, empty: unavailable || (!uncertain && !awaiting), includesMexico: args.contains("--guardian-fixture-mexico"))
        fixture = service
        _model = StateObject(wrappedValue: GuardianEnrollmentModel(scope:scope,service:service,
            store:GuardianIntentStore(vault:GuardianModelVault()),runtime:{ scope }))
    }
    var body: some View {
        Group { if ProcessInfo.processInfo.arguments.contains("--guardian-fixture-root") { GuardianRootTransitionFixtureRoot() }
        else if childMode { GuardianChildFixtureRoot() }
        else { NavigationStack {
            GuardianEnrollmentView(model:model, serviceURL: URL(string: "https://fixture.invalid")) {
                Text("Fictional guardian fixture · no real emails or accounts")
                Text(String(verificationCount)).accessibilityIdentifier("guardian.fixture.verificationRequests")
                if includesMexico && !confirmedLocation.isEmpty {
                    Text(verbatim: confirmedLocation).accessibilityIdentifier("guardian.fixture.confirmedLocation")
                }
                if model.selected?.state == .verificationPending {
                    Button("Fixture: verified adulthood") { Task { try? await fixture.completeProvider(); await model.load() } }
                        .accessibilityIdentifier("guardian.fixture.providerVerified")
                }
                if model.selected?.state == .consented {
                    Button("Fixture: child claimed") { Task { try? await fixture.childClaims(); await model.load() } }
                        .accessibilityIdentifier("guardian.fixture.childClaimed")
                }
            }
            .onChange(of:model.busy) { _, busy in if !busy {
                if model.selected == nil, let row = model.enrollments.first { model.select(row) }
                Task {
                    verificationCount = await fixture.verificationCount()
                    confirmedLocation = await fixture.confirmedLocation
                }
            } }
            .task {
                await model.load()
                if let row = model.enrollments.first { model.select(row) }
            }
        } } }
        .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--guardian-fixture-largest-text") ? .accessibility5 : .large)
    }
}
#endif
