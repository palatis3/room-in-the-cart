import SwiftUI
import CoreDomain

struct DinnerQuotesView: View {
    @ObservedObject var model: DinnerFeatureModel
    @State private var commitments = [DinnerCommitmentDraft()]
    @State private var first = DinnerStoreDraft()
    @State private var second = DinnerStoreDraft()
    @State private var pair: TwoStoreQuotePair?
    @State private var result: TwoStoreQuoteResult?
    @State private var showPreview = false
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
                    Text(dinnerFormat("Items before fees and discounts, second minus first: %@", dinnerMoney(result.itemSubtotalChange)))
                    Text(dinnerFormat("Checkout change, second minus first: %@", dinnerMoney(result.checkoutChange)))
                    Text(dinnerFormat("Checkout plus trip cash, second minus first: %@", dinnerMoney(result.tripCashChange)))
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
                }
            } else if model.budgetVisible {
                savedComparisons
                Section(dinnerText("Same commitments at both stores")) {
                    Text(dinnerText("List the dinners, lunches, sides and staples that both complete store plans must cover. Include all grocery needs in each reviewed total."))
                    ForEach($commitments) { $commitment in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(dinnerText("Commitment name"), text: $commitment.name)
                            TextField(dinnerText("Required portions"), text: $commitment.portions)
                            Picker(dinnerText("Commitment type"), selection: $commitment.kind) {
                                Text(dinnerText("Dinner")).tag(DinnerCommitment.Kind.dinner)
                                Text(dinnerText("Lunch")).tag(DinnerCommitment.Kind.lunch)
                                Text(dinnerText("Side")).tag(DinnerCommitment.Kind.side)
                                Text(dinnerText("Staple")).tag(DinnerCommitment.Kind.staple)
                            }
                            Toggle(dinnerText("Protected commitment"), isOn: $commitment.isProtected)
                            Button(dinnerText("Remove commitment"), role: .destructive) { commitments.removeAll { $0.id == commitment.id } }
                        }.padding(.vertical, 5)
                    }
                    Button(dinnerText("Add commitment")) { commitments.append(DinnerCommitmentDraft()) }.disabled(commitments.count >= 100)
                }
                DinnerStoreFields(title: dinnerText("First store"), prefix: "quote.first.", draft: $first)
                DinnerStoreFields(title: dinnerText("Second store"), prefix: "quote.second.", draft: $second)
                Section {
                    Button(dinnerText("Review two complete trips")) {
                        do {
                            guard let shop = model.shop else { return }
                            let same = DinnerCommitmentSet(commitments: try commitments.map { try $0.commitment() })
                            let candidate = TwoStoreQuotePair(shopID: shop.id, baseRevisionID: shop.revisionID, basisRevision: shop.basisRevision,
                                first: try first.option(commitments: same, basis: shop.basis), second: try second.option(commitments: same, basis: shop.basis))
                            let compared = try model.compare(candidate); pair = candidate; result = compared
                        } catch { model.report(error) }
                    }.disabled(!model.editable)
                }
            } else { Text(dinnerText("Budget access is required to review store quotes.")) }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Two store trips")).dinnerAccess(model, budget: true)
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                if pair != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(dinnerText("Edit quotes"), action: editQuotes).accessibilityIdentifier("quoteEditReviewed")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(ledgerText("Done")) { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        .accessibilityIdentifier("quoteKeyboardDone")
                }
            }
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
    private func editQuotes() {
        pair = nil
        result = nil
    }
    @ViewBuilder private var savedComparisons: some View {
        if let shop = model.shop {
            let saved = model.state.quotePairs.filter { $0.shopID == shop.id }
            if !saved.isEmpty {
                Section(dinnerText("Saved comparisons")) {
                    ForEach(saved) { comparison in
                        Button(dinnerFormat("%@ and %@",comparison.first.label,comparison.second.label)) {
                            do { result = try model.compare(comparison); pair = comparison } catch { model.report(error) }
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
            Text(dinnerFormat("Store slot: %@", ISO8601DateFormatter().date(from: option.quote.context.slot)?.formatted(date: .abbreviated, time: .shortened) ?? option.quote.context.slot))
            if let terms = option.eligibilityTerms { Text(dinnerFormat("Price conditions: %@", terms)) }
            Text(dinnerFormat("Items before fees and discounts: %@", dinnerMoney(try? TwoStoreQuoteEngine.itemSubtotal(option))))
            Text(option.quote.context.source)
            Text(option.quote.context.observedAt.formatted(date: .abbreviated, time: .shortened))
            Text(dinnerFormat("Checkout: %@", dinnerMoney(value.checkout.total.exact)))
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
    var body: some View {
        Section(title) {
            TextField(dinnerText("Store label"), text: $draft.label).accessibilityIdentifier(prefix + "label")
            TextField(dinnerText("Retailer name or identifier"), text: $draft.storeID).accessibilityIdentifier(prefix + "storeID")
            TextField(dinnerText("Branch"), text: $draft.branch).accessibilityIdentifier(prefix + "branch")
            Picker(dinnerText("Mode"), selection: $draft.mode) {
                Text(dinnerText("Pickup")).tag(ShoppingMode.pickup)
                Text(dinnerText("Delivery")).tag(ShoppingMode.delivery)
                Text(dinnerText("In store")).tag(ShoppingMode.inStore)
            }
            DatePicker(dinnerText("Store slot"), selection: $draft.slot)
            TextField(dinnerText("Evidence source"), text: $draft.source).accessibilityIdentifier(prefix + "source")
            DatePicker(dinnerText("Observed at"), selection: $draft.observedAt)
            TextField(dinnerText("Items before fees and discounts in USD, optional"), text: $draft.itemSubtotal).accessibilityIdentifier(prefix + "itemSubtotal")
            TextField(dinnerText("Price conditions, such as a loyalty card"), text: $draft.eligibilityTerms).accessibilityIdentifier(prefix + "eligibilityTerms")
            TextField(dinnerText("Whole checkout total in USD, optional"), text: $draft.total).accessibilityIdentifier(prefix + "total")
            Toggle(dinnerText("Total includes every item, fee, discount, tax and deposit"), isOn: $draft.allChargesIncluded).accessibilityIdentifier(prefix + "allChargesIncluded")
            Toggle(dinnerText("All required quantities match the commitments"), isOn: $draft.quantitiesMatched).accessibilityIdentifier(prefix + "quantitiesMatched")
            Toggle(dinnerText("This is one complete store plan"), isOn: $draft.singleStore).accessibilityIdentifier(prefix + "singleStore")
            Picker(dinnerText("Required product availability"), selection: $draft.availability) {
                Text(dinnerText("Unknown")).tag(0)
                Text(dinnerText("Reviewed available")).tag(1)
                Text(dinnerText("Unavailable")).tag(2)
            }.accessibilityIdentifier(prefix + "availability")
            TextField(dinnerText("Incremental trip cash in USD, optional"), text: $draft.tripCash).accessibilityIdentifier(prefix + "tripCash")
            TextField(dinnerText("Extra minutes, optional"), text: $draft.extraMinutes).accessibilityIdentifier(prefix + "extraMinutes")
            Toggle(dinnerText("Trip already planned"), isOn: $draft.alreadyPlanned).accessibilityIdentifier(prefix + "alreadyPlanned")
            Text(dinnerText("Blank costs stay unresolved. Enter zero only when you have confirmed there is no charge."))
        }
    }
}
