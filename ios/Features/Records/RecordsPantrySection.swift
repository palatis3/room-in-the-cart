import SwiftUI
import RecordArchive

/// Embedded in the existing Records Form. Composition owns workspace admission
/// and the separate recovered-pantry sheet; this surface never activates a store.
struct RecordsPantrySection: View {
    @ObservedObject var model: RecordsPantryToolsModel
    @State private var privateAcknowledged = false
    @State private var keySaved = false
    @State private var showKey = false
    @State private var deleteConfirmed = false
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        Group {
            Section(recordsText("Pantry recovery")) {
                Text(recordsText("Save an encrypted backup of your pantry or import one as a separate copy on this iPhone."))
                if showKey {
                    TextField(recordsText("Recovery key"), text: $model.recoveryKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    SecureField(recordsText("Recovery key"), text: $model.recoveryKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle(recordsText("Show recovery key"), isOn: $showKey)
                Button(recordsText("Generate recovery key")) { model.generateKey() }.disabled(!model.canStart)
                Text(recordsText("Keep the key somewhere safe. You’ll need the same key to open this backup."))
                Toggle(recordsText("I saved this recovery key somewhere safe."), isOn: $keySaved)
                Toggle(recordsText("I understand this pantry package contains private food and meal records."), isOn: $privateAcknowledged)
                Button(recordsText("Save current pantry to Files")) { Task { await model.prepareExport() } }
                    .disabled(!canExport).frame(minHeight: 44)
                Button(recordsText("Choose pantry package from Files")) { model.beginImport() }
                    .disabled(!model.canStart || !model.hasValidKey || !privateAcknowledged).frame(minHeight: 44)
                Button(recordsText("Refresh recovered pantries")) { Task { await model.reload() } }
                    .disabled(!model.canRefresh).frame(minHeight: 44)
                if model.busy || model.cleaning { ProgressView(recordsText("Working…")) }
                if let message {
                    Text(message).accessibilityFocused($statusFocused)
                        .accessibilityIdentifier("records.pantry.status")
                }
            }
            if let review = model.importReview {
                Section(recordsText("Review pantry import")) {
                    LabeledContent(recordsText("Food batches"), value: review.handle.lotCount.formatted())
                    LabeledContent(recordsText("Meal reservations"), value: review.handle.reservationCount.formatted())
                    LabeledContent(recordsText("Saved revision"), value: review.handle.descriptor.inventoryRevision.formatted())
                    Text(disposition(review.registry.disposition))
                    Text(recordsText("Pending changes in this backup are kept as history in the recovered copy."))
                    Button(recordsText("Apply pantry import")) { Task { await model.applyImport() } }
                        .disabled(model.busy || !review.registry.canApply).frame(minHeight: 44)
                    Button(recordsText("Cancel pantry review")) { model.cancelAction() }.disabled(model.busy).frame(minHeight: 44)
                }
            }
            Section(recordsText("Recovered pantries on this iPhone")) {
                if model.copies.isEmpty { Text(recordsText("No recovered pantry copies.")) }
                ForEach(model.copies) { copy in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recordsText("Recovered pantry") + " · " + copy.id.uuidString.suffix(8)).font(.headline)
                        Text(Date(timeIntervalSince1970: Double(copy.recoveredAtMilliseconds) / 1000), format: .dateTime.year().month().day().hour().minute())
                        Button(recordsText("Open recovered pantry")) { Task { await model.open(copy) } }
                            .disabled(!model.canStart).frame(minHeight: 44)
                        if case .ready = copy.materialization {
                            Button(recordsText("Save this edited copy to Files")) { Task { await model.prepareExport(copy: copy) } }
                                .disabled(!canExport).frame(minHeight: 44)
                        } else {
                            Text(recordsText("Open this recovered pantry before exporting its current contents."))
                        }
                        Button(recordsText("Review deletion of this copy"), role: .destructive) { Task { await model.reviewDeletion(copy) } }
                            .disabled(!model.canStart).frame(minHeight: 44)
                    }
                }
            }
            if let review = model.deletionReview {
                Section(recordsText("Delete recovered pantry copy")) {
                    ForEach(review.copies) { copy in
                        Text(recordsText("Recovered pantry") + " · " + copy.id.uuidString.suffix(8))
                    }
                    Text(recordsText("This permanently deletes the selected recovered copy from this iPhone. You’ll keep your current pantry and any files already exported."))
                    Toggle(recordsText("I reviewed this recovered copy for deletion."), isOn: $deleteConfirmed)
                    Button(recordsText("Delete this recovered copy"), role: .destructive) { Task { await model.applyDeletion() } }
                        .disabled(model.busy || !deleteConfirmed).frame(minHeight: 44)
                    Button(recordsText("Cancel pantry review")) { model.cancelAction() }.disabled(model.busy).frame(minHeight: 44)
                }
            }
        }
        .privacySensitive()
        .task { await model.reload() }
        .onChange(of: model.recoveryKey) { _, _ in keySaved = false }
        .onChange(of: model.deletionReview?.copies.map(\.id)) { _, _ in deleteConfirmed = false }
        .onChange(of: message) { _, value in if value != nil { statusFocused = true } }
        .sheet(item: Binding(get: { model.picker }, set: { _ in })) { presentation in
            if model.picker?.id == presentation.id {
                RecordsPantryFilePicker(operationID: presentation.id, mode: presentation.mode,
                    didPresent: { model.pickerDidPresent(operationID: $0) },
                    didDismiss: { await model.pickerDidDismiss(operationID: $0) },
                    willComplete: { model.pickerWillComplete(operationID: $0) },
                    completion: { await model.completePicker(operationID: $0, outcome: $1) })
            }
        }
    }
    private var canExport: Bool { model.canStart && model.hasValidKey && privateAcknowledged && keySaved }
    private var message: String? {
        if let error = model.error {
            switch error {
            case .invalidKey: return recordsText("Enter a valid pantry recovery key before using Files.")
            case .unavailable, .stale: return recordsText("Pantry access or records changed. Unlock and refresh before reviewing again.")
            case .failed: return recordsText("Couldn’t finish this action. Refresh the recovered pantries and try again.")
            }
        }
        switch model.status {
        case .imported: return recordsText("Pantry import saved as a separate local copy.")
        case .opened: return recordsText("Recovered pantry opened.")
        case .exported: return recordsText("Encrypted pantry package saved to Files.")
        case .deleted: return recordsText("Recovered pantry copy deleted from this iPhone.")
        case .cancelled: return recordsText("File selection cancelled.")
        case nil: return nil
        }
    }
    private func disposition(_ value: RecoveryDisposition) -> String {
        switch value {
        case .absent: return recordsText("This package can become a separate recovered pantry.")
        case .identical: return recordsText("This exact pantry package is already recovered here.")
        case .sibling: return recordsText("Another version is recovered here. This package will remain a separate copy.")
        case .quarantined: return recordsText("This package conflicts with a recovered identity and cannot be applied.")
        case .erased: return recordsText("This pantry package was removed locally and cannot be recovered again.")
        }
    }
}
