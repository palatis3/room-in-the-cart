import SwiftUI
import Combine
import CoreDomain

@MainActor private func contextualScope(_ household: HouseholdModel) -> ContextualHouseholdScope? {
    guard !household.locked, let identity = household.identity, let scope = household.projection,
          scope.enrolled, scope.grantId == nil, ["shopper", "organizer"].contains(scope.role) else { return nil }
    return ContextualHouseholdScope(subject: identity.subject, householdID: scope.household.id,
        memberID: scope.memberId, shopID: scope.shopId, role: scope.role, capabilities: Set(scope.capabilities))
}

struct FamilyInboxContextLink: View {
    @EnvironmentObject private var household: HouseholdModel
    var body: some View {
        if let scope = contextualScope(household), scope.permits(.inbox), household.canReviewHouseholdRequests {
            NavigationLink(ht("Review family requests")) {
                ContextualHouseholdEntry(destination: .inbox, scope: scope)
            }.frame(minHeight: 44).accessibilityIdentifier("shop.familyInbox")
        }
    }
}
struct ManagedViewsContextLink: View {
    @EnvironmentObject private var household: HouseholdModel
    var body: some View {
        if let scope = contextualScope(household), scope.permits(.managedViews) {
            NavigationLink(ht("Manage shared views")) {
                ContextualHouseholdEntry(destination: .managedViews, scope: scope)
            }.accessibilityIdentifier("records.managedViews")
        }
    }
}
private struct ContextualHouseholdEntry: View {
    @EnvironmentObject private var household: HouseholdModel
    let destination: ContextualHouseholdDestination
    @State private var originalScope: ContextualHouseholdScope
    init(destination: ContextualHouseholdDestination, scope: ContextualHouseholdScope) {
        self.destination = destination; _originalScope = State(initialValue: scope)
    }
    var body: some View {
        Group {
            if originalScope.allows(destination, current: contextualScope(household)) {
                switch destination {
                case .inbox:
                    if let inbox = household.shopperInbox, inbox.authorized,
                       inbox.householdID == originalScope.householdID,
                       inbox.memberID == originalScope.memberID, inbox.shopID == originalScope.shopID {
                        HouseholdInboxView(model: household)
                    } else { unavailable }
                case .managedViews:
                    if let lifecycle = household.lifecycle, matches(lifecycle), lifecycle.canAdminister || lifecycle.canShare {
                        HouseholdManagedViewsView(model: lifecycle)
                    } else { unavailable }
                case .composer:
                    if let lifecycle = household.lifecycle, matches(lifecycle), lifecycle.canShare {
                        HouseholdHelperComposer(model: lifecycle)
                    } else { unavailable }
                }
            } else { unavailable }
        }
    }
    private func matches(_ lifecycle: HouseholdLifecycleModel) -> Bool {
        lifecycle.scope?.shopId == originalScope.shopID && lifecycle.scope?.memberId == originalScope.memberID &&
        lifecycle.scope?.household.id == originalScope.householdID && lifecycle.scope?.role == originalScope.role &&
        lifecycle.scope?.grantId == nil && lifecycle.scope?.enrolled == true
    }
    private var unavailable: some View {
        ContentUnavailableView(ht("Household access changed"), systemImage: "lock",
            description: Text(ht("Return to the previous screen and choose the current household or shop again.")))
    }
}

/// The live composer starts empty. A private dated cook note never becomes shared
/// data merely because the shopper follows this contextual link.
struct CookLiveViewContextLink: View {
    var body: some View {
        Section(pTr("How to share this instruction")) {
            Text(pTr("Save or share a dated copy below, or prepare a separate current shared view. A dated copy stays as sent; a current view can expire or be revoked."))
            NavigationLink(pTr("Prepare a current shared view")) { CookLiveViewEntry() }
                .accessibilityIdentifier("cook.currentSharedView")
        }
    }
}
private struct CookLiveViewEntry: View {
    @EnvironmentObject private var household: HouseholdModel
    @State private var approvedScope: ContextualHouseholdScope?
    var body: some View {
        Form {
            Section {
                Text(pTr("Your private cook note is not copied here. Choose the shared shop, then enter and review only the instructions this recipient should see."))
                Text(pTr("Recipients can open the current view in a browser. Previously sent dated copies cannot be recalled."))
            }
            if let scope = contextualScope(household) {
                Section {
                    Text(household.projection?.household.label ?? "")
                    if let shopID = scope.shopID {
                        LabeledContent(pTr("Selected shared shop reference"), value: String(shopID.suffix(8)))
                    }
                    if household.projection?.canSelectShop == true || household.projection?.selectionRequired == true {
                        NavigationLink(ht("Choose shared shop")) { HouseholdShopSelector(household: household) }
                    }
                    if scope.permits(.composer), household.lifecycle?.canShare == true {
                        Toggle(pTr("I chose the shared shop for these new instructions."), isOn: Binding(
                            get: { approvedScope == scope }, set: { approvedScope = $0 ? scope : nil }))
                        NavigationLink(ht("Create shared cook instructions")) {
                            ContextualHouseholdEntry(destination: .composer, scope: scope)
                        }.disabled(approvedScope != scope).accessibilityIdentifier("cook.openSharedComposer")
                    } else { Text(ht("Only the assigned shopper can share instructions for this shop.")) }
                }
            }
            NavigationLink(ht("Household access")) { HouseholdSettingsView(model: household) }
        }.navigationTitle(pTr("Current shared view"))
            .onChange(of: contextualScope(household)) { _, _ in approvedScope = nil }
    }
}

enum ContextualDinnerDestination { case library, quotes }
struct ContextualDinnerFeature: View {
    @StateObject private var model: DinnerFeatureModel
    let destination: ContextualDinnerDestination
    init(ledger: LedgerModel, destination: ContextualDinnerDestination,
         access: @escaping DinnerFeatureModel.AccessProvider, phase: @escaping (UUID) -> BasketPhase,
         runtimeChanges: AnyPublisher<Void, Never>) {
        self.destination = destination
        let model = DinnerFeatureModel(store: ledger, access: access, phase: phase, ideaCatalog: DinnerPatternCatalog.patterns)
        model.observe(ledger.objectWillChange); model.observeRuntime(runtimeChanges)
        _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        Group {
            switch destination {
            case .library: DinnerLibraryView(model: model)
            case .quotes: DinnerQuotesView(model: model)
            }
        }.environment(\.timeZone, TimeZone(identifier: model.shop?.basis.timeZoneIdentifier ?? "") ?? .current)
    }
}
struct CheckoutQuotesContextLink: View {
    @ObservedObject var pickup: PickupModel
    @Environment(\.pickupLedger) private var ledger
    var body: some View {
        if let ledger, let journeyID = pickup.journey?.id, ledger.shop?.id == journeyID {
            NavigationLink(dinnerText("Compare two store trips")) {
                DinnerPlanningEntry(destination: .quotes, expectedShopID: journeyID)
            }.accessibilityIdentifier("checkout.twoStoreQuotes")
        }
    }
}
struct NextShopDinnerContextEntry: View {
    @ObservedObject var pickup: PickupModel
    @ObservedObject var ledger: LedgerModel
    let journeyID: UUID
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @State private var opened = false
    var body: some View {
        Group {
            if opened {
                DinnerPlanningEntry(destination: .library, expectedShopID: journeyID)
            } else {
                Form {
                    LedgerSaveStatus(model: ledger)
                    Text(pTr("Open this saved next-shop draft to choose a familiar dinner. Choosing a dinner still requires its own review and Apply."))
                    Button(pTr("Open saved next-shop dinner choices")) { Task { await open() } }
                        .disabled(ledger.saving || ledger.hasPendingSave)
                }
            }
        }.navigationTitle(pTr("Reuse a dinner next shop")).task { await open() }
    }
    private func open() async {
        let actor = access.localActorID, subject = household.identity?.subject
        if !ledger.ready { await ledger.open() }
        guard actor == access.localActorID, subject == household.identity?.subject,
              access.unlocked, !household.locked,
              household.projection.map({ ["shopper", "organizer"].contains($0.role) }) ?? true,
              let journey = pickup.journeys.first(where: { $0.id == journeyID }) else { return }
        opened = await LedgerCheckoutAdapter.openNextShop(journey, ledger: ledger)
    }
}
