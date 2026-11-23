import SwiftUI
import CoreDomain

struct LedgerPackChoiceView: View {
    @ObservedObject var model: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    let shopID: UUID
    let lineID: UUID
    @State private var draft = ComparisonDraft()
    @State private var source = ""
    @State private var observedAt = Date()
    @State private var review: LedgerPackReview?
    @State private var saved = false
    @State private var validation: String?
    @State private var initialized = false
    @Environment(\.dismiss) private var dismiss
    private struct Ingredient: Equatable {
        let shopID: UUID
        let lineID: UUID
        let name: String
        let unit: UnitOfMeasure
    }
    private enum Field { case firstLabel, firstAmount, firstPrice, secondLabel, secondAmount, secondPrice, source, cap }
    @FocusState private var field: Field?

    private var currentRequirement: LedgerPackRequirement? {
        guard let shop = model.workspace.shops.first(where: { $0.id == shopID }) else { return nil }
        return try? LedgerPackRequirement.review(shop: shop, lineID: lineID, bindings: model.workspace.dinnerPlanning.portionBindings)
    }
    var body: some View {
        let requirement = currentRequirement
        let ingredient = requirement.map { Ingredient(shopID: shopID, lineID: lineID, name: $0.name, unit: $0.quantity.unit) }
        WorkingForm {
            if saved {
                Section {
                    Text(ledgerText(review?.result.offerA.packsToBuy == 0 ? "Use-at-home choice saved for review." : "Pack choice saved for checkout review."))
                    if review?.result.offerA.packsToBuy == 0 {
                        Text(ledgerText("Your ingredient needs are unchanged. Open Review checkout to save the use-at-home plan. This does not place a retailer order."))
                    } else {
                        Text(ledgerText("Your ingredient needs are unchanged. Open Review checkout to apply the purchased amount and item cost. An earlier saved checkout keeps its existing terms until you review it."))
                    }
                    Button(ledgerText("Done")) { dismiss() }.accessibilityIdentifier("ledgerPackDone")
                }
            } else if let review {
                Section(ledgerText("Review whole packs for this item")) {
                    Text(review.requirement.name).font(.headline)
                    LabeledContent(ledgerText("Needed for this list"), value: ledgerQuantity(review.requirement.quantity))
                    LabeledContent(ledgerText("Protected inside that amount"), value: ledgerQuantity(review.requirement.protectedQuantity))
                    Text(ledgerText("Item-only comparison. Whole-checkout affordability still needs all groceries, fees and other charges."))
                    Text("\(review.source) · \(review.reviewedAt.formatted())")
                }
                if let stock = review.request.confirmedAtHome {
                    Section(ledgerText("Confirmed food allocated to this need")) {
                        Text(ledgerQuantity(stock))
                        Text(ledgerText("Food reserved for other needs is excluded. This choice must be reviewed again if the batch or pickup changes."))
                    }
                }
                if review.result.offerA.packsToBuy == 0 {
                    Section {
                        Text(ledgerText("Use confirmed food at home · no purchase needed"))
                        Text(ledgerText("Keep every meal and protected portion. This decision adds no purchased item or item charge."))
                        Button(ledgerText("Use confirmed food for this need")) { save(review, offerID: review.request.offerA.id) }
                            .buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerUseAtHome")
                    }
                } else {
                    result(review.result.offerA, offer: review.request.offerA, review: review)
                    result(review.result.offerB, offer: review.request.offerB, review: review)
                }
                Button(ledgerText("Keep editing")) { self.review = nil; validation = nil }
            } else {
                if let requirement {
                    Section(ledgerText("Current ingredient need")) {
                        Text(requirement.name).marketJournalTitle(.title2)
                        LabeledContent(ledgerText("Needed for this list"), value: ledgerQuantity(requirement.quantity))
                        LabeledContent(ledgerText("Protected inside that amount"), value: ledgerQuantity(requirement.protectedQuantity))
                        if let stock = liveStock {
                            LabeledContent(ledgerText("Confirmed food allocated to this need"), value: ledgerQuantity(stock))
                            Text(ledgerText("Food reserved for other needs is excluded. This choice must be reviewed again if the batch or pickup changes."))
                        } else {
                            Text(ledgerText("Only confirmed food matched to this list and its current pickup allocation can reduce the purchase."))
                        }
                    }
                }
                if fullyCovered {
                    Section {
                        Text(ledgerText("Use confirmed food at home · no purchase needed"))
                        Button(ledgerText("Review use-at-home plan"), action: prepareAtHome)
                            .buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerReviewAtHome")
                    }
                } else {
                Section(ledgerText("First pack")) {
                    TextField(ledgerText("First pack label"), text: $draft.aLabel).focused($field, equals: .firstLabel)
                    TextField(ledgerText("First pack usable amount"), text: $draft.aQuantity).keyboardType(.numbersAndPunctuation).focused($field, equals: .firstAmount)
                    unitPicker($draft.aUnit)
                    if let requirement {
                        PackConversionControl(packLabel: draft.aLabel.isEmpty ? ledgerText("First pack") : draft.aLabel,
                                              sourceUnit: draft.aUnit, targetUnit: requirement.quantity.unit,
                                              conversion: $draft.aConversion, identifier: "ledgerPackConversion-a")
                    }
                    TextField(ledgerFormat("First pack price, %@", draft.currency.rawValue), text: $draft.aPrice).keyboardType(.decimalPad).focused($field, equals: .firstPrice)
                }
                Section(ledgerText("Second pack")) {
                    TextField(ledgerText("Second pack label"), text: $draft.bLabel).focused($field, equals: .secondLabel)
                    TextField(ledgerText("Second pack usable amount"), text: $draft.bQuantity).keyboardType(.numbersAndPunctuation).focused($field, equals: .secondAmount)
                    unitPicker($draft.bUnit)
                    if let requirement {
                        PackConversionControl(packLabel: draft.bLabel.isEmpty ? ledgerText("Second pack") : draft.bLabel,
                                              sourceUnit: draft.bUnit, targetUnit: requirement.quantity.unit,
                                              conversion: $draft.bConversion, identifier: "ledgerPackConversion-b")
                    }
                    TextField(ledgerFormat("Second pack price, %@", draft.currency.rawValue), text: $draft.bPrice).keyboardType(.decimalPad).focused($field, equals: .secondPrice)
                }
                Section(ledgerText("Reviewed price evidence")) {
                    TextField(ledgerText("Where you checked these packs and prices"), text: $source).focused($field, equals: .source)
                    DatePicker(ledgerText("Checked at"), selection: $observedAt)
                    TextField(ledgerFormat("Item-only spending limit (%@, optional)", draft.currency.rawValue), text: $draft.cap).keyboardType(.decimalPad).focused($field, equals: .cap)
                    Text(ledgerText("Blank amount or price stays unresolved. A resolved pack can be selected even when the other pack is unknown."))
                    Button(ledgerText("Review whole packs"), action: prepare).buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerReviewPacks")
                }
                }
            }
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model)
        }
        // Start each step at its heading even when the prior form was scrolled to its last row.
        .id(saved ? "saved" : review == nil ? "entry" : "review")
        .workingSurface().scrollDismissesKeyboard(.interactively)
            .navigationTitle(ledgerText("Choose whole packs"))
            .disabled(model.saving || !model.ready)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) }
            }
            .keyboardDoneAction(visible: field != nil, title: ledgerText("Done"), identifier: "ledger.pack.keyboardDone") { field = nil }
            .task {
                await pickup.load()
                if pickup.pantryIsActive { _ = await pickup.refreshPantryStock() }
            }
            .onChange(of: ingredient, initial: true) { previous, current in
                guard let current else { draft.aConversion = nil; draft.bConversion = nil; return }
                if !initialized || previous?.shopID != current.shopID || previous?.lineID != current.lineID {
                    draft = ComparisonDraft(currency: model.workspace.shops.first(where: { $0.id == current.shopID })?.basis.currency ?? .groceryDefault())
                    draft.aUnit = current.unit
                    draft.bUnit = current.unit
                    initialized = true
                }
                draft.item = current.name
                draft.unit = current.unit
            }
    }
    private func unitPicker(_ selection: Binding<UnitOfMeasure>) -> some View {
        Picker(ledgerText("Unit"), selection: selection) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) } }
    }
    @ViewBuilder private func result(_ result: OfferResult, offer: PackOffer, review: LedgerPackReview) -> some View {
        Section(offer.label) {
            if let cost = result.totalCost {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ledgerText("Item cost")).font(.subheadline).foregroundStyle(Theme.secondary)
                    Text(moneyText(cost)).font(.title.weight(.bold)).monospacedDigit()
                    if let count = result.packsToBuy, count > 0, let price = offer.price {
                        WholePackCalculation(count: count, price: price)
                    }
                }
                .padding(.vertical, 4)
            }
            if let basis = offer.confirmedConversion {
                Text(ComparisonConversion.readableText(for: basis))
                    .accessibilityIdentifier("ledgerPackBasis-\(offer.id)")
            }
            if let count = result.packsToBuy {
                LabeledContent(ledgerText("Whole packs to buy"), value: String(count))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("ledgerPackCount-\(offer.id)")
            }
            if let purchased = result.purchasedAmount, let unit = review.result.unit {
                LabeledContent(ledgerText("Purchased usable amount"), value: ledgerQuantity(Quantity(amount: purchased, unit: unit, originalLiteral: purchased.description)))
            }
            if let leftover = result.leftover, let unit = review.result.unit {
                LabeledContent(ledgerText("Left after this need"), value: ledgerQuantity(Quantity(amount: leftover, unit: unit, originalLiteral: leftover.description)))
            }
            if !result.isResolved { Text(ledgerText("This pack remains unresolved. Check its usable amount, unit and price.")) }
            if result.isResolved, result.packsToBuy.map({ $0 > 0 }) == true {
                Button(ledgerFormat("Choose %@ for checkout review", offer.label)) { save(review, offerID: offer.id) }.buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerChoosePack-\(offer.id)")
            }
        }
    }
    private var liveStock: Quantity? {
        guard let shop = model.workspace.shops.first(where: { $0.id == shopID }) else { return nil }
        return try? pickup.confirmedPackStock(shop: shop, lineID: lineID, bindings: model.workspace.dinnerPlanning.portionBindings)
    }
    private var fullyCovered: Bool {
        guard let stock = liveStock, let shop = model.workspace.shops.first(where: { $0.id == shopID }),
              let quantity = try? shop.quantity(forLineID: lineID) else { return false }
        return stock.amount >= quantity.amount
    }
    private func save(_ review: LedgerPackReview, offerID: String) {
        Task {
            do { saved = try await review.save(offerID: offerID, ledger: model, pickup: pickup); validation = nil }
            catch { validation = ledgerText("The list or reviewed source changed. Make a new pack review before choosing.") }
        }
    }
    private func prepareAtHome() {
        do {
            review = try LedgerPackReview.prepare(ledger: model, shopID: shopID, lineID: lineID,
                offerA: PackOffer(id: "a", label: ledgerText("Confirmed food at home"), usableQuantity: nil, price: nil),
                offerB: PackOffer(id: "b", label: ledgerText("Confirmed food at home"), usableQuantity: nil, price: nil),
                itemCap: nil, at: Date(), source: ledgerText("Reviewed pantry or freezer allocation"), pickup: pickup)
            guard review?.result.offerA.packsToBuy == 0 else { review = nil; throw LedgerPackError.staleSource }
            validation = nil
        } catch { validation = ledgerText("The list or confirmed stock changed. Review the current checkout copy and allocation, then review packs again.") }
    }
    private func prepare() {
        do {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.aLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.bLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerPackError.invalidEvidence }
            guard let requirement = currentRequirement,
                  draft.item == requirement.name, draft.unit == requirement.quantity.unit else { throw LedgerPackError.staleSource }
            let offers = try ComparisonModel(draft: draft).request()
            review = try LedgerPackReview.prepare(ledger: model, shopID: shopID, lineID: lineID,
                offerA: offers.offerA, offerB: offers.offerB, itemCap: offers.itemCap, at: observedAt, source: source, pickup: pickup)
            field = nil
            validation = nil
        } catch LedgerPackError.staleSource { validation = ledgerText("The list or confirmed stock changed. Review the current checkout copy and allocation, then review packs again.") }
        catch DinnerPlanningError.reviewRequired { validation = dinnerText("Review the current ingredient portions") }
        catch { validation = ledgerText("Enter the pack labels, checked source and valid amounts. Unknown amounts stay blank.") }
    }
}

/// A stock-only plan has meal commitments, but no retailer basket to place.
struct LedgerAtHomePlanView: View {
    @ObservedObject var model: PickupModel
    @Environment(\.pickupLedger) private var ledger
    var reviewNotice: String? {
        let allocation = model.allocation
        if allocation?.confirmedCoverageComplete == true {
            return model.hasCurrentBasketStockBasis ? nil : ledgerText("Current quantities still cover the meal needs. Review the updated stock before relying on this plan.")
        }
        if allocation?.demands.contains(where: { $0.issues.isEmpty && ($0.shortfall ?? .zero) > .zero }) == true {
            return ledgerText("Confirmed food no longer covers every need. Review the current allocation and purchase needs again.")
        }
        return ledgerText("Stock coverage is uncertain. Review the available amounts for these meals.")
    }

    var body: some View {
        let notice = reviewNotice
        List {
            PickupSaveStatus(model: model)
            Section {
                Text(ledgerText(notice == nil
                    ? "Use confirmed food at home · no purchase needed" : "Review ingredient and purchase needs")).font(.headline)
                Text(ledgerText("No retailer order was created. Meal needs and protected portions stay recorded."))
                if let notice {
                    Text(notice)
                        .foregroundStyle(Theme.warning)
                }
            }
            if let journey = model.journey {
                Section(ledgerText("Meal needs kept in this plan")) {
                    ForEach(journey.plannedNeeds) { need in
                        Text("\(need.name): \(ledgerQuantity(need.amount))")
                        if let coverage = model.allocation?.demands.first(where: { $0.id == need.id }), let allocated = coverage.allocated {
                            Text(ledgerFormat("Confirmed at home for this need: %@", ledgerQuantity(Quantity(amount: allocated, unit: coverage.unit, originalLiteral: allocated.description))))
                        }
                    }
                }
                NavigationLink(pTr("Confirm pantry or freezer food")) {
                    WorkingForm { PickupSavedStockSection(model: model, journey: journey) }
                        .navigationTitle(pTr("Confirm pantry or freezer food"))
                }
            }
            NavigationLink(pTr("Tell the cook")) { PickupCookView(model: model) }
            if let ledger {
                NavigationLink(ledgerText("Review ingredient and purchase needs")) { LedgerHomeView(model: ledger) }
            }
        }.workingSurface().navigationTitle(ledgerText("Use-at-home plan"))
    }
}
