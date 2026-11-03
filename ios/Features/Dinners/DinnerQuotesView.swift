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
                    Text(dinnerFormat("Amount available for %@: %@", dinnerBudgetScope(basis.capScope), dinnerMoney(basis.cap)))
                    if let reserve = basis.fixedReserve { Text(dinnerFormat("Reserve recorded separately: %@", dinnerMoney(reserve))) }
                    Text(dinnerText("The entered cap is already the amount available for its scope. A recorded reserve is not subtracted again."))
                }
            }
            if let pair, let result, model.budgetVisible {
                Section(dinnerText("Reviewed trip comparison")) {
                    Text(dinnerText("These are entered observations, not live prices or stock."))
                    quoteResult(pair.first, result.first)
                    quoteResult(pair.second, result.second)
                    Text(dinnerFormat("Checkout change, second minus first: %@", dinnerMoney(result.checkoutChange)))
                    Text(dinnerFormat("Trip cash change, second minus first: %@", dinnerMoney(result.tripCashChange)))
                    if let minutes = result.extraMinutesChange { Text(dinnerFormat("Extra minutes change: %d", minutes)) }
                    if let breakEven = result.secondTripCashBreakEven { Text(dinnerFormat("Second trip cash break-even: %@", dinnerMoney(breakEven))) }
                    ForEach(result.issues, id: \.self) { Text(dinnerIssue($0)) }
                    Button(dinnerText("Save reviewed comparison")) { Task { _ = await model.saveQuotePair(pair) } }.disabled(!model.editable)
                    if model.state.quotePairs.contains(pair) {
                        Button(dinnerFormat("Preview using %@", pair.first.label)) { showPreview = model.previewAdoption(pair, option: pair.first) }
                            .disabled(!result.comparable || !result.first.coverageConfirmed || !model.editable)
                        Button(dinnerFormat("Preview using %@", pair.second.label)) { showPreview = model.previewAdoption(pair, option: pair.second) }
                            .disabled(!result.comparable || !result.second.coverageConfirmed || !model.editable)
                    }
                    Button(dinnerText("Continue editing")) { self.pair = nil; self.result = nil }
                }
            } else if model.budgetVisible {
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
                DinnerStoreFields(title: dinnerText("First store"), draft: $first)
                DinnerStoreFields(title: dinnerText("Second store"), draft: $second)
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
                if let shop = model.shop {
                    Section(dinnerText("Saved comparisons")) {
                        ForEach(model.state.quotePairs.filter { $0.shopID == shop.id }) { saved in
                            Button(dinnerFormat("%@ and %@", saved.first.label, saved.second.label)) {
                                do { result = try model.compare(saved); pair = saved } catch { model.report(error) }
                            }
                        }
                    }
                }
            } else { Text(dinnerText("Budget access is required to review store quotes.")) }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Two store trips")).dinnerAccess(model, budget: true)
            .navigationDestination(isPresented: $showPreview) { DinnerPreviewView(model: model) }
    }
    private func quoteResult(_ option: StoreQuoteOption, _ value: StoreQuoteResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(option.label).font(.headline)
            Text(option.quote.context.branchID)
            Text(option.quote.context.source)
            Text(option.quote.context.observedAt.formatted(date: .abbreviated, time: .shortened))
            Text(dinnerFormat("Checkout: %@", dinnerMoney(value.checkout.total.exact)))
            Text(dinnerCap(value.checkout.cap))
            Text(dinnerFormat("Checkout plus incremental trip cash: %@", dinnerMoney(value.tripInclusive.total.exact)))
            Text(value.coverageConfirmed ? dinnerText("Required availability reviewed") : dinnerText("Required availability unresolved"))
            if let minutes = value.extraMinutes { Text(dinnerFormat("Extra minutes: %d", minutes)) }
            Text(option.trip.tripAlreadyPlanned ? dinnerText("Trip already planned") : dinnerText("Additional trip"))
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
}
struct DinnerStoreFields: View {
    let title: String
    @Binding var draft: DinnerStoreDraft
    var body: some View {
        Section(title) {
            TextField(dinnerText("Store label"), text: $draft.label)
            TextField(dinnerText("Retailer name or identifier"), text: $draft.storeID)
            TextField(dinnerText("Branch"), text: $draft.branch)
            Picker(dinnerText("Mode"), selection: $draft.mode) {
                Text(dinnerText("Pickup")).tag(ShoppingMode.pickup)
                Text(dinnerText("Delivery")).tag(ShoppingMode.delivery)
                Text(dinnerText("In store")).tag(ShoppingMode.inStore)
            }
            DatePicker(dinnerText("Store slot"), selection: $draft.slot)
            TextField(dinnerText("Evidence source"), text: $draft.source)
            DatePicker(dinnerText("Observed at"), selection: $draft.observedAt)
            TextField(dinnerText("Whole checkout total in USD, optional"), text: $draft.total)
            Toggle(dinnerText("Total includes every item, fee, discount, tax and deposit"), isOn: $draft.allChargesIncluded)
            Toggle(dinnerText("All required quantities match the commitments"), isOn: $draft.quantitiesMatched)
            Toggle(dinnerText("This is one complete store plan"), isOn: $draft.singleStore)
            Picker(dinnerText("Required product availability"), selection: $draft.availability) {
                Text(dinnerText("Unknown")).tag(0)
                Text(dinnerText("Reviewed available")).tag(1)
                Text(dinnerText("Unavailable")).tag(2)
            }
            TextField(dinnerText("Incremental trip cash in USD, optional"), text: $draft.tripCash)
            TextField(dinnerText("Extra minutes, optional"), text: $draft.extraMinutes)
            Toggle(dinnerText("Trip already planned"), isOn: $draft.alreadyPlanned)
            Text(dinnerText("Blank costs stay unresolved. Enter zero only when you have confirmed there is no charge."))
        }
    }
}
