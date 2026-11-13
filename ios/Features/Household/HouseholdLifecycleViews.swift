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
                    Text(ht("Leave your display name blank to keep your existing name in this household. If you are joining for the first time, we request “Household member” as your name.")).font(.caption)
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
                if model.canReviewDevices {
                    Section {
                        NavigationLink(DeviceManagementCopy.text("Household devices")) {
                            if let devices = model.makeDevicesModel() { HouseholdDevicesView(model: devices) }
                        }.accessibilityIdentifier("household.devices.entry")
                    }
                }
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
                ForEach(items) { item in
                    let fields = dinnerDraftBinding(item, in: $items)
                    Section(ht("Instruction")) {
                        TextField(ht("Item"), text: fields.label)
                        TextField(ht("Amount, optional"), text: fields.amount)
                        TextField(ht("Unit, optional"), text: fields.unit)
                        TextField(ht("What the cook should do"), text: fields.action, axis: .vertical).lineLimit(2...5)
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
                        LabeledContent(ht("Current instruction revision"), value: view.revision.formatted())
                        LabeledContent(ht("Last updated"), value: householdTime(view.asOf))
                            .accessibilityIdentifier("helper.instructions.asOf")
                        LabeledContent(ht("Access expires"), value: householdTime(view.expiresAt))
                        ForEach(Array(view.items.enumerated()), id: \.offset) { _, item in helperInstruction(item) }
                    }
                    if let receipt = model.proposalReceipt {
                        Section {
                            Text(ht("Suggestion received for shopper review"))
                            LabeledContent(ht("Instruction revision reviewed"), value: receipt.baseRevision.formatted())
                        }
                    }
                    if let pending = model.pendingProposal {
                        Section(ht("Pending suggestion")) {
                            if model.proposalReceipt == nil {
                                if let revision = pending.reviewedRevision {
                                    LabeledContent(ht("Instruction revision reviewed"), value: revision.formatted())
                                }
                                Text(ht("The result is not confirmed. Retry the same suggestion before writing another one."))
                            }
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
                                NavigationLink(ht("Review and replace shared instructions")) { HouseholdHelperReviewView(lifecycle: model, grantID: view.id) }
                                    .accessibilityIdentifier("helperReview.openReplacement")
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
                            switch proposal.status {
                            case "pending":
                                Text(ht("Pending review"))
                                NavigationLink(ht("Review this suggestion")) { HouseholdHelperReviewView(lifecycle: model, grantID: grantID, proposalID: proposal.id) }
                                    .accessibilityIdentifier("helperReview.openSuggestion")
                            case "reviewed": Text(ht("Suggestion reviewed"))
                            case "dismissed": Text(ht("Suggestion dismissed"))
                            default: Text(ht("Check current status"))
                            }
                        }
                    }
                    if model.proposalCursor != nil {
                        Button(ht("Load more suggestions")) { Task { await model.loadProposals(grantID: grantID, more: true) } }
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

private struct HelperReviewDraft: Equatable {
    var label: String
    var language: String
    var items: [HelperDraftItem]
    init(_ projection: HelperProjection) {
        label = projection.shopLabel; language = projection.language
        items = projection.items.map { HelperDraftItem(label: $0.label, amount: $0.amount ?? "", unit: $0.unit ?? "", action: $0.action) }
    }
    func projection() throws -> HelperProjection {
        try HelperProjection(shopLabel: label, language: language, items: items.map {
            HelperInstruction(label: $0.label, amount: $0.amount.isEmpty ? nil : $0.amount,
                              unit: $0.unit.isEmpty ? nil : $0.unit, action: $0.action)
        })
    }
}

private struct HouseholdHelperReviewView: View {
    @ObservedObject var lifecycle: HouseholdLifecycleModel
    @StateObject private var model: HouseholdHelperReviewModel
    @State private var draft: HelperReviewDraft?
    @State private var inputNotice: String?
    @State private var clearRetry = false
    @Environment(\.scenePhase) private var scenePhase
    init(lifecycle: HouseholdLifecycleModel, grantID: String, proposalID: String? = nil) {
        self.lifecycle = lifecycle
        _model = StateObject(wrappedValue: lifecycle.helperReviewModel(grantID: grantID, proposalID: proposalID))
    }
    var body: some View {
        Form {
            if lifecycle.canShare {
                Section {
                    Text(ht("Review helper instructions"))
                    Text(ht("A suggestion never changes shared instructions automatically. Review the complete replacement; shopping basket changes remain separate."))
                    Button(ht("Refresh current shared status")) { Task { await model.load() } }.disabled(model.busy)
                }
                if model.authorized, let current = model.current {
                    Section(ht("Current shared instructions")) {
                        LabeledContent(ht("Instruction revision reviewed"), value: current.revision.formatted())
                        LabeledContent(ht("Access expires"), value: householdTime(current.expiresAt))
                        projection(current.projection)
                    }
                    if let proposal = model.proposal {
                        Section(ht("Suggestion")) {
                            Text(proposal.correction).textSelection(.enabled)
                            LabeledContent(ht("Instruction revision reviewed"), value: proposal.baseRevision.formatted())
                            LabeledContent(ht("Suggestion revision"), value: proposal.proposalRevision.formatted())
                            Text(proposal.status == "pending" ? ht("Pending review") : proposal.status == "reviewed" ? ht("Suggestion reviewed") : ht("Suggestion dismissed"))
                            if proposal.baseRevision != current.revision {
                                Text(ht("This suggestion refers to an earlier instruction revision. Compare it with the current instructions before deciding."))
                            }
                        }
                    }
                    if let pending = model.pending {
                        Section(ht("Reviewed action awaiting reconciliation")) {
                            Text(pending.decision == .dismiss ? ht("Dismiss this suggestion") : ht("Replace shared instructions"))
                            LabeledContent(ht("Instruction revision reviewed"), value: pending.baseRevision.formatted())
                            if let id = pending.proposalID { LabeledContent(ht("Suggestion reference"), value: String(id.suffix(8))) }
                            if let value = pending.projection { projection(value) }
                            Text(ht("Retry keeps the same reviewed fields, revision and action identity. It does not create a second action."))
                            Button(ht("Retry and reconcile this exact action")) { Task { await model.retryAndReconcile() } }
                                .disabled(model.busy).accessibilityIdentifier("helperReview.retry")
                            Button(ht("Review status and clear local retry"), role: .destructive) { clearRetry = true }.disabled(model.busy)
                        }
                    } else if model.receipt != nil {
                        Section { Text(ht("The reviewed action was confirmed. The shopping basket was not changed.")) }
                    } else if let reviewed = model.reviewed {
                        Section(ht("Final shopper review")) {
                            Text(reviewed.decision == .dismiss ? ht("Dismiss this suggestion") : ht("Replace shared instructions"))
                            if let value = reviewed.projection { projection(value) }
                            else { Text(ht("Dismissal closes this suggestion without changing the current instructions.")) }
                            Toggle(ht("I reviewed this exact action for this recipient"), isOn: $model.approved)
                            Button(ht("Apply reviewed helper action")) { Task { await model.apply() } }
                                .disabled(!model.canApply).accessibilityIdentifier("helperReview.apply")
                            Button(ht("Continue editing")) { model.cancelReview() }.disabled(model.busy)
                        }
                    } else if model.canReview, draft != nil {
                        editor
                        Section {
                            Button(ht("Review complete replacement")) {
                                do { model.review(decision: .replace, projection: try draft?.projection()); inputNotice = nil }
                                catch { inputNotice = ht("Check the shared name, language and every instruction field before reviewing.") }
                            }.accessibilityIdentifier("helperReview.replace")
                            if model.proposalID != nil {
                                Button(ht("Review dismissal")) { model.review(decision: .dismiss, projection: nil) }
                                    .accessibilityIdentifier("helperReview.dismiss")
                            }
                            if let inputNotice { Text(inputNotice) }
                        }
                    }
                }
                if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("helperReview.notice") } }
            } else { Text(ht("Shopper access required")) }
        }
        .navigationTitle(ht("Review helper instructions"))
        .task { await model.load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                model.enforceRuntime()
                if !model.authorized && !model.busy { draft = nil }
            }
        }
        .onChange(of: model.current) { _, value in draft = value.map { HelperReviewDraft($0.projection) }; inputNotice = nil }
        .onChange(of: draft) { _, _ in model.cancelReview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.invalidate(); draft = nil }
            if phase == .active { Task { await model.load() } }
        }
        .onDisappear { model.invalidate(); draft = nil }
        .confirmationDialog(ht("Clear only this local retry record?"), isPresented: $clearRetry, titleVisibility: .visible) {
            Button(ht("Refresh status and clear retry"), role: .destructive) { Task { await model.clearRetryAfterStatusReview() } }
        } message: {
            Text(ht("The app will refresh shared status first. Clearing a retry does not undo an action already received. Use exact retry to confirm the original result."))
        }
    }
    @ViewBuilder private var editor: some View {
        Section(ht("Editable replacement instructions")) {
            TextField(ht("Name shown for this shop"), text: Binding(get: { draft?.label ?? "" }, set: { draft?.label = $0 }))
            Picker(ht("Instruction language"), selection: Binding(get: { draft?.language ?? "en" }, set: { draft?.language = $0 })) {
                Text(ht("English")).tag("en"); Text(ht("Spanish")).tag("es")
            }
            Text(ht("Only the fields reviewed here will be shared. Existing budgets, receipts and private notes are not included."))
        }
        ForEach(draft?.items ?? []) { item in
            Section(ht("Instruction")) {
                TextField(ht("Item"), text: field(item, \.label))
                TextField(ht("Amount, optional"), text: field(item, \.amount))
                TextField(ht("Unit, optional"), text: field(item, \.unit))
                TextField(ht("What the cook should do"), text: field(item, \.action), axis: .vertical)
                Button(ht("Remove instruction"), role: .destructive) { draft?.items.removeAll { $0.id == item.id } }
            }
        }
        Section {
            Button(ht("Add an instruction")) { draft?.items.append(.init()) }.disabled((draft?.items.count ?? 200) >= 200)
        }
    }
    private func field(_ item: HelperDraftItem, _ path: WritableKeyPath<HelperDraftItem, String>) -> Binding<String> {
        Binding(get: { draft?.items.first { $0.id == item.id }?[keyPath: path] ?? "" }, set: { value in
            guard var current = draft, let index = current.items.firstIndex(where: { $0.id == item.id }) else { return }
            current.items[index][keyPath: path] = value; draft = current
        })
    }
    @ViewBuilder private func projection(_ value: HelperProjection) -> some View {
        Text(value.shopLabel).font(.headline)
        Text(value.language == "es" ? ht("Spanish") : ht("English"))
        ForEach(Array(value.items.enumerated()), id: \.offset) { _, item in helperInstruction(item) }
    }
}
