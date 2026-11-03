import SwiftUI

/// Keeps one feature coordinator alive for this navigation entry. The factory
/// obtains current native authority; archive payloads cannot supply it.
struct HistoryRecordsEntryView: View {
    @ObservedObject var household: HouseholdModel
    @State private var model: HistoryFeatureModel?
    var body: some View {
        Group {
            if !household.locked, let scope = household.projection, scope.enrolled,
               scope.grantId == nil, ["organizer", "shopper", "contributor"].contains(scope.role),
               household.identity != nil {
                if let model { HistoryEntryView(model: model) }
                else { Text(HistoryCopy.text("History is not configured on this iPhone.")) }
            } else {
                List {
                    Text(HistoryCopy.text("Connect your household to open saved price records and period plans."))
                    NavigationLink(HistoryCopy.text("Open household")) { HouseholdSettingsView(model: household) }
                }.navigationTitle(HistoryCopy.text("Prices and period budgets"))
            }
        }
        .task { if model == nil { model = household.makeHistoryModel() } }
        .onChange(of: household.projection) { _, _ in model?.enforceRuntime() }
        .onChange(of: household.identity?.subject) { _, _ in model?.enforceRuntime() }
        .onChange(of: household.locked) { _, _ in model?.enforceRuntime() }
    }
}
