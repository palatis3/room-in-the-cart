import SwiftUI

/// Records and Settings share the same recovery destination and complete
/// erasure cleanup. Keep new projection cleanup composed here for both entries.
struct RecordsRecoveryLink: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var surfaces: DeviceSurfacesComposition
    var accessibilityID = "records.recovery"

    var body: some View {
        NavigationLink(tr("Recovery, exports and saved records")) {
            RecordsToolsEntryView(app: app, ledger: ledger, pickup: pickup,
                erasureCleanup: RecordsErasureCleanup(eraseLedgerWorkspace: { id in
                    try await surfaces.eraseLedgerWorkspace(id)
                    try await CaptureCorrectionStore.shared.eraseProfile(
                        CaptureCorrectionScope(profileID: "local:" + id.uuidString,
                            localeIdentifier: Locale.current.language.languageCode?.identifier == "es" ? "es-US" : "en-US"))
                }, erasePickupRecord: { workspaceID, recordID in
                    try await surfaces.erasePickupRecord(workspaceID: workspaceID, recordID: recordID)
                }))
        }.accessibilityIdentifier(accessibilityID)
    }
}
