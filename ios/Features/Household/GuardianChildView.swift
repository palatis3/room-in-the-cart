import SwiftUI

/// An approved child-auth integration can present this view with its exact live session model.
/// GuardianChildEntryView intentionally does not construct one in the current production composition.
struct GuardianChildView: View {
    @ObservedObject var model: GuardianChildModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var forget = false
    @AccessibilityFocusState private var focusedStep: Step?
    private enum Step: Hashable { case pairingCode, finish }
    var body: some View {
        WorkingForm {
            Section {
                GuardianDeviceHeading(device: GuardianCopy.text("On the child’s device"),
                                     instruction: GuardianCopy.text("Your guardian will confirm this phone before you can send a request."))
            }
            if let code = model.pairingCode, model.status == .awaitingGuardian {
                Section(GuardianCopy.text("Show this code to your guardian")) {
                    Text(code).font(.title.monospaced().weight(.semibold))
                        .foregroundStyle(Theme.onSelection).padding(10)
                        .background(Theme.selection, in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled).privacySensitive()
                        .accessibilityIdentifier("guardian.childPairingCode")
                        .accessibilityFocused($focusedStep, equals: .pairingCode)
                    Text(GuardianCopy.text("Your guardian enters this pairing code on their own phone."))
                }
            }
            if model.hasPending {
                Section(GuardianCopy.text("Saved child setup")) {
                    Button(GuardianCopy.text("Resume the same saved setup")) { Task { await model.retry() } }
                        .accessibilityIdentifier("guardian.childRetry")
                    Button(GuardianCopy.text("Check guardian confirmation")) { Task { await model.refreshStatus() } }
                        .accessibilityIdentifier("guardian.childRefresh")
                }
            } else if !model.completed && !(model.coveredAuthentication && model.status == .ended) {
                Section(GuardianCopy.text("Invitation from your guardian")) {
                    if model.coveredAuthentication {
                        Text(GuardianCopy.text("Your guardian's invitation is approved for this sign-in. Continue to show the pairing code on this device."))
                    } else {
                    SecureField(GuardianCopy.text("Child invitation code"), text: $model.invitationToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityIdentifier("guardian.childToken")
                    }
                    Button(GuardianCopy.text("Use this invitation")) { Task { await model.claimInvitation() } }
                        .disabled(!model.canClaim).accessibilityIdentifier("guardian.childClaim")
                }
            }
            if let status = model.status {
                Section {
                    switch status {
                    case .awaitingGuardian: Text(GuardianCopy.text("Waiting for your guardian to confirm the code on this device."))
                    case .approved:
                        Text(GuardianCopy.text("Your guardian confirmed this device. Finish setup to open your own requests."))
                        Button(GuardianCopy.text("Finish child setup")) { Task { await model.finishSetup() } }
                            .buttonStyle(PrimaryAction()).disabled(!model.canFinish).accessibilityIdentifier("guardian.childFinish")
                            .accessibilityFocused($focusedStep, equals: .finish)
                    case .active:
                        Text(GuardianCopy.text("Your own-request access was confirmed by the household service."))
                    case .ended:
                        Text(GuardianCopy.text("This child setup has ended. Ask your guardian for a new setup."))
                    }
                }
            }
            if let message = model.message {
                Section { Text(message).accessibilityIdentifier("guardian.childResult").accessibilityAddTraits(.updatesFrequently) }
            }
            if model.busy { ProgressView(GuardianCopy.text("Checking child setup…")) }
            if model.hasPending {
                Section {
                    Button(GuardianCopy.text("Remove setup secrets from this device"), role: .destructive) { forget = true }
                        .accessibilityIdentifier("guardian.childForget")
                }
            }
            GuardianChildDeletionHelp()
        }.disabled(model.busy || !model.live)
        .navigationTitle(GuardianCopy.text("Use a child invitation"))
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.suspend() } else { Task { await model.load() } } }
        .onDisappear { model.suspend() }
        .onChange(of: model.status) { _, status in
            switch status {
            case .awaitingGuardian: focusedStep = .pairingCode
            case .approved: focusedStep = .finish
            default: focusedStep = nil
            }
        }
        .confirmationDialog(GuardianCopy.text("Remove saved setup secrets?"), isPresented: $forget, titleVisibility: .visible) {
            Button(GuardianCopy.text("Remove setup secrets from this device"), role: .destructive) { Task { await model.forgetThisDevice() } }
            Button(GuardianCopy.text("Cancel")) { forget = false }.accessibilityIdentifier("guardian.childForgetCancel")
        } message: { Text(GuardianCopy.text("This removes only this device's saved retry. Your guardian must cancel pending setup or withdraw any active permission.")) }
    }
}
