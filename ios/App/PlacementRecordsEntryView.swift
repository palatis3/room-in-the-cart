import SwiftUI

struct PlacementRecordsEntryView: View {
    @ObservedObject var household: HouseholdModel
    @State private var model: PlacementFeatureModel?
    private var activeNativeAccount: Bool {
        guard !household.locked, household.identity != nil, let scope = household.projection else { return false }
        return scope.enrolled && scope.grantId == nil && ["organizer", "shopper", "contributor"].contains(scope.role)
    }
    var body: some View {
        Group {
            if activeNativeAccount || household.placementEvidenceUnlocked {
                if let model { PlacementEntryView(model: model) }
                else { Text(PlacementCopy.text("Placement reports are not configured on this iPhone.")) }
            } else {
                List {
                    if household.canUnlockPlacementEvidence {
                        Text(PlacementCopy.text("Open your original saved evidence without fetching the current shopper's private records. This does not restore household authority."))
                        Button(PlacementCopy.text("Unlock saved placement evidence")) { Task { await household.unlockPlacementEvidence() } }
                            .disabled(household.busy).accessibilityIdentifier("placement.unlockLocalEvidence")
                        if let notice = household.placementEvidenceNotice { Text(notice) }
                    }
                    Text(PlacementCopy.text("Connect your household to report an external placement or review a pending report."))
                    NavigationLink(PlacementCopy.text("Open household")) { HouseholdSettingsView(model: household, continuesAfterWorkspaceLock: true) }
                }.navigationTitle(PlacementCopy.text("Shared placement reports"))
            }
        }
        .task { if model == nil { model = household.makePlacementModel() } }
        .onChange(of: household.projection) { _, _ in model?.enforceRuntime() }
        .onChange(of: household.identity?.subject) { _, _ in model?.enforceRuntime() }
        .onChange(of: household.locked) { _, _ in model?.enforceRuntime() }
        .onChange(of: household.placementEvidenceUnlocked) { _, _ in model?.enforceRuntime() }
    }
}
