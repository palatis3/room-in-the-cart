import CoreDomain
import SwiftUI
import DeviceSurfaces

private struct PrivatePantryRetryKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
extension EnvironmentValues {
    var privatePantryRetry: (@MainActor () -> Void)? {
        get { self[PrivatePantryRetryKey.self] }
        set { self[PrivatePantryRetryKey.self] = newValue }
    }
}

#if DEBUG && (CONTRIBUTOR_CAPTURE_UI_FIXTURE || DINNER_DECISION_UI_FIXTURE)
// The dedicated test build supplies its isolated @main from UITestSupport.
#else
@main struct RoomInTheCartApp: App {
    @UIApplicationDelegateAdaptor private var notificationDelegate: SurfaceNotificationDelegate
    init() {
        #if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
        RITCAppCaptureProbe.install()
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), args.contains("--test-shopping-add-intent") {
            Task { @MainActor in
                let intent = AddGroceryItemIntent()
                intent.wording = "2 kg rice"
                _ = try? await intent.perform()
            }
        }
        #endif
        // Keep inactive navigation labels legible against both system bar appearances.
        UITabBar.appearance().unselectedItemTintColor = UIColor(named: "secondary") ?? .secondaryLabel
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if Set(["--ui-testing", "--household-trip-fixture"]).isSubset(of: ProcessInfo.processInfo.arguments) {
                HouseholdTripFixture(notificationDelegate: notificationDelegate)
            } else if Set(["--ui-testing", "--meal-language-fixture"]).isSubset(of: ProcessInfo.processInfo.arguments) {
                MealLanguageFixture()
            } else { primaryWindow }
            #else
            primaryWindow
            #endif
        }
    }

    @ViewBuilder private var primaryWindow: some View {
        if #available(iOS 26.2, *), Bundle.main.object(forInfoDictionaryKey: "RITCRegionalAgeCheckEnabled") as? String == "YES" {
            RegionalAgeCheckWindow { approvedURL in
                GroceryWindow(notificationDelegate: notificationDelegate, approvedURL: approvedURL)
            }
        } else {
            GroceryWindow(notificationDelegate: notificationDelegate)
        }
    }
}

#endif

@MainActor private final class PrivatePantryRuntime: ObservableObject {
    static let mutationGate = PantryMutationGate()
    private var identity: CapturePrivateIdentity?
    private var generation = UUID()

    func update(_ next: CapturePrivateIdentity?) {
        if identity != next { identity = next; generation = UUID() }
    }

    func authorization(for adult: CapturePrivateIdentity, access: WorkspaceAccess, household: HouseholdModel,
                       child: GuardianChildCoordinator) -> @MainActor () -> Bool {
        let original = generation
        return { [weak self, weak access, weak household, weak child] in
            guard let self, let access, let household, let child else { return false }
            return self.identity == adult && self.generation == original && !child.presented &&
                household.projection?.grantId == nil && CapturePrivateIdentity.current(access: access, household: household) == adult
        }
    }
}

/// Observe activation in the window that receives widget and shortcut URLs.
struct GroceryWindow: View {
    let notificationDelegate: SurfaceNotificationDelegate
    @StateObject private var model = AppModel()
    @StateObject private var ledger = LedgerModel(inventoryProjectionsEnabled: true, mutationGate: PrivatePantryRuntime.mutationGate, usesLivePantry: true)
    @StateObject private var pickup = PickupModel(mutationGate: PrivatePantryRuntime.mutationGate, usesLivePantry: true)
    @StateObject private var household: HouseholdModel

    private let approvedURL: Binding<URL?>?
    init(notificationDelegate: SurfaceNotificationDelegate, household: HouseholdModel? = nil, approvedURL: Binding<URL?>? = nil) {
        self.approvedURL = approvedURL
        self.notificationDelegate = notificationDelegate
        _household = StateObject(wrappedValue: household ?? HouseholdModel())
    }
    @StateObject private var access = WorkspaceAccess()
    @StateObject private var membership = MembershipCoordinator()
    @StateObject private var surfaces = DeviceSurfacesComposition()
    @StateObject private var navigation = NavigationRestorationModel()
    @StateObject private var guardianChild = GuardianChildCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pantryRuntime = PrivatePantryRuntime()
    private enum PermissionScope: Equatable {
        case pantry(PantryVoicePromptScope)
        case recipeCamera(RecipeCameraPromptScope)
    }
    @StateObject private var permissionWindow = SystemPermissionWindow<PermissionScope>()
    @State private var pantryOpenAttempt = UUID()
    @State private var failedPantryScope: PantryOpenScope?
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var recoveryFixture = PrivatePickupRecoveryFixture()
    #endif
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Group {
            if scenePhase != .active && access.isProtected && !retainsPermissionPrompt {
                Theme.canvas.ignoresSafeArea()
            } else {
                root
                    .opacity(retainsPermissionPrompt ? 0 : 1)
                    .allowsHitTesting(!retainsPermissionPrompt)
                    .accessibilityHidden(retainsPermissionPrompt)
                    .background { if retainsPermissionPrompt { PantryVoicePrivacyCover() } }
            }
        }.environment(\.pantryVoicePrompt, PantryVoicePromptAccess(holdsPresentation: {
            UIApplication.shared.applicationState != .background && permissionWindow.holdsPresentation(voicePromptScope.map(PermissionScope.pantry))
        }, begin: {
            guard let scope = voicePromptScope, pickup.pantryRouteAvailable else { return nil }
            return permissionWindow.begin(.pantry(scope), phase: scenePhase)
        }, nextPermission: { permissionWindow.nextPermission($0) },
           ready: { permissionWindow.recognitionReady($0, appActive: UIApplication.shared.applicationState == .active) },
           cancel: { permissionWindow.cancel($0) }))
        .modifier(DinnerPrepAlertRuntime(ledger: ledger, pickup: pickup, access: access, household: household, child: guardianChild))
        .modifier(PantryDigestRuntime(pickup: pickup, ledger: ledger, access: access, household: household, child: guardianChild,
                                      retainedScope: { retainedPantryDigestScope }))
            .environment(\.pantryDigestPermissionPrompt, digestPermissionPrompt)
            .environment(\.recipeCameraPermissionPrompt, recipeCameraPermissionPrompt)
            .environment(\.pickupLedger, ledger)
            .environment(\.offersDuplicateAssistance, true)
            .environment(\.privatePantryRetry, pantryRetry)
            .environmentObject(model)
            .environmentObject(ledger).environmentObject(pickup)
            .environmentObject(household).environmentObject(access)
            .environmentObject(membership).environmentObject(surfaces).environmentObject(navigation)
            .environmentObject(guardianChild)
            .environment(\.guardianChildCoordinator, guardianChild)
            .tint(Theme.action)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .task {
                if guardianChild.presented {
                    guardianChild.enforcePrivacyBoundary(adult: household, access: access, surfaces: surfaces)
                } else if !access.unlocked { surfaces.background() }
                navigation.bind(app: model, ledger: ledger, household: household, access: access)
                pickup.bindCookLedger(ledger)
                membership.bind(to: household)
                surfaces.bind(ledger: ledger, pickup: pickup, household: household, access: access,
                              sceneActive: scenePhase == .active && !guardianChild.presented)
                let child = guardianChild, routing = navigation, deviceSurfaces = surfaces
                notificationDelegate.bind { [weak child, weak routing, weak deviceSurfaces] handle in
                    guard child?.presented == false else { return }
                    routing?.preferIncomingLink()
                    deviceSurfaces?.receiveReminderTap(handle)
                }
                if guardianChild.presented { await guardianChild.resume() }
                else { await openAdultWorkspace() }
            }
            .modifier(GroceryURLDelivery(approvedURL: approvedURL) { url in
                guard !guardianChild.presented else { return }
                navigation.preferIncomingLink(); surfaces.handle(url: url)
            })
            .sheet(item: Binding(get: { scenePhase == .active && !guardianChild.presented ? surfaces.destination : nil },
                                 set: { surfaces.destination = $0 })) { destination in
                NavigationStack {
                    DeviceSurfacesDestination(composition: surfaces, destination: destination,
                                              ledger: ledger, pickup: pickup, household: household)
                }.environment(\.pickupLedger, ledger)
                    .environment(\.guardianChildCoordinator, guardianChild)
                    .environmentObject(model)
                    .environmentObject(ledger).environmentObject(pickup)
                    .environmentObject(household).environmentObject(access)
                    .environmentObject(membership).environmentObject(surfaces).environmentObject(navigation)
            }
            .modifier(HouseholdWorkspaceProtection(household: household, access: access))
            .onChange(of: privatePantryIdentity) { previous, identity in
                pantryRuntime.update(identity)
                if previous != nil { pickup.suspendPrivatePantry() }
            }
            .task(id: scenePhase) {
                if scenePhase == .active { try? await PrivateReceiptInbox.expireOnForeground() }
            }
            .task(id: scenePhase == .active ? membership.model?.renewal : nil) {
                guard scenePhase == .active, let model = membership.model, let renewal = model.renewal else { return }
                await model.renewWhileActive(renewal)
            }
            .task(id: pantryOpenScope) { await openPrivatePantry(pantryOpenScope) }
            .onChange(of: household.deviceReminderPersona) { _, _ in surfaces.scopeChanged() }
            .onChange(of: guardianChild.presented) { _, childActive in
                if childActive {
                    navigation.suspend()
                    guardianChild.enforcePrivacyBoundary(adult: household, access: access, surfaces: surfaces)
                }
            }
            .onChange(of: access.unlocked) { _, unlocked in
                if unlocked && !guardianChild.presented { Task { await openAdultWorkspace() } }
            }
            .onChange(of: scenePhase) { _, phase in
                permissionWindow.sceneChanged(phase)
                if phase == .background {
                    guardianChild.suspend()
                    navigation.suspend(); surfaces.background(); access.background(); household.lock()
                }
                if phase == .active {
                    if guardianChild.presented {
                        guardianChild.enforcePrivacyBoundary(adult: household, access: access, surfaces: surfaces)
                        Task { await guardianChild.resume() }
                    } else {
                        navigation.resume(); membership.foreground()
                        Task { await openAdultWorkspace() }
                    }
                }
            }
    }
    @ViewBuilder private var root: some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--receipt-file-source-fixture") {
            ReceiptFileSourceFixture()
        } else if recoveryFixture.requested && recoveryFixture.phase != .ready {
            if recoveryFixture.phase == .failed { Text(verbatim: "Recovery fixture setup failed") }
            else { ProgressView() }
        } else { RootView() }
        #else
        RootView()
        #endif
    }

    private var voicePromptScope: PantryVoicePromptScope? {
        guard UIApplication.shared.isProtectedDataAvailable, !guardianChild.presented, household.projection?.grantId == nil,
              let adult = CapturePrivateIdentity.current(access: access, household: household),
              let origin = pickup.sourceWorkspaceID, let ledgerOrigin = ledger.sourceWorkspaceID, !ledger.hasPendingLedgerDeletion else { return nil }
        // Inventory and the shopping ledger have independent database origins.
        return PantryVoicePromptScope(adult: adult, origin: origin, ledger: ledgerOrigin, generation: pickup.privatePantryGeneration)
    }

    private var digestPermissionPrompt: PantryDigestPermissionPrompt? {
        guard let original = voicePromptScope else { return nil }
        return PantryDigestPermissionPrompt(scope: .init(origin: original.origin, identity: original.adult)) { request in
            try await permissionWindow.request(in: .pantry(original), phase: scenePhase,
                currentScope: { voicePromptScope.map(PermissionScope.pantry) }, appActive: { UIApplication.shared.applicationState == .active },
                request: request)
        }
    }

    private var recipeCameraScope: RecipeCameraPromptScope? {
        .current(ledger: ledger, access: access, household: household, childPresented: guardianChild.presented)
    }

    private var recipeCameraPermissionPrompt: RecipeCameraPermissionPrompt? {
        guard let original = recipeCameraScope else { return nil }
        return RecipeCameraPermissionPrompt(scope: original, present: { request in
            try await permissionWindow.request(in: .recipeCamera(original), phase: scenePhase,
                currentScope: { recipeCameraScope.map(PermissionScope.recipeCamera) },
                appActive: { UIApplication.shared.applicationState == .active }, request: request)
        }, holdsPresentation: {
            UIApplication.shared.applicationState != .background && recipeCameraScope == original &&
                permissionWindow.holdsPresentation(.recipeCamera(original))
        })
    }

    private var retainsPermissionPrompt: Bool {
        guard permissionWindow.token != nil, scenePhase == .inactive else { return false }
        return permissionWindow.retains(voicePromptScope.map(PermissionScope.pantry), phase: scenePhase) ||
            permissionWindow.retains(recipeCameraScope.map(PermissionScope.recipeCamera), phase: scenePhase)
    }

    private var retainedPantryDigestScope: PantryDigestScope? {
        guard let scope = voicePromptScope, permissionWindow.retains(.pantry(scope), phase: scenePhase) else { return nil }
        return .init(origin: scope.origin, identity: scope.adult)
    }

    private var privatePantryIdentity: CapturePrivateIdentity? {
        guard scenePhase == .active || retainsPermissionPrompt, !guardianChild.presented, household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }

    private struct PantryOpenScope: Equatable {
        let adult: CapturePrivateIdentity?
        let ledgerReady: Bool
        let ledgerOrigin: UUID?
        let attempt: UUID
    }
    private var pantryOpenScope: PantryOpenScope {
        PantryOpenScope(adult: privatePantryIdentity, ledgerReady: ledger.ready, ledgerOrigin: ledger.sourceWorkspaceID, attempt: pantryOpenAttempt)
    }
    private var pantryRetry: (@MainActor () -> Void)? {
        guard let failed = failedPantryScope, failed == pantryOpenScope, failed.adult != nil,
              !ledger.hasPendingLedgerDeletion, !pickup.pantryRestartAvailable, !pickup.pantryCleanupPending else { return nil }
        return {
            guard failed == pantryOpenScope, privatePantryIdentity == failed.adult else { return }
            failedPantryScope = nil
            pantryOpenAttempt = UUID()
        }
    }
    private func recordPantryFailure(_ expected: PantryOpenScope) {
        guard !Task.isCancelled, expected == pantryOpenScope, expected.adult != nil,
              !ledger.hasPendingLedgerDeletion, !pickup.pantryRestartAvailable, !pickup.pantryCleanupPending else { return }
        failedPantryScope = expected
    }
    @MainActor private func openPrivatePantry(_ scope: PantryOpenScope) async {
        guard !Task.isCancelled else { return }
        failedPantryScope = nil
        pantryRuntime.update(scope.adult)
        guard let identity = scope.adult else { return }
        Diagnostics.record(.pantryScopeEntered)
        if !scope.ledgerReady {
            if !ledger.hasPendingLedgerDeletion { await ledger.open() }
            if !ledger.ready && !ledger.opening {
                Diagnostics.record(.pantryLedgerOpeningFailed)
                recordPantryFailure(scope)
            }
            return  // Publishing ready starts a new task bound to the opened ledger.
        }
        let current = pantryRuntime.authorization(for: identity, access: access, household: household, child: guardianChild)
        let prompt = permissionWindow
        let authorize = { @MainActor in
            current() && prompt.allowsPantryAction(appActive: UIApplication.shared.applicationState == .active)
        }
        guard authorize(), !Task.isCancelled, ledger.sourceWorkspaceID == scope.ledgerOrigin else { return }
        do {
            let persona = ReceiptAcquisition.identity(["private-receipt-aliases", identity.actorID.uuidString,
                identity.subject ?? "", identity.householdID ?? "", identity.memberID ?? ""])
            try await pickup.bindPrivatePantry(ledger: ledger, receiptAliasPersona: persona,
                privateDinnerActorID: identity.subject == nil && identity.householdID == nil ? identity.actorID : nil, authorize: authorize)
            if !pickup.ready { await pickup.load() }
            if pickup.pantryRouteAvailable { Diagnostics.record(.pantryRouteReady) }
            else if !pickup.pantryRestartAvailable {
                Diagnostics.record(.pantryRouteUnavailable)
                recordPantryFailure(scope)
            }
            #if DEBUG && targetEnvironment(simulator)
            if authorize() { await recoveryFixture.prepare(ledger: ledger, pickup: pickup) }
            #endif
        } catch {
            guard authorize(), !Task.isCancelled else { return }
            recordPantryFailure(scope)
            Diagnostics.record(.pantryBindingUnavailable)
            pickup.error = pTr("Could not open saved pickups. Retry; existing records have not been replaced.")
        }
    }

    @MainActor private func openAdultWorkspace() async {
        guard scenePhase == .active, !guardianChild.presented, access.unlocked else { return }
        if !model.ready { await model.open() }
        guard !guardianChild.presented, access.unlocked else { return }
        if !ledger.ready { await ledger.open() }
        guard scenePhase == .active, !guardianChild.presented, access.unlocked else { return }
        navigation.resume()
        await surfaces.foreground()
    }
}

struct RootView: View {
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var access: WorkspaceAccess
    @Environment(\.guardianChildCoordinator) private var guardianChild
    var body: some View {
        if let guardianChild {
            GuardianBoundaryRoot(coordinator: guardianChild) { adultRoot }
        } else { adultRoot }
    }
    @ViewBuilder private var adultRoot: some View {
        if household.usesScopedHouseholdRoot {
            NavigationStack { HouseholdSettingsView(model: household) }
        } else if !access.unlocked {
            WorkspaceUnlockView(access: access, household: household, childExitNotice: guardianChild?.message)
        } else { tabs }
    }
    private var tabs: some View { RestorableAdultTabs() }
}

private struct GuardianBoundaryRoot<AdultRoot: View>: View {
    @ObservedObject var coordinator: GuardianChildCoordinator
    let adultRoot: () -> AdultRoot
    var body: some View {
        if coordinator.presented { GuardianChildRootView(coordinator: coordinator) }
        else { adultRoot() }
    }
}

private extension PickupModel {
    var pantryCleanupPending: Bool {
        guard let stores = pantryErasureStores else { return false }
        return PantryErasureCoordinator.hasPendingCleanup(in: stores.configuration.erasureJournalDirectory,
                                                         originID: stores.inventory.workspaceID)
    }
}

/// A tab can be selected while the private stores are opening or the pantry is retired.
struct AdultPantryTab: View {
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.pantryVoicePrompt) private var voicePrompt
    @Environment(\.privatePantryRetry) private var retry

    var body: some View {
        Group {
            if pickup.pantryRouteAvailable || voicePrompt?.holdsPresentation() == true {
                PantrySetupView(pickup: pickup, ledger: ledger)
            } else if pickup.pantryRestartAvailable {
                WorkingForm { PantryRestartButton(pickup: pickup) }
                    .navigationTitle(quickGroceryText("Pantry"))
            } else if let retry {
                WorkingForm {
                    Button(pantryText("Retry opening My Pantry"), action: retry)
                        .accessibilityIdentifier("pantry.retryOpen")
                }.navigationTitle(quickGroceryText("Pantry"))
            } else if household.projection?.grantId == nil,
                      CapturePrivateIdentity.current(access: access, household: household) != nil {
                if ledger.hasPendingLedgerDeletion || pickup.pantryCleanupPending {
                    WorkingForm {
                        Text(quickGroceryText("Finish the pending cleanup in Records to reopen this workspace."))
                        RecordsRecoveryLink(accessibilityID: "pantry.recovery")
                    }.navigationTitle(quickGroceryText("Pantry"))
                } else {
                    ProgressView(quickGroceryText("Opening Pantry…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas).navigationTitle(quickGroceryText("Pantry"))
                }
            } else {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
                    .foregroundStyle(Theme.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvas).navigationTitle(quickGroceryText("Pantry"))
            }
        }
    }
}

struct ShopView: View {
    @Environment(\.privatePantryRetry) private var retryPrivatePantry
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var surfaces: DeviceSurfacesComposition
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var navigation: NavigationRestorationModel
    private struct InStoreSelection: Identifiable { let id: UUID }
    @State private var inStoreShop: InStoreSelection?
    @State private var shopWithListLink: UUID?
    private static let moreToolsID = "shop.moreTools"
    @State private var showingSettings = false
    @State private var showingMoreTools = false
    @State private var showingStandingList = false
    @State private var showingFirstList = false
    @State private var showingPantry = false
    @Environment(\.pantryVoicePrompt) private var pantryVoicePrompt
    @EnvironmentObject private var pickup: PickupModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                shopContent
                    .onChange(of: showingMoreTools) { _, expanded in
                        if expanded { reader.scrollTo(Self.moreToolsID, anchor: .top) }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Reserve space above bottom navigation while the scroll view
            // takes its size directly from the available navigation content.
            Theme.canvas.frame(height: 8)
                .background(Theme.canvas.ignoresSafeArea(edges: .bottom))
                .accessibilityHidden(true)
        }.workingSurface().navigationTitle(tr("Shop")).navigationBarTitleDisplayMode(.inline)
            .settingsButton(presentation: $showingSettings)
            .task { await model.refresh() }
            .sheet(item: $inStoreShop) { shop in
                PrivateShoppingSheet(model: ledger) {
                    InStoreShoppingView(model: ledger, shopID: shop.id) { selected in
                        guard inStoreShop?.id == shop.id, navigation.selection == .shop,
                              navigation.shopPath.isEmpty, let workspace = ledger.sourceWorkspaceID else { return }
                        inStoreShop = nil
                        navigation.setPath([.shoppingList(actorID: access.localActorID, workspaceID: workspace, shopID: selected)], for: .shop)
                    }
                }
            }
            .sheet(isPresented: $showingPantry) {
                NavigationStack {
                    PantrySetupView(pickup: pickup, ledger: ledger)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(ht("Close")) { showingPantry = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingStandingList) {
                PrivateShoppingSheet(model: ledger) { StandingListView(model: ledger) }
            }
            .sheet(isPresented: $showingFirstList) {
                NavigationStack {
                    FirstListEntry(model: ledger, opensListAfterSave: true) { id in
                        guard access.unlocked, ledger.shop?.id == id, let workspace = ledger.sourceWorkspaceID else { return }
                        showingFirstList = false
                        navigation.setPath([.shoppingList(actorID: access.localActorID, workspaceID: workspace, shopID: id)], for: .shop)
                    }
                }
            }
    }
    private func pickupDestination<Content: View>(_ id: UUID, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if pickup.selectedID == id { content() }
            else { ProgressView() }
        }
        .onAppear { pickup.selectedID = id }
    }

    private var canReviewCheckout: Bool {
        guard ledger.ready, !ledger.hasPendingLedgerDeletion else { return false }
        guard let shop = ledger.shop,
              let journey = pickup.journeys.first(where: { $0.id == shop.id }) else { return true }
        return journey.closedAt == nil && (journey.basket == nil || journey.basket?.phase == .draft)
    }

    private var shopContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    LedgerQuickGroceryEntry(model: ledger, prominent: true)
                        .onPreferenceChange(ShopListLinkProvided.self) { shopWithListLink = $0 }
                    if let shop = ledger.shop, shopWithListLink != shop.id {
                        RestorableShoppingListLink {
                            Label(quickGroceryText("View shopping list"), systemImage: "list.bullet").frame(minHeight: 44)
                        }
                    }
                    Label(quickGroceryText("Private on this iPhone"), systemImage: "lock")
                        .font(.footnote).foregroundStyle(Theme.secondary)
                    if ledger.shop == nil {
                        Text(quickGroceryFormat("Add a grocery to start your “%@” list. Works offline without an account.", ledgerText("Pickup")))
                            .accessibilityIdentifier("quickGrocery.firstDestination")
                            .font(.footnote).foregroundStyle(Theme.secondary)
                    }
                }
                tripSummary
                shopTools
                if let saved = [ledger.savedAt, pickup.journeys.first?.savedAt, model.records.first?.savedAt].compactMap({ $0 }).max() {
                    Text(tr("Last local save") + " · " + saved.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(Theme.secondary).accessibilityIdentifier("shop.localSave")
                }
                if !household.locked, let shared = household.sharedShop { ShopSyncStatus(model: shared) }
                FamilyInboxContextLink()
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.error)
                    Button(tr("Try again")) { Task { await model.open(); await model.refresh() } }.frame(minHeight: 44)
                }
                if !model.records.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Pick up where you left off")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(model.records.prefix(5), id: \.id) { record in
                            SavedRow(record: record)
                            Divider()
                        }
                    }
                }
            }.frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.vertical, 16)
        }.accessibilityIdentifier("shopContentScroll")
    }

    @ViewBuilder private var tripSummary: some View {
        if let shop = ledger.shop {
            if !shop.basis.branch.isEmpty {
                Label(shop.basis.branch, systemImage: "storefront").font(.headline)
            }
            if let slot = shop.basis.slot, let zone = TimeZone(identifier: shop.basis.timeZoneIdentifier) {
                Text(slot.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)) + " · " + zone.identifier)
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            if let closed = pickup.journeys.first(where: { $0.id == shop.id })?.closedAt {
                Text(pTr("Closed") + " · " + closed.formatted(date: .abbreviated, time: .shortened))
            } else if let journey = pickup.resumableJourney(for: shop.id) {
                if shop.basis.slot == nil, let slot = journey.context?.slot, !slot.isEmpty {
                    Text(pTr("Pickup or delivery slot") + " · " + slot).font(.subheadline)
                }
                tripAction(journey, shop: shop)
            } else { resumeList(shop) }
        } else if let journey = pickup.resumableJourney(for: nil), !journey.offers.isEmpty {
            tripAction(journey, shop: nil)
        }
    }

    private func tripAction(_ journey: PickupJourney, shop: ShoppingLedger?) -> some View {
        let now = Date()
        let changes = journey.offers.map(\.deadline.cutoff) + (journey.pickup?.receipts.map(\.receivedAt) ?? [])
        return TimelineView(.explicit([now] + changes.filter { $0 > now }.sorted())) { context in
            if let offer = journey.nextUnfilledOffer(at: context.date) {
                let expired = context.date >= offer.deadline.cutoff
                VStack(alignment: .leading, spacing: 8) {
                    Text(pTr(expired ? "Await pickup · fill still unknown" : "Decision pending before cutoff"))
                        .font(.headline).accessibilityIdentifier("shop.resumeOfferStatus")
                    Text(offer.replacement)
                    Text(pTr("Cutoff") + " · " + pickupOfferCutoffText(offer) + " · " + offer.deadline.timeZoneID)
                        .accessibilityIdentifier("shop.resumeOfferCutoff")
                    NavigationLink(pTr(expired ? "Record what came home" : "Review a store offer")) {
                        pickupDestination(journey.id) {
                            if expired { PickupArrivalView(model: pickup) }
                            else { PickupOfferView(model: pickup) }
                        }
                    }.buttonStyle(PrimaryAction()).accessibilityIdentifier("shop.resumeOffer")
                }
            } else if journey.basket?.phase == .frozen {
                VStack(alignment: .leading, spacing: 4) {
                    NavigationLink(pTr("Prepare retailer handoff")) {
                        pickupDestination(journey.id) { PickupHandoffView(model: pickup, shopID: journey.id) }
                    }.buttonStyle(PrimaryAction())
                }
            } else if journey.shouldResumeArrival(at: context.date) {
                VStack(alignment: .leading, spacing: 4) {
                    NavigationLink(pTr("Record what came home")) {
                        pickupDestination(journey.id) { PickupArrivalView(model: pickup) }
                    }.buttonStyle(PrimaryAction())
                }
            } else if let shop, journey.basket?.phase != .reportedPlaced {
                resumeList(shop)
            }
        }
    }

    @ViewBuilder private func resumeList(_ shop: ShoppingLedger) -> some View {
        if shop.lines.contains(where: { $0.isChecked && !$0.isHandled && !$0.isTrashed }),
           shop.lines.contains(where: { !$0.isChecked && !$0.isHandled && !$0.isTrashed }) {
            Button(quickGroceryText("Resume picking")) { inStoreShop = InStoreSelection(id: shop.id) }
                .buttonStyle(PrimaryAction()).accessibilityIdentifier("shop.resumePicking")
        }
    }

    private var shopTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ledger.shop == nil {
                VStack(alignment: .leading, spacing: 0) {
                    Button { showingFirstList = true } label: { ShopToolLabel(ledgerText("Add several items"), "text.badge.plus", chevron: true) }
                        .disabled(ledger.firstListStore == nil || ledger.saving || ledger.hasPendingSave)
                        .accessibilityIdentifier("shop.addFirstList")
                    Divider()
                    NavigationLink { NewComparisonDestination() } label: { ShopToolLabel(tr("Compare packs"), "arrow.left.arrow.right", chevron: true) }
                        .accessibilityIdentifier("newComparison")
                    Divider()
                    RestorableShoppingListLink { ShopToolLabel(ledgerText("Start pickup"), "cart", chevron: true) }
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }
                DisclosureGroup(isExpanded: $showingMoreTools) { secondaryShopTools } label: {
                    Text(quickGroceryText("More shopping tools")).font(.headline)
                }
                .disclosureGroupStyle(LabeledFormDisclosureStyle(label: quickGroceryText("More shopping tools"), identifier: Self.moreToolsID))
                .id(Self.moreToolsID)
            } else {
                Text(quickGroceryText("Shopping tools")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                secondaryShopTools
                FirstListResumeButton(model: ledger, showingEditor: showingFirstList) { showingFirstList = true }
            }
        }
    }

    private var secondaryShopTools: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showingSettings = true } label: {
                ShopToolLabel(quickGroceryText("Household settings"), "person.2", chevron: true)
            }
            .accessibilityIdentifier("shop.familySharing")
            if ledger.shop == nil {
                Button { showingStandingList = true } label: { ShopToolLabel(shoppingText("Standing list"), "list.star") }
                    .disabled(!ledger.ready).accessibilityIdentifier("shop.standingList")
            } else {
                NavigationLink { NewComparisonDestination() } label: { ShopToolLabel(tr("Compare packs"), "arrow.left.arrow.right") }
                    .accessibilityIdentifier("newComparison")
            }
            if canReviewCheckout {
                NavigationLink { CheckOneChangeView() } label: {
                    ShopToolLabel(ledger.shop == nil ? CheckOneChangeView.title : tr("Review checkout"), "cart")
                }.accessibilityIdentifier("shop.checkOneChange")
            }
            NavigationLink { UrgentRepairView(model: pickup).environment(\.pickupLedger, ledger) } label: {
                ShopToolLabel(tr("Something is missing"), "basket")
            }.accessibilityIdentifier("urgentRepairShortcut")
            pantryShortcut
            NavigationLink { DeviceSurfacesEntry(composition: surfaces) } label: {
                ShopToolLabel(SurfaceCopy.text("Device shortcuts"), "iphone")
            }.accessibilityIdentifier("deviceShortcuts")
            if !pickup.journeys.isEmpty {
                NavigationLink { PickupHomeView(model: pickup).environment(\.pickupLedger, ledger) } label: {
                    ShopToolLabel(tr("Pickup, repairs and handoffs"), "shippingbox")
                }
            }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var pantryShortcut: some View {
        if pickup.pantryRouteAvailable || pantryVoicePrompt?.holdsPresentation() == true {
            if #available(iOS 18, *), household.projection?.canBrowseHouseholdTonight != true {
                NavigationLink { PantrySetupView(pickup: pickup, ledger: ledger) } label: {
                    ShopToolLabel(pantryText("My Pantry"), "cabinet")
                }.accessibilityIdentifier("shop.myPantry")
            } else {
                // iOS 17 needs a separate presentation when Shop observes pantry setup.
                Button { showingPantry = true } label: { ShopToolLabel(pantryText("My Pantry"), "cabinet") }
                    .accessibilityIdentifier("shop.myPantry")
            }
        } else if pickup.pantryRestartAvailable {
            PantryRestartButton(pickup: pickup)
        } else if let retryPrivatePantry {
            Button(pantryText("Retry opening My Pantry"), action: retryPrivatePantry)
                .frame(minHeight: 44).accessibilityIdentifier("shop.retryMyPantry")
        }
    }
}

private struct ShopToolLabel: View {
    let title: String
    let symbol: String
    let chevron: Bool
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, _ symbol: String, chevron: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.chevron = chevron
    }
    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.body.weight(.medium))
            if chevron {
                Spacer(minLength: 4)
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary).accessibilityHidden(true)
            }
        }.foregroundStyle(enabled ? Theme.action : Theme.secondary)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: max(44, rowHeight), alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct ShopSyncStatus: View {
    @ObservedObject var model: HouseholdShopModel
    var body: some View {
        if model.authorized, let date = model.lastShopSync {
            Text(tr("Last shared shop sync") + " · " + date.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote).accessibilityIdentifier("shop.householdSync")
        }
    }
}

import LocalStore
struct SavedRow: View {
    @EnvironmentObject private var model: AppModel
    let record: SavedComparison
    var body: some View {
        RestorableSavedComparisonLink(record: record) {
            VStack(alignment: .leading, spacing: 8) {
                Text(record.title.isEmpty ? tr("One item") : record.title).font(.headline).foregroundStyle(Theme.ink)
                Text(tr("Saved on this iPhone")).font(.subheadline).foregroundStyle(Theme.secondary)
                Text(record.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(Theme.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.accessibilityIdentifier("savedComparison")
    }
}

struct RecordsView: View {
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var ledger: LedgerModel
    private var hasSharedRecordsAccess: Bool {
        guard !household.locked, household.identity != nil, household.service != nil,
              let scope = household.projection, scope.enrolled, scope.grantId == nil else { return false }
        return ["organizer", "shopper", "contributor"].contains(scope.role)
    }

    var body: some View {
        JournalList {
            if model.hasLoadedRecords, model.error == nil, let recent = model.records.first {
                Section(recordsText("Latest saved comparison")) {
                    SavedRow(record: recent)
                        .privacySensitive()
                }
            }
            Section {
                if pickup.pantryRouteAvailable {
                    NavigationLink {
                        PantrySetupView(pickup: pickup, ledger: ledger, destination: .receipts)
                    } label: {
                        historyLabel(pantryText("Receipt history"),
                                     source: recordsText("Receipts you reviewed on this iPhone"),
                                     symbol: pantryReceiptSymbol)
                    }.accessibilityIdentifier("records.privateReceipts")
                    NavigationLink {
                        PantrySetupView(pickup: pickup, ledger: ledger, destination: .prices)
                    } label: {
                        historyLabel(pantryText("Private price history"),
                                     source: recordsText("Shelf prices, quotes and amounts you recorded"),
                                     symbol: "tag")
                    }.accessibilityIdentifier("records.privatePrices")
                }
                CheckedGroceriesHistoryLink(model: ledger)
                PickupPlacedOrdersLink(model: pickup)
                if pickup.journeys.contains(where: PickupDecisionEvidence.hasRecords) {
                    PickupDecisionsLink(shopID: nil)
                }
                if !hasSharedRecordsAccess && (household.canUnlockPlacementEvidence || household.placementEvidenceUnlocked) {
                    NavigationLink {
                        PlacementRecordsEntryView(household: household)
                    } label: { Label(PlacementCopy.text("Open my saved placement records"), systemImage: "lock.doc") }
                    .accessibilityIdentifier("records.sharedPlacementReports")
                }
                if !pickup.journeys.isEmpty {
                    NavigationLink {
                        PickupHomeView(model: pickup).environment(\.pickupLedger, ledger)
                    } label: { Label(tr("Pickup, repairs and handoffs"), systemImage: "shippingbox") }
                }
            } header: {
                Label(recordsText("On this iPhone"), systemImage: "lock")
                    .marketJournalTitle(.title2).textCase(nil)
            }
            Section(recordsText("Files and recovery")) {
                RecordsRecoveryLink()
            }
            if model.records.count != 1 || !model.hasLoadedRecords || model.error != nil {
                comparisonHistory
            }
            if !model.unavailableRecords.isEmpty {
                Section(tr("Comparisons that need attention")) {
                    ForEach(model.unavailableRecords) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.title.flatMap { $0.isEmpty ? nil : $0 } ?? tr("One item")).font(.headline)
                            Text(tr("This comparison could not be read. Its saved data has been kept. Other comparisons are still available."))
                                .font(.subheadline).foregroundStyle(Theme.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                    Button(tr("Try again")) { Task { await model.refresh() } }.frame(minHeight: 44)
                }
            }
            if hasSharedRecordsAccess, let scope = household.projection {
                Section(ht("Shared pickup records")) {
                    NavigationLink(ht("Find a past shared pickup")) {
                        HouseholdShopSelector(household: household, includingClosed: true)
                    }.accessibilityIdentifier("records.chooseSharedPickup")
                    if scope.shopId != nil {
                        NavigationLink(ht("Open selected shared pickup")) {
                            HouseholdShopView(model: household)
                        }.accessibilityIdentifier("records.sharedPickup")
                    }
                    NavigationLink {
                        PlacementRecordsEntryView(household: household)
                    } label: { Label(PlacementCopy.text("Shared placement reports"), systemImage: "doc.text") }
                    .accessibilityIdentifier("records.sharedPlacementReports")
                    NavigationLink {
                        HistoryRecordsEntryView(household: household)
                    } label: { Label(HistoryCopy.text("Prices and period budgets"), systemImage: "calendar") }
                    .accessibilityIdentifier("records.priceBudgetHistory")
                    if household.decisionAccess != nil {
                        NavigationLink {
                            FamilyDecisionsEntry()
                        } label: { Label(HistoryCopy.text("Family decision history"), systemImage: "person.2") }
                    }
                    ManagedViewsContextLink()
                }
            }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(Theme.error)
                    Button(tr("Try again")) {
                        Task {
                            if model.ready { await model.refresh() }
                            else { await model.open() }
                        }
                    }
                }
            }
        }.navigationTitle(tr("Records")).settingsButton().task { await model.refresh() }
    }

    private func historyLabel(_ title: String, source: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(source).font(.subheadline).foregroundStyle(Theme.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: symbol).accessibilityHidden(true) }
        .padding(.vertical, 3)
    }

    private var comparisonHistory: some View {
        Section(recordsText("Saved comparisons")) {
            if !model.hasLoadedRecords, model.error == nil {
                ProgressView(recordsText("Loading saved comparisons…"))
            } else if model.hasLoadedRecords, model.error == nil, model.records.isEmpty && model.unavailableRecords.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(tr("Your comparisons live here"), systemImage: "scalemass").font(.headline)
                    Text(tr("Save a pack comparison to return to the same amounts and prices, even offline."))
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }.padding(.vertical, 4)
                NavigationLink {
                    NewComparisonDestination()
                } label: { Label(tr("Compare packs"), systemImage: "plus") }
                .accessibilityIdentifier("records.startComparison")
            }
            ForEach(model.records.dropFirst(model.hasLoadedRecords && model.error == nil ? 1 : 0), id: \.id) {
                SavedRow(record: $0).privacySensitive()
            }
        }
    }
}

private struct SettingsButton: ViewModifier {
    let presentation: Binding<Bool>?
    @State private var showingSettings = false

    func body(content: Content) -> some View {
        let presented = presentation ?? $showingSettings
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { presented.wrappedValue = true } label: { Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(tr("Settings")).accessibilityIdentifier("settings")
            }
        }.sheet(isPresented: presented) {
            NavigationStack { SettingsView() }
                .environment(\.returnFromMembershipSettings, { presented.wrappedValue = false })
        }
    }
}
extension View {
    func settingsButton(presentation: Binding<Bool>? = nil) -> some View {
        modifier(SettingsButton(presentation: presentation))
    }
}

struct SettingsView: View {
    @ObservedObject private var feedbackConsent = LocalPickupFeedbackConsent.shared
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var surfaces: DeviceSurfacesComposition
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("appearance") private var appearance = "system"
    @State private var showingFamilyGuide = false
    @State private var dismissSettingsAfterGuide = false
    var body: some View {
        WorkingForm {
            Section {
                NavigationLink {
                    HouseholdSettingsView(model: household, continuesAfterWorkspaceLock: true)
                } label: {
                    Label(tr("Household requests"), systemImage: "list.bullet")
                }
                Button { showingFamilyGuide = true } label: {
                    Label(GuardianCopy.text("Child permissions"), systemImage: "hand.raised")
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("guardian.familyGuide")
                if household.canOpenMembership {
                    NavigationLink { MembershipEntryView(household: household) } label: {
                        Label(tr("Household membership"), systemImage: "person.2")
                    }
                }
                HouseholdPantryLink(household: household)
            } header: {
                Text(tr("Household"))
                    .marketJournalTitle(.title2).textCase(nil)
            }
            Section {
                Picker(tr("Appearance"), selection: $appearance) {
                    Text(tr("System")).tag("system")
                    Text(tr("Light")).tag("light")
                    Text(tr("Dark")).tag("dark")
                }
            }
            Section(tr("Language")) {
                Text(tr("Your iPhone’s app language controls English and Spanish. Saved prices keep their original currency."))
                Button(tr("Open iPhone settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.frame(minHeight: 44)
            }
            if surfaces.privateAuthorized {
                Section(SurfaceCopy.text("Device shortcuts")) {
                    NavigationLink(SurfaceCopy.text("Device shortcuts")) { DeviceSurfacesEntry(composition: surfaces) }
                }
            }
            HelpSettingsSection()
            Section(tr("Your data")) {
                if surfaces.privateAuthorized {
                    RecordsRecoveryLink(accessibilityID: "settings.recovery")
                    CorrectionSettingsLink()
                }
                Toggle(pTr("Offer optional feedback after a pickup"), isOn: Binding(get: { feedbackConsent.enabled(for: pickup.sourceWorkspaceID) }, set: { feedbackConsent.setEnabled($0, for: pickup.sourceWorkspaceID) }))
                Text(pTr("Local feedback stays on this iPhone. Your choice applies only to this local workspace and notice version. Nothing is sent."))
                if household.identity != nil, household.projection?.grantId == nil, !household.locked {
                    NavigationLink(pTr("Optional household measurement")) { MeasurementSettingsView(household: household) }
                }
                Text(tr("Private comparisons and planning stay on this iPhone. Joining a household does not upload existing work."))
            }
            #if DEBUG
            Section(tr("Development")) { NavigationLink(tr("Component gallery")) { ComponentGallery() } }
            #endif
        }.navigationTitle(tr("Settings"))
            .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .automatic)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
            // Keep the self-sizing guide out of the Settings navigation push on compact iOS.
            .sheet(isPresented: $showingFamilyGuide, onDismiss: {
                if dismissSettingsAfterGuide {
                    dismissSettingsAfterGuide = false
                    dismiss()
                }
            }) {
                NavigationStack {
                    FamilyPermissionGuide(backToSettings: { showingFamilyGuide = false }) {
                        dismissSettingsAfterGuide = true
                        showingFamilyGuide = false
                    }
                }
            }
    }
}

#if DEBUG
struct ComponentGallery: View {
    @State private var rtl = false
    @State private var large = false
    var body: some View {
        Form {
            Toggle("RTL layout stress", isOn: $rtl)
            Toggle("Largest Dynamic Type", isOn: $large)
            Section("Decision") {
                Text(tr("Item-only comparison")).font(.title.bold())
                Text("$6.00 USD").font(.largeTitle).monospacedDigit()
                Label(tr("Cost unresolved"), systemImage: "questionmark.circle").foregroundStyle(Theme.warning)
                Button(tr("Save comparison")) {}.buttonStyle(PrimaryAction())
            }
        }.workingSurface().navigationTitle(tr("Component gallery"))
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .dynamicTypeSize(large ? .accessibility5 : .large)
    }
}
#Preview("Shop") { RootView().environmentObject(AppModel()).environmentObject(LedgerModel()).environmentObject(PickupModel()).environmentObject(HouseholdModel()).environmentObject(WorkspaceAccess()).environmentObject(MembershipCoordinator()).environmentObject(DeviceSurfacesComposition()) }
#Preview("Dark / largest type") { RootView().environmentObject(AppModel()).environmentObject(LedgerModel()).environmentObject(PickupModel()).environmentObject(HouseholdModel()).environmentObject(WorkspaceAccess()).environmentObject(MembershipCoordinator()).environmentObject(DeviceSurfacesComposition()).preferredColorScheme(.dark).dynamicTypeSize(.accessibility5) }
#endif

#if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
import notify
import os
import Darwin

// Diagnostic-only. The serial queue never polls or writes files inside an envelope.
private final class RITCAppCaptureProbe {
    private static var retained: RITCAppCaptureProbe?
    static func install() {
        let env = ProcessInfo.processInfo.environment
        guard let nonce = env["RITC_CAPTURE_NONCE"] else { return }
        guard nonce.count == 32, nonce.allSatisfy({ $0.isHexDigit }),
              let expected = env["RITC_CAPTURE_DEVICE"],
              let runner = Int32(env["RITC_CAPTURE_RUNNER_PID"] ?? ""), runner > 1 else { return }
        do {
            let probe = try RITCAppCaptureProbe(nonce: nonce, expectedDevice: expected, runnerPID: runner)
            retained = probe
            probe.queue.async { probe.register() }
        } catch { /* The runner's bounded ARM wait fails; no successful ACK exists. */ }
    }

    private let nonce: String
    private let expectedDevice: String
    private let runnerPID: Int32
    private let directory: URL
    private let queue = DispatchQueue(label: "dev.roominthecart.capture-control")
    private let signposter: OSSignposter
    private var commandToken: Int32 = -1
    private var ackToken: Int32 = -1
    private var lastSequence: UInt64 = 0
    private var pending: UInt64?
    private var phase = "registered"
    private var terminalError: String?
    private var interval: OSSignpostIntervalState?
    private var activeID: UInt64?
    private var ledger: [[String: Any]] = []
    private var enabledAtReady = false
    private var epoch = Date().timeIntervalSince1970
    private var acknowledgedCommand: UInt64 = 0

    private init(nonce: String, expectedDevice: String, runnerPID: Int32) throws {
        self.nonce = nonce; self.expectedDevice = expectedDevice; self.runnerPID = runnerPID
        signposter = OSSignposter(subsystem: "dev.roominthecart.appcapture." + nonce, category: "CoverageControl")
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("AppCaptureControl", isDirectory: true)
            .appendingPathComponent(nonce, isDirectory: true)
        // A nonce directory must be new; stale status can never become a new capture.
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "RITCCapture", code: 1)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func register() {
        guard notify_register_check("dev.roominthecart.capture.\(nonce).ack", &ackToken) == 0,
              notify_set_state(ackToken, 0) == 0,
              notify_register_dispatch("dev.roominthecart.capture.\(nonce).command", &commandToken, queue,
                                       { [weak self] _ in self?.receive() }) == 0 else {
            fail("notification_registration", command: 0); return
        }
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"]?.uppercased() == expectedDevice.uppercased()
        else { fail("simulator_identity", command: 0); return }
        do { try status() } catch { fail("initial_status_write", command: 0) }
        // ARM cannot be lost to startup: inspect state after registration as well as notifications.
        receive()
    }

    private func status() throws {
        var value: [String: Any] = [
            "schemaVersion": 1, "nonce": nonce, "stage": phase,
            "pid": getpid(), "parentPID": getppid(), "uid": getuid(), "runnerPID": runnerPID,
            "simulatorUDID": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "",
            "compiledForSimulator": true, "executable": Bundle.main.executableURL?.path ?? "",
            "subsystem": "dev.roominthecart.appcapture." + nonce, "category": "CoverageControl",
            "lastSequence": lastSequence, "acknowledgedCommand": acknowledgedCommand,
            "enabledAtReady": enabledAtReady, "invocations": ledger, "startedEpoch": epoch,
            "statusEpoch": Date().timeIntervalSince1970
        ]
        if let pending { value["pendingCommand"] = pending }
        if let terminalError { value["error"] = terminalError }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 8192 else { throw NSError(domain: "RITCCapture", code: 2) }
        try data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
    }

    private func acknowledge(_ command: UInt64) throws {
        // A successful acknowledgement requires a completed operation and no terminal error.
        guard terminalError == nil, pending == command else { throw NSError(domain: "RITCCapture", code: 3) }
        guard notify_set_state(ackToken, command | (UInt64(1) << 56)) == 0,
              notify_post("dev.roominthecart.capture.\(nonce).ack") == 0 else {
            throw NSError(domain: "RITCCapture", code: 4)
        }
        acknowledgedCommand = command
        pending = nil
    }

    private func fail(_ reason: String, command: UInt64) {
        if terminalError == nil { terminalError = reason }
        phase = "failed"
        // Error status uses a different top byte. It can never match a success ACK.
        if ackToken >= 0 {
            _ = notify_set_state(ackToken, (command & 0x00ff_ffff_ffff_ffff) | (UInt64(2) << 56))
            _ = notify_post("dev.roominthecart.capture.\(nonce).ack")
        }
        try? status()
        if commandToken >= 0 { notify_cancel(commandToken); commandToken = -1 }
        // Keep failure state available until app exit; cancel only the app's registration at completion.
    }

    private func hostGate(_ expected: String, seconds: Double, command: UInt64) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            var current: UInt64 = 0
            guard notify_get_state(commandToken, &current) == 0, current == command else {
                throw NSError(domain: "RITCCapture.runner_aborted_or_replaced_pending_command", code: 5)
            }
            let file = directory.appendingPathComponent("host-command.txt")
            if let bytes = try? Data(contentsOf: file) {
                guard bytes.count <= 128, let text = String(data: bytes, encoding: .utf8) else {
                    throw NSError(domain: "RITCCapture.host_command_shape", code: 6)
                }
                if text == expected + " " + nonce + "\n" { return }
                if text == "ABORT " + nonce + "\n" {
                    throw NSError(domain: "RITCCapture.host_abort", code: 7)
                }
                // FINISH may still see the previous GO. No other token is accepted.
                guard expected == "Q" && text == "GO " + nonce + "\n" else {
                    throw NSError(domain: "RITCCapture.host_command_nonce_or_phase", code: 8)
                }
            }
            usleep(50_000)
        }
        throw NSError(domain: "RITCCapture.host_gate_deadline", code: 9)
    }

    private func receive() {
        guard terminalError == nil, commandToken >= 0 else { return }
        var command: UInt64 = 0
        guard notify_get_state(commandToken, &command) == 0 else {
            fail("read_command", command: 0); return
        }
        if command == 0 { return }
        // Dispatch delivery can coalesce. Re-reading an already acknowledged identical state is inert.
        // The protocol never reexecutes that command; a fresh sequence is required for every operation.
        if command == acknowledgedCommand { return }
        let operation = command & 0xff
        let sequence = (command >> 8) & 0x00ff_ffff
        let ordinal = (command >> 32) & 0xffff
        guard command >> 48 == 0, sequence == lastSequence + 1, pending == nil else {
            fail("sequence_or_pending_state", command: command); return
        }
        lastSequence = sequence; pending = command
        do {
            switch operation {
            case 1:
                guard phase == "registered", ordinal == 0 else { throw NSError(domain: "RITCCapture.arm_phase", code: 10) }
                phase = "waitingForCollector"; try status()
                try hostGate("GO", seconds: 30, command: command)
                enabledAtReady = signposter.isEnabled
                signposter.emitEvent("CaptureReady")
                phase = "recording"; try status(); try acknowledge(command)
            case 2:
                guard phase == "recording", interval == nil, ordinal == UInt64(ledger.count + 1), ordinal <= 16 else {
                    throw NSError(domain: "RITCCapture.begin_phase", code: 11)
                }
                let id = signposter.makeSignpostID()
                interval = signposter.beginInterval("ObservedInvocation", id: id)
                activeID = id.rawValue
                try acknowledge(command)
            case 3:
                guard phase == "recording", let state = interval, let id = activeID,
                      ordinal == UInt64(ledger.count + 1) else { throw NSError(domain: "RITCCapture.end_phase", code: 12) }
                signposter.endInterval("ObservedInvocation", state)
                ledger.append(["ordinal": ordinal, "signpostID": id, "beginSequence": sequence - 1, "endSequence": sequence])
                interval = nil; activeID = nil
                try acknowledge(command)
            case 4:
                guard phase == "recording", interval == nil, !ledger.isEmpty, ordinal == UInt64(ledger.count) else {
                    throw NSError(domain: "RITCCapture.finish_phase", code: 13)
                }
                signposter.emitEvent("CaptureComplete")
                phase = "waitingForFinalization"; try status()
                try hostGate("Q", seconds: 100, command: command)
                phase = "finished"
                // Persist finished before ACK; the runner may terminate the app immediately after ACK.
                acknowledgedCommand = command
                try status()
                try acknowledge(command)
                notify_cancel(commandToken); commandToken = -1
                notify_cancel(ackToken); ackToken = -1
            default:
                throw NSError(domain: "RITCCapture.abort_or_unknown_operation", code: 14)
            }
        } catch { fail(String(describing: error), command: command) }
    }
}
#endif
