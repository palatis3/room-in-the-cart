import SwiftUI
import UIKit
import CoreDomain

struct PickupHomeView: View {
    @ObservedObject var model: PickupModel
    @Environment(\.pickupLedger) private var ledger
    @State private var nextShopRequested = false
    @AccessibilityFocusState private var nextShopFocused: Bool
    var body: some View {
        List {
            PickupSaveStatus(model: model)
            PickupStockBasisNotice(model: model)
            if let value = model.journey {
                Section(pTr("This pickup")) {
                    Text(value.savedAt, format: .dateTime.month().day().year().hour().minute())
                    if value.originShopID != nil, value.context == nil, let ledger {
                        NavigationLink(pTr("Open next shopping list")) { PickupListBridgeView(model: model, ledger: ledger, journeyID: value.id) }
                    }
                    if let basket = value.basket {
                        Text(pTr(basket.phase == .reportedPlaced ? "Placement reported · original order locked" : basket.phase == .frozen ? "Frozen · placement unconfirmed" : "Draft · no order placed"))
                        if value.isAtHomeOnlyPlan {
                            NavigationLink(ledgerText("Use-at-home plan")) { LedgerAtHomePlanView(model: model) }
                        } else if basket.phase != .reportedPlaced {
                            NavigationLink(pTr("Review whole checkout")) { PickupCheckoutView(model: model) }
                            NavigationLink(pTr("Prepare retailer handoff")) { PickupHandoffView(model: model, shopID: value.id) }
                        } else {
                            NavigationLink(pTr("View placed order")) { PickupHandoffView(model: model, shopID: value.id) }
                        }
                    }
                    if value.pickup != nil {
                        NavigationLink(pTr("Review a store offer")) { PickupOfferView(model: model) }
                        NavigationLink(pTr("Record what came home")) { PickupArrivalView(model: model) }
                        NavigationLink(pTr("Close the pickup")) { PickupSettlementView(model: model) }
                    }
                    NavigationLink(pTr("Repair a meal")) { PickupRepairView(model: model) }
                    NavigationLink(pTr("Tell the cook")) { PickupCookView(model: model) }
                    Button(pTr("Start the next shop")) { nextShopRequested = true }.accessibilityFocused($nextShopFocused)
                }
            } else {
                Text(pTr("Review your shopping list to begin checkout. You can also repair a meal without an order."))
            }
            Section {
                NavigationLink(pTr("Confirm pantry or freezer food")) {
                    PickupStockEntryView(model: model, title: pTr("Confirm pantry or freezer food"))
                }
                NavigationLink(pTr("Something is missing")) { UrgentRepairView(model: model) }
            }
            if model.journeys.count > 1 {
                Section(pTr("Saved pickups and meal needs")) {
                    ForEach(model.journeys) { value in
                        Button { model.selectedID = value.id } label: {
                            VStack(alignment: .leading) {
                                Text(value.basket?.current.lines.first?.name ?? value.urgent.first?.meal ?? value.stockLots.first?.name ?? pTr("Pickup"))
                                Text(value.savedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(pTr("Pickup"))
        .modifier(PickupNextShopRoute(model: model, requested: $nextShopRequested) { nextShopFocused = true })
        .task { await model.load() }
        .disabled(model.saving)
    }
}

struct PickupStockBasisNotice: View {
    @ObservedObject var model: PickupModel
    @Environment(\.pickupLedger) private var ledger
    var body: some View {
        if !model.hasCurrentBasketStockBasis {
            Section {
                Text(ledgerText("Confirmed stock changed. Review ingredient needs and whole packs before continuing checkout."))
                    .foregroundStyle(Theme.warning).accessibilityIdentifier("pickupStockBasisStale")
                if let ledger {
                    NavigationLink(ledgerText("Review ingredient and purchase needs")) { LedgerHomeView(model: ledger) }
                }
            }
        }
    }
}

struct PickupSaveStatus: View {
    @ObservedObject var model: PickupModel
    var onRetried: (() -> Void)? = nil
    var body: some View {
        if let error = model.error {
            Section {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("pickup-save-error")
                if model.hasPendingSave {
                    Button(pTr("Retry save")) { Task { if await model.retrySave() { onRetried?() } } }
                    Button(pTr("Discard unsaved change"), role: .destructive) { model.discardPending() }
                } else if !model.ready { Button(pTr("Retry opening")) { Task { await model.load() } } }
            }
        }
        if model.saving { ProgressView(pTr("Saving on this device")) }
    }
}

struct PickupEvidenceField: View {
    let title: String
    @Binding var amount: String
    var body: some View {
        TextField(pTr(title), text: $amount).keyboardType(.decimalPad)
            .accessibilityHint(pTr("US dollars. Leave blank when unknown; enter zero only if confirmed."))
    }
}
@MainActor func pickupEvidence(_ text: String) throws -> CostEvidence {
    if let money = try ComparisonModel.money(text) { return .exact(money) }
    return .unknown(reason: pTr("Not confirmed"))
}
func pickupResultText(_ result: CheckoutResult) -> String {
    if let exact = result.total.exact { return pMoney(exact) }
    if let upper = result.total.upperBound { return "\(pMoney(result.total.lowerBound)) – \(pMoney(upper))" }
    return "\(pTr("At least")) \(pMoney(result.total.lowerBound)) · \(pTr("total unresolved"))"
}
private func pickupComponentName(_ component: String) -> String {
    if component.hasPrefix("line:") { return pTr("Item price") }
    if component.hasPrefix("fee:") { return pTr("Retailer fee") }
    if component.hasPrefix("discount:") { return pTr("Discount") }
    switch component {
    case "inclusiveTotal": return pTr("Inclusive total")
    case "lineSet": return pTr("Remaining original items")
    case "tax": return pTr("Tax")
    case "deposits": return pTr("Deposits and other charges")
    default: return pTr("Unresolved")
    }
}
struct PickupResultView: View {
    let result: CheckoutResult
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pickupResultText(result)).font(.title2.bold())
            switch result.cap {
            case .notProvided: Text(pTr("No spending cap supplied"))
            case .scopeMismatch: Text(pTr("Cap and checkout cover different commitments"))
            case .unresolved: Text(pTr("Whether this fits the cap is unresolved"))
            case let .within(_, headroom): Text("\(pTr("Within this scope’s cap · room remaining")) \(pMoney(headroom))")
            case let .over(_, overage): Text("\(pTr("Over this scope’s cap by")) \(pMoney(overage))")
            }
            ForEach(Array(result.uncertainties.enumerated()), id: \.offset) { _, issue in
                Text("\(pickupComponentName(issue.component)): \(pTr(issue.reason))").font(.caption)
            }
        }
    }
}

struct PickupCheckoutView: View {
    @ObservedObject var model: PickupModel
    private enum Field: Hashable {
        case store, branch, slot, source, cap, total, line(UUID), fee, threshold, discount, tax, deposits, hold, funds
    }
    @FocusState private var field: Field?
    @State private var draft = PickupCheckoutDraft()
    private struct QuoteReview: Identifiable {
        let id = UUID()
        let draft: PickupCheckoutDraft
        let quote: CheckoutQuote
        let cap: CheckoutCap?
    }
    @State private var quoteReview: QuoteReview?
    @State private var reviewingReplacement = false
    @State private var reopeningCurrent = false
    @State private var selected: Set<UUID> = []
    @State private var preview: (BasketProposal, CheckoutComparison)?
    @State private var formError: String?
    @State private var comparingHold = false
    @State private var hold = ""
    @State private var availableFunds = ""
    private var hasLocalReview: Bool {
        !selected.isEmpty || preview != nil || comparingHold || !hold.isEmpty || !availableFunds.isEmpty
    }
    private var draftIsStale: Bool {
        guard draft.journeyID != nil else { return false }
        return model.journey.map { !draft.matchesSource($0, workspaceID: model.sourceWorkspaceID) } ?? true
    }
    var body: some View {
        Form {
            if !draftIsStale { PickupSaveStatus(model: model) }
            if draftIsStale {
                Section {
                    Text(pTr("Your unsaved checkout edits are kept, but this pickup or its saved evidence changed. Reopen current details before saving."))
                        .foregroundStyle(Theme.warning)
                    Button(pTr("Reopen current checkout")) { reopeningCurrent = true }
                        .disabled(model.journey == nil)
                }
            } else {
                CheckoutQuotesContextLink(pickup: model)
                PickupStockBasisNotice(model: model)
            }
            Section(pTr("Retailer preview · source and time")) {
                TextField(pTr("Store"), text: $draft.store).focused($field, equals: .store)
                TextField(pTr("Branch"), text: $draft.branch).focused($field, equals: .branch)
                TextField(pTr("Pickup or delivery slot"), text: $draft.slot).focused($field, equals: .slot)
                if !draft.termsNeedFreshPricing {
                    TextField(pTr("Source of these prices"), text: $draft.source).focused($field, equals: .source)
                    DatePicker(pTr("Observed"), selection: $draft.observed)
                }
                Picker(pTr("Shopping mode"), selection: $draft.mode) {
                    Text(pTr("Pickup")).tag(ShoppingMode.pickup)
                    Text(pTr("Delivery")).tag(ShoppingMode.delivery)
                    Text(pTr("In store")).tag(ShoppingMode.inStore)
                }
                Picker(pTr("Scope"), selection: $draft.scope) {
                    Text(pTr("Whole checkout")).tag(CheckoutScope.wholeCheckout)
                    Text(pTr("Dinners only")).tag(CheckoutScope.dinner)
                    Text(pTr("Selected items only")).tag(CheckoutScope.item)
                }
                PickupEvidenceField(title: "Spending cap", amount: $draft.cap).focused($field, equals: .cap)
                Picker(pTr("Spending cap scope"), selection: $draft.capScope) {
                    Text(pTr("Whole checkout")).tag(CheckoutScope.wholeCheckout)
                    Text(pTr("Dinners only")).tag(CheckoutScope.dinner)
                    Text(pTr("Selected items only")).tag(CheckoutScope.item)
                }
            }.disabled(draftIsStale)
            Section(pTr("Expected charges · USD")) {
                if draft.pricingNeedsReplacement || draft.replacingPricing, let pricing = draft.originalPricing {
                    Text(pTr("Pricing details to preserve")).font(.headline)
                    if let original = draft.reviewedQuote {
                        PickupQuoteTermsView(quote: original, cap: draft.originalCap)
                    }
                    PickupSavedCheckoutPricingView(pricing: pricing)
                }
                if draft.pricingNeedsReplacement {
                    if draft.termsNeedFreshPricing {
                        Text(pTr("These prices belong to different checkout terms. Review them and enter fresh evidence."))
                    } else {
                        Text(pTr("These pricing details stay intact when you save. Review them before starting replacement pricing."))
                    }
                    Button(pTr("Replace pricing after review")) { reviewingReplacement = true }
                } else {
                    Toggle(pTr("Retailer total already includes all charges"), isOn: $draft.inclusive)
                    Text(pTr("Blank means unknown. Enter 0 only for a confirmed zero charge."))
                    if draft.inclusive { PickupEvidenceField(title: "Inclusive total", amount: $draft.total).focused($field, equals: .total) }
                    else {
                        ForEach(draft.displayLines) { line in
                            PickupEvidenceField(title: line.name, amount: Binding(get: { draft.prices[line.id] ?? "" }, set: { draft.prices[line.id] = $0 }))
                                .focused($field, equals: .line(line.id))
                        }
                        Toggle(pTr("All original items are represented"), isOn: $draft.complete)
                        PickupEvidenceField(title: "Fee below threshold or fixed fee", amount: $draft.fee).focused($field, equals: .fee)
                        PickupEvidenceField(title: "Fee waived at subtotal (optional)", amount: $draft.threshold).focused($field, equals: .threshold)
                        PickupEvidenceField(title: "Eligible discount", amount: $draft.discount).focused($field, equals: .discount)
                        PickupEvidenceField(title: "Tax", amount: $draft.tax).focused($field, equals: .tax)
                        PickupEvidenceField(title: "Deposits and other charges", amount: $draft.deposits).focused($field, equals: .deposits)
                    }
                }
                Button(pTr("Save and evaluate checkout")) { saveQuote() }.buttonStyle(.borderedProminent)
                    .disabled(draftIsStale || draft.termsNeedFreshPricing || !model.hasCurrentBasketStockBasis)
                if let formError { Text(formError).foregroundStyle(.red) }
                if !draftIsStale, !draft.hasUnsavedChanges, let result = model.result, let id = model.journey?.id {
                    NavigationLink(pTr("Check price by weight")) { PickupWeightReview(model: model, shopID: id) }
                        .accessibilityIdentifier("checkout.weightReview")
                    Text(pTr("Saved checkout result")).font(.headline)
                    PickupResultView(result: result)
                }
            }.disabled(draftIsStale)
            if !draftIsStale {
                if let history = model.journey?.earlierQuotes, !history.isEmpty {
                    DisclosureGroup(pTr("Earlier checkout quotes")) {
                        ForEach(history.reversed()) { record in
                            PickupQuoteTermsView(quote: record.quote, cap: record.cap)
                            PickupSavedCheckoutPricingView(pricing: record.quote.pricing)
                            if let result = try? CheckoutEngine.evaluate(record.quote, cap: record.cap) {
                                PickupResultView(result: result)
                            }
                            Divider()
                        }
                    }
                    .disclosureGroupStyle(LabeledFormDisclosureStyle(label: pTr("Earlier checkout quotes"),
                                                                     identifier: "checkout.earlierQuotes"))
                }
                Section(pTr("Payment hold · separate from spending")) {
                    Toggle(pTr("Compare an authorization hold"), isOn: $comparingHold)
                    if comparingHold {
                        PickupEvidenceField(title: "Retailer-displayed hold", amount: $hold).focused($field, equals: .hold)
                        PickupEvidenceField(title: "Available funds (private, this screen only)", amount: $availableFunds).focused($field, equals: .funds)
                        if let held = try? ComparisonModel.money(hold), let funds = try? ComparisonModel.money(availableFunds), let gap = try? held.subtracting(funds) {
                            Text("\(pTr("Hold less available funds")): \(pMoney(gap))")
                        } else { Text(pTr("Hold comparison unresolved")) }
                    }
                }
            }
            if !draftIsStale, !draft.hasUnsavedChanges, !draft.inclusive, !draft.pricingNeedsReplacement, model.result != nil {
                Section(pTr("Protect or defer · preview before applying")) {
                    Text(pTr("Only lines you explicitly mark flexible can be deferred. Protected meal needs stay recorded."))
                    ForEach(model.journey?.basket?.current.lines ?? []) { line in
                        Toggle(line.name, isOn: Binding(get: { model.journey?.flexible.contains(line.id) == true }, set: { enabled in
                            Task { await model.change { value in if enabled { value.flexible.insert(line.id) } else { value.flexible.remove(line.id) } } }
                        }))
                        .disabled(model.journey?.plannedNeeds.contains(where: { $0.orderLineID == line.id && $0.priority == .protected }) == true)
                        ForEach(model.journey?.plannedNeeds.filter { $0.orderLineID == line.id } ?? []) { need in
                            Text("\(need.name): \(pQuantity(need.amount)) · \(pTr(need.priority == .protected ? "Protected" : "Required"))").font(.caption)
                        }
                        if model.journey?.flexible.contains(line.id) == true {
                            Toggle(pTr("Include in deferral preview"), isOn: Binding(get: { selected.contains(line.id) }, set: { if $0 { selected.insert(line.id) } else { selected.remove(line.id) } }))
                        }
                    }
                    Button(pTr("Preview deferrals together")) {
                        do { preview = try model.deferralPreview(selected); formError = nil }
                        catch { formError = pTr("Select flexible lines and save a complete component quote first.") }
                    }
                    if let preview {
                        Text(pTr("Current checkout")); PickupResultView(result: preview.1.before)
                        Text(pTr("After all selected deferrals")); PickupResultView(result: preview.1.after)
                        Button(pTr("Apply reviewed deferral")) { Task { if await model.applyDeferral(preview.0) { self.preview = nil; selected = []; populate() } } }
                        Button(pTr("Cancel preview")) { self.preview = nil }
                    }
                    ForEach(model.journey?.proposals.filter { !(model.journey?.undoneProposals.contains($0.id) ?? false) } ?? []) { proposal in
                        Button(pTr("Undo deferral and review prices")) { Task { await model.undoDeferral(proposal) } }
                    }
                }
            }
        }.navigationTitle(pTr("Whole checkout"))
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: field != nil, title: pTr("Done")) { field = nil }
        .disabled(model.saving)
        .onAppear { populate() }
        .onChange(of: model.journey?.basket?.current.id) { _, _ in populate() }
        .onChange(of: model.selectedID) { _, _ in populate() }
        .onChange(of: model.journey?.quote) { _, _ in populate() }
        .onChange(of: model.journey?.context) { _, _ in populate() }
        .onChange(of: model.journey?.cap) { _, _ in populate() }
        .sheet(item: $quoteReview) { review in
            NavigationStack {
                Form {
                    if let earlier = review.draft.reviewedQuote {
                        Section(pTr("Earlier checkout quote")) {
                            PickupQuoteTermsView(quote: earlier, cap: review.draft.originalCap)
                            PickupSavedCheckoutPricingView(pricing: earlier.pricing)
                        }
                    }
                    Section(pTr("Proposed checkout quote")) {
                        PickupQuoteTermsView(quote: review.quote, cap: review.cap)
                        PickupSavedCheckoutPricingView(pricing: review.quote.pricing)
                        if let result = try? CheckoutEngine.evaluate(review.quote, cap: review.cap) {
                            PickupResultView(result: result)
                        }
                    }
                    if model.journey.map({ review.draft.matchesSource($0, workspaceID: model.sourceWorkspaceID) }) == true {
                        Button(pTr("Save reviewed checkout")) { Task { await commit(review) } }.disabled(model.saving || model.hasPendingSave)
                    } else {
                        Text(pTr("This checkout changed. Go back and reopen its current details before saving."))
                    }
                    PickupSaveStatus(model: model) {
                        if let saved = model.journey, saved.id == review.draft.journeyID,
                           saved.quote == review.quote, saved.cap == review.cap {
                            draft = PickupCheckoutDraft(journey: saved, workspaceID: model.sourceWorkspaceID)
                            quoteReview = nil
                        }
                    }
                }
                .navigationTitle(pTr("Review checkout changes"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pTr("Cancel")) { quoteReview = nil } } }
            }
        }
        .confirmationDialog(pTr("Discard unsaved checkout edits?"), isPresented: $reopeningCurrent, titleVisibility: .visible) {
            Button(pTr("Discard edits and reopen"), role: .destructive) {
                guard let value = model.journey else { return }
                draft = PickupCheckoutDraft(journey: value, workspaceID: model.sourceWorkspaceID)
                preview = nil; selected = []; formError = nil
                field = nil; comparingHold = false; hold = ""; availableFunds = ""
            }
            Button(pTr("Cancel"), role: .cancel) {}
        } message: {
            Text(pTr("This only discards the edits shown here. The saved checkout stays unchanged."))
        }
        .confirmationDialog(pTr("Replace saved pricing?"), isPresented: $reviewingReplacement, titleVisibility: .visible) {
            Button(pTr("Start replacement pricing")) {
                draft.beginPricingReplacement(); preview = nil; formError = nil
            }.disabled(draftIsStale)
            Button(pTr("Cancel"), role: .cancel) {}
        } message: {
            Text(pTr("Review the saved details above first. New pricing starts blank and replaces them only when you save. Cancel or go back to keep the saved checkout."))
        }
        .onChange(of: comparingHold) { _, enabled in
            guard !enabled else { return }
            if field == .hold || field == .funds { field = nil }
            hold = ""
            availableFunds = ""
        }
    }
    private func populate() {
        guard let value = model.journey, draft.refreshIfPristine(from: value, workspaceID: model.sourceWorkspaceID, hasLocalReview: hasLocalReview) else { return }
        preview = nil; selected = []; formError = nil
    }
    private func saveQuote() {
        let reviewed = draft
        formError = nil; preview = nil
        do {
            guard let value = model.journey else { throw PickupCheckoutDraftError.staleSource }
            let submission = try reviewed.submission(for: value, workspaceID: model.sourceWorkspaceID)
            let review = QuoteReview(draft: reviewed, quote: submission.quote, cap: submission.cap)
            if reviewed.changedRetailerTerms && reviewed.replacingPricing {
                quoteReview = review
            } else {
                Task { await commit(review) }
            }
        } catch PickupCheckoutDraftError.staleSource {
            formError = pTr("This checkout changed. Go back and reopen its current details before saving.")
        } catch PickupCheckoutDraftError.reviewReplacement {
            formError = pTr("Review the saved pricing before starting a replacement.")
        } catch {
            formError = pTr("Enter source, store, branch and slot, and valid dollar amounts with at most two decimal places.")
        }
    }
    @MainActor private func commit(_ review: QuoteReview) async {
        if await model.setQuote(review.quote, cap: review.cap, reviewed: review.draft), let saved = model.journey,
           saved.id == review.draft.journeyID {
            draft = PickupCheckoutDraft(journey: saved, workspaceID: model.sourceWorkspaceID)
            quoteReview = nil
        }
    }
}

private func pickupScopeLabel(_ scope: CheckoutScope) -> String {
    switch scope {
    case .wholeCheckout: pTr("Whole checkout")
    case .dinner: pTr("Dinners only")
    case .item: pTr("Selected items only")
    }
}

private struct PickupQuoteTermsView: View {
    let quote: CheckoutQuote
    let cap: CheckoutCap?
    private var mode: String {
        switch quote.context.mode {
        case .pickup: pTr("Pickup")
        case .delivery: pTr("Delivery")
        case .inStore: pTr("In store")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quote.context.storeID + " · " + quote.context.branchID)
            Text(mode + " · " + quote.context.slot)
            Text(pickupScopeLabel(quote.scope))
            if let cap { LabeledContent(pTr("Spending cap"), value: pMoney(cap.amount) + " · " + pickupScopeLabel(cap.scope)) }
            else { Text(pTr("No spending cap supplied")) }
            Text(quote.context.source)
            Text(quote.context.observedAt.formatted(date: .complete, time: .standard))
        }
    }
}

private struct PickupSavedCheckoutPricingView: View {
    let pricing: CheckoutPricing
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch pricing {
            case .inclusiveTotal(let value):
                Text(pTr("Inclusive total")).font(.headline)
                evidence(value)
            case let .components(lines, complete, fees, discounts, tax, deposits):
                Text(pTr(complete ? "All original items are represented" : "Original items are not fully represented"))
                ForEach(lines) { line in
                    Text(line.name).font(.headline)
                    evidence(line.cost)
                    Text(pTr(line.thresholdEligible ? "Included in fee threshold" : "Excluded from fee threshold")).font(.caption)
                }
                ForEach(Array(fees.enumerated()), id: \.offset) { index, fee in
                    Text(pTr("Retailer fee") + " " + String(index + 1)).font(.headline)
                    switch fee.rule {
                    case .fixed(let value): evidence(value)
                    case let .waivedAt(threshold, below, basis):
                        evidence(below)
                        LabeledContent(pTr("Fee waiver threshold"), value: pMoney(threshold))
                        Text(pTr(basis == .eligibleItemsBeforeDiscounts ? "Fee threshold uses eligible items before discounts" : "Fee threshold uses eligible items after eligible discounts")).font(.caption)
                    }
                }
                ForEach(Array(discounts.enumerated()), id: \.offset) { index, discount in
                    Text(pTr("Discount") + " " + String(index + 1)).font(.headline)
                    evidence(discount.amount)
                    Text(pTr(discount.reducesEligibleSubtotal ? "Discount reduces fee threshold subtotal" : "Discount does not reduce fee threshold subtotal")).font(.caption)
                }
                Text(pTr("Tax")).font(.headline); evidence(tax)
                Text(pTr("Deposits and other charges")).font(.headline); evidence(deposits)
            }
        }
    }
    @ViewBuilder private func evidence(_ value: CostEvidence) -> some View {
        switch value {
        case .exact(let amount): Text(pMoney(amount))
        case let .bounded(lower, upper, reason):
            Text(pMoney(lower) + " – " + pMoney(upper)); Text(pTr(reason)).font(.caption)
        case .unknown(let reason): Text(pTr(reason))
        }
    }
}

struct PickupActivitySheet: UIViewControllerRepresentable {
    let text: String
    let completion: (Bool, String?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in completion(completed, activity?.rawValue) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct PickupHandoffView: View {
    @ObservedObject var model: PickupModel
    let shopID: UUID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var access: WorkspaceAccess
    @State private var sharing: HandoffSnapshot?
    @State private var retailerURL = ""
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            if access.unlocked, let journey = model.journey, journey.id == shopID {
                if let placement = journey.basket?.placements.first,
                   let snapshot = journey.basket?.snapshots.first(where: { $0.id == placement.snapshotID }) {
                    placedReceipt(placement, snapshot: snapshot, quote: journey.frozenQuotes[snapshot.id])
                } else {
                    pendingHandoff(reviewing: journey)
                }
            }
        }.navigationTitle(pTr("Retailer handoff"))
        .disabled(model.saving)
        .sheet(item: $sharing) { snapshot in
            PickupActivitySheet(text: PickupModel.datedRetailerText(snapshot)) { completed, destination in
                Task { await model.recordHandoff(completed ? .shareCompleted : .shareCancelled, snapshot: snapshot, destination: destination) }
            }
        }
    }

    @ViewBuilder private func placedReceipt(_ placement: ReportedPlacement, snapshot: HandoffSnapshot, quote: CheckoutQuote?) -> some View {
        Section(pTr("Placement report")) {
            LabeledContent(pTr("Reported by"), value: reporterLabel(placement.reportedByLocalActorID)).accessibilityIdentifier("pickup.placementReporter")
            LabeledContent(pTr("Reported at"), value: placement.reportedAt.formatted(date: .long, time: .shortened))
            if let quote {
                LabeledContent(pTr("Store"), value: quote.context.storeID)
                LabeledContent(pTr("Branch"), value: quote.context.branchID)
                LabeledContent(pTr("Pickup or delivery slot"), value: quote.context.slot)
                if let result = try? CheckoutEngine.evaluate(quote, cap: nil) {
                    LabeledContent(pickupScopeLabel(quote.scope), value: pickupResultText(result))
                }
            }
        }
        Section(pTr("Dated snapshot")) {
            Text(verbatim: PickupModel.datedRetailerText(snapshot))
                .accessibilityIdentifier("pickup.placedSnapshot").textSelection(.enabled)
        }
        handoffHistory(model.journey?.basket?.handoffActions.filter { $0.snapshotID == snapshot.id } ?? [])
    }

    private func reporterLabel(_ actorID: UUID?) -> String {
        guard let actorID else { return pTr("Shopper not recorded") }
        return actorID == access.localActorID ? pTr("Local shopper on this iPhone") : pTr("Original local shopper")
    }

    @ViewBuilder private func handoffHistory(_ actions: [HandoffAction]) -> some View {
        if !actions.isEmpty {
            Section(pTr("Handoff history")) {
                ForEach(actions) { event in Text("\(pTr(event.kind.rawValue)) · \(event.occurredAt.formatted())") }
            }
        }
    }

    @ViewBuilder private func pendingHandoff(reviewing journey: PickupJourney) -> some View {
        PickupStockBasisNotice(model: model)
        Text(pTr("Freeze the reviewed revision before leaving the app. Copying or sharing does not place an order."))
        Button(pTr("Freeze reviewed basket")) {
            Task {
                guard access.unlocked else { return }
                await model.freeze(reviewing: journey)
            }
        }.disabled(model.result == nil || model.frozenSnapshot != nil)
        if let snapshot = model.frozenSnapshot {
            let text = PickupModel.datedRetailerText(snapshot)
            Section(pTr("Dated snapshot")) { Text(text).textSelection(.enabled) }
            Button(pTr("Copy dated list")) { Task {
                guard await model.recordHandoff(.copyAttempted, snapshot: snapshot), access.unlocked,
                      model.hasCurrentBasketStockBasis, model.frozenSnapshot?.id == snapshot.id else { return }
                UIPasteboard.general.string = text
                await model.recordHandoff(.copied, snapshot: snapshot)
            } }.disabled(!model.hasCurrentBasketStockBasis)
            Button(pTr("Share dated list")) { Task {
                guard await model.recordHandoff(.shareOpened, snapshot: snapshot), access.unlocked,
                      model.hasCurrentBasketStockBasis, model.frozenSnapshot?.id == snapshot.id else { return }
                sharing = snapshot
            } }.disabled(!model.hasCurrentBasketStockBasis)
            PickupRecipientSection(model: model, channel: .retailer, versionID: snapshot.id,
                                   language: Locale.current.language.languageCode?.identifier == "es" ? "es-US" : "en-US")
                .id(snapshot.id)
            TextField(pTr("Retailer website (https://…)"), text: $retailerURL).keyboardType(.URL).textInputAutocapitalization(.never)
            Button(pTr("Open retailer website")) { Task {
                guard access.unlocked, model.hasCurrentBasketStockBasis, model.frozenSnapshot?.id == snapshot.id else { return }
                guard let url = URL(string: retailerURL), url.scheme == "https", url.host != nil else { model.error = pTr("Enter a valid https retailer address."); return }
                if await UIApplication.shared.open(url) { await model.recordHandoff(.retailerOpened, snapshot: snapshot, destination: url.host) }
                else { model.error = pTr("Could not open the retailer. Placement remains unconfirmed.") }
            } }.disabled(!model.hasCurrentBasketStockBasis)
            Button(pTr("Still checking out")) { dismiss() }
            Button(pTr("I placed this order")) { Task {
                guard access.unlocked else { return }
                await model.reportPlaced(reviewing: snapshot, by: access.localActorID)
            } }.buttonStyle(.borderedProminent)
                .disabled(!model.hasCurrentBasketStockBasis)
            if !model.hasCurrentBasketStockBasis {
                Text(ledgerText("The frozen order keeps its original quantities. Reporting an order you already placed does not confirm that the changed food supply covers every meal."))
                Button(ledgerText("I already placed this original order with the retailer")) {
                    Task {
                        guard access.unlocked else { return }
                        await model.reportPlaced(reviewing: snapshot, by: access.localActorID, acknowledgingChangedStock: true)
                    }
                }.accessibilityIdentifier("pickupReportOriginalOrderAfterStockChange")
            }
            Button(pTr("Reopen draft and recheck prices")) {
                Task {
                    guard access.unlocked else { return }
                    await model.reopenDraft(reviewing: snapshot)
                }
            }
            handoffHistory(model.journey?.basket?.handoffActions ?? [])
        }
    }
}

private struct PickupWeightReview: View {
    @ObservedObject var model: PickupModel
    let shopID: UUID
    @State private var lineID: UUID?
    @State private var rate = ""
    @State private var increment = ""
    @State private var unit: UnitOfMeasure = .pound
    @State private var rounding: WeightChargeRounding = .unknown
    private enum Field { case rate, increment }
    @FocusState private var field: Field?

    private var journey: PickupJourney? { model.journey.flatMap { $0.id == shopID ? $0 : nil } }
    private var currentQuote: CheckoutQuote? {
        guard let journey, let basket = journey.basket, journey.quotedRevisionID == basket.current.id,
              let quote = journey.quote, quote.context == journey.context, quote.context.commitmentsID == shopID,
              case .components(let lines, _, _, _, _, _) = quote.pricing,
              Set(lines.map(\.id)) == Set(basket.current.lines.map(\.id)) else { return nil }
        return quote
    }
    private var limit: CheckoutWeightLimit {
        guard let lineID, let quote = currentQuote, let price = try? ComparisonModel.money(rate),
              let step = try? Rational(decimal: increment) else { return .unresolved }
        return (try? CheckoutEngine.maximumWeight(quote: quote, cap: journey?.cap, lineID: lineID,
            rate: price, increment: step, rounding: rounding)) ?? .unresolved
    }

    private func billedWeight(_ amount: Rational) -> String {
        let value = Decimal(amount.numerator) / Decimal(amount.denominator)
        let unitName = pTr(amount == .one ? unit.rawValue : "Quantity plural " + unit.rawValue)
        return "\(value.formatted(.number.precision(.fractionLength(0...18)))) \(unitName)"
    }
    private func clearRate() { rate = ""; increment = ""; rounding = .unknown }

    var body: some View {
        Form {
            Section {
                Text(pTr("Use the latest saved checkout terms. Choose one item sold by weight. The other items and their charges stay in the calculation."))
                if let quote = currentQuote {
                    Text("\(quote.context.branchID) · \(quote.context.slot)")
                    Text("\(quote.context.source) · \(quote.context.observedAt.formatted())")
                }
                if let cap = journey?.cap, cap.scope == .wholeCheckout {
                    LabeledContent(pTr("Spending cap"), value: pMoney(cap.amount))
                }
            }
            Section(pTr("Weighed item")) {
                Picker(pTr("Weighed item"), selection: $lineID) {
                    Text(pTr("Choose an item")).tag(UUID?.none)
                    ForEach(journey?.basket?.current.lines ?? []) { line in Text(line.name).tag(Optional(line.id)) }
                }.accessibilityIdentifier("checkout.weightLine")
                Picker(pTr("Price and increment unit"), selection: $unit) {
                    ForEach([UnitOfMeasure.pound, .ounce, .kilogram, .gram], id: \.self) { Text(pTr($0.rawValue)).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(pTr("Price per selected weight unit")).font(.caption).accessibilityHidden(true)
                    PickupEvidenceField(title: "Price per selected weight unit", amount: $rate)
                        .focused($field, equals: .rate).accessibilityIdentifier("checkout.weightRate")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(pTr("Retailer billing increment")).font(.caption).accessibilityHidden(true)
                    TextField(pTr("Retailer billing increment"), text: $increment)
                        .keyboardType(.decimalPad).focused($field, equals: .increment).accessibilityIdentifier("checkout.weightIncrement")
                }
                Text(pTr("Enter the smallest weight the retailer bills in that unit, such as 0.01 lb."))
                Picker(pTr("Fractional-cent rounding"), selection: $rounding) {
                    Text(pTr("Not confirmed")).tag(WeightChargeRounding.unknown)
                    Text(pTr("Round up to a cent")).tag(WeightChargeRounding.up)
                    Text(pTr("Nearest cent, half up")).tag(WeightChargeRounding.nearestCent)
                }
            }
            Section(pTr("Maximum weight that fits")) {
                switch limit {
                case let .maximum(weight, lineCost, checkout):
                    LabeledContent(pTr("Maximum billed weight"), value: billedWeight(weight))
                        .accessibilityIdentifier("checkout.maximumWeight")
                    LabeledContent(pTr("Item charge at that weight"), value: pMoney(lineCost))
                        .accessibilityIdentifier("checkout.maximumLineCharge")
                    LabeledContent(pTr("Whole pickup at that weight"), value: pMoney(checkout))
                        .accessibilityIdentifier("checkout.maximumTotal")
                    Text(pTr("Confirm the retailer’s actual weight and total before placing the order."))
                case .noPositiveIncrement: Text(pTr("No positive billing increment fits this cap with the entered charges."))
                case .unresolved:
                    Text(pTr("Weight limit unresolved. Review the whole-pickup cap, the other items, fees, discounts, tax and deposits. Enter the rate, billing increment and any required rounding."))
                        .accessibilityIdentifier("checkout.weightUnresolved")
                }
            }
        }
        .onChange(of: lineID) { _, _ in clearRate() }
        .onChange(of: unit) { _, _ in clearRate() }
        .navigationTitle(pTr("Check price by weight"))
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: field != nil, title: pTr("Done")) { field = nil }
    }
}
