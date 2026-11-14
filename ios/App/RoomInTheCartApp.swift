import SwiftUI
import DeviceSurfaces

#if DEBUG && (CONTRIBUTOR_CAPTURE_UI_FIXTURE || DINNER_DECISION_UI_FIXTURE)
// The dedicated test build supplies its isolated @main from UITestSupport.
#else
@main struct RoomInTheCartApp: App {
    @UIApplicationDelegateAdaptor private var notificationDelegate: SurfaceNotificationDelegate
    init() {
        #if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)
        RITCAppCaptureProbe.install()
        #endif
        // Keep inactive navigation labels legible against both system bar appearances.
        UITabBar.appearance().unselectedItemTintColor = UIColor(named: "secondary") ?? .secondaryLabel
    }
    var body: some Scene {
        WindowGroup { GroceryWindow(notificationDelegate: notificationDelegate) }
    }
}

/// Observe activation in the window that receives widget and shortcut URLs.
private struct GroceryWindow: View {
    let notificationDelegate: SurfaceNotificationDelegate
    @StateObject private var model = AppModel()
    @StateObject private var ledger = LedgerModel()
    @StateObject private var pickup = PickupModel()
    @StateObject private var household = HouseholdModel()
    @StateObject private var access = WorkspaceAccess()
    @StateObject private var membership = MembershipCoordinator()
    @StateObject private var surfaces = DeviceSurfacesComposition()
    @StateObject private var navigation = NavigationRestorationModel()
    @StateObject private var guardianChild = GuardianChildCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var recoveryFixture = PrivatePickupRecoveryFixture()
    #endif
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Group {
            if scenePhase != .active && access.isProtected {
                Theme.canvas.ignoresSafeArea()
            } else { root }
        }.environment(\.pickupLedger, ledger)
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
            .onOpenURL {
                guard !guardianChild.presented else { return }
                navigation.preferIncomingLink(); surfaces.handle(url: $0)
            }
            .sheet(item: Binding(get: { scenePhase == .active && !guardianChild.presented ? surfaces.destination : nil },
                                 set: { surfaces.destination = $0 })) { destination in
                NavigationStack {
                    DeviceSurfacesDestination(composition: surfaces, destination: destination,
                                              ledger: ledger, pickup: pickup, household: household)
                }.environment(\.pickupLedger, ledger)
                    .environmentObject(ledger).environmentObject(pickup)
                    .environmentObject(household).environmentObject(access)
                    .environmentObject(membership).environmentObject(surfaces).environmentObject(navigation)
            }
            .modifier(HouseholdWorkspaceProtection(household: household, access: access))
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
        if recoveryFixture.requested && recoveryFixture.phase != .ready {
            if recoveryFixture.phase == .failed { Text(verbatim: "Recovery fixture setup failed") }
            else { ProgressView() }
        } else { RootView() }
        #else
        RootView()
        #endif
    }

    @MainActor private func openAdultWorkspace() async {
        guard scenePhase == .active, !guardianChild.presented, access.unlocked else { return }
        if !model.ready { await model.open() }
        guard !guardianChild.presented, access.unlocked else { return }
        if !ledger.ready { await ledger.open() }
        guard !guardianChild.presented, access.unlocked else { return }
        if !pickup.ready { await pickup.load() }
        guard scenePhase == .active, !guardianChild.presented, access.unlocked else { return }
        #if DEBUG && targetEnvironment(simulator)
        await recoveryFixture.prepare(ledger: ledger, pickup: pickup)
        #endif
        navigation.resume()
        await surfaces.foreground()
    }
}

#endif

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
        if let role = household.projection?.role, !["shopper", "organizer"].contains(role) {
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

struct ShopView: View {
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var surfaces: DeviceSurfacesComposition
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                shopContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                // Keep scrolling text inside the actual content viewport. The
                // footer occupies the boundary above bottom navigation.
                Theme.canvas.frame(height: 8)
                    .background(Theme.canvas.ignoresSafeArea(edges: .bottom))
                    .accessibilityHidden(true)
            }
            .fittingViewport(viewport.size)
        }.workingSurface().navigationTitle(tr("Shop")).navigationBarTitleDisplayMode(.inline).settingsButton()
            .task { await model.refresh() }
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

    private var comparePacks: some View {
        NavigationLink { ComparisonView() } label: {
            Label(tr("Compare packs"), systemImage: "arrow.left.arrow.right")
                .frame(minHeight: 44)
        }.accessibilityIdentifier("newComparison")
    }

    private var shopContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let journey = pickup.resumableJourney(for: ledger.shop?.id) {
                    let timelineStart = Date()
                    TimelineView(.explicit([timelineStart] + (journey.offers.map(\.deadline.cutoff) + (journey.pickup?.receipts.map(\.receivedAt) ?? [])).filter { $0 > timelineStart }.sorted())) { context in
                        if let offer = journey.nextUnfilledOffer(at: context.date) {
                            let expired = context.date >= offer.deadline.cutoff
                            VStack(alignment: .leading, spacing: 8) {
                                Text(pTr(expired ? "Await pickup · fill still unknown" : "Decision pending before cutoff")).font(.headline)
                                    .accessibilityIdentifier("shop.resumeOfferStatus")
                                Text(offer.replacement)
                                Text("\(pTr("Cutoff")): \(pickupOfferCutoffText(offer)) · \(offer.deadline.timeZoneID)")
                                NavigationLink(pTr(expired ? "Record what came home" : "Review a store offer")) {
                                    pickupDestination(journey.id) {
                                        if expired { PickupArrivalView(model: pickup) }
                                        else { PickupOfferView(model: pickup) }
                                    }
                                }.frame(minHeight: 44).accessibilityIdentifier("shop.resumeOffer")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    if let shop = ledger.shop {
                        Text(shop.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        if let slot = shop.basis.slot, let zone = TimeZone(identifier: shop.basis.timeZoneIdentifier) {
                            Text(slot.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)) + " · " + zone.identifier)
                        }
                    } else {
                        comparePacks.buttonStyle(PrimaryAction())
                        Text(tr("Works offline. No account needed.")).font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    RestorableShoppingListLink {
                        Label(ledger.shop == nil ? ledgerText("Start pickup") : ledgerText("Shopping list"), systemImage: "list.bullet")
                            .font(.headline).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.foregroundStyle(Theme.action).accessibilityIdentifier("openPickupList")
                    if ledger.shop == nil && (ledger.saving || ledger.hasPendingSave || ledger.error != nil) {
                        LedgerSaveStatus(model: ledger)
                    }
                    if let shop = ledger.shop {
                        if let closed = pickup.journeys.first(where: { $0.id == shop.id })?.closedAt {
                            Text(pTr("Closed") + " · " + closed.formatted(date: .abbreviated, time: .shortened))
                        } else if let journey = pickup.resumableJourney(for: shop.id), let basket = journey.basket, basket.phase != .draft {
                            if shop.basis.slot == nil, let slot = journey.context?.slot, !slot.isEmpty {
                                Text(pTr("Pickup or delivery slot") + " · " + slot)
                            }
                            if basket.phase == .frozen {
                                NavigationLink(pTr("Prepare retailer handoff")) {
                                    pickupDestination(journey.id) { PickupHandoffView(model: pickup, shopID: journey.id) }
                                }.frame(minHeight: 44)
                            } else if journey.nextUnfilledOffer(at: .now) == nil, journey.pickup?.receipts.isEmpty == true {
                                NavigationLink(pTr("Record what came home")) {
                                    pickupDestination(journey.id) { PickupArrivalView(model: pickup) }
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                    if canReviewCheckout {
                        NavigationLink {
                            CheckOneChangeView()
                        } label: {
                            Label(ledger.shop == nil ? CheckOneChangeView.title : tr("Review checkout"),
                                  systemImage: "cart")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.foregroundStyle(Theme.action).accessibilityIdentifier("shop.checkOneChange")
                    }
                    if ledger.shop != nil {
                        comparePacks.foregroundStyle(Theme.action)
                    }
                    NavigationLink {
                        UrgentRepairView(model: pickup).environment(\.pickupLedger, ledger)
                    } label: {
                        Text(tr("Something is missing")).font(.body).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.foregroundStyle(Theme.action).accessibilityIdentifier("urgentRepairShortcut")
                    if let saved = [ledger.savedAt, pickup.journeys.first?.savedAt, model.records.first?.savedAt].compactMap({ $0 }).max() {
                        Text(tr("Last local save") + " · " + saved.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote).accessibilityIdentifier("shop.localSave")
                    }
                    if !household.locked, let shared = household.sharedShop { ShopSyncStatus(model: shared) }
                    FamilyInboxContextLink()
                    if !pickup.journeys.isEmpty {
                        NavigationLink(tr("Pickup, repairs and handoffs")) { PickupHomeView(model: pickup).environment(\.pickupLedger, ledger) }
                            .frame(minHeight: 44)
                    }
                }.padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                NavigationLink {
                    DeviceSurfacesEntry(composition: surfaces)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone").foregroundStyle(Theme.secondary)
                        Text(SurfaceCopy.text("Device shortcuts")).font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward").font(.footnote)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Theme.action)
                    .accessibilityIdentifier("deviceShortcuts")
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color("error"))
                    Button(tr("Try again")) { Task { await model.open(); await model.refresh() } }.frame(minHeight: 44)
                }
                if !model.records.isEmpty {
                    Text(tr("Pick up where you left off")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    ForEach(model.records.prefix(5), id: \.id) { record in
                        SavedRow(record: record)
                            .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }.padding(20)
        }.accessibilityIdentifier("shopContentScroll")
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
    @EnvironmentObject private var surfaces: DeviceSurfacesComposition
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var ledger: LedgerModel
    var body: some View {
        List {
            ManagedViewsContextLink()
            PickupPlacedOrdersLink(model: pickup)
            Section(ht("Shared pickup records")) {
                if !household.locked, household.identity != nil,
                   let scope = household.projection, scope.enrolled, scope.grantId == nil {
                    NavigationLink(ht("Find a past shared pickup")) {
                        HouseholdShopSelector(household: household, includingClosed: true)
                    }.accessibilityIdentifier("records.chooseSharedPickup")
                    NavigationLink(ht("Open selected shared pickup")) {
                        HouseholdShopView(model: household)
                    }.accessibilityIdentifier("records.sharedPickup")
                    Text(ht("Choose a pickup to reopen its orders, deliveries and saved cook instructions."))
                        .font(.footnote).foregroundStyle(Theme.secondary)
                }
                NavigationLink(PlacementCopy.text("Shared placement reports")) {
                    PlacementRecordsEntryView(household: household)
                }.accessibilityIdentifier("records.sharedPlacementReports")
            }
            NavigationLink(HistoryCopy.text("Family decision history")) { FamilyDecisionsEntry() }
            RecordsRecoveryLink()
            NavigationLink(HistoryCopy.text("Prices and period budgets")) {
                HistoryRecordsEntryView(household: household)
            }.accessibilityIdentifier("records.priceBudgetHistory")
            if model.records.isEmpty && model.unavailableRecords.isEmpty {
                ContentUnavailableView(tr("Your comparisons live here"), systemImage: "tray", description: Text(tr("Save a pack comparison to return to the same amounts and prices, even offline.")))
            }
            ForEach(model.records, id: \.id) { SavedRow(record: $0) }
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
            if !pickup.journeys.isEmpty {
                NavigationLink(tr("Pickup, repairs and handoffs")) { PickupHomeView(model: pickup).environment(\.pickupLedger, ledger) }
            }
            if let error = model.error { Text(error).foregroundStyle(Color("error")) }
        }.workingSurface().navigationTitle(tr("Records")).settingsButton().task { await model.refresh() }
    }
}

private struct SettingsButton: ViewModifier {
    @State private var presented = false
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { presented = true } label: { Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(tr("Settings")).accessibilityIdentifier("settings")
            }
        }.sheet(isPresented: $presented) { NavigationStack { SettingsView() } }
    }
}
extension View { func settingsButton() -> some View { modifier(SettingsButton()) } }

struct SettingsView: View {
    @ObservedObject private var feedbackConsent = LocalPickupFeedbackConsent.shared
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var surfaces: DeviceSurfacesComposition
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Section(tr("Appearance")) {
                Picker(tr("Appearance"), selection: $appearance) {
                    Text(tr("System")).tag("system")
                    Text(tr("Light")).tag("light")
                    Text(tr("Dark")).tag("dark")
                }
            }
            Section(tr("Language")) {
                Text(tr("English and Spanish follow your iPhone’s app language setting. Food names and USD stay as entered."))
                Button(tr("Open iPhone settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.frame(minHeight: 44)
            }
            Section(tr("Household")) {
                NavigationLink(tr("Household requests")) { HouseholdSettingsView(model: household, continuesAfterWorkspaceLock: true) }
                NavigationLink(tr("Household membership")) { MembershipEntryView(household: household) }
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
        }.workingSurface().navigationTitle(tr("Settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Done")) { dismiss() } } }
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
