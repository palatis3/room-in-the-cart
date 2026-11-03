import Foundation
import Combine

/// These locators contain identities only. No grant, role, consent, financial
/// projection, form draft or verified session is recovered from this file.
enum AdultTab: String, Codable, CaseIterable { case shop, dinners, records }
struct HouseholdNavigationIdentity: Codable, Hashable {
    let subject: String
    let householdID: String
    let memberID: String
    let shopID: String?

    init(_ scope: ContextualHouseholdScope) {
        subject = scope.subject; householdID = scope.householdID
        memberID = scope.memberID; shopID = scope.shopID
    }
    func matches(_ scope: ContextualHouseholdScope) -> Bool {
        self == Self(scope)
    }
}
enum RestorableDestination: Codable, Hashable {
    case shoppingList(actorID: UUID, workspaceID: UUID, shopID: UUID?)
    case comparison(actorID: UUID, workspaceID: UUID, recordID: UUID)
    case household(ContextualHouseholdDestination, HouseholdNavigationIdentity)
}
struct NavigationSnapshot: Codable, Equatable {
    let version: Int
    var selection: AdultTab
    var shop: [RestorableDestination]
    var dinners: [RestorableDestination]
    var records: [RestorableDestination]
    static let empty = Self(version: 1, selection: .shop, shop: [], dinners: [], records: [])
    subscript(_ tab: AdultTab) -> [RestorableDestination] {
        get { switch tab { case .shop: shop; case .dinners: dinners; case .records: records } }
        set { switch tab { case .shop: shop = newValue; case .dinners: dinners = newValue; case .records: records = newValue } }
    }
}
final class NavigationSnapshotStore {
    private let url: URL
    init(url: URL) { self.url = url }
    static func applicationStore() -> NavigationSnapshotStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = base.appendingPathComponent("RoomInTheCart", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            directory = base.appendingPathComponent("UITestWorkspace", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-test-workspace") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("navigation.json"))
            }
        }
        #endif
        return .init(url: directory.appendingPathComponent("navigation.json"))
    }
    func load() -> NavigationSnapshot {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16_384, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(NavigationSnapshot.self, from: data),
              value.version == 1, AdultTab.allCases.allSatisfy({ value[$0].count <= 4 }) else { return .empty }
        return value
    }
    func save(_ value: NavigationSnapshot) {
        guard let bytes = try? JSONEncoder().encode(value), bytes.count <= 16_384 else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Navigation is optional. A failed checkpoint never prevents opening
            // the durable source through its ordinary root.
        }
    }
}

@MainActor final class NavigationRestorationModel: ObservableObject {
    @Published private(set) var selection: AdultTab
    @Published private(set) var shopPath: [RestorableDestination] = []
    @Published private(set) var dinnersPath: [RestorableDestination] = []
    @Published private(set) var recordsPath: [RestorableDestination] = []
    private var snapshot: NavigationSnapshot
    private let store: NavigationSnapshotStore
    private weak var app: AppModel?
    private weak var ledger: LedgerModel?
    private weak var household: HouseholdModel?
    private weak var access: WorkspaceAccess?
    private var subscriptions: Set<AnyCancellable> = []
    private var suspended = false
    private var sawLiveHousehold = false
    private var resumingHousehold = false

    init(store: NavigationSnapshotStore = .applicationStore()) {
        self.store = store; snapshot = store.load(); selection = snapshot.selection
    }
    func bind(app: AppModel, ledger: LedgerModel, household: HouseholdModel, access: WorkspaceAccess) {
        guard subscriptions.isEmpty else { return }
        self.app = app; self.ledger = ledger; self.household = household; self.access = access
        let previous = household.onScopeChange
        household.onScopeChange = { [weak self] in
            self?.householdScopeWillChange(); previous?()
        }
        for publisher in [app.objectWillChange.eraseToAnyPublisher(), ledger.objectWillChange.eraseToAnyPublisher(),
                          household.objectWillChange.eraseToAnyPublisher(), access.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in
                Task { @MainActor [weak self] in await Task.yield(); self?.reconcile() }
            }.store(in: &subscriptions)
        }
        reconcile()
    }
    func path(for tab: AdultTab) -> [RestorableDestination] {
        switch tab { case .shop: shopPath; case .dinners: dinnersPath; case .records: recordsPath }
    }
    func select(_ tab: AdultTab) {
        selection = tab; snapshot.selection = tab; store.save(snapshot)
    }
    func setPath(_ path: [RestorableDestination], for tab: AdultTab) {
        snapshot[tab] = Array(path.prefix(4)); reconcile(); store.save(snapshot)
    }
    /// Called before the privacy curtain and household lock clear live models.
    func suspend() { suspended = true; resumingHousehold = true; store.save(snapshot) }
    func resume() { suspended = false; reconcile() }
    /// An explicit incoming shortcut wins even if it arrives before stores open.
    func preferIncomingLink() {
        snapshot = .empty; selection = .shop; publishPaths(shop: [], dinners: [], records: []); store.save(snapshot)
    }
    func reconcile() {
        guard !suspended, let household, let access else { return }
        if let role = household.projection?.role, !["shopper", "organizer"].contains(role) {
            snapshot = .empty; selection = .shop; publishPaths(shop: [], dinners: [], records: []); store.save(snapshot)
            sawLiveHousehold = true; return
        }
        let live = contextualScope(household)
        let lostLiveScope = sawLiveHousehold && (household.identity == nil || (live == nil && !resumingHousehold))
        if live != nil { sawLiveHousehold = true; resumingHousehold = false }
        var visible: [AdultTab: [RestorableDestination]] = [:]
        var changed = false
        for tab in AdultTab.allCases {
            var allowed: [RestorableDestination] = []
            for (index, savedRoute) in snapshot[tab].enumerated() {
                var route = savedRoute
                // Opening Start pickup before a shop exists becomes a concrete
                // shop locator as soon as the first durable draft is committed.
                if case .shoppingList(let actor, let workspace, nil) = route,
                   actor == access.localActorID, ledger?.sourceWorkspaceID == workspace,
                   let id = ledger?.shop?.id {
                    route = .shoppingList(actorID: actor, workspaceID: workspace, shopID: id)
                    snapshot[tab][index] = route; changed = true
                }
                let result = validation(route, lostLiveScope: lostLiveScope)
                if result == .invalid {
                    snapshot[tab] = Array(snapshot[tab].prefix(index)); changed = true; break
                }
                guard result == .allowed, access.unlocked else { break }
                allowed.append(route)
            }
            visible[tab] = allowed
        }
        publishPaths(shop: visible[.shop] ?? [], dinners: visible[.dinners] ?? [], records: visible[.records] ?? [])
        if changed { store.save(snapshot) }
    }
    private func householdScopeWillChange() {
        guard sawLiveHousehold, !suspended, !resumingHousehold else { return }
        // This hook runs before sign-out, revocation or a new enrollment clears
        // the live projection. Persist invalidation before any network await.
        func localPrefix(_ path: [RestorableDestination]) -> [RestorableDestination] {
            Array(path.prefix { route in if case .household = route { return false }; return true })
        }
        for tab in AdultTab.allCases { snapshot[tab] = localPrefix(snapshot[tab]) }
        publishPaths(shop: localPrefix(shopPath), dinners: localPrefix(dinnersPath), records: localPrefix(recordsPath))
        store.save(snapshot)
    }
    private enum Validation: Equatable { case allowed, waiting, invalid }
    private func validation(_ route: RestorableDestination, lostLiveScope: Bool) -> Validation {
        guard let access, let household else { return .waiting }
        switch route {
        case .shoppingList(let actor, let workspace, let shop):
            guard actor == access.localActorID else { return .invalid }
            guard let ledger, !ledger.hasPendingLedgerDeletion else { return .invalid }
            guard ledger.ready else { return .waiting }
            guard ledger.sourceWorkspaceID == workspace, ledger.shop?.id == shop,
                  shop == nil || ledger.workspace.shops.contains(where: { $0.id == shop }) else { return .invalid }
            return .allowed
        case .comparison(let actor, let workspace, let id):
            guard actor == access.localActorID else { return .invalid }
            guard let app, app.ready, app.hasLoadedRecords, app.error == nil else { return .waiting }
            guard app.store?.workspaceID == workspace,
                  let record = app.records.first(where: { $0.id == id }), (try? app.decode(record)) != nil else { return .invalid }
            return .allowed
        case .household(let destination, let identity):
            guard destination != .composer, !lostLiveScope else { return .invalid }
            if let subject = household.identity?.subject, subject != identity.subject { return .invalid }
            guard let scope = contextualScope(household) else { return .waiting }
            guard identity.matches(scope), scope.permits(destination) else { return .invalid }
            return .allowed
        }
    }
    private func publishPaths(shop: [RestorableDestination], dinners: [RestorableDestination], records: [RestorableDestination]) {
        if shopPath != shop { shopPath = shop }
        if dinnersPath != dinners { dinnersPath = dinners }
        if recordsPath != records { recordsPath = records }
    }
}
