import SwiftUI
import HouseholdClient

struct HouseholdDevicesView: View {
    @StateObject private var model: HouseholdDevicesModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: ManagedHouseholdDevice?
    @AccessibilityFocusState private var resultFocused: Bool
    init(model: HouseholdDevicesModel) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        Form {
            if model.live && !model.suspended {
                Section {
                    Text(model.inventoryScope == "guardian_children" ? DeviceManagementCopy.text("Devices for children under your verified guardianship.") : DeviceManagementCopy.text("Enrolled access for this household. Each reference identifies one enrollment."))
                    Text(DeviceManagementCopy.text("A person may have several enrollments on one phone or browser. Use the enrollment date and reference to choose the access to end."))
                    Button(DeviceManagementCopy.text("Refresh devices")) { Task { await model.load() } }.disabled(model.busy || model.blocked)
                        .accessibilityIdentifier("household.devices.refresh")
                }
                if let pending = model.pending {
                    Section(DeviceManagementCopy.text("Device action awaiting confirmation")) {
                        LabeledContent(DeviceManagementCopy.text("Device reference"), value: String(pending.targetDeviceID.suffix(8)))
                        Text(DeviceManagementCopy.text("The result is not confirmed. Retry the same device action to confirm whether access ended."))
                        Button(DeviceManagementCopy.text("Retry the same revocation")) { Task { await model.retry() } }.disabled(model.busy || model.blocked)
                            .accessibilityIdentifier("household.devices.retry")
                    }
                }
                ForEach(model.devices) { device in
                    Section {
                        Text(device.memberAlias).font(.headline).accessibilityIdentifier("household.devices.alias.\(device.id)")
                        LabeledContent(DeviceManagementCopy.text("Device reference"), value: String(device.id.suffix(8)))
                        LabeledContent(DeviceManagementCopy.text("Enrolled"), value: date(device.createdAt))
                        if device.isCurrentDevice { Text(DeviceManagementCopy.text("This device. Use Sign out in household settings to end this enrollment.")) }
                        if let revoked = device.revokedAt {
                            LabeledContent(DeviceManagementCopy.text("Access revoked"), value: date(revoked))
                                .accessibilityIdentifier("household.devices.revoked.\(device.id)")
                        } else {
                            Text(DeviceManagementCopy.text("Active enrollment")).accessibilityIdentifier("household.devices.active.\(device.id)")
                            if !device.isCurrentDevice {
                                Button(DeviceManagementCopy.text("Revoke this device"), role: .destructive) { selected = device }
                                    .disabled(model.busy || model.pending != nil || model.blocked)
                                    .accessibilityIdentifier("household.devices.revoke.\(device.id)")
                            }
                        }
                    }
                }
                if model.nextCursor != nil {
                    Button(DeviceManagementCopy.text("More devices")) { Task { await model.load(more: true) } }.disabled(model.busy || model.blocked)
                        .accessibilityIdentifier("household.devices.more")
                }
                if let message = model.message {
                    Section { Text(message).accessibilityFocused($resultFocused).accessibilityIdentifier("household.devices.result") }
                }
                if model.busy { ProgressView().accessibilityLabel(DeviceManagementCopy.text("Checking device access")) }
            } else { Text(DeviceManagementCopy.text("Return to household settings to review current access.")) }
        }
        .navigationTitle(DeviceManagementCopy.text("Household devices"))
        .task { await model.load() }
        .onDisappear { model.invalidate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.resume() } } else { selected = nil; model.suspend() }
        }
        .onChange(of: model.message) { _, value in if value != nil { resultFocused = true } }
        // A confirmationDialog can become a popover and omit its cancel action.
        // This destructive review always needs a visible, explicit way to cancel.
        .alert(DeviceManagementCopy.text("Revoke this enrolled device?"), isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let device = selected {
                Button(DeviceManagementCopy.text("Revoke this device"), role: .destructive) { selected = nil; Task { await model.revoke(device) } }
                    .accessibilityIdentifier("household.devices.confirm")
            }
            Button(DeviceManagementCopy.text("Cancel"), role: .cancel) { selected = nil }
                .accessibilityIdentifier("household.devices.cancel")
        } message: {
            if let device = selected {
                Text(String.localizedStringWithFormat(DeviceManagementCopy.text("%@ · reference %@. This ends this enrollment's online reads, queued writes and web access. Other devices and household membership stay active."), device.memberAlias, String(device.id.suffix(8))))
            }
        }
    }
    private func date(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
