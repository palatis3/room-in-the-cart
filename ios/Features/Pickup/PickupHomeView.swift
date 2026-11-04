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
                            NavigationLink(pTr("Prepare retailer handoff")) { PickupHandoffView(model: model) }
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
    var body: some View {
        if let error = model.error {
            Section {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("pickup-save-error")
                if model.hasPendingSave {
                    Button(pTr("Retry save")) { Task { await model.retrySave() } }
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
    @State private var store = ""
    @State private var branch = ""
    @State private var slot = ""
    @State private var source = ""
    @State private var observed = Date()
    @State private var mode: ShoppingMode = .pickup
    @State private var scope: CheckoutScope = .wholeCheckout
    @State private var inclusive = false
    @State private var total = ""
    @State private var prices: [UUID: String] = [:]
    @State private var fee = ""
    @State private var threshold = ""
    @State private var discount = ""
    @State private var tax = ""
    @State private var deposits = ""
    @State private var cap = ""
    @State private var complete = true
    @State private var selected: Set<UUID> = []
    @State private var preview: (BasketProposal, CheckoutComparison)?
    @State private var formError: String?
    @State private var hold = ""
    @State private var availableFunds = ""
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            CheckoutQuotesContextLink(pickup: model)
            PickupStockBasisNotice(model: model)
            Section(pTr("Retailer preview · source and time")) {
                TextField(pTr("Store"), text: $store)
                TextField(pTr("Branch"), text: $branch)
                TextField(pTr("Pickup or delivery slot"), text: $slot)
                TextField(pTr("Source of these prices"), text: $source)
                DatePicker(pTr("Observed"), selection: $observed)
                Picker(pTr("Shopping mode"), selection: $mode) {
                    Text(pTr("Pickup")).tag(ShoppingMode.pickup)
                    Text(pTr("Delivery")).tag(ShoppingMode.delivery)
                    Text(pTr("In store")).tag(ShoppingMode.inStore)
                }
                Picker(pTr("Scope"), selection: $scope) {
                    Text(pTr("Whole checkout")).tag(CheckoutScope.wholeCheckout)
                    Text(pTr("Dinners only")).tag(CheckoutScope.dinner)
                    Text(pTr("Selected items only")).tag(CheckoutScope.item)
                }
                PickupEvidenceField(title: "Spending cap", amount: $cap)
            }
            Section(pTr("Expected charges · USD")) {
                Toggle(pTr("Retailer total already includes all charges"), isOn: $inclusive)
                Text(pTr("Blank means unknown. Enter 0 only for a confirmed zero charge."))
                if inclusive { PickupEvidenceField(title: "Inclusive total", amount: $total) }
                else {
                    ForEach(model.journey?.basket?.current.lines ?? []) { line in
                        PickupEvidenceField(title: line.name, amount: Binding(get: { prices[line.id] ?? "" }, set: { prices[line.id] = $0 }))
                    }
                    Toggle(pTr("All original items are represented"), isOn: $complete)
                    PickupEvidenceField(title: "Fee below threshold or fixed fee", amount: $fee)
                    PickupEvidenceField(title: "Fee waived at subtotal (optional)", amount: $threshold)
                    PickupEvidenceField(title: "Eligible discount", amount: $discount)
                    PickupEvidenceField(title: "Tax", amount: $tax)
                    PickupEvidenceField(title: "Deposits and other charges", amount: $deposits)
                }
                Button(pTr("Save and evaluate checkout")) { saveQuote() }.buttonStyle(.borderedProminent)
                    .disabled(!model.hasCurrentBasketStockBasis)
                if let formError { Text(formError).foregroundStyle(.red) }
                if let result = model.result, let id = model.journey?.id {
                    NavigationLink(pTr("Check price by weight")) { PickupWeightReview(model: model, shopID: id) }
                        .accessibilityIdentifier("checkout.weightReview")
                    PickupResultView(result: result)
                }
            }
            Section(pTr("Payment hold · separate from spending")) {
                PickupEvidenceField(title: "Retailer-displayed hold", amount: $hold)
                PickupEvidenceField(title: "Available funds (private, this screen only)", amount: $availableFunds)
                if let held = try? ComparisonModel.money(hold), let funds = try? ComparisonModel.money(availableFunds), let gap = try? held.subtracting(funds) {
                    Text("\(pTr("Hold less available funds")): \(pMoney(gap))")
                } else { Text(pTr("Hold comparison unresolved")) }
            }
            if !inclusive, model.result != nil {
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
                        Button(pTr("Apply reviewed deferral")) { Task { if await model.applyDeferral(preview.0) { self.preview = nil; selected = [] } } }
                        Button(pTr("Cancel preview")) { self.preview = nil }
                    }
                    ForEach(model.journey?.proposals.filter { !(model.journey?.undoneProposals.contains($0.id) ?? false) } ?? []) { proposal in
                        Button(pTr("Undo deferral and review prices")) { Task { await model.undoDeferral(proposal) } }
                    }
                }
            }
        }.navigationTitle(pTr("Whole checkout"))
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(pTr("Done")) { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
        .disabled(model.saving)
        .onAppear { populate() }
    }
    private func populate() {
        guard let value = model.journey else { return }
        store = value.context?.storeID ?? ""; branch = value.context?.branchID ?? ""; slot = value.context?.slot ?? ""; source = value.context?.source ?? ""
        mode = value.context?.mode ?? .pickup; observed = value.context?.observedAt ?? Date()
        if let saved = value.cap { cap = Decimal(saved.amount.minorUnits).descriptionFromCents; scope = saved.scope }
        for line in value.basket?.current.lines ?? [] { if case let .exact(amount) = line.expectedCost { prices[line.id] = Decimal(amount.minorUnits).descriptionFromCents } }
    }
    private func saveQuote() {
        do {
            guard let value = model.journey, !store.isEmpty, !branch.isEmpty, !slot.isEmpty, !source.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
            let context = CheckoutContext(storeID: store, branchID: branch, mode: mode, slot: slot, commitmentsID: value.context?.commitmentsID ?? value.id, observedAt: observed, source: source)
            let pricing: CheckoutPricing
            if inclusive { pricing = .inclusiveTotal(try pickupEvidence(total)) }
            else {
                let lines = try (value.basket?.current.lines ?? []).map { CheckoutLine(id: $0.id, name: $0.name, cost: try pickupEvidence(prices[$0.id] ?? "")) }
                let feeRule: CheckoutFeeRule
                if let threshold = try ComparisonModel.money(threshold) { feeRule = .waivedAt(threshold: threshold, belowThreshold: try pickupEvidence(fee), basis: .eligibleItemsAfterEligibleDiscounts) }
                else { feeRule = .fixed(try pickupEvidence(fee)) }
                pricing = .components(lines: lines, lineSetComplete: complete, fees: [CheckoutFee(id: "retailer-fee", rule: feeRule)], discounts: [CheckoutDiscount(id: "eligible-discount", amount: try pickupEvidence(discount), reducesEligibleSubtotal: true)], tax: try pickupEvidence(tax), deposits: try pickupEvidence(deposits))
            }
            let cap = try ComparisonModel.money(cap).map { CheckoutCap(scope: scope, commitmentsID: context.commitmentsID, amount: $0) }
            let quote = CheckoutQuote(scope: scope, context: context, pricing: pricing)
            Task { await model.setQuote(quote, cap: cap) }; formError = nil; preview = nil
        } catch { formError = pTr("Enter source, store, branch and slot, and valid dollar amounts with at most two decimal places.") }
    }
}
private extension Decimal { var descriptionFromCents: String { (self / 100).description } }

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
    @EnvironmentObject private var access: WorkspaceAccess
    @State private var sharing: HandoffSnapshot?
    @State private var retailerURL = ""
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            PickupStockBasisNotice(model: model)
            Text(pTr("Freeze the reviewed revision before leaving the app. Copying or sharing does not place an order."))
            Button(pTr("Freeze reviewed basket")) { Task { await model.freeze() } }.disabled(model.result == nil || model.frozenSnapshot != nil)
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
                Button(pTr("I placed this order")) { Task { await model.reportPlaced() } }.buttonStyle(.borderedProminent)
                    .disabled(model.journey?.basket?.phase == .reportedPlaced || !model.hasCurrentBasketStockBasis)
                if !model.hasCurrentBasketStockBasis, model.journey?.basket?.phase != .reportedPlaced {
                    Text(ledgerText("The frozen order keeps its original quantities. Reporting an order you already placed does not confirm that the changed food supply covers every meal."))
                    Button(ledgerText("I already placed this original order with the retailer")) {
                        Task { await model.reportPlaced(acknowledgingChangedStock: true) }
                    }.accessibilityIdentifier("pickupReportOriginalOrderAfterStockChange")
                }
                if model.journey?.basket?.phase != .reportedPlaced {
                    Button(pTr("Reopen draft and recheck prices")) { Task { await model.reopenDraft() } }
                }
                Text(pTr("Still checking out? Your saved snapshot stays here. Placement requires your explicit report."))
                Section(pTr("Handoff history")) {
                    ForEach(model.journey?.basket?.handoffActions ?? []) { event in Text("\(pTr(event.kind.rawValue)) · \(event.occurredAt.formatted())") }
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
}

private struct PickupWeightReview: View {
    @ObservedObject var model: PickupModel
    let shopID: UUID
    @State private var lineID: UUID?
    @State private var rate = ""
    @State private var increment = ""
    @State private var unit: UnitOfMeasure = .pound
    @State private var rounding: WeightChargeRounding = .unknown
    @FocusState private var typing: Bool

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
                        .focused($typing).accessibilityIdentifier("checkout.weightRate")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(pTr("Retailer billing increment")).font(.caption).accessibilityHidden(true)
                    TextField(pTr("Retailer billing increment"), text: $increment)
                        .keyboardType(.decimalPad).focused($typing).accessibilityIdentifier("checkout.weightIncrement")
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
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(pTr("Done")) { typing = false } } }
    }
}
