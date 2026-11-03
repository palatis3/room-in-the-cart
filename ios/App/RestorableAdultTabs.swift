import SwiftUI
import LocalStore

/// Each native tab keeps its own explicit path. View-based links and contextual
/// sheets may add transient UI, but only these reviewed source locators persist.
struct RestorableAdultTabs: View {
    @EnvironmentObject private var navigation: NavigationRestorationModel
    var body: some View {
        TabView(selection: Binding(get: { navigation.selection }, set: navigation.select)) {
            NavigationStack(path: path(.shop)) {
                ShopView().navigationDestination(for: RestorableDestination.self) { RestoredDestinationView(destination: $0) }
            }.tabItem { Label(tr("Shop"), systemImage: "cart") }.tag(AdultTab.shop)
            NavigationStack(path: path(.dinners)) {
                DinnerPlanningEntry().settingsButton()
                    .navigationDestination(for: RestorableDestination.self) { RestoredDestinationView(destination: $0) }
            }.tabItem { Label(tr("Dinners"), systemImage: "fork.knife") }.tag(AdultTab.dinners)
            NavigationStack(path: path(.records)) {
                RecordsView().navigationDestination(for: RestorableDestination.self) { RestoredDestinationView(destination: $0) }
            }.tabItem { Label(tr("Records"), systemImage: "clock.arrow.circlepath") }.tag(AdultTab.records)
        }
    }
    private func path(_ tab: AdultTab) -> Binding<[RestorableDestination]> {
        Binding(get: { navigation.path(for: tab) }, set: { navigation.setPath($0, for: tab) })
    }
}
struct RestoredDestinationView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var access: WorkspaceAccess
    let destination: RestorableDestination
    var body: some View {
        Group {
            if access.unlocked,
               household.projection.map({ ["shopper", "organizer"].contains($0.role) }) ?? true {
                switch destination {
                case .shoppingList(let actor, let workspace, let shop):
                    if actor == access.localActorID, ledger.ready, !ledger.hasPendingLedgerDeletion,
                       ledger.sourceWorkspaceID == workspace, ledger.shop?.id == shop {
                        LedgerHomeView(model: ledger).navigationTitle(ledger.shop?.title ?? tr("Shop"))
                    } else { unavailable }
                case .comparison(let actor, let workspace, let id):
                    if actor == access.localActorID, app.ready, app.hasLoadedRecords, app.error == nil, app.store?.workspaceID == workspace,
                       let record = app.records.first(where: { $0.id == id }), let draft = try? app.decode(record) {
                        ComparisonView(draft: draft, savedAt: record.savedAt)
                    } else { unavailable }
                case .household(let destination, let identity):
                    if let scope = contextualScope(household), identity.matches(scope), scope.permits(destination) {
                        ContextualHouseholdEntry(destination: destination, scope: scope)
                    } else { unavailable }
                }
            } else { unavailable }
        }
    }
    private var unavailable: some View {
        ContentUnavailableView(ht("Household access changed"), systemImage: "lock",
            description: Text(ht("Return to the previous screen and choose the current household or shop again.")))
    }
}

struct RestorableShoppingListLink<Label: View>: View {
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    private let label: Label
    init(@ViewBuilder label: () -> Label) { self.label = label() }
    var body: some View {
        if let workspace = ledger.sourceWorkspaceID {
            NavigationLink(value: RestorableDestination.shoppingList(actorID: access.localActorID,
                workspaceID: workspace, shopID: ledger.shop?.id)) { label }
        } else { label }
    }
}
struct RestorableSavedComparisonLink<Label: View>: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var access: WorkspaceAccess
    let record: SavedComparison
    private let label: Label
    init(record: SavedComparison, @ViewBuilder label: () -> Label) { self.record = record; self.label = label() }
    var body: some View {
        if let workspace = app.store?.workspaceID, (try? app.decode(record)) != nil {
            NavigationLink(value: RestorableDestination.comparison(actorID: access.localActorID,
                workspaceID: workspace, recordID: record.id)) { label }
        } else {
            NavigationLink {
                ContentUnavailableView(tr("This comparison could not be opened"), systemImage: "doc.badge.ellipsis",
                    description: Text(tr("The saved record is still on this iPhone. A newer app version may be needed.")))
            } label: { label }
        }
    }
}
