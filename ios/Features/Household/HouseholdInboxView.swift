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
    @AccessibilityFocusState private var focusedRequest: String?
    var body: some View {
        List {
            if model.authorized {
                ShopperDeliverySection(model: model)
                Section {
                    Button(ht("Refresh requests")) { Task { await model.load() } }.disabled(model.busy)
                    Text(ht("Each request keeps its own outcome. Linking a line does not add another pack."))
                        .foregroundStyle(.secondary)
                }
                Section(ht("Requests for this shop")) {
                    ForEach(model.duplicateRequestGroups) { group in
                        if group.hasPossibleDuplicates { RequestDuplicateGroupHeading(group: group) }
                        ForEach(group.requests) { request in
                            Button {
                                lastRequestID = request.id; decisionRequest = request
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(request.originalItem).font(.headline)
                                    if let alias = request.authorAlias { Text(alias).font(.subheadline) }
                                    if let quantity = request.ownQuantity { Text(quantity) }
                                    Text(shopperRequestStatus(request)).foregroundStyle(.secondary)
                                    Text(householdTime(request.receivedAt)).font(.caption)
                                }
                            }.disabled(model.busy || model.pending != nil)
                                .accessibilityIdentifier("household.request.\(request.id)")
                                .accessibilityFocused($focusedRequest, equals: request.id)
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
            model.cancelReview(); focusedRequest = lastRequestID
        }) { request in
            NavigationStack { HouseholdRequestDecisionView(model: model, request: request) }
                .presentationDetents([.large])
        }
        .onChange(of: model.authorized) { _, allowed in if !allowed { decisionRequest = nil } }
    }
}
struct HouseholdRequestDecisionView: View {
    @ObservedObject var model: HouseholdInboxModel
    let request: OwnRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
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
                                    TextField(ht("Price per pack in USD, blank if unknown"), text: $model.price).keyboardType(.decimalPad)
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
                                Button(ht("Review decision")) { Task { await model.review() } }.accessibilityIdentifier("household.decision.review")
                            }
                        } else { Section { Text(ht("This request has a recorded outcome. Refresh to check for changes.")) } }
                        if let preview = model.preview {
                            Section(ht("Review before applying")) {
                                Text(model.choice.title).font(.headline)
                                if let selection = model.packSelection { HouseholdChosenPackSummary(selection: selection) }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ht("After this decision")).font(.headline)
                                    LabeledContent(ht("Expected total"), value: householdMoney(preview.after.totalMinor, currency: preview.after.currency))
                                        .accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("household.decision.after-total")
                                    if preview.after.status == "overCap" {
                                        LabeledContent(ht("Over cap"), value: householdMoney(preview.after.overCapMinor, currency: preview.after.currency))
                                            .accessibilityElement(children: .combine)
                                            .accessibilityIdentifier("household.decision.over-cap")
                                    }
                                    if preview.after.status == "unresolved" { Text(ht("Missing facts prevent a confirmed budget result.")) }
                                    if preview.after.status == "scopeMismatch" { Text(ht("The cap and total cover different scopes.")) }
                                    LabeledContent(ht("Scope"), value: householdScope(preview.after.scope))
                                    LabeledContent(ht("Before this decision"), value: householdMoney(preview.before.totalMinor, currency: preview.before.currency))
                                        .accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("household.decision.before-total")
                                    LabeledContent(ht("Cost change"), value: householdMoney(preview.changeMinor, currency: preview.after.currency))
                                    LabeledContent(ht("Cap"), value: householdMoney(shop.quote.capMinor, currency: shop.quote.currency))
                                    LabeledContent(ht("Cap scope"), value: householdScope(shop.quote.capScope))
                                    if let context = model.requestMealContext { HouseholdRequestMealContextView(context: context) }
                                }
                                .monospacedDigit()
                                DisclosureGroup(ht("Checkout calculation details")) {
                                    LabeledContent(ht("Shop revision"), value: shop.shopRevision.formatted())
                                    LabeledContent(ht("Quote recorded"), value: householdTime(shop.quote.observedAt))
                                    LabeledContent(ht("Quote expires"), value: householdTime(shop.quote.expiresAt))
                                    DisclosureGroup(ht("Included charges and discounts")) {
                                        if shop.quote.fee.kind == "fixed" {
                                            LabeledContent(ht("Retailer fee"), value: householdMoney(shop.quote.fee.amountMinor, currency: shop.quote.currency))
                                        } else {
                                            LabeledContent(ht("Fee threshold"), value: householdMoney(shop.quote.fee.thresholdMinor, currency: shop.quote.currency))
                                            LabeledContent(ht("Fee below threshold"), value: householdMoney(shop.quote.fee.belowMinor, currency: shop.quote.currency))
                                            LabeledContent(ht("Fee at or above threshold"), value: householdMoney(shop.quote.fee.aboveMinor, currency: shop.quote.currency))
                                        }
                                        LabeledContent(ht("Tax"), value: householdMoney(shop.quote.taxesMinor, currency: shop.quote.currency))
                                        LabeledContent(ht("Deposits"), value: householdMoney(shop.quote.depositsMinor, currency: shop.quote.currency))
                                        LabeledContent(ht("Discounts"), value: householdMoney(shop.quote.discountsMinor, currency: shop.quote.currency))
                                    }
                                    ShopperBudgetView(title: ht("Before this decision"), value: preview.before)
                                    ShopperBudgetView(title: ht("After this decision"), value: preview.after)
                                }
                                LabeledContent(ht("Preview expires"), value: householdTime(preview.expiresAt))
                                if preview.requiresOverageAcceptance { Toggle(ht("I accept the displayed overage"), isOn: $model.acceptOverage).accessibilityIdentifier("household.decision.overage") }
                                if preview.requiresUnknownAcceptance { Toggle(ht("I understand the total or its scope is unresolved"), isOn: $model.acceptUnknown) }
                                Button(ht("Apply reviewed decision")) { Task { await model.apply() } }
                                    .disabled(!model.canApply).accessibilityIdentifier("household.decision.apply")
                                Button(ht("Cancel preview")) { model.invalidatePreview() }
                            }
                        }
                        if selected.ownActionAllowed {
                            Section(ht("Ask for clarification")) {
                                Text(ht("Only this requester receives your question. Leave private costs and other requests out of it."))
                                    .foregroundStyle(.secondary)
                                TextField(ht("Question"), text: $model.clarification, axis: .vertical).lineLimit(2...5)
                                Button(ht("Send clarification")) { Task { await model.sendClarification() } }
                                    .disabled(model.clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("household.decision.notice") } }
                if model.busy { ProgressView(ht("Checking service…")) }
            } else { Text(ht("Shopper access has ended. Return to household settings.")) }
        }
        .scrollDismissesKeyboard(.immediately)
        .disabled(model.busy)
        .navigationTitle(ht("Review request"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { model.cancelReview(); dismiss() }.accessibilityIdentifier("household.decision.cancel") } }
        .task { model.select(request) }
    }
}
private struct ShopperDeliverySection: View {
    @ObservedObject var model: HouseholdInboxModel
    var body: some View {
        switch model.delivery {
        case .none: EmptyView()
        case .waiting, .needsReview:
            Section(ht("Pending decision")) {
                Text(ht("The result is not confirmed. Refresh current requests before creating another decision."))
                if model.delivery == .waiting { Button(ht("Retry the same decision")) { Task { await model.retry() } }.disabled(model.busy) }
                Button(ht("Refresh current requests")) { Task { await model.load() } }.disabled(model.busy)
                Button(ht("I reviewed the current requests; clear this retry")) { Task { await model.clearPendingAfterReview() } }
                    .disabled(model.busy || !model.reviewedCurrentFacts)
            }
        case .confirmed(let receipt):
            Section {
                Label(ht("Decision confirmed by the household"), systemImage: "checkmark.circle")
                Text(shopperDisposition(receipt.disposition))
                Text(ht("This records a household decision. It does not place an order with the retailer."))
            }
        }
    }
}
private struct ShopperBudgetView: View {
    let title: String
    let value: ShopperBudget
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            LabeledContent(ht("Scope"), value: householdScope(value.scope))
            LabeledContent(ht("Expected total"), value: householdMoney(value.totalMinor, currency: value.currency))
            if value.status == "overCap" { LabeledContent(ht("Over cap"), value: householdMoney(value.overCapMinor, currency: value.currency)) }
            if value.status == "withinCap" { LabeledContent(ht("Remaining within this cap"), value: householdMoney(value.headroomMinor, currency: value.currency)) }
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
