import SwiftUI
import CoreDomain

struct DinnerQuotesView: View {
    @ObservedObject var model: DinnerFeatureModel
    @State private var draft = DinnerQuoteEditDraft()
    @State private var pair: TwoStoreQuotePair?
    @State private var result: TwoStoreQuoteResult?
    @State private var showPreview = false
    @FocusState private var inputFocus: String?
    var body: some View {
        Form {
            if model.budgetVisible, let basis = model.shop?.basis {
                Section(dinnerText("Available budget")) {
                    if !basis.branch.isEmpty { Text(dinnerFormat("Current pickup branch: %@",basis.branch)).accessibilityIdentifier("quoteCurrentBranch") }
                    Text(dinnerFormat("Amount available for %@: %@", dinnerBudgetScope(basis.capScope), dinnerMoney(basis.cap)))
                    if let reserve = basis.fixedReserve { Text(dinnerFormat("Reserve recorded separately: %@", dinnerMoney(reserve))) }
                    Text(dinnerText("The entered cap is already the amount available for its scope. A recorded reserve is not subtracted again."))
                }
            }
            if let pair, let result, model.budgetVisible {
                Section(dinnerText("Reviewed trip comparison")) {
                    Text(dinnerText("These are entered observations, not live prices or stock."))
                    quoteResult(pair.first, result.first).accessibilityIdentifier("quoteFirstResult")
                    quoteResult(pair.second, result.second).accessibilityIdentifier("quoteSecondResult")
                    quoteMoneyChange("Items before fees and discounts, second minus first: %@", result.itemSubtotalChange)
                    quoteMoneyChange("Checkout change, second minus first: %@", result.checkoutChange)
                    quoteMoneyChange("Checkout plus trip cash, second minus first: %@", result.tripCashChange)
                    if let minutes = result.extraMinutesChange { Text(dinnerFormat("Extra minutes change: %d", minutes)) }
                    if let breakEven = result.secondTripCashBreakEven { Text(dinnerFormat("Second trip cash break-even: %@", dinnerMoney(breakEven))) }
                    ForEach(result.issues, id: \.self) { Text(dinnerIssue($0)) }
                    Button(dinnerText("Save reviewed comparison")) { Task { _ = await model.saveQuotePair(pair) } }.disabled(!model.editable)
                    if model.state.quotePairs.contains(pair) {
                        let current = model.shop?.revisionID == pair.baseRevisionID && model.shop?.basisRevision == pair.basisRevision
                        if !current { Text(dinnerText("This saved comparison uses an earlier pickup revision. Review the store options again to change the current pickup.")) }
                        Button(dinnerFormat("Preview using %@", pair.first.label)) { showPreview = model.previewAdoption(pair, option: pair.first) }
                            .disabled(!current || !result.comparable || !result.first.coverageConfirmed || !model.editable)
                        Button(dinnerFormat("Preview using %@", pair.second.label)) { showPreview = model.previewAdoption(pair, option: pair.second) }
                            .disabled(!current || !result.comparable || !result.second.coverageConfirmed || !model.editable)
                    }
                    Button(dinnerText("Continue editing"), action: editQuotes)
                    Button(dinnerText("Start a new comparison")) { draft = DinnerQuoteEditDraft(); editQuotes() }
                }
            } else if model.budgetVisible {
                savedComparisons
                if draft.hasSeparateCommitments {
                    commitmentFields(dinnerText("First store commitments"), rows: $draft.commitments)
                    commitmentFields(dinnerText("Second store commitments"), rows: $draft.secondCommitments)
                } else {
                    commitmentFields(dinnerText("Same commitments at both stores"), rows: $draft.commitments)
                }
                DinnerStoreFields(title: dinnerText("First store"), prefix: "quote.first.", draft: $draft.first, focus: $inputFocus, shopZone: model.shop?.basis.timeZoneIdentifier)
                DinnerStoreFields(title: dinnerText("Second store"), prefix: "quote.second.", draft: $draft.second, focus: $inputFocus, shopZone: model.shop?.basis.timeZoneIdentifier)
                Section {
                    Button(dinnerText("Review two complete trips")) {
                        do {
                            guard let shop = model.shop else { return }
                            let candidate = try draft.pair(for: shop)
                            let compared = try model.compare(candidate); pair = candidate; result = compared
                        } catch { model.report(error) }
                    }.disabled(!model.editable)
                }
            } else { Text(dinnerText("Budget access is required to review store quotes.")) }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Two store trips")).dinnerAccess(model, budget: true)
            .onChange(of: model.shop?.id) { _, _ in
                draft = DinnerQuoteEditDraft(); editQuotes(); showPreview = false
            }
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                if pair != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(dinnerText("Edit"), action: editQuotes)
                            .accessibilityLabel(dinnerText("Edit quotes"))
                            .accessibilityIdentifier("quoteEditReviewed")
                    }
                }
            }
            .keyboardDoneAction(visible: inputFocus != nil, title: ledgerText("Done"), identifier: "quoteKeyboardDone") { inputFocus = nil }
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
    private func commitmentFields(_ title: String, rows: Binding<[DinnerCommitmentDraft]>) -> some View {
        Section(title) {
            if !draft.hasSeparateCommitments {
                Text(dinnerText("List the dinners, lunches, sides and staples that both complete store plans must cover. Include all grocery needs in each reviewed total."))
            }
            ForEach(rows.wrappedValue) { value in
                let commitment = dinnerDraftBinding(value, in: rows)
                VStack(alignment: .leading, spacing: 6) {
                    TextField(dinnerText("Commitment name"), text: commitment.name)
                        .focused($inputFocus, equals: "\(title).\(value.id).name")
                    TextField(dinnerText("Required portions"), text: commitment.portions)
                        .focused($inputFocus, equals: "\(title).\(value.id).portions")
                    Picker(dinnerText("Commitment type"), selection: commitment.kind) {
                        Text(dinnerText("Dinner")).tag(DinnerCommitment.Kind.dinner)
                        Text(dinnerText("Lunch")).tag(DinnerCommitment.Kind.lunch)
                        Text(dinnerText("Side")).tag(DinnerCommitment.Kind.side)
                        Text(dinnerText("Staple")).tag(DinnerCommitment.Kind.staple)
                    }
                    Toggle(dinnerText("Protected commitment"), isOn: commitment.isProtected)
                    Button(dinnerText("Remove commitment"), role: .destructive) { rows.wrappedValue.removeAll { $0.id == value.id } }
                }.padding(.vertical, 5)
            }
            Button(dinnerText("Add commitment")) { rows.wrappedValue.append(DinnerCommitmentDraft()) }.disabled(rows.wrappedValue.count >= 100)
        }
    }
    private func editQuotes() {
        pair = nil
        result = nil
    }
    @ViewBuilder private var savedComparisons: some View {
        if let shop = model.shop {
            let saved = model.state.quotePairs.filter { $0.shopID == shop.id }
            if !saved.isEmpty {
                let titles = saved.map { dinnerFormat("%@ and %@", $0.first.label, $0.second.label) }
                let counts = Dictionary(titles.map { ($0, 1) }, uniquingKeysWith: +)
                Section(dinnerText("Saved comparisons")) {
                    ForEach(Array(saved.enumerated().reversed()), id: \.element.id) { index, comparison in
                        let title = titles[index]
                        let repeats = counts[title, default: 0] > 1
                        Button(repeats ? dinnerFormat("%@ · comparison %d", title, index + 1) : title) {
                            do {
                                result = try model.compare(comparison)
                                draft = DinnerQuoteEditDraft(comparison)
                                pair = comparison
                            } catch { model.report(error) }
                        }
                    }
                }
            }
        }
    }

    private func quoteResult(_ option: StoreQuoteOption, _ value: StoreQuoteResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(option.label).font(.headline)
            Text(dinnerFormat("Store and branch: %@ · %@", option.quote.context.storeID, option.quote.context.branchID))
            Text(dinnerFormat("Store slot: %@", DinnerStoreDraft.slotDate(option.quote.context.slot).map { dinnerStoreSlot($0, zoneID: option.adoptionBasis?.timeZoneIdentifier) } ?? option.quote.context.slot))
            if let terms = option.eligibilityTerms { Text(dinnerFormat("Price conditions: %@", terms)) }
            Text(dinnerFormat("Items before fees and discounts: %@", dinnerMoney(try? TwoStoreQuoteEngine.itemSubtotal(option))))
            Text(option.quote.context.source)
            Text(option.quote.context.observedAt.formatted(date: .abbreviated, time: .shortened))
            if option.quote.scope != .wholeCheckout {
                Text(dinnerFormat("Recorded scope: %@", dinnerBudgetScope(option.quote.scope == .dinner ? .dinnersOnly : .selectedItems)))
            }
            if case let .inclusiveTotal(.bounded(lower, upper, reason)) = option.quote.pricing {
                Text(dinnerFormat("Recorded cost range: %@ to %@", dinnerMoney(lower), dinnerMoney(upper)))
                Text(reason)
            } else {
                Text(dinnerFormat("Checkout: %@", dinnerMoney(value.checkout.total.exact)))
            }
            Text(dinnerCap(value.checkout.cap))
            switch option.trip.incrementalCash {
            case .exact(let amount): Text(dinnerFormat("Incremental trip cash: %@", dinnerMoney(amount)))
            case .bounded(let lower, let upper, _): Text(dinnerFormat("Incremental trip cash range: %@ to %@", dinnerMoney(lower), dinnerMoney(upper)))
            case .unknown: Text(dinnerFormat("Incremental trip cash: %@", dinnerMoney(nil)))
            }
            Text(dinnerFormat("Checkout plus incremental trip cash: %@", dinnerMoney(value.tripInclusive.total.exact)))
            Text(value.coverageConfirmed ? dinnerText("Required availability reviewed") : dinnerText("Required availability unresolved"))
            if let minutes = value.extraMinutes { Text(dinnerFormat("Extra minutes: %d", minutes)) }
            Text(option.trip.tripAlreadyPlanned ? dinnerText("Trip already planned") : dinnerText("Additional trip"))
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
}
struct DinnerStoreFields: View {
    let title: String
    let prefix: String
    @Binding var draft: DinnerStoreDraft
    let focus: FocusState<String?>.Binding
    var shopZone: String? = nil
    var body: some View {
        Section(title) {
            textField(dinnerText("Store label"), value: $draft.label, key: "label")
            textField(dinnerText("Retailer name or identifier"), value: $draft.storeID, key: "storeID")
            textField(dinnerText("Branch"), value: $draft.branch, key: "branch")
            Picker(dinnerText("Mode"), selection: $draft.mode) {
                Text(dinnerText("Pickup")).tag(ShoppingMode.pickup)
                Text(dinnerText("Delivery")).tag(ShoppingMode.delivery)
                Text(dinnerText("In store")).tag(ShoppingMode.inStore)
            }
            if let slot = Binding($draft.writtenSlot) {
                textField(dinnerText("Store slot"), value: slot, key: "slot")
            } else {
                let zone = (draft.savedSlotZone ?? shopZone).flatMap(TimeZone.init(identifier:)) ?? .current
                DatePicker(dinnerText("Store slot"), selection: $draft.slot)
                    .environment(\.timeZone, zone)
                if zone != .current { Text(verbatim: zone.identifier) }
            }
            textField(dinnerText("Evidence source"), value: $draft.source, key: "source")
            DatePicker(dinnerText("Observed at"), selection: $draft.observedAt)
            if case .components = draft.retainedCheckout?.pricing {
                Text(dinnerText("This comparison keeps the recorded line prices, fees, discounts, taxes and deposits."))
            } else {
                EnteredQuoteValueField(title: dinnerText("Items before fees and discounts in USD, optional"), value: $draft.itemSubtotal, identifier: prefix + "itemSubtotal", focus: focus)
            }
            textField(dinnerText("Price conditions, such as a loyalty card"), value: $draft.eligibilityTerms, key: "eligibilityTerms")
            if let quote = draft.retainedCheckout {
                Text(dinnerFormat("Recorded scope: %@", dinnerBudgetScope(quote.scope == .wholeCheckout ? .wholeShop : quote.scope == .dinner ? .dinnersOnly : .selectedItems)))
                if case let .inclusiveTotal(.bounded(lower, upper, reason)) = quote.pricing {
                    Text(dinnerFormat("Recorded cost range: %@ to %@", dinnerMoney(lower), dinnerMoney(upper)))
                    Text(reason)
                } else if let amount = try? CheckoutEngine.evaluate(quote).total {
                    Text(dinnerFormat("Recorded cost: %@", dinnerMoney(amount.exact)))
                }
                Text(dinnerText("Edit other observations here. Start a new comparison to enter a different checkout total."))
            } else {
                EnteredQuoteValueField(title: dinnerText("Whole checkout total in USD, optional"), value: $draft.total, identifier: prefix + "total", focus: focus)
                Toggle(dinnerText("Total includes every item, fee, discount, tax and deposit"), isOn: $draft.allChargesIncluded).accessibilityIdentifier(prefix + "allChargesIncluded")
            }
            Toggle(dinnerText("All required quantities match the commitments"), isOn: $draft.quantitiesMatched).accessibilityIdentifier(prefix + "quantitiesMatched")
            Toggle(dinnerText("This is one complete store plan"), isOn: $draft.singleStore).accessibilityIdentifier(prefix + "singleStore")
            Picker(dinnerText("Required product availability"), selection: $draft.availability) {
                Text(dinnerText("Unknown")).tag(0)
                Text(dinnerText("Reviewed available")).tag(1)
                Text(dinnerText("Unavailable")).tag(2)
            }.accessibilityIdentifier(prefix + "availability")
            if let (lower, upper, reason) = draft.tripRange {
                Text(dinnerFormat("Incremental trip cash range: %@ to %@", dinnerMoney(lower), dinnerMoney(upper)))
                Text(reason)
            } else {
                EnteredQuoteValueField(title: dinnerText("Incremental trip cash in USD, optional"), value: $draft.tripCash, identifier: prefix + "tripCash", focus: focus)
            }
            EnteredQuoteValueField(title: dinnerText("Extra minutes, optional"), value: $draft.extraMinutes, identifier: prefix + "extraMinutes", focus: focus)
            Toggle(dinnerText("Trip already planned"), isOn: $draft.alreadyPlanned).accessibilityIdentifier(prefix + "alreadyPlanned")
            Text(dinnerText("Blank costs stay unresolved. Enter zero only when you have confirmed there is no charge."))
        }
    }
    private func textField(_ title: String, value: Binding<String>, key: String) -> some View {
        let identifier = prefix + key
        return TextField(title, text: value).focused(focus, equals: identifier).accessibilityIdentifier(identifier)
    }
}

func quoteMoneyChange(_ format: String, _ money: Money?) -> some View {
    let amount = dinnerMoney(money)
    // Keep the sign beside its currency amount when a comparison wraps across lines.
    let visible = amount.replacingOccurrences(of: "-", with: "-\u{2060}")
        .replacingOccurrences(of: "−", with: "−\u{2060}")
    return Text(verbatim: dinnerFormat(format, visible))
        .accessibilityLabel(Text(verbatim: dinnerFormat(format, amount)))
}

/// Financial and time meaning remains visible after the placeholder becomes an entered value.
struct EnteredQuoteValueField: View {
    let title: String
    @Binding var value: String
    let identifier: String
    let focus: FocusState<String?>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $value).focused(focus, equals: identifier).accessibilityIdentifier(identifier)
        }
    }
}
