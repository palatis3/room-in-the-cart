import SwiftUI

/// An approved child-auth integration can present this view with its exact live session model.
/// GuardianChildEntryView intentionally does not construct one in the current production composition.
struct GuardianChildView: View {
    @ObservedObject var model: GuardianChildModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var forget = false
    var body: some View {
        Form {
            Section {
                Text(GuardianCopy.text("This space is for your own requests. Your guardian must confirm this device before access can begin."))
            }
            if let code = model.pairingCode {
                Section(GuardianCopy.text("Show this code to your guardian")) {
                    Text(code).font(.title.monospaced()).textSelection(.enabled).privacySensitive()
                        .accessibilityIdentifier("guardian.childPairingCode")
                    Text(GuardianCopy.text("Show it on this device to your guardian. An invitation alone does not activate access."))
                }
            }
            if model.hasPending {
                Section(GuardianCopy.text("Saved child setup")) {
                    Button(GuardianCopy.text("Resume the same saved setup")) { Task { await model.retry() } }
                        .accessibilityIdentifier("guardian.childRetry")
                    Button(GuardianCopy.text("Check guardian confirmation")) { Task { await model.refreshStatus() } }
                        .accessibilityIdentifier("guardian.childRefresh")
                }
            } else if !model.completed {
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
                            .disabled(!model.canFinish).accessibilityIdentifier("guardian.childFinish")
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
        }.disabled(model.busy || !model.live)
        .navigationTitle(GuardianCopy.text("Use a child invitation"))
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.suspend() } else { Task { await model.load() } } }
        .onDisappear { model.suspend() }
        .confirmationDialog(GuardianCopy.text("Remove saved setup secrets?"), isPresented: $forget, titleVisibility: .visible) {
            Button(GuardianCopy.text("Remove setup secrets from this device"), role: .destructive) { Task { await model.forgetThisDevice() } }
            Button(GuardianCopy.text("Cancel")) { forget = false }.accessibilityIdentifier("guardian.childForgetCancel")
        } message: { Text(GuardianCopy.text("This removes only this device's saved retry. Your guardian must cancel pending setup or withdraw any active permission.")) }
    }
}
