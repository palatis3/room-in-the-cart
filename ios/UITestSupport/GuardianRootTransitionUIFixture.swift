#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import HouseholdClient
import LocalStore
import DeviceSurfaces
import CryptoKit

private final class GuardianRootMemoryVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private final class GuardianRootFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, ["guardian-root-fixture.invalid","identity.guardian-root-fixture.invalid"].contains(url.host ?? "") else {
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)); return
        }
        let availability = url.path == "/v1/guardian/availability"
        var body: [String:Any] = ["error":["code":"fixture_session_rejected"]]
        var status = 401
        if availability {
            body = ["available":false,"reason":"provider_configuration_required"]
            status = 200
        } else if ProcessInfo.processInfo.arguments.contains("--household-first-sign-in") {
            let user = ["id":"fixture-first-shopper","email_confirmed_at":"date"]
            let home = "10000000-0000-4000-8000-000000000001"
            switch url.path {
            case "/auth/v1/otp": body = [:]
            case "/auth/v1/verify": body = ["access_token":"fictional-access","refresh_token":"fictional-refresh","expires_in":3600,"user":user]
            case "/auth/v1/user": body = user
            case "/v1/me/workspaces": body = ["workspaces":[["householdId":home,"label":"Fixture family","role":"shopper"]]]
            case "/v1/households/\(home)/devices": body = ["deviceId":"fixture-device","deviceToken":"fictional-device-access"]
            case "/v1/households/\(home)/bootstrap":
                body = ["household":["id":home,"label":"Fixture family"],"memberId":"fixture-shopper","role":"shopper",
                    "enrolled":true,"queueConsent":false,"capabilities":[]]
            default: break
            }
            if body["error"] == nil { status = 200 }
        }
        let data = try! JSONSerialization.data(withJSONObject:body,options:[.sortedKeys])
        let response = HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Uses real RootView, Settings, coordinator, marker and cleanup. All session
/// vaults, defaults, files and HTTP responses belong only to this fixture.
@MainActor private final class GuardianRootTransitionState: ObservableObject {
    private struct Baseline: Codable { let ledgerHash: String; let ledgerRevision: Int64; let inboxID: UUID; let inboxDigest: String }
    let app: AppModel
    let ledger: LedgerModel
    let pickup: PickupModel
    let household: HouseholdModel
    let access: WorkspaceAccess
    let surfaces: DeviceSurfacesComposition
    let membership = MembershipCoordinator()
    let navigation: NavigationRestorationModel
    let coordinator: GuardianChildCoordinator
    @Published private(set) var ready = false
    @Published private(set) var preservation = "not checked"
    private let directory: URL
    private let reset: Bool
    private let identityVault: GuardianRootMemoryVault
    private let deviceVault: GuardianRootMemoryVault
    private let setupVault: GuardianRootMemoryVault
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let synthetic = arguments.contains("--guardian-root-synthetic-vaults")
        let firstSignIn = arguments.contains("--household-first-sign-in")
        let suffix = firstSignIn ? "first-sign-in" : (synthetic ? "synthetic" : "empty")
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let directory = support.appendingPathComponent("UITestWorkspace/GuardianRootTransition/" + suffix,isDirectory:true)
        self.directory = directory
        let suite = "dev.roominthecart.guardian-root-ui-fixture." + suffix
        let defaults = UserDefaults(suiteName:suite)!
        reset = arguments.contains("--ui-testing") && arguments.contains("--guardian-fixture-root") && arguments.contains("--reset-guardian-root-fixture")
        if reset {
            if FileManager.default.fileExists(atPath:directory.path) { try! FileManager.default.removeItem(at:directory) }
            defaults.removePersistentDomain(forName:suite)
        }
        let bundleURL = directory.appendingPathComponent("Disconnected.bundle",isDirectory:true)
        try! FileManager.default.createDirectory(at:bundleURL,withIntermediateDirectories:true)
        let info = try! PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":suite],format:.xml,options:0)
        try! info.write(to:bundleURL.appendingPathComponent("Info.plist"),options:.atomic)
        let disconnected = Bundle(url:bundleURL)!
        app = AppModel(databaseURL:directory.appendingPathComponent("unopened-comparisons.sqlite"))
        ledger = LedgerModel(databaseURL:directory.appendingPathComponent("private-ledger.sqlite"))
        pickup = PickupModel(databaseURL:directory.appendingPathComponent("unopened-pickup.sqlite"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GuardianRootFixtureProtocol.self]
        let transport = HTTPTransport(session:URLSession(configuration:config))
        let auth = firstSignIn ? AdultAuth(configuration: try! .init(projectURL: URL(string:"https://identity.guardian-root-fixture.invalid")!,
            publishableKey:"sb_publishable_guardian_root_fixture"), vault:GuardianRootMemoryVault(), transport:transport) : nil
        let service = auth.map { HouseholdService(configuration:try! .init(baseURL:URL(string:"https://guardian-root-fixture.invalid")!),
            auth:$0, deviceVault:GuardianRootMemoryVault(), transport:transport) }
        household = HouseholdModel(bundle:disconnected,auth:auth,service:service,outboxURL:directory.appendingPathComponent("unused-adult-outbox.json"),
            deletionVault:GuardianRootMemoryVault(),exitVault:GuardianRootMemoryVault(),guardianVault:GuardianRootMemoryVault())
        access = WorkspaceAccess(defaults:defaults)
        surfaces = DeviceSurfacesComposition(directory:directory.appendingPathComponent("surfaces"),bundle:disconnected,launchArguments:arguments)
        navigation = NavigationRestorationModel(store:NavigationSnapshotStore(url:directory.appendingPathComponent("unused-navigation.json")))
        let syntheticMaterial = synthetic && (reset || FileManager.default.fileExists(atPath:directory.appendingPathComponent("child-root-marker.json").path))
        identityVault = GuardianRootMemoryVault(syntheticMaterial ? "fictional-refresh-which-cannot-authenticate" : nil)
        deviceVault = GuardianRootMemoryVault(syntheticMaterial ? "fictional-device-which-cannot-enroll" : nil)
        setupVault = GuardianRootMemoryVault(syntheticMaterial ? "fictional-pending-secret-only" : nil)
        coordinator = GuardianChildCoordinator.rootTransitionFixture(bundle:disconnected,
            marker:.init(url:directory.appendingPathComponent("child-root-marker.json")),
            authConfiguration:try! .init(projectURL:URL(string:"https://identity.guardian-root-fixture.invalid")!,publishableKey:"sb_publishable_guardian_root_fixture"),
            serviceConfiguration:try! .init(baseURL:URL(string:"https://guardian-root-fixture.invalid")!),
            identityVault:identityVault,deviceVault:deviceVault,setupVault:setupVault,transport:transport)
        if reset && !firstSignIn { access.protect() }
    }
    func start() async {
        do {
            if reset {
                // This explicit fixture preparation occurs before child entry. A
                // marker-active cold launch never opens the adult model/store.
                await ledger.open()
                guard await ledger.startShop(title:"Fictional adult private pickup"), let shopID = ledger.shop?.id,
                      await ledger.editShop(key:"fixture-private-line",shopID:shopID,{ shop in
                          _ = try shop.addManualLine(name:"Fictional adult private item",quantity:nil)
                      }) else { throw ClientError.configuration }
                let store = try LedgerStore(url:directory.appendingPathComponent("private-ledger.sqlite"))
                guard let saved = try await store.load() else { throw ClientError.configuration }
                let inbox = try SelectedTextInbox(url:directory.appendingPathComponent("surfaces/TestInbox/selected-text.sqlite"))
                let entry = try await inbox.stage(operationID:UUID(),originalText:"Fictional private selected-text draft",now:Date())
                let baseline = Baseline(ledgerHash:Self.hash(saved.payload),ledgerRevision:saved.revision,inboxID:entry.operationID,inboxDigest:entry.digest)
                try JSONEncoder().encode(baseline).write(to:directory.appendingPathComponent("fixture-baseline.json"),options:.atomic)
                try await store.close()
            }
            if coordinator.presented { coordinator.enforcePrivacyBoundary(adult:household,access:access,surfaces:surfaces) }
            surfaces.bind(ledger:ledger,pickup:pickup,household:household,access:access)
            if coordinator.presented { await coordinator.resume() }
            ready = true
        } catch { preservation = "fixture setup failed" }
    }
    func verifyPreservation() async {
        guard !coordinator.presented, !access.unlocked else { preservation = "blocked while child or adult unlocked"; return }
        do {
            let baseline = try JSONDecoder().decode(Baseline.self,from:Data(contentsOf:directory.appendingPathComponent("fixture-baseline.json")))
            let store = try LedgerStore(url:directory.appendingPathComponent("private-ledger.sqlite"))
            guard let saved = try await store.load(), saved.revision == baseline.ledgerRevision,
                  Self.hash(saved.payload) == baseline.ledgerHash else { throw ClientError.invalidResponse }
            try await store.close()
            let inbox = try SelectedTextInbox(url:directory.appendingPathComponent("surfaces/TestInbox/selected-text.sqlite"))
            let pending = try await inbox.pending(now:Date())
            guard pending.count == 1, pending[0].id == baseline.inboxID, pending[0].receipt.digest == baseline.inboxDigest,
                  pending[0].receipt.disposition == .pending, try identityVault.read() == nil,
                  try deviceVault.read() == nil, try setupVault.read() == nil else { throw ClientError.invalidResponse }
            preservation = "adult records and inbox preserved; child vaults empty; adult locked"
        } catch { preservation = "preservation or cleanup failed" }
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    func phaseChanged(_ phase: ScenePhase) {
        if phase == .background { coordinator.suspend(); surfaces.background(); access.background(); household.lock() }
        if phase == .active, coordinator.presented {
            coordinator.enforcePrivacyBoundary(adult:household,access:access,surfaces:surfaces)
            Task { await coordinator.resume() }
        }
    }
}

@MainActor struct GuardianRootTransitionFixtureRoot: View {
    @StateObject private var state = GuardianRootTransitionState()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        // Fixture state never forwards coordinator.objectWillChange. Production
        // RootView's subscribed GuardianBoundaryRoot owns every root transition.
        VStack(spacing:0) {
            RootView()
                .environment(\.pickupLedger,state.ledger)
                .environmentObject(state.app).environmentObject(state.ledger).environmentObject(state.pickup)
                .environmentObject(state.household).environmentObject(state.access).environmentObject(state.surfaces)
                .environmentObject(state.membership).environmentObject(state.navigation)
                .environmentObject(state.coordinator).environment(\.guardianChildCoordinator,state.coordinator)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
            VStack {
                if state.ready { Text("Fixture ready").accessibilityIdentifier("guardian.fixture.rootReady") }
                Button("Fixture: check preservation") { Task { await state.verifyPreservation() } }
                    .accessibilityIdentifier("guardian.fixture.checkPreservation")
                Text(state.preservation).accessibilityIdentifier("guardian.fixture.preservation")
            }.font(.caption).padding(4).frame(maxWidth:.infinity).background(.regularMaterial)
        }
            .modifier(HouseholdWorkspaceProtection(household: state.household, access: state.access))
            .task { await state.start() }
            .onChange(of:phase) { _, value in state.phaseChanged(value) }
    }
}
#endif
