import SwiftUI
import HouseholdClient

struct HouseholdSettingsView: View {
    @ObservedObject var model: HouseholdModel
    var fromPrivateSettings = false
    @State private var visibleEntry: UUID?
    @Environment(\.scenePhase) private var scenePhase
    @State private var requestReview: RequestReviewPresentation?
    private struct RequestReviewPresentation: Identifiable {
        let id = UUID()
        let scope: ContributorRequestScope
        let capture: Bool
    }
    var body: some View {
        Form {
            HelpSettingsSection().environmentObject(model)
            Section {
                Text(ht("Your private work stays on this phone. Signing in does not upload it."))
                    .foregroundStyle(.secondary)
            }
            if !model.configured {
                Section(ht("Household access")) {
                    Label(ht("Household service is not configured"), systemImage: "network.slash")
                    Text(ht("Private shopping tools work without an account. Household sign-in will be available when the service is connected."))
                }
            } else if model.locked {
                Section(ht("Protected account")) {
                    Button(ht("Unlock household access")) { Task { await model.unlock() } }
                    Button(ht("Sign out")) { Task { await model.signOut() } }
                }
            } else if model.identity == nil {
                Section(ht("Adult sign-in")) {
                    Button(ht("Resume saved account")) { Task { await model.unlock() } }
                    if model.emailOTPEnabled {
                    TextField(ht("Email"), text: $model.email).textContentType(.emailAddress)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(ht("Email me a code")) { Task { await model.sendCode() } }
                        .disabled(model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.codeSent {
                        SecureField(ht("Email sign-in code"), text: $model.code).textContentType(.oneTimeCode)
                        Button(ht("Verify code")) {
                            let entry = visibleEntry
                            Task {
                                await model.verifyCode {
                                    fromPrivateSettings && entry != nil && entry == visibleEntry
                                }
                            }
                        }.disabled(model.code.isEmpty)
                    }
                    } else {
                        Text(ht("Email sign-in is not ready yet. Your private shopping tools work without an account."))
                    }
                }
            } else {
                if let projection = model.projection {
                    Section(ht("Connected household")) {
                        Text(projection.household.label)
                        Text(ht("Access is checked by the household service."))
                        if projection.canSelectShop == true || projection.selectionRequired == true {
                            NavigationLink(ht("Choose shared shop")) { HouseholdShopSelector(household: model) }
                        }
                        if projection.canSetRequestQueue == true {
                            Button(ht(projection.requestQueueEnabled ? "Turn off and clear unsent offline requests" : "Allow offline requests on this iPhone for up to 24 hours")) {
                                Task { await model.setRequestQueuePermission(!projection.requestQueueEnabled) }
                            }.disabled(model.busy).accessibilityIdentifier("household.request.queuePermission")
                        }
                        Button(ht("Refresh household")) { Task { await model.refresh() } }
                        if model.sharedShop != nil { NavigationLink(ht("Open shared household shop")) { HouseholdShopView(model: model) } }
                        if model.storeQuoteScope != nil {
                            NavigationLink(StoreQuoteCopy.text("Two entered store quotes")) { SharedStoreQuotesView(household: model) }
                                .accessibilityIdentifier("sharedShop.storeQuotes")
                        }
                        if projection.capabilities.contains("meal_proposals") {
                            NavigationLink(ht("Propose a meal move")) { SharedMealMovesView(household: model) }
                        }
                        if model.canReviewHouseholdRequests {
                            NavigationLink(ht("Review family requests")) { HouseholdInboxView(model: model) }
                        }
                    }
                    if let lifecycle = model.lifecycle {
                        Section(ht("Household access")) {
                            if lifecycle.isHelper { NavigationLink(ht("Cook instructions")) { HouseholdHelperView(model: lifecycle) } }
                            if lifecycle.canAdminister { NavigationLink(ht("People and invitations")) { HouseholdPeopleView(model: lifecycle) } }
                            if lifecycle.canShare || lifecycle.canAdminister { NavigationLink(ht("Manage shared views")) { HouseholdManagedViewsView(model: lifecycle) } }
                            if !lifecycle.isHelper { NavigationLink(ht("Guardian controls")) { GuardianControlsEntry(household: model, lifecycle: lifecycle) } }
                            if lifecycle.canReviewDevices {
                                NavigationLink(DeviceManagementCopy.text("Household devices")) {
                                    if let devices = lifecycle.makeDevicesModel() { HouseholdDevicesView(model: devices) }
                                }.accessibilityIdentifier("household.devices.settingsEntry")
                            }
                        }
                    }
                    if projection.capabilities.contains("own_requests"), projection.shopId != nil || !model.requests.isEmpty {
                        Section(ht("My requests")) {
                            ForEach(model.requests) { request in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(request.originalItem).font(.headline)
                                    if let quantity = request.ownQuantity { Text(quantity) }
                                    if request.fromPreviousShop == true { Text(ht("From an earlier pickup")) }
                                    Text(status(request)).foregroundStyle(.secondary)
                                    if let outcome = request.purchaseOutcome { Text(purchaseStatus(outcome)) }
                                    if let clarification = request.clarification { Text(clarification) }
                                    if request.ownActionAllowed {
                                        HStack {
                                            Button(ht("Edit request")) { model.edit(request) }.buttonStyle(.borderless)
                                            Button(ht("Withdraw request"), role: .destructive) { Task { await model.withdraw(request) } }.buttonStyle(.borderless)
                                        }
                                    } else {
                                        Button(ht("Send a follow-up")) { model.followUp(request) }.buttonStyle(.borderless)
                                    }
                                }.accessibilityElement(children: .combine)
                                .accessibilityIdentifier("household.ownRequest." + request.id)
                            }
                            if model.requests.isEmpty { Text(ht("No received requests in this view.")) }
                            if model.nextRequestCursor != nil {
                                Button(ht("Load more requests")) { Task { await model.loadMoreRequests() } }
                            }
                        }
                    }
                    if projection.capabilities.contains("own_requests"), projection.shopId != nil || model.editing != nil || model.followingUp != nil {
                        Section(model.editing == nil ? ht("New request") : ht("Edit request")) {
                            if model.editing != nil || model.followingUp != nil { Button(ht("Cancel edit")) { model.cancelEdit() } }
                            if model.followingUp != nil { Text(ht("This follow-up leaves the accepted request unchanged.")) }
                            TextField(ht("Item"), text: $model.item)
                            TextField(ht("Quantity, optional"), text: $model.quantity)
                            if model.editing == nil { Toggle(ht("Ask for next shop"), isOn: $model.forNextShop) }
                            Button(ht("Review request before sending")) {
                                if let scope = model.contributorRequestScope { requestReview = .init(scope: scope, capture: false) }
                            }.disabled(!canSend).accessibilityIdentifier("household.request.review")
                            Button(ht("Capture and review a request")) {
                                if let scope = model.contributorRequestScope { requestReview = .init(scope: scope, capture: true) }
                            }.disabled(model.contributorRequestScope == nil).accessibilityIdentifier("household.request.capture")
                            delivery
                        }
                    }
                } else {
                    Section(ht("Choose household")) {
                        Toggle(ht("Keep my existing work private on this phone"), isOn: $model.keepLocalPrivate)
                        ForEach(model.workspaces) { workspace in
                            Button(workspace.label) { Task { await model.join(workspace) } }.disabled(!model.keepLocalPrivate)
                        }
                        if model.workspaces.isEmpty { Text(ht("No active household access is available for this account.")) }
                    }
                    if let lifecycle = model.lifecycle { HouseholdSetupSections(model: lifecycle) }
                }
                Section {
                    Button(ht("Sign out"), role: .destructive) { Task { await model.signOut() } }
                    Button(ht("Sign out all devices"), role: .destructive) { Task { await model.signOut(allDevices: true) } }
                }
            }
            Section {
                if let exit = model.householdExit, model.identity != nil, !model.locked, model.projection?.grantId == nil {
                    NavigationLink(ht("Leave a household")) { HouseholdExitView(account: model, exit: exit) }
                }
                NavigationLink(ht("Account deletion")) {
                    if let deletion = model.accountDeletion {
                        AccountDeletionView(account: model, deletion: deletion)
                    } else {
                        Form {
                            Section { Text(ht("This iPhone has no household service connection configured. Account deletion is unavailable.")) }
                            AccountDeletionScope()
                        }.navigationTitle(ht("Account deletion"))
                    }
                }.accessibilityIdentifier("household.accountDeletion")
            }
            if model.identity != nil {
                Section {
                    NavigationLink(PlacementCopy.text("Shared placement reports")) { PlacementRecordsEntryView(household: model) }
                        .accessibilityIdentifier("household.placementReports")
                }
            }
            Section {
                GuardianChildEntryButton(household: model)
            }
            if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("household.notice") } }
            if model.busy { ProgressView(ht("Checking service…")) }
        }
        .onAppear { visibleEntry = UUID() }
        .onDisappear { visibleEntry = nil }
        .disabled(model.busy)
        .navigationTitle(ht("Household"))
        .sheet(item: $requestReview) { selected in
            NavigationStack { ContributorRequestCaptureView(household: model, scope: selected.scope, capture: selected.capture) }
        }
        .onChange(of: scenePhase) { _, value in if value == .background { model.lock() } }
    }
    private var canSend: Bool {
        guard !model.item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch model.delivery { case .waiting, .needsReview, .accessEnded: return false; default: return true }
    }
    @ViewBuilder private var delivery: some View {
        switch model.delivery {
        case .localDraft: Text(ht("Draft on screen. Send to ask the household."))
        case .waiting:
            Label(ht("Waiting for the household to confirm receipt"), systemImage: "clock")
            Button(ht("Retry the same request")) { Task { await model.retry() } }
        case .needsReview:
            Text(ht("Review needed. Check received requests before creating a new request."))
            Button(ht("I checked received requests; clear this retry")) { Task { await model.discardPendingAfterReview() } }
        case .received: Label(ht("Received by the household"), systemImage: "checkmark.circle")
        case .accessEnded: Text(ht("Household access has ended or needs sign-in."))
        }
    }
    private func status(_ request: OwnRequest) -> String {
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
