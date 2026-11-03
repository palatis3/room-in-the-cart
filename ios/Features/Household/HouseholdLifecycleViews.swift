import SwiftUI
import HouseholdClient

struct HouseholdSetupSections: View {
    @ObservedObject var model: HouseholdLifecycleModel
    @State private var clearRetry = false
    var body: some View {
        Group {
            if model.activation != nil {
                Section(ht("Confirmed membership")) {
                    Text(ht("Membership was confirmed. Connect again to finish opening this household."))
                    Button(ht("Connect confirmed household")) { Task { await model.connectConfirmedMembership() } }
                }
            } else if model.pendingMembership != nil {
                Section(ht("Pending household action")) {
                    Text(ht("The result is not confirmed. Retry the same action or check your household list before clearing it."))
                    Button(ht("Retry the same household action")) { Task { await model.retryMembership() } }
                    Button(ht("Clear after checking households")) { clearRetry = true }
                }
            } else {
                Section(ht("Adult household setup")) {
                    TextField(ht("Your household alias"), text: $model.alias)
                    Toggle(ht("I confirm I am an adult"), isOn: $model.adultAttestation)
                    Text(ht("This is your declaration. It does not verify age or establish guardian consent.")).font(.caption)
                    Toggle(ht("Keep my existing work private on this phone"), isOn: $model.keepLocalPrivate)
                }
                Section(ht("Create a household")) {
                    TextField(ht("Household name"), text: $model.householdLabel)
                    Button(ht("Create household")) { Task { await model.createHousehold() } }.disabled(!canContinue)
                }
                Section(ht("Use an invitation")) {
                    SecureField(ht("Invitation code"), text: $model.invitationCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(ht("Paste the code shared by the organizer or shopper. The invitation determines your access."))
                    Button(ht("Join with invitation")) { Task { await model.redeemInvitation() } }.disabled(!canContinue)
                }
            }
            lifecycleNotice(model)
        }.disabled(model.busy)
        .task { await model.restorePending() }
        .confirmationDialog(ht("Clear this local retry?"), isPresented: $clearRetry, titleVisibility: .visible) {
            Button(ht("I checked my households; clear retry"), role: .destructive) { Task { await model.clearPendingMembership() } }
        } message: { Text(ht("Clearing a retry does not undo a household or membership already created by the service.")) }
    }
    private var canContinue: Bool { model.adultAttestation && model.keepLocalPrivate }
}

struct HouseholdPeopleView: View {
    @ObservedObject var model: HouseholdLifecycleModel
    @State private var selectedMember: HouseholdMember?
    var body: some View {
        Form {
            if model.canAdminister {
                Section(ht("People")) {
                    Button(ht("Refresh people")) { Task { await model.loadMembers() } }
                    ForEach(model.members) { member in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(member.alias).font(.headline)
                            Text(member.state == "active" ? ht("Active access") : ht("Access revoked"))
                            if member.memberId != model.scope?.memberId, member.state == "active" {
                                Button(ht("Remove household access"), role: .destructive) { selectedMember = member }
                            }
                        }
                    }
                }
                Section(ht("Invite an adult contributor")) {
                    Text(ht("An adult contributor can send requests. This invitation does not assign a paid seat or shopper authority."))
                    expiryPicker(model)
                    if model.issuanceUncertain { uncertainCreation(model) }
                    else { Button(ht("Create adult invitation")) { Task { await model.createAdultInvitation() } } }
                }
                Section(ht("Managed invitations")) {
                    ForEach(model.invitations) { invitation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(invitation.kind == "adult_contributor" ? ht("Adult contributor") : ht("Scoped helper invitation"))
                            LabeledContent(ht("Reference"), value: String(invitation.id.suffix(8)))
                            Text(accessStatus(invitation.status))
                            LabeledContent(ht("Access expires"), value: householdTime(invitation.expiresAt))
                            if ["pending", "redeemed"].contains(invitation.status) {
                                Button(ht("Revoke invitation"), role: .destructive) { Task { await model.revoke(.invite, targetID: invitation.id) } }
                            }
                        }
                    }
                    Text(ht("Revoking an invitation stops further redemption. Remove membership or revoke its scoped view to end existing access."))
                }
                IssuedInvitationSection(model: model, helperOnly: false)
                lifecycleNotice(model)
            } else { Text(ht("Only the organizer can manage household members and invitations.")) }
        }.disabled(model.busy).navigationTitle(ht("People and invitations"))
        .task { await model.loadMembers() }
        .confirmationDialog(ht("Remove this person's household access?"), isPresented: Binding(get: { selectedMember != nil }, set: { if !$0 { selectedMember = nil } }), titleVisibility: .visible) {
            if let member = selectedMember { Button(ht("Remove household access"), role: .destructive) { Task { await model.revoke(.member, targetID: member.id); selectedMember = nil } } }
        } message: { if let member = selectedMember { Text(member.alias) } }
    }
}

private struct HelperDraftItem: Identifiable, Equatable {
    let id = UUID()
    var label = ""; var amount = ""; var unit = ""; var action = ""
}
struct HouseholdHelperComposer: View {
    @ObservedObject var model: HouseholdLifecycleModel
    @State private var shopLabel = ""
    @State private var language = "en"
    @State private var mode = "read"
    @State private var items = [HelperDraftItem()]
    @State private var reviewed: HelperProjection?
    @State private var approved = false
    @State private var inputNotice: String?
    var body: some View {
        Form {
            if model.canShare {
                Section(ht("Share instructions for this shop")) {
                    Text(ht("Only the fields reviewed here will be shared. Existing budgets, receipts and private notes are not included."))
                    TextField(ht("Name shown for this shop"), text: $shopLabel)
                    Picker(ht("Instruction language"), selection: $language) {
                        Text(ht("English")).tag("en"); Text(ht("Spanish")).tag("es")
                    }
                    Picker(ht("Recipient access"), selection: $mode) {
                        Text(ht("Read instructions")).tag("read")
                        Text(ht("Read and suggest corrections")).tag("edit")
                    }
                    Text(ht("Suggestions wait for shopper review. They do not change the basket or instructions automatically."))
                    expiryPicker(model)
                }
                ForEach($items) { $item in
                    Section(ht("Instruction")) {
                        TextField(ht("Item"), text: $item.label)
                        TextField(ht("Amount, optional"), text: $item.amount)
                        TextField(ht("Unit, optional"), text: $item.unit)
                        TextField(ht("What the cook should do"), text: $item.action, axis: .vertical).lineLimit(2...5)
                        Button(ht("Remove instruction"), role: .destructive) { items.removeAll { $0.id == item.id } }
                    }
                }
                Section {
                    Button(ht("Add an instruction")) { items.append(.init()) }.disabled(items.count >= 200)
                    Button(ht("Review shared fields")) { review() }
                    if let inputNotice { Text(inputNotice) }
                }
                if let reviewed {
                    Section(ht("Recipient preview")) {
                        Text(reviewed.shopLabel).font(.headline)
                        ForEach(Array(reviewed.items.enumerated()), id: \.offset) { _, item in helperInstruction(item) }
                        Toggle(ht("I reviewed these instructions for this recipient"), isOn: $approved)
                        if model.issuanceUncertain { uncertainCreation(model) }
                        else { Button(ht("Create scoped invitation")) { Task { await model.createHelperView(projection: reviewed, mode: mode) } }.disabled(!approved) }
                    }
                }
                if model.issuanceUncertain { NavigationLink(ht("Review managed views")) { HouseholdManagedViewsView(model: model) } }
                IssuedInvitationSection(model: model, helperOnly: true)
                lifecycleNotice(model)
            } else { Text(ht("Only the assigned shopper can share instructions for this shop.")) }
        }.disabled(model.busy).navigationTitle(ht("Shared cook instructions"))
        .onChange(of: items) { _, _ in invalidate() }.onChange(of: shopLabel) { _, _ in invalidate() }
        .onChange(of: language) { _, _ in invalidate() }.onChange(of: mode) { _, _ in invalidate() }
        .onChange(of: model.expiryHours) { _, _ in invalidate() }
    }
    private func invalidate() { reviewed = nil; approved = false; inputNotice = nil }
    private func review() {
        do {
            guard !items.isEmpty else { inputNotice = ht("Add at least one complete instruction before sharing."); return }
            reviewed = try .init(shopLabel: shopLabel.trimmingCharacters(in: .whitespacesAndNewlines), language: language,
                items: items.map { .init(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines), amount: optionalText($0.amount), unit: optionalText($0.unit), action: $0.action.trimmingCharacters(in: .whitespacesAndNewlines)) })
            approved = false; inputNotice = nil
        } catch { inputNotice = ht("Review the shop name and each instruction. Names and actions are required; keep amounts and units short.") }
    }
    private func optionalText(_ value: String) -> String? { let value = value.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
}

struct HouseholdHelperView: View {
    @ObservedObject var model: HouseholdLifecycleModel
    @State private var clearProposal = false
    var body: some View {
        Form {
            if model.isHelper {
                Button(ht("Refresh instructions")) { Task { await model.loadHelper() } }
                if let view = model.helperView {
                    Section {
                        Text(view.shopLabel).font(.headline)
                        LabeledContent(ht("Last updated"), value: householdTime(view.asOf))
                        LabeledContent(ht("Access expires"), value: householdTime(view.expiresAt))
                        ForEach(Array(view.items.enumerated()), id: \.offset) { _, item in helperInstruction(item) }
                    }
                    if let receipt = model.proposalReceipt { Section { Text(receipt.status == "pending" ? ht("Suggestion received for shopper review") : ht("Check current status")) } }
                    if model.pendingProposal != nil {
                        Section(ht("Pending suggestion")) {
                            Text(ht("The result is not confirmed. Retry the same suggestion before writing another one."))
                            Button(ht("Retry the same suggestion")) { Task { await model.retryProposal() } }
                            Button(ht("Review and clear this suggestion retry")) { clearProposal = true }
                        }
                    } else if view.canPropose {
                        Section(ht("Suggest a correction")) {
                            TextField(ht("Suggestion"), text: $model.correction, axis: .vertical).lineLimit(3...7)
                            Text(ht("Suggestions wait for shopper review. They do not change the basket or instructions automatically."))
                            Button(ht("Send suggestion for review")) { Task { await model.sendProposal() } }
                        }
                    }
                }
                lifecycleNotice(model)
            } else { Text(ht("This scoped view is no longer available. Ask the shopper for a fresh invitation.")) }
        }.disabled(model.busy).navigationTitle(ht("Cook instructions")).task { await model.loadHelper() }
        .task(id: model.helperView?.expiresAt) {
            guard let date = model.helperView.flatMap({ serviceDate($0.expiresAt) }) else { return }
            if date > Date() { try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow)) }
            guard !Task.isCancelled else { return }; await model.expireHelperIfNeeded()
        }
        .confirmationDialog(ht("Clear this suggestion retry?"), isPresented: $clearProposal, titleVisibility: .visible) {
            Button(ht("Refresh instructions and clear retry"), role: .destructive) { Task { await model.clearPendingProposalAfterReview() } }
        } message: { Text(ht("Clearing a local retry does not remove a suggestion already received by the shopper.")) }
    }
}

struct HouseholdManagedViewsView: View {
    @ObservedObject var model: HouseholdLifecycleModel
    @State private var revoking: ManagedHelperView?
    var body: some View {
        Form {
            if model.canAdminister || model.canShare {
                Section {
                    Button(ht("Refresh managed views")) { Task { await model.loadManagedViews() } }
                    if model.canShare { NavigationLink(ht("Create shared cook instructions")) { HouseholdHelperComposer(model: model) } }
                    Text(ht("These are the views you may manage. Previously exported copies keep their original date."))
                }
                ForEach(model.managedViews) { view in
                    Section(view.shopLabel) {
                        Text(view.mode == "edit" ? ht("Read and suggest corrections") : ht("Read instructions"))
                        Text(accessStatus(view.status))
                        if let alias = view.recipientAlias { LabeledContent(ht("Recipient"), value: alias) }
                        LabeledContent(ht("Access expires"), value: householdTime(view.expiresAt))
                        if ["available", "active"].contains(view.status) {
                            if model.canShare, view.shopId == model.scope?.shopId {
                                NavigationLink(ht("Review suggestions")) { HouseholdHelperProposalsView(model: model, grantID: view.id) }
                            }
                            Button(ht("Revoke scoped access"), role: .destructive) { revoking = view }
                        }
                    }
                }
                if model.managedViews.isEmpty { Text(ht("No managed views are available.")) }
                lifecycleNotice(model)
            } else { Text(ht("Current household permission is required to manage shared views.")) }
        }.disabled(model.busy).navigationTitle(ht("Manage shared views")).task { await model.loadManagedViews() }
        .confirmationDialog(ht("End this recipient's live access?"), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            if let view = revoking { Button(ht("Revoke scoped access"), role: .destructive) { Task { await model.revoke(.view, targetID: view.id); revoking = nil } } }
        } message: { Text(ht("Previously exported copies cannot be recalled.")) }
    }
}
private struct HouseholdHelperProposalsView: View {
    @ObservedObject var model: HouseholdLifecycleModel
    let grantID: String
    var body: some View {
        Form {
            if model.canShare {
                Button(ht("Refresh suggestions")) { Task { await model.loadProposals(grantID: grantID) } }
                Text(ht("Suggestions are pending review. Review any basket change separately using the current shop."))
                if model.proposalsGrantID == grantID {
                    ForEach(model.proposals) { proposal in
                        Section {
                            Text(proposal.correction)
                            LabeledContent(ht("Received"), value: householdTime(proposal.createdAt))
                            LabeledContent(ht("Instruction revision reviewed"), value: proposal.baseRevision.formatted())
                            Text(proposal.status == "pending" ? ht("Pending review") : ht("Check current status"))
                        }
                    }
                    if model.proposals.isEmpty { Text(ht("No suggestions have been received.")) }
                }
                lifecycleNotice(model)
            } else { Text(ht("Shopper access required")) }
        }.disabled(model.busy).navigationTitle(ht("Review suggestions")).task { await model.loadProposals(grantID: grantID) }
    }
}

struct HouseholdGuardianView: View {
    @ObservedObject var model: HouseholdLifecycleModel
    @State private var selected: GuardianConsent?
    var body: some View {
        Form {
            if model.scope != nil, !model.isHelper {
                Section {
                    Text(ht("Child enrollment is unavailable until verified guardian consent is connected."))
                    Text(ht("Only consents covered by your verified guardian relationships appear here."))
                    Button(ht("Refresh guardian controls")) { Task { await model.loadConsents() } }
                }
                ForEach(model.consents) { consent in
                    Section(consent.childAlias) {
                        LabeledContent(ht("Notice version"), value: consent.noticeVersion)
                        LabeledContent(ht("Consent recorded"), value: householdTime(consent.grantedAt))
                        if let revoked = consent.revokedAt { LabeledContent(ht("Consent withdrawn"), value: householdTime(revoked)) }
                        else { Button(ht("Withdraw consent"), role: .destructive) { selected = consent } }
                    }
                }
                if model.consents.isEmpty { Text(ht("No guardian consents are available in this scope.")) }
                lifecycleNotice(model)
            } else { Text(ht("Guardian controls require your verified household access.")) }
        }.disabled(model.busy).navigationTitle(ht("Guardian controls")).task { await model.loadConsents() }
        .confirmationDialog(ht("Withdraw this child's consent?"), isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let consent = selected { Button(ht("Withdraw consent"), role: .destructive) { Task { await model.withdrawConsent(consent); selected = nil } } }
        } message: { Text(ht("Withdrawal ends the child's current online access and cannot be undone by restoring a backup.")) }
    }
}

private struct IssuedInvitationSection: View {
    @ObservedObject var model: HouseholdLifecycleModel
    let helperOnly: Bool
    var body: some View {
        if let issued = model.issued, (issued.grantId != nil) == helperOnly {
            Section(ht("Invitation ready")) {
                LabeledContent(ht("Access expires"), value: householdTime(issued.expiresAt))
                Text(issued.token).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                ShareLink(item: issued.token) { Label(ht("Share invitation code"), systemImage: "square.and.arrow.up") }
                Text(ht("This code is shown after creation. Share it only with the intended adult recipient."))
                Button(ht("Revoke this invitation"), role: .destructive) { Task { await model.revoke(issued.grantId == nil ? .invite : .view, targetID: issued.grantId ?? issued.inviteId) } }
            }
        }
    }
}
@MainActor @ViewBuilder private func lifecycleNotice(_ model: HouseholdLifecycleModel) -> some View {
    if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("household.lifecycle.notice") } }
    if model.busy { ProgressView(ht("Checking service…")) }
}
@ViewBuilder private func helperInstruction(_ item: HelperInstruction) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(item.label).font(.headline)
        if let amount = item.amount { Text(amount) }
        if let unit = item.unit { Text(unit) }
        Text(item.action)
    }.accessibilityElement(children: .combine)
}
@MainActor @ViewBuilder private func expiryPicker(_ model: HouseholdLifecycleModel) -> some View {
    Stepper(value: Binding(get: { model.expiryHours }, set: { model.expiryHours = $0 }), in: 1...168) {
        LabeledContent(ht("Expires after hours"), value: model.expiryHours.formatted())
    }
}
@MainActor @ViewBuilder private func uncertainCreation(_ model: HouseholdLifecycleModel) -> some View {
    Text(ht("Creation was not confirmed. Another invitation may remain active until it expires. Review managed access before creating a new one."))
    Button(ht("I reviewed managed access; allow a new invitation")) { model.acknowledgeUncertainCreation() }
        .disabled(!model.managementReviewed)
}
private func accessStatus(_ status: String) -> String {
    switch status { case "pending", "available": return ht("Waiting for the recipient")
    case "redeemed": return ht("Invitation redeemed"); case "active": return ht("Active access")
    case "revoked": return ht("Access revoked"); case "expired": return ht("Access expired"); default: return ht("Check current status") }
}
