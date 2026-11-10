import SwiftUI
import HouseholdClient

struct HouseholdInboxView: View {
    @ObservedObject var model: HouseholdModel
    var body: some View {
        Group {
            if model.canReviewHouseholdRequests, let inbox = model.shopperInbox {
                ShopperInboxContent(model: inbox)
            } else { ContentUnavailableView(ht("Shopper access required"), systemImage: "lock", description: Text(ht("Only the assigned shopper can review these requests."))) }
        }.navigationTitle(ht("Family requests"))
    }
}
struct ShopperInboxContent: View {
    @ObservedObject var model: HouseholdInboxModel
    @State private var decisionRequest: OwnRequest?
    @State private var lastRequestID: String?
    @State private var confirmedReturnID: String?
    @AccessibilityFocusState private var focusedRequest: String?
    @AccessibilityFocusState private var focusedOutcome: String?
    var body: some View {
        ScrollViewReader { scroll in
            List {
                if model.authorized {
                    ShopperDeliverySection(model: model)
                    if model.trackingAllowed, model.pending == nil {
                        NavigationLink(ru("Accepted request changes")) { SharedRequestUndoInboxView(owner: model) }
                            .accessibilityIdentifier("household.requests.acceptedChanges")
                    }
                    if model.canReviewDeferred, model.pending == nil {
                        NavigationLink(ht("Saved from earlier pickups")) { DeferredRequestsView(model: model) }
                            .accessibilityIdentifier("household.deferred.open")
                    }
                    Section {
                        Button(ht("Refresh requests")) { Task { await model.load() } }.disabled(model.busy)
                        Text(ht("Each request keeps its own outcome. Linking a line does not add another pack."))
                            .foregroundStyle(.secondary)
                    }
                    Section(ht("Requests for this shop")) {
                        ForEach(model.duplicateRequestGroups) { group in
                            if group.hasPossibleDuplicates { RequestDuplicateGroupHeading(group: group) }
                            ForEach(group.requests) { request in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button {
                                        confirmedReturnID = nil; focusedOutcome = nil
                                        lastRequestID = request.id; decisionRequest = request
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(request.originalItem).font(.headline)
                                            if let alias = request.authorAlias { Text(alias).font(.subheadline) }
                                            if let quantity = request.ownQuantity { Text(quantity) }
                                            if request.fromPreviousShop == true { Text(ht("From an earlier pickup")) }
                                            Text(householdTime(request.receivedAt)).font(.caption)
                                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }.disabled(model.busy || model.pending != nil)
                                        .accessibilityIdentifier("household.request.\(request.id)")
                                        .accessibilityFocused($focusedRequest, equals: request.id)
                                    Text(shopperRequestStatus(request)).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("household.request.outcome.\(request.id)")
                                        .accessibilityFocused($focusedOutcome, equals: request.id)
                                }.accessibilityElement(children: .contain)
                                    .id(request.id)
                            }
                        }
                        if model.requests.isEmpty, !model.busy { Text(ht("No requests are available in this shop.")) }
                        if model.nextCursor != nil { Button(ht("Load more requests")) { Task { await model.load(more: true) } }.disabled(model.busy) }
                    }
                    if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("household.inbox.notice") } }
                    if model.busy { ProgressView(ht("Checking service…")) }
                } else { Text(ht("Shopper access has ended. Return to household settings.")) }
            }.task { await model.load() }
            .sheet(item: $decisionRequest, onDismiss: {
                model.cancelReview()
                if let id = confirmedReturnID, model.confirmedDecisionRequestID == id {
                    scroll.scrollTo(id, anchor: .center)
                    focusedRequest = nil; focusedOutcome = id
                } else { focusedRequest = lastRequestID }
            }) { request in
                NavigationStack { HouseholdRequestDecisionView(model: model, request: request) }
                    .presentationDetents([.large])
            }
            .onChange(of: model.confirmedDecisionRequestID) { _, id in
                guard let id, decisionRequest?.id == id else { return }
                confirmedReturnID = id
                decisionRequest = nil
            }
            .onChange(of: model.authorized) { _, allowed in if !allowed { decisionRequest = nil } }
        }
    }
}
private struct DeferredRequestsView: View {
    @ObservedObject var model: HouseholdInboxModel
    @State private var reviewed: DeferredRequest?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.canReviewDeferred, model.pending == nil {
                if let row = reviewed, model.deferredRequests.contains(row) {
                    Section {
                        Text(row.originalItem).font(.headline)
                        Text(row.authorAlias)
                        if let amount = row.ownQuantity { Text(amount) }
                        Text(householdTime(row.receivedAt))
                        Text(ht("Bring this request to the current inbox. Review the price and quantity there before changing the basket."))
                        Button(ht("Bring to this inbox")) {
                            Task {
                                await model.carryForReview(row)
                                reviewed = nil
                            }
                        }.disabled(model.busy)
                            .accessibilityIdentifier("household.deferred.confirm")
                        Button(ht("Keep for later")) { reviewed = nil }
                            .accessibilityIdentifier("household.deferred.keep")
                    }
                } else {
                    ForEach(model.deferredRequests) { row in
                        Button { reviewed = row } label: {
                            VStack(alignment: .leading) {
                                Text(row.originalItem).font(.headline)
                                Text(row.authorAlias)
                                if let amount = row.ownQuantity { Text(amount) }
                                Text(householdTime(row.receivedAt)).font(.caption)
                            }
                        }.accessibilityIdentifier("household.deferred.\(row.id.uuidString.lowercased())")
                    }
                    if model.deferredPage != nil && model.deferredRequests.isEmpty {
                        Text(ht("No earlier requests are waiting for this pickup."))
                    }
                    if model.deferredPage?.nextCursor != nil {
                        Button(ht("Load more requests")) { Task { await model.loadDeferred(more: true) } }
                    }
                    Button(ht("Refresh requests")) { Task { await model.load(); await model.loadDeferred() } }
                }
            } else if model.pending != nil { ShopperDeliverySection(model: model) }
            if let notice = model.notice { Text(notice) }
            if model.busy { ProgressView(ht("Checking service…")) }
        }
        .navigationTitle(ht("Saved from earlier pickups"))
        .task { await model.loadDeferred() }
        .onChange(of: model.delivery) { _, delivery in
            if case .confirmed(let receipt) = delivery, receipt.kind == "request.carry" { dismiss() }
        }
        .onDisappear { model.forgetDeferred() }
    }
}
struct HouseholdRequestDecisionView: View {
    @ObservedObject var model: HouseholdInboxModel
    let request: OwnRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        WorkingForm {
            if model.authorized {
                ShopperDeliverySection(model: model)
                if let selected = model.selected, selected.id == request.id {
                    Section(ht("Request")) {
                        Text(selected.originalItem).font(.headline)
                        if let alias = selected.authorAlias { LabeledContent(ht("Requested by"), value: alias) }
                        if let quantity = selected.ownQuantity { Text(quantity) }
                        Text(shopperRequestStatus(selected))
                        LabeledContent(ht("Received"), value: householdTime(selected.receivedAt))
                        if let clarification = selected.clarification { Text(clarification) }
                    }
                    RequestDuplicateComparisonSection(model: model, requestID: request.id)
                    if model.pending == nil, let shop = model.shop {
                        if !model.availableChoices.isEmpty {
                            Section(ht("Choose an outcome")) {
                                Picker(ht("Outcome"), selection: $model.choice) {
                                    ForEach(model.availableChoices) { choice in Text(choice.title).tag(choice) }
                                }.accessibilityIdentifier("household.decision.choice")
                                if model.choice == .add {
                                    HouseholdRequestPackReviewView(model: model)
                                    if let selection = model.packSelection { HouseholdChosenPackSummary(selection: selection) }
                                    TextField(ht("Pack or item name"), text: $model.lineItem).accessibilityIdentifier("household.decision.item")
                                    Stepper(value: $model.packs, in: 1...10_000) {
                                        LabeledContent(ht("Whole packs"), value: model.packs.formatted())
                                    }
                                    workingTextField(ht("Price per pack in USD, blank if unknown"), text: $model.price).keyboardType(.decimalPad)
                                        .accessibilityIdentifier("household.decision.price")
                                    Toggle(ht("Counts toward the retailer fee threshold"), isOn: $model.feeEligible)
                                }
                                if model.choice == .link {
                                    Picker(ht("Existing line"), selection: $model.linkedLineID) {
                                        Text(ht("Choose a line")).tag("")
                                        ForEach(shop.lines) { line in Text(line.originalItem).tag(line.id) }
                                    }
                                    if let line = shop.lines.first(where: { $0.id == model.linkedLineID }) {
                                        LabeledContent(ht("Whole packs"), value: line.packs.formatted())
                                        LabeledContent(ht("Price per pack"), value: householdMoney(line.unitPriceMinor, currency: shop.quote.currency))
                                    }
                                }
                                if (model.choice == .add || model.choice == .link), selected.route == "next" {
                                    Toggle(ht("Bring this next-shop request into this shop"), isOn: $model.promote)
                                }
                                if model.preview == nil {
                                    reviewButton.buttonStyle(PrimaryAction())
                                } else {
                                    reviewButton
                                }
                            }
                        } else { Section { Text(ht("This request has a recorded outcome. Refresh to check for changes.")) } }
                        if let preview = model.preview {
                            Section(header: Text(ht("Review before applying")).foregroundStyle(Theme.secondary)) {
                                Text(model.choice.title).font(.title2)
                                if let selection = model.packSelection { HouseholdChosenPackSummary(selection: selection) }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ht("After this decision")).font(.title2)
                                    HouseholdDecisionTotal(value: householdMoney(preview.after.totalMinor, currency: preview.after.currency))
                                        .accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("household.decision.after-total")
                                    if preview.after.status == "overCap" {
                                        HouseholdDecisionFact(ht("Over cap"), value: householdMoney(preview.after.overCapMinor, currency: preview.after.currency))
                                            .accessibilityElement(children: .combine)
                                            .accessibilityIdentifier("household.decision.over-cap")
                                    }
                                    if preview.after.status == "unresolved", preview.after.missing.isEmpty {
                                        Text(ht("Missing facts prevent a confirmed budget result."))
                                    }
                                    if preview.after.status == "scopeMismatch", !preview.after.missing.contains("scope_mismatch") {
                                        Text(ht("The cap and total cover different scopes."))
                                    }
                                    ForEach(preview.after.missing, id: \.self) { code in
                                        Text(missingBudgetFact(code))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    HouseholdDecisionFact(ht("Scope"), value: householdScope(preview.after.scope))
                                    Text(householdDecisionFeeBasis(shop.quote))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("household.decision.feeBasis")
                                    HouseholdDecisionFact(ht("Before this decision"), value: householdMoney(preview.before.totalMinor, currency: preview.before.currency))
                                        .accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("household.decision.before-total")
                                    HouseholdDecisionFact(ht("Cost change"), value: householdMoney(preview.changeMinor, currency: preview.after.currency))
                                    HouseholdDecisionFact(ht("Cap"), value: householdMoney(shop.quote.capMinor, currency: shop.quote.currency))
                                    HouseholdDecisionFact(ht("Cap scope"), value: householdScope(shop.quote.capScope))
                                    if let context = model.requestMealContext { HouseholdRequestMealContextView(context: context) }
                                }
                                .monospacedDigit()
                                DisclosureGroup(ht("Checkout calculation details")) {
                                    HouseholdDecisionFact(ht("Shop revision"), value: shop.shopRevision.formatted(), valueRole: .metadata)
                                    HouseholdDecisionFact(ht("Quote recorded"), value: householdTime(shop.quote.observedAt), valueRole: .metadata)
                                    HouseholdDecisionFact(ht("Quote expires"), value: householdTime(shop.quote.expiresAt), valueRole: .metadata)
                                    DisclosureGroup(ht("Included charges and discounts")) {
                                        if shop.quote.fee.kind == "fixed" {
                                            HouseholdDecisionFact(ht("Retailer fee"), value: householdMoney(shop.quote.fee.amountMinor, currency: shop.quote.currency))
                                        } else {
                                            HouseholdDecisionFact(ht("Fee threshold"), value: householdMoney(shop.quote.fee.thresholdMinor, currency: shop.quote.currency))
                                            HouseholdDecisionFact(ht("Fee below threshold"), value: householdMoney(shop.quote.fee.belowMinor, currency: shop.quote.currency))
                                            HouseholdDecisionFact(ht("Fee at or above threshold"), value: householdMoney(shop.quote.fee.aboveMinor, currency: shop.quote.currency))
                                        }
                                        HouseholdDecisionFact(ht("Tax"), value: householdMoney(shop.quote.taxesMinor, currency: shop.quote.currency))
                                        HouseholdDecisionFact(ht("Deposits"), value: householdMoney(shop.quote.depositsMinor, currency: shop.quote.currency))
                                        HouseholdDecisionFact(ht("Discounts"), value: householdMoney(shop.quote.discountsMinor, currency: shop.quote.currency))
                                    }
                                    .disclosureGroupStyle(LabeledFormDisclosureStyle(label: ht("Included charges and discounts"),
                                                                                     identifier: "household.decision.includedCharges"))
                                    ShopperBudgetView(title: ht("Before this decision"), value: preview.before)
                                    ShopperBudgetView(title: ht("After this decision"), value: preview.after)
                                }
                                .disclosureGroupStyle(LabeledFormDisclosureStyle(label: ht("Checkout calculation details"),
                                                                                 identifier: "household.decision.checkoutDetails"))
                                HouseholdDecisionFact(ht("Preview expires"), value: householdTime(preview.expiresAt), valueRole: .metadata)
                                if preview.requiresOverageAcceptance { Toggle(ht("I accept the displayed overage"), isOn: $model.acceptOverage).accessibilityIdentifier("household.decision.overage") }
                                if preview.requiresUnknownAcceptance { Toggle(ht("I understand the total or its scope is unresolved"), isOn: $model.acceptUnknown) }
                                Button(ht("Apply reviewed decision")) { Task { await model.apply() } }
                                    .buttonStyle(PrimaryAction())
                                    .disabled(!model.canApply).accessibilityIdentifier("household.decision.apply")
                                Button(ht("Cancel preview")) { model.invalidatePreview() }
                            }
                        }
                        if selected.ownActionAllowed {
                            Section(ht("Ask for clarification")) {
                                Text(ht("Only this requester receives your question. Leave private costs and other requests out of it."))
                                    .foregroundStyle(Theme.secondary)
                                workingTextField(ht("Question"), text: $model.clarification, axis: .vertical).lineLimit(2...5)
                                    .accessibilityIdentifier("household.decision.question")
                                Button(ht("Send clarification")) { Task { await model.sendClarification() } }
                                    .disabled(model.clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                if case .confirmed(let receipt) = model.delivery, receipt.kind == "request.apply",
                   receipt.requestId == request.id, model.confirmedDecisionRequestID == nil {
                    Button(ht("Refresh requests")) { Task { await model.load() } }
                        .accessibilityIdentifier("household.decision.refreshOutcome")
                }
                if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("household.decision.notice") } }
                if model.busy { ProgressView(ht("Checking service…")) }
            } else { Text(ht("Shopper access has ended. Return to household settings.")) }
        }
        .scrollDismissesKeyboard(.immediately)
        .disabled(model.busy)
        .sheet(item: Binding(get: { model.requestFood }, set: { if $0 == nil { model.cancelRequestFood() } })) { context in
            NavigationStack { SharedRequestFoodView(inbox: model, context: context) }
        }
        .sheet(item: Binding(get: { model.trackingRequest }, set: { if $0 == nil { model.cancelRequestFood() } })) { context in
            NavigationStack { SharedTrackingRequestView(owner: model, context: context) }
        }
        .navigationTitle(ht("Review request"))
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { model.cancelReview(); dismiss() }.accessibilityIdentifier("household.decision.cancel") } }
        .task { model.select(request) }
    }

    private var reviewButton: some View {
        Button(ht("Review decision")) { Task { await model.review() } }
            .accessibilityIdentifier("household.decision.review")
    }
}

/// Show the quoted rule, never infer a threshold fee from incomplete basket facts.
private func householdDecisionFeeBasis(_ quote: ShopperQuote) -> String {
    switch quote.fee.kind {
    case "fixed":
        guard let amount = quote.fee.amountMinor else { return ht("The retailer fee is unknown.") }
        return String(format: ht("Fixed retailer fee: %@."), householdMoney(amount, currency: quote.currency))
    case "threshold":
        return String(format: ht("Retailer fee: %@ below %@ in eligible items; %@ at or above."),
                      householdMoney(quote.fee.belowMinor, currency: quote.currency),
                      householdMoney(quote.fee.thresholdMinor, currency: quote.currency),
                      householdMoney(quote.fee.aboveMinor, currency: quote.currency))
    default:
        return ht("The retailer fee is unknown.")
    }
}

struct ShopperDeliverySection: View {
    @ObservedObject var model: HouseholdInboxModel
    @State private var reachedRetryDeadline: Date?
    var body: some View {
        switch model.delivery {
        case .none: EmptyView()
        case .waiting, .needsReview:
            Section(ht("Pending decision")) {
                Text(ht("The result is not confirmed. Refresh current requests before creating another decision."))
                if model.delivery == .waiting {
                    Button(ht("Retry the same decision")) { Task { await model.retry() } }
                        .disabled(model.busy || (reachedRetryDeadline != model.retryAfter && Date.now < model.retryAfter))
                        .task(id: model.retryAfter) {
                            let deadline = model.retryAfter
                            do {
                                while deadline > .now {
                                    try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                                }
                                try Task.checkCancellation()
                                reachedRetryDeadline = deadline
                            } catch is CancellationError {
                                // A new deadline or a dismissed action cancels this wait.
                            } catch { return }
                        }
                }
                Button(ht("Refresh current requests")) { Task { await model.load() } }.disabled(model.busy)
                if model.pending?.sharedTrackingBinding != nil || model.pending?.sharedRequestUndoBinding != nil {
                    Text(st("The saved action is unresolved. Refresh current access, then retry the same saved action. A refresh does not undo or discard it."))
                } else if model.pending == nil {
                    Text(st("This review can no longer be applied. Refresh current facts and review a new action explicitly."))
                } else {
                    Button(ht("I reviewed the current requests; clear this retry")) { Task { await model.clearPendingAfterReview() } }
                        .disabled(model.busy || !model.reviewedCurrentFacts)
                }
            }
        case .confirmed(let receipt):
            Section {
                Label(ht("Decision confirmed by the household"), systemImage: "checkmark.circle")
                if receipt.kind == "request.carry" {
                    Text(ht("Ready for review in this pickup"))
                } else if receipt.kind != "request.confirmPurchase" {
                    Text(shopperDisposition(receipt.disposition))
                }
                Text(ht("This records a household decision. It does not place an order with the retailer."))
            }
        }
    }
}
struct ShopperBudgetView: View {
    let title: String
    let value: ShopperBudget
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HouseholdDecisionFact(ht("Scope"), value: householdScope(value.scope))
            HouseholdDecisionFact(ht("Expected total"), value: householdMoney(value.totalMinor, currency: value.currency))
            if value.status == "overCap" { HouseholdDecisionFact(ht("Over cap"), value: householdMoney(value.overCapMinor, currency: value.currency)) }
            if value.status == "withinCap" { HouseholdDecisionFact(ht("Remaining within this cap"), value: householdMoney(value.headroomMinor, currency: value.currency)) }
            if value.status == "scopeMismatch" { Text(ht("The cap and total cover different scopes.")) }
            if value.status == "unresolved" { Text(ht("Missing facts prevent a confirmed budget result.")) }
            ForEach(value.missing, id: \.self) { code in Text(missingBudgetFact(code)).font(.caption) }
        }.accessibilityElement(children: .combine)
    }
}
func householdMoney(_ amount: Int?, currency: String) -> String {
    guard let amount else { return ht("Unknown") }
    return (Decimal(amount) / 100).formatted(.currency(code: currency))
}
func householdTime(_ value: String) -> String {
    serviceDate(value)?.formatted(date: .abbreviated, time: .shortened) ?? ht("Time unavailable")
}
func householdScope(_ value: String) -> String {
    switch value { case "wholeCheckout": return ht("Whole checkout"); case "item": return ht("This item only")
    case "dinner": return ht("Dinner only"); default: return ht("Unknown scope") }
}
func shopperRequestStatus(_ request: OwnRequest) -> String {
    if request.carriedForward == true { return ht("Moved to a later pickup for review") }
    if request.status == "pending" { return request.route == "next" ? ht("Received for next shop") : ht("Received, waiting for review") }
    return shopperDisposition(request.status)
}
func shopperDisposition(_ value: String) -> String {
    switch value { case "clarified": return ht("Clarification requested"); case "added": return ht("Added to the plan")
    case "deferred": return ht("Saved for next shop"); case "handled": return ht("Handled"); case "dismissed": return ht("Not included")
    case "withdrawn": return ht("Withdrawn"); default: return ht("Check current status") }
}
private func missingBudgetFact(_ value: String) -> String {
    switch value { case "remaining_original_items": return ht("Some original items are missing from this quote.")
    case "line_price": return ht("At least one line price is unknown."); case "fee": return ht("The retailer fee is unknown.")
    case "tax": return ht("Tax is unknown."); case "deposit": return ht("Deposits are unknown.")
    case "discount": return ht("Discounts are unknown."); case "cap": return ht("No cap is recorded.")
    case "scope_mismatch": return ht("The cap and total cover different scopes."); default: return ht("A budget fact is unknown.") }
}
