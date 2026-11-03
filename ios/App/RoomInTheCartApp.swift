import SwiftUI
import DeviceSurfaces

@main struct RoomInTheCartApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var ledger = LedgerModel()
    @StateObject private var pickup = PickupModel()
    @StateObject private var household = HouseholdModel()
    @StateObject private var access = WorkspaceAccess()
    @StateObject private var membership = MembershipCoordinator()
    @StateObject private var surfaces = DeviceSurfacesComposition()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    init() {
        // Keep inactive navigation labels legible against both system bar appearances.
        UITabBar.appearance().unselectedItemTintColor = UIColor(named: "secondary") ?? .secondaryLabel
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if scenePhase != .active && access.isProtected {
                    Theme.canvas.ignoresSafeArea()
                } else { RootView() }
            }.environment(\.pickupLedger, ledger)
                .environmentObject(model)
                .environmentObject(ledger).environmentObject(pickup)
                .environmentObject(household).environmentObject(access)
                .environmentObject(membership).environmentObject(surfaces)
                .tint(Theme.action)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task {
                    membership.bind(to: household)
                    surfaces.bind(ledger: ledger, pickup: pickup, household: household, access: access)
                    await model.open(); await ledger.open(); await pickup.load()
                    await surfaces.foreground()
                }
                .onOpenURL { surfaces.handle(url: $0) }
                .sheet(item: Binding(get: { scenePhase == .active ? surfaces.destination : nil },
                                     set: { surfaces.destination = $0 })) { destination in
                    NavigationStack {
                        DeviceSurfacesDestination(composition: surfaces, destination: destination,
                                                  ledger: ledger, pickup: pickup, household: household)
                    }.environment(\.pickupLedger, ledger)
                        .environmentObject(ledger).environmentObject(pickup)
                        .environmentObject(household).environmentObject(access)
                        .environmentObject(membership).environmentObject(surfaces)
                }
                .onChange(of: household.identity?.subject) { _, subject in
                    if subject != nil { access.protect() }
                    surfaces.scopeChanged()
                }
                .onChange(of: household.projection?.memberId) { _, id in
                    if id != nil { access.protect() }
                    surfaces.scopeChanged()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { surfaces.background(); access.background(); household.lock() }
                    if phase == .active { membership.foreground(); Task { await surfaces.foreground() } }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var access: WorkspaceAccess
    var body: some View {
        if let role = household.projection?.role, !["shopper", "organizer"].contains(role) {
            NavigationStack { HouseholdSettingsView(model: household) }
        } else if !access.unlocked {
            WorkspaceUnlockView(access: access, household: household)
        } else { tabs }
    }
    private var tabs: some View {
        TabView {
            NavigationStack { ShopView() }
                .tabItem { Label(tr("Shop"), systemImage: "cart") }
            NavigationStack { DinnerPlanningEntry().settingsButton() }
                .tabItem { Label(tr("Dinners"), systemImage: "fork.knife") }
            NavigationStack { RecordsView() }
                .tabItem { Label(tr("Records"), systemImage: "clock.arrow.circlepath") }
        }
    }
}

struct ShopView: View {
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
            .frame(width: viewport.size.width, height: viewport.size.height)
        }.workingSurface().navigationTitle(tr("Shop")).settingsButton()
            .task { await model.refresh() }
    }
    private var shopContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label(tr("On this iPhone"), systemImage: "iphone")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "basket").font(.largeTitle).foregroundStyle(Theme.action).accessibilityHidden(true)
                    Text(tr("Make room for what matters.")).font(.largeTitle.bold())
                    Text(tr("Start with one item. Compare two packs and see what it costs to bring home enough."))
                        .foregroundStyle(Theme.secondary)
                    NavigationLink { ComparisonView() } label: {
                        Label(tr("Compare packs"), systemImage: "arrow.left.arrow.right")
                    }.buttonStyle(PrimaryAction()).accessibilityIdentifier("newComparison")
                    Text(tr("Works offline. No account needed.")).font(.footnote).foregroundStyle(Theme.secondary)
                }.padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink {
                        LedgerHomeView(model: ledger).navigationTitle(ledger.shop?.title ?? tr("Shop"))
                    } label: {
                        Label(ledger.shop == nil ? ledgerText("Start pickup") : ledgerText("Shopping list"), systemImage: "list.bullet")
                            .font(.headline).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.foregroundStyle(Theme.action).accessibilityIdentifier("openPickupList")
                    if let shop = ledger.shop {
                        Text(shop.title).font(.title2.bold())
                        NavigationLink(tr("Review checkout")) {
                            LedgerCheckoutEntry(ledger: ledger, pickup: pickup)
                        }.frame(minHeight: 44)
                    }
                    NavigationLink {
                        UrgentRepairView(model: pickup).environment(\.pickupLedger, ledger)
                    } label: {
                        Text(tr("Something is missing")).font(.body).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.foregroundStyle(Theme.action).accessibilityIdentifier("urgentRepairShortcut")
                    if !pickup.journeys.isEmpty {
                        NavigationLink(tr("Pickup, repairs and handoffs")) { PickupHomeView(model: pickup).environment(\.pickupLedger, ledger) }
                            .frame(minHeight: 44)
                    }
                }.padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                NavigationLink(SurfaceCopy.text("Device shortcuts")) {
                    DeviceSurfacesEntry(composition: surfaces)
                }.frame(minHeight: 44).accessibilityIdentifier("deviceShortcuts")
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

import LocalStore
struct SavedRow: View {
    @EnvironmentObject private var model: AppModel
    let record: SavedComparison
    var body: some View {
        NavigationLink {
            if let draft = try? model.decode(record) {
                ComparisonView(draft: draft, savedAt: record.savedAt)
            } else {
                ContentUnavailableView(tr("This comparison could not be opened"), systemImage: "doc.badge.ellipsis", description: Text(tr("The saved record is still on this iPhone. A newer app version may be needed.")))
            }
        } label: {
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
            NavigationLink(tr("Recovery, exports and saved records")) {
                RecordsToolsEntryView(app: model, ledger: ledger, pickup: pickup,
                    erasureCleanup: RecordsErasureCleanup(eraseLedgerWorkspace: { id in
                        try await surfaces.eraseLedgerWorkspace(id)
                        try await CaptureCorrectionStore.shared.eraseProfile(
                            CaptureCorrectionScope(profileID: "local:" + id.uuidString,
                                                   localeIdentifier: Locale.current.language.languageCode?.identifier == "es" ? "es-US" : "en-US"))
                    }, erasePickupRecord: { workspaceID, recordID in
                        try await surfaces.erasePickupRecord(workspaceID: workspaceID, recordID: recordID)
                    }))
            }
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
    @AppStorage(PickupFeedbackSection.consentKey) private var feedbackEnabled = false
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
                NavigationLink(tr("Household requests")) { HouseholdSettingsView(model: household) }
                NavigationLink(tr("Household membership")) { MembershipEntryView(household: household) }
            }
            if surfaces.privateAuthorized {
                Section(SurfaceCopy.text("Device shortcuts")) {
                    NavigationLink(SurfaceCopy.text("Device shortcuts")) { DeviceSurfacesEntry(composition: surfaces) }
                }
            }
            Section(tr("Your data")) {
                Toggle(pTr("Offer optional feedback after a pickup"), isOn: $feedbackEnabled)
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
