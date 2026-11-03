import SwiftUI

/// Keeps one feature coordinator alive for this navigation entry. The factory
/// obtains current native authority; archive payloads cannot supply it.
struct HistoryRecordsEntryView: View {
    @ObservedObject var household: HouseholdModel
    @State private var model: HistoryFeatureModel?
    @State private var choosingScope = false
    var body: some View {
        Group {
            if !household.locked, let scope = household.projection, scope.enrolled,
               scope.grantId == nil, ["organizer", "shopper", "contributor"].contains(scope.role),
               household.identity != nil {
                if let model {
                    HistoryEntryView(model: model, chooseShop: { choosingScope = true })
                }
                else { Text(HistoryCopy.text("History is not configured on this iPhone.")) }
            } else {
                List {
                    Text(HistoryCopy.text("Connect your household to open saved price records and period plans."))
                    NavigationLink(HistoryCopy.text("Open household")) { HouseholdSettingsView(model: household) }
                }.navigationTitle(HistoryCopy.text("Prices and period budgets"))
            }
        }
        .sheet(isPresented: $choosingScope) {
            NavigationStack {
                HouseholdShopSelector(household: household)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { choosingScope = false } }
                    }
                    .safeAreaInset(edge: .bottom) {
                        Text(HistoryCopy.text("For a budget covering several shops, choose Use household overview. Each shop still requires your current access."))
                            .font(.footnote).padding().background(.regularMaterial)
                    }
            }
        }
        .toolbar {
            if !household.locked, household.projection?.grantId == nil, household.projection?.canSelectShop == true {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(HistoryCopy.text("Choose shared shop scope")) { HouseholdShopSelector(household: household) }
                }
            }
        }
        .task { if model == nil { model = household.makeHistoryModel() } }
        .onChange(of: household.projection) { _, _ in model?.enforceRuntime() }
        .onChange(of: household.identity?.subject) { _, _ in model?.enforceRuntime() }
        .onChange(of: household.locked) { _, _ in model?.enforceRuntime() }
    }
}
