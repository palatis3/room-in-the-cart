import SwiftUI
import UIKit
import HouseholdClient

private struct GuardianChildCoordinatorKey: EnvironmentKey {
    static let defaultValue: GuardianChildCoordinator? = nil
}
extension EnvironmentValues {
    var guardianChildCoordinator: GuardianChildCoordinator? {
        get { self[GuardianChildCoordinatorKey.self] }
        set { self[GuardianChildCoordinatorKey.self] = newValue }
    }
}

/// Place at the app root before adult tab routing. No NavigationLink or cover owns this boundary.
struct GuardianChildRootView: View {
    @ObservedObject var coordinator: GuardianChildCoordinator
    @State private var remove = false
    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.destination {
                case .starting:
                    ProgressView(GuardianCopy.text("Checking child setup…"))
                case .signIn:
                    if let model = coordinator.authentication { GuardianNativeAuthenticationView(model: model) }
                case .pairing:
                    if let model = coordinator.pairing {
                        GuardianChildView(model: model)
                            .onChange(of: model.completed) { _, completed in if completed { coordinator.showOwnRequests() } }
                    }
                case .requests:
                    if let household = coordinator.household {
                        GuardianChildRequestsView(household: household, recheckAccess: { await coordinator.resume() })
                    }
                case .unavailable, .blocked:
                    WorkingForm {
                        Label(GuardianCopy.text("Child access is unavailable"), systemImage: "lock.shield").font(.headline)
                        if let message = coordinator.message { Text(message).accessibilityIdentifier("guardian.childRootResult") }
                        Button(GuardianCopy.text("Check child access again")) { Task { await coordinator.resume() } }
                        GuardianChildDeletionHelp()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(GuardianCopy.text("Leave child space")) { remove = true }
                        .disabled(coordinator.busy).accessibilityIdentifier("guardian.leaveChildSpace")
                }
            }
            .confirmationDialog(GuardianCopy.text("Remove this child session from the device?"), isPresented: $remove, titleVisibility: .visible) {
                Button(GuardianCopy.text("Sign out child"), role: .destructive) {
                    Task { await coordinator.removeChildSession() }
                }.accessibilityIdentifier("guardian.confirmChildSignOut")
                Button(GuardianCopy.text("Cancel")) { remove = false }.accessibilityIdentifier("guardian.leaveChildCancel")
            } message: {
                Text(GuardianCopy.text("This signs the child out on this device. Adult groceries, meals and costs stay locked and require device-owner authentication."))
            }
        }
    }
}

struct GuardianChildEntryButton: View {
    @ObservedObject var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var coordinator
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var surfaces: DeviceSurfacesComposition
    var body: some View {
        if let coordinator {
            Text(GuardianCopy.text("Opening child space locks the private workspace on this iPhone. To return, choose “Leave child space”, confirm sign-out, then unlock the workspace."))
                .foregroundStyle(Theme.secondary)
            Button {
                coordinator.open(adult: household, access: access, surfaces: surfaces)
            } label: {
                Label {
                    Text(GuardianCopy.text("Use a child invitation"))
                        .font(.body.weight(.semibold)).underline()
                } icon: { Image(systemName: "envelope.open") }
                    .foregroundStyle(Theme.action)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.accessibilityIdentifier("household.childInvitation")
        } else {
            NavigationLink(GuardianCopy.text("Use a child invitation")) { GuardianChildEntryView() }
                .accessibilityIdentifier("household.childInvitation")
        }
    }
}

struct GuardianNativeAuthenticationView: View {
    @ObservedObject var model: GuardianNativeAuthenticationModel
    @Environment(\.scenePhase) private var phase
    var body: some View {
        WorkingForm {
            Section {
                Label(GuardianCopy.text("On the child’s device"), systemImage: "iphone").font(.headline)
                Text(GuardianCopy.text("Enter the invitation from your guardian and the email they approved for you."))
            }
            if model.availability?.available != true {
                Section {
                    Label(GuardianCopy.text("Child sign-in is not available yet"), systemImage: "lock.shield")
                        .accessibilityIdentifier("guardian.nativeAuthUnavailable")
                    Button(GuardianCopy.text("Check child access again")) { Task { await model.load() } }
                }
            } else if model.hasSavedAction {
                Section(GuardianCopy.text("Saved child sign-in")) {
                    Text(GuardianCopy.text("Resume the same saved sign-in. An uncertain request must not send a new email."))
                    Button(GuardianCopy.text("Resume the same saved sign-in")) { Task { await model.resumeSavedSignIn() } }
                        .disabled(model.availability?.available != true).accessibilityIdentifier("guardian.nativeAuthRetry")
                }
            } else {
                Section(GuardianCopy.text("Guardian-approved invitation")) {
                    SecureField(GuardianCopy.text("Child invitation code"), text: $model.token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityIdentifier("guardian.nativeAuthToken")
                    TextField(GuardianCopy.text("Exact email approved by your guardian"), text: $model.email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().privacySensitive().accessibilityIdentifier("guardian.nativeAuthEmail")
                    Button(GuardianCopy.text("Request the child sign-in code")) { Task { await model.startSignIn() } }
                        .disabled(!model.canStart).accessibilityIdentifier("guardian.nativeAuthStart")
                }
            }
            if model.challengeReady, model.availability?.available == true {
                Section(GuardianCopy.text("Verify the child sign-in code")) {
                    Text(GuardianCopy.text("Check your approved email and enter its sign-in code on this phone."))
                    SecureField(GuardianCopy.text("Email sign-in code"), text: $model.code)
                        .textContentType(.oneTimeCode).keyboardType(.numberPad).privacySensitive()
                        .accessibilityIdentifier("guardian.nativeAuthCode")
                    Button(GuardianCopy.text("Verify child code and continue")) { Task { await model.verifyCode() } }
                        .buttonStyle(PrimaryAction()).disabled(!model.canVerify).accessibilityIdentifier("guardian.nativeAuthVerify")
                }
            }
            if let message = model.message {
                Section { Text(message).accessibilityIdentifier("guardian.nativeAuthResult") }
            }
            if model.busy { ProgressView(GuardianCopy.text("Checking child setup…")) }
            GuardianChildDeletionHelp()
        }.disabled(model.busy)
        .navigationTitle(GuardianCopy.text("Child sign-in"))
        .task { await model.load() }
        .onChange(of: phase) { _, value in if value != .active { model.suspend() } else { Task { await model.load() } } }
        .onDisappear { model.invalidate() }
    }
}

/// S22 exposes only typed own-request work and status. It has no adult navigation, purchase, roster, deletion or guardian destination.
struct GuardianChildRequestsView: View {
    @ObservedObject var household: HouseholdModel
    var recheckAccess: (() async -> Void)? = nil
    @AccessibilityFocusState private var resultFocused: Bool
    @State private var review: ReviewDestination?
    @State private var resultBeforeReview: String?
    private struct ReviewDestination: Identifiable {
        let id = UUID()
        let scope: ContributorRequestScope
        let pickupLabel: String
    }
    var body: some View {
        WorkingForm {
            if household.locked || household.projection == nil {
                Section {
                    if case .accessEnded = household.delivery {
                        Label(GuardianCopy.text("Child access is unavailable"), systemImage: "lock.shield")
                        if let recheckAccess {
                            Button(GuardianCopy.text("Check child access again")) { Task { await recheckAccess() } }
                        }
                    } else {
                        Text(GuardianCopy.text("Your child access is being checked. Adult work remains locked."))
                    }
                }
            } else if let scope = household.projection {
                Section {
                    Text(verbatim: scope.household.label)
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("guardian.childHousehold")
                    Text(GuardianCopy.text("You can send a request to the shopper. Only your own requests appear here."))
                }
                Section(household.contributorDraftTitle) {
                    if household.editing != nil || household.followingUp != nil { Button(ht("Cancel edit")) { household.cancelEdit() } }
                    if household.requiresRequestPickupChoice && household.editing == nil && household.followingUp == nil {
                        pickupPicker
                    }
                    TextField(ht("Item"), text: $household.item).accessibilityIdentifier("guardian.childRequestItem")
                    TextField(ht("Quantity, optional"), text: $household.quantity)
                    if household.requestRequiresNextShop {
                        Text(ht("Request for next shop"))
                    } else if household.editing == nil && (!household.requiresRequestPickupChoice || household.followingUp != nil || household.selectedRequestPickupID != nil) {
                        Toggle(ht("Ask for next shop"), isOn: $household.forNextShop)
                    }
                    Button(ht("Review request before sending")) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        if let scope = household.contributorRequestScope {
                            let pickup = household.requestPickups.first { $0.shopId == UUID(uuidString: scope.targetShopID) }
                            resultBeforeReview = household.delivery.requestResultID
                            review = .init(scope: scope, pickupLabel: pickup.map(pickupLabel) ?? String(scope.targetShopID.prefix(8)))
                        }
                    }.buttonStyle(PrimaryAction()).disabled(household.contributorRequestScope == nil || household.item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("guardian.childRequestReview")
                    switch household.draftDelivery {
                    case .waiting:
                        Text(household.waitingRequestText).accessibilityFocused($resultFocused)
                        Button(ht("Retry the same request")) { Task { await household.retry() } }
                    case .needsReview:
                        Text(ht("Review needed. Check received requests before creating a new request.")).accessibilityFocused($resultFocused)
                        if household.canReviewRejectedCorrection {
                            ContributorCorrectionButton(model: household)
                        }
                        Button(ht("I checked received requests; clear this retry")) { Task { await household.discardPendingAfterReview() } }
                    case .received(let receipt): Text(receipt.contributorDeliveryLabel).accessibilityFocused($resultFocused)
                    case .accessEnded: Text(ht("Household access has ended or needs sign-in."))
                    case .localDraft: Text(ht("Draft on this iPhone."))
                    }
                }
                Section(GuardianCopy.text("My requests")) {
                    Button(GuardianCopy.text("Refresh my requests")) { Task { await household.refresh() } }
                        .accessibilityIdentifier("guardian.childRequestsRefresh")
                    ForEach(household.requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.originalItem).font(.headline)
                            if let quantity = request.ownQuantity { Text(quantity) }
                            RequestReadTimeLabel(asOf: household.requestReadTimes.rows[request.id])
                            if let proposed = household.pendingCorrection(for: request) {
                                LabeledContent(ht("Correction on this device"), value: proposed)
                            }
                            if request.fromPreviousShop == true { Text(ht("From an earlier pickup")) }
                            Text(shopperRequestStatus(request)).font(.body.weight(.semibold))
                            if let outcome = request.purchaseOutcome { Text(purchaseStatus(outcome)) }
                            else if request.status == "added" { Text(ht("Purchase still unknown.")).foregroundStyle(Theme.secondary) }
                            if let clarification = request.clarification {
                                Text(verbatim: clarification)
                                if request.canReportClarification == true, let field = SharedMessageField(.clarification, request.id, request.revision, .question, clarification) {
                                    SharedSafetyButton(channel: household.sharedSafetyChannel(), fields: [field])
                                }
                            }
                            if request.ownActionAllowed {
                                OwnRequestEditActions(model: household, request: request)
                            } else if request.status != "withdrawn" {
                                Button(ht("Send a follow-up")) { household.followUp(request) }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if household.requests.isEmpty {
                        Text(ht("No received requests in this view."))
                        RequestReadTimeLabel(asOf: household.requestReadTimes.emptyPage)
                    }
                    if household.nextRequestCursor != nil { Button(ht("Load more requests")) { Task { await household.loadMoreRequests() } } }
                }
            }
            if let message = household.notice { Section { Text(message).accessibilityIdentifier("guardian.childRequestsResult") } }
            if household.busy { ProgressView(ht("Checking service…")) }
            GuardianChildDeletionHelp()
        }.disabled(household.busy)
        .navigationTitle(GuardianCopy.text("My requests"))
        .sheet(item: $review, onDismiss: {
            resultFocused = household.draftDelivery.hasNewRequestResult(since: resultBeforeReview)
            resultBeforeReview = nil
        }) { value in
            NavigationStack {
                ContributorRequestCaptureView(household: household, scope: value.scope, capture: false, pickupLabel: value.pickupLabel)
            }
        }
    }
    @ViewBuilder private var pickupPicker: some View {
        Picker(GuardianCopy.text("Pickup for this request"), selection: Binding(
            get: { household.selectedRequestPickupID },
            set: { if let id = $0 { household.selectRequestPickup(id) } }
        )) {
            Text(GuardianCopy.text("Choose a pickup")).tag(nil as UUID?).disabled(true)
            ForEach(household.requestPickups) { pickup in
                Text(pickupLabel(pickup)).tag(Optional(pickup.shopId))
            }
        }
        .pickerStyle(.menu)
        .disabled(household.requestPickups.isEmpty || hasPendingRequest)
        .accessibilityIdentifier("guardian.childRequestPickup")
        if household.nextRequestPickupCursor != nil {
            Button(GuardianCopy.text("Load more pickups")) { Task { await household.loadMoreRequestPickups() } }
                .accessibilityIdentifier("guardian.childRequestMorePickups")
        }
    }

    private var hasPendingRequest: Bool {
        switch household.delivery {
        case .waiting, .needsReview: true
        default: false
        }
    }

    private func pickupLabel(_ pickup: RequestPickup) -> String {
        let id = pickup.shopId.uuidString.lowercased()
        let prefix = String(id.prefix(8))
        let collision = household.requestPickups.contains { $0.shopId != pickup.shopId && $0.shopId.uuidString.lowercased().hasPrefix(prefix) }
        let format = pickup.nextShopOnly
            ? GuardianCopy.text("Next shop only · ID %@ · created %@")
            : GuardianCopy.text("This pickup · ID %@ · created %@")
        return String(format: format, locale: .current, collision ? id : prefix, GuardianCopy.date(pickup.createdAt, dateStyle: .numeric))
    }

}
