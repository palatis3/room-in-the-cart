import SwiftUI
import SafariServices
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
                WorkingForm { Text(GuardianCopy.text("Guardian access must be checked again. Unlock your household account.")) }
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
        GuardianEnrollmentView(model: model, serviceURL: household.service?.baseURL,
                               householdName: household.projection?.household.label, allowsNewSetup: lifecycle.canAdminister) {
            NavigationLink(GuardianCopy.text("Review or withdraw current permissions")) { HouseholdGuardianView(model: lifecycle) }
            GuardianChildDeletionLink(household: household)
        }
    }
}

struct GuardianEnrollmentView<Withdrawal: View>: View {
    @ObservedObject var model: GuardianEnrollmentModel
    var serviceURL: URL? = nil
    var householdName: String? = nil
    var allowsNewSetup = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var cancelSelected = false
    @State private var clearSelected = false
    @ViewBuilder var withdrawal: () -> Withdrawal
    var body: some View {
        WorkingForm {
            Section {
                GuardianDeviceHeading(device: GuardianCopy.text("On the guardian’s device"),
                                     instruction: GuardianCopy.text("Verify your adulthood, give permission for this child’s own requests, then confirm the child’s device."))
                if let householdName { LabeledContent(ht("Household"), value: householdName).privacySensitive() }
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
                    VStack(alignment: .leading, spacing: 6) {
                        Label(GuardianCopy.text("Child setup is unavailable"), systemImage: "lock.shield")
                            .font(.headline)
                            .accessibilityIdentifier("guardian.unavailable")
                        Text(GuardianCopy.text("The verification service and guardian notices need approval first."))
                            .foregroundStyle(Theme.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text(GuardianCopy.text("Send this invitation privately to the child’s device. The child will use the email you approved."))
                    Text(invitation.token).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                        .accessibilityIdentifier("guardian.invitationToken")
                    LabeledContent(GuardianCopy.text("Expires"), value: GuardianCopy.date(invitation.expiresAt, includingTimeZone: true))
                    if let serviceURL {
                        BrowserInvitationShare(route: .child, serviceURL: serviceURL, code: invitation.token)
                    }
                    ShareLink(item: invitation.token) { Text(GuardianCopy.text("Share child invitation")) }
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
                                Text(GuardianCopy.state(enrollment.state.rawValue)).font(.caption).foregroundStyle(Theme.secondary)
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
                    LabeledContent(GuardianCopy.text("Expires"), value: GuardianCopy.date(selected.expiresAt, includingTimeZone: true))
                    selectedActions(selected)
                    if !["active", "cancelled", "expired", "withdrawn"].contains(selected.state.rawValue) {
                        Button(GuardianCopy.text("Cancel this setup"), role: .destructive) { cancelSelected = true }
                            .disabled(model.hasPending)
                    }
                }
            }
            if allowsNewSetup, model.available, !model.hasPending {
                Section(GuardianCopy.text("Begin a new child setup")) {
                    childResidenceFields
                    Toggle(GuardianCopy.text("I am this child's parent or legal guardian"), isOn: $model.guardianDeclaration)
                        .accessibilityIdentifier("guardian.declaration")
                    Text(GuardianCopy.text("This is your declaration. The verification provider checks adulthood and does not independently establish your relationship to the child."))
                    Button(GuardianCopy.text("Create a child setup")) { Task { await model.start() } }
                        .disabled(!model.canStart).accessibilityIdentifier("guardian.create")
                }
            }
            Section { withdrawal() }
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
            Button(GuardianCopy.text("Keep this setup")) { cancelSelected = false }.accessibilityIdentifier("guardian.cancelSetupCancel")
        } message: { Text(GuardianCopy.text("Cancellation ends this pending setup. An active child's permission is withdrawn through current permissions.")) }
        .confirmationDialog(GuardianCopy.text("Clear this local retry?"), isPresented: $clearSelected, titleVisibility: .visible) {
            Button(GuardianCopy.text("Check status, then clear local retry"), role: .destructive) { Task { await model.clearRetryAfterStatusReview() } }
            Button(GuardianCopy.text("Cancel")) { clearSelected = false }.accessibilityIdentifier("guardian.clearRetryCancel")
        } message: { Text(GuardianCopy.text("Clearing a local retry does not cancel setup or withdraw permission already saved by the household service.")) }
    }
    @ViewBuilder private var childResidenceFields: some View {
        if model.usesLegacyChildLocation {
            Text(GuardianCopy.text("For a child living in a U.S. state or DC, enter US or a state code such as US-CA. U.S. territories are outside the enrollment area."))
                .font(.footnote)
            TextField(GuardianCopy.text("Child's country or region code"), text: $model.childLocation)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityIdentifier("guardian.childLocation")
        } else {
            Picker(GuardianCopy.text("Child's country of residence"), selection: $model.childCountry) {
                Text(GuardianCopy.text("Choose a country")).tag(GuardianChildCountry?.none)
                ForEach(model.supportedChildCountries, id: \.self) { country in
                    Text(GuardianCopy.text(country == .mexico ? "Mexico" : "United States (50 states and DC)")).tag(Optional(country))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("guardian.childCountry")
            if model.childCountry == .unitedStates {
                TextField(GuardianCopy.text("U.S. state code or DC (optional)"), text: $model.childUSRegion,
                          prompt: Text(verbatim: "CA"))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("guardian.childUSRegion")
            }
        }
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
                .buttonStyle(PrimaryAction()).disabled(!model.canGrant).accessibilityIdentifier("guardian.grant")
        case "consented":
            Button(GuardianCopy.text("Create a child invitation")) { Task { await model.createInvitation() } }
                .disabled(!model.available || model.hasPending).accessibilityIdentifier("guardian.invite")
        case "child_claimed":
            Text(GuardianCopy.text("Look at the pairing code on the child’s phone. Enter it here, on your phone, to confirm that device."))
            TextField(GuardianCopy.text("Code on the child's device"), text: $model.pairingCode)
                .textInputAutocapitalization(.characters).autocorrectionDisabled().privacySensitive()
                .accessibilityIdentifier("guardian.pairingCode")
            Button(GuardianCopy.text("Confirm this child's device")) { Task { await model.confirmChild() } }
                .buttonStyle(PrimaryAction()).disabled(!model.available || model.hasPending || model.pairingCode.isEmpty).accessibilityIdentifier("guardian.confirmChild")
        case "child_approved":
            Text(GuardianCopy.text("You confirmed the child’s device. On that device, the child can now choose Finish child setup."))
        case "active":
            Text(GuardianCopy.text("The household service confirms active own-request access. Use current permissions to withdraw it."))
        default: EmptyView()
        }
    }
}

struct GuardianDeviceHeading: View {
    let device: String
    let instruction: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(device)
                .marketJournalTitle(.title2)
            Text(instruction)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }
}

struct FamilyPermissionGuideLink: View {
    var title = GuardianCopy.text("Children and guardian permission")
    var done: (() -> Void)?

    var body: some View {
        NavigationLink {
            FamilyPermissionGuide(done: done)
        } label: {
            Label(title, systemImage: "person.2")
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("guardian.familyGuide")
    }
}

struct FamilyPermissionGuide: View {
    let backToSettings: (() -> Void)?
    let done: (() -> Void)?

    init(done: (() -> Void)? = nil) {
        self.done = done
        self.backToSettings = nil
    }

    init(backToSettings: @escaping () -> Void, done: @escaping () -> Void) {
        self.done = done
        self.backToSettings = backToSettings
    }

    var body: some View {
        WorkingForm { FamilyPermissionSections(done: done) }
            .navigationTitle(GuardianCopy.text("Child permissions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let backToSettings {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: backToSettings) {
                            Label(GuardianCopy.text("Back to Settings"), systemImage: "chevron.backward")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityIdentifier("guardian.familyGuide.settings")
                    }
                }
                if let done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(ledgerText("Done"), action: done)
                            .accessibilityIdentifier("guardian.familyGuide.done")
                    }
                }
            }
    }
}

private struct FamilyPermissionSections: View {
    var done: (() -> Void)? = nil
    private let configuration = HelpConfiguration.fromBundle()
    @State private var showingOnlineGuide = false

    var body: some View {
        Section {
            Text(GuardianCopy.text("With guardian permission, a child can send grocery requests and see the status of their own requests. The assigned shopper decides what goes in the basket. The household budget stays private."))
                .accessibilityIdentifier("guardian.familyGuide.scope")
        } header: {
            Text(GuardianCopy.text("What a child can do"))
                .marketJournalTitle(.title2).textCase(nil)
        }
        Section(GuardianCopy.text("On the guardian’s iPhone")) {
            Text(GuardianCopy.text("When child setup is available, open Household requests in Settings, sign in to your adult account, choose your child’s household, then open Guardian controls."))
                .accessibilityIdentifier("guardian.familyGuide.start")
            Text(GuardianCopy.text("A parent or legal guardian verifies adulthood, gives permission and confirms the child’s device. Keep the invitation private. The child signs in with their own approved email."))
        }
        Section(GuardianCopy.text("If someone can’t join")) {
            Text(GuardianCopy.text("Ask a parent or guardian to open Support and describe where setup stopped. Keep invitation links, sign-in codes and the child’s email private. You can keep using your shopping list."))
                .accessibilityIdentifier("guardian.familyGuide.joinHelp")
            NavigationLink(helpText("Support")) {
                HelpSupportView().toolbar {
                    if let done {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(ledgerText("Done"), action: done)
                                .accessibilityIdentifier("guardian.familyGuide.exitSupport")
                        }
                    }
                }
            }.accessibilityIdentifier("guardian.familyGuide.support")
        }
        Section {
            Text(configuration.helpURL == nil
                 ? GuardianCopy.text("You can read this guide offline. This iPhone has no link to the public family guide.")
                 : GuardianCopy.text("You can read this guide on this iPhone without an internet connection."))
                .accessibilityIdentifier("guardian.familyGuide.offline")
            if let url = configuration.familyHelpURL {
                Button(GuardianCopy.text("Read the family guide online")) { showingOnlineGuide = true }
                    .accessibilityAddTraits(.isLink)
                    .accessibilityIdentifier("guardian.familyGuide.online")
                    .fullScreenCover(isPresented: $showingOnlineGuide) {
                        FamilyGuideBrowser(url: url) { showingOnlineGuide = false }
                            .ignoresSafeArea()
                    }
            } else if let url = configuration.helpURL {
                Link(helpText("Online help"), destination: url)
            }
        }
    }
}

private struct FamilyGuideBrowser: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .done
        browser.delegate = context.coordinator
        return browser
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { done() }
    }
}

/// This is the production entry until the operator-approved child identity setup is integrated.
/// It deliberately has no email field, adult declaration, or fallback to AdultAuth.
struct GuardianChildEntryView: View {
    var body: some View {
        WorkingForm {
            Section {
                Label(GuardianCopy.text("Child sign-in is not available yet"), systemImage: "lock.shield")
                    .accessibilityIdentifier("guardian.childAuthUnavailable")
                Text(GuardianCopy.text("Online requests stay unavailable until your guardian finishes setup. An adult account cannot be used to sign in for a child."))
            }
            FamilyPermissionSections()
            GuardianChildDeletionHelp()
        }
        .navigationTitle(GuardianCopy.text("Child access"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
