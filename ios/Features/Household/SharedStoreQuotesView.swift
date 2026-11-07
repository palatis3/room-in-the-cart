import SwiftUI
import CoreDomain
import HouseholdClient

struct SharedStoreQuotesView: View {
    @ObservedObject var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SharedStoreQuotesModel?
    private var scope: StoreQuoteScope? { household.storeQuoteScope }
    var body: some View {
        Group {
            if let model, model.scope == scope { SharedStoreQuotesContent(model: model, household: household).id(model.scope) }
            else { ContentUnavailableView(StoreQuoteCopy.text("Two entered store quotes"), systemImage: "lock", description: Text(StoreQuoteCopy.text("Select a shared shop and refresh your adult budget access."))) }
        }
        .navigationTitle(StoreQuoteCopy.text("Two store quotes"))
        .task(id: scope) { await open() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model?.invalidate(); model = nil }
            else { Task { await open() } }
        }
        .onDisappear { model?.invalidate() }
    }
    @MainActor private func open() async {
        model?.invalidate(); model = nil
        guard let scope, let service = household.service else { return }
        let next = SharedStoreQuotesModel(scope: scope, service: service, store: household.storeQuotesPendingStore, runtime: { self.scope })
        model = next; await next.load()
    }
}
private struct SharedStoreQuotesContent: View {
    @ObservedObject var model: SharedStoreQuotesModel
    @ObservedObject var household: HouseholdModel
    @State private var first = DinnerStoreDraft()
    @State private var second = DinnerStoreDraft()
    @State private var firstCap = ""
    @State private var secondCap = ""
    @State private var firstCapScope = "wholeCheckout"
    @State private var secondCapScope = "wholeCheckout"
    @State private var firstEligibility = false
    @State private var secondEligibility = false
    @State private var entering = false
    @State private var acknowledgedReviewID: UUID?
    @State private var clearing = false
    @State private var entryNotice: String?
    @FocusState private var inputFocus: String?
    @AccessibilityFocusState private var reviewFocused: Bool
    @AccessibilityFocusState private var resultFocused: Bool
    var body: some View {
        ScrollViewReader { proxy in
        Form {
            if let page = model.page {
                Section {
                    Text(StoreQuoteCopy.text("Manual observations only. Enter two complete single-store plans for the same shared basket. No retailer, route, order, or location is contacted.")).accessibilityIdentifier("sharedQuotes.scope")
                    LabeledContent(ht("Revision"), value: page.shopRevision.formatted())
                    Text(page.shopper ? StoreQuoteCopy.text("You are the assigned shopper. Only you can adopt a reviewed store choice.") : StoreQuoteCopy.text("Your saved comparisons stay private until you explicitly propose one to the assigned shopper."))
                    if page.phase != "draft" { Text(StoreQuoteCopy.text("This shop is frozen or placed. Saved proof is read-only; it cannot change the order.")) }
                    if let basis = page.currentBasis {
                        LabeledContent(StoreQuoteCopy.text("Adopted store"), value: basis.store)
                        LabeledContent(dinnerText("Branch"), value: basis.branch)
                        Text(StoreQuoteCopy.text("Prices from the former store are invalid. Review a fresh checkout quote before freezing."))
                        if page.shopper { NavigationLink(StoreQuoteCopy.text("Review shared checkout after store choice")) { HouseholdShopView(model: household) }.accessibilityIdentifier("sharedQuotes.reviewCheckout") }
                    }
                }
                Section(StoreQuoteCopy.text("Exact shared basket commitments")) {
                    ForEach(page.commitments) { c in
                        LabeledContent(c.label, value: String(format: StoreQuoteCopy.text("%d whole packs"), c.packs))
                    }
                    if page.commitments.isEmpty { Text(StoreQuoteCopy.text("The assigned shopper must review a shared basket before comparing stores.")) }
                }
                if model.review == nil && !model.hasPending {
                    if entering && page.phase == "draft" { editor(page) }
                    else if page.phase == "draft" {
                        Button(StoreQuoteCopy.text("Enter two store quotes")) { entering = true; entryNotice = nil }
                            .disabled(page.commitments.isEmpty).accessibilityIdentifier("sharedQuotes.enter")
                    }
                }
                if let review = model.review {
                    Section {
                        reviewFacts(review, page: page)
                        let acknowledged = acknowledgedReviewID == review.id
                        Button {
                            acknowledgedReviewID = acknowledged ? nil : review.id
                        } label: {
                            Label(StoreQuoteCopy.text("I reviewed these exact quotes, conditions, and shared commitments"),
                                  systemImage: acknowledged ? "checkmark.square.fill" : "square")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(acknowledged ? .isSelected : [])
                        .accessibilityIdentifier("sharedQuotes.acknowledged")
                        Button(actionLabel(review.action)) {
                            Task {
                                guard acknowledgedReviewID == review.id, model.review?.id == review.id else { return }
                                await model.sendReviewed()
                                entering = false; acknowledgedReviewID = nil
                            }
                        }
                        .buttonStyle(PrimaryAction()).disabled(!acknowledged).accessibilityIdentifier("sharedQuotes.confirm")
                        Button(dinnerText("Cancel")) { model.cancelReview(); acknowledgedReviewID = nil }
                    } header: {
                        Text(StoreQuoteCopy.text("Review exact action")).accessibilityFocused($reviewFocused)
                    }.id("store-quote-review")
                }
                Section(StoreQuoteCopy.text("Saved comparisons and shopper proposals")) {
                    if model.pairs.isEmpty { Text(StoreQuoteCopy.text("No comparisons are available in your current scope.")) }
                    ForEach(model.pairs) { pair in
                        DisclosureGroup {
                            if let date = serviceDate(pair.savedAt) { Text(date.formatted(date: .complete, time: .shortened)) }
                            Text(pair.own ? (pair.proposals.isEmpty ? StoreQuoteCopy.text("Saved privately by you") : StoreQuoteCopy.text("You explicitly sent this comparison to the shopper")) : StoreQuoteCopy.text("Explicit proposal for your shopper review"))
                            SharedStoreQuoteFacts(options: pair.options, commitments: pair.commitments, shopID: page.shopId)
                            if !pair.current(in: page) { Text(StoreQuoteCopy.text("Earlier revision or shopper assignment. Keep this proof; enter a fresh comparison for the current draft.")) }
                            if pair.own {
                                ForEach(StoreQuoteChoice.allCases, id: \.self) { choice in
                                    Button(selectionLabel(pair.options[choice], shopper: page.shopper)) { Task { acknowledgedReviewID = nil; await model.prepareSelection(pair: pair, choice: choice) } }
                                        .disabled(!selectionAllowed(pair, choice: choice, page: page))
                                        .accessibilityIdentifier("sharedQuotes.select." + choice.rawValue)
                                }
                            } else if page.shopper {
                                ForEach(pair.proposals) { proposal in
                                    Button(selectionLabel(pair.options[proposal.choice], shopper: true)) { Task { acknowledgedReviewID = nil; await model.prepareSelection(pair: pair, choice: proposal.choice, proposalID: proposal.id) } }
                                        .disabled(!selectionAllowed(pair, choice: proposal.choice, page: page))
                                        .accessibilityIdentifier("sharedQuotes.reviewProposal")
                                }
                            }
                        } label: { Text(verbatim: pair.options.first.label + " / " + pair.options.second.label) }
                    }
                    if page.nextCursor != nil { Button(StoreQuoteCopy.text("Load earlier comparisons")) { Task { await model.load(more: true) } } }
                }
                if page.shopper && model.review == nil && !model.hasPending {
                    Section(StoreQuoteCopy.text("Named adult budget access for this shop")) {
                        Text(StoreQuoteCopy.text("Granting access shares this shop's budget and allows private comparisons and proposals. It does not grant meal planning, household administration, a paid seat, or shopper authority."))
                        ForEach(page.adults) { adult in
                            HStack {
                                Text(verbatim: adult.label); Spacer()
                                Button(adult.enabled ? StoreQuoteCopy.text("Review revoking access") : StoreQuoteCopy.text("Review granting access")) {
                                    Task { acknowledgedReviewID = nil; await model.prepareGrant(adult, enabled: !adult.enabled) }
                                }.accessibilityIdentifier("sharedQuotes.grant." + adult.id.uuidString.lowercased())
                                    .accessibilityLabel(String(format: StoreQuoteCopy.text(adult.enabled ? "Review revoking budget access from %@" : "Review granting budget access to %@"), adult.label))
                            }
                        }
                    }
                }
            }
            if model.hasPending {
                Section(StoreQuoteCopy.text("Exact saved retry")) {
                    Text(StoreQuoteCopy.text("The result is unconfirmed. Retrying keeps the original identifier and reviewed revision through reconnect or app restart."))
                    if let pending = model.pending {
                        Text(actionLabel(pending.action))
                        LabeledContent(StoreQuoteCopy.text("Originally reviewed revision"), value: pending.request.shopRevision.formatted())
                        Button(StoreQuoteCopy.text("Retry exact saved action")) { Task { await model.retry() } }.accessibilityIdentifier("sharedQuotes.retry")
                        DisclosureGroup(StoreQuoteCopy.text("Original reviewed quotes and commitments")) {
                            ForEach(pending.reviewedCommitments) { commitment in LabeledContent(commitment.label, value: String(format:StoreQuoteCopy.text("%d whole packs"),commitment.packs)) }
                            if let options = pending.request.options, !pending.reviewedCommitments.isEmpty { SharedStoreQuoteFacts(options: options, commitments: pending.reviewedCommitments, shopID: pending.shopID) }
                        }.accessibilityIdentifier("sharedQuotes.originalRetryDetails")
                    }
                    Button(StoreQuoteCopy.text("Refresh and clear local retry"), role: .destructive) { clearing = true }
                }.id("store-quote-pending")
            }
            if let notice = model.notice ?? entryNotice {
                Text(notice).accessibilityIdentifier("sharedQuotes.notice").accessibilityFocused($resultFocused).id("store-quote-result")
            }
            if model.busy { ProgressView(ht("Checking service…")) }
            Button(StoreQuoteCopy.text("Refresh store quote access")) { Task { entering = false; first = .init(); second = .init(); await model.load() } }
                .disabled(!model.live).accessibilityIdentifier("sharedQuotes.refresh")
        }
        .disabled(model.busy || !model.live)
        .workingSurface()
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: model.review?.id) { _, id in
            reviewFocused = false
            guard id != nil else { return }
            Task { @MainActor in
                await Task.yield()
                guard model.review?.id == id, model.live else { return }
                proxy.scrollTo("store-quote-review", anchor: .top)
                reviewFocused = true
            }
        }
        .onChange(of: model.pending?.id) { _, id in
            guard id != nil else { return }
            Task { @MainActor in
                await Task.yield()
                guard model.pending?.id == id, model.live else { return }
                proxy.scrollTo("store-quote-pending", anchor: .top)
            }
        }
        .onChange(of: model.notice ?? entryNotice) { _, notice in
            resultFocused = false
            guard notice != nil else { return }
            Task { @MainActor in
                await Task.yield()
                guard (model.notice ?? entryNotice) == notice else { return }
                proxy.scrollTo("store-quote-result", anchor: .center)
                resultFocused = true
            }
        }
        .confirmationDialog(StoreQuoteCopy.text("Clear local retry?"), isPresented: $clearing, titleVisibility: .visible) {
            Button(StoreQuoteCopy.text("Refresh and clear local retry"), role: .destructive) { Task { await model.clearPendingAfterRefresh() } }
        } message: { Text(StoreQuoteCopy.text("Clearing cannot undo a comparison, proposal, grant, or store adoption already received. Review the refreshed household result.")) }
        .keyboardDoneAction(visible: inputFocus != nil, title: ledgerText("Done")) { inputFocus = nil }
        }
    }
    @ViewBuilder private func editor(_ page: StoreQuotePage) -> some View {
        DinnerStoreFields(title: dinnerText("First store"), prefix: "sharedQuotes.first.", draft: $first, focus: $inputFocus)
        termsAndCap(first: true)
        DinnerStoreFields(title: dinnerText("Second store"), prefix: "sharedQuotes.second.", draft: $second, focus: $inputFocus)
        termsAndCap(first: false)
        Section {
            Button(StoreQuoteCopy.text("Review private comparison save")) {
                do {
                    let options = EnteredStoreQuoteOptions(first: try entered(first, cap: firstCap, capScope: firstCapScope, eligibility: firstEligibility), second: try entered(second, cap: secondCap, capScope: secondCapScope, eligibility: secondEligibility))
                    _ = try SharedStoreQuoteMath.compare(options, commitments: page.commitments, shopID: page.shopId)
                    acknowledgedReviewID = nil; entryNotice = nil
                    Task { await model.prepareSave(options) }
                } catch { entryNotice = StoreQuoteCopy.text("Enter both stores, branches, sources, dates and valid amounts. Blank costs and unreviewed availability remain unknown.") }
            }.buttonStyle(PrimaryAction()).accessibilityIdentifier("sharedQuotes.reviewSave")
            Button(dinnerText("Cancel")) { entering = false }
        }
    }
    private func termsAndCap(first isFirst: Bool) -> some View {
        Section(isFirst ? StoreQuoteCopy.text("First store conditions and cap") : StoreQuoteCopy.text("Second store conditions and cap")) {
            Toggle(StoreQuoteCopy.text("Eligibility and price conditions reviewed"), isOn: isFirst ? $firstEligibility : $secondEligibility)
                .accessibilityIdentifier(isFirst ? "sharedQuotes.first.eligibility" : "sharedQuotes.second.eligibility")
            EnteredQuoteValueField(title: StoreQuoteCopy.text("Applicable cap in USD, optional"), value: isFirst ? $firstCap : $secondCap,
                identifier: isFirst ? "sharedQuotes.first.cap" : "sharedQuotes.second.cap", focus: $inputFocus)
            Picker(StoreQuoteCopy.text("Cap scope"), selection: isFirst ? $firstCapScope : $secondCapScope) {
                Text(dinnerText("Whole pickup")).tag("wholeCheckout")
                Text(StoreQuoteCopy.text("Items before fees and discounts only")).tag("itemsOnly")
            }
        }
    }
    private func entered(_ draft: DinnerStoreDraft, cap: String, capScope: String, eligibility: Bool) throws -> EnteredStoreQuote {
        func cents(_ text: String) throws -> Int? { try DinnerEntry.money(text).map { Int($0.minorUnits) } }
        let value = EnteredStoreQuote(label: draft.label, store: draft.storeID, branch: draft.branch, mode: draft.mode.rawValue,
            slot: ISO8601DateFormatter().string(from: draft.slot), observedAt: ISO8601DateFormatter().string(from: draft.observedAt), source: draft.source,
            terms: draft.eligibilityTerms, itemsMinor: try cents(draft.itemSubtotal), checkoutMinor: try cents(draft.total), allChargesIncluded: draft.allChargesIncluded,
            available: draft.availability == 0 ? nil : draft.availability == 1, quantitiesMatched: draft.quantitiesMatched, singleStore: draft.singleStore,
            tripAlreadyPlanned: draft.alreadyPlanned, tripMinor: try cents(draft.tripCash), extraMinutes: try DinnerEntry.minutes(draft.extraMinutes),
            capMinor: try cents(cap), capScope: capScope, eligibilityConfirmed: eligibility)
        try value.validate(); return value
    }
    @ViewBuilder private func reviewFacts(_ review: StoreQuoteIntent, page: StoreQuotePage) -> some View {
        if let options = review.request.options {
            SharedStoreQuoteFacts(options: options, commitments: review.reviewedCommitments, shopID: page.shopId)
            Text(StoreQuoteCopy.text("Saving creates private proof only. It leaves the shared basket, prices, and store unchanged."))
        } else if let pair = model.pairs.first(where: { $0.id == review.request.pairId }), let choice = review.request.choice {
            SharedStoreQuoteFacts(options: pair.options, commitments: pair.commitments, shopID: page.shopId)
            LabeledContent(StoreQuoteCopy.text("Chosen store"), value: pair.options[choice].label)
            if review.action == .adoptions { Text(StoreQuoteCopy.text("Adopting revises the open shared draft and clears former store prices and checkout charges. It preserves the original quote proof and requires fresh checkout review.")) }
            else { Text(StoreQuoteCopy.text("Sending this proposal shares the comparison with the assigned shopper. It does not change the basket.")) }
        } else if let adult = page.adults.first(where: { $0.id == review.request.adultId }) {
            LabeledContent(StoreQuoteCopy.text("Named adult"), value: adult.label)
            Text(review.request.enabled == true ? StoreQuoteCopy.text("Grant budget access for this shop and current shopper assignment") : StoreQuoteCopy.text("Revoke this adult's budget access and pending quote proposals"))
        }
    }
    private func selectionAllowed(_ pair: StoreQuotePage.Pair, choice: StoreQuoteChoice, page: StoreQuotePage) -> Bool {
        model.canPrepare && pair.current(in: page) && pair.comparison.comparable && pair.options[choice].available == true && pair.options[choice].eligibilityConfirmed
    }
    private func selectionLabel(_ option: EnteredStoreQuote, shopper: Bool) -> String {
        String(format: StoreQuoteCopy.text(shopper ? "Review adopting %@" : "Review proposing %@"), option.label)
    }
    private func actionLabel(_ action: StoreQuoteAction) -> String {
        switch action {
        case .pairs: return StoreQuoteCopy.text("Save private comparison")
        case .proposals: return StoreQuoteCopy.text("Send reviewed store proposal")
        case .adoptions: return StoreQuoteCopy.text("Adopt reviewed store for this draft")
        case .grants: return StoreQuoteCopy.text("Confirm named adult budget access")
        }
    }
}

private struct SharedStoreQuoteFacts: View {
    let options: EnteredStoreQuoteOptions
    let commitments: [StoreQuotePage.Commitment]
    let shopID: UUID
    var body: some View {
        if let result = try? SharedStoreQuoteMath.compare(options, commitments: commitments, shopID: shopID) {
            facts(options.first, result: result.first).accessibilityIdentifier("sharedQuotes.firstFacts")
            facts(options.second, result: result.second).accessibilityIdentifier("sharedQuotes.secondFacts")
            Text(dinnerFormat("Items before fees and discounts, second minus first: %@", dinnerMoney(result.itemSubtotalChange)))
            Text(dinnerFormat("Checkout change, second minus first: %@", dinnerMoney(result.checkoutChange)))
            Text(dinnerFormat("Checkout plus trip cash, second minus first: %@", dinnerMoney(result.tripCashChange))).accessibilityIdentifier("sharedQuotes.cashDelta")
            if let minutes = result.extraMinutesChange { Text(dinnerFormat("Extra minutes change: %d", minutes)) }
            if let breakEven = result.secondTripCashBreakEven { Text(dinnerFormat("Second trip cash break-even: %@", dinnerMoney(breakEven))).accessibilityIdentifier("sharedQuotes.breakEven") }
            if let preferred = result.preferredByTotalCash {
                LabeledContent(StoreQuoteCopy.text("Lower confirmed total cash"), value: preferred == SharedStoreQuoteMath.firstID ? options.first.label : options.second.label)
            } else { Text(StoreQuoteCopy.text("No confirmed cheaper complete trip. Review the unresolved facts or equal totals.")) }
            ForEach(result.issues, id: \.self) { Text(dinnerIssue($0)) }
        } else { Text(StoreQuoteCopy.text("The comparison is unresolved. Review both complete quotes.")) }
    }
    private func facts(_ value: EnteredStoreQuote, result: StoreQuoteResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: value.label).font(.headline)
            Text(dinnerFormat("Store and branch: %@ · %@", value.store, value.branch))
            Text(dinnerText(value.mode == "inStore" ? "In store" : value.mode == "delivery" ? "Delivery" : "Pickup"))
            if let date = serviceDate(value.slot) { Text(date.formatted(date: .complete, time: .shortened)) }
            LabeledContent(dinnerText("Evidence source"), value: value.source)
            if let date = serviceDate(value.observedAt) { LabeledContent(dinnerText("Observed at"), value: date.formatted(date: .complete, time: .shortened)) }
            if !value.terms.isEmpty { Text(dinnerFormat("Price conditions: %@", value.terms)) }
            Text(value.eligibilityConfirmed ? StoreQuoteCopy.text("Eligibility reviewed") : StoreQuoteCopy.text("Eligibility unresolved"))
            Text(dinnerFormat("Items before fees and discounts: %@", dinnerMoney(value.itemsMinor.map { Money(minorUnits: Int64($0)) })))
            Text(dinnerFormat("Checkout: %@", dinnerMoney(result.checkout.total.exact)))
            Text(dinnerFormat("Incremental trip cash: %@", dinnerMoney(value.tripMinor.map { Money(minorUnits: Int64($0)) })))
            Text(dinnerFormat("Checkout plus incremental trip cash: %@", dinnerMoney(result.tripInclusive.total.exact)))
            Text(value.tripAlreadyPlanned ? dinnerText("Trip already planned") : dinnerText("Additional trip"))
            if let minutes = value.extraMinutes { Text(dinnerFormat("Extra minutes: %d", minutes)) }
            Text(result.coverageConfirmed ? dinnerText("Required availability reviewed") : dinnerText("Required availability unresolved"))
            cap(value)
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
    @ViewBuilder private func cap(_ value: EnteredStoreQuote) -> some View {
        if let cap = value.capMinor {
            Text(String(format: StoreQuoteCopy.text("Applicable cap: %@ · %@"), dinnerMoney(Money(minorUnits: Int64(cap))), StoreQuoteCopy.text(value.capScope == "itemsOnly" ? "Items before fees and discounts only" : "Whole checkout")))
            if let assessment = try? SharedStoreQuoteMath.capAssessment(value, commitmentsID: shopID) { Text(dinnerCap(assessment)) }
        } else { Text(dinnerText("No cap supplied")) }
    }
}
enum StoreQuoteCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "StoreQuotes") }
}
