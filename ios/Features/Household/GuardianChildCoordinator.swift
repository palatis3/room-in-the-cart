import Foundation
import SwiftUI
import HouseholdClient

/// This marker controls only which local root may render. It carries no identity, invitation or credential.
struct GuardianChildPresentationMarker {
    let url: URL
    private struct Marker: Codable { let version: Int; let active: Bool }
    func read() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        guard data.count <= 1000 else { throw ClientError.configuration }
        let value = try JSONDecoder().decode(Marker.self, from: data)
        guard value.version == 1, value.active else { throw ClientError.configuration }; return true
    }
    func activate() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Marker(version: 1, active: true))
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var privateURL = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try privateURL.setResourceValues(values)
        guard try read() else { throw ClientError.configuration }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ClientError.configuration }
    }
}

@MainActor final class GuardianChildCoordinator: ObservableObject {
    enum Destination: Equatable { case starting, signIn, pairing, requests, unavailable, blocked }
    @Published private(set) var presented: Bool
    @Published private(set) var destination: Destination = .starting
    @Published private(set) var authentication: GuardianNativeAuthenticationModel?
    @Published private(set) var pairing: GuardianChildModel?
    @Published private(set) var household: HouseholdModel?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let marker: GuardianChildPresentationMarker
    private let bundle: Bundle
    private var generation = UUID()
    private var resumeID = UUID()
    private var active = true
    private var boundaryValid = true
    private var sessionMaterialPossible = false
    private var scope: GuardianChildScope?
    private var adoptionReady = false
    private var identity: AdultAuth?
    private var service: HouseholdService?
    private var invitationClient: ChildInvitationClient?
    private var pending: GuardianChildPendingStore?
    private var identityVault: (any RefreshTokenVault)?
    private var deviceVault: (any RefreshTokenVault)?
    private var exitAdult: (() -> Void)?
    init(bundle: Bundle = .main, marker: GuardianChildPresentationMarker? = nil) {
        self.bundle = bundle
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.marker = marker ?? .init(url: base.appendingPathComponent("RoomInTheCart/child-root-marker.json"))
        do { presented = try self.marker.read(); sessionMaterialPossible = presented }
        catch { presented = true; sessionMaterialPossible = true; boundaryValid = false; destination = .blocked; message = GuardianCopy.text("Saved child access could not be checked. Adult work remains locked.") }
    }
    #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
    /// Test-build composition only. No release initializer, authentication bypass or local activation is added.
    static func rootTransitionFixture(bundle: Bundle, marker: GuardianChildPresentationMarker,
        authConfiguration: AdultAuthConfiguration, serviceConfiguration: ServiceConfiguration,
        identityVault: any RefreshTokenVault, deviceVault: any RefreshTokenVault,
        setupVault: any RefreshTokenVault, transport: HTTPTransport) -> GuardianChildCoordinator {
        let value = GuardianChildCoordinator(bundle: bundle, marker: marker)
        let identity = AdultAuth(configuration: authConfiguration, vault: identityVault, transport: transport)
        value.identity = identity
        value.service = HouseholdService(configuration: serviceConfiguration, auth: identity, deviceVault: deviceVault, transport: transport)
        value.invitationClient = ChildInvitationClient(configuration: serviceConfiguration, transport: transport,
            access: { try await identity.childInvitationAccess() })
        value.pending = GuardianChildPendingStore(vault: setupVault)
        value.identityVault = identityVault; value.deviceVault = deviceVault
        value.sessionMaterialPossible = true
        return value
    }
    #endif
    /// Root must call this before rendering child UI, opening adult stores, or refreshing device surfaces.
    func enforcePrivacyBoundary(adult: HouseholdModel, access: WorkspaceAccess, surfaces: DeviceSurfacesComposition) {
        access.protect()
        surfaces.background()
        adult.lock()
        surfaces.scopeChanged()
        exitAdult = { [weak adult, weak access, weak surfaces] in
            access?.protect(); surfaces?.background(); adult?.lock(); surfaces?.scopeChanged()
        }
    }
    func open(adult: HouseholdModel, access: WorkspaceAccess, surfaces: DeviceSurfacesComposition) {
        enforcePrivacyBoundary(adult: adult, access: access, surfaces: surfaces)
        do { try marker.activate(); boundaryValid = true; active = true; presented = true; destination = .starting; message = nil }
        catch { presented = true; boundaryValid = false; destination = .blocked; message = GuardianCopy.text("This device could not save the child privacy boundary. Adult work remains locked."); return }
        Task { await resume() }
    }
    private func configure() throws {
        if identity != nil { return }
        guard let serviceString = bundle.object(forInfoDictionaryKey: "HouseholdServiceURL") as? String,
              let providerString = bundle.object(forInfoDictionaryKey: "SupabaseProjectURL") as? String,
              let key = bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
              let serviceURL = URL(string: serviceString), let providerURL = URL(string: providerString) else { throw ClientError.configuration }
        let configuration = try ServiceConfiguration(baseURL: serviceURL)
        let authConfiguration = try AdultAuthConfiguration(projectURL: providerURL, publishableKey: key)
        let namespace = (bundle.bundleIdentifier ?? "RoomInTheCart") + ".child." + serviceURL.absoluteString + "." + providerURL.absoluteString
        let identityVault = KeychainRefreshTokenVault(service: namespace, account: "covered-child-refresh")
        let deviceVault = KeychainRefreshTokenVault(service: namespace, account: "covered-child-device")
        let identity = AdultAuth(configuration: authConfiguration, vault: identityVault)
        let service = HouseholdService(configuration: configuration, auth: identity, deviceVault: deviceVault)
        let client = ChildInvitationClient(configuration: configuration, access: { try await identity.childInvitationAccess() })
        let pending = GuardianChildPendingStore(vault: KeychainRefreshTokenVault(service: namespace, account: "covered-child-setup"))
        sessionMaterialPossible = true
        self.identityVault = identityVault; self.deviceVault = deviceVault
        self.identity = identity; self.service = service; self.invitationClient = client; self.pending = pending
    }
    func resume() async {
        active = true
        guard presented, boundaryValid, !busy else { return }
        let start = generation, attempt = UUID(); resumeID = attempt; busy = true
        defer { if resumeID == attempt { busy = false } }
        do {
            try configure()
            guard let identity, let service, let client = invitationClient, let pending else { throw ClientError.configuration }
            if try identityVault?.read() != nil, try deviceVault?.read() != nil {
                let access = try await identity.childInvitationAccess()
                guard current(start), resumeID == attempt else { return }
                let child = makeHousehold(identity: identity, service: service)
                try await child.resumeGuardianChildSession(expectedAccess: access)
                guard current(start), resumeID == attempt else { return }
                try await pending.purge()
                guard current(start), resumeID == attempt else { return }
                household = child; destination = .requests; message = nil; return
            }
            if let pairing, scope != nil {
                await pairing.load(); guard current(start), resumeID == attempt else { return }; destination = .pairing; return
            }
            if authentication == nil {
                authentication = GuardianNativeAuthenticationModel(service: client, identity: identity, store: pending,
                    live: { [weak self] in self?.current(start) == true },
                    onAdmitted: { [weak self] access, authentication, admission in
                        guard let self, self.current(start) else { throw ClientError.cancelled }
                        try self.presentPairing(access: access, authentication: authentication, admission: admission)
                    })
            }
            destination = .signIn
            await authentication?.load()
        } catch {
            guard current(start), resumeID == attempt else { return }
            destination = error as? ClientError == .configuration ? .unavailable : .blocked
            message = GuardianCopy.text("Child access could not be reopened. Adult work remains locked. You can remove this child session from the device.")
        }
    }
    private func current(_ start: UUID) -> Bool { presented && active && generation == start }
    private func makeHousehold(identity: AdultAuth, service: HouseholdService) -> HouseholdModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HouseholdModel(bundle: bundle, auth: identity, service: service,
            outboxURL: base.appendingPathComponent("RoomInTheCart/covered-child/outbox.json"), guardianChildOnly: true)
    }
    private func presentPairing(access: ChildInvitationAccess, authentication: ChildNativeAuthStartIntent, admission: ChildNativeAuthAdmitIntent) throws {
        guard let client = invitationClient, let pending, let identity, let service else { throw ClientError.configuration }
        let scope = GuardianChildScope(issuer: access.issuer, subject: access.subject, sessionID: access.sessionID, generation: UUID())
        self.scope = scope; adoptionReady = false
        let adapter = GuardianCoveredChildService(client: client, start: authentication, admission: admission)
        let start = generation
        pairing = GuardianChildModel(scope: scope, service: adapter, store: pending, coveredAuthentication: true,
            runtime: { [weak self] in self?.current(start) == true ? self?.scope : nil },
            onEnrolled: { [weak self] expected, receipt in
                guard let self, self.current(start), self.scope == expected else { throw ClientError.cancelled }
                let current = try await identity.childInvitationAccess()
                guard self.current(start), current.issuer == expected.issuer, current.subject == expected.subject, current.sessionID == expected.sessionID else { throw ClientError.accessEnded }
                let child = self.makeHousehold(identity: identity, service: service)
                try await child.adoptGuardianChildEnrollment(receipt: receipt, expectedAccess: current)
                guard self.current(start), self.scope == expected else { throw ClientError.cancelled }
                self.household = child; self.adoptionReady = true
            })
        destination = .pairing
    }
    func showOwnRequests() {
        guard presented, pairing?.completed == true, adoptionReady, household?.projection != nil else { return }
        authentication?.invalidate(); authentication = nil; pairing = nil; destination = .requests
    }
    func suspend() {
        active = false; resumeID = UUID(); busy = false
        authentication?.suspend(); pairing?.suspend(); household?.lock()
    }
    func removeChildSession() async {
        guard presented, !busy else { return }
        let stableAdoptedDevice = destination == .requests && household?.projection != nil
        busy = true; generation = UUID(); scope = nil; adoptionReady = false
        authentication?.invalidate(); pairing?.invalidate(); household?.lock()
        var remoteUnconfirmed = !stableAdoptedDevice
        if sessionMaterialPossible, identity == nil {
            do { try configure() } catch {
                busy = false; destination = .blocked
                message = GuardianCopy.text("Child cleanup could not be confirmed. Adult work remains locked. Unlock this device and try again."); return
            }
        }
        // Stop a late accepted finish before it can call adoption. During setup the
        // server may have activated a device whose receipt never reached this process.
        await invitationClient?.close()
        if stableAdoptedDevice {
            do { try await service?.revokeCurrentDevice() } catch { remoteUnconfirmed = true }
        }
        // This increments the service generation before old adoption/bootstrap can write.
        await service?.clearScope()
        do { try await identity?.signOut() } catch { remoteUnconfirmed = true }
        do {
            if let household { guard await household.endGuardianChildSession() else { throw ClientError.configuration } }
            try await pending?.purge(); await invitationClient?.close(); await service?.clearScope()
            try identityVault?.clear(); try deviceVault?.clear()
            guard try identityVault?.read() == nil, try deviceVault?.read() == nil else { throw ClientError.configuration }
            try marker.clear()
            exitAdult?(); authentication = nil; pairing = nil; household = nil; presented = false
            message = remoteUnconfirmed ? GuardianCopy.text("Child access was removed from this device. Remote device revocation could not be confirmed; ask your guardian to review active permission.") : nil
        } catch {
            destination = .blocked; message = GuardianCopy.text("Child cleanup could not be confirmed. Adult work remains locked. Unlock this device and try again.")
        }
        busy = false
    }
}
