import SwiftUI
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
                    if let household = coordinator.household { GuardianChildRequestsView(household: household) }
                case .unavailable, .blocked:
                    Form {
                        Text(GuardianCopy.text("Child sign-in is not available yet"))
                        if let message = coordinator.message { Text(message).accessibilityIdentifier("guardian.childRootResult") }
                        Button(GuardianCopy.text("Check child access again")) { Task { await coordinator.resume() } }
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
                Button(GuardianCopy.text("Remove child session and return to locked adult access"), role: .destructive) {
                    Task { await coordinator.removeChildSession() }
                }
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
            Button(GuardianCopy.text("Use a child invitation")) {
                coordinator.open(adult: household, access: access, surfaces: surfaces)
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
        Form {
            Section {
                Text(GuardianCopy.text("Use only the email your guardian approved for this invitation. This child sign-in is separate from any adult account on the device."))
            }
            if model.availability?.available != true {
                Section {
                    Label(GuardianCopy.text("Child sign-in is unavailable until the covered email service and current notices are approved."), systemImage: "lock.shield")
                        .accessibilityIdentifier("guardian.nativeAuthUnavailable")
                }
            }
            if model.hasSavedAction {
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
            if model.challengeReady {
                Section(GuardianCopy.text("Verify the child sign-in code")) {
                    SecureField(GuardianCopy.text("Email sign-in code"), text: $model.code)
                        .textContentType(.oneTimeCode).keyboardType(.numberPad).privacySensitive()
                        .accessibilityIdentifier("guardian.nativeAuthCode")
                    Button(GuardianCopy.text("Verify child code and continue")) { Task { await model.verifyCode() } }
                        .disabled(!model.canVerify).accessibilityIdentifier("guardian.nativeAuthVerify")
                }
            }
            if let message = model.message {
                Section { Text(message).accessibilityIdentifier("guardian.nativeAuthResult") }
            }
            if model.busy { ProgressView(GuardianCopy.text("Checking child setup…")) }
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
    @State private var review: ReviewDestination?
    private struct ReviewDestination: Identifiable {
        let id = UUID()
        let scope: ContributorRequestScope
        let pickupLabel: String
    }
    var body: some View {
        Form {
            Section { Text(GuardianCopy.text("Only your own requests and their status appear here. The shopper decides what goes into the basket.")) }
            if household.locked || household.projection == nil {
                Section { Text(GuardianCopy.text("Your child access is being checked. Adult work remains locked.")) }
            } else if let scope = household.projection {
                Section {
                    Text(verbatim: scope.household.label)
                        .font(.headline)
                        .accessibilityIdentifier("guardian.childHousehold")
                }
                Section(GuardianCopy.text("My requests")) {
                    Button(GuardianCopy.text("Refresh my requests")) { Task { await household.refresh() } }
                        .accessibilityIdentifier("guardian.childRequestsRefresh")
                    ForEach(household.requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.originalItem).font(.headline)
                            if let quantity = request.ownQuantity { Text(quantity) }
                            if request.fromPreviousShop == true { Text(ht("From an earlier pickup")) }
                            Text(requestStatus(request)).foregroundStyle(.secondary)
                            if let outcome = request.purchaseOutcome { Text(purchaseStatus(outcome)) }
                            if let clarification = request.clarification { Text(clarification) }
                            if request.ownActionAllowed {
                                HStack {
                                    Button(ht("Edit request")) { household.edit(request) }.buttonStyle(.borderless)
                                    Button(ht("Withdraw request"), role: .destructive) { Task { await household.withdraw(request) } }.buttonStyle(.borderless)
                                }
                            } else {
                                Button(ht("Send a follow-up")) { household.followUp(request) }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if household.requests.isEmpty { Text(ht("No received requests in this view.")) }
                    if household.nextRequestCursor != nil { Button(ht("Load more requests")) { Task { await household.loadMoreRequests() } } }
                }
                Section(household.editing == nil ? ht("New request") : ht("Edit request")) {
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
                        if let scope = household.contributorRequestScope {
                            let pickup = household.requestPickups.first { $0.shopId == UUID(uuidString: scope.targetShopID) }
                            review = .init(scope: scope, pickupLabel: pickup.map(pickupLabel) ?? String(scope.targetShopID.prefix(8)))
                        }
                    }.disabled(household.contributorRequestScope == nil || household.item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("guardian.childRequestReview")
                    switch household.delivery {
                    case .waiting:
                        Text(ht("Waiting for the household to confirm receipt"))
                        Button(ht("Retry the same request")) { Task { await household.retry() } }
                    case .needsReview:
                        Text(ht("Review needed. Check received requests before creating a new request."))
                        Button(ht("I checked received requests; clear this retry")) { Task { await household.discardPendingAfterReview() } }
                    case .received(let receipt): Text(receipt.contributorDeliveryLabel)
                    case .accessEnded: Text(ht("Household access has ended or needs sign-in."))
                    case .localDraft: Text(ht("Draft on screen. Send to ask the household."))
                    }
                }
            }
            if let message = household.notice { Section { Text(message).accessibilityIdentifier("guardian.childRequestsResult") } }
            if household.busy { ProgressView(ht("Checking service…")) }
        }.disabled(household.busy)
        .navigationTitle(GuardianCopy.text("My requests"))
        .sheet(item: $review) { value in
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
        return GuardianCopy.date(pickup.createdAt) + " · " + (collision ? id : prefix)
    }

    private func requestStatus(_ request: OwnRequest) -> String {
        if request.carriedForward == true { return ht("Moved to a later pickup for review") }
        switch request.status {
        case "pending": return request.route == "next" ? ht("Received for next shop") : ht("Received, waiting for review")
        case "clarified": return ht("Clarification requested")
        case "added": return ht("Added to the plan")
        case "deferred": return ht("Saved for next shop")
        case "handled": return ht("Handled")
        case "dismissed": return ht("Not included")
        case "withdrawn": return ht("Withdrawn")
        default: return ht("Check current status")
        }
    }
}
