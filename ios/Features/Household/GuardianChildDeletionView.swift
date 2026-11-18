import SwiftUI
import HouseholdClient

struct GuardianChildDeletionLink: View {
    @ObservedObject var household: HouseholdModel
    var body: some View {
        if let scope = household.guardianRuntimeScope, let service = household.service {
            NavigationLink(GuardianCopy.text("Delete a child’s account")) {
                GuardianChildDeletionView(household: household, scope: scope, service: service)
                    .id(scope.generation.uuidString + scope.enrollmentRevision.uuidString + scope.householdID)
            }.accessibilityIdentifier("guardian.childDeletionEntry")
        }
    }
}

private struct GuardianChildDeletionView: View {
    @ObservedObject var household: HouseholdModel
    @StateObject private var model: GuardianChildDeletionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var selectedChild: GuardianDeletionChild?
    @State private var childEmail = ""
    @State private var confirming: GuardianDeletionReview?
    @State private var forgetting: GuardianDeletionRequest?

    init(household: HouseholdModel, scope: GuardianRuntimeScope, service: HouseholdService) {
        self.household = household
        let namespace = (Bundle.main.bundleIdentifier ?? "RoomInTheCart") + "." + service.baseURL.absoluteString
        _model = StateObject(wrappedValue: GuardianChildDeletionModel(scope: scope, service: service,
            vault: KeychainRefreshTokenVault(service: namespace, account: "guardian-child-deletion-receipts"),
            runtime: { [weak household] in household?.guardianRuntimeScope }))
    }

    var body: some View {
        Form {
            if model.live && scenePhase == .active {
                Section {
                    Text(GuardianCopy.text("Withdrawing permission ends access to this household. Deleting the child’s account permanently removes their sign-in and private account data across all households."))
                    Text(GuardianCopy.text("Only the child’s verified parent or legal guardian can confirm deletion. Access ends when the service accepts the request."))
                }
                ForEach(model.receipts) { receipt in receiptSection(receipt) }
                Section(GuardianCopy.text("Choose a child’s account")) {
                    Button(GuardianCopy.text("Refresh child accounts")) { clearSelection(); Task { await model.load() } }
                    if let children = model.children {
                        if children.isEmpty {
                            Text(GuardianCopy.text("No verified child account is available for immediate deletion here. If sign-in was interrupted or another guardian is involved, open a private guardian review below."))
                        }
                        ForEach(children) { child in
                            Button {
                                model.cancelReview()
                                childEmail = ""
                                selectedChild = child
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: child.childAlias)
                                    Text(verbatim: String(child.id.uuidString.lowercased().suffix(8))).font(.caption.monospaced())
                                }
                            }.disabled(!model.canReview(child)).accessibilityIdentifier("guardian.reviewChildDeletion")
                        }
                    }
                }
                if let child = selectedChild, model.canReview(child) {
                    Section {
                        LabeledContent(GuardianCopy.text("Child’s account"), value: child.childAlias)
                        TextField(GuardianCopy.text("Child’s approved sign-in email"), text: $childEmail)
                            .textContentType(.emailAddress).keyboardType(.emailAddress).autocorrectionDisabled()
                            .textInputAutocapitalization(.never).privacySensitive().accessibilityIdentifier("guardian.childDeletionEmail")
                        Button(GuardianCopy.text("Verify email and review deletion")) {
                            let email = childEmail
                            clearSelection()
                            Task { await model.select(child, email: email) }
                        }.disabled(!GuardianChildSignInEmail.isValid(childEmail)).accessibilityIdentifier("guardian.verifyDeletionEmail")
                    }
                }
                if let review = model.review {
                    Section(GuardianCopy.text("Review permanent deletion")) {
                        LabeledContent(GuardianCopy.text("Child’s account"), value: review.childAlias)
                        LabeledContent(GuardianCopy.text("Setup ID"), value: String(review.enrollmentId.uuidString.lowercased().suffix(8)))
                        LabeledContent(GuardianCopy.text("Review expires"), value: GuardianCopy.date(review.expiresAt))
                        if review.verifiedBackupRetentionDays == 1 { Text(ht("Older backups may retain data for up to one day.")) }
                        else { Text(String.localizedStringWithFormat(ht("Older backups may retain data for up to %lld days."), Int64(review.verifiedBackupRetentionDays))) }
                        Button(GuardianCopy.text("Delete this child’s account…"), role: .destructive) { confirming = review }
                            .accessibilityIdentifier("guardian.confirmChildDeletion")
                        Button(ht("Cancel")) { model.cancelReview() }
                    }
                }
                if let scope = household.guardianRuntimeScope, let service = household.service {
                    Section {
                        NavigationLink(GuardianCopy.text("Request or check a private guardian review")) {
                            GuardianManualReviewView(household: household, scope: scope, service: service)
                        }.accessibilityIdentifier("guardian.manualReviewEntry")
                    }
                }
                if let message = model.message { Text(message).accessibilityIdentifier("guardian.childDeletionResult") }
                if model.needsSignIn && household.emailOTPEnabled {
                    Button(ht("Sign out to verify again")) { Task { await household.signOut(); dismiss() } }
                }
                if model.busy { ProgressView(ht("Checking service…")) }
            } else { Text(GuardianCopy.text("Guardian access must be checked again. Unlock your household account.")) }
        }.disabled(model.busy)
        .privacySensitive()
        .navigationTitle(GuardianCopy.text("Delete a child’s account"))
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
            else { clearSelection(); confirming = nil; forgetting = nil; model.clear() }
        }
        .onDisappear { clearSelection(); confirming = nil; forgetting = nil; model.clear() }
        .alert(GuardianCopy.text("Permanently delete this child’s account?"),
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { review in
            Button(ht("Cancel"), role: .cancel) {}
            Button(GuardianCopy.text("Confirm permanent deletion"), role: .destructive) { Task { await model.submit(review) } }
        } message: { review in
            Text(String.localizedStringWithFormat(GuardianCopy.text("I confirm that I am the current parent or legal guardian of %@ and authorize permanent deletion of this child’s account in every household. An accepted request cannot be undone."), review.childAlias))
        }
        .alert(ht("Remove this receipt from this phone?"),
               isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), presenting: forgetting) { receipt in
            Button(ht("Cancel"), role: .cancel) {}
            Button(ht("Remove receipt"), role: .destructive) { model.forget(receipt) }
        } message: { _ in Text(ht("Removing this receipt ends your ability to check this request on this phone. It does not cancel deletion.")) }
    }

    private func clearSelection() {
        selectedChild = nil
        childEmail = ""
    }

    @ViewBuilder private func receiptSection(_ request: GuardianDeletionRequest) -> some View {
        Section(GuardianCopy.text("Child account deletion receipt")) {
            LabeledContent(GuardianCopy.text("Child’s account"), value: request.review.childAlias)
            Text(request.receipt.created.formatted(date: .abbreviated, time: .shortened))
            if let status = model.statuses[request.id] {
                if status.status == .complete {
                    Text(GuardianCopy.text("Deletion complete. The service erased the child’s private account data and confirmed deletion of their sign-in."))
                } else {
                    Text(ht("Deletion accepted and still pending. Check this receipt again later."))
                    if status.appDataErased { Text(ht("Live application data has been erased.")) }
                }
                Text(String.localizedStringWithFormat(ht("Receipt available until %@."), GuardianCopy.date(status.receiptExpiresAt)))
            } else { Text(ht("This device saved a receipt. Check it to learn whether the service accepted the request.")) }
            Button(ht("Check deletion status")) { Task { await model.check(request) } }
            if model.statuses[request.id]?.status == .complete || model.missing.contains(request.id) {
                Button(ht("Remove receipt from this phone"), role: .destructive) { forgetting = request }
            }
        }
    }
}

/// Visible in child spaces without disclosing an adult's identity, account list or receipt.
struct GuardianChildDeletionHelp: View {
    var body: some View {
        Section(GuardianCopy.text("Delete my child account")) {
            Text(GuardianCopy.text("Ask your parent or legal guardian to open Household requests on their own device, choose your household, then open Guardian controls and Delete a child’s account. They can do this before you finish pairing your device."))
                .accessibilityIdentifier("guardian.childDeletionHelp")
            Text(GuardianCopy.text("If your sign-in stopped after you requested an email code, your guardian can open a private review from that screen."))
            Text(GuardianCopy.text("Leaving child space signs you out on this device. Your guardian can request permanent deletion from every household."))
        }
    }
}

struct GuardianDeletionSupportSection: View {
    private let configuration = HelpConfiguration.fromBundle()
    @Environment(\.openURL) private var openURL
    @State private var emailUnavailable = false

    var body: some View {
        Section(GuardianCopy.text("Help with child account deletion")) {
            Text(GuardianCopy.text("Contact support for help verifying your guardian authority. Leave the child’s personal information out of your first message."))
            if let address = configuration.supportEmailAddress, let url = Self.contactURL(address: address) {
                Button(GuardianCopy.text("Draft an email about guardian verification")) {
                    openURL(url) { opened in emailUnavailable = !opened }
                }
                if emailUnavailable {
                    Text(GuardianCopy.text("Copy this address into your email app to contact support."))
                    Text(verbatim: address).textSelection(.enabled)
                }
            } else if let url = configuration.supportURL {
                Link(helpText("Open support"), destination: url)
            } else {
                Text(GuardianCopy.text("Support contact details are unavailable on this device."))
            }
        }
    }

    static func contactURL(address: String) -> URL? {
        guard let url = HelpConfiguration.emailURL(address),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "subject", value: GuardianCopy.text("Guardian review for child account deletion"))]
        return parts.url
    }
}

private struct GuardianManualReviewView: View {
    @ObservedObject var household: HouseholdModel
    @StateObject private var model: GuardianManualReviewModel
    @State private var chosen: GuardianManualReviewChild?
    @State private var email = ""
    @State private var confirming = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(household: HouseholdModel, scope: GuardianRuntimeScope, service: HouseholdService) {
        self.household = household
        let namespace = (Bundle.main.bundleIdentifier ?? "RoomInTheCart") + "." + service.baseURL.absoluteString
        _model = StateObject(wrappedValue: GuardianManualReviewModel(scope: scope, service: service,
            vault: KeychainRefreshTokenVault(service: namespace, account: "guardian-private-review-keys"),
            runtime: { [weak household] in household?.guardianRuntimeScope }))
    }

    var body: some View {
        Form {
            if model.live && scenePhase == .active {
                Section {
                    Text(GuardianCopy.text("Request a private review when the service needs more evidence of your authority to delete a child’s account. Opening a case lets the review team verify your request. Deletion requires a separate decision."))
                    Button(GuardianCopy.text("Refresh my review cases")) { resetForm(); Task { await model.refresh() } }
                }
                ForEach(model.cases) { entry in
                    Section(GuardianCopy.text("Private review case")) {
                        LabeledContent(GuardianCopy.text("Case number"), value: entry.id.uuidString.lowercased()).textSelection(.enabled)
                        LabeledContent(GuardianCopy.text("Review status"), value: label(entry.status))
                        LabeledContent(GuardianCopy.text("Last updated"), value: GuardianCopy.date(entry.updatedAt))
                        LabeledContent(GuardianCopy.text("Case available until"), value: GuardianCopy.date(entry.expiresAt))
                        if entry.status == .closed {
                            Text(GuardianCopy.text("This review case is closed. Only a deletion receipt confirms that the account was erased."))
                        }
                        if entry.status == .verificationNeeded {
                            Text(GuardianCopy.text("Contact support with your case number to ask how to complete guardian verification."))
                        }
                    }
                }
                if model.available == true {
                    Section(GuardianCopy.text("Choose a child setup for review")) {
                        if model.children.isEmpty {
                            Text(GuardianCopy.text("No child setup is available for review here. In Guardian controls, check verification and consent for the intended email. Refresh after the child requests a sign-in code."))
                        }
                        ForEach(model.children) { child in
                            Button {
                                chosen = child
                                email = ""
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: child.childAlias)
                                    Text(verbatim: String(child.id.uuidString.lowercased().suffix(8))).font(.caption.monospaced())
                                    if child.identityState == .unmatched {
                                        Text(GuardianCopy.text("Interrupted sign-in · account unconfirmed")).font(.caption)
                                    }
                                }
                            }.accessibilityIdentifier("guardian.manualReviewCandidate")
                        }
                    }
                    if let child = chosen {
                        Section {
                            LabeledContent(GuardianCopy.text("Child setup"), value: child.childAlias)
                            if child.identityState == .unmatched {
                                Text(GuardianCopy.text("A sign-in code was requested, but the child’s account has not been confirmed. Ask the review team to investigate the interrupted setup."))
                            }
                            TextField(GuardianCopy.text("Child’s approved sign-in email"), text: $email)
                                .textContentType(.emailAddress).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            Button(GuardianCopy.text("Request private review…")) { confirming = true }
                                .disabled(!GuardianChildSignInEmail.isValid(email))
                        }
                    }
                } else if model.available == false {
                    Text(GuardianCopy.text("The service is not accepting new private review cases. You can still check your existing cases."))
                }
                if let message = model.message { Text(message) }
                if model.needsSignIn && household.emailOTPEnabled {
                    Button(ht("Sign out to verify again")) { Task { await household.signOut(); dismiss() } }
                }
                if model.available == false || model.message != nil || model.cases.contains(where: { $0.status == .verificationNeeded }) {
                    GuardianDeletionSupportSection()
                }
                if model.busy { ProgressView(ht("Checking service…")) }
            } else { Text(GuardianCopy.text("Guardian access must be checked again. Unlock your household account.")) }
        }.disabled(model.busy)
        .privacySensitive()
        .navigationTitle(GuardianCopy.text("Private guardian review"))
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
            else { resetForm(); model.clear() }
        }
        .onDisappear { resetForm(); model.clear() }
        .alert(GuardianCopy.text("Open a private review case?"), isPresented: $confirming, presenting: chosen) { child in
            Button(ht("Cancel"), role: .cancel) {}
            Button(GuardianCopy.text("Open case")) {
                let reviewedEmail = email
                resetForm()
                Task { await model.submit(child: child, email: reviewedEmail) }
            }
        } message: { child in
            Text(String.localizedStringWithFormat(GuardianCopy.text("I am the parent or legal guardian of %@. I request a private review of this setup and my authority to delete any associated child account."), child.childAlias))
        }
    }

    private func resetForm() {
        chosen = nil
        email = ""
        confirming = false
    }

    private func label(_ status: GuardianManualReviewCase.Status) -> String {
        switch status {
        case .received: GuardianCopy.text("Review request received")
        case .inReview: GuardianCopy.text("Under private review")
        case .verificationNeeded: GuardianCopy.text("Additional guardian verification needed")
        case .closed: GuardianCopy.text("Review case closed")
        }
    }
}
