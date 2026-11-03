import SwiftUI
import CoreDomain

private struct DinnerHouseholdKey: EnvironmentKey {
    static let defaultValue: HouseholdModel? = nil
}
extension EnvironmentValues {
    var dinnerHousehold: HouseholdModel? {
        get { self[DinnerHouseholdKey.self] }
        set { self[DinnerHouseholdKey.self] = newValue }
    }
}

/// The household route receives no device-private ledger or stock store.
struct DinnerSharedPlanningEntry: View {
    @ObservedObject var household: HouseholdModel
    @State private var showingChanges = false
    @State private var showingDates = false
    @State private var pendingShopReview = false
    @State private var reviewingShop = false
    private func openShopReview() { pendingShopReview = true; showingChanges = false; showingDates = false }
    private func sheetClosed() { if pendingShopReview { pendingShopReview = false; reviewingShop = true } }
    var body: some View {
        List {
            if household.canOpenSharedDinnerPlanning {
                Section(ht("Shared meal plan")) {
                    NavigationLink(ht("Shared meal ideas")) { SharedMealIdeasView(household: household) }
                        .accessibilityIdentifier("dinner.sharedIdeas")
                    Button(ht("Guest, ingredient, and serving-group proposals")) { showingChanges = true }
                    Button(ht("Shared meal dates")) { showingDates = true }
                }
            } else {
                Text(ht("Refresh the household and check meal planning access."))
            }
        }.navigationTitle(ht("Shared meal plan"))
        .sheet(isPresented: $showingChanges, onDismiss: sheetClosed) {
            NavigationStack { SharedMealChangesView(household: household, onReviewOpened: openShopReview)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { showingChanges = false } } } }
        }
        .sheet(isPresented: $showingDates, onDismiss: sheetClosed) {
            NavigationStack { SharedMealMovesView(household: household, onReviewOpened: openShopReview)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { showingDates = false } } } }
        }
        .navigationDestination(isPresented: $reviewingShop) { HouseholdShopView(model: household) }
        .onChange(of: household.sharedMealChangeScope) { _, _ in
            showingChanges = false; showingDates = false; pendingShopReview = false; reviewingShop = false
        }
    }
}

extension HouseholdModel {
    var canOpenSharedDinnerPlanning: Bool {
        sharedMealChangeScope != nil
    }
}

/// Sharing is a separate explicit review. Building a local preview never submits it.
struct DinnerSharedProposalEntry: View {
    @ObservedObject var model: DinnerFeatureModel
    let preview: DinnerPreview
    @Environment(\.dinnerHousehold) private var household
    var body: some View {
        if let household, !preview.proposal.isIsolatedPreview {
            DinnerSharedProposalContent(model: model, household: household, preview: preview)
        }
    }
}
private struct DinnerSharedProposalContent: View {
    @ObservedObject var model: DinnerFeatureModel
    @ObservedObject var household: HouseholdModel
    let preview: DinnerPreview
    @State private var seed: SharedMealChangeSeed?
    @State private var showing = false
    @State private var failure: String?
    @State private var reviewedScope: SharedMealChangeScope?
    @State private var pendingShopReview = false
    @State private var reviewingShop = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
        if household.canOpenSharedDinnerPlanning {
        Section(ht("Shared meal proposal")) {
            Text(ht("Choose one reviewed dinner to share. Review the exact household meal and food details before sending. Local prices and stock are not copied."))
            ForEach(preview.projectedMeals.filter { (preview.changedOccurrenceIDs.contains($0.id) || !$0.ingredientContributionIDs.filter { preview.changedContributionIDs.contains($0) }.isEmpty) && $0.removedAt == nil && $0.carryover == nil }) { meal in
                Button {
                    do {
                        guard model.canReviewPreview, model.preview == preview, household.canOpenSharedDinnerPlanning else { return }
                        seed = try SharedMealChangeSeed(preview: preview, occurrenceID: meal.id, state: model.state)
                        reviewedScope = household.sharedMealChangeScope
                        failure = nil; showing = true
                    } catch {
                        failure = ht("This dinner needs complete shared portion evidence. Review the groups and quantities before sharing.")
                    }
                } label: { Text(verbatim: meal.title) }
                .accessibilityIdentifier("dinner.shareProposal.\(meal.id)")
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        }
        }
        .sheet(isPresented: $showing, onDismiss: {
            seed = nil
            if pendingShopReview, reviewedScope == household.sharedMealChangeScope { reviewingShop = true }
            pendingShopReview = false
        }) {
            NavigationStack {
                if reviewedScope == household.sharedMealChangeScope {
                SharedMealChangesView(household: household, seed: seed, onReviewOpened: { pendingShopReview = true; showing = false })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { showing = false } } }
                }
            }
        }
        .navigationDestination(isPresented: $reviewingShop) { HouseholdShopView(model: household) }
        .onChange(of: model.preview) { _, next in if next != preview { showing = false; seed = nil } }
        .onChange(of: household.sharedMealChangeScope) { _, _ in
            showing = false; seed = nil; reviewedScope = nil; pendingShopReview = false; reviewingShop = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { showing = false; seed = nil; reviewedScope = nil; pendingShopReview = false; reviewingShop = false }
        }
    }
}
