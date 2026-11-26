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
        WorkingForm {
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
                    if model.paid {
                        if let coverage = pair.pairedItemCoverage {
                            LabeledContent(dinnerText("Items priced for the same quantity at both stores"),
                                           value: String(coverage.matched) + " / " + (coverage.total.map(String.init) ?? dinnerText("Unknown")))
                        } else { Text(dinnerText("Price coverage by item is unknown for an inclusive total.")).font(.footnote) }
                    }
                    quoteResult(pair.first, result.first).accessibilityIdentifier("quoteFirstResult")
                    quoteResult(pair.second, result.second).accessibilityIdentifier("quoteSecondResult")
                    quoteMoneyChange("Items before fees and discounts, second minus first: %@", result.itemSubtotalChange)
                    quoteMoneyChange("Checkout change, second minus first: %@", result.checkoutChange)
                    quoteMoneyChange("Checkout plus trip cash, second minus first: %@", result.tripCashChange)
                    if let minutes = result.extraMinutesChange { Text(dinnerFormat("Extra minutes change: %d", minutes)) }
                    if let breakEven = result.secondTripCashBreakEven { Text(dinnerFormat("Second trip cash break-even: %@", dinnerMoney(breakEven))) }
                    if let preferred = result.preferredByTotalCash {
                        LabeledContent(dinnerText("Lower confirmed total cash"), value: preferred == pair.first.id ? pair.first.label : pair.second.label)
                    }
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
                DinnerStoreFields(title: dinnerText("First store"), prefix: "quote.first.", draft: $draft.first, focus: $inputFocus, shopZone: model.shop?.basis.timeZoneIdentifier, currency: model.shop?.basis.currency ?? .usd, commitmentRows: draft.commitments.map { ($0.id, $0.name) })
                DinnerStoreFields(title: dinnerText("Second store"), prefix: "quote.second.", draft: $draft.second, focus: $inputFocus, shopZone: model.shop?.basis.timeZoneIdentifier, currency: model.shop?.basis.currency ?? .usd, commitmentRows: (draft.hasSeparateCommitments ? draft.secondCommitments : draft.commitments).map { ($0.id, $0.name) })
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
            .onChange(of: model.shop?.basis.currency) { _, _ in
                draft = DinnerQuoteEditDraft(); editQuotes(); showPreview = false
            }
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
            QuoteOrderEvidenceSummary(status: value.minimumStatus, minimum: option.orderMinimum, rows: option.supplies ?? [],
                names: Dictionary(uniqueKeysWithValues: option.commitments.commitments.map { ($0.id, $0.name) }))
            Text(dinnerCap(value.checkout.cap))
            switch option.trip.incrementalCash {
            case .exact(let amount): Text(dinnerFormat("Incremental trip cash: %@", dinnerMoney(amount)))
            case .bounded(let lower, let upper, _): Text(dinnerFormat("Incremental trip cash range: %@ to %@", dinnerMoney(lower), dinnerMoney(upper)))
            case .unknown: Text(dinnerFormat("Incremental trip cash: %@", dinnerMoney(nil)))
            }
            Text(dinnerFormat("Checkout plus incremental trip cash: %@", dinnerMoney(value.tripInclusive.total.exact)))
            Text(option.available == true ? dinnerText("Required availability reviewed") : dinnerText("Required availability unresolved"))
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
    var currency: Currency = .usd
    var commitmentRows: [(id: UUID, title: String)] = []
    var showsEligibilityReview = true
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
                EnteredQuoteValueField(title: dinnerFormat("Items before fees and discounts in %@, optional", currency.rawValue), value: $draft.itemSubtotal, identifier: prefix + "itemSubtotal", focus: focus)
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
                EnteredQuoteValueField(title: dinnerFormat("Whole checkout total in %@, optional", currency.rawValue), value: $draft.total, identifier: prefix + "total", focus: focus)
                Toggle(dinnerText("Total includes every item, fee, discount, tax and deposit"), isOn: $draft.allChargesIncluded).accessibilityIdentifier(prefix + "allChargesIncluded")
            }
            Toggle(dinnerText("All required quantities match the commitments"), isOn: $draft.quantitiesMatched).accessibilityIdentifier(prefix + "quantitiesMatched")
            Toggle(dinnerText("This is one complete store plan"), isOn: $draft.singleStore).accessibilityIdentifier(prefix + "singleStore")
            if showsEligibilityReview {
                Toggle(dinnerText("Offer eligibility reviewed"), isOn: $draft.eligibilityReviewed).accessibilityIdentifier(prefix + "eligibility")
            }
            Picker(dinnerText("Purchase minimum"), selection: $draft.orderMinimumKind) {
                Text(dinnerText("Minimum unknown")).tag(StoreOrderMinimum.Kind.unknown)
                Text(dinnerText("No purchase minimum")).tag(StoreOrderMinimum.Kind.noneRequired)
                Text(dinnerText("Minimum applies")).tag(StoreOrderMinimum.Kind.required)
            }.accessibilityIdentifier(prefix + "purchaseMinimum")
            if draft.orderMinimumKind == .required {
                EnteredQuoteValueField(title: dinnerText("Required merchandise subtotal"), value: $draft.minimumAmount,
                    identifier: prefix + "minimumAmount", focus: focus)
                EnteredQuoteValueField(title: dinnerText("Eligible merchandise subtotal"), value: $draft.eligibleSubtotal,
                    identifier: prefix + "eligibleSubtotal", focus: focus)
            }
            Toggle(dinnerText("Review packages by commitment"), isOn: $draft.detailSupply)
            if draft.detailSupply {
                ForEach(commitmentRows, id: \.id) { id, title in
                    let row = Binding(get: { draft.supply[id] ?? StoreSupplyDraft() }, set: { draft.supply[id] = $0 })
                    Text(verbatim: title).font(.headline)
                    textField(dinnerText("Units needed"), value: row.needed, key: id.uuidString + ".need")
                    textField(dinnerText("Usable units per package"), value: row.usable, key: id.uuidString + ".usable")
                    textField(dinnerText("Packages in this quote"), value: row.packs, key: id.uuidString + ".packs")
                    Picker(dinnerText("Unit"), selection: row.unit) {
                        ForEach([UnitOfMeasure.count, .gram, .milliliter], id: \.self) { unit in Text(dinnerUnit(unit)).tag(unit) }
                    }
                }
            }
            Picker(dinnerText("Required product availability"), selection: $draft.availability) {
                Text(dinnerText("Unknown")).tag(0)
                Text(dinnerText("Reviewed available")).tag(1)
                Text(dinnerText("Unavailable")).tag(2)
            }.accessibilityIdentifier(prefix + "availability")
            if let (lower, upper, reason) = draft.tripRange {
                Text(dinnerFormat("Incremental trip cash range: %@ to %@", dinnerMoney(lower), dinnerMoney(upper)))
                Text(reason)
            } else {
                EnteredQuoteValueField(title: dinnerFormat("Incremental trip cash in %@, optional", currency.rawValue), value: $draft.tripCash, identifier: prefix + "tripCash", focus: focus)
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

struct QuoteOrderEvidenceSummary: View {
    let status: StoreOrderMinimum.Status
    let minimum: StoreOrderMinimum?
    let rows: [StoreCommitmentSupply]
    let names: [UUID: String]
    var body: some View {
        switch status {
        case .unknown: Text(dinnerText("Purchase minimum or eligible subtotal is unknown"))
        case .noneRequired: Text(dinnerText("No purchase minimum"))
        case .met: Text(dinnerText("Purchase minimum met"))
        case .notMet: Text(dinnerText("Purchase minimum not met"))
        }
        if let minimum, minimum.kind == .required {
            LabeledContent(dinnerText("Required merchandise subtotal"), value: dinnerMoney(minimum.minimum))
            LabeledContent(dinnerText("Eligible merchandise subtotal"), value: dinnerMoney(minimum.eligibleSubtotal))
        }
        ForEach(rows) { row in
            if let surplus = try? row.surplus() {
                VStack(alignment: .leading) {
                    Text(verbatim: names[row.id] ?? row.id.uuidString)
                    LabeledContent(dinnerText("Units needed"), value: String(row.requiredUnits) + " " + dinnerUnit(row.unit))
                    Text(verbatim: String(row.packages) + " × " + String(row.usableUnitsPerPackage) + " " + dinnerUnit(row.unit))
                    LabeledContent(surplus >= 0 ? dinnerText("Excess usable quantity") : dinnerText("Missing usable quantity"),
                                   value: String(abs(surplus)) + " " + dinnerUnit(row.unit))
                }
            }
        }
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
            Text(title).font(.caption).foregroundStyle(Theme.secondary)
            TextField(title, text: $value).focused(focus, equals: identifier).accessibilityIdentifier(identifier)
        }
    }
}

/// Reads only this private ledger's accepted plan and this device's authorized Pantry.
struct WeeklyCostReviewView: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    @State private var selected: UUID?
    @State private var loaded: LoadKey?
    @State private var review: WeeklyPurchaseReview?
    @State private var failed = false

    private struct LoadKey: Equatable {
        let receipt: UUID
        let origin: UUID
        let inventoryRevision: Int64
        let journeyRevision: Int64?
        let generation: UUID
        let actor: String
    }

    private var receipts: [DinnerApplyReceipt] {
        guard let shop = model.shop, model.paid, model.budgetVisible, let owner = model.localIdeaWorkspaceID,
              let actor = model.editorIdentity?.actorID else { return [] }
        return model.state.applyReceipts.reversed().filter {
            $0.proposal.shopID == shop.id && $0.proposal.repeatWeek != nil &&
            $0.proposal.namespace == "local:\(owner.uuidString)" && $0.appliedBy == actor
        }
    }
    private var receipt: DinnerApplyReceipt? { receipts.first { $0.id == selected } ?? receipts.first }
    private var journey: PickupJourney? { pickup.journeys.first { $0.id == model.shop?.id } }
    private var key: LoadKey? {
        guard let receipt, receipt.costBaseline != nil, pickup.ready, pickup.pantryReadIsCurrent,
              let state = pickup.pantrySnapshot?.state, state.active, pickup.sourceWorkspaceID == state.workspaceID,
              let ledger = model.store as? LedgerModel, pickup.recoveryLedger === ledger,
              let actor = model.editorIdentity?.actorID else { return nil }
        return .init(receipt: receipt.id, origin: state.workspaceID, inventoryRevision: state.revision,
                     journeyRevision: journey?.revision, generation: pickup.privatePantryGeneration, actor: actor)
    }

    var body: some View {
        WorkingForm {
            if receipts.count > 1, let receipt {
                Picker(dinnerText("Accepted plan"), selection: Binding(get: { receipt.id }, set: { selected = $0 })) {
                    ForEach(receipts) { plan in Text(plan.appliedAt.formatted()).tag(plan.id) }
                }
            }
            if let receipt, let baseline = receipt.costBaseline {
                Section(dinnerText("Original shopping estimate")) {
                    Text(receipt.appliedAt.formatted())
                    if !baseline.store.isEmpty { Text(verbatim: baseline.store) }
                    let prices = baseline.lines.compactMap(\.estimate)
                    LabeledContent(dinnerText("Priced items"), value: "\(prices.count) / \(baseline.lines.count)")
                    LabeledContent(dinnerText("Known estimated subtotal"), value: dinnerMoney(try? WeeklyPurchaseReview.total(prices)))
                }
                let current = key != nil && loaded == key ? review : nil
                purchaseSection(current, currency: baseline.currency)
                plannedLines(baseline, current: current)
                cookedSection(receipt)
            } else { Text(dinnerText("No saved estimate for this shop.")) }
        }
        .privacySensitive()
        .navigationTitle(dinnerText("Weekly costs and outcomes"))
        .dinnerAccess(model, budget: true)
        .task(id: key) { await load(key) }
    }

    private func purchaseSection(_ current: WeeklyPurchaseReview?, currency: Currency) -> some View {
        Section(dinnerText("Confirmed private purchases")) {
            LabeledContent(dinnerText("Known paid subtotal"), value: dinnerMoney(current?.knownActual))
            if let current {
                let matching = current.purchases.filter { $0.net?.currency == currency }
                Text(dinnerFormat("Receipt lines with an amount in %@: %d of %d", currency.rawValue, matching.count, current.purchases.count))
                Text(dinnerFormat("Planned items without a linked receipt line: %d", current.unmatchedPlanLines))
                ForEach(current.purchases.filter { $0.plannedLineID == nil }, id: \.acquisition.id) { purchase in
                    purchaseRow(purchase)
                    if let match = purchase.acquisition.orderMatch, match.portions.count > 1 {
                        Text(dinnerText("Receipt quantity split across items. The paid amount is counted once.")).font(.footnote)
                    } else {
                        Text(dinnerText("Receipt saved for this shop. Basket line unresolved.")).font(.footnote)
                    }
                }
            } else if key != nil && !failed { ProgressView() }
            else {
                Text(dinnerText("Private purchase evidence is unavailable."))
                if failed, let key { Button(ledgerText("Retry")) { Task { await load(key) } } }
            }
        }
    }

    private func plannedLines(_ baseline: WeeklyCostBaseline, current: WeeklyPurchaseReview?) -> some View {
        Section(dinnerText("Planned items")) {
            ForEach(baseline.lines) { line in
                DisclosureGroup(line.name) {
                    Text(dinnerQuantity(line.quantity))
                    ForEach(Array(line.packages.enumerated()), id: \.offset) { _, pack in
                        let size = Quantity(amount: pack.amountPerPack, unit: pack.unit, originalLiteral: pack.amountPerPack.description)
                        Text(dinnerFormat("Packages: %@ × %@", String(pack.count), dinnerQuantity(size)))
                    }
                    if let containers = line.containers { Text(dinnerFormat("Reviewed containers: %lld", containers.count)) }
                    LabeledContent(dinnerText("Original estimate"), value: dinnerMoney(line.estimate))
                    switch line.source {
                    case .pick(let at): Text(dinnerText("Recorded shelf price") + " · " + at.formatted()).font(.footnote)
                    case .reviewedPack: Text(dinnerText("Reviewed pack choice")).font(.footnote)
                    case nil: EmptyView()
                    }
                    let purchases = current?.purchases.filter { $0.plannedLineID == line.id } ?? []
                    let split = current?.purchases.compactMap { purchase -> Quantity? in
                        guard let match = purchase.acquisition.orderMatch, match.portions.count > 1 else { return nil }
                        return match.portions.first { $0.lineID == line.id }?.quantity
                    } ?? []
                    if purchases.isEmpty && split.isEmpty { Text(dinnerText("No matched receipt line")) }
                    ForEach(purchases, id: \.acquisition.id) { purchase in purchaseRow(purchase) }
                    ForEach(Array(split.enumerated()), id: \.offset) { _, quantity in
                        Text(dinnerFormat("Split receipt quantity: %@", dinnerQuantity(quantity)))
                    }
                    if split.isEmpty, let status = quantityDifference(line.quantity, purchases: purchases) { Text(status) }
                    if split.isEmpty, let estimate = line.estimate, !purchases.isEmpty,
                       purchases.allSatisfy({ $0.net?.currency == estimate.currency }),
                       let actual = try? WeeklyPurchaseReview.total(purchases.compactMap(\.net)),
                       let change = try? actual.subtracting(estimate) {
                        LabeledContent(dinnerText("Paid minus estimate"), value: dinnerMoney(change))
                    }
                }
            }
        }
    }

    @ViewBuilder private func cookedSection(_ receipt: DinnerApplyReceipt) -> some View {
        if let plan = receipt.proposal.repeatWeek, let start = plan.targetStart.date {
            let cooked = (journey?.cookedMeals ?? []).filter { row in
                row.isActive && receipt.proposal.changes.contains { change in
                    if case .choose(let dinner) = change { return dinner.occurrenceID == row.draft.meal.id }
                    return false
                }
            }
            Section(dinnerText("Confirmed cooked dinners")) {
                if cooked.isEmpty { Text(dinnerText("No cooking recorded for these dinners.")) }
                ForEach(cooked, id: \.draft.id) { row in Text(verbatim: row.draft.cookedTitle) }
            }
            var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: plan.targetStart.timeZoneIdentifier) ?? .current; return c }
            if let next = calendar.date(byAdding: .day, value: 7, to: start) {
                if let target = try? MealDay(date: next, timeZoneIdentifier: plan.targetStart.timeZoneIdentifier) {
                    waitingFood(receipt: receipt, next: target)
                }
                DinnerDecisionButton(model: model, title: dinnerText("Review items for next week"), identifier: "weekCost.repeat") {
                    DinnerRepeatWeekView(model: model, initialDate: next, useSelectedStart: true)
                }
            }
        }
    }

    @ViewBuilder private func waitingFood(receipt: DinnerApplyReceipt, next: MealDay) -> some View {
        if key != nil, let snapshot = pickup.pantrySnapshot {
            let claims = (try? model.cookedDinners(pickup: pickup)) ?? []
            let meals = Set(receipt.proposal.changes.compactMap { change -> UUID? in
                if case .choose(let dinner) = change { return dinner.occurrenceID }
                return nil
            })
            let cooks = Set((journey?.cookedMeals ?? []).filter { $0.isActive && meals.contains($0.draft.meal.id) }.map(\.draft.id))
            let waiting = claims.filter { claim in
                guard claim.state == .active, let dinner = claim.cookedDinner, dinner.servedAt == nil, cooks.contains(dinner.cookID),
                      let lot = snapshot.lots.first(where: { $0.id == claim.lotID }), let amount = claim.amount,
                      amount.amount > .zero else { return false }
                return snapshot.availability.reservations(for: lot, among: snapshot.reservations).contains {
                    $0.id == claim.id && $0.allocation?.amount == amount.amount && !$0.coverage.unresolved
                }
            }
            Section(dinnerText("Cooked food still waiting")) {
                if waiting.isEmpty { Text(dinnerText("No confirmed portions waiting for these dinners.")) }
                ForEach(waiting) { claim in
                    NavigationLink {
                        DinnerCookedPortionsView(model: model, id: claim.id, suggestedDay: next)
                    } label: {
                        VStack(alignment: .leading) {
                            DinnerCookedPortionsLabel(claim: claim)
                            Text(dinnerFormat("Review for %@", dinnerDay(next))).font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private func quantityDifference(_ planned: Quantity?, purchases: [WeeklyPurchaseReview.Purchase]) -> String? {
        guard let planned, !purchases.isEmpty else { return nil }
        var total = Rational.zero
        for purchase in purchases {
            guard let amount = try? purchase.acquisition.received.converted(to: planned.unit),
                  let next = try? total.adding(amount) else { return dinnerText("Quantity units need review.") }
            total = next
        }
        return total != planned.amount ? dinnerText("Received quantity differs from the plan.") : nil
    }

    @ViewBuilder private func purchaseRow(_ purchase: WeeklyPurchaseReview.Purchase) -> some View {
        let row = purchase.acquisition
        VStack(alignment: .leading) {
            Text(verbatim: row.name + " · " + dinnerQuantity(row.received))
            Text(dinnerFormat("Receipt revision %lld", row.revision)).font(.footnote)
            Text(verbatim: row.merchant + " · " + row.purchaseDate.formatted(date: .abbreviated, time: .omitted))
            LabeledContent(dinnerText("Receipt line total"), value: dinnerMoney(row.paidLineTotal))
            ForEach(purchase.earlierRevisions) { earlier in
                LabeledContent(dinnerFormat("Receipt revision %lld", earlier.revision), value: dinnerMoney(earlier.paidLineTotal))
            }
            if let credit = purchase.credit, credit.minorUnits > 0 {
                LabeledContent(dinnerText("Confirmed discounts and refunds"), value: dinnerMoney(credit))
            }
            if let id = purchase.plannedLineID,
               let fragment = journey?.pickup?.receipts.first(where: { fragment in
                   guard case .linked(let key) = row.stock else { return false }
                   return fragment.key == key && key.orderLineID == id
               }), fragment.disposition == .wrongItem { Text(dinnerText("Different item received")) }
        }
    }

    @MainActor private func load(_ requested: LoadKey?) async {
        review = nil; loaded = nil; failed = false
        guard let requested, requested == key else { return }
        guard let pantry = pickup.makePantryModel(),
              let receipt, let baseline = receipt.costBaseline, let state = pickup.pantrySnapshot?.state else { failed = true; return }
        do {
            let result = try await pantry.weeklyPurchaseReview(baseline, pickup: .init(originID: requested.origin, id: receipt.proposal.shopID),
                fragments: Set(journey?.pickup?.receipts.map(\.key) ?? []), expected: state)
            guard !Task.isCancelled, requested == key else { return }
            review = result; loaded = requested
        } catch { if !Task.isCancelled, requested == key { failed = true } }
    }
}
