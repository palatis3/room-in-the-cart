import SwiftUI
import UIKit
import HouseholdClient

struct HouseholdSettingsView: View {
    @ObservedObject var model: HouseholdModel
    var continuesAfterWorkspaceLock = false
    @State private var visibleEntry: UUID?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceAccess
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var lastCallItemFocused: Bool
    @AccessibilityFocusState private var resultFocused: Bool
    @State private var requestReview: RequestReviewPresentation?
    @State private var resultBeforeReview: String?
    private struct RequestReviewPresentation: Identifiable {
        let id = UUID()
        let scope: ContributorRequestScope
        let capture: Bool
    }
    var body: some View {
        Group {
            if !model.locked, let scope = model.projection, scope.grantId != nil {
                if let lifecycle = model.lifecycle {
                    HouseholdHelperView(model: lifecycle, expectedScope: scope)
                        .id(scope.grantId)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink {
                                    WorkingForm { accountControls }
                                        .navigationTitle(ht("Account"))
                                } label: { Label(ht("Account"), systemImage: "person.crop.circle") }
                                    .accessibilityIdentifier("household.cookAccount")
                            }
                        }
                } else {
                    ProgressView(ht("Checking service…"))
                }
            } else { householdForm }
        }
        .onChange(of: scenePhase) { _, value in if value == .background { model.lock() } }
    }

    private var showsAdultSignIn: Bool { model.configured && !model.locked && model.identity == nil }

    private var householdForm: some View {
        WorkingForm {
            if let scope = model.projection, !scope.enrolled {
                Section { Text(ht("Access has ended. Choose an available workspace.")) }
            } else if model.projection == nil, model.configured {
                Section {
                    Text(ht("Your lists and meal plans stay on this iPhone when you join."))
                        .foregroundStyle(Theme.secondary)
                }
            }
            if !model.configured {
                Section {
                    Text(ht("Sending a request to someone else requires access to their household."))
                    Text(ht("You can make a private shopping list, compare packs and plan dinners on this iPhone without an account."))
                        .foregroundStyle(Theme.secondary)
                } header: {
                    Text(ht("Household sign-in is unavailable"))
                        .marketJournalTitle(.title2).textCase(nil)
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
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        Button(ht("Email me a code")) { Task { await model.sendCode() } }
                            .disabled(model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.codeSent {
                            SecureField(ht("Email sign-in code"), text: $model.code).textContentType(.oneTimeCode).privacySensitive()
                            Button(ht("Verify code")) {
                                let entry = visibleEntry
                                Task {
                                    await model.verifyCode {
                                        continuesAfterWorkspaceLock && entry != nil && entry == visibleEntry
                                    }
                                }
                            }.disabled(model.code.isEmpty)
                        }
                    } else {
                        Text(ht("Email sign-in is unavailable. You can still use your private shopping tools."))
                    }
                    if let notice = model.notice { Text(notice).accessibilityIdentifier("household.notice") }
                }
            } else {
                if model.workspaceListState == .unavailable {
                    Section(ht("Choose household")) {
                        Text(ht("Your household list could not be loaded. Check your connection and try again."))
                        Button(ht("Retry loading households")) { Task { await model.retryWorkspaceList() } }
                            .accessibilityIdentifier("household.workspaces.retry")
                    }
                }
                if let projection = model.projection, projection.enrolled {
                    Section {
                        HouseholdScopeHeading(scope: projection)
                        SharedPickingLink(household: model)
                        if projection.canSelectShop == true || projection.selectionRequired == true {
                            NavigationLink(ht("Choose shared shop")) { HouseholdShopSelector(household: model) }
                        }
                        if model.canReviewHouseholdRequests {
                            NavigationLink(ht("Review family requests")) { HouseholdInboxView(model: model) }
                        }
                    }
                    if projection.capabilities.contains("own_requests"), projection.shopId != nil || model.selectedRequestPickupID != nil || model.editing != nil || model.followingUp != nil {
                        if model.editing == nil, model.followingUp == nil,
                           let shop = model.selectedRequestPickupID ?? projection.shopId.flatMap(UUID.init(uuidString:)),
                           model.adultRequestScope(shop: shop, capability: "adult_last_call") != nil {
                            AdultShopLastCall(household: model, shopID: shop) { late in
                                model.forNextShop = late
                                lastCallItemFocused = true
                            }
                        }
                        Section(model.contributorDraftTitle) {
                            if model.editing != nil || model.followingUp != nil { Button(ht("Cancel edit")) { model.cancelEdit() } }
                            if model.followingUp != nil { Text(ht("This follow-up leaves the accepted request unchanged.")) }
                            TextField(ht("Item"), text: $model.item).focused($lastCallItemFocused)
                            TextField(ht("Quantity, optional"), text: $model.quantity)
                            if model.requestRequiresNextShop {
                                Text(ht("Request for next shop"))
                            } else if model.editing == nil {
                                Toggle(ht("Ask for next shop"), isOn: $model.forNextShop)
                            }
                            Button(ht("Review request before sending")) {
                                openRequestReview(capture: false)
                            }.buttonStyle(PrimaryAction()).disabled(!canSend).accessibilityIdentifier("household.request.review")
                            Button(ht("Capture and review a request")) {
                                openRequestReview(capture: true)
                            }.disabled(model.contributorRequestScope == nil).accessibilityIdentifier("household.request.capture")
                            delivery
                        }
                    } else if projection.capabilities.contains("own_requests") {
                        switch model.delivery {
                        case .waiting, .needsReview, .received:
                            Section(ht("My requests")) { delivery }
                        default: EmptyView()
                        }
                    }
                    if projection.capabilities.contains("own_requests"), projection.shopId != nil || !model.requests.isEmpty {
                        Section(ht("My requests")) {
                            ForEach(model.requests) { request in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(request.originalItem).font(.headline)
                                    if let quantity = request.ownQuantity { Text(quantity) }
                                    RequestReadTimeLabel(asOf: model.requestReadTimes.rows[request.id])
                                    if let proposed = model.pendingCorrection(for: request) {
                                        LabeledContent(ht("Correction on this device"), value: proposed)
                                    }
                                    AdultProductReferenceLink(household: model, request: request)
                                    TripSubstitutionLink(household: model, request: request)
                                    if request.fromPreviousShop == true { Text(ht("From an earlier pickup")) }
                                    Text(shopperRequestStatus(request)).font(.body.weight(.semibold))
                                    if let outcome = request.purchaseOutcome { Text(purchaseStatus(outcome)) }
                                    else if request.status == "added" { Text(ht("Purchase still unknown.")).foregroundStyle(Theme.secondary) }
                                    if let clarification = request.clarification {
                                        Text(verbatim: clarification)
                                        if request.canReportClarification == true, let field = SharedMessageField(.clarification, request.id, request.revision, .question, clarification) {
                                            SharedSafetyButton(channel: model.sharedSafetyChannel(), fields: [field])
                                        }
                                    }
                                    if request.ownActionAllowed {
                                        OwnRequestEditActions(model: model, request: request)
                                    } else if request.status != "withdrawn" {
                                        Button(ht("Send a follow-up")) { model.followUp(request) }.buttonStyle(.borderless)
                                    }
                                }.accessibilityElement(children: projection.supportsSharedContentSafety || projection.capabilities.contains("adult_product_reference") || projection.capabilities.contains("trip_substitutions") ? .contain : .combine)
                                .accessibilityIdentifier("household.ownRequest." + request.id)
                            }
                            if model.requests.isEmpty {
                                Text(ht("No received requests in this view."))
                                RequestReadTimeLabel(asOf: model.requestReadTimes.emptyPage)
                            }
                            if model.nextRequestCursor != nil {
                                Button(ht("Load more requests")) { Task { await model.loadMoreRequests() } }
                            }
                        }
                    }
                    if let lifecycle = model.lifecycle { HouseholdInvitedDinnerEntry(model: lifecycle, scope: projection) }
                    Section(ht("Connected household")) {
                        HouseholdPantryLink(household: model)
                        HouseholdMealPreferencesLink(household: model)
                        if model.membershipSession != nil {
                            NavigationLink(tr("Household membership")) { MembershipEntryView(household: model) }
                                .accessibilityIdentifier("household.membership")
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
                    }
                    if let lifecycle = model.lifecycle {
                        Section(ht("Household access")) {
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
                } else {
                    if let email = model.identity?.email {
                        Section(ht("Signed in as")) {
                            Text(verbatim: email).privacySensitive()
                            Button(ht("Use another account")) { Task { await model.signOut() } }
                        }
                    }
                    if !model.workspaces.isEmpty {
                        Section(ht("Choose household")) {
                            Toggle(ht("Keep my existing work private on this phone"), isOn: $model.keepLocalPrivate)
                            ForEach(model.workspaces) { workspace in
                                Button(workspace.label) { Task { await model.join(workspace) } }.disabled(!model.keepLocalPrivate)
                            }
                        }
                    }
                    if model.workspaceListState == .loaded, model.workspaces.isEmpty {
                        Text(ht("This account has no active household access. Your private work stays on this phone."))
                    }
                    if let lifecycle = model.lifecycle {
                        HouseholdSetupSections(model: lifecycle, showsNewSetup: model.workspaceListState == .loaded)
                    }
                }
            }
            if model.projection?.grantId == nil {
                Section(GuardianCopy.text("Child sign-in")) {
                    GuardianChildEntryButton(household: model)
                }
            }
            if !model.configured || (!model.locked && model.identity == nil) {
                Section { PrivateListSharingGuide() }
            }
            accountControls
            // Shop selection briefly clears the projection. Keep this destination
            // mounted while it rechecks the new scope before showing records.
            if !model.locked, model.identity != nil, model.projection?.grantId == nil {
                Section {
                    NavigationLink(HistoryCopy.text("Prices and period budgets")) {
                        HistoryRecordsEntryView(household: model)
                    }.accessibilityIdentifier("household.priceBudgetHistory")
                }
            }
            if !model.locked, model.identity != nil, model.projection?.grantId == nil {
                Section {
                    NavigationLink(PlacementCopy.text("Shared placement reports")) { PlacementRecordsEntryView(household: model) }
                        .accessibilityIdentifier("household.placementReports")
                }
            }
            HelpSettingsSection().environmentObject(model)
            if !showsAdultSignIn, let notice = model.notice { Section { Text(notice).accessibilityIdentifier("household.notice") } }
            if model.busy { ProgressView(ht("Checking service…")) }
        }
        .onAppear { visibleEntry = UUID() }
        .onDisappear {
            visibleEntry = nil
            model.lifecycle?.invalidateInvitationPreview()
        }
        .disabled(model.busy)
        .navigationTitle(ht("Household"))
        .sheet(item: $requestReview, onDismiss: {
            resultFocused = model.draftDelivery.hasNewRequestResult(since: resultBeforeReview)
            resultBeforeReview = nil
        }) { selected in
            NavigationStack { ContributorRequestCaptureView(household: model, scope: selected.scope, capture: selected.capture) }
        }
    }

    @ViewBuilder private var accountControls: some View {
        if !model.locked, model.identity != nil {
            Section(ht("Account")) {
                if let scope = model.projection, scope.enrolled, scope.grantId == nil, ["shopper", "organizer"].contains(scope.role) {
                    Button(ht("Return to private shopping")) {
                        workspace.protect()
                        model.lock()
                        dismiss()
                    }.accessibilityIdentifier("household.returnToPrivate")
                }
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
                    WorkingForm {
                        Section { Text(ht("Account deletion is unavailable on this iPhone. Open Support in Settings for help.")) }
                        AccountDeletionScope()
                        GuardianDeletionSupportSection()
                    }.navigationTitle(ht("Account deletion"))
                }
            }.accessibilityIdentifier("household.accountDeletion")
        }
    }

    private func openRequestReview(capture: Bool) {
        // Finish the draft field's editing callbacks before presenting its review.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if let scope = model.contributorRequestScope {
            resultBeforeReview = model.delivery.requestResultID
            requestReview = .init(scope: scope, capture: capture)
        }
    }
    private var canSend: Bool {
        guard !model.item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return model.contributorRequestScope != nil
    }
    @ViewBuilder private var delivery: some View {
        switch model.draftDelivery {
        case .localDraft: Text(ht("Draft on this iPhone."))
        case .waiting:
            Label(model.waitingRequestText, systemImage: "clock").accessibilityFocused($resultFocused)
            Button(ht("Retry the same request")) { Task { await model.retry() } }
        case .needsReview:
            Text(ht("Review needed. Check received requests before creating a new request.")).accessibilityFocused($resultFocused)
            if model.canReviewRejectedCorrection {
                ContributorCorrectionButton(model: model)
            }
            Button(ht("I checked received requests; clear this retry")) { Task { await model.discardPendingAfterReview() } }
        case .received(let receipt): Label(receipt.contributorDeliveryLabel, systemImage: "checkmark.circle").accessibilityFocused($resultFocused)
        case .accessEnded: Text(ht("Household access has ended or needs sign-in."))
        }
    }

}

struct ContributorCorrectionButton: View {
    @ObservedObject var model: HouseholdModel
    @State private var replacement: HouseholdModel.DraftReplacement?

    var body: some View {
        Button(ht("Review my correction")) {
            if let draft = model.correctionReplacingDraft {
                replacement = draft
            } else {
                Task { await model.reviewRejectedCorrection() }
            }
        }
        .confirmationDialog(ht("Replace your current draft with the saved correction?"), isPresented: Binding(
            get: { replacement != nil }, set: { if !$0 { replacement = nil } }
        ), titleVisibility: .visible, presenting: replacement) { draft in
            Button(ht("Replace draft"), role: .destructive) {
                Task { await model.reviewRejectedCorrection(replacing: draft) }
            }
            Button(ht("Cancel"), role: .cancel) {}
        }
        .onChange(of: model.correctionReplacingDraft) { _, _ in replacement = nil }
    }
}

struct OwnRequestEditActions: View {
    @ObservedObject var model: HouseholdModel
    let request: OwnRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.edit(request)
            } label: {
                Label(ht("Edit request"), systemImage: "pencil")
                    .foregroundStyle(Theme.action)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Divider()
            ContributorWithdrawalButton(model: model, request: request)
        }
    }
}

struct ContributorWithdrawalButton: View {
    @ObservedObject var model: HouseholdModel
    let request: OwnRequest
    @State private var reviewed: OwnRequest?

    var body: some View {
        Button(role: .destructive) {
            reviewed = request
        } label: {
            Label(ht("Withdraw request"), systemImage: "minus.circle")
                .foregroundStyle(Theme.error)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
            .accessibilityIdentifier("household.withdrawRequest")
            .buttonStyle(.borderless)
            .disabled(model.busy)
            .alert(ht("Withdraw this request?"), isPresented: Binding(
                get: { reviewed != nil }, set: { if !$0 { reviewed = nil } }
            ), presenting: reviewed) { original in
                Button(ht("Withdraw request"), role: .destructive) {
                    Task { await model.withdraw(original) }
                }
                Button(ht("Cancel"), role: .cancel) {}
            } message: { original in
                Text(verbatim: [original.originalItem, original.ownQuantity].compactMap { $0 }.joined(separator: " · "))
            }
            .onChange(of: request) { _, _ in reviewed = nil }
    }
}


/// Uses only the household and pickup returned for the current adult workspace.
struct HouseholdScopeHeading: View {
    let scope: HouseholdBootstrap
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: scope.household.label)
                .marketJournalTitle(.title2)
                .privacySensitive()
                .accessibilityIdentifier("household.scope.name")
            if let shop = scope.shopId {
                BrandScopeLabel(ht("Pickup") + " · " + String(shop.prefix(8)), systemImage: "bag")
                .accessibilityIdentifier("household.scope.pickup")
            }
            if scope.role == "shopper", scope.shopId != nil {
                Text(ht("You’re doing the shopping for this pickup."))
            } else if scope.capabilities.contains("household_admin") {
                Text(mtr("Household organizer"))
            } else if scope.capabilities.contains("own_requests") {
                Text(ht("You can send grocery requests."))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }
}
