import SwiftUI
import HouseholdClient

struct GuardianControlsEntry: View {
    @ObservedObject var household: HouseholdModel
    @ObservedObject var lifecycle: HouseholdLifecycleModel
    var body: some View {
        Group {
            if let scope = household.guardianRuntimeScope, let service = household.service {
                GuardianSetupHost(household: household, lifecycle: lifecycle, scope: scope, service: service,
                                  store: household.guardianIntentStore)
                    .id(scope.generation.uuidString + scope.enrollmentRevision.uuidString)
            } else {
                Form { Text(GuardianCopy.text("Guardian access must be checked again. Unlock your household account.")) }
            }
        }.navigationTitle(GuardianCopy.text("Guardian controls"))
    }
}
private struct GuardianSetupHost: View {
    @ObservedObject var household: HouseholdModel
    @ObservedObject var lifecycle: HouseholdLifecycleModel
    @StateObject private var model: GuardianEnrollmentModel
    init(household: HouseholdModel, lifecycle: HouseholdLifecycleModel, scope: GuardianRuntimeScope,
         service: HouseholdService, store: GuardianIntentStore) {
        self.household = household; self.lifecycle = lifecycle
        _model = StateObject(wrappedValue: GuardianEnrollmentModel(scope: scope, service: service, store: store,
            runtime: { [weak household] in household?.guardianRuntimeScope }))
    }
    var body: some View {
        GuardianEnrollmentView(model: model, serviceURL: household.service?.baseURL) {
            NavigationLink(GuardianCopy.text("Review or withdraw current permissions")) { HouseholdGuardianView(model: lifecycle) }
        }
    }
}

struct GuardianEnrollmentView<Withdrawal: View>: View {
    @ObservedObject var model: GuardianEnrollmentModel
    var serviceURL: URL? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var cancelSelected = false
    @State private var clearSelected = false
    @ViewBuilder var withdrawal: () -> Withdrawal
    var body: some View {
        Form {
            Section {
                Text(GuardianCopy.text("Children can send and see only their own requests. Verification of adulthood, guardian permission, and device confirmation are separate steps."))
                withdrawal()
            }
            Section(GuardianCopy.text("Current guardian notice")) {
                Picker(GuardianCopy.text("Notice language"), selection: $model.language) {
                    Text(GuardianCopy.text("English")).tag(GuardianLanguage.en)
                    Text(GuardianCopy.text("Spanish")).tag(GuardianLanguage.es)
                }.disabled(model.hasPending)
                Button(GuardianCopy.text("Refresh notice and setup status")) { Task { await model.load() } }
                    .accessibilityIdentifier("guardian.refresh")
                if let response = model.availability, response.available, let notice = response.notice {
                    Text(notice.text).textSelection(.enabled).accessibilityIdentifier("guardian.noticeText")
                    LabeledContent(GuardianCopy.text("Notice version"), value: notice.version)
                    Text(GuardianCopy.text("Permission covers this child's own requests. It does not provide basket or budget access."))
                    Toggle(GuardianCopy.text("I reviewed this current notice"), isOn: $model.noticeReviewed)
                        .accessibilityIdentifier("guardian.reviewedNotice")
                } else {
                    Label(GuardianCopy.text("Child setup is unavailable until the verification service and current notices are approved."), systemImage: "lock.shield")
                        .accessibilityIdentifier("guardian.unavailable")
                }
            }
            if model.hasPending {
                Section(GuardianCopy.text("Saved setup action")) {
                    Text(GuardianCopy.text("An exact action is saved on this device. Check its status before starting a different action."))
                    if model.pending != nil {
                        Button(GuardianCopy.text("Retry the same setup action")) { Task { await model.retry() } }
                            .accessibilityIdentifier("guardian.retry")
                    }
                    Button(GuardianCopy.text("Check status, then clear local retry")) { clearSelected = true }
                }
            }
            if let invitation = model.invitation {
                Section(GuardianCopy.text("Child invitation")) {
                    Text(GuardianCopy.text("Share this invitation with the intended child's device. Keep it private."))
                    Text(invitation.token).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                        .accessibilityIdentifier("guardian.invitationToken")
                    LabeledContent(GuardianCopy.text("Expires"), value: GuardianCopy.date(invitation.expiresAt))
                    if let serviceURL {
                        BrowserInvitationShare(route: .child, serviceURL: serviceURL, code: invitation.token)
                    }
                    ShareLink(item: invitation.token) { Text(GuardianCopy.text("Share child invitation")) }
                    Text(GuardianCopy.text("The child must use their own approved sign-in. Do not enter an adult account on the child's device."))
                    Button(GuardianCopy.text("I finished sharing; continue to pairing")) { Task { await model.clearRetryAfterStatusReview() } }
                }
            }
            if !model.enrollments.isEmpty {
                Section(GuardianCopy.text("Your child setups")) {
                    ForEach(model.enrollments, id: \.enrollmentId) { enrollment in
                        Button {
                            model.select(enrollment)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(enrollment.childAlias ?? GuardianCopy.text("Child setup"))
                                Text(GuardianCopy.state(enrollment.state.rawValue)).font(.caption).foregroundStyle(.secondary)
                                Text(String(enrollment.enrollmentId.suffix(8))).font(.caption.monospaced())
                            }
                        }.buttonStyle(.borderless)
                            .accessibilityIdentifier("guardian.enrollment." + enrollment.enrollmentId)
                    }
                }
            }
            if let selected = model.selected {
                Section(GuardianCopy.text("Selected setup")) {
                    Text(selected.childAlias ?? GuardianCopy.text("Child setup")).font(.headline)
                    Text(GuardianCopy.state(selected.state.rawValue)).accessibilityIdentifier("guardian.state")
                    LabeledContent(GuardianCopy.text("Expires"), value: GuardianCopy.date(selected.expiresAt))
                    selectedActions(selected)
                    if !["active", "cancelled", "expired", "withdrawn"].contains(selected.state.rawValue) {
                        Button(GuardianCopy.text("Cancel this setup"), role: .destructive) { cancelSelected = true }
                            .disabled(model.hasPending)
                    }
                }
            }
            if model.available, !model.hasPending {
                Section(GuardianCopy.text("Begin a new child setup")) {
                    TextField(GuardianCopy.text("Child's country or region code"), text: $model.childLocation)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("guardian.childLocation")
                    Toggle(GuardianCopy.text("I am this child's parent or legal guardian"), isOn: $model.guardianDeclaration)
                        .accessibilityIdentifier("guardian.declaration")
                    Text(GuardianCopy.text("This is your declaration. The verification provider checks adulthood and does not independently establish your relationship to the child."))
                    Button(GuardianCopy.text("Create a child setup")) { Task { await model.start() } }
                        .disabled(!model.canStart).accessibilityIdentifier("guardian.create")
                }
            }
            if let message = model.message {
                Section { Text(message).accessibilityIdentifier("guardian.result").accessibilityAddTraits(.updatesFrequently) }
            }
            if model.busy { ProgressView(GuardianCopy.text("Checking guardian setup…")) }
        }.disabled(model.busy || !model.live)
        .navigationTitle(GuardianCopy.text("Guardian controls"))
        .task { await model.load() }
        .onChange(of: model.language) { _, _ in Task { await model.load() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.invalidate() } else { Task { await model.load() } } }
        .onDisappear { model.invalidate() }
        .confirmationDialog(GuardianCopy.text("Cancel this child setup?"), isPresented: $cancelSelected, titleVisibility: .visible) {
            Button(GuardianCopy.text("Cancel this setup"), role: .destructive) { Task { await model.cancelEnrollment() } }
            Button(GuardianCopy.text("Cancel")) { cancelSelected = false }.accessibilityIdentifier("guardian.cancelSetupCancel")
        } message: { Text(GuardianCopy.text("Cancellation ends this pending setup. An active child's permission is withdrawn through current permissions.")) }
        .confirmationDialog(GuardianCopy.text("Clear this local retry?"), isPresented: $clearSelected, titleVisibility: .visible) {
            Button(GuardianCopy.text("Check status, then clear local retry"), role: .destructive) { Task { await model.clearRetryAfterStatusReview() } }
            Button(GuardianCopy.text("Cancel")) { clearSelected = false }.accessibilityIdentifier("guardian.clearRetryCancel")
        } message: { Text(GuardianCopy.text("Clearing a local retry does not cancel setup or withdraw permission already saved by the household service.")) }
    }
    @ViewBuilder private func selectedActions(_ selected: GuardianEnrollment) -> some View {
        switch selected.state.rawValue {
        case "awaiting_verification":
            Text(GuardianCopy.text("Request adulthood verification using the confirmed email on your current account. Verification alone does not give permission."))
            Button(GuardianCopy.text("Request adult verification")) { Task { await model.requestVerification() } }
                .disabled(!model.available || model.hasPending).accessibilityIdentifier("guardian.verify")
        case "verification_uncertain":
            Text(GuardianCopy.text("The verification request is uncertain. Refresh status or wait for the verified result. A new verification email cannot be requested from this setup."))
        case "verification_pending":
            Text(GuardianCopy.text("Complete the verification provider's process, then refresh status. A browser return does not confirm verification."))
        case "verified":
            Text(GuardianCopy.text("Adulthood verification is complete. Review the current notice and make a separate permission decision."))
            TextField(GuardianCopy.text("Child's household alias"), text: $model.childAlias)
                .accessibilityIdentifier("guardian.childAlias")
            TextField(GuardianCopy.text("Child's exact sign-in email"), text: $model.childSignInEmail)
                .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                .autocorrectionDisabled().privacySensitive().accessibilityIdentifier("guardian.childSignInEmail")
            Text(GuardianCopy.text("Review this exact email before granting permission. The child may sign in only with this email after permission is recorded."))
            Toggle(GuardianCopy.text("I grant this child permission for their own requests under this notice"), isOn: $model.grantReviewed)
                .accessibilityIdentifier("guardian.grantReviewed")
            Button(GuardianCopy.text("Grant permission")) { Task { await model.grantPermission() } }
                .disabled(!model.canGrant).accessibilityIdentifier("guardian.grant")
        case "consented":
            Button(GuardianCopy.text("Create a child invitation")) { Task { await model.createInvitation() } }
                .disabled(!model.available || model.hasPending).accessibilityIdentifier("guardian.invite")
        case "child_claimed":
            Text(GuardianCopy.text("Read the pairing code displayed on the intended child's device. Confirm that exact code here before access can activate."))
            TextField(GuardianCopy.text("Code on the child's device"), text: $model.pairingCode)
                .textInputAutocapitalization(.characters).autocorrectionDisabled().privacySensitive()
                .accessibilityIdentifier("guardian.pairingCode")
            Button(GuardianCopy.text("Confirm this child's device")) { Task { await model.confirmChild() } }
                .disabled(!model.available || model.hasPending || model.pairingCode.isEmpty).accessibilityIdentifier("guardian.confirmChild")
        case "child_approved":
            Text(GuardianCopy.text("This device was confirmed. The child can finish setup in their own authenticated session."))
        case "active":
            Text(GuardianCopy.text("The household service confirms active own-request access. Use current permissions to withdraw it."))
        default: EmptyView()
        }
    }
}

/// This is the production entry until the operator-approved child identity setup is integrated.
/// It deliberately has no email field, adult declaration, or fallback to AdultAuth.
struct GuardianChildEntryView: View {
    var body: some View {
        Form {
            Section {
                Label(GuardianCopy.text("Child sign-in is not available yet"), systemImage: "lock.shield")
                    .accessibilityIdentifier("guardian.childAuthUnavailable")
                Text(GuardianCopy.text("A child invitation requires the child's own live authenticated session from an approved guardian setup. This app cannot create or substitute an adult account for that session."))
                Text(GuardianCopy.text("Ask your guardian to keep the invitation private and check setup status. Online requests stay unavailable until verification, permission, and device pairing are complete."))
            }
        }.navigationTitle(GuardianCopy.text("Use a child invitation"))
    }
}
